package Plugins::SiriusXM::ProtocolHandler;

use strict;
use warnings;

use base qw(Slim::Player::Protocols::HTTP);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Plugins::SiriusXM::API;

my $log = logger('plugin.siriusxm');
my $prefs = preferences('plugin.siriusxm');

Slim::Player::ProtocolHandlers->registerHandler('sxm', __PACKAGE__);

sub new {
    my $class = shift;
    my $args  = shift;
    
    my $client = $args->{'client'};
    my $song   = $args->{'song'};
    my $url    = $song->currentTrack()->url;
    
    $log->debug("Creating new protocol handler for: $url");
    
    return $class->SUPER::new($args);
}

sub canSeek { 0 }
sub canSeekError { return ('SEEK_ERROR_TYPE_NOT_SUPPORTED', 'SiriusXM'); }

sub isRemote { 1 }

sub contentType {
    return 'audio/mpeg';
}

sub getFormatForURL {
    return 'mp3';
}

sub scanUrl {
    my ($class, $url, $args) = @_;
    
    $log->debug("Scanning URL: $url");
    
    my $cb = $args->{cb};
    
    # Extract channel ID from URL
    my ($channel_id) = $url =~ /^sxm:\/\/(.+)$/;
    unless ($channel_id) {
        $log->error("Invalid SiriusXM URL: $url");
        $cb->({});
        return;
    }
    
    # Get stream information
    $class->_getStreamInfo($channel_id, sub {
        my $info = shift;
        $cb->($info || {});
    });
}

sub getNextTrack {
    my ($class, $song, $successCb, $errorCb) = @_;
    
    my $url = $song->currentTrack()->url;
    $log->debug("Getting next track for: $url");
    
    # Extract channel ID from URL
    my ($channel_id) = $url =~ /^sxm:\/\/(.+)$/;
    unless ($channel_id) {
        $log->error("Invalid SiriusXM URL: $url");
        $errorCb->('Invalid URL');
        return;
    }
    
    # Get actual stream URL from API
    Plugins::SiriusXM::API->getStreamUrl($channel_id, sub {
        my $stream_url = shift;
        
        unless ($stream_url) {
            $log->error("Failed to get stream URL for channel: $channel_id");
            $errorCb->('Failed to get stream URL');
            return;
        }
        
        $log->debug("Got stream URL: $stream_url");
        $song->currentTrack()->url($stream_url);
        
        $successCb->();
    });
}

sub _getStreamInfo {
    my ($class, $channel_id, $cb) = @_;
    
    $log->debug("Getting stream info for channel: $channel_id");
    
    # Get channels to find channel information
    Plugins::SiriusXM::API->getChannels(undef, sub {
        my $channels = shift;
        
        my $channel_info;
        for my $channel (@$channels) {
            if ($channel->{id} eq $channel_id) {
                $channel_info = $channel;
                last;
            }
        }
        
        unless ($channel_info) {
            $log->error("Channel not found: $channel_id");
            $cb->({});
            return;
        }
        
        my $info = {
            title       => $channel_info->{name},
            artist      => 'SiriusXM',
            album       => $channel_info->{category} || 'SiriusXM',
            duration    => 0, # Live stream
            bitrate     => $class->_getBitrate(),
            type        => 'MP3 (SiriusXM)',
            icon        => $channel_info->{logo} || 'plugins/SiriusXM/html/images/siriusxm.png',
            cover       => $channel_info->{logo} || 'plugins/SiriusXM/html/images/siriusxm.png',
        };
        
        $cb->($info);
    });
}

sub _getBitrate {
    my $class = shift;
    
    my $quality = $prefs->get('quality') || 'medium';
    
    my %bitrates = (
        'low'    => '32k',
        'medium' => '64k',
        'high'   => '128k',
    );
    
    return $bitrates{$quality} || '64k';
}

# Override parent methods for SiriusXM specific behavior
sub handleDirectError {
    my ($class, $client, $url, $response, $status_line) = @_;
    
    $log->error("Stream error for $url: $status_line");
    
    # Try to get a new stream URL if the current one fails
    if ($url =~ /^sxm:\/\/(.+)$/) {
        my $channel_id = $1;
        $log->info("Attempting to refresh stream URL for channel: $channel_id");
        
        # Clear any cached stream URLs and try again
        # This would be handled by the getNextTrack method
    }
    
    return $class->SUPER::handleDirectError($client, $url, $response, $status_line);
}

sub metadata {
    my ($class, $client, $url) = @_;
    
    # Extract channel ID from URL
    my ($channel_id) = $url =~ /^sxm:\/\/(.+)$/;
    return {} unless $channel_id;
    
    # Return basic metadata - real metadata would come from the stream
    return {
        artist => 'SiriusXM',
        title  => "Channel $channel_id",
        type   => 'SiriusXM Radio',
        icon   => 'plugins/SiriusXM/html/images/siriusxm.png',
    };
}

1;