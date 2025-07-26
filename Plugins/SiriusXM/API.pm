package Plugins::SiriusXM::API;

use strict;
use warnings;

use JSON::XS;
use HTTP::Request;
use LWP::UserAgent;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Cache;

my $log = logger('plugin.siriusxm');
my $prefs = preferences('plugin.siriusxm');
my $cache = Slim::Utils::Cache->new();

# Cache timeout in seconds
use constant CACHE_TIMEOUT => 300; # 5 minutes

sub init {
    my $class = shift;
    $log->debug("Initializing SiriusXM API");
}

sub cleanup {
    my $class = shift;
    $log->debug("Cleaning up SiriusXM API");
    # Clear any cached data
    $cache->remove('siriusxm_channels');
    $cache->remove('siriusxm_auth_token');
}

sub getChannels {
    my ($class, $client, $cb) = @_;
    
    $log->debug("Getting SiriusXM channels");
    
    # Check cache first
    my $cached = $cache->get('siriusxm_channels');
    if ($cached) {
        $log->debug("Returning cached channels");
        $cb->($cached);
        return;
    }
    
    # Get channels from helper application
    my $helper_path = $prefs->get('helper_path');
    my $username = $prefs->get('username');
    my $password = $prefs->get('password');
    my $quality = $prefs->get('quality') || 'medium';
    
    unless (-x $helper_path) {
        $log->error("Helper application not found: $helper_path");
        $cb->([]);
        return;
    }
    
    # Build command to execute helper
    my @cmd = (
        $helper_path,
        '--username', $username,
        '--password', $password,
        '--quality', $quality,
        '--list-channels',
        '--format', 'json'
    );
    
    # Execute helper asynchronously
    Slim::Utils::Timers::setTimer(undef, time(), sub {
        my $output = eval {
            local $SIG{ALRM} = sub { die "timeout\n" };
            alarm 30; # 30 second timeout
            my $result = `@cmd 2>&1`;
            alarm 0;
            return $result;
        };
        
        if ($@) {
            $log->error("Helper execution failed: $@");
            $cb->([]);
            return;
        }
        
        my $channels = eval {
            my $data = decode_json($output);
            return $data->{channels} || [];
        };
        
        if ($@) {
            $log->error("Failed to parse channel data: $@");
            $log->debug("Raw output: $output");
            $cb->([]);
            return;
        }
        
        # Cache the results
        $cache->set('siriusxm_channels', $channels, CACHE_TIMEOUT);
        
        $log->info("Retrieved " . scalar(@$channels) . " channels");
        $cb->($channels);
    });
}

sub getStreamUrl {
    my ($class, $channel_id, $cb) = @_;
    
    $log->debug("Getting stream URL for channel: $channel_id");
    
    my $helper_path = $prefs->get('helper_path');
    my $username = $prefs->get('username');
    my $password = $prefs->get('password');
    my $quality = $prefs->get('quality') || 'medium';
    
    unless (-x $helper_path) {
        $log->error("Helper application not found: $helper_path");
        $cb->(undef);
        return;
    }
    
    # Build command to get stream URL
    my @cmd = (
        $helper_path,
        '--username', $username,
        '--password', $password,
        '--quality', $quality,
        '--channel', $channel_id,
        '--get-stream-url',
        '--format', 'json'
    );
    
    # Execute helper asynchronously
    Slim::Utils::Timers::setTimer(undef, time(), sub {
        my $output = eval {
            local $SIG{ALRM} = sub { die "timeout\n" };
            alarm 30; # 30 second timeout
            my $result = `@cmd 2>&1`;
            alarm 0;
            return $result;
        };
        
        if ($@) {
            $log->error("Helper execution failed: $@");
            $cb->(undef);
            return;
        }
        
        my $stream_data = eval {
            my $data = decode_json($output);
            return $data;
        };
        
        if ($@) {
            $log->error("Failed to parse stream data: $@");
            $log->debug("Raw output: $output");
            $cb->(undef);
            return;
        }
        
        my $stream_url = $stream_data->{stream_url};
        unless ($stream_url) {
            $log->error("No stream URL returned for channel: $channel_id");
            $cb->(undef);
            return;
        }
        
        $log->debug("Stream URL retrieved: $stream_url");
        $cb->($stream_url);
    });
}

sub authenticate {
    my ($class, $cb) = @_;
    
    $log->debug("Authenticating with SiriusXM");
    
    my $helper_path = $prefs->get('helper_path');
    my $username = $prefs->get('username');
    my $password = $prefs->get('password');
    
    unless (-x $helper_path) {
        $log->error("Helper application not found: $helper_path");
        $cb->(0);
        return;
    }
    
    # Build command to test authentication
    my @cmd = (
        $helper_path,
        '--username', $username,
        '--password', $password,
        '--test-auth',
        '--format', 'json'
    );
    
    # Execute helper asynchronously
    Slim::Utils::Timers::setTimer(undef, time(), sub {
        my $output = eval {
            local $SIG{ALRM} = sub { die "timeout\n" };
            alarm 15; # 15 second timeout for auth test
            my $result = `@cmd 2>&1`;
            alarm 0;
            return $result;
        };
        
        if ($@) {
            $log->error("Authentication test failed: $@");
            $cb->(0);
            return;
        }
        
        my $auth_result = eval {
            my $data = decode_json($output);
            return $data->{authenticated} || 0;
        };
        
        if ($@) {
            $log->error("Failed to parse authentication result: $@");
            $log->debug("Raw output: $output");
            $cb->(0);
            return;
        }
        
        $log->info("Authentication " . ($auth_result ? "successful" : "failed"));
        $cb->($auth_result);
    });
}

1;