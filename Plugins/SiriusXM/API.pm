package Plugins::SiriusXM::API;

use strict;
use warnings;

use JSON::XS;
use HTTP::Request;
use LWP::UserAgent;
use Time::HiRes;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Cache;
use Slim::Utils::Timers;
use Slim::Networking::SimpleAsyncHTTP;

my $log = logger('plugin.siriusxm');
my $prefs = preferences('plugin.siriusxm');
my $cache = Slim::Utils::Cache->new();

# Cache timeout in seconds
use constant CACHE_TIMEOUT => 86400; # 24 hours (1 day)
use constant NOWPLAYING_POLL_INTERVAL => 30; # 30 seconds
use constant NOWPLAYING_CACHE_TIMEOUT => 60; # 1 minute

sub init {
    my $class = shift;
    $log->debug("Initializing SiriusXM API");
}

sub cleanup {
    my $class = shift;
    $log->debug("Cleaning up SiriusXM API");
    
    # Stop all nowplaying timers
    Slim::Utils::Timers::killTimers(undef, qr/^nowplaying_/);
    
    # Clear any cached data
    $cache->remove('siriusxm_channels');
    $cache->remove('siriusxm_auth_token');
    
    # Clear nowplaying cache
    # Note: We can't easily remove all nowplaying cache entries without iterating
    # but they will expire naturally due to the short timeout
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
    
    my $port = $prefs->get('port') || '9999';
    my $stream_url = "http://localhost:$port/$channel_id.m3u8";
    
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
        
        # Store channel info with best matching logo (closest to 520x520)
        my $logo_url = '';
        if ($channel->{images}) {
            $logo_url = $class->findBestImage($channel->{images}, 520, 520);
        }
        
        my $channel_info = {
            id => $channel->{channelId},
            name => $channel->{name},
            category => $primary_category,
            number => $channel->{siriusChannelNumber} || $channel->{channelNumber} || '',
            description => $channel->{shortDescription} || '',
            logo => $logo_url,
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

sub normalizeChannelName {
    my ($class, $channel_name) = @_;
    
    return '' unless $channel_name;
    
    # Convert to lowercase and remove spaces, underscores, and special characters
    my $normalized = lc($channel_name);
    $normalized =~ s/[^a-z0-9]//g;
    
    return $normalized;
}

sub fetchNowPlayingFresh {
    my ($class, $channel_name, $cb) = @_;
    
    return $cb->({}) unless $channel_name;
    
    $log->debug("Fetching fresh nowplaying data for channel: $channel_name");
    
    # Normalize channel name for API
    my $normalized_channel = $class->normalizeChannelName($channel_name);
    unless ($normalized_channel) {
        $log->warn("Could not normalize channel name: $channel_name");
        return $cb->({});
    }
    
    # Build API URL
    my $api_url = "https://xmplaylist.com/api/station/$normalized_channel";
    
    $log->debug("Fetching nowplaying from: $api_url");
    
    # Use async HTTP request (always fetch fresh, no cache check)
    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $response = shift;
            my $content = $response->content;
            
            $log->debug("Received fresh nowplaying response for: $normalized_channel");
            
            my $data;
            eval {
                $data = decode_json($content);
            };
            
            if ($@) {
                $log->error("Failed to parse nowplaying JSON for $normalized_channel: $@");
                return $cb->({});
            }
            
            # Parse the response
            my $nowplaying = $class->parseNowPlayingResponse($data);
            
            $log->debug("Successfully parsed fresh nowplaying data for: $normalized_channel");
            $cb->($nowplaying);
        },
        sub {
            my ($http, $error) = @_;
            $log->warn("Failed to fetch fresh nowplaying for $normalized_channel: $error");
            $cb->({});
        },
        {
            timeout => 15,
        }
    );
    
    $http->get($api_url);
}

sub notifyPlayersOfMetadataChange {
    my ($class, $normalized_channel, $nowplaying_data) = @_;
    
    return unless $normalized_channel && $nowplaying_data;
    
    $log->debug("Notifying players of metadata change for: $normalized_channel");
    
    # Get all connected clients
    require Slim::Player::Client;
    my @clients = Slim::Player::Client::clients();
    
    for my $client (@clients) {
        next unless $client;
        
        # Check if this client is playing a SiriusXM stream for this channel
        my $url = $client->currentTrack() ? $client->currentTrack()->url : '';
        next unless $url;
        
        # Check if URL matches our channel (localhost or 127.0.0.1 patterns)
        if ($url =~ /(localhost|127\.0\.0\.1).*\/([^\/]+)\.m3u8$/) {
            my $url_channel = $2;
            my $url_normalized = $class->normalizeChannelName($url_channel);
            
            if ($url_normalized eq $normalized_channel) {
                $log->debug("Updating metadata for client playing: $normalized_channel");
                
                # Create a request to update the track metadata
                require Slim::Control::Request;
                my $request = Slim::Control::Request->new(
                    $client->id(),
                    ['songinfo', 0, 100, 'tags:alTC']
                );
                
                # Add nowplaying information to the current track's metadata
                if ($client->currentTrack()) {
                    my $track = $client->currentTrack();
                    
                    # Update track's remote metadata
                    if ($nowplaying_data->{title}) {
                        $track->pluginData('siriusxm_nowplaying_title', $nowplaying_data->{title});
                    }
                    if ($nowplaying_data->{artist}) {
                        $track->pluginData('siriusxm_nowplaying_artist', $nowplaying_data->{artist});
                    }
                    if ($nowplaying_data->{artwork_url}) {
                        $track->pluginData('siriusxm_nowplaying_artwork', $nowplaying_data->{artwork_url});
                    }
                    
                    # Notify LMS that metadata has changed
                    $client->currentPlaylistUpdateTime(Time::HiRes::time());
                    
                    # Send notification to web interface
                    my $notify_request = Slim::Control::Request->new(
                        $client->id(),
                        ['playlist', 'newsong', $track->title || $nowplaying_data->{title} || 'Unknown']
                    );
                    $notify_request->execute();
                }
            }
        }
    }
}

sub fetchNowPlaying {
    my ($class, $channel_name, $cb) = @_;
    
    return $cb->({}) unless $channel_name;
    
    $log->debug("Fetching nowplaying data for channel: $channel_name");
    
    # Normalize channel name for API
    my $normalized_channel = $class->normalizeChannelName($channel_name);
    unless ($normalized_channel) {
        $log->warn("Could not normalize channel name: $channel_name");
        return $cb->({});
    }
    
    # Check cache first
    my $cache_key = "nowplaying_$normalized_channel";
    my $cached = $cache->get($cache_key);
    if ($cached) {
        $log->debug("Returning cached nowplaying data for: $normalized_channel");
        return $cb->($cached);
    }
    
    # If not cached, fetch fresh data
    $class->fetchNowPlayingFresh($normalized_channel, sub {
        my $nowplaying = shift;
        
        # Cache the result
        $cache->set($cache_key, $nowplaying, NOWPLAYING_CACHE_TIMEOUT);
        
        $cb->($nowplaying);
    });
}

sub parseNowPlayingResponse {
    my ($class, $data) = @_;
    
    return {} unless $data && ref($data) eq 'HASH';
    
    # Check if we have results
    unless ($data->{results} && ref($data->{results}) eq 'ARRAY' && @{$data->{results}}) {
        $log->debug("No results in nowplaying response");
        return {};
    }
    
    # Get the first (most recent) result
    my $result = $data->{results}->[0];
    return {} unless $result && ref($result) eq 'HASH';
    
    my $nowplaying = {};
    
    # Extract track information
    if ($result->{track} && ref($result->{track}) eq 'HASH') {
        my $track = $result->{track};
        
        # Track title
        if ($track->{title}) {
            $nowplaying->{title} = $track->{title};
        }
        
        # Artists (join multiple if present)
        if ($track->{artists} && ref($track->{artists}) eq 'ARRAY' && @{$track->{artists}}) {
            $nowplaying->{artist} = join(', ', @{$track->{artists}});
        }
    }
    
    # Extract album artwork from Spotify data
    if ($result->{spotify} && ref($result->{spotify}) eq 'HASH') {
        my $spotify = $result->{spotify};
        
        if ($spotify->{albumImageLarge}) {
            $nowplaying->{artwork_url} = $spotify->{albumImageLarge};
        }
    }
    
    # Add timestamp for change detection
    $nowplaying->{timestamp} = time();
    
    return $nowplaying;
}

sub startNowPlayingPolling {
    my ($class, $channel_name) = @_;
    
    return unless $channel_name;
    
    my $normalized_channel = $class->normalizeChannelName($channel_name);
    return unless $normalized_channel;
    
    $log->debug("Starting nowplaying polling for: $normalized_channel");
    
    # Stop any existing timer for this channel
    $class->stopNowPlayingPolling($normalized_channel);
    
    # Create polling timer
    my $timer_id = "nowplaying_$normalized_channel";
    
    Slim::Utils::Timers::setTimer(
        undef,  # no specific client
        time() + NOWPLAYING_POLL_INTERVAL,
        sub {
            $class->pollNowPlaying($normalized_channel);
        },
        $timer_id
    );
    
    # Also fetch immediately
    $class->pollNowPlaying($normalized_channel);
}

sub stopNowPlayingPolling {
    my ($class, $channel_name) = @_;
    
    return unless $channel_name;
    
    my $normalized_channel = $class->normalizeChannelName($channel_name);
    return unless $normalized_channel;
    
    $log->debug("Stopping nowplaying polling for: $normalized_channel");
    
    my $timer_id = "nowplaying_$normalized_channel";
    Slim::Utils::Timers::killTimers(undef, $timer_id);
}

sub pollNowPlaying {
    my ($class, $normalized_channel) = @_;
    
    return unless $normalized_channel;
    
    $log->debug("Polling nowplaying for: $normalized_channel");
    
    # Get current cached data for change detection
    my $cache_key = "nowplaying_$normalized_channel";
    my $current_data = $cache->get($cache_key) || {};
    
    # Always fetch fresh data during polling (bypass cache)
    $class->fetchNowPlayingFresh($normalized_channel, sub {
        my $new_data = shift;
        
        # Check if data has changed
        my $has_changed = 0;
        if (!$current_data->{title} && $new_data->{title}) {
            $has_changed = 1;
        } elsif ($current_data->{title} && $new_data->{title} && 
                 $current_data->{title} ne $new_data->{title}) {
            $has_changed = 1;
        } elsif ($current_data->{artist} && $new_data->{artist} && 
                 $current_data->{artist} ne $new_data->{artist}) {
            $has_changed = 1;
        }
        
        if ($has_changed) {
            $log->info("Track changed for $normalized_channel: " . 
                      ($new_data->{title} || 'Unknown') . " by " . 
                      ($new_data->{artist} || 'Unknown'));
            
            # Update cache with new data
            $cache->set($cache_key, $new_data, NOWPLAYING_CACHE_TIMEOUT);
            
            # Notify active players about the change
            $class->notifyPlayersOfMetadataChange($normalized_channel, $new_data);
        }
        
        # Schedule next poll
        my $timer_id = "nowplaying_$normalized_channel";
        Slim::Utils::Timers::setTimer(
            undef,
            time() + NOWPLAYING_POLL_INTERVAL,
            sub {
                $class->pollNowPlaying($normalized_channel);
            },
            $timer_id
        );
    });
}

sub getNowPlaying {
    my ($class, $channel_name, $cb) = @_;
    
    return $cb->({}) unless $channel_name;
    
    my $normalized_channel = $class->normalizeChannelName($channel_name);
    return $cb->({}) unless $normalized_channel;
    
    # Try to get from cache first, otherwise fetch fresh
    my $cache_key = "nowplaying_$normalized_channel";
    my $cached = $cache->get($cache_key);
    
    if ($cached && $cached->{title}) {
        $log->debug("Returning cached nowplaying for: $normalized_channel");
        return $cb->($cached);
    }
    
    # Fetch fresh data
    $class->fetchNowPlaying($normalized_channel, $cb);
}

1;
