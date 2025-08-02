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
        my $channel_id = $1;
        my $port = $prefs->get('port') || '9999';
        $streamUrl = "http://localhost:$port/$channel_id.m3u8";
        
        # Store the channel ID for metadata lookup
        $song->pluginData('siriusxm_channel_id', $channel_id);
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
sub contentType { 'audio/aac' };

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

    # Extract channel name/ID from URL or song data
    my $channel_id;
    if ($url =~ /^siriusxm:\/\/(.+)$/) {
        $channel_id = $1;
    } elsif (my $stored_channel = $song->pluginData('siriusxm_channel_id')) {
        $channel_id = $stored_channel;
    } elsif ($url =~ m{(localhost|127\.0\.0\.1):\d+/([^/.]+)\.m3u8$}) {
        $channel_id = $2;
    }

    # If we have a channel ID, try to get nowplaying data
    if ($channel_id) {
        $log->debug("Getting nowplaying metadata for channel: $channel_id");
        
        # Try to get cached nowplaying data synchronously for initial metadata
        my $normalized_channel = Plugins::SiriusXM::API->normalizeChannelName($channel_id);
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
        Plugins::SiriusXM::API->fetchNowPlaying($channel_id, sub {
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
        $class->startMetadataTimer($client, $channel_id);
        
        # Return basic metadata while we wait for nowplaying data
        return {
            artist   => 'SiriusXM',
            title    => ucfirst($channel_id),
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

    main::DEBUGLOG && $log->debug("Returning default metadata");

    return {
        icon     => $icon,
        cover    => $icon,
        bitrate  => '',
        title    => 'SiriusXM Radio',
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
    my ($class, $client, $channel_id) = @_;
    
    return unless $client && $channel_id;
    
    my $normalized_channel = Plugins::SiriusXM::API->normalizeChannelName($channel_id);
    return unless $normalized_channel;
    
    my $timer_id = "siriusxm_metadata_" . $client->id . "_" . $normalized_channel;
    
    $log->debug("Starting metadata timer for client " . $client->name . " channel $channel_id");
    
    # Stop any existing timer for this client/channel
    Slim::Utils::Timers::killTimers($client, $timer_id);
    
    # Start new timer to refresh metadata every 30 seconds
    Slim::Utils::Timers::setTimer(
        $client,
        time() + 30,
        sub {
            $class->refreshMetadata($client, $channel_id, $timer_id);
        },
        $timer_id
    );
}

sub refreshMetadata {
    my ($class, $client, $channel_id, $timer_id) = @_;
    
    return unless $client && $channel_id;
    
    # Check if client is still playing a SiriusXM stream
    my $song = $client->playingSong();
    return unless $song;
    
    my $url = $song->track->url;
    return unless $url =~ /^siriusxm:/;
    
    $log->debug("Refreshing metadata for client " . $client->name . " channel $channel_id");
    
    # Get fresh nowplaying data (bypassing cache)
    my $normalized_channel = Plugins::SiriusXM::API->normalizeChannelName($channel_id);
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
                    $log->info("Track changed for $channel_id: " . $nowplaying->{title});
                    
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
                        $class->refreshMetadata($client, $channel_id, $timer_id);
                    },
                    $timer_id
                );
            }
        },
        sub {
            my ($http, $error) = @_;
            $log->warn("Failed to refresh metadata for $channel_id: $error");
            
            # Schedule retry in 30 seconds if still playing
            if ($client->playingSong() && $client->playingSong()->track->url =~ /^siriusxm:/) {
                Slim::Utils::Timers::setTimer(
                    $client,
                    time() + 30,
                    sub {
                        $class->refreshMetadata($client, $channel_id, $timer_id);
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