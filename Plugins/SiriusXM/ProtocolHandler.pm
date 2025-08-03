package Plugins::SiriusXM::ProtocolHandler;

use strict;
use base qw(Slim::Player::Protocols::HTTP);

use JSON::XS;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Networking::SimpleAsyncHTTP;

use Plugins::SiriusXM::API;

my $prefs = preferences('plugin.siriusxm');
my $log = logger('plugin.siriusxm');

# To support remote streaming (synced players), we need to subclass Protocols::HTTP
sub new {
    my $class  = shift;
    my $args   = shift;

    my $client = $args->{client};
    my $song      = $args->{song};
    my $originalUrl = $song->streamUrl() || return;

    # Convert siriusxm:// URL to actual HTTP proxy URL
    my $streamUrl;
    if ($originalUrl =~ /^siriusxm:\/\/(.+)$/) {
        my $channel_name = $1;
        my $port = $prefs->get('port') || '9999';
        $streamUrl = "http://localhost:$port/$channel_name.m3u8";
        
        # Store the channel name for metadata lookup
        $song->pluginData('siriusxm_channel_name', $channel_name);
    } else {
        $streamUrl = $originalUrl;
    }

    main::DEBUGLOG && $log->debug( "Remote streaming SiriusXM track: $originalUrl -> $streamUrl" );

    return $class->SUPER::new( {
        url     => $streamUrl,
        song    => $args->{song},
        client  => $client,
    } );
}

sub canSeek { 0 }
sub isRemote { 1 }
sub canDirectStream { 0 }
sub isRepeatingStream { 1 }
sub contentType { 'audio/flac' };

sub canDoAction {
    my ( $class, $client, $url, $action ) = @_;

    # SiriusXM doesn't support pause, rewind, or seeking
    if ( $action eq 'pause' || $action eq 'rew' ) {
        return 0;
    }

    return 1;
}

# Avoid scanning
sub scanUrl {
    my ( $class, $url, $args ) = @_;
    $args->{cb}->( $args->{song}->currentTrack() );
}

sub getMetadataFor {
    my ( $class, $client, $url, undef, $song ) = @_;

    $client = $client->master;
    $song ||= $client->playingSong();
    return {} unless $song;

    my $icon = $class->getIcon();

    # Extract channel name from URL or song data
    my $channel_name;
    if ($url =~ /^siriusxm:\/\/(.+)$/) {
        $channel_name = $1;
    } elsif (my $stored_channel = $song->pluginData('siriusxm_channel_name')) {
        $channel_name = $stored_channel;
    } elsif ($url =~ m{(localhost|127\.0\.0\.1):\d+/([^/.]+)\.m3u8$}) {
        $channel_name = $2;
    }

    # If we have a channel name, try to get nowplaying data
    if ($channel_name) {
        $log->debug("Getting nowplaying metadata for channel: $channel_name");
        
        # Try to get cached nowplaying data synchronously for initial metadata
        my $normalized_channel = Plugins::SiriusXM::API->normalizeChannelName($channel_name);
        if ($normalized_channel) {
            my $cache_key = "nowplaying_$normalized_channel";
            my $cached = Slim::Utils::Cache->new()->get($cache_key);
            
            if ($cached && $cached->{title}) {
                $log->debug("Using cached nowplaying data for metadata: " . $cached->{title});
                
                return {
                    artist   => $cached->{artist} || 'SiriusXM',
                    title    => $cached->{title},
                    cover    => $cached->{artwork_url} || $icon,
                    icon     => $icon,
                    bitrate  => '',
                    duration => 0,
                    secs     => 0,
                    buttons  => {
                        rew => 0,
                    },
                };
            }
        }
        
        # If no cached data, fetch asynchronously and update later
        Plugins::SiriusXM::API->fetchNowPlaying($channel_name, sub {
            my $nowplaying = shift;
            
            if ($nowplaying && $nowplaying->{title}) {
                $log->debug("Got fresh nowplaying data, updating metadata");
                
                # Update the song's metadata
                if (my $track = $song->track) {
                    $track->title($nowplaying->{title});
                    $track->artist($nowplaying->{artist}) if $nowplaying->{artist};
                    $track->cover($nowplaying->{artwork_url}) if $nowplaying->{artwork_url};
                }
                
                # Notify clients of metadata change
                require Slim::Control::Request;
                Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
            }
        });
        
        # Start periodic metadata updates for this channel
        $class->startMetadataTimer($client, $channel_name);
        
        # Return basic metadata while we wait for nowplaying data
        return {
            artist   => 'SiriusXM',
            title    => ucfirst($channel_name),
            cover    => $icon,
            icon     => $icon,
            bitrate  => '',
            duration => 0,
            secs     => 0,
            buttons  => {
                rew => 0,
            },
        };
    }

    main::DEBUGLOG && $log->debug("Returning default metadata with channel name");

    # Use channel name if we have one, otherwise fall back to generic
    my $channel_title = $channel_name ? ucfirst($channel_name) : 'SiriusXM Radio';

    return {
        icon     => $icon,
        cover    => $icon,
        bitrate  => '',
        title    => $channel_title,
        duration => 0,
        secs     => 0,
        buttons  => {
            rew => 0,
        },
    };
}

sub getIcon {
    return 'plugins/SiriusXM/html/images/SiriusXMLogo.png';
}

sub startMetadataTimer {
    my ($class, $client, $channel_name) = @_;
    
    return unless $client && $channel_name;
    
    my $normalized_channel = Plugins::SiriusXM::API->normalizeChannelName($channel_name);
    return unless $normalized_channel;
    
    my $client_id = $client->id;
    my $timer_id = "siriusxm_metadata_" . $client_id . "_" . $normalized_channel;
    
    $log->debug("Starting metadata timer for client " . $client->name . " channel $channel_name");
    
    # Clean up ALL existing SiriusXM metadata timers for this client first
    # This ensures that when switching channels, old timers are cleaned up
    Slim::Utils::Timers::killTimers($client, qr/^siriusxm_metadata_${client_id}_/);
    
    # Start new timer to refresh metadata every 30 seconds
    Slim::Utils::Timers::setTimer(
        $client,
        time() + 30,
        sub {
            $class->refreshMetadata($client, $channel_name, $timer_id, 1); # 1 = timer_triggered
        },
        $timer_id
    );
}

sub refreshMetadata {
    my ($class, $client, $channel_name, $timer_id, $timer_triggered) = @_;
    
    return unless $client && $channel_name;
    
    # Check if client is still playing a SiriusXM stream
    my $song = $client->playingSong();
    return unless $song;
    
    my $url = $song->track->url;
    return unless $url =~ /^siriusxm:/;
    
    my $normalized_channel = Plugins::SiriusXM::API->normalizeChannelName($channel_name);
    
    # If this is not a timer-triggered refresh, just return cached data
    unless ($timer_triggered) {
        my $cache_key = "nowplaying_$normalized_channel";
        my $cached = Slim::Utils::Cache->new()->get($cache_key);
        if ($cached && $cached->{title}) {
            $log->debug("Returning cached metadata for regular refreshMetadata call");
            return $cached;
        }
        # If no cached data available, fall back to default
        return {};
    }
    
    $log->debug("Timer-triggered metadata refresh for client " . $client->name . " channel $channel_name");
    
    # Get fresh nowplaying data (bypassing cache) for timer-triggered refreshes only
    my $api_url = "https://xmplaylist.com/api/station/$normalized_channel";
    
    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $response = shift;
            my $content = $response->content;
            
            my $data;
            eval {
                $data = decode_json($content);
            };
            
            return if $@;
            
            my $nowplaying = Plugins::SiriusXM::API->parseNowPlayingResponse($data);
            
            if ($nowplaying && $nowplaying->{title}) {
                # Check if this is actually new metadata
                my $cache_key = "nowplaying_$normalized_channel";
                my $cached = Slim::Utils::Cache->new()->get($cache_key);
                
                my $has_changed = 0;
                if (!$cached || !$cached->{title} || $cached->{title} ne $nowplaying->{title}) {
                    $has_changed = 1;
                }
                
                if ($has_changed) {
                    $log->info("Track changed for $channel_name: " . $nowplaying->{title});
                    
                    # Update cache
                    Slim::Utils::Cache->new()->set($cache_key, $nowplaying, 60);
                    
                    # Update the song's metadata
                    if (my $track = $song->track) {
                        $track->title($nowplaying->{title});
                        $track->artist($nowplaying->{artist}) if $nowplaying->{artist};
                        $track->cover($nowplaying->{artwork_url}) if $nowplaying->{artwork_url};
                    }
                    
                    # Notify clients of metadata change
                    require Slim::Control::Request;
                    Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
                }
            }
            
            # Schedule next refresh if still playing
            if ($client->playingSong() && $client->playingSong()->track->url =~ /^siriusxm:/) {
                Slim::Utils::Timers::setTimer(
                    $client,
                    time() + 30,
                    sub {
                        $class->refreshMetadata($client, $channel_name, $timer_id, 1); # 1 = timer_triggered
                    },
                    $timer_id
                );
            }
        },
        sub {
            my ($http, $error) = @_;
            $log->warn("Failed to refresh metadata for $channel_name: $error");
            
            # On failure, provide fallback metadata with channel name and icon
            my $icon = $class->getIcon();
            my $fallback_metadata = {
                artist   => 'SiriusXM',
                title    => ucfirst($channel_name),
                cover    => $icon,
                icon     => $icon,
                bitrate  => '',
                duration => 0,
                secs     => 0,
                buttons  => {
                    rew => 0,
                },
            };
            
            # Update the song's metadata with fallback
            if (my $track = $song->track) {
                $track->title($fallback_metadata->{title});
                $track->artist($fallback_metadata->{artist});
                $track->cover($fallback_metadata->{cover});
            }
            
            # Notify clients of metadata change
            require Slim::Control::Request;
            Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
            
            # Schedule retry in 30 seconds if still playing
            if ($client->playingSong() && $client->playingSong()->track->url =~ /^siriusxm:/) {
                Slim::Utils::Timers::setTimer(
                    $client,
                    time() + 30,
                    sub {
                        $class->refreshMetadata($client, $channel_name, $timer_id, 1); # 1 = timer_triggered
                    },
                    $timer_id
                );
            }
        },
        {
            timeout => 15,
        }
    );
    
    $http->get($api_url);
}

1;