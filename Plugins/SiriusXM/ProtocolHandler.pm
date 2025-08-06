package Plugins::SiriusXM::ProtocolHandler;

use strict;
use warnings;

use base qw(Slim::Player::Protocols::HTTP);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Utils::Cache;
use Slim::Utils::Timers;
use Slim::Networking::SimpleAsyncHTTP;
use JSON::XS;
use Data::Dumper;

use Plugins::SiriusXM::API;

my $log = logger('plugin.siriusxm');
my $prefs = preferences('plugin.siriusxm');

# Metadata update interval (25 seconds)
use constant METADATA_UPDATE_INTERVAL => 25;

# Global hash to track player metadata timers and states
my %playerStates = ();

sub new {
    my $class = shift;
    my $args = shift;

    my $client = $args->{client};

    my $song = $args->{'song'};
    my $streamUrl = $song->streamUrl();

    $log->info( 'PH:new(): ' . $streamUrl );

    return $class->SUPER::new({
        song => $song,
        url  => $song->track()->url(),
        client => $client,
    });
}

sub canSeek { 0 }
sub canSkip { 0 }
sub isRemote { 1 }
sub canDirectStream { 0 }
sub isRepeatingStream { 0 }


# Initialize player event callbacks for metadata tracking
sub initPlayerEvents {
    my $class = shift;

    $log->debug("Registering player event callbacks for metadata tracking");
    
    # Register callbacks for player state changes
    Slim::Control::Request::subscribe(
        \&onPlayerEvent,
        [['play', 'pause', 'stop', 'playlist']]
    );
}

# Clean up player event subscriptions and timers
sub cleanupPlayerEvents {
    my $class = shift;
    
    $log->debug("Cleaning up player event callbacks and timers");
    
    # Unsubscribe from player events
    Slim::Control::Request::unsubscribe(\&onPlayerEvent);
    
    # Stop all active metadata timers
    for my $clientId (keys %playerStates) {
        if ($playerStates{$clientId}->{timer}) {
            # Find the client object to cancel timers
            my $client = Slim::Player::Client::getClient($clientId);
            if ($client) {
                Slim::Utils::Timers::killTimers($client, \&_onMetadataTimer);
            }
        }
    }
    
    # Clear all player states - Pretty sure we don't want to do this, there may be multiple players.
    #%playerStates = ();
}

# Player event callback handler
sub onPlayerEvent {
    my $request = shift;
    my $client = $request->client() || return;
    my $command = $request->getRequest(0) || return;
    
    return unless $client;
    
    my $clientId = $client->id();
    my $song = $client->playingSong();
    my $url = $song ? $song->currentTrack()->url() : '';
    
    # Only handle SiriusXM streams (both sxm: and converted HTTP URLs)
    return unless $url =~ /^sxm:/ || $url =~ m{^http://localhost:\d+/[\w-]+\.m3u8$};
    
    $log->debug("Player event '$command' for client $clientId, URL: $url");
    
    if ($command eq 'play') {
        _startMetadataTimer($client, $url);
    } elsif ($command eq 'pause' || $command eq 'stop') {
        _stopMetadataTimer($client);
    } elsif ($command eq 'playlist') {
        # Handle playlist changes - may need to start/stop timers
        my $clientId = $client->id();
        my $isPlaying = $client->isPlaying();
        my $timersRunning = exists $playerStates{$clientId} && $playerStates{$clientId}->{timer};
        
        if ($isPlaying && !$timersRunning) {
            # Start timers if playing and no timers running
            _startMetadataTimer($client, $url);
        } elsif ($isPlaying && $timersRunning) {
            # Do nothing - timers already running
        } elsif (!$isPlaying && $timersRunning) {
            # Stop timers if not playing but timers are running
            _stopMetadataTimer($client);
        }
    }
}

# Start metadata update timer for a client
sub _startMetadataTimer {
    my ($client, $url) = @_;
    
    return unless $client && $url;
    
    # Check if metadata updates are enabled
    unless ($prefs->get('enable_metadata')) {
        $log->debug("Metadata updates disabled by user preference, skipping timer setup");
        return;
    }
    
    my $clientId = $client->id();
    
    # Stop any existing timer
    _stopMetadataTimer($client);
    
    # Get channel info for xmplaylist integration
    my $channel_info = __PACKAGE__->getChannelInfoFromUrl($url);
    return unless $channel_info && $channel_info->{xmplaylist_name};
    
    $log->info("Starting metadata timer for client $clientId, channel: " . $channel_info->{name});
    
    # Initialize player state
    $playerStates{$clientId} = {
        url => $url,
        channel_info => $channel_info,
        last_next => undef,
        timer => undef,
    };
    
    # Start immediate metadata fetch
    _fetchXMPlaylistMetadata($client);
    
    # Schedule periodic updates
    $playerStates{$clientId}->{timer} = Slim::Utils::Timers::setTimer(
        $client,
        time() + METADATA_UPDATE_INTERVAL,
        \&_onMetadataTimer
    );
}

# Stop metadata update timer for a client
sub _stopMetadataTimer {
    my $client = shift;
    
    return unless $client;
    
    my $clientId = $client->id();
    
    if (exists $playerStates{$clientId}) {
        $log->debug("Stopping metadata timer for client $clientId");
        
        # Cancel timer if exists
        if ($playerStates{$clientId}->{timer}) {
            Slim::Utils::Timers::killTimers($client, \&_onMetadataTimer);
        }
        
        # Clean up state
        delete $playerStates{$clientId};
    }
}

# Timer callback for metadata updates
sub _onMetadataTimer {
    my $client = shift;
    
    return unless $client;
    
    my $clientId = $client->id();
    
    # Verify client is still playing
    my $isPlaying = $client->isPlaying();
    if (!$isPlaying) {
        $log->debug("Client $clientId no longer playing, stopping metadata timer");
        _stopMetadataTimer($client);
        return;
    }
    
    # Fetch metadata update
    _fetchXMPlaylistMetadata($client);
    
    # Let the meta data refresh one more time, to return player screens to channel artwork.
    unless ($prefs->get('enable_metadata')) {
        $log->debug("Metadata updates disabled by user preference, stopping timer");
        _stopMetadataTimer($client);
        return;
    }

    # Schedule next update if still playing
    if (exists $playerStates{$clientId}) {
        $playerStates{$clientId}->{timer} = Slim::Utils::Timers::setTimer(
            $client,
            time() + METADATA_UPDATE_INTERVAL,
            \&_onMetadataTimer
        );
    }
}

# Fetch metadata from xmplaylist.com API
sub _fetchXMPlaylistMetadata {
    my $client = shift;
    
    return unless $client;
    
    my $clientId = $client->id();
    my $state = $playerStates{$clientId};
    
    return unless $state && $state->{channel_info};
    
    my $channel_info = $state->{channel_info};
    my $xmplaylist_name = $channel_info->{xmplaylist_name};
    
    return unless $xmplaylist_name;
    
    my $url = "https://xmplaylist.com/api/station/$xmplaylist_name";
    
    $log->debug("Fetching metadata from xmplaylist.com for channel: $xmplaylist_name");
    
    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $response = shift;
            _processXMPlaylistResponse($client, $response);
        },
        sub {
            my ($http, $error) = @_;
            $log->warn("Failed to fetch metadata from xmplaylist.com: $error");
        },
        {
            timeout => 15,
        }
    );
    
    $http->get($url);
}

# Process xmplaylist.com API response
sub _processXMPlaylistResponse {
    my ($client, $response) = @_;
    
    return unless $client && $response;
    
    my $clientId = $client->id();
    my $state = $playerStates{$clientId};
    
    return unless $state;
    
    my $content = $response->content;
    my $data;
    
    eval {
        $data = decode_json($content);
    };
    
    if ($@) {
        $log->error("Failed to parse xmplaylist.com response: $@");
        return;
    }
    
    # Check if metadata has changed using "next" field
    my $next = $data->{next};
    if (defined $state->{last_next} && defined $next && $state->{last_next} eq $next) {
        $log->debug("No new metadata available (next field unchanged)");
        return;
    }
    
    # Update the last_next value
    $state->{last_next} = $next;
    
    # Build new metadata
    my $new_meta = {};
    
    if ($prefs->get('enable_metadata')) {

        # Extract track information from latest result
        my $results = $data->{results};
        return unless $results && @$results;

        my $latest_track = $results->[0];
        my $track_info = $latest_track->{track};
        my $spotify_info = $latest_track->{spotify};

        return unless $track_info;

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
        $new_meta->{album} = $state->{channel_info}->{name} || 'SiriusXM';

    } else {
        # Metadata is off, return to channel meta.
        my $state = $playerStates{$clientId};

        my $channel_info = $state->{channel_info} || '';

        if ($channel_info) {
            $log->debug(Dumper($channel_info));
            # Fall back to basic channel info when metadata is enabled
            $new_meta->{artist} = $channel_info->{name};
            $new_meta->{title} = $channel_info->{description} || $channel_info->{name};
            $new_meta->{icon} = $channel_info->{icon};
            $new_meta->{cover} = $channel_info->{icon};
            $new_meta->{album} = 'SiriusXM';
        }
    }

    # Update the current song's metadata if we have new information
    if (keys %$new_meta) {
        $log->info("Updating metadata for client $clientId: " . 
                  ($new_meta->{title} || 'Unknown') . " by " . 
                  ($new_meta->{artist} || 'Unknown Artist'));
        
        my $song = $client->playingSong();
        if ($song) {
            # Update song metadata
            $song->pluginData('xmplaylist_meta', $new_meta);
            
            # Notify clients of metadata update
            $client->currentPlaylistUpdateTime(Time::HiRes::time());
            Slim::Control::Request::notifyFromArray($client, ['playlist', 'newsong']);
        }
    }
}

# Handle sxm: protocol URLs by converting them to HTTP proxy URLs
sub getFormatForURL {
    my ($class, $url) = @_;
    
    # For sxm: URLs, we'll stream as HTTP since we convert to HTTP proxy URLs
    return 'mp3';  # Default format, actual format determined by proxy
}

sub scanUrl {
    my ($class, $url, $args) = @_;
    $args->{'cb'}->($args->{'song'}->currentTrack());
}

sub getNextTrack {
    my ($class, $song, $successCb, $errorCb) = @_;
    
    my $url = $song->currentTrack()->url;
    
    $log->debug("getNextTrack called for: $url");
    
    # Convert sxm: URL to HTTP proxy URL
    my $httpUrl = $class->sxmToHttpUrl($url);
    
    if ($httpUrl) {
        # Store channel info for metadata access only if metadata is enabled
        if ($prefs->get('enable_metadata')) {
            my $channel_info = $class->getChannelInfoFromUrl($url);
            $song->pluginData('channel_info', $channel_info) if $channel_info;
        }
        
        # Update the track URL to the HTTP proxy URL
        $song->currentTrack()->url($httpUrl);
        
        $log->debug("Converted sxm URL to HTTP URL: $httpUrl");
        
        $successCb->();
    } else {
        $errorCb->('Failed to convert sxm URL to HTTP URL');
    }
}

# Convert sxm: protocol URL to HTTP proxy URL
sub sxmToHttpUrl {
    my ($class, $url) = @_;
    
    return unless $url =~ /^sxm:/;
    
    # Extract channel ID from sxm:channelId format
    my ($channel_id) = $url =~ /^sxm:(.+)$/;
    
    return unless $channel_id;
    
    my $port = $prefs->get('port') || '9999';
    my $http_url = "http://localhost:$port/$channel_id.m3u8";
    
    $log->debug("Converted sxm:$channel_id to $http_url");
    
    return $http_url;
}

# Extract channel information from the URL for metadata access
sub getChannelInfoFromUrl {
    my ($class, $url) = @_;
    
    # Handle both sxm: URLs and converted HTTP URLs
    my $channel_id;
    
    if ($url =~ /^sxm:(.+)$/) {
        $channel_id = $1;
    } elsif ($url =~ m{^http://localhost:\d+/([\w-]+)\.m3u8$}) {
        $channel_id = $1;
    } else {
        return;
    }
    
    # Use the API's cached channel info (processed data, not menu data)
    my $cache = Slim::Utils::Cache->new();
    my $cached_channel_info = $cache->get('siriusxm_channel_info');
    
    if ($cached_channel_info) {
        # Search through cached channel info data (categories hash from processChannelData)
        for my $category_name (keys %$cached_channel_info) {
            my $channels_in_category = $cached_channel_info->{$category_name};
            
            for my $channel (@$channels_in_category) {
                # Check if this channel matches our channel ID
                if ($channel->{id} && $channel->{id} eq $channel_id) {
                    # Return the processed channel info with correct normalized name
                    return {
                        id => $channel->{id},
                        name => $channel->{name},
                        xmplaylist_name => $channel->{xmplaylist_name},
                        description => $channel->{description},
                        channel_number => $channel->{number},
                        icon => $channel->{icon},
                        category => $channel->{category},
                    };
                }
            }
        }
    } else {
        # No cache available - trigger async API call to populate cache
        # But don't wait for it, just return fallback for now
        Plugins::SiriusXM::API->getChannels(undef, sub {
            # Cache will be populated for next time
        });
    }
    
    # Fallback channel info if not found in cache    ----   May only get here if restarting from playlist.  BUt should not need this.
#    return {
#        id => $channel_id,
#        name => "SiriusXM Channel",
#        xmplaylist_name => undef,
#        description => "SiriusXM Channel $channel_id",
#    };
    return;
}

# Normalize channel name for xmplaylist.com API (same logic as API.pm)
sub _normalizeChannelName {
    my $channel_name = shift;

    return '' unless $channel_name;

    # Convert to lowercase and remove spaces, underscores, and special characters
    my $normalized = lc($channel_name);
    $normalized =~ s/[^a-z0-9]//g;

    return $normalized;
}

# Provide metadata for the stream
sub getMetadataFor {
    my ($class, $client, $url, $forceCurrent) = @_;
    
    my $song = $client->streamingSong() || $client->playingSong();
    my $channel_info;

    if ($song) {
        $channel_info = $song->pluginData('channel_info');
    }

    my $xmplaylist_meta;
    
    # Only use external metadata sources if metadata is enabled
    if ($prefs->get('enable_metadata') && $song) {
        $xmplaylist_meta = $song->pluginData('xmplaylist_meta');
    }

    # If no channel info in song data, try to extract from URL
    if (!$channel_info) {
        $channel_info = $class->getChannelInfoFromUrl($url);
    }
    
    my $meta = $class->SUPER::getMetadataFor($client, $url, $forceCurrent) || {};
    
    # Use xmplaylist metadata if available and metadata is enabled, otherwise fall back to basic info
    if ($prefs->get('enable_metadata') && $xmplaylist_meta && keys %$xmplaylist_meta) {
        # Use enhanced metadata from xmplaylist.com
        $meta->{title} = $xmplaylist_meta->{title} if $xmplaylist_meta->{title};
        $meta->{artist} = $xmplaylist_meta->{artist} if $xmplaylist_meta->{artist};
        $meta->{cover} = $xmplaylist_meta->{cover} if $xmplaylist_meta->{cover};
        $meta->{icon} = $xmplaylist_meta->{icon} if $xmplaylist_meta->{icon};
        $meta->{album} = $xmplaylist_meta->{album} if $xmplaylist_meta->{album};
        
#       Really noisy log message when using a LMS web.
#        $log->debug("Using xmplaylist metadata: " . ($meta->{title} || 'Unknown') . 
#                  " by " . ($meta->{artist} || 'Unknown Artist'));
    } elsif ($channel_info) {
        # Fall back to basic channel info when metadata is enabled
        $meta->{artist} = $channel_info->{name};
        $meta->{title} = $channel_info->{description} || $channel_info->{name};
        $meta->{icon} = $channel_info->{icon};
        $meta->{cover} = $channel_info->{icon};
        $meta->{album} = 'SiriusXM';
    }

    $meta->{channel_info} = $channel_info if $channel_info;

    return $meta;
}

# Handle HTTPS support
sub requestString {
    my ($class, $client, $url, $maxRedirects) = @_;
    
    # Convert sxm: to HTTP URL first
    my $httpUrl = $class->sxmToHttpUrl($url);
    
    if ($httpUrl) {
        return $class->SUPER::requestString($client, $httpUrl, $maxRedirects);
    }
    
    return $class->SUPER::requestString($client, $url, $maxRedirects);
}

1;
