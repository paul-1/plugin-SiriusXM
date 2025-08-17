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
use Date::Parse;
use Time::HiRes;

use Plugins::SiriusXM::API;
use Plugins::SiriusXM::APImetadata;
use Plugins::SiriusXM::TrackDurationDB;

my $log = logger('plugin.siriusxm');
my $prefs = preferences('plugin.siriusxm');

# Metadata update intervals
use constant METADATA_UPDATE_INTERVAL => 25;      # Default interval when no track timing

# Global hash to track player metadata timers and states
my %playerStates = ();

sub new {
    my $class = shift;
    my $args = shift;

    my $client = $args->{client};

    my $song = $args->{'song'};
    my $streamUrl = $song->streamUrl() || return;

    main::DEBUGLOG && $log->debug( 'PH:new(): ' . $song->track()->url() );

    return $class->SUPER::new({
        song => $song,
        url  => $streamUrl,
        client => $client,
    });
}

sub canSeek { 0 }
sub canSkip { 0 }
sub isRemote { 1 }
sub canDirectStream { 0 }
sub isRepeatingStream { 0 }

sub canDoAction {
    my ( $class, $client, $url, $action ) = @_;

    # "stop" seems to be called when a user pressed FWD...
	 if ( $action eq 'stop' ) {
        return 0;
    }
    elsif ( $action eq 'rew' ) {
        return 0;
    }

    return 1;
}

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

    # Initialize Player Metatadata
    my $state = $playerStates{$clientId};
    if (!$state) {
        $log->debug("No current player state, configuring");
        my $channel_info = __PACKAGE__->getChannelInfoFromUrl($url);
        # Initialize player state
        $playerStates{$clientId} = {
            url => $url,
            channel_info => $channel_info,
            last_next => undef,
            timer => undef,
        };
        _fetchMetadataFromAPI($client);
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
    _fetchMetadataFromAPI($client);
    
    # Schedule periodic updates with dynamic interval
    my $initialInterval = __PACKAGE__->_calculateNextUpdateInterval($client);
    $playerStates{$clientId}->{timer} = Slim::Utils::Timers::setTimer(
        $client,
        time() + $initialInterval,
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
    _fetchMetadataFromAPI($client);
    
    # Let the meta data refresh one more time, to return player screens to channel artwork.
    unless ($prefs->get('enable_metadata')) {
        $log->debug("Metadata updates disabled by user preference, stopping timer");
        _stopMetadataTimer($client);
        return;
    }

    # Schedule next update if still playing with dynamic interval
    if (exists $playerStates{$clientId}) {
        my $nextInterval = __PACKAGE__->_calculateNextUpdateInterval($client);
        $playerStates{$clientId}->{timer} = Slim::Utils::Timers::setTimer(
            $client,
            time() + $nextInterval,
            \&_onMetadataTimer
        );
        $log->debug("Scheduled next metadata update in ${nextInterval}s for client $clientId");
    }
}

# Fetch metadata from xmplaylist.com API using APImetadata module
sub _fetchMetadataFromAPI {
    my $client = shift;
    
    return unless $client;
    
    my $clientId = $client->id();
    my $state = $playerStates{$clientId};
    
    return unless $state && $state->{channel_info};
    
    my $channel_info = $state->{channel_info};
    
    Plugins::SiriusXM::APImetadata->fetchMetadata($client, $channel_info, sub {
        my $result = shift;
        return unless $result;
        
        _updateClientMetadata($client, $result);
    });
}

# Update client with new metadata
sub _updateClientMetadata {
    my ($client, $result) = @_;
    
    return unless $client && $result;
    
    my $clientId = $client->id();
    my $state = $playerStates{$clientId};
    
    return unless $state;
    
    my $new_meta = $result->{metadata};
    my $next = $result->{next};
    my $metadata_is_fresh = $result->{is_fresh};
    
    # Check if we should show channel metadata instead of track metadata
    if (!$new_meta || !keys %$new_meta) {
        $log->debug("No track metadata available, showing channel info for client $clientId");
        
        # Use channel info as metadata
        if ($state->{channel_info}) {
            my $channel_meta = {
                artist => $state->{channel_info}->{name},
                title => $state->{channel_info}->{description} || $state->{channel_info}->{name},
                cover => $state->{channel_info}->{icon},
                icon => $state->{channel_info}->{icon},
                album => 'SiriusXM',
                bitrate => '',
            };
            
            my $song = $client->playingSong();
            if ($song) {
                $song->pluginData('xmplaylist_meta', $channel_meta);
                $client->currentPlaylistUpdateTime(Time::HiRes::time());
                Slim::Control::Request::notifyFromArray($client, ['playlist', 'newsong']);
            }
        }
        return;
    }
    
    # Check if metadata has changed using "next" field
    if (defined $state->{last_next} && defined $next && $state->{last_next} eq $next) {
        # Only skip update if metadata is fresh - if stale, we need to update display
        if ($metadata_is_fresh) {
            $log->debug("No new metadata available and current metadata is fresh - skipping update");
            return;
        } else {
            $log->debug("Metadata unchanged but stale - updating display to show channel info");
        }
    }
    
    # Update the last_next value
    $state->{last_next} = $next;
    
    # Update the current song's metadata if we have new information
    if ($new_meta && keys %$new_meta) {
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
    
    my $client = $song->master();
    my $url = $song->currentTrack()->url;
    
    my $clientId = $client->id();
    if ($clientId) {
        $log->debug("getNextTrack called for: $clientId -> $url");
        # Clear player state for different channels to ensure fresh state
        $class->_clearPlayerStatesForDifferentChannel($client, $url);
    }

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
    
    # Use the consolidated channel ID extraction function
    my $channel_id = $class->_extractChannelIdFromUrl($url);
    return unless $channel_id;
    
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
    return {
        id => $channel_id,
        name => "SiriusXM Channel",
        xmplaylist_name => undef,
        description => "SiriusXM Channel $channel_id",
    };
}



# Provide metadata for the stream
sub getMetadataFor {
    my ($class, $client, $url, undef, $song) = @_;
    
    my $song ||= $client->playingSong();
    return {} unless $song;

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

#    my $meta = $class->SUPER::getMetadataFor($client, $url, $forceCurrent) || {};
    my $meta;    

    # Use xmplaylist metadata if available and metadata is enabled, otherwise fall back to basic info
    if ($prefs->get('enable_metadata') && $xmplaylist_meta && keys %$xmplaylist_meta) {
        # Use enhanced metadata from xmplaylist.com
        $meta->{title} = $xmplaylist_meta->{title} if $xmplaylist_meta->{title};
        $meta->{artist} = $xmplaylist_meta->{artist} if $xmplaylist_meta->{artist};
        $meta->{cover} = $xmplaylist_meta->{cover} if $xmplaylist_meta->{cover};
        $meta->{icon} = $xmplaylist_meta->{icon} if $xmplaylist_meta->{icon};
        $meta->{album} = $xmplaylist_meta->{album} if $xmplaylist_meta->{album};
        $meta->{bitrate} = '';
        
        # Add duration if available
        if (defined $xmplaylist_meta->{duration}) {
            $meta->{duration} = $xmplaylist_meta->{duration};
            $meta->{secs} = $xmplaylist_meta->{duration};
            
            # Set track duration for LMS
            Slim::Music::Info::setDuration($song->track, $meta->{duration}) if $song;
        }
        
        # Store track timing info for metadata refresh calculations only
        if ($xmplaylist_meta->{track_timestamp}) {
            # Store track start time info in block data for timer calculations
            my $blockData = __PACKAGE__->getBlockData($song) || {};
            
            # Parse timestamp and set start time
            eval {
                my $track_start_time = str2time($xmplaylist_meta->{track_timestamp});
                if (defined $track_start_time) {
                    $blockData->{track_start_time} = $track_start_time;
                    $blockData->{xmplaylist_id} = $xmplaylist_meta->{xmplaylist_id} if $xmplaylist_meta->{xmplaylist_id};
                    
                    __PACKAGE__->setBlockData($song, $blockData);
                }
            };
            
            if ($@) {
                $log->warn("Failed to parse track timestamp: $@");
            }
        }
        
        #       Really noisy log message when using a LMS web.
        #        $log->debug("Using xmplaylist metadata: " . ($meta->{title} || 'Unknown') . 
        #                  " by " . ($meta->{artist} || 'Unknown Artist'));
    } elsif ($channel_info) {
        # Fall back to basic channel info when metadata is enabled
        $meta->{artist} = $channel_info->{name};
        $meta->{title} = $channel_info->{description} || '';
        $meta->{icon} = $channel_info->{icon};
        $meta->{cover} = $channel_info->{icon};
        $meta->{album} = 'SiriusXM';
        $meta->{bitrate} = '';
    }

#    $meta->{channel_info} = $channel_info if $channel_info;
#    $log->debug(Dumper($meta));
    return $meta;
}

# Clear player states for channels different from the specified URL
sub _clearPlayerStatesForDifferentChannel {
    my ($class, $client, $newUrl) = @_;
    my $clientId = $client->id();

    return unless $client, $newUrl, $clientId;

    # Extract channel ID from the new URL
    my $newChannelId = $class->_extractChannelIdFromUrl($newUrl);
    return unless $newChannelId;

    $log->debug("Checking player state for $clientId different channels than: $newChannelId");

    # Check existing player state.
    my $state = $playerStates{$clientId};
    return unless $state && $state->{url};
    # Extract channel ID from existing state URL
    my $existingChannelId = $class->_extractChannelIdFromUrl($state->{url});
    return unless $existingChannelId;

    # If the channel ID is different, clear this player state
    if ($existingChannelId ne $newChannelId) {
        $log->debug("Clearing player state for client $clientId (old channel: $existingChannelId, new channel: $newChannelId)");

        # Find the client object to cancel timers properly
        my $client = Slim::Player::Client::getClient($clientId);
        if ($client && $state->{timer}) {
           Slim::Utils::Timers::killTimers($client, \&_onMetadataTimer);
        }

        # Remove the player state
        delete $playerStates{$clientId};
    }
}

# Extract channel ID from URL (supports both sxm: and HTTP URLs)
sub _extractChannelIdFromUrl {
    my ($class, $url) = @_;

    return unless $url;

    # Handle sxm: URLs
    if ($url =~ /^sxm:(.+)$/) {
        return $1;
    }

    # Handle converted HTTP URLs
    if ($url =~ m{^http://localhost:\d+/([\w-]+)\.m3u8$}) {
        return $1;
    }

    return;
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

# Block data management (following RadioParadise pattern)
sub getBlockData {
    my ($class, $song) = @_;
    return unless $song;
    
    my $url = $song->streamUrl() || return;
    return $playerStates{_cleanupBlockURL($url)};
}

sub setBlockData {
    my ($class, $song, $data) = @_;
    return unless $song && $data;
    
    my $url = $song->streamUrl() || return;
    $playerStates{_cleanupBlockURL($url)} = $data;
}

sub _cleanupBlockURL {
    my $url = shift || '';
    $url =~ s/\?.*//;
    return $url;
}

# Calculate elapsed time for a track based on its start timestamp
sub _calculateTrackElapsed {
    my ($class, $timestamp) = @_;
    
    return unless $timestamp;
    
    eval {
        # Parse the UTC timestamp format: 2025-08-09T15:57:41.586Z
        my $track_start_time = str2time($timestamp);
        return unless defined $track_start_time;
        
        my $current_time = time();
        my $elapsed = $current_time - $track_start_time;
        
        # Only return positive elapsed times (track has started)
        return $elapsed >= 0 ? $elapsed : 0;
    };
    
    if ($@) {
        $log->warn("Failed to calculate track elapsed time from timestamp '$timestamp': $@");
    }
    
    return;
}

# Calculate next update interval based on track timing
# Formula: MusicBrainz Duration - Current Time - xmplaylist Start time - 30 or 15s whichever is greater
sub _calculateNextUpdateInterval {
    my ($class, $client) = @_;
    
    return METADATA_UPDATE_INTERVAL unless $client;
    
    # Get the current song and its metadata
    my $song = $client->playingSong();
    return METADATA_UPDATE_INTERVAL unless $song;
    
    my $xmplaylist_meta = $song->pluginData('xmplaylist_meta');
    return METADATA_UPDATE_INTERVAL unless $xmplaylist_meta;
    
    # Get block data to check track timing
    my $blockData = __PACKAGE__->getBlockData($song);
    return METADATA_UPDATE_INTERVAL unless $blockData && $blockData->{track_start_time};
    
    # Get track duration if available
    my $duration = $xmplaylist_meta->{duration};
    return METADATA_UPDATE_INTERVAL unless defined $duration && $duration > 0;
    
    # Calculate using formula: Duration - (Current Time - Start Time) - 30
    my $current_time = time();
    my $elapsed = $current_time - $blockData->{track_start_time};
    my $remaining = $duration - $elapsed;
    my $nextInterval = $remaining - 30;
    
    # Use 15s as minimum interval
    if ($nextInterval < 15) {
        $nextInterval = 15;
    }
    
    $log->debug("Timer calculation: duration=${duration}s, elapsed=${elapsed}s, remaining=${remaining}s, interval=${nextInterval}s");
    
    return $nextInterval;
}

1;
