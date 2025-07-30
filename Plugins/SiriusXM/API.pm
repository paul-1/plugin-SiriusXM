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
            
            # Process and organize channels by category
            my $categories = $class->processChannelData($channels_data);
            
            # Build hierarchical menu structure
            my $menu_items = $class->buildCategoryMenu($categories);
            
            # Cache the processed results
            $cache->set('siriusxm_channels', $menu_items, CACHE_TIMEOUT);
            
            $log->info("Retrieved and processed channels into menu structure");
            $cb->($menu_items);
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

sub buildCategoryMenu {
    my ($class, $categories) = @_;
    
    my @menu_items = ();
    my $port = $prefs->get('port') || '9999';
    
    # Create folder menu for each category
    for my $category_name (sort keys %$categories) {
        my $channels_in_category = $categories->{$category_name};
        
        # Sort channels within category by channel number
        my @sorted_channels = sort {
            my $a_num = $a->{number} || 9999;
            my $b_num = $b->{number} || 9999;
            $a_num <=> $b_num;
        } @$channels_in_category;
        
        # Create menu items for channels in this category
        my @category_items = ();
        for my $channel (@sorted_channels) {
            # Build proper proxy URL
            my $stream_url = "http://localhost:$port/" . $channel->{id} . ".m3u8";
            
            push @category_items, {
                name => $channel->{name},
                type => 'audio',
                url  => 'sxm://' . $channel->{id},
                icon => $channel->{logo} || 'plugins/SiriusXM/html/images/SiriusXMLogo.png',
                on_select => 'play',
                description => $channel->{description},
                channel_number => $channel->{number},
            };
        }
        
        # Create category folder
        push @menu_items, {
            name => $category_name,
            type => 'opml',
            items => \@category_items,
            icon => 'plugins/SiriusXM/html/images/SiriusXMLogo.png',
        };
    }
    
    return \@menu_items;
}

sub processChannelData {
    my ($class, $raw_channels) = @_;
    
    return [] unless $raw_channels && ref($raw_channels) eq 'ARRAY';
    
    my %categories = ();
    
    # Process channels and organize by primary category
    for my $channel (@$raw_channels) {
        next unless $channel->{channelId} && $channel->{name};
        
        # Find the primary category
        my $primary_category = 'Other';  # Default fallback
        
        if ($channel->{categories} && $channel->{categories}->{categories}) {
            my $category_list = $channel->{categories}->{categories};
            
            # Look for category with isPrimary = true
            for my $cat (@$category_list) {
                if ($cat->{isPrimary} && $cat->{name}) {
                    $primary_category = $cat->{name};
                    last;
                }
            }
        }
        
        # Store channel info with high-resolution logo (520x520)
        my $logo_url = '';
        if ($channel->{channelLogo}) {
            # Use 520x520 resolution for logos
            $logo_url = $channel->{channelLogo};
            $logo_url =~ s/\/\d+x\d+\//\/520x520\//;  # Replace any existing resolution with 520x520
        }
        
        my $channel_info = {
            id => $channel->{channelId},
            name => $channel->{name},
            category => $primary_category,
            number => $channel->{siriusChannelNumber} || $channel->{channelNumber} || '',
            description => $channel->{description} || '',
            logo => $logo_url,
        };
        
        # Add to category group
        push @{$categories{$primary_category}}, $channel_info;
    }
    
    $log->debug("Processed channels into " . scalar(keys %categories) . " categories");
    
    return \%categories;  # Return categories hash instead of flat list
}

1;