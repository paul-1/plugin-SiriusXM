package Plugins::SiriusXM::Proxy;

use strict;
use warnings;

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);
use File::Spec;
use File::Basename qw(dirname);
use Proc::Background;

my $log = logger('plugin.siriusxm');
my $prefs = preferences('plugin.siriusxm');

# Global proxy process handle
my $proxyProcess;

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

sub scan_inc_dirs {
    my @inc = @_;

    my @required_dirs = qw(CPAN Slim);
    my $lib_dir = 'lib';
    my $lib_readme = 'lib/README';

    my (@filtered, @found_subs, @both_cpan_and_lib);
    my %seen_combined;

    foreach my $dir (grep { $_ !~ /Plugin/i } @inc) {
        next unless -d $dir;
        my %has;
        my $found = 0;

        # Check for required subdirectories
        foreach my $subdir (@required_dirs) {
            my $full_path = "$dir/$subdir";
            if (-d $full_path) {
                $has{$subdir} = 1;
                push @found_subs, $full_path unless $seen_combined{$full_path}++;
                $found = 1;
            }
        }

        # Check for required file lib/README, collect just 'lib' directory
        my $lib_path = "$dir/$lib_dir";
        if (-d $lib_path && -f "$lib_path/README") {
            $has{$lib_dir} = 1;
            push @found_subs, $lib_path unless $seen_combined{$lib_path}++;
            $found = 1;
        }

        if ($found && !$seen_combined{$dir}++) {
            push @filtered, $dir;
        }

        if ($has{CPAN} && $has{$lib_dir}) {
            push @both_cpan_and_lib, $dir unless $seen_combined{"both:$dir"}++;
        }
    }

    my @combined = (@filtered, @found_subs);
    return (\@combined, \@both_cpan_and_lib);
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
    my ($newinc, $lmsroot) = scan_inc_dirs(@INC);
    my $inc_path = join(' -I', @$newinc);

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
        '-p', $port,
        '--lmsroot', @$lmsroot
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
