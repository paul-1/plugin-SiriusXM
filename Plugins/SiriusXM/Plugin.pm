package Plugins::SiriusXM::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);

use Plugins::SiriusXM::API;
use Plugins::SiriusXM::ProtocolHandler;
use Plugins::SiriusXM::Settings;

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
        quality => 'medium',
        helper_path => '/usr/local/bin/siriusxm-perl',
    });
    
    # Initialize the API module
    Plugins::SiriusXM::API->init();
    
    # Register protocol handler
    Slim::Player::ProtocolHandlers->registerHandler(
        sxm => 'Plugins::SiriusXM::ProtocolHandler'
    );
    
    # Add to music services menu
    Slim::Menu::TrackInfo->registerInfoProvider( siriusxm => (
        parent => 'moreinfo',
        func   => \&trackInfoMenu,
    ));
    
    # Initialize settings
    Plugins::SiriusXM::Settings->new();
    
    $class->SUPER::initPlugin(
        feed   => \&handleFeed,
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
    
    # Clean up API connections
    Plugins::SiriusXM::API->cleanup();
    
    $class->SUPER::shutdownPlugin();
}

sub handleFeed {
    my ($client, $cb, $args) = @_;
    
    $log->debug("Handling feed request");
    
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
    
    # Check if helper application is available
    unless (-x $prefs->get('helper_path')) {
        $cb->({
            items => [{
                name => string('PLUGIN_SIRIUSXM_ERROR_HELPER_NOT_FOUND'),
                type => 'text',
            }]
        });
        return;
    }
    
    # Get channels from API
    Plugins::SiriusXM::API->getChannels($client, sub {
        my $channels = shift;
        
        if (!$channels || !@$channels) {
            $cb->({
                items => [{
                    name => string('PLUGIN_SIRIUSXM_ERROR_LOGIN_FAILED'),
                    type => 'text',
                }]
            });
            return;
        }
        
        my @items = map {
            {
                name => $_->{name},
                type => 'audio',
                url  => 'sxm://' . $_->{id},
                icon => $_->{logo} || 'plugins/SiriusXM/html/images/siriusxm.png',
                on_select => 'play',
            }
        } @$channels;
        
        $cb->({
            items => \@items
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
    return 'plugins/SiriusXM/html/images/siriusxm.png';
}

sub playerMenu {
    shift->can('nonSNApps') ? undef : 'RADIO';
}

1;