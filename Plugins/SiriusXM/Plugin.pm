package Plugins::SiriusXM::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);
use File::Spec;
use File::Basename qw(dirname);

use Plugins::SiriusXM::API;
use Plugins::SiriusXM::Settings;

my $prefs = preferences('plugin.siriusxm');
my $log = Slim::Utils::Log->addLogCategory({
    'category' => 'plugin.siriusxm',
    'defaultLevel' => 'INFO',
    'description' => 'PLUGIN_SIRIUSXM',
});

# Try to load Proc::Simple, fall back to basic fork if not available
my $use_proc_simple = 0;
eval {
    require Proc::Simple;
    Proc::Simple->import();
    $use_proc_simple = 1;
};
if ($@) {
    $log->warn("Proc::Simple not available, using basic process management");
}

# Global proxy process handle
my $proxyProcess;
my $proxyPid;

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
        port => '9999'
    });
    
    # Validate HLS stream support requirements
    unless ($class->validateHLSSupport()) {
        $log->error("SiriusXM Plugin cannot initialize: HLS requirements not met");
        return;
    }
    
    # Start the proxy process
    $class->startProxy();
    
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
    
    # Stop the proxy process
    $class->stopProxy();
    
    # Clean up API connections
    Plugins::SiriusXM::API->cleanup();
    
}

sub validateHLSSupport {
    my $class = shift;
    
    $log->debug("Validating HLS stream support requirements");
    
    # Check if PlayHLS plugin is available and version is adequate
    my $playHLS_available = 0;
    eval {
        require Plugins::PlayHLS::Plugin;
        my $version = $Plugins::PlayHLS::Plugin::VERSION || '0.0.0';
        
        # Simple version comparison for v1.1 or later
        my ($major, $minor) = split(/\./, $version);
        $major ||= 0; $minor ||= 0;
        
        if ($major > 1 || ($major == 1 && $minor >= 1)) {
            $playHLS_available = 1;
            $log->info("PlayHLS plugin v$version found - HLS support available");
        } else {
            $log->warn("PlayHLS plugin v$version found but v1.1+ required");
        }
    };
    
    if ($@) {
        $log->warn("PlayHLS plugin not found: $@");
    }
    
    # Check if FFmpeg is available in the system
    my $ffmpeg_available = 0;
    my $ffmpeg_path = `which ffmpeg 2>/dev/null`;
    chomp($ffmpeg_path);
    
    if ($ffmpeg_path && -x $ffmpeg_path) {
        $ffmpeg_available = 1;
        $log->info("FFmpeg found at: $ffmpeg_path");
    } else {
        $log->warn("FFmpeg not found in system PATH");
    }
    
    # Both requirements must be met
    if (!$playHLS_available || !$ffmpeg_available) {
        my @missing = ();
        push @missing, "PlayHLS v1.1+" unless $playHLS_available;
        push @missing, "FFmpeg" unless $ffmpeg_available;
        
        $log->error("Missing requirements for SiriusXM plugin: " . join(", ", @missing));
        return 0;
    }
    
    return 1;
}

sub toplevelMenu {
    my ($client, $cb, $args) = @_;
    
    $log->debug("Building top level menu");
    
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
    
    $log->info("Starting proxy: " . join(' ', @proxy_cmd));
    
    # Start proxy as background process
    eval {
        if ($use_proc_simple) {
            # Use Proc::Simple if available
            $proxyProcess = Proc::Simple->new();
            $proxyProcess->start(@proxy_cmd);
            
            if ($proxyProcess->poll()) {
                $log->info("Proxy process started successfully on port $port using Proc::Simple");
                # Give the proxy a moment to start up
                sleep(2);
                return 1;
            } else {
                $log->error("Failed to start proxy process with Proc::Simple");
                $proxyProcess = undef;
                return 0;
            }
        } else {
            # Fall back to basic fork
            my $pid = fork();
            
            if (!defined $pid) {
                $log->error("Fork failed: $!");
                return 0;
            } elsif ($pid == 0) {
                # Child process - exec the proxy
                exec(@proxy_cmd) or die "exec failed: $!";
            } else {
                # Parent process - store PID
                $proxyPid = $pid;
                $log->info("Proxy process started successfully on port $port using fork (PID: $pid)");
                # Give the proxy a moment to start up
                sleep(2);
                return 1;
            }
        }
    };
    
    if ($@) {
        $log->error("Error starting proxy: $@");
        $proxyProcess = undef;
        $proxyPid = undef;
        return 0;
    }
}

sub stopProxy {
    my $class = shift;
    
    if ($use_proc_simple && $proxyProcess && $proxyProcess->poll()) {
        $log->info("Stopping proxy process (Proc::Simple)");
        
        eval {
            $proxyProcess->kill();
            
            # Wait up to 5 seconds for clean shutdown
            my $timeout = 5;
            while ($timeout > 0 && $proxyProcess->poll()) {
                sleep(1);
                $timeout--;
            }
            
            # Force kill if still running
            if ($proxyProcess->poll()) {
                $log->warn("Proxy did not shut down cleanly, force killing");
                $proxyProcess->kill('KILL');
            }
            
            $log->info("Proxy process stopped");
        };
        
        if ($@) {
            $log->error("Error stopping proxy: $@");
        }
        
        $proxyProcess = undef;
    } elsif ($proxyPid) {
        $log->info("Stopping proxy process (fork, PID: $proxyPid)");
        
        eval {
            # Send TERM signal first
            kill('TERM', $proxyPid);
            
            # Wait up to 5 seconds for clean shutdown
            my $timeout = 5;
            while ($timeout > 0) {
                my $result = waitpid($proxyPid, 1); # WNOHANG
                last if $result > 0; # Process has exited
                sleep(1);
                $timeout--;
            }
            
            # Force kill if still running
            if (kill(0, $proxyPid)) { # Check if process still exists
                $log->warn("Proxy did not shut down cleanly, force killing");
                kill('KILL', $proxyPid);
                waitpid($proxyPid, 0); # Wait for cleanup
            }
            
            $log->info("Proxy process stopped");
        };
        
        if ($@) {
            $log->error("Error stopping proxy: $@");
        }
        
        $proxyPid = undef;
    }
    
    # Clean up environment variables
    delete $ENV{SXM_USER};
    delete $ENV{SXM_PASS};
}

sub isProxyRunning {
    my $class = shift;
    
    if ($use_proc_simple) {
        return $proxyProcess && $proxyProcess->poll();
    } else {
        return $proxyPid && kill(0, $proxyPid);
    }
}

1;
