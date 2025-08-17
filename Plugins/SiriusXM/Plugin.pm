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
use Plugins::SiriusXM::TrackDurationDB;

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
        enable_metadata => 0,
        proxy_log_level => 'OFF'
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
    
    # Initialize track duration database
    Plugins::SiriusXM::TrackDurationDB->init();
    
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
    
    # Shutdown track duration database
    Plugins::SiriusXM::TrackDurationDB->shutdown();
    
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

sub getLogFilePath {
    my $class = shift;

    # Get LMS log directory path
    my $log_dir;
    eval {
        # Try to get log directory from server preferences
        require Slim::Utils::OSDetect;
        $log_dir = Slim::Utils::OSDetect::dirsFor('log');
    };
    if ($@ || !$log_dir) {
        # If $log_dir is not set, use the operating system's TMPDIR
        $log_dir = $ENV{TMPDIR} || '/tmp';
        $log->warn("Could not determine LMS log directory, using TMPDIR: $log_dir");
    }

    my $log_file = File::Spec->catfile($log_dir, 'sxm-proxy.log');
    $log->debug("Proxy log file path: $log_file");

    return $log_file;
}

sub rotateLogFile {
    my ($class, $log_file) = @_;

    return unless -f $log_file;

    my $max_size = 10 * 1024 * 1024; # 10MB
    my $max_files = 3;

    my @stat = stat($log_file);
    my $size = $stat[7] || 0;

    if ($size > $max_size) {
        $log->info("Rotating proxy log file (size: $size bytes)");

        # Rotate existing log files
        for my $i (reverse(1..$max_files-1)) {
            my $old_file = "$log_file.$i";
            my $new_file = "$log_file." . ($i + 1);

            if (-f $old_file) {
                if ($i == $max_files-1) {
                    # Delete the oldest file
                    unlink($old_file);
                    $log->debug("Deleted oldest log file: $old_file");
                } else {
                    # Rename to next number
                    rename($old_file, $new_file);
                    $log->debug("Rotated $old_file -> $new_file");
                }
            }
        }

        # Move current log to .1
        rename($log_file, "$log_file.1");
        $log->debug("Rotated current log file to $log_file.1");
    }
}

sub startProxy {
    my $class = shift;
    
    my $username = $prefs->get('username');
    my $password = $prefs->get('password');
    my $port = $prefs->get('port') || '9999';
    my $region = $prefs->get('region') || 'US';
    my $quality = $prefs->get('quality') || 'high';
    
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
    my $inc_path = join(' -I ', @INC);

    # Get log level for proxy from preferences
    my $proxy_log_level = $prefs->get('proxy_log_level') || 'INFO';

    # Get log file path and ensure log rotation
    my $log_file = $class->getLogFilePath();

    # Ensure log directory exists and is writable
    my $log_dir = dirname($log_file);
    unless (-d $log_dir) {
        eval { 
            require File::Path;
            File::Path::make_path($log_dir);
        };
        if ($@) {
            $log->warn("Could not create log directory $log_dir: $@");
            $log_file = File::Spec->catfile('/tmp', 'sxm-proxy.log');
            $log->warn("Using fallback log file: $log_file");
        }
    }

    unless (-w $log_dir) {
        $log->warn("Log directory $log_dir is not writable, using fallback");
        $log_file = File::Spec->catfile('/tmp', 'sxm-proxy.log');
    }

    $class->rotateLogFile($log_file);

    # Build proxy command using
    my @proxy_cmd = (
        $perl_exe,
        "-I $inc_path",
        $proxy_path,
        '-e',  # Use environment variables
        '-p', $port
    );
    
    if ($quality eq 'medium' ) {
        push @proxy_cmd, '--quality', 'Med';
    } elsif ($quality eq 'low' ) {
        push @proxy_cmd, '--quality', 'Low';
    }

    # Add region parameter for Canada
    if ($region eq 'Canada') {
        push @proxy_cmd, '-ca';
    }

    # Only add verbosity flag if log level is not OFF
    if ($proxy_log_level ne 'OFF') {
        push @proxy_cmd, '-v', $proxy_log_level;
        push @proxy_cmd, '--logfile', $log_file;
    }
    
    $log->info("Starting proxy: " . join(' ', @proxy_cmd));
    $log->info("Proxy output will be logged to: $log_file");
    
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

sub getProxyPid {
    my $class = shift;
    
    return unless $proxyProcess;

    my $pid = $proxyProcess->pid();
    $log->debug($pid);

    if($pid) {
        return $pid;
    }
    
    return undef;
}

1;
