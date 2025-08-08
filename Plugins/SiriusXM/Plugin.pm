package Plugins::SiriusXM::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);
use File::Spec;
use File::Basename qw(dirname);
use Proc::Background;

use Plugins::SiriusXM::API;
use Plugins::SiriusXM::Settings;
use Plugins::SiriusXM::ProtocolHandler;

my $prefs = preferences('plugin.siriusxm');
my $log = Slim::Utils::Log->addLogCategory({
    'category' => 'plugin.siriusxm',
    'defaultLevel' => 'INFO',
    'description' => 'PLUGIN_SIRIUSXM',
});

# Global proxy process handle
my $proxyProcess;

# Plugin metadata
sub getDisplayName { 'PLUGIN_SIRIUSXM' }

sub initPlugin {
    my $class = shift;
    
    $log->info("Initializing SiriusXM Plugin");
    
    # Initialize preferences with defaults
    $prefs->init({
        username => '',
        password => '',
        quality => 'high',
        port => '9999',
        region => 'US',
        enable_metadata => 0
    });
    

    
    # Start the proxy process
    $class->startProxy();
    
    # Register protocol handler for sxm: URLs
    Slim::Player::ProtocolHandlers->registerHandler(
        sxm => 'Plugins::SiriusXM::ProtocolHandler'
    );
    
    # Initialize player event callbacks for metadata tracking
    Plugins::SiriusXM::ProtocolHandler->initPlayerEvents();
    
    # Initialize the API module
    Plugins::SiriusXM::API->init();
    
    # Add to music services menu
    Slim::Menu::TrackInfo->registerInfoProvider( siriusxm => (
        parent => 'moreinfo',
        func   => \&trackInfoMenu,
    ));
    
    # Initialize settings
    Plugins::SiriusXM::Settings->new();
    
    $class->SUPER::initPlugin(
        feed   => \&toplevelMenu,
        tag    => 'siriusxm',
        menu   => 'radios',
        is_app => 1,
        weight => 10,
    );
    
    $log->info("SiriusXM Plugin initialized successfully");
}

sub shutdownPlugin {
    my $class = shift;
    
    $log->info("Shutting down SiriusXM Plugin");
    
    # Clean up player event subscriptions and timers
    Plugins::SiriusXM::ProtocolHandler->cleanupPlayerEvents();
    
    # Stop the proxy process
    $class->stopProxy();
    
    # Clean up API connections
    Plugins::SiriusXM::API->cleanup();
    
}

sub validateHLSSupport {
    my $class = shift;
    
    $log->debug("Validating HLS stream support requirements");
    
    # Check for HLS mimetype support
    my $hlssupported = Slim::Music::Info::mimeToType('application/vnd.apple.mpegurl');
    
    if ($hlssupported) {
        $log->info("HLS mimetype support found - HLS streams supported");
        return 1;
    } else {
        $log->warn("HLS mimetype support not found - HLS streams may not be supported");
        return 0;
    }
}

sub toplevelMenu {
    my ($client, $cb, $args) = @_;
    
    $log->debug("Building top level menu");
    
    # Check HLS support
    unless (__PACKAGE__->validateHLSSupport()) {
        $cb->({
            items => [{
                name => string('PLUGIN_SIRIUSXM_ERROR_HLS_UNSUPPORTED'),
                type => 'text',
            }]
        });
        return;
    }
    
    # Check if credentials are configured
    unless ($prefs->get('username') && $prefs->get('password')) {
        $cb->({
            items => [{
                name => string('PLUGIN_SIRIUSXM_ERROR_NO_CREDENTIALS'),
                type => 'text',
            }]
        });
        return;
    }
    
    # Build simplified top-level menu structure
    my @menu_items = (
        {
            name => string('PLUGIN_SIRIUSXM_MENU_SEARCH'),
            type => 'search',
            url  => \&searchMenu,
            icon => 'plugins/SiriusXM/html/images/SiriusXMLogo.png',
        },
        {
            name => string('PLUGIN_SIRIUSXM_MENU_FAVORITES'),
            type => 'opml',
            url  => \&favoritesMenu,
            icon => 'plugins/SiriusXM/html/images/SiriusXMLogo.png',
        },
        {
            name => string('PLUGIN_SIRIUSXM_MENU_BROWSE_BY_GENRE'),
            type => 'opml',
            url  => \&browseByGenre,
            icon => 'plugins/SiriusXM/html/images/SiriusXMLogo.png',
        }
    );
    
    $cb->({
        items => \@menu_items
    });
}

sub searchMenu {
    my ($client, $cb, $args, $pt) = @_;
    
    my $search_term = $pt->[0] || $args->{search} || '';
    
    $log->debug("Search menu called with term: $search_term");
    
    if (!$search_term) {
        # Return empty search menu
        $cb->({
            items => [{
                name => string('PLUGIN_SIRIUSXM_MENU_SEARCH'),
                type => 'search',
                url  => \&searchMenu,
            }]
        });
        return;
    }
    
    # Search channels via API
    Plugins::SiriusXM::API->searchChannels($client, $search_term, sub {
        my $results = shift;
        
        if (!$results || !@$results) {
            $cb->({
                items => [{
                    name => "No results found for '$search_term'",
                    type => 'text',
                }]
            });
            return;
        }
        
        $cb->({
            items => $results
        });
    });
}

sub browseByGenre {
    my ($client, $cb, $args) = @_;
    
    $log->debug("Browse by genre menu");
    
    # Get channels organized by genre from API
    Plugins::SiriusXM::API->getChannels($client, sub {
        my $menu_items = shift;
        
        if (!$menu_items || !@$menu_items) {
            $cb->({
                items => [{
                    name => string('PLUGIN_SIRIUSXM_ERROR_LOGIN_FAILED'),
                    type => 'text',
                }]
            });
            return;
        }
        
        $cb->({
            items => $menu_items
        });
    });
}

sub favoritesMenu {
    my ($client, $cb, $args) = @_;
    
    $log->debug("Favorites menu");
    
    # Get favorite channels from API
    Plugins::SiriusXM::API->getFavoriteChannels($client, sub {
        my $favorite_items = shift;
        
        if (!$favorite_items || !@$favorite_items) {
            $cb->({
                items => [{
                    name => "No favorite channels found. Mark channels as favorites in your SiriusXM account to see them here.",
                    type => 'text',
                }]
            });
            return;
        }
        
        $cb->({
            items => $favorite_items
        });
    });
}

sub trackInfoMenu {
    my ($client, $url, $track, $remoteMeta) = @_;
    
    return unless $url =~ /^sxm:/;
    
    my $items = [];
    
    if ($remoteMeta && $remoteMeta->{title}) {
        push @$items, {
            name => $remoteMeta->{title},
            type => 'text',
        };
    }
    
    return $items;
}

sub getIcon {
    my ($class, $url) = @_;
    return 'plugins/SiriusXM/html/images/SiriusXMLogo.png';
}

sub playerMenu {
    shift->can('nonSNApps') ? undef : 'RADIO';
}

sub startProxy {
    my $class = shift;
    
    my $username = $prefs->get('username');
    my $password = $prefs->get('password');
    my $port = $prefs->get('port') || '9999';
    my $region = $prefs->get('region') || 'US';
    
    # Check if credentials are configured
    unless ($username && $password) {
        $log->warn("Cannot start proxy: username and password not configured");
        return 0;
    }
    
    # Stop existing proxy if running
    $class->stopProxy();
    
    # Get path to proxy script
    my $plugin_dir = dirname(__FILE__);
    my $proxy_path = File::Spec->catfile($plugin_dir, 'Bin', 'sxm.pl');
    
    unless (-f $proxy_path && -r $proxy_path) {
        $log->error("Proxy script not found or not readable: $proxy_path");
        return 0;
    }
    
    # Set environment variables for the proxy
    $ENV{SXM_USER} = $username;
    $ENV{SXM_PASS} = $password;
    
    # Get the perl executable path and @INC from the server process
    my $perl_exe = $^X;
    my $inc_path = join(':', @INC);
    
    # Build proxy command using --env flag and server's perl
    my @proxy_cmd = (
        $perl_exe,
        "-I$inc_path",
        $proxy_path,
        '-e',  # Use environment variables
        '-p', $port
    );
    
    # Add region parameter for Canada
    if ($region eq 'Canada') {
        push @proxy_cmd, '-ca';
    }
    
    $log->info("Starting proxy: " . join(' ', @proxy_cmd));
    
    # Start proxy as background process
    eval {
        # Use Proc::Background if available
        $proxyProcess = Proc::Background->new(@proxy_cmd);
      
        if ($proxyProcess->alive()) {
            $log->info("Proxy process started successfully on port $port using Proc::Background");
            # Give the proxy a moment to start up
            sleep(2);
            return 1;
        } else {
            $log->error("Failed to start proxy process with Proc::Background");
            $proxyProcess = undef;
            return 0;
        }
    };
    
    if ($@) {
        $log->error("Error starting proxy: $@");
        $proxyProcess = undef;
        return 0;
    }
}

sub stopProxy {
    my $class = shift;
    
    return unless $proxyProcess;
 
    $log->info("Stopping proxy process (Proc::Background)");
        
    eval {
        $proxyProcess->die();
        
        # Wait up to 5 seconds for clean shutdown
        my $timeout = 5;
        while ($timeout > 0 && $proxyProcess->alive()) {
            sleep(1);
            $timeout--;
        }
            
        # Force kill if still running
        if ($proxyProcess->alive()) {
            $log->warn("Proxy did not shut down cleanly, force killing");
            $proxyProcess->kill('KILL');
        }
            
        $log->info("Proxy process stopped");
    };
        
    if ($@) {
        $log->error("Error stopping proxy: $@");
    }
        
    $proxyProcess = undef;

    # Clean up environment variables
    delete $ENV{SXM_USER};
    delete $ENV{SXM_PASS};
}

sub isProxyRunning {
    my $class = shift;
    
    return $proxyProcess && $proxyProcess->alive();
}

1;
