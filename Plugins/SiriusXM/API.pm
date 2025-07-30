package Plugins::SiriusXM::API;

use strict;
use warnings;

use JSON::XS;
use HTTP::Request;
use LWP::UserAgent;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Cache;
use Slim::Networking::SimpleAsyncHTTP;

my $log = logger('plugin.siriusxm');
my $prefs = preferences('plugin.siriusxm');
my $cache = Slim::Utils::Cache->new();

# Cache timeout in seconds
use constant CACHE_TIMEOUT => 300; # 5 minutes

sub init {
    my $class = shift;
    $log->debug("Initializing SiriusXM API");
}

sub cleanup {
    my $class = shift;
    $log->debug("Cleaning up SiriusXM API");
    # Clear any cached data
    $cache->remove('siriusxm_channels');
    $cache->remove('siriusxm_auth_token');
}

sub getChannels {
    my ($class, $client, $cb) = @_;
    
    $log->debug("Getting SiriusXM channels from proxy");
    
    # Check cache first
    my $cached = $cache->get('siriusxm_channels');
    if ($cached) {
        $log->debug("Returning cached channels");
        $cb->($cached);
        return;
    }
    
    my $port = $prefs->get('port') || '9999';
    my $url = "http://localhost:$port/channel/all";
    
    $log->debug("Fetching channels from proxy: $url");
    
    # Use async HTTP request to avoid blocking
    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $response = shift;
            my $content = $response->content;
            
            $log->debug("Received channel data from proxy");
            
            my $channels_data;
            eval {
                $channels_data = decode_json($content);
            };
            
            if ($@) {
                $log->error("Failed to parse channel data from proxy: $@");
                $cb->([]);
                return;
            }
            
            # Process and organize channels
            my $processed_channels = $class->processChannelData($channels_data);
            
            # Cache the processed results
            $cache->set('siriusxm_channels', $processed_channels, CACHE_TIMEOUT);
            
            $log->info("Retrieved and processed " . scalar(@$processed_channels) . " channels");
            $cb->($processed_channels);
        },
        sub {
            my ($http, $error) = @_;
            $log->error("Failed to fetch channels from proxy: $error");
            $cb->([]);
        },
        {
            timeout => 30,
        }
    );
    
    $http->get($url);
}

sub getStreamUrl {
    my ($class, $channel_id, $cb) = @_;
    
    $log->debug("Getting stream URL for channel: $channel_id");
    
    my $port = $prefs->get('port') || '9999';
    my $stream_url = "http://localhost:$port/$channel_id.m3u8";
    
    $log->debug("Stream URL: $stream_url");
    $cb->($stream_url);
}

sub authenticate {
    my ($class, $cb) = @_;
    
    $log->debug("Testing authentication with SiriusXM proxy");
    
    my $port = $prefs->get('port') || '9999';
    my $url = "http://localhost:$port/channel/all";
    
    # Use async HTTP request to test proxy connection
    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $response = shift;
            $log->info("Authentication test successful - proxy is responding");
            $cb->(1);
        },
        sub {
            my ($http, $error) = @_;
            $log->error("Authentication test failed - proxy not responding: $error");
            $cb->(0);
        },
        {
            timeout => 15,
        }
    );
    
    $http->get($url);
}

sub processChannelData {
    my ($class, $raw_channels) = @_;
    
    return [] unless $raw_channels && ref($raw_channels) eq 'ARRAY';
    
    my @processed_channels = ();
    my %categories = ();
    
    # First pass: organize channels by category
    for my $channel (@$raw_channels) {
        next unless $channel->{channelId} && $channel->{name};
        
        # Get the primary category or use a default
        my $category = $channel->{categoryList}->[0]->{categoryName} || 'Other';
        
        # Store channel info
        my $channel_info = {
            id => $channel->{channelId},
            name => $channel->{name},
            category => $category,
            number => $channel->{siriusChannelNumber} || '',
            description => $channel->{description} || '',
            logo => $channel->{channelLogo} || '',
        };
        
        # Add to category group
        push @{$categories{$category}}, $channel_info;
    }
    
    # Second pass: create menu structure with categories
    for my $category (sort keys %categories) {
        my $channels_in_category = $categories{$category};
        
        # Sort channels within category by channel number
        my @sorted_channels = sort {
            my $a_num = $a->{number} || 9999;
            my $b_num = $b->{number} || 9999;
            $a_num <=> $b_num;
        } @$channels_in_category;
        
        # Add each channel with category prefix
        for my $channel (@sorted_channels) {
            push @processed_channels, {
                id => $channel->{id},
                name => "$category / $channel->{name}",
                display_name => $channel->{name},
                category => $category,
                number => $channel->{number},
                description => $channel->{description},
                logo => $channel->{logo},
            };
        }
    }
    
    $log->debug("Processed " . scalar(@processed_channels) . " channels into " . scalar(keys %categories) . " categories");
    
    return \@processed_channels;
}

1;