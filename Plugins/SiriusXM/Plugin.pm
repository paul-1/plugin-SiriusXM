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

# Add local lib directory to @INC for Proc::Background
BEGIN {
    my $libdir = File::Spec->catdir(dirname(__FILE__), 'lib');
    unshift @INC, $libdir if -d $libdir;
}

# Try to load Proc::Background, fall back to basic fork if not available
my $use_proc_background = 0;
eval {
    require Proc::Background;
    Proc::Background->import();
    $use_proc_background = 1;
};
if ($@) {
    $log->warn("Proc::Background not available, using basic process management: $@");
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
        port => '9999',
        region => 'US'
    });
    

    
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
    my $max_files = 5;
    
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

sub isPortAvailable {
    my ($class, $port) = @_;
    
    # Try to bind to the port to check if it's available
    eval {
        require IO::Socket::INET;
        my $socket = IO::Socket::INET->new(
            LocalPort => $port,
            Proto     => 'tcp',
            ReuseAddr => 1,
            Listen    => 1,
            Timeout   => 1
        );
        if ($socket) {
            $socket->close();
            return 1;  # Port is available
        }
        return 0;  # Port is not available
    };
    if ($@) {
        $log->warn("Could not check port availability: $@");
        return 1;  # Assume available if we can't check
    }
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
    
    # Build proxy command using --env flag and server's perl with logging
    my @proxy_cmd = (
        $perl_exe,
        "-I$inc_path",
        $proxy_path,
        '-e',  # Use environment variables
        '-p', $port,
    );
    
    # Only add verbosity flag if log level is not OFF
    if ($proxy_log_level ne 'OFF') {
        push @proxy_cmd, '-v', $proxy_log_level;
    }
    
    # Add region parameter for Canada
    if ($region eq 'Canada') {
        push @proxy_cmd, '-ca';
    }
    
    $log->info("Starting proxy: " . join(' ', @proxy_cmd));
    $log->info("Proxy output will be logged to: $log_file");
    
    # Start proxy as background process
    eval {
        if ($use_proc_background) {
            # Use Proc::Background if available
            # Note: Proc::Background doesn't directly support output redirection,
            # so we'll redirect via shell
            my $cmd_with_redirect = join(' ', map { "'$_'" } @proxy_cmd) . " >> '$log_file' 2>&1";
            $proxyProcess = Proc::Background->new('sh', '-c', $cmd_with_redirect);
            
            if ($proxyProcess->alive()) {
                $log->info("Proxy process started successfully on port $port using Proc::Background (PID: " . $proxyProcess->pid . ")");
                $log->info("Proxy output redirected to: $log_file");
                # Give the proxy a moment to start up
                sleep(2);
                return 1;
            } else {
                $log->error("Failed to start proxy process with Proc::Background");
                $proxyProcess = undef;
                return 0;
            }
        } else {
            # Fall back to basic fork with output redirection
            my $pid = fork();
            
            if (!defined $pid) {
                $log->error("Fork failed: $!");
                return 0;
            } elsif ($pid == 0) {
                # Child process - redirect output and exec the proxy
                
                # Redirect STDOUT to log file
                if (!open(STDOUT, '>>', $log_file)) {
                    die "Cannot redirect STDOUT to $log_file: $!";
                }
                
                # Redirect STDERR to log file as well
                if (!open(STDERR, '>>', $log_file)) {
                    die "Cannot redirect STDERR to $log_file: $!";
                }
                
                # Disable buffering for immediate log output
                $| = 1;
                select(STDERR); $| = 1; select(STDOUT);
                
                exec(@proxy_cmd) or die "exec failed: $!";
            } else {
                # Parent process - store PID
                $proxyPid = $pid;
                $log->info("Proxy process started successfully on port $port using fork (PID: $pid)");
                $log->info("Proxy output redirected to: $log_file");
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
    
    if ($use_proc_background && $proxyProcess && $proxyProcess->alive()) {
        $log->info("Stopping proxy process (Proc::Background, PID: " . $proxyProcess->pid . ")");
        
        eval {
            # Send TERM signal first for graceful shutdown
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
                
                # Wait a bit more for the kill to take effect
                my $kill_timeout = 2;
                while ($kill_timeout > 0 && $proxyProcess->alive()) {
                    sleep(1);
                    $kill_timeout--;
                }
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
    
    if ($use_proc_background) {
        return $proxyProcess && $proxyProcess->alive();
    } else {
        return $proxyPid && kill(0, $proxyPid);
    }
}

1;
