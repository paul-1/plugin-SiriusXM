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
        --segment-drop NUM      Number of segments to drop from first playlist (default: 3, max: 30)
        --logfile FILE          Log file location (default: /var/log/sxm-proxy.log)
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

our $VERSION = '1.1.0';
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
        log4perl.appender.logfile.layout.ConversionPattern = [%d{dd.MM.yyyy HH:mm:ss.SSS}] %5p <%M>:%4L: %m%n
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
#use Data::Dumper;

# Constants
use constant {
    USER_AGENT              => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_12_6) AppleWebKit/604.5.6 (KHTML, like Gecko) Version/11.0.3 Safari/604.5.6',
    REST_FORMAT             => 'https://player.siriusxm.com/rest/v2/experience/modules/%s',
    LIVE_PRIMARY_HLS        => 'https://siriusxm-priprodlive.akamaized.net',
    LIVE_SECONDARY_HLS      => 'https://siriusxm-secprodlive.akamaized.net',
    SEGMENT_CACHE_BATCH_SIZE => 2,  # Number of segments to cache per iteration
};

sub new {
    my ($class, $username, $password, $region) = @_;
    
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
        last_segment => {},     # Track last requested segment per channel_id
        playlist_cache => {},   # Store cached m3u8 content per channel_id
        playlist_channel_name => {}, # Store channel name for each channel_id for efficient lookup
        playlist_next_update => {}, # Track next scheduled update time per channel_id
        channel_last_activity => {}, # Track last client activity time per channel_id
        channel_avg_duration => {},  # Track average EXTINF duration per channel_id
 
        ua        => undef,
        json      => JSON::XS->new->utf8->canonical,
    };
    
    bless $self, $class;
    
    # Initialize user agent
    $self->{ua} = LWP::UserAgent->new(
        agent      => USER_AGENT,
        cookie_jar => HTTP::Cookies->new,
        timeout    => 30,
    );
    
    main::log_debug("SiriusXM object created for user: $username, region: $self->{region}");
    
    return $self;
}

# Get or create cookie jar for a specific channel
sub get_channel_cookie_jar {
    my ($self, $channel_id) = @_;
    
    # If no channel_id specified, use global cookie jar for backward compatibility
    return $self->{ua}->cookie_jar unless $channel_id;
    
    # Create channel-specific cookie jar if it doesn't exist
    if (!exists $self->{channel_cookies}->{$channel_id}) {
        $self->{channel_cookies}->{$channel_id} = HTTP::Cookies->new;
        main::log_debug("Created new cookie jar for channel: $channel_id");
    }
    
    return $self->{channel_cookies}->{$channel_id};
}

# Set the user agent to use a specific channel's cookie jar
sub set_channel_context {
    my ($self, $channel_id) = @_;
    
    my $cookie_jar = $self->get_channel_cookie_jar($channel_id);
    $self->{ua}->cookie_jar($cookie_jar);
    
    main::log_trace("Set cookie context for channel: " . ($channel_id || 'global'));
}

# Clear all cookies for a specific channel (or global if no channel_id)
sub clear_channel_cookies {
    my ($self, $channel_id) = @_;
    
    my $context = $channel_id ? "channel $channel_id" : "global";
    
    if ($channel_id) {
        # Create a fresh cookie jar for this channel
        $self->{channel_cookies}->{$channel_id} = HTTP::Cookies->new;
        main::log_debug("Cleared cookies for $context");
    } else {
        # Clear global cookie jar
        $self->{ua}->cookie_jar(HTTP::Cookies->new);
        main::log_debug("Cleared global cookies");
    }
}

sub is_logged_in {
    my ($self, $channel_id) = @_;
    my $cookies = $self->get_channel_cookie_jar($channel_id);

    #main::log_trace("Cookies:" . Dumper($cookies));

    # Check for SXMDATA cookie
    my $has_sxmdata = 0;
    my @cookie_names = ();
    
    $cookies->scan(sub {
        my ($version, $key, $val, $path, $domain, $port, $path_spec, $secure, $expires, $discard, $hash) = @_;
        push @cookie_names, $key;
        main::log_trace("Cookie found: $key = " . substr($val, 0, 50) . (length($val) > 50 ? "..." : ""));
        $has_sxmdata = 1 if $key eq 'SXMDATA';
    });
    
    my $context = $channel_id ? "channel $channel_id" : "global";
    main::log_trace("is_logged_in() check for $context - found cookies: " . join(", ", @cookie_names));
    main::log_trace("is_logged_in() result for $context: " . ($has_sxmdata ? "true" : "false"));
    
    return $has_sxmdata;
}

sub is_session_authenticated {
    my ($self, $channel_id) = @_;
    my $cookies = $self->get_channel_cookie_jar($channel_id);
    
    # Check for AWSALB and JSESSIONID cookies
    my ($has_awsalb, $has_jsessionid) = (0, 0);
    my @cookie_names = ();
    
    $cookies->scan(sub {
        my ($version, $key, $val, $path, $domain, $port, $path_spec, $secure, $expires, $discard, $hash) = @_;
        push @cookie_names, $key;
        $has_awsalb = 1 if $key eq 'AWSALB';
        $has_jsessionid = 1 if $key eq 'JSESSIONID';
    });
    
    my $context = $channel_id ? "channel $channel_id" : "global";
    main::log_trace("is_session_authenticated() check for $context - found cookies: " . join(", ", @cookie_names));
    main::log_trace("is_session_authenticated() result for $context: " . (($has_awsalb && $has_jsessionid) ? "true" : "false"));
    
    return $has_awsalb && $has_jsessionid;
}

sub get_request {
    my ($self, $method, $params, $authenticate, $channel_id) = @_;
    $authenticate //= 1;
    
    if ($authenticate) {
        # Set channel context for authentication
        $self->set_channel_context($channel_id);
        
        if (!$self->is_session_authenticated($channel_id) && !$self->authenticate($channel_id)) {
            main::log_error('Unable to authenticate');
            return undef;
        }
    }
    
    my $url = sprintf(REST_FORMAT, $method);
    my $uri = URI->new($url);
    $uri->query_form($params) if $params;
    
    main::log_trace("GET request to: $uri");
    
    my $response = $self->{ua}->get($uri);
    
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
        # Set channel context for authentication
        $self->set_channel_context($channel_id);
        
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
    
    my $response = $self->{ua}->request($request);
    
    # Log response details for trace level
    main::log_trace("Response status: " . $response->status_line);
    if ($response->header('Set-Cookie')) {
        main::log_trace("Response cookies: " . $response->header('Set-Cookie'));
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
    
    # Set channel context before login
    $self->set_channel_context($channel_id);
    
    my $context = $channel_id ? "channel $channel_id" : "global";
    main::log_debug("Attempting to login user: $self->{username} for $context");
    
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
    
    my $data = $self->post_request('modify/authentication', $postdata, 0, $channel_id);
    return 0 unless $data;
    
    main::log_trace("Login response received for $context, checking status");
    
    my $success = 0;
    eval {
        my $status = $data->{ModuleListResponse}->{status};
        main::log_trace("Login response status for $context: $status");
        
        if ($status == 1 && $self->is_logged_in($channel_id)) {
            main::log_info("Login successful for user: $self->{username} ($context)");
            main::log_trace("Session cookies after login for $context: " . ($self->{ua}->cookie_jar ? "present" : "none"));
            $success = 1;
        } else {
            main::log_trace("Login failed for $context - status: $status, is_logged_in: " . ($self->is_logged_in($channel_id) ? "true" : "false"));
        }
    };
    if ($@) {
        main::log_error("Error decoding JSON response for login ($context): $@");
    }
    
    if ($success) {
        return 1;
    }
    
    main::log_error("Login failed for user: $self->{username} ($context)");
    return 0;
}

sub authenticate {
    my ($self, $channel_id) = @_;
    
    if (!$self->is_logged_in($channel_id) && !$self->login($channel_id)) {
        main::log_error('Unable to authenticate because login failed');
        return 0;
    }
    
    # Set channel context for authentication
    $self->set_channel_context($channel_id);
    
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
    
    my $data = $self->post_request('resume?OAtrial=false', $postdata, 0, $channel_id);
    return 0 unless $data;
    
    main::log_trace("Authentication response received for $context, checking status");
    
    my $success = 0;
    eval {
        my $status = $data->{ModuleListResponse}->{status};
        main::log_trace("Authentication response status for $context: $status");
        
        if ($status == 1 && $self->is_session_authenticated($channel_id)) {
            main::log_info("Session authentication successful for $context");
            main::log_trace("Session authenticated for $context, cookies available");
            $success = 1;
        } else {
            main::log_trace("Authentication failed for $context - status: $status, is_session_authenticated: " . ($self->is_session_authenticated($channel_id) ? "true" : "false"));
        }
    };
    if ($@) {
        main::log_error("Error parsing JSON response for authentication ($context): $@");
    }
    
    if ($success) {
        return 1;
    }
    
    main::log_error("Session authentication failed for $context");
    return 0;
}

sub get_sxmak_token {
    my ($self, $channel_id) = @_;
    
    my $cookies = $self->get_channel_cookie_jar($channel_id);
    my $token;
    $cookies->scan(sub {
        my ($version, $key, $val, $path, $domain, $port, $path_spec, $secure, $expires, $discard, $hash) = @_;
        if ($key eq 'SXMAKTOKEN') {
            # Parse token value: token=value,other_data
            if ($val =~ /^([^=]+)=([^,]+)/) {
                $token = $2;
            }
        }
    });
    
    my $context = $channel_id ? "channel $channel_id" : "global";
    main::log_trace("SXMAK token for $context: " . ($token || 'not found'));
    return $token;
}

sub get_gup_id {
    my ($self, $channel_id) = @_;
    
    my $cookies = $self->get_channel_cookie_jar($channel_id);
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
                my $context = $channel_id ? "channel $channel_id" : "global";
                main::log_warn("Error parsing SXMDATA cookie for $context: $@");
                main::log_debug("Clearing corrupted cookies for $context to force fresh authentication");
                $self->clear_channel_cookies($channel_id);
            }
        }
    });
    
    my $context = $channel_id ? "channel $channel_id" : "global";
    main::log_trace("GUP ID for $context: " . ($gup_id || 'not found'));
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
   Playlist data format is
  {
    'size' => 'SMALL',
    'name' => 'primary',
    'url' => '%Live_Primary_HLS%/AAC_Data/9450/9450_variant_small_v3.m3u8'
  },
=end comment
=cut

    for my $playlist_info (@$playlists) {
        if ($playlist_info->{size} eq 'MEDIUM') {
            my $playlist_url = $playlist_info->{url};
            $playlist_url =~ s/%Live_Primary_HLS%/@{[LIVE_PRIMARY_HLS]}/g;
            
            my $variant_url = $self->get_playlist_variant_url($playlist_url, $channel_id);
            if ($variant_url) {
                $self->{playlists}->{$channel_id}->{'url'} = $variant_url;
                main::log_debug("Cached playlist URL for channel: $channel_id");
                return $variant_url;
            }
        }
    }
    
    main::log_error("No suitable playlist found for channel: $channel_id");
    return undef;
}

sub get_playlist_variant_url {
    my ($self, $url, $channel_id) = @_;
    
    # Set channel context for token retrieval
    $self->set_channel_context($channel_id);
    
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
    
    my $response = $self->{ua}->get($uri);
    
    if (!$response->is_success) {
        main::log_error("Received status code " . $response->code . " on playlist variant retrieval");
        return undef;
    }
    
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
    
    my $url = $self->get_playlist_url($guid, $channel_id, $use_cache);
    return undef unless $url;
    
    # Set channel context for token retrieval
    $self->set_channel_context($channel_id);
    
    my $token = $self->get_sxmak_token($channel_id);
    my $gup_id = $self->get_gup_id($channel_id);
    
    # If we can't get both token and gup_id, this might be due to corrupted cookies
    # Try to authenticate again if they're missing
    if (!$token || !$gup_id) {
        main::log_debug("Missing token or gup_id for channel $channel_id, attempting authentication");
        if ($self->authenticate($channel_id)) {
            # Try again after authentication
            $token = $self->get_sxmak_token($channel_id);
            $gup_id = $self->get_gup_id($channel_id);
        }
    }
    
    return undef unless $token && $gup_id;
    
    my $uri = URI->new($url);
    $uri->query_form(
        token    => $token,
        consumer => 'k2', 
        gupId    => $gup_id,
    );
    
    main::log_debug("Getting playlist for channel: $name");
    main::log_trace("Playlist URL: $uri");
    
    my $response = $self->{ua}->get($uri);
    
    if ($response->code == 403 || $response->code == 500) {
        main::log_warn("Received status code " . $response->code . " on playlist for channel: $channel_id, renewing session");
        
        # Try re-authentication first (without clearing cookies)
        if ($self->authenticate($channel_id)) {
            return $self->get_playlist($name, 0);
        } else {
            # If re-authentication failed, clear potentially corrupted cookies and try once more
            main::log_debug("Re-authentication failed, clearing cookies for channel $channel_id and retrying");
            $self->clear_channel_cookies($channel_id);
            if ($self->authenticate($channel_id)) {
                return $self->get_playlist($name, 0);
            } else {
                main::log_error("Failed to re-authenticate for channel: $channel_id after clearing cookies");
                return undef;
            }
        }
    }
    
    if (!$response->is_success) {
        main::log_error("Received status code " . $response->code . " on playlist variant");
        return undef;
    }
    
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
        main::log_debug("Caching disabled (segment_drop=0) for channel $channel_id");
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

    # Schedule next playlist update based on new segment count
    # Use the count saved BEFORE any caching started
    if ($new_segment_count > 0) {
        my $delay = $self->calculate_playlist_update_delay($content, $new_segment_count, $channel_id);
        my $next_update = time() + $delay;
        $self->{playlist_next_update}->{$channel_id} = $next_update;
        
        my $update_time = strftime('%Y-%m-%d %H:%M:%S', localtime($next_update));
        main::log_info(sprintf("Cached playlist for channel %s, next update scheduled in %.1f seconds at %s (%d new segments)", 
                              $channel_id, $delay, $update_time, $new_segment_count));
    } else {
        # No new segments, schedule a default update in 6 seconds
        my $delay = 6;
        my $next_update = time() + $delay;
        $self->{playlist_next_update}->{$channel_id} = $next_update;
        main::log_debug("$new_segment_count new segments in playlist for channel $channel_id, scheduling default update in $delay seconds");
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
    
    for my $line (@lines) {
        $line =~ s/^\s+|\s+$//g;
        next if $line eq '';
        
        if ($line =~ /^#EXTINF:/) {
            $expecting_uri = 1;
        } elsif ($expecting_uri && $line !~ /^#/ && $line =~ /\.aac/) {
            push @segments, $line;
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
    
    # Adaptive backoff strategy:
    # - Start with EXTINF duration as base
    # - If 1 new segment: backoff by 1.7x (to avoid constant refreshing)
    # - If >1 new segments: use EXTINF duration (more segments = faster refresh needed)
    my $delay;
    if ($new_segment_count == 1) {
        $delay = $extinf_duration - 1;
    } else {
        $delay = $extinf_duration * 1.6;
    }
    
    # Ensure delay is at least 5 seconds and at most 30 seconds
    $delay = 5 if $delay < 5;
    $delay = 30 if $delay > 30;
    
    main::log_debug(sprintf("Calculated playlist update delay: %.1f seconds (EXTINF: %.1f, new segments: %d, strategy: %s)", 
                           $delay, $extinf_duration, $new_segment_count, 
                           $new_segment_count == 1 ? "backoff 1.7x" : "EXTINF"));
    
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
            $cached_count++;
        } else {
            main::log_warn("Failed to cache segment: $segment_path for channel $channel_id");
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
    
    # Construct full segment URL with base path
    my $url = LIVE_PRIMARY_HLS . "/$base_path/$path";
    
    # Set channel context for token retrieval
    $self->set_channel_context($channel_id);
    
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
    main::log_trace("Channel ID: $channel_id, Base path: $base_path");
    
    my $response = $self->{ua}->get($uri);
    
    if ($response->code == 403 || $response->code == 500) {
        if ($max_attempts > 0) {
            main::log_warn("Received status code " . $response->code . " on segment for channel: $channel_id, renewing session");
            
            # Try re-authentication first (without clearing cookies)
            main::log_trace("Attempting to authenticate for channel: $channel_id to get new session tokens");
            if ($self->authenticate($channel_id)) {
                main::log_trace("Session renewed successfully for channel: $channel_id, retrying segment request");
                return $self->get_segment($path, $max_attempts - 1);
            } else {
                # If re-authentication failed, clear potentially corrupted cookies and try once more
                main::log_debug("Re-authentication failed, clearing cookies for channel $channel_id and retrying");
                $self->clear_channel_cookies($channel_id);
                main::log_trace("Attempting to authenticate for channel: $channel_id after clearing cookies");
                if ($self->authenticate($channel_id)) {
                    main::log_trace("Session renewed successfully for channel: $channel_id after clearing cookies, retrying segment request");
                    return $self->get_segment($path, $max_attempts - 1);
                } else {
                    main::log_error("Session renewal failed for channel: $channel_id after clearing cookies");
                    return undef;
                }
            }
        } else {
            main::log_error("Received status code " . $response->code . " on segment for channel: $channel_id, max attempts exceeded");
            return undef;
        }
    }
    
    if (!$response->is_success) {
        main::log_error("Received status code " . $response->code . " on segment");
        return undef;
    }
    
    return $response->content;
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
                    main::log_warn("Session expired (code: $message_code), re-authenticating for channel list");
                    $self->clear_channel_cookies(undef); # Clear global cookies
                    
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
        main::log_debug("Background refresh: Playlist expired for channel $channel_id, fetching new one");
        
        # Get the channel name from our cached mapping
        my $channel_name = $self->{playlist_channel_name}->{$channel_id};
        
        if ($channel_name) {
            # Manually clear the playlist cache to avoid expiring authentication
            delete $self->{playlist_cache}->{$channel_id};
            delete $self->{playlist_next_update}->{$channel_id};
            
            # Fetch new playlist (this will update the cache and schedule next update)
            eval {
                $self->get_playlist($channel_name, 1);  # Use cache for auth, but we cleared playlist cache above
            };
            if ($@) {
                main::log_warn("Error refreshing playlist for channel $channel_id: $@");
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
    delete $self->{last_segment}->{$channel_id};
    
    # Clear activity tracking
    delete $self->{channel_last_activity}->{$channel_id};
    delete $self->{channel_avg_duration}->{$channel_id};
    
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
        
        my $key = decode_base64('0Nsco7MAgxowGvkUT8aYag==');
        my $response = HTTP::Response->new(200);
        $response->content_type('text/plain');
        $response->header('Connection', 'close');
        $response->content($key);
        eval { $client->send_response($response); };
        if ($@) {
            main::log_warn("Error sending key response: $@");
        }
    }
    elsif ($path =~ /^\/channel\/(.+)$/) {
        # Handle channel info requests
        my $channel = $1;
        my $channel_info;
        
        main::log_debug("Channel info request for: $channel");
        
        if ( $channel eq 'all' ) {
            $channel_info = $sxm->refresh_channels();
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
            if ($value < 0 || $value > 30) {
                die "Invalid segment-drop value: $value. Must be between 0 and 30\n";
            }
            $CONFIG{segment_drop} = $value;
        },
        'logfile=s'     => \$CONFIG{logfile},
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
    
    # Create SiriusXM object
    my $region = $CONFIG{canada} ? 'CA' : 'US';
    $SIRIUS_XM = SiriusXM->new($CONFIG{username}, $CONFIG{password}, $region);
    
    if ($CONFIG{list}) {
        list_channels($SIRIUS_XM);
    } else {
        start_server($SIRIUS_XM);
    }
}

# Run main program
main() unless caller;

__END__
