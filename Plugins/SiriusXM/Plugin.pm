package Plugins::SiriusXM::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);

use Plugins::SiriusXM::API;
use Plugins::SiriusXM::Settings;
use Plugins::SiriusXM::ProtocolHandler;
use Plugins::SiriusXM::Proxy;

my $prefs = preferences('plugin.siriusxm');
my $log = Slim::Utils::Log->addLogCategory({
    'category' => 'plugin.siriusxm',
    'defaultLevel' => 'INFO',
    'description' => 'PLUGIN_SIRIUSXM',
});

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
        enable_metadata => 0,
        proxy_log_level => 'OFF'
    });
    
 
    # Start the proxy process
    Plugins::SiriusXM::Proxy->startProxy();
    
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
    Plugins::SiriusXM::Proxy->stopProxy();
    
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
            name => string('PLUGIN_SIRIUSXM_MENU_BROWSE_BY_CHANNEL'),
            type => 'opml',
            url  => \&browseByChannel,
            icon => 'plugins/SiriusXM/html/images/SiriusXMLogo.png',
        },
        {
            name => string('PLUGIN_SIRIUSXM_MENU_BROWSE_BY_GENRE'),
            type => 'opml',
            url  => \&browseByGenre,
            icon => 'plugins/SiriusXM/html/images/SiriusXMLogo.png',
        },
        {
            name => string('PLUGIN_SIRIUSXM_MENU_SEARCH'),
            type => 'search',
            url  => \&searchMenu,
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

sub browseByChannel {
    my ($client, $cb, $args) = @_;
    
    $log->debug("Browse by channel number menu");
    
    # Get channels sorted by channel number from API
    Plugins::SiriusXM::API->getChannelsSortedByNumber($client, sub {
        my $channel_items = shift;
        
        if (!$channel_items || !@$channel_items) {
            $cb->({
                items => [{
                    name => string('PLUGIN_SIRIUSXM_ERROR_LOGIN_FAILED'),
                    type => 'text',
                }]
            });
            return;
        }
        
        $cb->({
            items => $channel_items
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

1;
