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
        -h, --help              Show this help message

=head1 DESCRIPTION

This script creates a server that serves HLS streams for SiriusXM channels.
It provides the same functionality as the Python sxm.py script with enhanced
logging and error handling.

Usage examples:
    perl sxm.pl myuser mypass -p 8888
    perl sxm.pl myuser mypass -l
    perl sxm.pl user pass -e -p 8888 --verbose DEBUG

In a player that supports HLS (QuickTime, VLC, ffmpeg, etc) you can access
a channel at http://127.0.0.1:8888/channel.m3u8 where "channel" is the
channel name, ID, or Sirius channel number.

=cut

use strict;
use warnings;
use v5.14;

# Core modules
use Getopt::Long qw(:config bundling);
use Pod::Usage;
use POSIX qw(strftime);
use Time::HiRes qw(time);
use File::Basename;
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

# Data handling modules
use JSON::XS;
use MIME::Base64;

# Signal handling
use sigtrap 'handler' => \&signal_handler, qw(INT QUIT TERM);

#=============================================================================
# Global variables and constants
#=============================================================================

our $VERSION = '1.0.0';

# Logging levels
use constant {
    LOG_ERROR => 0,
    LOG_WARN  => 1, 
    LOG_INFO  => 2,
    LOG_DEBUG => 3,
    LOG_TRACE => 4,
};

# Global configuration
my %CONFIG = (
    username     => '',
    password     => '',
    port         => 9999,
    list         => 0,
    canada       => 0,
    env          => 0,
    verbose      => LOG_INFO,
    help         => 0,
);

# Global state
my $HTTP_DAEMON;
my $SIRIUS_XM;
our $RUNNING = 1;

#=============================================================================
# Logging functions
#=============================================================================

sub log_message {
    my ($level, $message) = @_;
    return if $level > $CONFIG{verbose};
    
    my $timestamp = strftime('%d.%b %Y %H:%M:%S', gmtime);
    my $level_name = qw(ERROR WARN INFO DEBUG TRACE)[$level];
    
    printf "%s <%s>: %s\n", $timestamp, $level_name, $message;
}

sub log_error { log_message(LOG_ERROR, shift) }
sub log_warn  { log_message(LOG_WARN,  shift) }
sub log_info  { log_message(LOG_INFO,  shift) }
sub log_debug { log_message(LOG_DEBUG, shift) }
sub log_trace { log_message(LOG_TRACE, shift) }

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

# Constants
use constant {
    USER_AGENT       => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_12_6) AppleWebKit/604.5.6 (KHTML, like Gecko) Version/11.0.3 Safari/604.5.6',
    REST_FORMAT      => 'https://player.siriusxm.com/rest/v2/experience/modules/%s',
    LIVE_PRIMARY_HLS => 'https://siriusxm-priprodlive.akamaized.net',
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

sub is_logged_in {
    my $self = shift;
    my $cookies = $self->{ua}->cookie_jar;
    
    # Check for SXMDATA cookie
    my $has_sxmdata = 0;
    my @cookie_names = ();
    
    $cookies->scan(sub {
        my ($version, $key, $val, $path, $domain, $port, $path_spec, $secure, $expires, $discard, $hash) = @_;
        push @cookie_names, $key;
        main::log_trace("Cookie found: $key = " . substr($val, 0, 50) . (length($val) > 50 ? "..." : ""));
        $has_sxmdata = 1 if $key eq 'SXMDATA';
    });
    
    main::log_trace("is_logged_in() check - found cookies: " . join(", ", @cookie_names));
    main::log_trace("is_logged_in() result: " . ($has_sxmdata ? "true" : "false"));
    
    return $has_sxmdata;
}

sub is_session_authenticated {
    my $self = shift;
    my $cookies = $self->{ua}->cookie_jar;
    
    # Check for AWSALB and JSESSIONID cookies
    my ($has_awsalb, $has_jsessionid) = (0, 0);
    my @cookie_names = ();
    
    $cookies->scan(sub {
        my ($version, $key, $val, $path, $domain, $port, $path_spec, $secure, $expires, $discard, $hash) = @_;
        push @cookie_names, $key;
        $has_awsalb = 1 if $key eq 'AWSALB';
        $has_jsessionid = 1 if $key eq 'JSESSIONID';
    });
    
    main::log_trace("is_session_authenticated() check - found cookies: " . join(", ", @cookie_names));
    main::log_trace("is_session_authenticated() result: " . (($has_awsalb && $has_jsessionid) ? "true" : "false"));
    
    return $has_awsalb && $has_jsessionid;
}

sub get_request {
    my ($self, $method, $params, $authenticate) = @_;
    $authenticate //= 1;
    
    if ($authenticate && !$self->is_session_authenticated() && !$self->authenticate()) {
        main::log_error('Unable to authenticate');
        return undef;
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
    my ($self, $method, $postdata, $authenticate) = @_;
    $authenticate //= 1;
    
    if ($authenticate && !$self->is_session_authenticated() && !$self->authenticate()) {
        main::log_error('Unable to authenticate');
        return undef;
    }
    
    my $url = sprintf(REST_FORMAT, $method);
    my $json_data = $self->{json}->encode($postdata);
    
    main::log_trace("POST request to: $url");
    main::log_trace("POST data: $json_data");
    
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
    my $self = shift;
    
    main::log_debug("Attempting to login user: $self->{username}");
    
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
    
    my $data = $self->post_request('modify/authentication', $postdata, 0);
    return 0 unless $data;
    
    main::log_trace("Login response received, checking status");
    
    my $success = 0;
    eval {
        my $status = $data->{ModuleListResponse}->{status};
        main::log_trace("Login response status: $status");
        
        if ($status == 1 && $self->is_logged_in()) {
            main::log_info("Login successful for user: $self->{username}");
            main::log_trace("Session cookies after login: " . ($self->{ua}->cookie_jar ? "present" : "none"));
            $success = 1;
        } else {
            main::log_trace("Login failed - status: $status, is_logged_in: " . ($self->is_logged_in() ? "true" : "false"));
        }
    };
    if ($@) {
        main::log_error("Error decoding JSON response for login: $@");
    }
    
    if ($success) {
        return 1;
    }
    
    main::log_error("Login failed for user: $self->{username}");
    return 0;
}

sub authenticate {
    my $self = shift;
    
    if (!$self->is_logged_in() && !$self->login()) {
        main::log_error('Unable to authenticate because login failed');
        return 0;
    }
    
    main::log_debug("Attempting to authenticate session");
    
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
    
    my $data = $self->post_request('resume?OAtrial=false', $postdata, 0);
    return 0 unless $data;
    
    main::log_trace("Authentication response received, checking status");
    
    my $success = 0;
    eval {
        my $status = $data->{ModuleListResponse}->{status};
        main::log_trace("Authentication response status: $status");
        
        if ($status == 1 && $self->is_session_authenticated()) {
            main::log_info("Session authentication successful");
            main::log_trace("Session authenticated, cookies available");
            $success = 1;
        } else {
            main::log_trace("Authentication failed - status: $status, is_session_authenticated: " . ($self->is_session_authenticated() ? "true" : "false"));
        }
    };
    if ($@) {
        main::log_error("Error parsing JSON response for authentication: $@");
    }
    
    if ($success) {
        return 1;
    }
    
    main::log_error("Session authentication failed");
    return 0;
}

sub get_sxmak_token {
    my $self = shift;
    
    my $token;
    $self->{ua}->cookie_jar->scan(sub {
        my ($version, $key, $val, $path, $domain, $port, $path_spec, $secure, $expires, $discard, $hash) = @_;
        if ($key eq 'SXMAKTOKEN') {
            # Parse token value: token=value,other_data
            if ($val =~ /^([^=]+)=([^,]+)/) {
                $token = $2;
            }
        }
    });
    
    main::log_trace("SXMAK token: " . ($token || 'not found'));
    return $token;
}

sub get_gup_id {
    my $self = shift;
    
    my $gup_id;
    $self->{ua}->cookie_jar->scan(sub {
        my ($version, $key, $val, $path, $domain, $port, $path_spec, $secure, $expires, $discard, $hash) = @_;
        if ($key eq 'SXMDATA') {
            eval {
                my $decoded = uri_unescape($val);
                my $data = $self->{json}->decode($decoded);
                $gup_id = $data->{gupId};
            };
            if ($@) {
                main::log_warn("Error parsing SXMDATA cookie: $@");
            }
        }
    });
    
    main::log_trace("GUP ID: " . ($gup_id || 'not found'));
    return $gup_id;
}

sub get_playlist_url {
    my ($self, $guid, $channel_id, $use_cache, $max_attempts) = @_;
    $use_cache //= 1;
    $max_attempts //= 5;
    
    if ($use_cache && exists $self->{playlists}->{$channel_id}) {
        main::log_trace("Using cached playlist for channel: $channel_id");
        return $self->{playlists}->{$channel_id};
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
    
    my $data = $self->get_request('tune/now-playing-live', $params);
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
            main::log_warn("Session expired (code: $message_code), re-authenticating");
            if ($self->authenticate()) {
                main::log_info("Successfully re-authenticated");
                return $self->get_playlist_url($guid, $channel_id, $use_cache, $max_attempts - 1);
            } else {
                main::log_error("Failed to re-authenticate");
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
    
    for my $playlist_info (@$playlists) {
        if ($playlist_info->{size} eq 'LARGE') {
            my $playlist_url = $playlist_info->{url};
            $playlist_url =~ s/%Live_Primary_HLS%/@{[LIVE_PRIMARY_HLS]}/g;
            
            my $variant_url = $self->get_playlist_variant_url($playlist_url);
            if ($variant_url) {
                $self->{playlists}->{$channel_id} = $variant_url;
                main::log_debug("Cached playlist URL for channel: $channel_id");
                return $variant_url;
            }
        }
    }
    
    main::log_error("No suitable playlist found for channel: $channel_id");
    return undef;
}

sub get_playlist_variant_url {
    my ($self, $url) = @_;
    
    my $token = $self->get_sxmak_token();
    my $gup_id = $self->get_gup_id();
    
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
    
    # Try to clean up any potential character encoding issues
    $content =~ s/\r//g;  # Remove carriage returns
    
    my $found_lines = 0;
    for my $line (split /\n/, $content) {
        chomp($line);  # Remove any trailing newlines
        $line =~ s/^\s+|\s+$//g;  # Trim whitespace
        next if $line eq '';  # Skip empty lines
        
        $found_lines++;
        main::log_trace("Processing line $found_lines: '$line'");
        if ($line =~ /\.m3u8$/) {
            # First variant should be 256k one
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

sub get_playlist {
    my ($self, $name, $use_cache) = @_;
    $use_cache //= 1;
    
    my ($guid, $channel_id) = $self->get_channel($name);
    if (!$guid || !$channel_id) {
        main::log_error("No channel found for: $name");
        return undef;
    }
    
    my $url = $self->get_playlist_url($guid, $channel_id, $use_cache);
    return undef unless $url;
    
    my $token = $self->get_sxmak_token();
    my $gup_id = $self->get_gup_id();
    
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
    
    if ($response->code == 403) {
        main::log_warn("Received status code 403 on playlist, renewing session");
        return $self->get_playlist($name, 0);
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
    
    my @lines = split /\n/, $content;
    my $modified_segments = 0;
    for my $i (0..$#lines) {
        $lines[$i] =~ s/\r?\n$//;
        if ($lines[$i] =~ /\.aac$/) {
            my $original = $lines[$i];
            $lines[$i] = "$base_path/$lines[$i]";
            $modified_segments++;
            main::log_trace("Modified segment: '$original' -> '$lines[$i]'");
        }
    }
    
    main::log_trace("Modified $modified_segments segments with base path");
    return join("\n", @lines);
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
    my $token = $self->get_sxmak_token();
    my $gup_id = $self->get_gup_id();
    
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
    
    if ($response->code == 403) {
        if ($max_attempts > 0) {
            main::log_warn("Received status code 403 on segment, renewing session");
            main::log_trace("Attempting to authenticate to get new session tokens");
            if ($self->authenticate()) {
                main::log_trace("Session renewed successfully, retrying segment request");
                return $self->get_segment($path, $max_attempts - 1);
            } else {
                main::log_error("Session renewal failed");
                return undef;
            }
        } else {
            main::log_error("Received status code 403 on segment, max attempts exceeded");
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
    
    # Download channel list if necessary
    if (!defined $self->{channels}) {
        main::log_debug("Fetching channel list");
        
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
        
        my $data = $self->post_request('get', $postdata);
        if (!$data) {
            main::log_error('Unable to get channel list');
            return [];
        }
        
        eval {
            $self->{channels} = $data->{ModuleListResponse}->{moduleList}->{modules}->[0]->{moduleResponse}->{contentData}->{channelListing}->{channels};
        };
        if ($@) {
            main::log_error("Error parsing JSON response for channels: $@");
            return [];
        }
        
        main::log_info("Loaded " . @{$self->{channels}} . " channels");
    }
    
    return $self->{channels};
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
    
    my $daemon = HTTP::Daemon->new(
        LocalPort => $port,
        LocalAddr => '0.0.0.0',
        ReuseAddr => 1,
    );
    
    if (!$daemon) {
        main::log_error("Could not create HTTP server on port $port: $!");
        return undef;
    }
    
    main::log_info("HTTP server started on port $port");
    main::log_info("Access channels at: http://127.0.0.1:$port/channel.m3u8");
    
    while ($main::RUNNING) {
        main::log_trace("Server loop iteration, waiting for client connection");
        my $client = $daemon->accept();
        if (!$client) {
            main::log_trace("No client connection, continuing loop");
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
        
        my $data = $sxm->get_segment($segment_path);
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
    
    # Ensure we're authenticated first
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
    
    # Test authentication before starting server
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
