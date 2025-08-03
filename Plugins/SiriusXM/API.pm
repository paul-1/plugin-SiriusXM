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
use constant CACHE_TIMEOUT => 86400; # 24 hours (1 day)

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

sub invalidateChannelCache {
    my $class = shift;
    $log->info("Invalidating channel cache due to playback failure");
    $cache->remove('siriusxm_channels');
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
            
            # Invalidate cache since proxy communication failed
            $cache->remove('siriusxm_channels');
            
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
    
    # Generate sxm protocol URL instead of direct HTTP URL
    my $stream_url = "sxm:$channel_id";
    
    $log->debug("Stream URL: $stream_url");
    $cb->($stream_url);
}

sub authenticate {
    my ($class, $cb) = @_;
    
    $log->debug("Testing authentication with SiriusXM proxy");
    
    my $port = $prefs->get('port') || '9999';
    my $url = "http://localhost:$port/auth";
    
    # Use async HTTP request to test proxy authentication
    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $response = shift;
            my $content = $response->content;
            
            $log->debug("Authentication response received");
            
            my $auth_data;
            eval {
                $auth_data = decode_json($content);
            };
            
            if ($@) {
                $log->error("Failed to parse authentication response: $@");
                $cb->(0);
                return;
            }
            
            my $authenticated = $auth_data->{authenticated} || 0;
            if ($authenticated) {
                $log->info("Authentication test successful - user is authenticated");
                $cb->(1);
            } else {
                $log->warn("Authentication test failed - user is not authenticated");
                $cb->(0);
            }
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
            # Build sxm protocol URL
            my $stream_url = "sxm:" . $channel->{id};
            
            # Format channel name: "Channel Icon - Channel Name (siriusChannelNumber)"
            my $display_name = $channel->{name};
            if ($channel->{number}) {
                $display_name .= " (" . $channel->{number} . ")";
            }
            
            push @category_items, {
                name => $display_name,
                type => 'audio',
                url  => $stream_url,
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

sub findBestImage {
    my ($class, $images_data, $target_width, $target_height) = @_;
    
    return '' unless $images_data && $images_data->{images} && ref($images_data->{images}) eq 'ARRAY';
    
    my $best_image = '';
    my $best_score = 999999; # Start with a high score
    
    for my $image (@{$images_data->{images}}) {
        next unless $image->{width} && $image->{height} && $image->{url};
        
        # Calculate distance from target size (Euclidean distance)
        my $width_diff = abs($image->{width} - $target_width);
        my $height_diff = abs($image->{height} - $target_height);
        my $score = sqrt($width_diff * $width_diff + $height_diff * $height_diff);
        
        if ($score < $best_score) {
            $best_score = $score;
            $best_image = $image->{url};
        }
    }
    
    return $best_image;
}

sub normalizeChannelName {
    my ($class, $channel_name) = @_;

    return '' unless $channel_name;

    # Convert to lowercase and remove spaces, underscores, and special characters
    my $normalized = lc($channel_name);
    $normalized =~ s/[^a-z0-9]//g;

    return $normalized;
}


sub processChannelData {
    my ($class, $raw_channels) = @_;
    
    return [] unless $raw_channels && ref($raw_channels) eq 'ARRAY';
    
    my %categories = ();
    
    # Process channels and organize by primary category
    for my $channel (@$raw_channels) {
        next unless $channel->{channelId} && $channel->{name};
        
        my $channel_name = $channel->{name};
        my $xmp_name = $class->normalizeChannelName($channel_name);

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
        
        # Store channel info with best matching logo (closest to 520x520)
        my $logo_url = '';
        if ($channel->{images}) {
            $logo_url = $class->findBestImage($channel->{images}, 520, 520);
        }
        
        my $channel_info = {
            id => $channel->{channelId},
            name => $channel->{name},
            xmplaylist_name => $xmp_name,
            category => $primary_category,
            number => $channel->{siriusChannelNumber} || $channel->{channelNumber} || '',
            description => $channel->{shortDescription} || '',
            logo => $logo_url,
            icon => $logo_url,
        };
        
        # Add to category group
        push @{$categories{$primary_category}}, $channel_info;
    }
    
    $log->debug("Processed channels into " . scalar(keys %categories) . " categories");
    
    return \%categories;  # Return categories hash instead of flat list
}

sub searchChannels {
    my ($class, $client, $search_term, $cb) = @_;
    
    $log->debug("Searching channels for: $search_term");
    
    # Get all channels first
    $class->getChannels($client, sub {
        my $category_menu = shift;
        
        return $cb->([]) unless $category_menu && @$category_menu;
        
        my @search_results = ();
        my $search_lc = lc($search_term);
        
        # Search through all categories and channels
        for my $category (@$category_menu) {
            next unless $category->{items};
            
            for my $channel (@{$category->{items}}) {
                my $channel_name = lc($channel->{name} || '');
                my $channel_desc = lc($channel->{description} || '');
                
                # Match on channel name or description
                if ($channel_name =~ /\Q$search_lc\E/ || $channel_desc =~ /\Q$search_lc\E/) {
                    # Format channel name: "Channel Icon - Channel Name (siriusChannelNumber) (Category)"
                    my $display_name = $channel->{name};
                    if ($channel->{channel_number}) {
                        $display_name .= " (" . $channel->{channel_number} . ")";
                    }
                    $display_name .= " (" . $category->{name} . ")";
                    
                    push @search_results, {
                        %$channel,
                        name => $display_name,
                    };
                }
            }
        }
        
        $log->debug("Found " . scalar(@search_results) . " search results");
        $cb->(\@search_results);
    });
}

1;
