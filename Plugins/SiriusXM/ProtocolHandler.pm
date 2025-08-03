package Plugins::SiriusXM::ProtocolHandler;

use strict;
use warnings;

use base qw(Slim::Player::Protocols::HTTP);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Utils::Cache;

use Plugins::SiriusXM::API;

my $log = logger('plugin.siriusxm');
my $prefs = preferences('plugin.siriusxm');

sub new {
    my $class = shift;
    my $args = shift;

    my $song = $args->{'song'};

    return $class->SUPER::new({
        'song' => $song,
        'url'  => $song->track()->url(),
    });
}

# Handle sxm: protocol URLs by converting them to HTTP proxy URLs
sub getFormatForURL {
    my ($class, $url) = @_;
    
    # For sxm: URLs, we'll stream as HTTP since we convert to HTTP proxy URLs
    return 'mp3';  # Default format, actual format determined by proxy
}

sub isRemote {
    return 1;
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
        # Store channel info for metadata access
        my $channel_info = $class->getChannelInfoFromUrl($url);
        $song->pluginData('channel_info', $channel_info) if $channel_info;
        
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
    
    return unless $url =~ /^sxm:/;
    
    my ($channel_id) = $url =~ /^sxm:(.+)$/;
    return unless $channel_id;
    
    # Try to get channel info from cache first
    my $cache = Slim::Utils::Cache->new();
    my $cached_channels = $cache->get('siriusxm_channels');
    
    if ($cached_channels) {
        # Search through cached channel data
        for my $category (@$cached_channels) {
            next unless $category->{items};
            
            for my $channel (@{$category->{items}}) {
                # Extract channel ID from the URL
                if ($channel->{url} && $channel->{url} =~ /\/$channel_id\.m3u8$/) {
                    return {
                        id => $channel_id,
                        name => $channel->{name},
                        description => $channel->{description},
                        channel_number => $channel->{channel_number},
                        icon => $channel->{icon},
                        category => $category->{name},
                    };
                }
            }
        }
    }
    
    # Fallback channel info if not found in cache
    return {
        id => $channel_id,
        name => "SiriusXM Channel",
        description => "SiriusXM Channel $channel_id",
    };
}

# Provide metadata for the stream
sub getMetadataFor {
    my ($class, $client, $url, $forceCurrent) = @_;
    
    my $song = $client->streamingSong() || $client->playingSong();
    my $channel_info;
    
    if ($song) {
        $channel_info = $song->pluginData('channel_info');
    }
    
    # If no channel info in song data, try to extract from URL
    if (!$channel_info) {
        $channel_info = $class->getChannelInfoFromUrl($url);
    }
    
    my $meta = $class->SUPER::getMetadataFor($client, $url, $forceCurrent) || {};
    
    if ($channel_info) {
        $meta->{artist} ||= $channel_info->{name};
        $meta->{title} ||= $channel_info->{description} || $channel_info->{name};
        $meta->{icon} ||= $channel_info->{icon};
        $meta->{cover} ||= $channel_info->{icon};
        $meta->{album} ||= 'SiriusXM';
        
        # Store channel info for other uses
        $meta->{channel_info} = $channel_info;
    }
    
    return $meta;
}

# Support for seeking (pass through to HTTP handler)
sub canSeek {
    my ($class, $client, $song) = @_;
    return $class->SUPER::canSeek($client, $song);
}

# Support for direct streaming 
sub canDirectStream {
    my ($class, $client, $url) = @_;
    return $class->SUPER::canDirectStream($client, $url);
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