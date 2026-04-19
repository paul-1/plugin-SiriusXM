package Plugins::SiriusXM::APImetadata;

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Cache;
use Slim::Networking::SimpleAsyncHTTP;
use JSON::XS;
use Date::Parse;
use Time::HiRes;
use File::Spec;
use Errno qw(ENOENT);

my $log = logger('plugin.siriusxm');
my $prefs = preferences('plugin.siriusxm');
my $cache = Slim::Utils::Cache->new();

use constant STATION_CACHE_TIMEOUT => 21600; # 6 hours
use constant MIN_NEXT_UPDATE_DELAY_SECONDS => 1;

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

# Track in-flight station listing requests to prevent concurrent calls
my %station_fetch_callbacks = ();

# Fetch station listings from xmplaylist.com API 
# Returns mapping of siriusChannelNumber -> xmplaylist deeplink name
sub fetchStationListings {
    my ($class, $callback) = @_;
    
    # Check cache first
    my $cached_stations = $cache->get('xmplaylist_stations');
    if ($cached_stations) {
        $log->debug("Using cached station listings from xmplaylist.com");
        $callback->($cached_stations) if $callback;
        return;
    }
    
    # Check if we're already fetching station listings
    if (exists $station_fetch_callbacks{'in_progress'}) {
        $log->debug("Station listings fetch already in progress, queuing callback");
        push @{$station_fetch_callbacks{'in_progress'}}, $callback if $callback;
        return;
    }
    
    # Initialize the callback queue
    $station_fetch_callbacks{'in_progress'} = $callback ? [$callback] : [];
    
    my $url = "https://xmplaylist.com/api/station";
    
    $log->debug("Fetching station listings from xmplaylist.com");
    
    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $response = shift;
            $class->_processStationListings($response, $station_fetch_callbacks{'in_progress'});
        },
        sub {
            my ($http, $error) = @_;
            $log->warn("Failed to fetch station listings from xmplaylist.com: $error");
            # Call all queued callbacks with empty result
            for my $cb (@{$station_fetch_callbacks{'in_progress'} || []}) {
                $cb->({}) if $cb;
            }
            delete $station_fetch_callbacks{'in_progress'};
        },
        {
            timeout => 30,
        }
    );
    
    $http->get($url);
}

# Process station listings response and build lookup table
sub _processStationListings {
    my ($class, $response, $callbacks) = @_;
    
    return unless $response;
    
    # Ensure callbacks is an array reference
    $callbacks = [$callbacks] unless ref($callbacks) eq 'ARRAY';
    
    my $content = $response->content;
    my $data;
    
    eval {
        $data = decode_json($content);
    };
    
    if ($@) {
        $log->error("Failed to parse station listings response: $@");
        # Call all queued callbacks with empty result
        for my $cb (@$callbacks) {
            $cb->({}) if $cb;
        }
        delete $station_fetch_callbacks{'in_progress'};
        return;
    }
    
    # Build lookup table: siriusChannelNumber -> deeplink
    my %station_lookup = ();
    
    if ($data->{results} && ref($data->{results}) eq 'ARRAY') {
        for my $station (@{$data->{results}}) {
            my $number = $station->{number};
            my $deeplink = $station->{deeplink};
            
            if ($number && $deeplink) {
                $station_lookup{$number} = $deeplink;
                $log->debug("Station mapping: $number -> $deeplink");
            }
        }
    }
    
    # Cache the lookup table
    $cache->set('xmplaylist_stations', \%station_lookup, STATION_CACHE_TIMEOUT);
    $log->info("Cached " . scalar(keys %station_lookup) . " station mappings for 6 hours");
    
    # Call all queued callbacks
    for my $cb (@$callbacks) {
        $cb->(\%station_lookup) if $cb;
    }
    
    # Clear the in-progress flag
    delete $station_fetch_callbacks{'in_progress'};
}

# Get xmplaylist deeplink name for a given sirius channel number
sub getChannelDeeplink {
    my ($class, $sirius_number, $callback) = @_;
    
    return unless $sirius_number && $callback;
    
    $class->fetchStationListings(sub {
        my $station_lookup = shift || {};
        my $deeplink = $station_lookup->{$sirius_number};
        $callback->($deeplink);
    });
}

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

    my $selected_track = $results->[0];
    my $selected_reason = 'default latest xmplaylist record';
    my $pdt_timestamp_available = 0;
    my $next_update_delay;

    if ($channel_info && $channel_info->{id}) {
        my $channel_id = $channel_info->{id};
        unless ($channel_id =~ /^[A-Za-z0-9_-]+$/ && $channel_id !~ /\.\./) {
            $log->warn("Invalid channel id '$channel_id' for PDT lookup, falling back to channel metadata");
            $selected_reason = 'invalid siriusxm channel id';
            $channel_id = undef;
        }

        if ($channel_id) {
            my $tmp_dir = $ENV{TMPDIR} || $ENV{TEMP} || File::Spec->tmpdir() || '/tmp';
            my $pdt_file = File::Spec->catfile($tmp_dir, 'siriusxm', 'pdt_' . $channel_id . '.txt');
            $log->debug("Checking PDT file for SiriusXM channel id $channel_id: $pdt_file");
            my ($play_ts, $pdt_file_mtime) = _readPlayTimestampFromFile($pdt_file);

            if (defined $play_ts) {
                $pdt_timestamp_available = 1;
                my $matched_track;
                my $matched_ts;
                my $next_track_ts;

                for my $result (@$results) {
                    next unless $result && ref($result) eq 'HASH';

                    my $result_ts = _parseTimestampToEpoch($result->{timestamp});
                    next unless defined $result_ts;

                    if ($result_ts > $play_ts) {
                        # Track the nearest upcoming record so ProtocolHandler can
                        # schedule the next metadata refresh near the transition time.
                        $next_track_ts = $result_ts
                            if !defined $next_track_ts || $result_ts < $next_track_ts;
                        next;
                    }

                    if (!defined $matched_ts || $result_ts > $matched_ts) {
                        $matched_track = $result;
                        $matched_ts = $result_ts;
                    }
                }

                if (defined $next_track_ts) {
                    # If mtime is unavailable, treat age as 0 and use the raw
                    # timestamp delta (best-effort fallback).
                    my $pdt_age = 0;
                    if (defined $pdt_file_mtime) {
                        $pdt_age = Time::HiRes::time() - $pdt_file_mtime;
                        $pdt_age = 0 if $pdt_age < 0;
                    }

                    $next_update_delay = $next_track_ts - $play_ts - $pdt_age;
                    if ($next_update_delay < MIN_NEXT_UPDATE_DELAY_SECONDS) {
                        $next_update_delay = MIN_NEXT_UPDATE_DELAY_SECONDS;
                    }
                    $log->debug("Next xmplaylist track timestamp is in ${next_update_delay}s relative to playback (pdt age=${pdt_age}s)");
                }

                if ($matched_track) {
                    $selected_track = $matched_track;
                    $selected_reason = 'matched record at/before play timestamp';
                    $log->debug("Selected xmplaylist record timestamp " . ($selected_track->{timestamp} || 'unknown') . " for play timestamp $play_ts");
                } else {
                    $log->debug("No xmplaylist record timestamp <= play timestamp $play_ts, falling back to latest record");
                }
            } else {
                $selected_reason = 'no usable play timestamp from pdt file';
                $log->debug("No usable play timestamp from $pdt_file, falling back to channel metadata");
            }
        }
    } else {
        $selected_reason = 'missing siriusxm channel id';
        $log->debug("Missing SiriusXM channel id in channel info, falling back to channel metadata");
    }

    my $track_info = $selected_track->{track};
    my $spotify_info = $selected_track->{spotify};
    $log->debug("Metadata source selection: $selected_reason");

    # Determine whether to use xmplaylist metadata or channel metadata.
    # xmplaylist metadata is only used when we have a usable playback timestamp from the pdt file.
    my $use_xmplaylists_metadata = 0;
    my $metadata_is_fresh = 0;

    if ($prefs->get('enable_metadata') && $pdt_timestamp_available && $track_info) {
        $use_xmplaylists_metadata = 1;
        $metadata_is_fresh = 1;
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
        # Fall back to basic channel info when xmplaylist metadata is unavailable or disabled
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
            next_update_delay => $next_update_delay,
        });
    }
}

sub _readPlayTimestampFromFile {
    my ($pdt_file) = @_;

    open(my $fh, '<', $pdt_file) or do {
        if ($!{ENOENT}) {
            $log->debug("PDT file not found: $pdt_file");
        } else {
            $log->warn("Unable to read PDT file $pdt_file: $!");
        }
        return;
    };

    my $raw_ts = <$fh>;
    close($fh);

    unless (defined $raw_ts) {
        $log->debug("PDT file is empty: $pdt_file");
        return;
    }

    $raw_ts =~ s/^\s+|\s+$//g;
    unless (length $raw_ts) {
        $log->debug("PDT file contains no timestamp text: $pdt_file");
        return;
    }

    my $play_ts = _parseTimestampToEpoch($raw_ts);
    unless (defined $play_ts) {
        $log->debug("Failed to parse play timestamp '$raw_ts' from $pdt_file");
        return;
    }

    my $pdt_file_mtime;
    my @stats = stat($pdt_file);
    if (@stats) {
        $pdt_file_mtime = $stats[9];
    }

    $log->debug("Read play timestamp '$raw_ts' ($play_ts) from $pdt_file");
    return ($play_ts, $pdt_file_mtime);
}

sub _parseTimestampToEpoch {
    my ($timestamp) = @_;
    return unless defined $timestamp;

    # Handle epoch seconds (optionally fractional) before trying Date::Parse formats.
    if ($timestamp =~ /^\s*(\d+(?:\.\d+)?)\s*$/) {
        return $1 + 0;
    }

    return str2time($timestamp);
}

1;
