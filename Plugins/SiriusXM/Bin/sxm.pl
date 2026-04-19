#!/usr/bin/perl

=head1 NAME

sxm.pl - SiriusXM proxy server

=head1 SYNOPSIS

    perl sxm.pl username password [options]
    
    Options:
        -l, --list              List available channels
        -p, --port PORT         Server port (default: 9999)
        -ca, --canada           Use Canadian region
        -e, --env               Use SXM_USER and SXM_PASS environment variables
        -v, --verbose LEVEL     Set logging level (ERROR, WARN, INFO, DEBUG, TRACE)
        -q, --quality QUALITY   Audio quality: High (256k, default), Med (96k), Low (64k)
        --segment-drop NUM      Number of segments to drop from first playlist (default: 0, max: 30)
        --logfile FILE          Log file location (default: /var/log/sxm-proxy.log)
        --cookiefile FILE       Cookie storage file (default: <cache_dir>/siriusxm-cookies.txt)
        --lmsroot DIR           Specify LMS root directory (Not needed when running inside LMS)
        -h, --help              Show this help message

=head1 DESCRIPTION

This script creates a server that serves HLS streams for SiriusXM channels.
It provides the same functionality as the Python sxm.py script with enhanced
logging and error handling.

Usage examples:
    perl sxm.pl myuser mypass -p 8888
    perl sxm.pl myuser mypass -l
    perl sxm.pl user pass -e -p 8888 --verbose DEBUG
    perl sxm.pl user pass --lmsroot /opt/lms -p 8888
    perl sxm.pl user pass -p 8888 --cookiefile /path/to/cookies.txt

In a player that supports HLS (QuickTime, VLC, ffmpeg, etc) you can access
a channel at http://127.0.0.1:8888/channel.m3u8 where "channel" is the
channel name, ID, or Sirius channel number.

=cut

require 5.010;
use strict;
use warnings;

use Config;

# LMS service constants (similar to scanner.pl)
use constant SLIM_SERVICE => 0;
use constant SCANNER      => 1;  # Set as scanner to avoid loading full modules.conf
use constant SXMPROXY     => 1;
use constant RESIZER      => 0;
use constant TRANSCODING  => 0;
use constant PERFMON      => 0;
use constant ISWINDOWS    => ( $^O =~ /^m?s?win/i ) ? 1 : 0;
use constant ISACTIVEPERL => ( $Config{cf_email} =~ /ActiveState/i ) ? 1 : 0;
use constant ISMAC        => ( $^O =~ /darwin/i ) ? 1 : 0;
use constant DEBUGLOG     => 1;
use constant INFOLOG      => 1;
use constant STATISTICS   => 0;
use constant SB1SLIMP3SYNC=> 0;
use constant WEBUI        => 0;
use constant HAS_AIO      => 0;
use constant LOCALFILE    => 0;
use constant NOMYSB       => 1;

our $VERSION = '2.0.0';
our $REVISION    = undef;
our $BUILDDATE   = undef;

# @INC is set on Commandline from the LMS server @INC
use Slim::bootstrap;
use Slim::Utils::OSDetect;

# This should only be needed in testing environment, since LMS normally calls with full @INC.
my $libpath;  #This gets set to the LMS root directory for bootstrap.

BEGIN {
    # Early parsing for bootstrap-critical arguments like --lmsroot
    # We need to parse this before LMS bootstrap to set up @INC properly
    my $early_lmsroot;
    
    # Simple early parsing just for --lmsroot (before full GetOptions)
    for my $i (0..$#ARGV) {
        if ($ARGV[$i] eq '--lmsroot' && $i < $#ARGV) {
            $early_lmsroot = $ARGV[$i + 1];
            last;
        } elsif ($ARGV[$i] =~ /^--lmsroot=(.+)$/) {
            $early_lmsroot = $1;
            last;
        }
    }
    $libpath = $early_lmsroot;
}    

# Bootstrap must be in a separate BEGIN block after the modules are useable
BEGIN {

    # Load essential modules for logging system to work, but more importantly, set the @INC.
    Slim::bootstrap->loadModules([qw(version Time::HiRes Log::Log4perl JSON::XS)], [], $libpath);

};

# End of LMS Bootstrap code.

# Core modules
use Getopt::Long qw(:config bundling);
use Pod::Usage;
use POSIX qw(strftime);
use Time::HiRes qw(time);
use File::Basename;
use File::Path qw(make_path);
use File::Spec;
use Encode qw(decode encode);

# Network and HTTP modules  
use LWP::UserAgent;
use HTTP::Request;
use HTTP::Response;
use HTTP::Status qw(:constants);
use HTTP::Daemon;
use HTTP::Cookies;
use URI;
use URI::Escape;
use IO::Select;

# Data handling modules
use JSON::XS;
use MIME::Base64;

# Signal handling
use sigtrap 'handler' => \&signal_handler, qw(INT QUIT TERM);

# LMS logging system
use Log::Log4perl qw(get_logger);
use Slim::Utils::Prefs;

#=============================================================================
# Global variables and constants
#=============================================================================

# Logging levels
use constant {
    LOG_ERROR => 0,
    LOG_WARN  => 1, 
    LOG_INFO  => 2,
    LOG_DEBUG => 3,
    LOG_TRACE => 4,
};

# Global configuration
our %CONFIG = (
    username     => '',
    password     => '',
    port         => 9999,
    list         => 0,
    canada       => 0,
    env          => 0,
    verbose      => LOG_INFO,
    help         => 0,
    quality      => 'High',
    logfile      => '/var/log/sxm-proxy.log',
    cookiefile   => undef,  # Will be set to default in init_logging if not specified
    segment_drop => 0,
);

# Global state
my $HTTP_DAEMON;
my $SIRIUS_XM;
our $RUNNING = 1;
my $LOGGER;

#=============================================================================
# Logging functions
#=============================================================================

#=============================================================================
# Logging functions
#=============================================================================

sub init_logging {
    my ($verbose_level, $logfile) = @_;
    
    # Map our verbose level to Log4Perl levels
    my @level_mapping = qw(ERROR WARN INFO DEBUG DEBUG);
    my $log_level = $level_mapping[$verbose_level] || 'INFO';
    
    # Set up default cookie file if not specified
    if (!defined $CONFIG{cookiefile}) {
        # Use system temp directory as fallback
        my $temp_dir = $ENV{TMPDIR} || $ENV{TEMP} || '/tmp';
        $CONFIG{cookiefile} = File::Spec->catfile($temp_dir, 'siriusxm', 'sxm');
    }
    
    # Ensure directory for cookiefile exists
    if ($CONFIG{cookiefile}) {
        my $cookie_dir = dirname($CONFIG{cookiefile});
        if (!-d $cookie_dir) {
            eval {
                make_path($cookie_dir, { mode => 0755 });
            };
            if ($@) {
                # Use warn here since logging system is not yet initialized
                warn "Warning: Could not create cookie directory $cookie_dir: $@\n";
            }
        }
    }
    
    # Determine log file location
    if (!$logfile || $logfile eq '/var/log/sxmproxy.log') {
        # Use LMS default log directory
        my $log_dir = Slim::Utils::OSDetect::dirsFor('log');
        $logfile = File::Spec->catfile($log_dir, 'sxmproxy.log');
    }
    
    # Parse logfile to extract directory and filename
    my $logdir = dirname($logfile);
    my $logfilename = basename($logfile);
    
    # Create log directory if it doesn't exist
    if (!-d $logdir) {
        eval {
            make_path($logdir, { mode => 0755 });
        };
        if ($@) {
            warn "Warning: Could not create log directory $logdir: $@\n";
            $logfile = undef;  # Disable file logging
        }
    }
    
    my $appenders = "screen";
    # Create Log4Perl configuration compatible with v1.23
    my $log4perl_config = qq{
        log4perl.appender.screen = Log::Log4perl::Appender::Screen
        log4perl.appender.screen.stderr = 1
        log4perl.appender.screen.layout = Log::Log4perl::Layout::PatternLayout
        log4perl.appender.screen.layout.ConversionPattern = [%d{dd.MM.yyyy HH:mm:ss.SSS}] %5p <%c>: %m%n
    };
    
    # Add file appender if logfile is specified
    if ($logfile && -w $logdir) {
        $appenders .= ", logfile";
        $log4perl_config .= qq{
        log4perl.appender.logfile = Log::Log4perl::Appender::File
        log4perl.appender.logfile.filename = $logfile
        log4perl.appender.logfile.mode = append
        log4perl.appender.logfile.layout = Log::Log4perl::Layout::PatternLayout
        log4perl.appender.logfile.layout.ConversionPattern = [%d{dd.MM.yyyy HH:mm:ss.SSS}] %5p %M:%4L: %m%n
        };
    }

    # Set the logger with all appenders in one line
    $log4perl_config = "log4perl.logger.sxm.proxy = $log_level, $appenders\n" . $log4perl_config;

    # Initialize Log4Perl directly (not through LMS wrapper)
    Log::Log4perl->init(\$log4perl_config);    


    # Get logger instance for this process
    $Log::Log4perl::caller_depth++;
    $LOGGER = get_logger('sxm.proxy');
    $Log::Log4perl::caller_depth--;
    $LOGGER->info("SiriusXM Proxy logging initialized with level: $log_level");
    if ($logfile && -w $logdir) {
        $LOGGER->info("File logging enabled: $logfile");
    } else {
        $LOGGER->warn("File logging disabled, using console output only");
    }
    
    # Log cookie file location
    if ($CONFIG{cookiefile}) {
        $LOGGER->info("Cookie file: $CONFIG{cookiefile}");
    }
}

sub log_message {
    my ($level, $message) = @_;

    # Always check if the level should be logged based on CONFIG{verbose}
    return if $level > $CONFIG{verbose};
    
    # If LMS logger is not initialized, fall back to simple print
    if (!$LOGGER) {
        my $timestamp = strftime('%d.%b %Y %H:%M:%S', gmtime);
        my $level_name = qw(ERROR WARN INFO DEBUG TRACE)[$level];
        printf "%s <%s>: %s\n", $timestamp, $level_name, $message;
        return;
    }
    $Log::Log4perl::caller_depth +=2;
    # Use LMS logging system with level mapping
    if ($level == LOG_ERROR) {
        $LOGGER->error($message);
    } elsif ($level == LOG_WARN) {
        $LOGGER->warn($message);
    } elsif ($level == LOG_INFO) {
        $LOGGER->info($message);
    } elsif ($level == LOG_DEBUG) {
        $LOGGER->debug($message);
    } elsif ($level == LOG_TRACE) {
        # Map TRACE to DEBUG since LMS only supports up to DEBUG level
        $LOGGER->debug("[TRACE] $message");
    }
    $Log::Log4perl::caller_depth -=2;
}

sub log_error { log_message(LOG_ERROR, shift) }
sub log_warn  { log_message(LOG_WARN,  shift) }
sub log_info  { log_message(LOG_INFO,  shift) }
sub log_debug { log_message(LOG_DEBUG, shift) }
sub log_trace { log_message(LOG_TRACE, shift) }

# Sanitize sensitive data for safe logging
sub sanitize_for_logging {
    my ($data) = @_;
    
    # Handle different data types
    if (ref($data) eq 'HASH') {
        my %sanitized = %$data;  # Create a copy
        
        # Recursively sanitize hash values
        for my $key (keys %sanitized) {
            if ($key =~ /^password$/i) {
                # Mask password fields
                $sanitized{$key} = '*****';
            } else {
                # Recursively sanitize nested structures
                $sanitized{$key} = sanitize_for_logging($sanitized{$key});
            }
        }
        return \%sanitized;
    }
    elsif (ref($data) eq 'ARRAY') {
        # Recursively sanitize array elements
        return [map { sanitize_for_logging($_) } @$data];
    }
    else {
        # Return scalars as-is
        return $data;
    }
}

#=============================================================================
# Signal handling
#=============================================================================

sub signal_handler {
    my $signal = shift;
    log_info("Received signal $signal, shutting down gracefully...");
    $RUNNING = 0;
    
    if ($HTTP_DAEMON) {
        $HTTP_DAEMON->close();
        log_info("HTTP server closed");
    }
    
    exit(0);
}

sub playlist_size_for_segment_drop {
    my ($segment_drop) = @_;
    $segment_drop //= 0;
    return ($segment_drop <= 15) ? 'SMALL'
         : ($segment_drop <= 30) ? 'MEDIUM'
         : 'LARGE';
}

# Handle SIGPIPE gracefully - ignore broken pipe errors
$SIG{PIPE} = 'IGNORE';

#=============================================================================
# SiriusXM Class
#=============================================================================

package SiriusXM;

use strict;
use warnings;
use POSIX qw(strftime);
use URI;
use URI::Escape;
use LWP::UserAgent;
use HTTP::Cookies;
use HTTP::Request;
use JSON::XS;
use File::Basename;
use File::Spec;
#use Data::Dumper;

# Constants
use constant {
    USER_AGENT              => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_12_6) AppleWebKit/604.5.6 (KHTML, like Gecko) Version/11.0.3 Safari/604.5.6',
    REST_FORMAT             => 'https://player.siriusxm.com/rest/v2/experience/modules/%s',
    LIVE_PRIMARY_HLS        => 'https://siriusxm-priprodlive.akamaized.net',
    LIVE_SECONDARY_HLS      => 'https://siriusxm-secprodlive.akamaized.net',
    SEGMENT_CACHE_BATCH_SIZE => 2,  # Number of segments to cache per iteration
    SERVER_FAILURE_THRESHOLD => 5,  # Number of consecutive failures before switching servers
    MAX_HOLD_COUNT          => 3,   # Consecutive no-new-segment fetches before treating as server failure
                                    # (3 × EXTINF/2 ≈ 15 s without new content per event;
                                    #  5 such events → SERVER_FAILURE_THRESHOLD → server switch)
    MAX_SEGMENT_RETRIES     => 3,   # Max consecutive fetch failures per segment before dropping it
                                    # (~1 s between each retry via process_segment_queues interval)
    SESSION_MAX_LIFE        => 14400,  # JSESSIONID estimated lifetime: 14400s (4 hours)
    CHANNEL_CACHE_TTL       => 86400, # Channel list cache lifetime: 24 hours
};

# Cookie classification:
#   Auth cookies  – tied to the user's login; stored ONLY in the global cookie jar.
#   Session cookies – short-lived server-affinity cookies; stored ONLY in per-channel
#                     in-memory jars (or the global jar when no channel is specified).
my %AUTH_COOKIE_NAMES    = map { $_ => 1 } qw(SXMDATA);
# SXMAKTOKEN is listed here even though it lives in the per-channel jar so that
# it is included in the debug routing log alongside AWSALB/JSESSIONID.
my %SESSION_COOKIE_NAMES = map { $_ => 1 } qw(AWSALB JSESSIONID AWSALBCORS SXMAKTOKEN);

sub is_auth_cookie    { return exists $AUTH_COOKIE_NAMES{$_[0]}    }
sub is_session_cookie { return exists $SESSION_COOKIE_NAMES{$_[0]} }

sub new {
    my ($class, $username, $password, $region, $cookiefile) = @_;
    
    my $self = {
        username  => $username,
        password  => $password,  
        region    => $region || 'US',
        playlists => {},
        channels  => undef,
        channel_base_paths => {},
        channel_cookies => {},  # Store per-channel cookie jars
        segment_cache => {},    # Store cached segments per channel_id
        segment_queue => {},    # Track segments to be cached per channel_id
        segment_pdt => {},      # Track upstream #EXT-X-PROGRAM-DATE-TIME per segment (per channel_id)
        last_written_segment_pdt => {}, # Last PDT written to disk per channel_id (to avoid redundant writes)
        segment_retry_count => {}, # Track consecutive fetch failures per segment (per channel)
        last_segment => {},     # Track last requested segment per channel_id
        playlist_cache => {},   # Store cached m3u8 content per channel_id
        playlist_channel_name => {}, # Store channel name for each channel_id for efficient lookup
        playlist_next_update => {}, # Track next scheduled update time per channel_id
        playlist_hold_count  => {}, # Consecutive no-new-segment fetches per channel (FFmpeg m3u8_hold_counters analog)
        channel_last_activity => {}, # Track last client activity time per channel_id
        channel_avg_duration => {},  # Track average EXTINF duration per channel_id
        
        # HLS server failover tracking (per channel)
        channel_server => {},  # Track which server each channel is using: 'primary' or 'secondary'
        channel_failure_count => {},  # Track consecutive failures per channel

        # Channel list disk cache
        channel_cache_file    => undef,  # Path to channel list cache file (channels.json)
        channel_cache_expires => 0,      # Unix timestamp when channel cache expires (0 = expired)

        # Per-channel server-selection state file (server_state.json) – separate from the
        # channel cache so that server switches can be persisted immediately without
        # rewriting the entire (large) channel list.
        server_state_file     => undef,

        # Tracked JSESSIONID expiry (cookie carries no timestamp; we set it ourselves)
        jsessionid_expires    => 0,      # Unix timestamp; 0 = treat as expired, triggers re-auth

        # Per-channel SXMAKTOKEN cache.  SXMAKTOKEN is a per-session token issued by
        # the server during authenticate().  It is stored in the per-channel jar, not
        # the global jar, so that concurrent channels each keep their own copy.
        # This cache holds the last-seen value per channel so it survives
        # clear_all_cookies() or the cookie expiring inside HTTP::Cookies.
        sxmaktoken_cache      => {},

        ua        => undef,
        json      => JSON::XS->new->utf8->canonical,
        cookiefile => $cookiefile,
    };
    
    bless $self, $class;
    
    # Initialize user agent with persistent cookie jar
    my $cookie_jar;
    if ($cookiefile) {
        $cookie_jar = HTTP::Cookies->new(
            file => $cookiefile,
            autosave => 1,
            ignore_discard => 1,
        );
        
        # Load existing cookies if file exists
        if (-e $cookiefile) {
            eval {
                $cookie_jar->load();
                main::log_info("Loaded cookies from: $cookiefile");
                
                # SXMAKTOKEN is now per-channel only.  Any copy left in the global
                # jar is stale data written by an older version.  Remove it so that
                # the cookie file stays clean going forward.
                my @sxmaktoken_entries;
                $cookie_jar->scan(sub {
                    my ($version, $key, $val, $path, $domain) = @_;
                    push @sxmaktoken_entries, [$domain, $path, $key] if $key eq 'SXMAKTOKEN';
                });
                if (@sxmaktoken_entries) {
                    $cookie_jar->clear(@$_) for @sxmaktoken_entries;
                    $cookie_jar->save();
                    main::log_debug("Removed " . scalar(@sxmaktoken_entries) .
                                    " stale SXMAKTOKEN entry(s) from global cookie file");
                }

            };
            if ($@) {
                main::log_warn("Error loading cookies from $cookiefile: $@");
            }
        } else {
            main::log_info("Cookie file will be created at: $cookiefile");
        }
    } else {
        # No persistence - use in-memory cookie jar
        $cookie_jar = HTTP::Cookies->new();
        main::log_warn("Cookie persistence disabled - cookies will not be saved");
    }
    
    $self->{ua} = LWP::UserAgent->new(
        agent      => USER_AGENT,
        cookie_jar => $cookie_jar,
        timeout    => 30,
        keep_alive => 1,   # reuse TCP connections; server may still close idle sockets
    );

    # Analyze and log cookie information now that $self->{ua} is ready.
    if ($cookiefile && -e $cookiefile) {
        eval { $self->analyze_cookies(undef, undef) };
        if ($@) {
            main::log_warn("Error analyzing cookies: $@");
        }
    }

    main::log_debug("SiriusXM object created for user: $username, region: $self->{region}");

    # Set up channel cache file path (same directory as cookie file)
    if ($cookiefile) {
        my $cache_dir = dirname($cookiefile);
        $self->{channel_cache_file} = File::Spec->catfile($cache_dir, 'channels.json');
        main::log_debug("Channel cache file: $self->{channel_cache_file}");

        # Set up server state file path (lightweight, written on every server switch)
        $self->{server_state_file} = File::Spec->catfile($cache_dir, 'server_state.json');

        # Load channel list and server state from disk at startup
        $self->load_channel_cache();
        $self->load_server_state();
    }

    return $self;
}

# Analyze and log cookie expiration information.
# Auth cookies (SXMDATA) are always read from the global jar.
# Session cookies (AWSALB, JSESSIONID, SXMAKTOKEN) are read from the channel jar when
# channel_id is provided, or from the global jar when channel_id is undef.
# The legacy $cookies positional parameter is accepted but ignored.
sub analyze_cookies {
    my ($self, $cookies, $channel_id) = @_;
    
    my $context = $channel_id ? "channel $channel_id" : "global";
    my %cookie_info = ();
    my $now = time();

    # Helper to log a single cookie's expiry info
    my $log_cookie = sub {
        my ($key, $expires, $discard) = @_;
        $cookie_info{$key} = { expires => $expires, discard => $discard };

        if ($key eq 'JSESSIONID' && !$expires) {
            my $estimated_expires = $now + SESSION_MAX_LIFE;
            my $expires_str = strftime('%Y-%m-%d %H:%M:%S UTC', gmtime($estimated_expires));
            my $hours = int(SESSION_MAX_LIFE / 3600);
            main::log_info("Cookie $key ($context): no expiration set, estimated lifetime ~${hours}h (expires ~$expires_str)");
            $cookie_info{$key}->{estimated_expires} = $estimated_expires;
        } elsif ($expires) {
            my $remaining = $expires - $now;
            my $expires_str = strftime('%Y-%m-%d %H:%M:%S UTC', gmtime($expires));
            if ($remaining > 0) {
                my $days    = int($remaining / 86400);
                my $hours   = int(($remaining % 86400) / 3600);
                my $minutes = int(($remaining % 3600) / 60);
                main::log_info("Cookie $key ($context): expires $expires_str (in ${days}d ${hours}h ${minutes}m)");
            } else {
                main::log_warn("Cookie $key ($context): EXPIRED at $expires_str");
            }
        } else {
            if ($discard) {
                main::log_debug("Cookie $key ($context): session cookie (will be discarded)");
            } else {
                main::log_debug("Cookie $key ($context): no expiration set");
            }
        }
    };

    # Check global jar for auth cookies (SXMDATA only)
    my $global_jar = $self->{ua}->cookie_jar;
    $global_jar->scan(sub {
        my ($version, $key, $val, $path, $domain, $port, $path_spec, $secure, $expires, $discard, $hash) = @_;
        if (is_auth_cookie($key)) {
            $log_cookie->($key, $expires, $discard);
        }
    });

    # Check appropriate jar for session cookies.
    # SXMAKTOKEN is per-channel only — skip it in the global context because any
    # entry there is stale data from before the per-channel migration and will
    # never be refreshed at the global level.
    my $session_jar = $channel_id
        ? $self->get_channel_cookie_jar($channel_id)
        : $global_jar;
    $session_jar->scan(sub {
        my ($version, $key, $val, $path, $domain, $port, $path_spec, $secure, $expires, $discard, $hash) = @_;
        return if !$channel_id && $key eq 'SXMAKTOKEN';
        if (is_session_cookie($key)) {
            $log_cookie->($key, $expires, $discard);
        }
    });

    return \%cookie_info;
}

# Check if auth cookies need renewal (before they expire).
# Auth cookies (SXMDATA) live only in the global jar.
sub should_renew_cookies {
    my ($self, $channel_id) = @_;
    
    # Auth cookies are always in the global jar regardless of channel
    my $cookies = $self->{ua}->cookie_jar;
    my $now = time();
    
    # Renew if cookies expire within 1 hour (3600 seconds)
    my $renewal_threshold = 3600;
    
    my $should_renew = 0;
    
    $cookies->scan(sub {
        my ($version, $key, $val, $path, $domain, $port, $path_spec, $secure, $expires, $discard, $hash) = @_;
        
        # Only check SXMDATA for renewal.  The SiriusXM server does NOT return a
        # fresh SXMAKTOKEN in routine login/authenticate responses, so triggering
        # renewal when SXMAKTOKEN is near expiry causes a login-failure feedback
        # loop: login() is called, the server responds with status=1 but without
        # a new SXMAKTOKEN, the near-expiry flag remains set, is_logged_in()
        # still returns false, and login() falsely reports failure.
        if ($key eq 'SXMDATA' && $expires) {
            my $remaining = $expires - $now;
            
            if ($remaining > 0 && $remaining < $renewal_threshold) {
                my $minutes = int($remaining / 60);
                main::log_info("Cookie $key (global) expires in ${minutes}m, scheduling renewal");
                $should_renew = 1;
            }
        }
    });
    
    return $should_renew;
}

# DEPRECATED: Auth cookies are no longer copied into channel jars.
# Login/auth cookies are tracked exclusively in the global cookie jar.
# Channel requests receive auth cookies via the merged Cookie: header built
# by compose_cookie_header() / make_channel_request().
sub copy_auth_cookies_to_channel {
    my ($self, $channel_id) = @_;
    main::log_debug("copy_auth_cookies_to_channel() called but is now a no-op (deprecated)");
    return 0;
}

# Get or create an in-memory session cookie jar for a specific channel.
# Channel jars hold session/affinity cookies (AWSALB, JSESSIONID, SXMAKTOKEN, etc.).
# The global auth cookie (SXMDATA) lives exclusively in the global jar.
sub get_channel_cookie_jar {
    my ($self, $channel_id) = @_;
    
    # If no channel_id specified, return the global cookie jar
    return $self->{ua}->cookie_jar unless $channel_id;
    
    # Create a fresh in-memory cookie jar for this channel if one doesn't exist yet
    if (!exists $self->{channel_cookies}->{$channel_id}) {
        my $cookie_jar = HTTP::Cookies->new();
        $self->{channel_cookies}->{$channel_id} = $cookie_jar;
        main::log_debug("Created in-memory session cookie jar for channel: $channel_id");
    }
    
    return $self->{channel_cookies}->{$channel_id};
}

# DEPRECATED: The UA no longer swaps cookie jars between channels.
# Cookies are now merged explicitly in make_channel_request() via compose_cookie_header().
sub set_channel_context {
    my ($self, $channel_id) = @_;
    main::log_trace("set_channel_context() called but is now a no-op (deprecated)");
}

# Clear cookies for a specific channel (or global if no channel_id).
# Channel jars are in-memory only, so clearing them just removes the in-memory object.
sub clear_channel_cookies {
    my ($self, $channel_id) = @_;
    
    my $context = $channel_id ? "channel $channel_id" : "global";
    
    if ($channel_id) {
        # Drop the in-memory session jar; it will be recreated fresh on next access
        delete $self->{channel_cookies}->{$channel_id};
        main::log_debug("Cleared in-memory session cookies for $context");
    } else {
        # Clear global cookie jar (and its backing file if configured)
        if ($self->{cookiefile} && -e $self->{cookiefile}) {
            unlink($self->{cookiefile});
            main::log_debug("Deleted global cookie file: $self->{cookiefile}");
        }
        
        # Create a fresh global cookie jar
        my $cookie_jar;
        if ($self->{cookiefile}) {
            $cookie_jar = HTTP::Cookies->new(
                file => $self->{cookiefile},
                autosave => 1,
                ignore_discard => 1,
            );
        } else {
            $cookie_jar = HTTP::Cookies->new();
        }
        
        $self->{ua}->cookie_jar($cookie_jar);
        main::log_debug("Cleared global cookies");
    }
}

# Clear all cookies (global and all channel-specific in-memory jars).
sub clear_all_cookies {
    my ($self) = @_;
    
    main::log_info("Clearing all cookies (global and all channels)");
    
    my $cleared_channels = scalar keys %{$self->{channel_cookies}};
    
    # Remove all in-memory channel session jars
    $self->{channel_cookies} = {};
    
    # Clear the global cookie jar (and its backing file if configured)
    if ($self->{cookiefile} && -e $self->{cookiefile}) {
        unlink($self->{cookiefile});
        main::log_debug("Deleted global cookie file: $self->{cookiefile}");
    }
    
    # Create a fresh global cookie jar
    my $cookie_jar;
    if ($self->{cookiefile}) {
        $cookie_jar = HTTP::Cookies->new(
            file => $self->{cookiefile},
            autosave => 1,
            ignore_discard => 1,
        );
    } else {
        $cookie_jar = HTTP::Cookies->new();
    }
    
    $self->{ua}->cookie_jar($cookie_jar);
    
    main::log_info("Cleared all cookies: global and $cleared_channels in-memory channel jar(s)");
    
    return $cleared_channels + 1;  # Return total count including global
}

# Get the current HLS server name for a channel (primary or secondary)
sub get_channel_server {
    my ($self, $channel_id) = @_;
    
    # Default to primary for new channels
    return $self->{channel_server}->{$channel_id} || 'primary';
}

# Record a successful request for a channel
sub record_channel_success {
    my ($self, $channel_id) = @_;
    
    # Reset failure count on success
    $self->{channel_failure_count}->{$channel_id} = 0;
}

# Record a failed request for a channel and potentially switch servers
sub record_channel_failure {
    my ($self, $channel_id, $error_msg) = @_;
    
    # Increment failure count
    $self->{channel_failure_count}->{$channel_id} //= 0;
    $self->{channel_failure_count}->{$channel_id}++;
    
    my $current_server = $self->get_channel_server($channel_id);
    my $failure_count = $self->{channel_failure_count}->{$channel_id};
    
    main::log_warn("HLS server $current_server failure #$failure_count for channel $channel_id: $error_msg");
    
    # Check if we should switch servers
    if ($failure_count >= SERVER_FAILURE_THRESHOLD) {
        my $new_server = $current_server eq 'primary' ? 'secondary' : 'primary';
        main::log_error("Channel $channel_id: $current_server server has failed $failure_count consecutive times (threshold: " . 
                       SERVER_FAILURE_THRESHOLD . "), switching to $new_server");
        $self->switch_channel_server($channel_id, $new_server);
    }
}

# Switch a channel to a different HLS server
sub switch_channel_server {
    my ($self, $channel_id, $new_server) = @_;
    
    my $old_server = $self->get_channel_server($channel_id);
    
    if ($old_server eq $new_server) {
        main::log_debug("Channel $channel_id already using $new_server server");
        return;
    }
    
    $self->{channel_server}->{$channel_id} = $new_server;
    $self->{channel_failure_count}->{$channel_id} = 0;  # Reset failure count
    
    # Clear cached playlist URL to force re-fetch with new server
    delete $self->{playlists}->{$channel_id}->{'url'};
    
    main::log_info("Channel $channel_id: switched from $old_server to $new_server server");

    # Persist the new server selection immediately (small file, written on every switch)
    $self->save_server_state();
}

# Reset channel to primary server (called when starting new playback)
sub reset_channel_server {
    my ($self, $channel_id) = @_;
    
    my $current_server = $self->get_channel_server($channel_id);
    
    if ($current_server ne 'primary') {
        main::log_info("Channel $channel_id: resetting to primary server for new playback session");
        $self->{channel_server}->{$channel_id} = 'primary';
        $self->{channel_failure_count}->{$channel_id} = 0;
        delete $self->{playlists}->{$channel_id}->{'url'};

        # Persist the reset so it survives the next restart
        $self->save_server_state();
    }
}

sub is_logged_in {
    my ($self, $channel_id) = @_;
    # Auth cookies (SXMDATA) live exclusively in the global jar.
    # The channel_id parameter is accepted for call-site compatibility but is ignored.
    my $cookies = $self->{ua}->cookie_jar;
    
    # Check for SXMDATA cookie
    my $has_sxmdata = 0;
    my $sxmdata_expired = 0;
    my @cookie_names = ();
    my $now = time();
    
    $cookies->scan(sub {
        my ($version, $key, $val, $path, $domain, $port, $path_spec, $secure, $expires, $discard, $hash) = @_;
        push @cookie_names, $key;
        # Log cookie names only – never log values
        main::log_trace("Global cookie found: $key");
        
        if ($key eq 'SXMDATA') {
            $has_sxmdata = 1;
            
            # Check if cookie is expired
            if ($expires && $expires < $now) {
                $sxmdata_expired = 1;
                my $expires_str = strftime('%Y-%m-%d %H:%M:%S UTC', gmtime($expires));
                main::log_warn("SXMDATA cookie has expired at $expires_str");
            } elsif ($expires) {
                my $remaining = $expires - $now;
                my $days = int($remaining / 86400);
                my $hours = int(($remaining % 86400) / 3600);
                main::log_debug("SXMDATA cookie valid for ${days}d ${hours}h");
            }
        }
    });
    
    main::log_trace("is_logged_in() check (global jar) - found cookies: " . join(", ", @cookie_names));
    
    # Return false if cookie is expired
    if ($sxmdata_expired) {
        main::log_debug("is_logged_in() result: false (cookie expired)");
        return 0;
    }
    
    # Check if cookies need proactive renewal
    if ($has_sxmdata && $self->should_renew_cookies()) {
        main::log_info("Auth cookies approaching expiration, returning false to trigger renewal");
        return 0;
    }
    
    main::log_trace("is_logged_in() result: " . ($has_sxmdata ? "true" : "false"));
    return $has_sxmdata;
}

sub is_session_authenticated {
    my ($self, $channel_id) = @_;
    # Session cookies (AWSALB, JSESSIONID) live in the per-channel in-memory jar when a
    # channel is active, or in the global jar for channel-less (e.g. get_channels) flows.
    my $cookies = $channel_id
        ? $self->get_channel_cookie_jar($channel_id)
        : $self->{ua}->cookie_jar;
    
    # Check for AWSALB and JSESSIONID cookies
    my ($has_awsalb, $has_jsessionid) = (0, 0);
    my ($awsalb_expired, $jsessionid_expired) = (0, 0);
    my @cookie_names = ();
    my $now = time();
    
    $cookies->scan(sub {
        my ($version, $key, $val, $path, $domain, $port, $path_spec, $secure, $expires, $discard, $hash) = @_;
        push @cookie_names, $key;
        
        if ($key eq 'AWSALB') {
            $has_awsalb = 1;
            if ($expires && $expires < $now) {
                $awsalb_expired = 1;
                main::log_warn("AWSALB cookie has expired");
            }
        } elsif ($key eq 'JSESSIONID') {
            $has_jsessionid = 1;
            if ($expires && $expires < $now) {
                $jsessionid_expired = 1;
                main::log_warn("JSESSIONID cookie has expired");
            }
        }
    });
    
    my $context = $channel_id ? "channel $channel_id" : "global";
    main::log_trace("is_session_authenticated() check for $context - found cookies: " . join(", ", @cookie_names));
    
    # Return false if any required cookie is expired
    if ($awsalb_expired || $jsessionid_expired) {
        main::log_debug("is_session_authenticated() result for $context: false (cookies expired)");
        return 0;
    }
    
    my $result = $has_awsalb && $has_jsessionid;
    main::log_trace("is_session_authenticated() result for $context: " . ($result ? "true" : "false"));
    
    return $result;
}

#-----------------------------------------------------------------------------
# Cookie merge helpers (new model)
#-----------------------------------------------------------------------------

# Compose a merged Cookie: header string for a channel request.
# Always includes SXMDATA from the global auth jar.
# When channel_id is defined, also includes that channel's session cookies
# (AWSALB, JSESSIONID, SXMAKTOKEN, etc.) from the in-memory channel jar.
sub compose_cookie_header {
    my ($self, $channel_id) = @_;

    my %cookies;

    # Pull auth cookies (SXMDATA) from the global jar
    my $global_jar = $self->{ua}->cookie_jar;
    $global_jar->scan(sub {
        my ($version, $key, $val, $path, $domain, $port, $path_spec, $secure, $expires, $discard, $hash) = @_;
        if (is_auth_cookie($key)) {
            $cookies{$key} = $val;
        }
    });

    # Pull session cookies from the channel's in-memory jar (if applicable)
    if ($channel_id && exists $self->{channel_cookies}->{$channel_id}) {
        my $channel_jar = $self->{channel_cookies}->{$channel_id};
        $channel_jar->scan(sub {
            my ($version, $key, $val, $path, $domain, $port, $path_spec, $secure, $expires, $discard, $hash) = @_;
            # Never let auth cookies come from the channel jar
            $cookies{$key} = $val unless is_auth_cookie($key);
        });
    }

    my @cookie_pairs = map { "$_=$cookies{$_}" } sort keys %cookies;

    if (@cookie_pairs && $main::CONFIG{verbose} >= main::LOG_TRACE) {
        my @names = map { (split '=', $_, 2)[0] } @cookie_pairs;
        main::log_trace("Composed Cookie header for " . ($channel_id ? "channel $channel_id" : "global") .
                        ": " . join(', ', @names) . " (" . scalar(@cookie_pairs) . " cookies)");
    }

    return join('; ', @cookie_pairs);
}

# Route Set-Cookie headers from $response to the correct cookie jar.
#   channel_id undef  → all cookies go to the global jar (normal LWP behaviour).
#   channel_id defined → SXMDATA goes to global jar;
#                        everything else (SXMAKTOKEN, AWSALB, JSESSIONID, incapsula, …)
#                        goes to the channel in-memory jar.
# Cookie values are never logged.
sub route_response_cookies {
    my ($self, $response, $channel_id) = @_;

    return unless $response;

    my $global_jar = $self->{ua}->cookie_jar;

    if (!defined $channel_id) {
        # Global request – let the global jar absorb all Set-Cookie headers
        $global_jar->extract_cookies($response);
        $self->log_jar_cookie_names($global_jar, 'global') if $main::CONFIG{verbose} >= main::LOG_DEBUG;
        return;
    }

    # Channel request – route each Set-Cookie to the appropriate jar
    my @set_cookies = $response->header('Set-Cookie');
    unless (@set_cookies) {
        main::log_trace("No Set-Cookie headers in response for channel $channel_id");
        return;
    }

    main::log_debug("Routing " . scalar(@set_cookies) . " Set-Cookie header(s) for channel $channel_id");

    my $channel_jar = $self->get_channel_cookie_jar($channel_id);
    my $req         = $response->request;

    unless ($req) {
        main::log_warn("Cannot route Set-Cookie headers: response has no associated request object");
        return;
    }

    my (@auth_names, @session_names, @unknown_names);

    for my $set_cookie (@set_cookies) {
        # Extract the cookie name (first token before '=')
        my ($name) = $set_cookie =~ /^([^=;]+)/;
        next unless defined $name;
        $name =~ s/^\s+|\s+$//g;

        # Build a minimal response wrapping just this one Set-Cookie header so that
        # extract_cookies() can determine the correct domain/path from the request URI.
        my $mini_resp = HTTP::Response->new(200);
        $mini_resp->request(HTTP::Request->new(GET => $req->uri));
        $mini_resp->header('Set-Cookie', $set_cookie);

        if (is_auth_cookie($name)) {
            $global_jar->extract_cookies($mini_resp);
            push @auth_names, $name;
        } else {
            $channel_jar->extract_cookies($mini_resp);
            if (is_session_cookie($name)) {
                push @session_names, $name;
            } else {
                push @unknown_names, $name;
            }
        }
    }

    main::log_debug("Cookie routing for channel $channel_id: " .
                    "global=[" . join(',', @auth_names) . "] " .
                    "channel=[" . join(',', @session_names, @unknown_names) . "]")
        if @auth_names || @session_names || @unknown_names;
}

# Execute an HTTP request with the correct cookie jars for the given channel.
#
# For channel_id=undef: delegates directly to the UA (which holds the global jar).
# For a defined channel_id:
#   1. Composes a merged Cookie: header (global auth + channel session cookies).
#   2. Temporarily replaces the UA's jar with an empty one so LWP does not
#      auto-add or auto-store cookies for this request.
#   3. Makes the request.
#   4. Restores the global jar on the UA.
#   5. Routes Set-Cookie response headers to the correct jars via route_response_cookies().
sub make_channel_request {
    my ($self, $request, $channel_id) = @_;

    unless (defined $channel_id) {
        # Global request: use the UA with its global jar unchanged
        main::log_trace("Global request via UA global jar: " . $request->uri);
        return $self->_ua_request_with_retry($request);
    }

    # Channel request: merge cookies manually, bypass LWP auto-cookie handling
    main::log_trace("Channel $channel_id request: merging Cookie header for " . $request->uri);

    my $cookie_header = $self->compose_cookie_header($channel_id);
    $request->header('Cookie', $cookie_header) if $cookie_header;

    # Swap in an empty jar so LWP neither adds extra cookies nor stores Set-Cookie
    my $saved_jar = $self->{ua}->cookie_jar;
    $self->{ua}->cookie_jar(HTTP::Cookies->new());

    my $response = $self->_ua_request_with_retry($request);

    # Restore the global jar immediately after the request
    $self->{ua}->cookie_jar($saved_jar);

    # Route Set-Cookie headers to the appropriate jars
    $self->route_response_cookies($response, $channel_id);

    return $response;
}

# Wrap $ua->request with a single retry on connection-drop style failures.
# LWP will automatically open a fresh TCP connection on the retry; keep-alive
# is best-effort and the server may close idle sockets at any time.
sub _ua_request_with_retry {
    my ($self, $request) = @_;

    my $response = $self->{ua}->request($request);
    return $response if $response->is_success;

    my $status = $response->status_line // '';
    if ($status =~ /(?:timeout|read timed out|connection reset|broken pipe|closed|EOF)/i) {
        main::log_warn("Connection issue ($status) - retrying once with a new TCP connection");
        $response = $self->{ua}->request($request);
    }

    return $response;
}

# Log the names (never values) of all cookies in $jar.
# Intended for DEBUG/TRACE diagnostics only.
sub log_jar_cookie_names {
    my ($self, $jar, $context) = @_;
    return unless $main::CONFIG{verbose} >= main::LOG_DEBUG;

    my @names;
    $jar->scan(sub { my ($v, $k) = @_; push @names, $k; });

    if (@names) {
        main::log_debug("Cookie names in $context jar: " . join(', ', @names));
    } else {
        main::log_debug("No cookies in $context jar");
    }
}

#-----------------------------------------------------------------------------
# HTTP API helpers
#-----------------------------------------------------------------------------

sub get_request {
    my ($self, $method, $params, $authenticate, $channel_id) = @_;
    $authenticate //= 1;
    
    if ($authenticate) {
        if (!$self->is_session_authenticated($channel_id) && !$self->authenticate($channel_id)) {
            main::log_error('Unable to authenticate');
            return undef;
        }
    }
    
    my $url = sprintf(REST_FORMAT, $method);
    my $uri = URI->new($url);
    $uri->query_form($params) if $params;
    
    main::log_trace("GET request to: $uri");
    
    my $request  = HTTP::Request->new(GET => $uri);
    my $response = $self->make_channel_request($request, $channel_id);
    
    if (!$response->is_success) {
        main::log_error("Received status code " . $response->code . " for method '$method'");
        return undef;
    }
    
    my $content = $response->decoded_content;
    my $data;
    eval {
        $data = $self->{json}->decode($content);
    };
    if ($@) {
        main::log_error("Error decoding JSON for method '$method': $@");
        return undef;
    }
    
    return $data;
}

sub post_request {
    my ($self, $method, $postdata, $authenticate, $channel_id) = @_;
    $authenticate //= 1;
    
    if ($authenticate) {
        if (!$self->is_session_authenticated($channel_id) && !$self->authenticate($channel_id)) {
            main::log_error('Unable to authenticate');
            return undef;
        }
    }
    
    my $url = sprintf(REST_FORMAT, $method);
    my $json_data = $self->{json}->encode($postdata);
    
    main::log_trace("POST request to: $url");
    # Only sanitize POST data if trace logging is enabled to avoid unnecessary overhead
    if ($main::CONFIG{verbose} >= main::LOG_TRACE) {
        my $sanitized_postdata = main::sanitize_for_logging($postdata);
        my $sanitized_json = $self->{json}->encode($sanitized_postdata);
        main::log_trace("POST data: $sanitized_json");
    }
    
    my $request = HTTP::Request->new(POST => $url);
    $request->content_type('application/json');
    $request->content($json_data);
    
    my $response = $self->make_channel_request($request, $channel_id);
    
    # Log response details for trace level (cookie names only, never values)
    main::log_trace("Response status: " . $response->status_line);
    if ($response->header('Set-Cookie') && $main::CONFIG{verbose} >= main::LOG_TRACE) {
        my @names = map { /^([^=;]+)/ ? $1 : '?' } $response->header('Set-Cookie');
        main::log_trace("Response Set-Cookie names: " . join(', ', @names));
    }
    
    if (!$response->is_success) {
        main::log_error("Received status code " . $response->code . " for method '$method'");
        main::log_trace("Response content: " . $response->decoded_content) if $response->decoded_content;
        return undef;
    }
    
    my $content = $response->decoded_content;
    main::log_trace("Response content: $content");
    
    my $data;
    eval {
        $data = $self->{json}->decode($content);
    };
    if ($@) {
        main::log_error("Error decoding JSON for method '$method': $@");
        return undef;
    }
    
    main::log_trace("Parsed response data: " . $self->{json}->encode($data));
    return $data;
}

sub login {
    my ($self, $channel_id) = @_;
    
    # Login is made with the channel context so that the Cookie: header carries
    # any session cookies already in the channel jar (e.g. incapsula affinity
    # cookies).  The SiriusXM server returns SXMAKTOKEN only when those session
    # cookies are present.  route_response_cookies() then puts SXMDATA into
    # the global jar and SXMAKTOKEN + session cookies into the channel jar.
    my $context = $channel_id ? "channel $channel_id" : "global";
    main::log_debug("Attempting to login user: $self->{username} ($context)");
    
    my $postdata = {
        moduleList => {
            modules => [{
                moduleRequest => {
                    resultTemplate => 'web',
                    deviceInfo => {
                        osVersion        => 'Mac',
                        platform         => 'Web',
                        sxmAppVersion    => '3.1802.10011.0',
                        browser          => 'Safari',
                        browserVersion   => '11.0.3',
                        appRegion        => $self->{region},
                        deviceModel      => 'K2WebClient',
                        clientDeviceId   => 'null',
                        player           => 'html5',
                        clientDeviceType => 'web',
                    },
                    standardAuth => {
                        username => $self->{username},
                        password => $self->{password},
                    },
                },
            }],
        },
    };
    
    # Pass channel_id so make_channel_request() composes the Cookie: header with
    # SXMDATA (global) and channel session cookies.  route_response_cookies()
    # ensures SXMDATA lands in the global jar and SXMAKTOKEN in the channel jar.
    my $data = $self->post_request('modify/authentication', $postdata, 0, $channel_id);
    return 0 unless $data;
    
    main::log_trace("Login response received, checking status");
    
    my $success = 0;
    eval {
        my $status = $data->{ModuleListResponse}->{status};
        main::log_trace("Login response status: $status");
        
        # Verify success by checking SXMDATA is present and not expired.
        # Do NOT call is_logged_in() here: that method calls should_renew_cookies()
        # which can return true when SXMAKTOKEN is approaching expiry.  Because
        # the server does not return a fresh SXMAKTOKEN, calling is_logged_in()
        # inside login() creates a feedback loop where login falsely reports
        # failure even though the server responded with status=1.
        my $sxmdata_valid = 0;
        my $now_t = time();
        $self->{ua}->cookie_jar->scan(sub {
            my ($v, $k, $val, $p, $d, $port, $ps, $sec, $expires) = @_;
            $sxmdata_valid = 1 if $k eq 'SXMDATA' && (!$expires || $expires > $now_t);
        });
        
        if ($status == 1 && $sxmdata_valid) {
            main::log_info("Login successful for user: $self->{username}");
            $success = 1;
        } else {
            main::log_trace("Login failed - status: $status, sxmdata valid: " . ($sxmdata_valid ? "true" : "false"));
        }
    };
    if ($@) {
        main::log_error("Error decoding JSON response for login: $@");
    }
    
    if ($success) {
        # Analyze cookies after successful login
        $self->analyze_cookies(undef, $channel_id);
        return 1;
    }
    
    main::log_error("Login failed for user: $self->{username}");
    return 0;
}

sub authenticate {
    my ($self, $channel_id) = @_;
    
    if (!$self->is_logged_in($channel_id) && !$self->login($channel_id)) {
        main::log_error('Unable to authenticate because login failed');
        return 0;
    }
    
    my $context = $channel_id ? "channel $channel_id" : "global";
    main::log_debug("Attempting to authenticate session for $context");
    
    my $postdata = {
        moduleList => {
            modules => [{
                moduleRequest => {
                    resultTemplate => 'web',
                    deviceInfo => {
                        osVersion        => 'Mac',
                        platform         => 'Web',
                        clientDeviceType => 'web',
                        sxmAppVersion    => '3.1802.10011.0',
                        browser          => 'Safari',
                        browserVersion   => '11.0.3',
                        appRegion        => $self->{region},
                        deviceModel      => 'K2WebClient',
                        player           => 'html5',
                        clientDeviceId   => 'null',
                    }
                }
            }]
        }
    };
    
    # post_request will route the response cookies via route_response_cookies():
    # - SXMDATA          → global jar
    # - SXMAKTOKEN       → channel jar
    # - AWSALB/JSESSIONID → channel jar (or global jar when channel_id is undef)
    my $data = $self->post_request('resume?OAtrial=false', $postdata, 0, $channel_id);
    return 0 unless $data;
    
    main::log_trace("Authentication response received for $context, checking status");
    
    my $success = 0;
    eval {
        my $status = $data->{ModuleListResponse}->{status};
        main::log_trace("Authentication response status for $context: $status");
        
        if ($status == 1 && $self->is_session_authenticated($channel_id)) {
            main::log_info("Session authentication successful for $context");
            $success = 1;
        } else {
            main::log_trace("Authentication failed for $context - status: $status, is_session_authenticated: " . ($self->is_session_authenticated($channel_id) ? "true" : "false"));
        }
    };
    if ($@) {
        main::log_error("Error parsing JSON response for authentication ($context): $@");
    }
    
    if ($success) {
        # Analyze cookies after successful authentication
        $self->analyze_cookies(undef, $channel_id);

        # Track when the JSESSIONID session will expire.
        # The cookie carries no explicit timestamp so we calculate it ourselves.
        # We only track this for the global (undef channel) auth flow because the
        # background channel-cache refresh uses that path.
        if (!defined $channel_id) {
            $self->{jsessionid_expires} = time() + SESSION_MAX_LIFE;
            my $exp_str = strftime('%Y-%m-%d %H:%M:%S UTC', gmtime($self->{jsessionid_expires}));
            main::log_debug("Tracked JSESSIONID expiry (global): $exp_str (~" . int(SESSION_MAX_LIFE/3600) . "h)");
        }
        return 1;
    }
    
    main::log_error("Session authentication failed for $context");
    return 0;
}

sub get_sxmak_token {
    my ($self, $channel_id) = @_;
    
    # SXMAKTOKEN is a per-session/per-channel token.  Each call to authenticate()
    # receives a fresh one from the server and it is stored in the channel's
    # in-memory jar so that concurrent channels each keep their own independent copy.
    my $jar = $channel_id
        ? $self->get_channel_cookie_jar($channel_id)
        : $self->{ua}->cookie_jar;

    my $token;
    $jar->scan(sub {
        my ($version, $key, $val, $path, $domain, $port, $path_spec, $secure, $expires, $discard, $hash) = @_;
        if ($key eq 'SXMAKTOKEN') {
            # Parse token value: token=value,other_data
            if ($val =~ /^([^=]+)=([^,]+)/) {
                $token = $2;
            }
        }
    });
    
    my $cache_key = $channel_id // '__global__';
    if ($token) {
        # Keep the per-channel cache current so we survive clear_all_cookies().
        $self->{sxmaktoken_cache}{$cache_key} = $token;
    } elsif (exists $self->{sxmaktoken_cache}{$cache_key}) {
        # The server does not re-issue SXMAKTOKEN in every authenticate response.
        # Fall back to the last known value for this channel – the server typically
        # still accepts it.
        $token = $self->{sxmaktoken_cache}{$cache_key};
        main::log_debug("SXMAK token: using cached value for " .
                        ($channel_id ? "channel $channel_id" : "global") .
                        " (cookie missing from jar)");
    }
    
    my $context = $channel_id ? "channel $channel_id" : "global";
    main::log_trace("SXMAK token ($context): " . ($token ? "found" : "not found"));
    return $token;
}

sub get_gup_id {
    my ($self, $channel_id) = @_;
    
    # SXMDATA is an auth cookie; it lives exclusively in the global jar.
    my $cookies = $self->{ua}->cookie_jar;
    my $gup_id;
    $cookies->scan(sub {
        my ($version, $key, $val, $path, $domain, $port, $path_spec, $secure, $expires, $discard, $hash) = @_;
        if ($key eq 'SXMDATA') {
            eval {
                my $decoded = uri_unescape($val);
                my $data = $self->{json}->decode($decoded);
                $gup_id = $data->{gupId};
            };
            if ($@) {
                main::log_warn("Error parsing SXMDATA cookie (global jar): $@");
                main::log_debug("Clearing global cookies to force fresh authentication");
                $self->clear_channel_cookies(undef);  # clear global jar
            }
        }
    });
    
    main::log_trace("GUP ID (global jar): " . ($gup_id || 'not found'));
    return $gup_id;
}

sub get_playlist_url {
    my ($self, $guid, $channel_id, $use_cache, $max_attempts) = @_;
    $use_cache //= 1;
    $max_attempts //= 5;
    
    if ($use_cache && exists $self->{playlists}->{$channel_id}->{'url'}) {
        main::log_trace("Using cached playlist for channel: $channel_id");
        return $self->{playlists}->{$channel_id}->{'url'};
    }
    
    my $timestamp = sprintf("%.0f", time() * 1000);
    my $iso_time = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime());
    
    my $params = {
        assetGUID        => $guid,
        ccRequestType    => 'AUDIO_VIDEO', 
        channelId        => $channel_id,
        hls_output_mode  => 'custom',
        marker_mode      => 'all_separate_cue_points',
        'result-template' => 'web',
        time             => $timestamp,
        timestamp        => $iso_time,
    };
    
    main::log_debug("Getting playlist URL for channel: $channel_id");
    
    my $data = $self->get_request('tune/now-playing-live', $params, 1, $channel_id);
    return undef unless $data;
    
    # Get status
    my ($status, $message, $message_code);
    eval {
        $status = $data->{ModuleListResponse}->{status};
        $message = $data->{ModuleListResponse}->{messages}->[0]->{message};
        $message_code = $data->{ModuleListResponse}->{messages}->[0]->{code};
    };
    if ($@) {
        main::log_error("Error parsing JSON response for playlist: $@");
        return undef;
    }
    
    # Handle session expiration
    if ($message_code == 201 || $message_code == 208) {
        if ($max_attempts > 0) {
            main::log_warn("Session expired (code: $message_code), re-authenticating for channel: $channel_id");
            if ($self->authenticate($channel_id)) {
                main::log_info("Successfully re-authenticated for channel: $channel_id");
                return $self->get_playlist_url($guid, $channel_id, $use_cache, $max_attempts - 1);
            } else {
                main::log_error("Failed to re-authenticate for channel: $channel_id");
                return undef;
            }
        } else {
            main::log_error("Reached max attempts for playlist");
            return undef;
        }
    } elsif ($message_code != 100) {
        main::log_error("Received error $message_code: $message");
        return undef;
    }
    
    # Get m3u8 URL
    my $playlists;
    eval {
        $playlists = $data->{ModuleListResponse}->{moduleList}->{modules}->[0]->{moduleResponse}->{liveChannelData}->{hlsAudioInfos};
    };
    if ($@) {
        main::log_error("Error parsing JSON response for playlist: $@");
        return undef;
    }

=begin comment
   Playlist data format includes both primary and secondary servers:
   SMALL = 17segments
   MEDIUM = 32segments
   LARGE = >100 segments
  [
    {
      'size' => 'SMALL',
      'name' => 'primary',
      'url' => '%Live_Primary_HLS%/AAC_Data/9450/9450_variant_small_v3.m3u8'
    },
    {
      'size' => 'MEDIUM',
      'name' => 'primary',
      'url' => '%Live_Primary_HLS%/AAC_Data/9450/9450_variant_medium_v3.m3u8'
    },
    {
      'size' => 'LARGE',
      'name' => 'primary',
      'url' => '%Live_Primary_HLS%/AAC_Data/9450/9450_variant_large_v3.m3u8'
    },
    {
      'size' => 'SMALL',
      'name' => 'secondary',
      'url' => '%Live_Secondary_HLS%/AAC_Data/9450/9450_variant_small_v3.m3u8'
    },
    {
      'size' => 'MEDIUM',
      'name' => 'secondary',
      'url' => '%Live_Secondary_HLS%/AAC_Data/9450/9450_variant_medium_v3.m3u8'
    },
    {
      'size' => 'LARGE',
      'name' => 'secondary',
      'url' => '%Live_Secondary_HLS%/AAC_Data/9450/9450_variant_large_v3.m3u8'
    }
  ]
=end comment
=cut

    # Determine which server to use for this channel
    my $desired_server = $self->get_channel_server($channel_id);
    my $desired_playlist_size = main::playlist_size_for_segment_drop($CONFIG{segment_drop});

    main::log_info("Channel $channel_id: selecting $desired_playlist_size playlist on $desired_server server (segment_drop=$CONFIG{segment_drop})");
    
    # Find the appropriate playlist entry (matching both size and server name)
    for my $playlist_info (@$playlists) {
        if ($playlist_info->{size} eq $desired_playlist_size && $playlist_info->{name} eq $desired_server) {
            my $playlist_url = $playlist_info->{url};
            
            # Replace the placeholder with actual server URL
            if ($desired_server eq 'primary') {
                $playlist_url =~ s/%Live_Primary_HLS%/@{[LIVE_PRIMARY_HLS]}/g;
            } else {
                $playlist_url =~ s/%Live_Secondary_HLS%/@{[LIVE_SECONDARY_HLS]}/g;
            }
            
            main::log_debug("Channel $channel_id: using $desired_server server $desired_playlist_size playlist");
            
            my $variant_url = $self->get_playlist_variant_url($playlist_url, $channel_id);
            if ($variant_url) {
                $self->{playlists}->{$channel_id}->{'url'} = $variant_url;
                main::log_debug("Cached playlist URL for channel: $channel_id");
                return $variant_url;
            }
        }
    }
    
    main::log_error("No suitable $desired_server $desired_playlist_size playlist found for channel: $channel_id");
    return undef;
}

sub get_playlist_variant_url {
    my ($self, $url, $channel_id) = @_;
    
    # Auth tokens come from the global jar; no set_channel_context needed
    my $token = $self->get_sxmak_token($channel_id);
    my $gup_id = $self->get_gup_id($channel_id);
    
    return undef unless $token && $gup_id;
    
    my $uri = URI->new($url);
    $uri->query_form(
        token    => $token,
        consumer => 'k2',
        gupId    => $gup_id,
    );
    
    main::log_trace("Getting playlist variant from: $uri");
    
    my $request  = HTTP::Request->new(GET => $uri);
    my $response = $self->make_channel_request($request, $channel_id);
    
    if (!$response->is_success) {
        my $error_msg = "Received status code " . $response->code . " on playlist variant retrieval";
        main::log_error($error_msg);
        $self->record_channel_failure($channel_id, $error_msg);
        return undef;
    }
    
    # Record successful request
    $self->record_channel_success($channel_id);
    
    my $content = $response->decoded_content;
    main::log_trace("Playlist variant content received:\n$content");
    
    # Check if this is a master playlist with quality variants
    if ($content =~ /#EXT-X-STREAM-INF/) {
        main::log_debug("Master playlist detected in variant URL, selecting quality variant");
        my $variant_url = $self->select_quality_variant($content, $url, $CONFIG{quality}, $channel_id);
        if ($variant_url) {
            main::log_info("Selected quality variant: $variant_url");
            return $variant_url;
        } else {
            main::log_warn("Failed to select quality variant, falling back to first found");
        }
    }
    
    # Parse playlist according to Apple HLS specification
    # Handle both Unix (\n) and Windows (\r\n) line endings
    my @lines = split /\r?\n/, $content;
    my $found_lines = 0;
    
    for my $line (@lines) {
        # Trim whitespace per HLS spec
        $line =~ s/^\s+|\s+$//g;
        
        # Skip empty lines (permitted by HLS spec)
        next if $line eq '';
        
        # Skip comments and tags
        next if $line =~ /^#/;
        
        $found_lines++;
        main::log_trace("Processing line $found_lines: '$line'");
        
        # Look for .m3u8 URLs (variant playlists)
        if ($line =~ /\.m3u8$/) {
            # Found a variant playlist URL
            my $base_url = $url;
            $base_url =~ s/\/[^\/]+$//;
            my $variant_url = "$base_url/$line";
            main::log_trace("Found playlist variant: $variant_url");
            return $variant_url;
        }
    }
    
    main::log_error("No playlist variant found in $found_lines lines of content");
    return undef;
}

# Trim playlist to reduce size from 1800+ segments to a manageable window
sub drop_last_segments {
    my ($self, $content, $segment_drop) = @_;
    
    # Drop last N segments from playlist (for first load only)
    # Following Apple HLS specification
    
    return $content if $segment_drop <= 0;
    
    my @lines = split /\r?\n/, $content;
    my @segment_starts = ();  # Track start line indices of segments
    my $header_end = -1;
    
    # Find header end and all segment start positions
    for my $i (0 .. $#lines) {
        my $line = $lines[$i];
        $line =~ s/^\s+|\s+$//g;
        
        if ($line =~ /^#EXTINF:/) {
            push @segment_starts, $i;
            $header_end = $i - 1 if $header_end == -1;
        }
    }
    
    my $total_segments = scalar(@segment_starts);
    return $content if $total_segments <= $segment_drop;
    
    # Keep all segments except the last segment_drop
    my $segments_to_keep = $total_segments - $segment_drop;
    
    # Build output: header + segments (minus last N)
    my @output;
    push @output, @lines[0 .. $header_end] if $header_end >= 0;
    
    for my $seg_idx (0 .. $segments_to_keep - 1) {
        my $start_line = $segment_starts[$seg_idx];
        my $end_line = $seg_idx < $#segment_starts ? $segment_starts[$seg_idx + 1] - 1 : $#lines;
        push @output, @lines[$start_line .. $end_line];
    }
    
    main::log_debug(sprintf("Dropped last %d segments from playlist: %d -> %d segments", 
                           $segment_drop, $total_segments, $segments_to_keep));
    
    return join("\n", @output);
}

sub get_playlist {
    my ($self, $name, $use_cache) = @_;
    $use_cache //= 1;
    
    my ($guid, $channel_id) = $self->get_channel($name);
    if (!$guid || !$channel_id) {
        main::log_error("No channel found for: $name");
        return undef;
    }
    
    # Check if caching is disabled (segment_drop == 0)
    my $segment_drop = $CONFIG{segment_drop};
    my $caching_enabled = $segment_drop >= 1;
    
    # Check if we have a cached playlist and it's not time to update yet
    # Only use cache if caching is enabled
    my $now = time();
    if ($caching_enabled && $use_cache && 
        exists $self->{playlist_cache}->{$channel_id} && 
        exists $self->{playlist_next_update}->{$channel_id}) {
        
        my $next_update = $self->{playlist_next_update}->{$channel_id};
        if ($now < $next_update) {
            my $remaining = $next_update - $now;
            main::log_debug(sprintf("Using cached playlist for channel %s (next update in %.1f seconds)", 
                                   $channel_id, $remaining));
            return $self->{playlist_cache}->{$channel_id};
        } else {
            main::log_debug("Cached playlist expired for channel $channel_id, fetching new one");
        }
    }
    
    # Capture any stale cached content so we can serve it as a fallback if the
    # fresh fetch fails (transient CDN/server error).  Only applies to client-driven
    # requests (use_cache=1); background-refresh calls (use_cache=0) are fine to
    # return undef so the scheduler retries.
    my $stale_cache = ($caching_enabled && $use_cache &&
                       exists $self->{playlist_cache}->{$channel_id})
                      ? $self->{playlist_cache}->{$channel_id} : undef;

    my $url = $self->get_playlist_url($guid, $channel_id, $use_cache);
    unless ($url) {
        main::log_warn("Could not get playlist URL for channel $channel_id" .
                       ($stale_cache ? ", serving stale playlist" : ""));
        return $stale_cache;
    }
    
    # Auth tokens come from the global jar; no set_channel_context needed
    my $token = $self->get_sxmak_token($channel_id);
    my $gup_id = $self->get_gup_id($channel_id);
    
    # If we can't get both token and gup_id, this might be due to corrupted cookies
    # Try to authenticate again if they're missing
    if (!$token || !$gup_id) {
        main::log_warn("Missing token or gup_id for channel $channel_id, attempting authentication");
        if ($self->authenticate($channel_id)) {
            # Try again after authentication
            $token = $self->get_sxmak_token($channel_id);
            $gup_id = $self->get_gup_id($channel_id);
        }
    }
    
    unless ($token && $gup_id) {
        main::log_warn("Still missing token or gup_id for channel $channel_id" .
                       ($stale_cache ? ", serving stale playlist" : ""));
        return $stale_cache;
    }
    
    my $uri = URI->new($url);
    $uri->query_form(
        token    => $token,
        consumer => 'k2', 
        gupId    => $gup_id,
    );
    
    main::log_debug("Getting playlist for channel: $name");
    main::log_trace("Playlist URL: $uri");
    
    my $request  = HTTP::Request->new(GET => $uri);
    my $response = $self->make_channel_request($request, $channel_id);
    
    if ($response->code == 500) {
        my $status_code = $response->code;
        my $error_msg = "Received status code $status_code on playlist for channel: $channel_id";
        $self->record_channel_failure($channel_id, $error_msg);
        main::log_warn("$error_msg – server may be temporarily unavailable, preserving cookies" .
                       ($stale_cache ? "; serving stale playlist to client" : ""));
        return $stale_cache;
    } elsif ($response->code == 403) {
        my $status_code = $response->code;
        my $error_msg = "Received status code $status_code on playlist for channel: $channel_id";
        # Count toward server failover (same as get_segment does)
        $self->record_channel_failure($channel_id, $error_msg);

        main::log_warn("$error_msg, renewing session");
        
        # Try re-authentication first (without clearing cookies)
        if ($self->authenticate($channel_id)) {
            return $self->get_playlist($name, 0) // $stale_cache;
        } else {
            # A 403 is a genuine auth rejection – clear cookies and try a fresh login.
            main::log_warn("Re-authentication failed, clearing all cookies and retrying for channel $channel_id");
            $self->clear_all_cookies();
            if ($self->authenticate($channel_id)) {
                return $self->get_playlist($name, 0) // $stale_cache;
            } else {
                main::log_error("Failed to re-authenticate for channel: $channel_id after clearing all cookies" .
                                ($stale_cache ? "; serving stale playlist to client" : ""));
                return $stale_cache;
            }
        }
    }
    
    if (!$response->is_success) {
        my $error_msg = "Received status code " . $response->code . " on playlist variant";
        main::log_error($error_msg . ($stale_cache ? "; serving stale playlist to client" : ""));
        $self->record_channel_failure($channel_id, $error_msg);
        return $stale_cache;
    }

    $self->record_channel_success($channel_id);
    
    my $content = $response->decoded_content;
    
    # Calculate and store base path for this channel
    my $base_url = $url;
    $base_url =~ s/\/[^\/]+$//;
    my $base_path = $base_url;
    $base_path =~ s/^https?:\/\/[^\/]+\///;
    
    # Store the base path for this channel ID
    $self->{channel_base_paths}->{$channel_id} = $base_path;
    
    main::log_info("Processing playlist - URL: $url");
    main::log_trace("Processing playlist - Base URL: $base_url");
    main::log_trace("Processing playlist - Base path: $base_path");
    main::log_trace("Stored base path for channel $channel_id: $base_path");

    # If caching is disabled, return playlist directly without any processing
    if (!$caching_enabled) {
        main::log_debug("Caching disabled (Playlist Behind Live = 0) for channel $channel_id");
        return $content;
    }

    # Extract and queue segment list from the playlist BEFORE modifying it
    # This works on the full playlist for proper caching
    my $new_segment_count = $self->extract_segments_from_playlist($content, $channel_id);
    
    # Check if this is the first load for this channel
    my $is_first_load = (not exists $self->{playlists}->{$channel_id}->{'First'} or $self->{playlists}->{$channel_id}->{'First'} != 1);
    
    # Cache the full playlist
    $self->{playlist_cache}->{$channel_id} = $content;
    $self->{playlist_channel_name}->{$channel_id} = $name;
    
    # On first load: drop last segment_drop segments from what we return to client
    # This helps ffmpeg cache properly, but cache still has full playlist
    if ($is_first_load && $segment_drop > 0) {
        $content = $self->drop_last_segments($content, $segment_drop);
        $self->{playlists}->{$channel_id}->{'First'} = 1;
        main::log_debug("First load: returning playlist with last $segment_drop segments dropped (cache has full playlist)");
    }

    # Schedule next playlist update using FFmpeg's refresh heuristic
    # (new segment → EXTINF, no new segment → EXTINF/2)
    my $delay = $self->calculate_playlist_update_delay($content, $new_segment_count, $channel_id);
    my $next_update = time() + $delay;
    $self->{playlist_next_update}->{$channel_id} = $next_update;

    if ($new_segment_count > 0) {
        # New content arrived — reset the hold counter and the CDN failure counter
        $self->{playlist_hold_count}->{$channel_id} = 0;
        my $update_time = strftime('%Y-%m-%d %H:%M:%S', localtime($next_update));
        main::log_info(sprintf("Cached playlist for channel %s, next update scheduled in %.1f seconds at %s (%d new segments)", 
                              $channel_id, $delay, $update_time, $new_segment_count));
    } else {
        # No new content yet — increment the hold counter.
        # Every MAX_HOLD_COUNT consecutive misses, escalate to record_channel_failure so
        # the server-failover logic can eventually switch to the secondary CDN.
        my $hold_count = ++$self->{playlist_hold_count}->{$channel_id};
        if ($hold_count >= MAX_HOLD_COUNT) {
            $self->record_channel_failure($channel_id,
                sprintf("Playlist stalled: %d consecutive fetches with no new segments (%.0fs without new content)",
                        $hold_count, $hold_count * $delay));
            $self->{playlist_hold_count}->{$channel_id} = 0;  # reset so we escalate again after the next MAX_HOLD_COUNT misses
        }
        main::log_debug(sprintf("No new segments for channel %s, scheduling refresh in %.1f seconds (EXTINF/2, hold_count=%d)",
                               $channel_id, $delay, $hold_count));
    }
    
    return $content;
}

# Extract segment paths from a playlist
sub extract_segments_from_playlist {
    my ($self, $content, $channel_id) = @_;
    
    # Optimized segment extraction following Apple HLS specification
    # URI lines immediately follow #EXTINF tags
    
    my @lines = split /\r?\n/, $content;
    my @segments = ();
    my $expecting_uri = 0;
    my $current_pdt;
    
    for my $line (@lines) {
        $line =~ s/^\s+|\s+$//g;
        next if $line eq '';
        
        if ($line =~ /^#EXT-X-PROGRAM-DATE-TIME:(.+)$/) {
            $current_pdt = $1;
        } elsif ($line =~ /^#EXTINF:/) {
            $expecting_uri = 1;
        } elsif ($expecting_uri && $line !~ /^#/ && $line =~ /\.aac/) {
            push @segments, $line;
            if (defined $current_pdt && !exists $self->{segment_pdt}->{$channel_id}->{$line}) {
                $self->{segment_pdt}->{$channel_id}->{$line} = $current_pdt;
            }
            $expecting_uri = 0;
        }
    }
    
    $self->{playlists}->{$channel_id}->{'segments'} = \@segments;
    main::log_debug("Extracted " . scalar(@segments) . " segments for channel $channel_id");
    
    # Determine uncached segments based on last requested position
    my $start_index = 0;
    my $defer_caching = 0;
    
    if ($self->{last_segment}->{$channel_id}) {
        my $last_seg = $self->{last_segment}->{$channel_id};
        for my $i (0 .. $#segments) {
            if ($segments[$i] eq $last_seg) {
                $start_index = $i + 1;
                last;
            }
        }
    } else {
        main::log_debug("No last_segment for channel $channel_id - deferring caching until client requests first segment");
        $defer_caching = 1;
    }
    
    # Count uncached segments efficiently
    my @uncached_segments = ();
    for my $i ($start_index .. $#segments) {
        my $segment = $segments[$i];
        next if exists $self->{segment_cache}->{$channel_id}->{$segment};
        
        # Check queue efficiently
        if ($self->{segment_queue}->{$channel_id}) {
            my $in_queue = 0;
            for my $queued (@{$self->{segment_queue}->{$channel_id}}) {
                if ($queued eq $segment) {
                    $in_queue = 1;
                    last;
                }
            }
            next if $in_queue;
        }
        
        push @uncached_segments, $segment;
    }
    
    # Queue uncached segments if appropriate
    if (@uncached_segments && (!$self->{segment_queue}->{$channel_id} || !@{$self->{segment_queue}->{$channel_id}})) {
        my $cache_size = 0;
        my $cache_count = 0;
        if ($self->{segment_cache}->{$channel_id}) {
            for my $cached_seg (keys %{$self->{segment_cache}->{$channel_id}}) {
                $cache_size += length($self->{segment_cache}->{$channel_id}->{$cached_seg});
                $cache_count++;
            }
        }
        
        main::log_info(sprintf("New playlist for channel %s has %d uncached segments, current cache: %d segments (%.2f MB)", 
                              $channel_id, scalar(@uncached_segments), $cache_count, $cache_size / 1024 / 1024));
        
        if (!$defer_caching) {
            $self->{segment_queue}->{$channel_id} = \@uncached_segments;
        } else {
            main::log_debug("Deferring segment queueing for channel $channel_id until client requests first segment");
        }
    }
    
    return scalar(@uncached_segments);
}

# Parse EXTINF tags from playlist content to calculate segment durations
sub parse_extinf_durations {
    my ($self, $content) = @_;
    
    # Parse #EXT-X-TARGETDURATION from playlist header per Apple HLS specification
    # Format: #EXT-X-TARGETDURATION:<duration>
    # This tag is REQUIRED in Media Playlists and specifies the maximum segment duration
    # More reliable than parsing individual #EXTINF tags
    
    my @lines = split /\r?\n/, $content;  # Handle both Unix and Windows line endings
    
    for my $line (@lines) {
        # Trim whitespace per HLS spec
        $line =~ s/^\s+|\s+$//g;
        
        # Match #EXT-X-TARGETDURATION:<duration>
        # Duration is an integer (decimal-integer per spec)
        if ($line =~ /^#EXT-X-TARGETDURATION:\s*(\d+)\s*$/) {
            my $duration = $1;
            main::log_debug("Found EXT-X-TARGETDURATION: $duration seconds");
            return $duration;
        }
    }
    
    # If no EXT-X-TARGETDURATION found, return default
    # Note: This shouldn't happen with valid HLS playlists, but we handle it gracefully
    main::log_debug("No EXT-X-TARGETDURATION found in playlist, using default 10 seconds");
    return 10;
}

# Calculate next playlist update time based on new segment count
sub calculate_playlist_update_delay {
    my ($self, $content, $new_segment_count, $channel_id) = @_;
    
    # Get segment duration from first EXTINF tag
    my $extinf_duration = $self->parse_extinf_durations($content);
    
    # Store the EXTINF duration for this channel for idle timeout checking
    $self->{channel_avg_duration}->{$channel_id} = $extinf_duration;
    
    # Match FFmpeg's HLS live-stream refresh heuristic:
    # - New segment(s) found  → refresh after one full EXTINF interval
    # - No new segment found  → refresh after half an EXTINF interval (poll faster)
    my ($delay, $strategy);
    if ($new_segment_count > 0) {
        $delay    = $extinf_duration;
        $strategy = "EXTINF";
    } else {
        $delay    = $extinf_duration / 2.0;
        $strategy = "EXTINF/2";
    }

    # Clamp to a sensible range
    $delay = 2  if $delay < 2;
    $delay = 30 if $delay > 30;

    main::log_debug(sprintf("Calculated playlist update delay: %.1f seconds (EXTINF: %.1f, new segments: %d, strategy: %s)",
                           $delay, $extinf_duration, $new_segment_count, $strategy));
    
    return $delay;
}

# Start precaching remaining segments in the background
sub precache_segments {
    my ($self, $channel_id, $current_segment) = @_;
    
    # Get the segment list for this channel
    my $segments = $self->{playlists}->{$channel_id}->{'segments'};
    return unless $segments && @$segments;
    
    # Find the index of the current segment
    my $current_index = -1;
    for my $i (0 .. $#$segments) {
        if ($segments->[$i] eq $current_segment) {
            $current_index = $i;
            last;
        }
    }
    
    if ($current_index < 0) {
        main::log_warn("Current segment $current_segment not found in playlist for channel $channel_id");
        return;
    }
    
    # Get remaining segments after the current one
    my @remaining_segments = @{$segments}[($current_index + 1) .. $#$segments];
    
    if (@remaining_segments) {
        # Calculate total cache size and count
        my $cache_size = 0;
        my $cache_count = 0;
        if ($self->{segment_cache}->{$channel_id}) {
            for my $cached_seg (keys %{$self->{segment_cache}->{$channel_id}}) {
                $cache_size += length($self->{segment_cache}->{$channel_id}->{$cached_seg});
                $cache_count++;
            }
        }
        
        main::log_info("Starting precache of " . scalar(@remaining_segments) . 
                      " segments for channel $channel_id, current cache: " . $cache_count . " segments (" . 
                      sprintf("%.2f MB", $cache_size / 1024 / 1024) . ")");
        main::log_debug("Segments to cache: " . join(", ", @remaining_segments));
        
        # Store the queue of segments to cache
        $self->{segment_queue}->{$channel_id} = \@remaining_segments;
        
        # Cache the first segment immediately in the background
        $self->cache_next_segment($channel_id);
    } else {
        main::log_debug("No remaining segments to precache for channel $channel_id");
    }
}

# Cache the next segment in the queue for a channel
sub cache_next_segment {
    my ($self, $channel_id) = @_;
    
    my $queue = $self->{segment_queue}->{$channel_id};
    return unless $queue && @$queue;
    
    # Cache up to SEGMENT_CACHE_BATCH_SIZE segments at a time to avoid blocking while making progress
    my $cached_count = 0;
    
    while ($cached_count < SEGMENT_CACHE_BATCH_SIZE && @$queue) {
        # Get the next segment to cache
        my $segment_path = shift @$queue;
        
        main::log_debug("Caching segment: $segment_path for channel $channel_id");
        
        # Fetch the segment
        my $segment_data = $self->get_segment($segment_path);
        
        if ($segment_data) {
            # Store in cache
            $self->{segment_cache}->{$channel_id}->{$segment_path} = $segment_data;
            main::log_info("Cached segment: $segment_path (" . length($segment_data) . " bytes) for channel $channel_id");
            # Clear any retry counter on success
            delete $self->{segment_retry_count}->{$channel_id}->{$segment_path};
            $cached_count++;
        } else {
            # Track retry attempts for this segment
            $self->{segment_retry_count}->{$channel_id} //= {};
            my $retries = ++$self->{segment_retry_count}->{$channel_id}->{$segment_path};

            if ($retries <= MAX_SEGMENT_RETRIES) {
                main::log_warn("Failed to cache segment: $segment_path for channel $channel_id"
                    . " (attempt $retries/" . MAX_SEGMENT_RETRIES . "), will retry in ~1s");
                # Put the segment back at the front of the queue so the next scheduler
                # tick (~1 s) retries it, rather than waiting for the next playlist refresh.
                unshift @$queue, $segment_path;
            } else {
                main::log_warn("Failed to cache segment: $segment_path for channel $channel_id"
                    . " after " . MAX_SEGMENT_RETRIES . " attempts, dropping segment");
                delete $self->{segment_retry_count}->{$channel_id}->{$segment_path};
            }
            # Stop this batch — don't skip past a failed segment on this tick.
            last;
        }
    }
    
    # Log progress
    my $remaining = scalar(@$queue);
    main::log_debug("Cached $cached_count segments for channel $channel_id, $remaining remaining segments to cache");
}

# Get a segment from cache or fetch it
sub get_cached_segment {
    my ($self, $segment_path, $channel_id) = @_;
    
    # Track this as the last requested segment for this channel
    $self->{last_segment}->{$channel_id} = $segment_path;
    $self->write_segment_pdt_file($channel_id, $segment_path);
    
    # Check if caching is enabled
    my $caching_enabled = $CONFIG{segment_drop} >= 1;
    
    # Check if segment is in cache (only if caching is enabled)
    if ($caching_enabled && exists $self->{segment_cache}->{$channel_id}->{$segment_path}) {
        main::log_info("Using cached segment: $segment_path for channel $channel_id");
        my $data = $self->{segment_cache}->{$channel_id}->{$segment_path};
        
        # Drop the segment from cache after use
        delete $self->{segment_cache}->{$channel_id}->{$segment_path};
        
        # Get the number of remaining cached segments for this channel
        my $remaining_segments = scalar keys %{$self->{segment_cache}->{$channel_id}};
        # Optionally log or output the count of remaining segments
        main::log_debug("Dropped cached segment: $segment_path, Segments in cache: $remaining_segments");
        
        # Start caching the next segment in the queue
        $self->cache_next_segment($channel_id);
        
        return $data;
    }
    
    # Not in cache, fetch it directly
    main::log_debug("Fetching segment directly: $segment_path for channel $channel_id");
    
    my $data = $self->get_segment($segment_path);
    
    # Only start precaching if caching is enabled
    if ($caching_enabled && $data) {
        # Start precaching remaining segments
        $self->precache_segments($channel_id, $segment_path);
    }
    
    return $data;
}

# Write the upstream PDT for the requested segment to $TMPDIR/siriusxm/pdt_<channel_id>.txt
sub write_segment_pdt_file {
    my ($self, $channel_id, $segment_path) = @_;

    my $segment_pdt = $self->{segment_pdt}->{$channel_id}->{$segment_path};
    if (!defined $segment_pdt || $segment_pdt eq '') {
        main::log_trace("No upstream PDT recorded for segment $segment_path on channel $channel_id");
        return;
    }

    my $tmp_dir = $ENV{TMPDIR} || $ENV{TEMP} || '/tmp';
    my $pdt_dir = File::Spec->catdir($tmp_dir, 'siriusxm');
    if (!-d $pdt_dir) {
        eval {
            File::Path::make_path($pdt_dir, { mode => 0755 });
            1;
        } or do {
            my $err = $@ || 'unknown error';
            main::log_debug("Could not create PDT directory $pdt_dir for channel $channel_id: $err");
            return;
        };
    }

    my $tmp_file = File::Spec->catfile($pdt_dir, "pdt_${channel_id}.txt.tmp");
    my $pdt_file = File::Spec->catfile($pdt_dir, "pdt_${channel_id}.txt");

    if (defined $self->{last_written_segment_pdt}->{$channel_id}
        && $self->{last_written_segment_pdt}->{$channel_id} eq $segment_pdt
        && -e $pdt_file) {
        main::log_trace("PDT unchanged for channel $channel_id; skipping file write");
        return;
    }

    eval {
        open(my $fh, '>', $tmp_file) or die "Cannot open temp PDT file: $!";
        print $fh $segment_pdt . "\n";
        close($fh) or die "Cannot close temp PDT file: $!";

        rename($tmp_file, $pdt_file) or die "Cannot rename PDT file: $!";
        $self->{last_written_segment_pdt}->{$channel_id} = $segment_pdt;
        1;
    } or do {
        my $err = $@ || 'unknown error';
        unlink($tmp_file) if -e $tmp_file;
        main::log_debug("Failed writing PDT file for channel $channel_id: $err");
        return;
    };

    main::log_trace("Updated PDT file for channel $channel_id");
}

sub select_quality_variant {
    my ($self, $master_playlist, $base_url, $quality, $channel_id) = @_;
    
    # Define bandwidth mappings for quality levels
    my %quality_bandwidths = (
        'High' => 281600,
        'Med'  => 105600,
        'Low'  => 70400,
    );
    
    # Get desired bandwidth from quality parameter
    my $desired_bandwidth = $quality_bandwidths{$quality};
    if (!$desired_bandwidth) {
        main::log_error("Invalid quality setting: $quality");
        return undef;
    }
    
    main::log_debug("Selecting quality variant for: $quality ($desired_bandwidth bps)");
    
    # Parse master playlist according to Apple HLS specification
    # #EXT-X-STREAM-INF tags are followed by the URI line
    my @lines = split /\r?\n/, $master_playlist;  # Handle both Unix and Windows line endings
    my %variants = ();
    
    # Parse master playlist to extract variants with their bandwidths
    for my $i (0..$#lines) {
        my $line = $lines[$i];
        # Trim whitespace per HLS spec
        $line =~ s/^\s+|\s+$//g;
        
        # Look for #EXT-X-STREAM-INF tag with BANDWIDTH attribute
        if ($line =~ /^#EXT-X-STREAM-INF:.*BANDWIDTH=(\d+)/) {
            my $bandwidth = $1;
            
            # Per HLS spec, URI line immediately follows (skip comments/empty lines)
            for my $j (($i + 1)..$#lines) {
                my $next_line = $lines[$j];
                $next_line =~ s/^\s+|\s+$//g;
                
                # Skip empty lines
                next if $next_line eq '';
                
                # If it's another tag, something is wrong - break
                last if $next_line =~ /^#/;
                
                # This should be the URI line
                my $variant_url = $next_line;
                
                # Convert relative URL to absolute if needed
                if ($variant_url !~ /^https?:\/\//) {
                    my $base = $base_url;
                    $base =~ s/\/[^\/]*$/\//;
                    $variant_url = $base . $variant_url;
                }
                
                $variants{$bandwidth} = $variant_url;
                main::log_trace("Found variant: $bandwidth bps -> $variant_url");
            }
        }
    }
    
    # Select the best matching variant
    my $selected_url = undef;
    my $selected_bandwidth = undef;
    
    if (exists $variants{$desired_bandwidth}) {
        # Exact match found
        $selected_url = $variants{$desired_bandwidth};
        $selected_bandwidth = $desired_bandwidth;
        main::log_debug("Found exact bandwidth match: $desired_bandwidth");
    } else {
        # Find closest match - prefer lower bandwidth over higher to avoid buffering issues
        my @available_bandwidths = sort { $a <=> $b } keys %variants;
        
        for my $bandwidth (@available_bandwidths) {
            if ($bandwidth <= $desired_bandwidth) {
                $selected_url = $variants{$bandwidth};
                $selected_bandwidth = $bandwidth;
            } else {
                last;
            }
        }
        
        # If no suitable lower bandwidth found, use the lowest available
        if (!$selected_url && @available_bandwidths) {
            $selected_bandwidth = $available_bandwidths[0];
            $selected_url = $variants{$selected_bandwidth};
            main::log_warn("No suitable quality variant found, using lowest: $selected_bandwidth");
        }
    }
    
    if ($selected_url) {
        main::log_info("Selected quality variant: $quality -> $selected_bandwidth bps");
        return $selected_url;
    } else {
        main::log_error("No quality variants found in master playlist");
        return undef;
    }
}

sub get_segment {
    my ($self, $path, $max_attempts) = @_;
    $max_attempts //= 5;
    
    # Extract channel ID from segment path (e.g., "9450_256k_1_072668629528_00389632_v3.aac" -> "9450" or "thepulse_256k_1_072668629528_00389632_v3.aac" -> "thepulse")
    my $channel_id;
    if ($path =~ /^([^_]+)_/) {
        $channel_id = $1;
    } else {
        main::log_error("Could not extract channel ID from segment path: $path");
        return undef;
    }
    
    # Get the stored base path for this channel
    my $base_path = $self->{channel_base_paths}->{$channel_id};
    if (!$base_path) {
        main::log_error("No base path stored for channel ID: $channel_id");
        return undef;
    }
    
    # Construct full segment URL with base path using the server for this channel
    my $server_name = $self->get_channel_server($channel_id);
    my $server_url = $server_name eq 'primary' ? LIVE_PRIMARY_HLS : LIVE_SECONDARY_HLS;
    my $url = $server_url . "/$base_path/$path";
    
    # Auth tokens come from the global jar; no set_channel_context needed
    my $token = $self->get_sxmak_token($channel_id);
    my $gup_id = $self->get_gup_id($channel_id);
    
    return undef unless $token && $gup_id;
    
    my $uri = URI->new($url);
    $uri->query_form(
        token    => $token,
        consumer => 'k2',
        gupId    => $gup_id,
    );
    
    main::log_info("Getting segment: $url");
    main::log_trace("Channel ID: $channel_id, Base path: $base_path, Server: $server_name");
    
    my $request  = HTTP::Request->new(GET => $uri);
    my $response = $self->make_channel_request($request, $channel_id);
    
    if ($response->code == 500) {
        my $status_code = $response->code;
        my $error_msg = "Received status code $status_code on segment for channel: $channel_id";
        $self->record_channel_failure($channel_id, $error_msg);
        main::log_warn("$error_msg – server may be temporarily unavailable, preserving cookies");
        return undef;
    } elsif ($response->code == 403) {
        my $status_code = $response->code;
        my $error_msg = "Received status code $status_code on segment for channel: $channel_id";
        $self->record_channel_failure($channel_id, $error_msg);

        if ($max_attempts > 0) {
            main::log_warn("$error_msg, renewing session");
            
            # Try re-authentication first (without clearing cookies)
            main::log_trace("Attempting to authenticate for channel: $channel_id to get new session tokens");
            if ($self->authenticate($channel_id)) {
                main::log_trace("Session renewed successfully for channel: $channel_id, retrying segment request");
                return $self->get_segment($path, $max_attempts - 1);
            } else {
                # A 403 is a genuine auth rejection – clear cookies and try a fresh login.
                main::log_debug("Re-authentication failed, clearing all cookies and retrying for channel $channel_id");
                $self->clear_all_cookies();
                main::log_trace("Attempting to authenticate for channel: $channel_id after clearing all cookies");
                if ($self->authenticate($channel_id)) {
                    main::log_trace("Session renewed successfully for channel: $channel_id after clearing cookies, retrying segment request");
                    return $self->get_segment($path, $max_attempts - 1);
                } else {
                    main::log_error("Session renewal failed for channel: $channel_id after clearing all cookies");
                    return undef;
                }
            }
        } else {
            main::log_error("$error_msg, max attempts exceeded");
            return undef;
        }
    }
    
    if (!$response->is_success) {
        my $error_msg = "Received status code " . $response->code . " on segment";
        main::log_error($error_msg);
        $self->record_channel_failure($channel_id, $error_msg);
        return undef;
    }
    
    # Record successful request
    $self->record_channel_success($channel_id);
    
    return $response->content;
}

# Load channel list from disk cache
# Returns 1 if channels were loaded (even if expired), 0 on failure
sub load_channel_cache {
    my ($self) = @_;

    return 0 unless $self->{channel_cache_file} && -e $self->{channel_cache_file};

    my $now = time();
    eval {
        open(my $fh, '<', $self->{channel_cache_file}) or die "Cannot open: $!";
        my $content = do { local $/; <$fh> };
        close($fh);

        my $cache_data = $self->{json}->decode($content);

        unless ($cache_data->{expires_at} && $cache_data->{channels} &&
                ref($cache_data->{channels}) eq 'ARRAY' && @{$cache_data->{channels}} > 0) {
            main::log_warn("Channel cache file is missing required fields or is empty");
            return;
        }

        my $channel_count = scalar(@{$cache_data->{channels}});

        # Restore tracked JSESSIONID expiry (persisted so it survives restarts).
        # Default to 0 (expired) if not present (older cache files or first run).
        if ($cache_data->{jsessionid_expires}) {
            $self->{jsessionid_expires} = $cache_data->{jsessionid_expires};
            my $j_remaining = $self->{jsessionid_expires} - $now;
            if ($j_remaining > 0) {
                my $j_min = int($j_remaining / 60);
                main::log_debug("Restored tracked JSESSIONID expiry: valid for ${j_min}m");
            } else {
                main::log_debug("Restored tracked JSESSIONID expiry: already expired, re-auth will run");
            }
        } else {
            $self->{jsessionid_expires} = 0;
            main::log_debug("No tracked JSESSIONID expiry in cache, re-auth will run on next refresh");
        }

        if ($cache_data->{expires_at} <= $now) {
            # Cache is expired – load it anyway so we can serve data during background refresh
            my $expired_at = strftime('%Y-%m-%d %H:%M:%S UTC', gmtime($cache_data->{expires_at}));
            main::log_info("Loaded $channel_count channels from expired cache (expired: $expired_at) – background refresh will run");
            $self->{channels}             = $cache_data->{channels};
            $self->{channel_cache_expires} = 0;  # Trigger immediate background refresh
        } else {
            my $remaining = $cache_data->{expires_at} - $now;
            my $hours   = int($remaining / 3600);
            my $minutes = int(($remaining % 3600) / 60);
            main::log_info("Loaded $channel_count channels from cache (expires in ${hours}h ${minutes}m)");
            $self->{channels}             = $cache_data->{channels};
            $self->{channel_cache_expires} = $cache_data->{expires_at};
        }
    };
    if ($@) {
        main::log_warn("Error loading channel cache from $self->{channel_cache_file}: $@");
        return 0;
    }

    return defined($self->{channels}) ? 1 : 0;
}

# Save channel list to disk cache with expiry timestamp
sub save_channel_cache {
    my ($self) = @_;

    return unless $self->{channel_cache_file} && defined $self->{channels} && @{$self->{channels}} > 0;

    my $now        = time();
    my $expires_at = $now + CHANNEL_CACHE_TTL;

    eval {
        my $cache_data = {
            fetched_at         => $now,
            expires_at         => $expires_at,
            jsessionid_expires => $self->{jsessionid_expires} || 0,
            channels           => $self->{channels},
        };

        open(my $fh, '>', $self->{channel_cache_file}) or die "Cannot open: $!";
        print $fh $self->{json}->encode($cache_data);
        close($fh);

        my $expires_str = strftime('%Y-%m-%d %H:%M:%S UTC', gmtime($expires_at));
        main::log_info("Saved " . scalar(@{$self->{channels}}) .
                       " channels to cache $self->{channel_cache_file} (expires: $expires_str)");
        $self->{channel_cache_expires} = $expires_at;
    };
    if ($@) {
        main::log_warn("Error saving channel cache to $self->{channel_cache_file}: $@");
    }
}

# Save per-channel server selection to a dedicated lightweight file (server_state.json).
# This is written on every server switch so state is always current, without the overhead
# of rewriting the full (large) channel list cache.
sub save_server_state {
    my ($self) = @_;

    return unless $self->{server_state_file};

    eval {
        my $state = { channel_server => $self->{channel_server} || {} };
        open(my $fh, '>', $self->{server_state_file}) or die "Cannot open: $!";
        print $fh $self->{json}->encode($state);
        close($fh);
        main::log_debug("Saved server state to $self->{server_state_file}");
    };
    if ($@) {
        main::log_warn("Error saving server state to $self->{server_state_file}: $@");
    }
}

# Load per-channel server selection from server_state.json on startup.
# Backward-compatible: silently skips if the file does not exist yet.
sub load_server_state {
    my ($self) = @_;

    return 0 unless $self->{server_state_file} && -e $self->{server_state_file};

    eval {
        open(my $fh, '<', $self->{server_state_file}) or die "Cannot open: $!";
        my $content = do { local $/; <$fh> };
        close($fh);

        my $state = $self->{json}->decode($content);
        if ($state->{channel_server} && ref($state->{channel_server}) eq 'HASH') {
            $self->{channel_server} = $state->{channel_server};
            my $count = scalar keys %{$self->{channel_server}};
            main::log_debug("Restored server selection for $count channel(s) from $self->{server_state_file}") if $count;
        }
    };
    if ($@) {
        main::log_warn("Error loading server state from $self->{server_state_file}: $@");
        return 0;
    }

    return 1;
}

# Background refresh: fetch fresh channel list from API when the cache has expired.
# The old channel data continues to be served while the refresh runs.
sub refresh_channel_cache_if_expired {
    my ($self) = @_;

    # Only run if we already have channel data (so old data can be served during refresh)
    return unless defined $self->{channels};

    # Only run when the cache has expired
    return unless time() >= $self->{channel_cache_expires};

    main::log_info("Channel cache expired – fetching fresh channel list in background...");

    # Temporarily advance the expiry so repeated loop iterations don't pile up.
    # If the refresh fails we will retry in 5 minutes.
    $self->{channel_cache_expires} = time() + 300;

    # Only re-authenticate when our tracked JSESSIONID expiry has passed.
    # JSESSIONID carries no explicit cookie timestamp; we set jsessionid_expires ourselves
    # in authenticate() and persist it in channels.json so it survives restarts.
    if (time() >= $self->{jsessionid_expires}) {
        my $hours = int(SESSION_MAX_LIFE / 3600);
        main::log_info("Background channel refresh: JSESSIONID expired (tracked lifetime ~${hours}h), re-authenticating...");
        if (!$self->authenticate(undef)) {
            main::log_warn("Background channel refresh: re-authentication failed – keeping existing channel list, retry in 5 minutes");
            return;
        }
        # jsessionid_expires is updated by authenticate() on success
    } else {
        my $remaining = int(($self->{jsessionid_expires} - time()) / 60);
        main::log_debug("Background channel refresh: JSESSIONID valid for ${remaining}m, skipping re-auth");
    }

    my $old_channels = $self->{channels};

    eval {
        my $postdata = {
            moduleList => {
                modules => [{
                    moduleArea => 'Discovery',
                    moduleType => 'ChannelListing',
                    moduleRequest => {
                        consumeRequests => [],
                        resultTemplate  => 'responsive',
                        alerts          => [],
                        profileInfos    => [],
                    },
                }],
            },
        };

        my $data = $self->post_request('get', $postdata, 1, undef);
        unless ($data) {
            main::log_warn("Background channel refresh: no data returned by server – keeping existing channel list");
            return;
        }

        my $channels;
        eval {
            $channels = $data->{ModuleListResponse}->{moduleList}->{modules}->[0]->{moduleResponse}->{contentData}->{channelListing}->{channels};
        };

        unless (defined $channels && ref($channels) eq 'ARRAY' && @$channels > 0) {
            main::log_warn("Background channel refresh: invalid or empty response – keeping existing channel list");
            return;
        }

        # Replace the in-memory channel list with fresh data
        $self->{channels} = $channels;
        main::log_info("Background channel refresh complete: " . scalar(@$channels) . " channels loaded");

        # Persist the fresh list and update expiry
        $self->save_channel_cache();
    };

    if ($@) {
        main::log_warn("Background channel refresh error: $@ – keeping existing channel list, retry in 5 minutes");
        # Preserve old channel data if the refresh blew away $self->{channels}
        $self->{channels} //= $old_channels;
    }
}

sub get_channels {
    my $self = shift;
    my $retry_count = shift || 0;
    my $reauth_attempted = shift || 0; # Track if we've attempted reauthorization
    my $max_retries = 1; # Reduce from 3 to 1 simple retry
    my $retry_delay = 2; # Use fixed delay of 2 seconds
    
    # Download channel list if necessary - cache indefinitely for playback use
    if (!defined $self->{channels}) {
        main::log_debug("Fetching channel list" . ($retry_count > 0 ? " (retry $retry_count/$max_retries)" : ""));
        
        my $postdata = {
            moduleList => {
                modules => [{
                    moduleArea => 'Discovery',
                    moduleType => 'ChannelListing',
                    moduleRequest => {
                        consumeRequests => [],
                        resultTemplate  => 'responsive',
                        alerts          => [],
                        profileInfos    => [],
                    }
                }]
            }
        };
        
        my $data = $self->post_request('get', $postdata, 1, undef);  # Use global authentication for channel listing
        if (!$data) {
            main::log_error('Unable to get channel list - no data returned from server');
            if ($retry_count < $max_retries) {
                main::log_info("Retrying channel fetch in $retry_delay seconds...");
                sleep($retry_delay);
                return $self->get_channels($retry_count + 1, $reauth_attempted);
            }
            main::log_error("Failed to get channel list after $max_retries retries");

            # Add trace logging to dump server response
            main::log_error("Channel list response received: " . $self->{json}->encode($data));
        
            return [];
        }
        
        # Check for API response status - only code 100 indicates success
        my ($status, $message, $message_code);
        eval {
            $status = $data->{ModuleListResponse}->{status};
            if (exists $data->{ModuleListResponse}->{messages} && 
                ref($data->{ModuleListResponse}->{messages}) eq 'ARRAY' &&
                @{$data->{ModuleListResponse}->{messages}} > 0) {
                $message = $data->{ModuleListResponse}->{messages}->[0]->{message};
                $message_code = $data->{ModuleListResponse}->{messages}->[0]->{code};
            }
        };
        if ($@) {
            main::log_debug("No status messages found in channel list response, proceeding with channel parsing");
        }
        
        # Check for successful response (code 100) - anything else is an error
        if (defined $message_code && $message_code != 100) {
            # Handle session expiration codes specifically
            if ($message_code == 201 || $message_code == 208) {
                if (!$reauth_attempted) {
                    main::log_warn("Session expired (code: $message_code), clearing all cookies and re-authenticating");
                    $self->clear_all_cookies();
                    
                    if ($self->authenticate(undef)) {
                        main::log_info("Successfully re-authenticated for channel list");
                        # Reset retry count and try again with fresh authentication
                        return $self->get_channels(0, 1); # reauth_attempted = 1
                    } else {
                        main::log_error("Failed to re-authenticate for channel list");
                        return [];
                    }
                } else {
                    main::log_error("Session expired after re-authentication attempt, giving up");
                    return [];
                }
            } else {
                # Handle other error codes
                main::log_error("API returned error code $message_code: $message");
                if ($retry_count < $max_retries) {
                    main::log_info("Retrying channel fetch in $retry_delay seconds...");
                    sleep($retry_delay);
                    return $self->get_channels($retry_count + 1, $reauth_attempted);
                }
                main::log_error("Failed to get channel list after $max_retries retries due to API error");
                return [];
            }
        }
        
        my $channels;
        eval {
            $channels = $data->{ModuleListResponse}->{moduleList}->{modules}->[0]->{moduleResponse}->{contentData}->{channelListing}->{channels};
        };
        if ($@) {
            main::log_error("Error parsing JSON response for channels: $@");
            if ($retry_count < $max_retries) {
                main::log_info("Retrying channel fetch in $retry_delay seconds...");
                sleep($retry_delay);
                return $self->get_channels($retry_count + 1, $reauth_attempted);
            }
            main::log_error("Failed to parse channel data after $max_retries retries");
            return [];
        }
        
        # Ensure channels is defined and is an array reference
        if (!defined $channels || ref($channels) ne 'ARRAY') {
            main::log_error("Channel data is not in expected format - received: " . (defined $channels ? ref($channels) : 'undef'));
            main::log_error("Channel data received: " . $self->{json}->encode($data));
            
            # Simple retry only (session expiration already handled above)
            if ($retry_count < $max_retries) {
                main::log_info("Retrying channel fetch in $retry_delay seconds...");
                sleep($retry_delay);
                return $self->get_channels($retry_count + 1, $reauth_attempted);
            }
            
            main::log_error("Channel data format invalid after $max_retries retries");
            return [];
        }
        
        # Check if we got an empty channel list
        if (@$channels == 0) {
            main::log_warn("Server returned empty channel list");
            if ($retry_count < $max_retries) {
                main::log_info("Retrying channel fetch in $retry_delay seconds...");
                sleep($retry_delay);
                return $self->get_channels($retry_count + 1, $reauth_attempted);
            }
            main::log_error("Received empty channel list after $max_retries retries");
            # Don't cache empty results - let subsequent calls retry
            return [];
        }
        
        # Only cache successful, non-empty results
        $self->{channels} = $channels;
        main::log_info("Loaded " . @{$self->{channels}} . " channels");

        # Persist to disk cache so future startups can load without hitting the API
        $self->save_channel_cache();
    }
    
    return $self->{channels};
}

sub refresh_channels {
    my $self = shift;
    
    # Clear cached channels to force refresh
    main::log_debug("Refreshing channel data (clearing cache)");
    delete $self->{channels};
    
    # Fetch fresh channel data
    return $self->get_channels();
}

# Check and refresh expired playlists
sub refresh_expired_playlists {
    my $self = shift;
    
    # Skip if caching is disabled
    return unless $CONFIG{segment_drop} >= 1;
    
    my $now = time();
    my @channels_to_refresh;
    my @channels_to_clear;
    
    # Check all channels with scheduled updates
    for my $channel_id (keys %{$self->{playlist_next_update}}) {
        # Check if channel has been idle for too long (4x EXTINF duration)
        if (exists $self->{channel_last_activity}->{$channel_id} && 
            exists $self->{channel_avg_duration}->{$channel_id}) {
            
            my $last_activity = $self->{channel_last_activity}->{$channel_id};
            my $avg_duration = $self->{channel_avg_duration}->{$channel_id};
            my $idle_timeout = $avg_duration * 4;
            my $idle_time = $now - $last_activity;
            
            if ($idle_time >= $idle_timeout) {
                main::log_info(sprintf("Channel %s idle for %.1fs (timeout: %.1fs, 4x avg duration of %.1fs) - stopping refresh and clearing cache", 
                                      $channel_id, $idle_time, $idle_timeout, $avg_duration));
                push @channels_to_clear, $channel_id;
                next;  # Skip refresh for this channel
            }
        }
        
        # Check if playlist needs refresh
        my $next_update = $self->{playlist_next_update}->{$channel_id};
        if ($now >= $next_update) {
            push @channels_to_refresh, $channel_id;
        }
    }
    
    # Clear cache for idle channels
    for my $channel_id (@channels_to_clear) {
        $self->clear_channel_cache($channel_id);
    }
    
    # Refresh expired playlists for active channels
    for my $channel_id (@channels_to_refresh) {
        main::log_debug("Background refresh: Fetching new playlist for channel $channel_id");
        
        # Get the channel name from our cached mapping
        my $channel_name = $self->{playlist_channel_name}->{$channel_id};
        
        if ($channel_name) {
            # Save old playlist content so clients keep getting something if the refresh fails
            my $old_cache = $self->{playlist_cache}->{$channel_id};

            # Clear the playlist content cache so get_playlist fetches a fresh copy
            delete $self->{playlist_cache}->{$channel_id};
            delete $self->{playlist_next_update}->{$channel_id};

            # Fetch new playlist (this will update the cache and schedule next update on success)
            my $result;
            eval {
                $result = $self->get_playlist($channel_name, 1);
            };
            if ($@) {
                main::log_warn("Error refreshing playlist for channel $channel_id: $@");
                $result = undef;
            }

            if (!$result) {
                # Fetch failed (e.g. transient server error) — restore old cache so clients
                # are still served during the outage, and reschedule a retry in 2 seconds
                # instead of dropping the channel from the background refresh queue.
                $self->{playlist_cache}->{$channel_id} = $old_cache if $old_cache;
                $self->{playlist_next_update}->{$channel_id} = time() + 2;
                main::log_debug("Background refresh failed for channel $channel_id, retrying in 2 seconds");
            }
        } else {
            main::log_warn("Could not find channel name for channel_id $channel_id in cache");
        }
    }
}

# Process segment caching queues for all active channels
sub process_segment_queues {
    my $self = shift;
    
    # Skip if caching is disabled
    return unless $CONFIG{segment_drop} >= 1;
    
    # Iterate through all channels with segment queues
    for my $channel_id (keys %{$self->{segment_queue}}) {
        my $queue = $self->{segment_queue}->{$channel_id};
        
        # Skip if queue is empty
        next unless $queue && @$queue;
        
        # Cache a batch of segments for this channel
        $self->cache_next_segment($channel_id);
    }
}

sub get_channel {
    my ($self, $name) = @_;
    
    $name = lc($name);
    my $channels = $self->get_channels();
    
    for my $channel (@$channels) {
        my $channel_name = lc($channel->{name} || '');
        my $channel_id = lc($channel->{channelId} || '');
        my $sirius_number = $channel->{siriusChannelNumber} || '';
        
        if ($channel_name eq $name || $channel_id eq $name || $sirius_number eq $name) {
            main::log_debug("Found channel: $name -> $channel->{channelId}");
            return ($channel->{channelGuid}, $channel->{channelId});
        }
    }
    
    main::log_warn("Channel not found: $name");
    return (undef, undef);
}

sub get_simplified_channel_info {
    my ($self, $name) = @_;
    
    $name = lc($name);
    my $channels = $self->get_channels();
    
    for my $channel (@$channels) {
        my $channel_name = lc($channel->{name} || '');
        my $channel_id = lc($channel->{channelId} || '');
        my $sirius_number = $channel->{siriusChannelNumber} || '';
        
        if ($channel_name eq $name || $channel_id eq $name || $sirius_number eq $name) {
            main::log_debug("Found channel for simplified info: $name -> $channel->{channelId}");
            my $data = $self->{json}->encode($channel);
            main::log_trace("Channel content: $data");

            # Extract simplified channel information
            my $simplified_info = {
                channelId => $channel->{channelId},
                siriusChannelNumber => $channel->{siriusChannelNumber},
                name => $channel->{name}
            };
            
            # Get the URL of the 4th image (index 3) from the images array
            if (defined $channel->{images}->{images} && ref($channel->{images}->{images}) eq 'ARRAY' && @{$channel->{images}->{images}} > 3) {
                $simplified_info->{imageUrl} = $channel->{images}->{images}->[3]->{url};
            }
            
            return $simplified_info;
        }
    }
    
    main::log_warn("Channel not found for simplified info: $name");
    return undef;
}

# Clear all cached data for a channel (used when idle timeout exceeded)
sub clear_channel_cache {
    my ($self, $channel_id) = @_;
    
    main::log_info("Clearing all cached data for idle channel: $channel_id");
    
    # Clear playlist cache
    delete $self->{playlist_cache}->{$channel_id};
    delete $self->{playlist_channel_name}->{$channel_id};
    delete $self->{playlist_next_update}->{$channel_id};
    delete $self->{playlists}->{$channel_id}->{'First'};
    
    # Clear segment cache and queue
    delete $self->{segment_cache}->{$channel_id};
    delete $self->{segment_queue}->{$channel_id};
    delete $self->{segment_pdt}->{$channel_id};
    delete $self->{last_written_segment_pdt}->{$channel_id};
    delete $self->{segment_retry_count}->{$channel_id};
    delete $self->{last_segment}->{$channel_id};

    # Remove persisted PDT files for this channel from $TMPDIR/siriusxm
    my $tmp_dir = $ENV{TMPDIR} || $ENV{TEMP} || '/tmp';
    my $pdt_dir = File::Spec->catdir($tmp_dir, 'siriusxm');
    if (-d $pdt_dir) {
        my $pdt_file = File::Spec->catfile($pdt_dir, "pdt_${channel_id}.txt");
        my $pdt_tmp_file = File::Spec->catfile($pdt_dir, "pdt_${channel_id}.txt.tmp");
        unlink($pdt_file) if -e $pdt_file;
        unlink($pdt_tmp_file) if -e $pdt_tmp_file;
    }
    
    # Clear activity tracking
    delete $self->{channel_last_activity}->{$channel_id};
    delete $self->{channel_avg_duration}->{$channel_id};
    delete $self->{playlist_hold_count}->{$channel_id};
    
    # Reset server selection so the next new session tries primary again
    $self->reset_channel_server($channel_id);
    
    main::log_debug("Cleared playlist, segment cache, and activity data for channel $channel_id");
}

# Update last activity time for a channel
sub update_channel_activity {
    my ($self, $channel_id) = @_;
    
    $self->{channel_last_activity}->{$channel_id} = time();
    main::log_trace("Updated activity timestamp for channel $channel_id");
}

1;

#=============================================================================
# HTTP Server Handler
#=============================================================================

package SiriusHandler;

use strict;
use warnings;
use MIME::Base64;

# HLS AES Key (base64 decoded)
use constant HLS_AES_KEY => decode_base64('0Nsco7MAgxowGvkUT8aYag==');

#=============================================================================
# HTTP Daemon Handler  
#=============================================================================

sub start_http_daemon {
    my ($sxm, $port) = @_;

    my $max_retries = 3;  # Configure maximum number of retry attempts
    my $retry_delay = 2;  # Delay in seconds between retries
    my $daemon;
    my $attempts = 0;

    while (!$daemon && $attempts < $max_retries) {
        $attempts++;

        $daemon = HTTP::Daemon->new(
            LocalPort => $port,
            LocalAddr => '0.0.0.0',
            ReuseAddr => 1,
        );

        if (!$daemon) {
            main::log_error("Attempt $attempts/$max_retries: Could not create HTTP server on port $port: $!");

            if ($attempts < $max_retries) {
                sleep($retry_delay);
            }
        }
    }

    if (!$daemon) {
        main::log_error("Failed to create HTTP server after $max_retries attempts");
        return undef;
    }

    main::log_info("HTTP server started on port $port");
    main::log_info("Access channels at: http://127.0.0.1:$port/channel.m3u8");
    
    # Create IO::Select for non-blocking accept with timeout
    my $select = IO::Select->new($daemon);
    my $last_refresh_check = time();
    my $refresh_check_interval = 1;  # Check for expired playlists every 1 seconds
    
    while ($main::RUNNING) {
        # Check if any expired playlists need refreshing or segments need caching
        my $now = time();
        if ($now - $last_refresh_check >= $refresh_check_interval) {
            $sxm->refresh_expired_playlists();
            $sxm->process_segment_queues();
            $sxm->refresh_channel_cache_if_expired();
            $last_refresh_check = $now;
        }
        
        # Wait for client connection with timeout
#        main::log_trace("Server loop iteration, waiting for client connection");
        my @ready = $select->can_read(1.0);  # 1 second timeout
        
        if (!@ready) {
            # No client connection within timeout, continue loop
#            main::log_trace("No client connection within timeout, continuing loop");
            next;
        }
        
        my $client = $daemon->accept();
        if (!$client) {
#            main::log_trace("No client connection, continuing loop");
            next;
        }
        
        main::log_debug("Client connected, handling request");
        
        # Handle client with timeout and error handling
        eval {
            local $SIG{ALRM} = sub { die "timeout" };
            local $SIG{PIPE} = 'IGNORE'; # Ignore broken pipe for this client
            alarm(10); # Reduced timeout to 10 seconds
            
            # Handle only one request per connection to avoid holding connections open
            my $request = $client->get_request();
            if ($request) {
                handle_http_request($client, $request, $sxm);
            }
            
            alarm(0);
        };
        if ($@) {
            if ($@ =~ /timeout/) {
                main::log_warn("Client request timeout");
            } else {
                main::log_warn("Client request error: $@");
            }
        }
        
        # Ensure client connection is properly closed
        eval {
            $client->close();
        };
        undef $client;
        main::log_debug("Client connection closed");
    }
    
    main::log_debug("Server shutdown - daemon closed");
    
    $daemon->close();
    return 1;
}

sub handle_http_request {
    my ($client, $request, $sxm) = @_;
    
    my $path = $request->uri->path;
    my $method = $request->method;
    
    main::log_debug("$method request: $path");
    
    if ($method ne 'GET') {
        send_error_response($client, 405, 'Method Not Allowed');
        return;
    }
    
    if ($path =~ /\.m3u8$/) {
        # Handle playlist requests
        my $channel = $path;
        $channel =~ s/^\/(.+)\.m3u8$/$1/;
        
        main::log_debug("Playlist request for channel: $channel");
        
        my $data = $sxm->get_playlist($channel);
        if ($data) {
            # Update activity timestamp for this channel
            my ($guid, $channel_id) = $sxm->get_channel($channel);
            if ($channel_id) {
                $sxm->update_channel_activity($channel_id);
            }
            
            my $response = HTTP::Response->new(200);
            $response->content_type('application/x-mpegURL');
            $response->header('Connection', 'close');
            $response->content($data);
            eval { $client->send_response($response); };
            if ($@) {
                main::log_warn("Error sending playlist response: $@");
            }
        } else {
            send_error_response($client, 500, 'Internal Server Error');
        }
    }
    elsif ($path =~ /\.aac$/) {
        # Handle audio segment requests
        my $segment_path = $path;
        $segment_path =~ s/^\/(.+)$/$1/;
        
        main::log_debug("Segment request: $segment_path");
        
        # Extract channel_id from segment path
        my $channel_id;
        if ($segment_path =~ /^([^_]+)_/) {
            $channel_id = $1;
        }
        
        my $data;
        if ($channel_id) {
            # Update activity timestamp for this channel
            $sxm->update_channel_activity($channel_id);
            
            # Use cached segment if available
            $data = $sxm->get_cached_segment($segment_path, $channel_id);
        } else {
            # Fallback to direct fetch if we can't extract channel_id
            main::log_warn("Could not extract channel_id from segment path: $segment_path");
            $data = $sxm->get_segment($segment_path);
        }
        
        if ($data) {
            my $response = HTTP::Response->new(200);
            $response->content_type('audio/x-aac');
            $response->header('Connection', 'close');
            $response->content($data);
            eval { $client->send_response($response); };
            if ($@) {
                main::log_warn("Error sending segment response: $@");
            }
        } else {
            send_error_response($client, 500, 'Internal Server Error');
        }
    }
    elsif ($path eq '/key/1') {
        # Handle encryption key requests
        main::log_trace("Key request");
        
        my $response = HTTP::Response->new(200);
        $response->content_type('text/plain');
        $response->header('Connection', 'close');
        $response->content(HLS_AES_KEY);
        eval { $client->send_response($response); };
        if ($@) {
            main::log_warn("Error sending HLS_AES key response: $@");
        }
    }
    elsif ($path =~ /^\/channel\/(.+)$/) {
        # Handle channel info requests
        my $channel = $1;
        my $channel_info;
        
        main::log_debug("Channel info request for: $channel");
        
        if ( $channel eq 'all' ) {
            $channel_info = $sxm->get_channels();
        } else {
            $channel_info = $sxm->get_simplified_channel_info($channel);
        }
        if ($channel_info) {
            my $json_data = $sxm->{json}->encode($channel_info);
            my $response = HTTP::Response->new(200);
            $response->content_type('application/json');
            $response->header('Connection', 'close');
            $response->content($json_data);
            eval { $client->send_response($response); };
            if ($@) {
                main::log_warn("Error sending channel info response: $@");
            }
        } else {
            send_error_response($client, 404, 'Channel Not Found');
        }
    }
    elsif ($path eq '/auth') {
        # Handle authentication state requests
        main::log_debug("Authentication state request");
        
        my $authenticated = ($sxm->is_logged_in() && $sxm->is_session_authenticated()) ? 1 : 0;
        my $auth_state = { authenticated => $authenticated };
        my $json_data = $sxm->{json}->encode($auth_state);
        
        my $response = HTTP::Response->new(200);
        $response->content_type('application/json');
        $response->header('Connection', 'close');
        $response->content($json_data);
        eval { $client->send_response($response); };
        if ($@) {
            main::log_warn("Error sending authentication state response: $@");
        }
    }
    else {
        # Handle unknown requests
        main::log_warn("Unknown request: $path");
        send_error_response($client, 404, 'Not Found');
    }
}

sub send_error_response {
    my ($client, $code, $message) = @_;
    
    my $response = HTTP::Response->new($code);
    $response->content_type('text/plain');
    $response->header('Connection', 'close');
    $response->content($message);
    eval { $client->send_response($response); };
    if ($@) {
        main::log_warn("Error sending error response: $@");
    }
}

#=============================================================================
# Main program 
#=============================================================================

package main;

sub parse_arguments {
    my $help_text = 0;
    
    GetOptions(
        'list|l'        => \$CONFIG{list},
        'port|p=i'      => \$CONFIG{port},
        'canada|ca'     => \$CONFIG{canada},
        'env|e'         => \$CONFIG{env},
        'verbose|v=s'   => sub {
            my ($name, $value) = @_;
            my %levels = (
                'ERROR' => LOG_ERROR,
                'WARN'  => LOG_WARN,
                'INFO'  => LOG_INFO,
                'DEBUG' => LOG_DEBUG,
                'TRACE' => LOG_TRACE,
            );
            if (exists $levels{uc($value)}) {
                $CONFIG{verbose} = $levels{uc($value)};
            } else {
                die "Invalid verbose level: $value. Use: ERROR, WARN, INFO, DEBUG, TRACE\n";
            }
        },
        'quality|q=s'   => sub {
            my ($name, $value) = @_;
            my %qualities = (
                'HIGH' => 'High',
                'MED'  => 'Med', 
                'LOW'  => 'Low',
            );
            if (exists $qualities{uc($value)}) {
                $CONFIG{quality} = $qualities{uc($value)};
            } else {
                die "Invalid quality level: $value. Use: High, Med, Low\n";
            }
        },
        'segment-drop=i' => sub {
            my ($name, $value) = @_;
            my $orig = $value;
            $value = 0  if $value < 0;
            $value = 30 if $value > 30;

            if ($value != $orig) {
                warn "segment-drop value $value exceeds 30 clamping\n";
            }
            $CONFIG{segment_drop} = $value;
        },
        'logfile=s'     => \$CONFIG{logfile},
        'cookiefile=s'  => \$CONFIG{cookiefile},
        'lmsroot=s'     => \$CONFIG{lmsroot},
        'help|h'        => \$help_text,
    ) or pod2usage(2);
    
    pod2usage(1) if $help_text;
    
    # Get username and password from arguments (optional if --env is set)
    if ($CONFIG{env}) {
        # When using --env, allow optional or dummy arguments
        if (@ARGV >= 2) {
            $CONFIG{username} = shift @ARGV;
            $CONFIG{password} = shift @ARGV;
        } else {
            # Set dummy values that will be overridden by environment variables
            $CONFIG{username} = 'dummy';
            $CONFIG{password} = 'dummy';
        }
    } else {
        # When not using --env, require username and password
        if (@ARGV >= 2) {
            $CONFIG{username} = shift @ARGV;
            $CONFIG{password} = shift @ARGV;
        } else {
            pod2usage("Error: username and password are required (or use --env with SXM_USER and SXM_PASS environment variables)\n");
        }
    }
    
    # Handle environment variables
    if ($CONFIG{env}) {
        if ($ENV{SXM_USER}) {
            $CONFIG{username} = $ENV{SXM_USER};
            log_debug("Using username from SXM_USER environment variable");
        }
        if ($ENV{SXM_PASS}) {
            $CONFIG{password} = $ENV{SXM_PASS};
            log_debug("Using password from SXM_PASS environment variable");
        }
        
        # Validate that we have valid credentials when using --env
        if (!$ENV{SXM_USER} || !$ENV{SXM_PASS}) {
            pod2usage("Error: When using --env, both SXM_USER and SXM_PASS environment variables must be set\n");
        }
    }
    
    log_info("Configuration loaded - Port: $CONFIG{port}, Region: " . ($CONFIG{canada} ? 'CA' : 'US'));
}

sub list_channels {
    my $sxm = shift;
    
    log_info("Fetching channel list...");
    
    # Ensure we're authenticated first (use global authentication for channel listing)
    if (!$sxm->authenticate()) {
        log_error("Authentication failed - cannot fetch channels");
        return;
    }
    
    my $channels = $sxm->get_channels();
    if (!@$channels) {
        log_error("No channels available or channel fetch failed");
        return;
    }
    
    # Sort channels by favorite status and channel number
    my @sorted_channels = sort {
        my $a_fav = $a->{isFavorite} || 0;
        my $b_fav = $b->{isFavorite} || 0;
        my $a_num = $a->{siriusChannelNumber} || 9999;
        my $b_num = $b->{siriusChannelNumber} || 9999;
        
        # Favorites first, then by channel number
        ($b_fav <=> $a_fav) || ($a_num <=> $b_num);
    } @$channels;
    
    # Calculate column widths
    my $max_id_len = 0;
    my $max_num_len = 0;
    my $max_name_len = 0;
    
    for my $channel (@sorted_channels) {
        my $id_len = length($channel->{channelId} || '');
        my $num_len = length($channel->{siriusChannelNumber} || '??');
        my $name_len = length($channel->{name} || '??');
        
        $max_id_len = $id_len if $id_len > $max_id_len;
        $max_num_len = $num_len if $num_len > $max_num_len;
        $max_name_len = $name_len if $name_len > $max_name_len;
    }
    
    # Ensure minimum widths
    $max_id_len = 2 if $max_id_len < 2;    # "ID"
    $max_num_len = 3 if $max_num_len < 3;  # "Num"
    $max_name_len = 4 if $max_name_len < 4; # "Name"
    
    # Print header
    printf "%-${max_id_len}s | %-${max_num_len}s | %-${max_name_len}s\n", 
           'ID', 'Num', 'Name';
    print '-' x ($max_id_len + $max_num_len + $max_name_len + 6) . "\n";
    
    # Print channels
    for my $channel (@sorted_channels) {
        my $id = substr($channel->{channelId} || '', 0, $max_id_len);
        my $num = substr($channel->{siriusChannelNumber} || '??', 0, $max_num_len);
        my $name = substr($channel->{name} || '??', 0, $max_name_len);
        
        printf "%-${max_id_len}s | %-${max_num_len}s | %-${max_name_len}s\n",
               $id, $num, $name;
    }
    
    log_info("Listed " . @sorted_channels . " channels");
}

sub start_server {
    my $sxm = shift;
    
    log_info("Starting HTTP server on port $CONFIG{port}");
    
    # Test authentication before starting server (use global authentication for server startup)
    if (!$sxm->authenticate()) {
        log_error("Authentication failed - cannot start server");
        exit(1);
    }
    
    log_info("Authentication successful - starting server");

    # Ensure channel list is available at startup.
    # get_channels() fetches from the API when:
    #   - The cache file does not exist ($self->{channels} is undef)
    #   - The cache file was corrupt ($self->{channels} is undef)
    # For an expired cache, channels were pre-loaded by load_channel_cache() and the
    # background refresh in the server loop will fetch updated data asynchronously.
    my $channels = $sxm->get_channels();
    if (!$channels || !@$channels) {
        log_warn("Unable to load channel list at startup - channels will be retried on demand");
    } else {
        log_info("Channel list ready at startup: " . scalar(@$channels) . " channels");
    }

    # Start HTTP daemon
    eval {
        SiriusHandler::start_http_daemon($sxm, $CONFIG{port});
    };
    if ($@) {
        log_error("Server error: $@");
        exit(1);
    }
    
    log_info("Server shutdown complete");
}

sub main {
    parse_arguments();
    
    # Initialize logging using LMS logging system
    init_logging($CONFIG{verbose}, $CONFIG{logfile});
    
    log_info("Starting SiriusXM Perl proxy v$VERSION");
    
    # Create SiriusXM object with cookie file
    my $region = $CONFIG{canada} ? 'CA' : 'US';
    $SIRIUS_XM = SiriusXM->new($CONFIG{username}, $CONFIG{password}, $region, $CONFIG{cookiefile});
    
    if ($CONFIG{list}) {
        list_channels($SIRIUS_XM);
    } else {
        start_server($SIRIUS_XM);
    }
}

# Run main program
main() unless caller;

__END__
