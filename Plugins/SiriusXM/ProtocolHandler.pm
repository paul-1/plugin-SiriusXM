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
use Slim::Player::Playlist;
use Scalar::Util qw(refaddr);
use Time::HiRes qw(time);
use JSON::XS;
use Data::Dumper;
use Date::Parse;

use Plugins::SiriusXM::API;
use Plugins::SiriusXM::APImetadata;

my $log = logger('plugin.siriusxm');
my $prefs = preferences('plugin.siriusxm');
my $json_encoder = JSON::XS->new->canonical(1);

# Metadata update interval (25 seconds)
use constant METADATA_UPDATE_INTERVAL => 25;

# Global hash to track player metadata timers and states
my %playerStates = ();

# Global hash to track metadata by channel ID
my %channelMetadata = ();
my $lastChannelInfoFetch = 0;

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

    $log->debug("canDoAction action=$action url=$url");

    # SXM live streams can't be restarted or rewound, but must not block
    # skipping to another track.
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
    
    # Clear channel metadata cache
    %channelMetadata = ();
}

#Call this in init if there is bad data in the database (Not currently called)
sub purgeTrackCache {
    my $class = shift;
    my $port  = $prefs->get('port') || '9999';
    my $dbh   = Slim::Schema->dbh;

    my $rows = $dbh->do(
        "DELETE FROM tracks WHERE url LIKE 'sxm:%' OR url LIKE ?",
        undef, "http://localhost:$port/%.m3u8"
    );
    $log->info("Purged " . ($rows + 0) . " SXM track row(s) from library.db");
}

sub _syncMasterClient {
    my ($client) = @_;
    return unless $client;

    my $master = eval { $client->master };
    return ($master && $master->id) ? $master : $client;
}

# Log the full playlist for a client (index, url, title)
sub _logPlaylist {
    my ($client, $label) = @_;
    return unless $client && main::DEBUGLOG && $log->is_debug;

    my $count = Slim::Player::Playlist::count($client) || 0;
    my @lines;
    for my $i (0 .. $count - 1) {
        my $t = Slim::Player::Playlist::track($client, $i);
        my $u = $t ? $t->url : 'undef';
        my $title = ($t && $t->can('title')) ? ($t->title // '') : '';
        push @lines, sprintf("  [%d] %s %s", $i, $u, $title ? "($title)" : '');
    }
    $log->debug("$label: playlist for " . $client->id . " has $count item(s):\n" . join("\n", @lines));
}

# Player event callback handler
sub onPlayerEvent {
    my $request = shift;
    my $client = $request->client() || return;

    my $realClient = _syncMasterClient($client);
    # If this event came from a slave, ignore it (the master will also get one)
    return if $realClient->id ne $client->id;

    my $command = $request->getRequest(0) || return;
    my $subcommand = $request->getRequest(1) || '';
    
    # Print the current playlist content.
    if ($command eq 'playlist') {
        # Log what was added/loaded, independent of whether SXM is currently playing
        my $params = $request->getParamsCopy() || {};
        $log->debug("playlist event sub='$subcommand' client=" . $realClient->id
            . " params=" . join(', ', map { "$_=" . (defined $params->{$_} ? $params->{$_} : 'undef') } sort keys %$params));

        if ($subcommand =~ /^(?:add|addtracks|insert|insertlist|load|loadtracks)$/) {
            $log->info("Playlist add/load: "
                . ($params->{_item} // $params->{_path} // $params->{_what} // 'see params above'));
        }

        if ($subcommand eq 'load_done') {
            _logPlaylist($realClient, 'load_done');
        }
        elsif ($subcommand =~ /^(?:add|addtracks|delete|move|clear)$/) {
            # Playlist may not be fully populated yet, so defer slightly
            Slim::Utils::Timers::setTimer($realClient, time() + 0.5, sub {
                _logPlaylist(shift, "after $subcommand");
            });
        }
    }

    my $clientId = $realClient->id();
    my $song = $realClient->playingSong();
    my $url = $song ? $song->currentTrack()->url() : '';
    my $port = $prefs->get('port');

    my $is_sxm = ($url =~ /^sxm:/ || $url =~ m{^http://localhost:$port\b/[\w-]+\.m3u8$}) ? 1 : 0;

    # If we've moved off SXM, stop SXM metadata/timer state for this client.
    if (!$is_sxm) {
        _stopMetadataTimer($realClient) if exists $playerStates{$clientId};
        return;
    }

    $log->debug("Player event '$command:$subcommand' for client $clientId, URL:$url" );

    # Only handle SiriusXM streams (both sxm: and converted HTTP URLs)
    return unless $url =~ /^sxm:/ || $url =~ m{^http://localhost:$port\b/[\w-]+\.m3u8$};

    $log->debug("Player event '$command:$subcommand' for client $clientId, URL:$url" );
#    $log->debug(Dumper($request));
    
    if ($command eq 'playlist' && $subcommand eq 'jump') {
        my $jump_index = $request->getParam('_index');
        $jump_index = '' unless defined $jump_index;

        my $count = Slim::Player::Playlist::count($realClient);
        my $idx   = Slim::Player::Source::streamingSongIndex($realClient);
        my @urls  = map {
            my $t = Slim::Player::Playlist::track($realClient, $_);
            "$_=" . ($t ? $t->url : 'undef');
        } (0 .. $count - 1);
        $log->debug("playlist:jump count=$count idx=$idx tracks: " . join(', ', @urls));

        my $playing   = Slim::Player::Source::playingSongIndex($realClient);
        my $streaming = Slim::Player::Source::streamingSongIndex($realClient);
        $log->debug("playlist:jump index='$jump_index' playingIdx=$playing streamingIdx=$streaming");

        Slim::Utils::Timers::setTimer($realClient, time() + 0.5, sub {
            my $c = shift || return;
            my $idx   = Slim::Player::Source::streamingSongIndex($c);
            my $track = Slim::Player::Playlist::track($c, $idx);
            my $url   = $track ? $track->url : '';
            my $port  = $prefs->get('port');
            my $is_sxm = ($url =~ /^sxm:/ || $url =~ m{^http://localhost:$port\b/[\w-]+\.m3u8$}) ? 1 : 0;

            $log->debug("post-jump streamingIdx=$idx url=$url is_sxm=$is_sxm");

            if ($is_sxm && $c->isPlaying()) {
                _startMetadataTimer($c, $url);
            } else {
                _stopMetadataTimer($c);
            }
        });
        return;
    }


    if ($song) {
        my $handler = $song->currentTrackHandler();
        if ($handler ne qw(Plugins::SiriusXM::ProtocolHandler) ) {
            if ( $url =~ m{^http://localhost:$port\b/([\w-]+)\.m3u8$} ) {
                $log->debug("Current Track Handler: $handler overriding to SXM");
                my $newurl = "sxm:" . $1;
                $song->currentTrack()->url($newurl);
                $song->_currentTrackHandler(Slim::Player::ProtocolHandlers->handlerForURL( $newurl ));
            }
        }
    }
    if ($command eq 'play') {
        _startMetadataTimer($realClient, $url);
    } elsif ($command eq 'pause' || $command eq 'stop') {
        _stopMetadataTimer($realClient);
    } elsif ($command eq 'playlist') {
        # Handle playlist changes - may need to start/stop timers
        my $clientId = $realClient->id();
        my $isPlaying = $realClient->isPlaying();
        my $timersRunning = exists $playerStates{$clientId} && $playerStates{$clientId}->{timer};
        
        if ($isPlaying && !$timersRunning) {
            # Start timers if playing and no timers running
            _startMetadataTimer($realClient, $url);
        } elsif ($isPlaying && $timersRunning) {
            # Do nothing - timers already running
        } elsif (!$isPlaying && $timersRunning) {
            # Stop timers if not playing but timers are running
            _stopMetadataTimer($realClient);
        }
    }

    # Initialize player metadata
    my $state = $playerStates{$clientId};
    if (!$state) {
        unless ($realClient->isPlaying()) {
            $log->debug("Client $clientId is not playing, skipping metadata state initialization");
            return;
        }

        $log->debug("No current player state, configuring");
        my $channel_info = __PACKAGE__->getChannelInfoFromUrl($url, $realClient);
        # Initialize player state
        $playerStates{$clientId} = {
            url => $url,
            channel_info => $channel_info,
            last_metadata_signature => undef,
            metadata_request_token => undef,
            metadata_request_seq => 0,
            pending_metadata_result => undef,
            timer => undef,
        };
        _fetchMetadataFromAPI($realClient);
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
    my $channel_info = __PACKAGE__->getChannelInfoFromUrl($url, $client);
    return unless $channel_info && $channel_info->{xmplaylist_name};
    
    $log->info("Starting metadata timer for client $clientId, channel: " . $channel_info->{name});
    
    # Initialize player state
    $playerStates{$clientId} = {
        url => $url,
        channel_info => $channel_info,
        last_metadata_signature => undef,
        metadata_request_token => undef,
        metadata_request_seq => 0,
        pending_metadata_result => undef,
        timer => undef,
    };
    
    # Start immediate metadata fetch
    _fetchMetadataFromAPI($client);
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
        
        my $chan = __PACKAGE__->_extractChannelIdFromUrl($playerStates{$clientId}->{url});
        __PACKAGE__->_resetChannelMetadata($chan, $client);

        # Clean up state
        delete $playerStates{$clientId};
    }
}

# Timer callback for metadata updates
sub _onMetadataTimer {
    my $client = shift;
    
    return unless $client;

    my $realClient = _syncMasterClient($client);
    return if $realClient->id ne $client->id;  # timer should only run on master
    
    my $clientId = $client->id();
    my $state = $playerStates{$clientId};

    unless ($state) {
        $log->debug("No metadata state for client $clientId, stopping timer");
        _stopMetadataTimer($client);
        return;
    }
    
    # Verify client is still playing
    my $isPlaying = $client->isPlaying();
    if (!$isPlaying) {
        $log->debug("Client $clientId no longer playing, stopping metadata timer");
        _stopMetadataTimer($client);
        return;
    }

    unless ($prefs->get('enable_metadata')) {
        $log->debug("Metadata updates disabled by user preference, stopping timer");
        _stopMetadataTimer($client);
        return;
    }

    if ($state && $state->{pending_metadata_result}) {
        my $pending_result = delete $state->{pending_metadata_result};
        $log->debug("Applying cached next-track metadata for client $clientId");
        _updateClientMetadata($client, $pending_result);

        _scheduleNextMetadataUpdate($client, METADATA_UPDATE_INTERVAL);
        return;
    }
    
    # Fetch metadata update
    _fetchMetadataFromAPI($client);
    
    # Let the meta data refresh one more time, to return player screens to channel artwork.
}

# Fetch metadata from xmplaylist.com API using APImetadata module
sub _fetchMetadataFromAPI {
    my $client = shift;
    
    return unless $client;
    
    my $realClient = _syncMasterClient($client);
    return if $realClient->id ne $client->id;  # timer should only run on master
    
    my $clientId = $client->id();
    my $state = $playerStates{$clientId};
    
    return unless $state && $state->{channel_info};
    
    my $channel_info = $state->{channel_info};
    my $request_seq = ++$state->{metadata_request_seq};
    my $request_token = join(':', $clientId, refaddr($state), $request_seq, time());
    my $request_channel_id = $channel_info->{id};
    $state->{metadata_request_token} = $request_token;
    
    Plugins::SiriusXM::APImetadata->fetchMetadata($client, $channel_info, sub {
        my $result = shift;
        my $next_delay = METADATA_UPDATE_INTERVAL;
        my $current_state = $playerStates{$clientId};

        unless ($current_state) {
            $log->debug("Ignoring async metadata response for client $clientId: no active player state");
            return;
        }

        my $current_request_token = $current_state->{metadata_request_token};
        if (!defined $current_request_token) {
            $log->debug("Ignoring stale async metadata response for client $clientId: missing request token");
            return;
        }

        if ($current_request_token ne $request_token) {
            $log->debug("Ignoring stale async metadata response for client $clientId token $request_token");
            return;
        }

        unless ($client->isPlaying()) {
            $log->debug("Ignoring async metadata response for client $clientId: client no longer playing");
            _stopMetadataTimer($client);
            return;
        }

        my $current_channel_id = $current_state->{channel_info}
            ? $current_state->{channel_info}->{id}
            : undef;
        if (
            defined $request_channel_id && defined $current_channel_id
            && $request_channel_id ne $current_channel_id
        ) {
            $log->debug("Ignoring stale async metadata response for client $clientId channel $request_channel_id");
            return;
        }

        if ($result) {
            _updateClientMetadata($client, $result);
            delete $current_state->{pending_metadata_result};

            if (
                _isValidDelay($result->{next_update_delay})
                && $result->{next_metadata}
            ) {
                $next_delay = $result->{next_update_delay};
                $current_state->{pending_metadata_result} = {
                    metadata => $result->{next_metadata},
                    is_fresh => 1,
                };
            }
        }

        unless ($prefs->get('enable_metadata')) {
            _stopMetadataTimer($client);
            return;
        }

        _scheduleNextMetadataUpdate($client, $next_delay);
    });
}

sub _scheduleNextMetadataUpdate {
    my ($client, $delay) = @_;
    return unless $client;

    my $clientId = $client->id();
    return unless exists $playerStates{$clientId};

    $delay = METADATA_UPDATE_INTERVAL unless _isValidDelay($delay);
    $log->debug("Scheduling next metadata update for client $clientId in ${delay}s");

    if ($playerStates{$clientId}->{timer}) {
        Slim::Utils::Timers::killTimers($client, \&_onMetadataTimer);
    }

    $playerStates{$clientId}->{timer} = Slim::Utils::Timers::setTimer(
        $client,
        time() + $delay,
        \&_onMetadataTimer
    );
}

# Update client with new metadata
sub _updateClientMetadata {
    my ($client, $result) = @_;
    
    return unless $client && $result;
    
    my $clientId = $client->id();
    my $state = $playerStates{$clientId};
    
    return unless $state;

    my $new_meta = $result->{metadata};
    my $metadata_is_fresh = $result->{is_fresh};
    my $metadata_signature = _metadataSignature($new_meta, "client $clientId");
    
    # Check if metadata content has changed.
    # Using metadata signature avoids lag when xmplaylist's "next" token
    # stays constant while the selected record for play-behind-live changes.
    if (
        defined $state->{last_metadata_signature}
        && defined $metadata_signature
        && $state->{last_metadata_signature} eq $metadata_signature
    ) {
        # Only skip update if metadata is fresh - if stale, we need to update display
        if ($metadata_is_fresh) {
            $log->debug("No new metadata available and current metadata is fresh - skipping update");
            return;
        } else {
            $log->debug("Metadata unchanged but stale - updating display to show channel info");
        }
    }
    
    $state->{last_metadata_signature} = $metadata_signature;
    
    # Update the current song's metadata if we have new information
    if ($new_meta && keys %$new_meta) {
        $log->info("Updating metadata for client $clientId: " . 
                  ($new_meta->{title} || 'Unknown') . " by " . 
                  ($new_meta->{artist} || 'Unknown Artist'));
        
        my $song = $client->playingSong();

        if ($song) {
            # Extract channel ID from current playing URL
            my $currentUrl = $song->currentTrack()->url();
            my $channel_id = __PACKAGE__->_extractChannelIdFromUrl($currentUrl);
            
            if ($channel_id) {
                # Store metadata in global channel cache (primary storage)
                $channelMetadata{$channel_id} = $new_meta;
                $log->debug("Stored metadata for channel $channel_id in global cache");
            }
            
            # Update song metadata for backward compatibility
            $song->pluginData('xmplaylist_meta', $new_meta);
            
            # Notify clients of metadata update
            $client->currentPlaylistUpdateTime(Time::HiRes::time());
            Slim::Control::Request::notifyFromArray($client, ['playlist', 'newsong']);
        }
    } else {
        my $song = $client->playingSong();
        my $channel_id = $song ? __PACKAGE__->_extractChannelIdFromUrl($song->currentTrack()->url()) : undef;
        if ($channel_id) {
            __PACKAGE__->_resetChannelMetadata($channel_id, $client);
            $client->currentPlaylistUpdateTime(Time::HiRes::time());
            Slim::Control::Request::notifyFromArray($client, ['playlist', 'newsong']);
        }
    }
}

sub _metadataSignature {
    my ($meta, $context) = @_;
    return unless $meta && ref($meta) eq 'HASH';
    $context ||= 'unknown context';

    my $signature;
    eval {
        $signature = $json_encoder->encode($meta);
    };
    if ($@) {
        $log->warn("Failed to encode metadata signature for $context: $@");
        return;
    }

    return $signature;
}

sub _isValidDelay {
    my ($delay) = @_;
    return defined $delay && $delay =~ /^\d+(?:\.\d+)?$/ && $delay > 0;
}

# Handle sxm: protocol URLs by converting them to HTTP proxy URLs
sub getFormatForURL {
    my ($class, $url) = @_;
    
    # For sxm: URLs, we'll stream as HTTP since we convert to HTTP proxy URLs
    return 'm3u8';  # Default format, actual format determined by proxy
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

        Slim::Player::Playlist::refreshPlaylist($client);
    
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
    my ($class, $url, $client) = @_;
    
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
        # Throttled so a failing proxy cannot cause repeated fetches
        my $now = time();
        if ($now - $lastChannelInfoFetch >= 30) {
            $lastChannelInfoFetch = $now;
            my $clientId = $client ? $client->id() : undef;
            Plugins::SiriusXM::API->getChannels(undef, sub {
                # Refresh the display once, and only if the channel data is now cached,
                # otherwise the refresh would trigger another fetch.
                return unless $clientId && $cache->get('siriusxm_channel_info');
                my $c = Slim::Player::Client::getClient($clientId) || return;
                $c->currentPlaylistUpdateTime(Time::HiRes::time());
                Slim::Control::Request::notifyFromArray($c, ['playlist', 'newsong']);
            });
        }
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
#    $log->debug("getMetadataFor ENTER url=" . ($url // 'undef') . " song=" . ($song ? 'y' : 'n'));
    $song ||= $client ? $client->playingSong() : undef;

    my $channel_id = $class->_extractChannelIdFromUrl($url);
    return {} unless $channel_id;

    my $channel_info = $class->getChannelInfoFromUrl($url, $client);
    return {} unless $channel_info;

    my $currentSong = $client ? $client->playingSong() : undef;

    # Check if this URL/channel is currently being played by this client
    my $isCurrentTrack = 0;
    
    if ($currentSong) {
        my $currentUrl = $currentSong->currentTrack()->url();
        my $currentChannelId = $class->_extractChannelIdFromUrl($currentUrl);
        $isCurrentTrack = ($currentChannelId && $currentChannelId eq $channel_id);
    }

    # Default to SXM channel info/artwork
    my $meta = {
        artist  => $channel_info->{name},
        title   => $channel_info->{description} || '',
        icon    => $channel_info->{icon},
        cover   => $channel_info->{icon},
        album   => 'SiriusXM',
        bitrate => '',
    };

    # Only overlay external metadata (xmplaylist) for the currently playing track
    if ($isCurrentTrack && $prefs->get('enable_metadata')) {
        my $cached_meta = $channelMetadata{$channel_id};

        if (!$cached_meta || !keys %$cached_meta) {
            $cached_meta = $song && $song->pluginData('xmplaylist_meta');
        }

        if ($cached_meta && keys %$cached_meta) {
            $meta->{title}  = $cached_meta->{title}  if $cached_meta->{title};
            $meta->{artist} = $cached_meta->{artist} if $cached_meta->{artist};
            $meta->{album}  = $cached_meta->{album}  if $cached_meta->{album};
            # Track artwork overrides channel artwork only when present
            if ($cached_meta->{cover}) {
                $meta->{cover} = $cached_meta->{cover};
                $meta->{icon}  = $cached_meta->{icon} || $cached_meta->{cover};
            }
        }
    }

    return $meta;
}

# Reset cached metadata so the default channel name/artwork is shown
sub _resetChannelMetadata {
    my ($class, $channel_id, $client) = @_;
    return unless $channel_id;

    delete $channelMetadata{$channel_id};

    if ($client) {
        my $song = $client->playingSong();
        $song->pluginData('xmplaylist_meta', undef) if $song;
    }
}

# Clear player states for channels different from the specified URL
sub _clearPlayerStatesForDifferentChannel {
    my ($class, $client, $newUrl) = @_;
    my $clientId = $client->id();

    return unless $client && $newUrl && $clientId;

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

        $class->_resetChannelMetadata($existingChannelId, $client);
        delete $channelMetadata{$newChannelId};

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

    my $port = $prefs->get('port');

    # Handle converted HTTP URLs
    if ($url =~ m{^http://localhost:$port\b/([\w-]+)\.m3u8$}) {
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

1;
