package Plugins::SiriusXM::APImetadata;

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Networking::SimpleAsyncHTTP;
use JSON::XS;
use Date::Parse;
use Time::HiRes;

my $log = logger('plugin.siriusxm');
my $prefs = preferences('plugin.siriusxm');

# xmplaylists.com API JSON Schema:
# {
#   "count": 0,
#   "next": "string",
#   "previous": "string",
#   "results": [
#     {
#       "id": "string",
#       "timestamp": "string",
#       "track": {
#         "id": "string",
#         "title": "string",
#         "artists": [
#           "string"
#         ]
#       },
#       "spotify": {
#         "id": "string",
#         "albumImageLarge": "string",
#         "albumImageMedium": "string",
#         "albumImageSmall": "string",
#         "previewUrl": "string"
#       }
#     }
#   ],
#   "channel": {
#     "id": "string",
#     "name": "string",
#     "number": "string",
#     "deeplink": "string",
#     "genres": [
#       "string"
#     ],
#     "shortDescription": "string",
#     "longDescription": "string",
#     "spotifyPlaylist": "string",
#     "applePlaylist": "string"
#   }
# }

# Fetch metadata from xmplaylist.com API
sub fetchMetadata {
    my ($class, $client, $channel_info, $callback) = @_;
    
    return unless $client && $channel_info;
    
    my $xmplaylist_name = $channel_info->{xmplaylist_name};
    return unless $xmplaylist_name;
    
    my $url = "https://xmplaylist.com/api/station/$xmplaylist_name";
    
    $log->debug("Fetching metadata from xmplaylist.com for channel: $xmplaylist_name");
    
    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $response = shift;
            $class->_processResponse($client, $channel_info, $response, $callback);
        },
        sub {
            my ($http, $error) = @_;
            $log->warn("Failed to fetch metadata from xmplaylist.com: $error");
            $callback->() if $callback;
        },
        {
            timeout => 15,
        }
    );
    
    $http->get($url);
}

# Process xmplaylist.com API response
sub _processResponse {
    my ($class, $client, $channel_info, $response, $callback) = @_;
    
    return unless $client && $response;
    
    my $content = $response->content;
    my $data;
    
    eval {
        $data = decode_json($content);
    };
    
    if ($@) {
        $log->error("Failed to parse xmplaylist.com response: $@");
        $callback->() if $callback;
        return;
    }
    
    # Extract track information from latest result first to check timestamp
    my $results = $data->{results};
    unless ($results && @$results) {
        $callback->() if $callback;
        return;
    }

    my $latest_track = $results->[0];
    my $track_info = $latest_track->{track};
    my $spotify_info = $latest_track->{spotify};
    my $timestamp = $latest_track->{timestamp};

    return unless $track_info;

    # Determine whether to use xmplaylists metadata or fallback to channel info
    # based on timestamp (if metadata is 0-200 seconds old, use it; otherwise use channel info)
    my $use_xmplaylists_metadata = 0;
    my $metadata_is_fresh = 0;
    
    # Only consider xmplaylists metadata if metadata is enabled
    if ($prefs->get('enable_metadata') && $timestamp) {
        # Parse timestamp and check if it's within 3 minutes
        eval {
            # Use Date::Parse to handle UTC timestamp format: 2025-08-09T15:57:41.586Z
            my $track_time = str2time($timestamp);
            die "Failed to parse timestamp" unless defined $track_time;
            
            my $current_time = time();
            my $age_seconds = $current_time - $track_time;
            
            $log->debug("Track timestamp: $timestamp, age: ${age_seconds}s");
            
            # Use xmplaylists metadata if timestamp is (200 seconds) or newer
            if ($age_seconds <= 200) {
                $use_xmplaylists_metadata = 1;
                $metadata_is_fresh = 1;
            }
        };
        
        if ($@) {
            $log->warn("Failed to parse timestamp '$timestamp': $@");
            # Default to using xmplaylists metadata if we can't parse timestamp
            $use_xmplaylists_metadata = 1;
            $metadata_is_fresh = 1;
        }
    }
    
    # Build new metadata
    my $new_meta = {};
    
    if ($use_xmplaylists_metadata) {
        # Use enhanced metadata from xmplaylist.com
        
        # Track title
        if ($track_info->{title}) {
            $new_meta->{title} = $track_info->{title};
        }

        # Artists (join multiple if present)
        if ($track_info->{artists} && ref($track_info->{artists}) eq 'ARRAY') {
            my @artists = @{$track_info->{artists}};
            if (@artists) {
                $new_meta->{artist} = join(', ', @artists);
            }
        }

        # Album artwork from Spotify
        if ($spotify_info && $spotify_info->{albumImageLarge}) {
            $new_meta->{cover} = $spotify_info->{albumImageLarge};
            $new_meta->{icon} = $spotify_info->{albumImageLarge};
        }

        # Add channel information
        $new_meta->{album} = $channel_info->{name} || 'SiriusXM';
        $new_meta->{bitrate} = '';

    } else {
        # Fall back to basic channel info when metadata is too old or disabled
        if ($channel_info) {
            # Fall back to basic channel info
            $new_meta->{artist} = $channel_info->{name};
            $new_meta->{title} = $channel_info->{description} || $channel_info->{name};
            $new_meta->{cover} = $channel_info->{icon};
            $new_meta->{icon} = $channel_info->{icon};
            $new_meta->{album} = 'SiriusXM';
            $new_meta->{bitrate} = '';
        }
    }

    # Return metadata and freshness info through callback
    if ($callback) {
        $callback->({
            metadata => $new_meta,
            next => $data->{next},
            is_fresh => $metadata_is_fresh,
        });
    }
}

1;