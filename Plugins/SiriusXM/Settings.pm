package Plugins::SiriusXM::Settings;

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Plugins::SiriusXM::API;

my $log = logger('plugin.siriusxm');
my $prefs = preferences('plugin.siriusxm');

sub name {
    return Slim::Web::HTTP::CSRF->protectName('PLUGIN_SIRIUSXM_SETTINGS');
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI('plugins/SiriusXM/settings/basic.html');
}

sub prefs {
    return ($prefs, qw(username password quality port region enable_metadata proxy_log_level));
}

sub handler {
    my ($class, $client, $params, $callback, @args) = @_;
    
    $log->debug("Handling settings request");
    
    # Handle Check Status button
    if ($params->{checkStatus}) {
        $log->info("Check Status button pressed");
        
        if (Plugins::SiriusXM::Plugin->isProxyRunning()) {
            my $pid = Plugins::SiriusXM::Plugin->getProxyPid();
            if ($pid) {
                $params->{info} = string('PLUGIN_SIRIUSXM_PROXY_STATUS_CHECKED') . " (PID: $pid)";
            } else {
                $params->{info} = string('PLUGIN_SIRIUSXM_PROXY_STATUS_CHECKED');
            }
        } else {
            $params->{warning} = string('PLUGIN_SIRIUSXM_PROXY_NOT_RUNNING');
        }
        
        return $class->SUPER::handler($client, $params, $callback, @args);
    }
    
    # Handle Restart Proxy button
    if ($params->{restartProxy}) {
        $log->info("Restart Proxy button pressed");
        
        # Stop current proxy if running
        Plugins::SiriusXM::Plugin->stopProxy();
        
        # Give it a moment to shut down
        sleep(2);
        
        # Start proxy if credentials are available
        if ($prefs->get('username') && $prefs->get('password')) {
            if (Plugins::SiriusXM::Plugin->startProxy()) {
                my $pid = Plugins::SiriusXM::Plugin->getProxyPid();
                if ($pid) {
                    $params->{info} = string('PLUGIN_SIRIUSXM_PROXY_RESTART_SUCCESS') . " (PID: $pid)";
                } else {
                    $params->{info} = string('PLUGIN_SIRIUSXM_PROXY_RESTART_SUCCESS');
                }
            } else {
                $params->{warning} = string('PLUGIN_SIRIUSXM_PROXY_RESTART_FAILED');
            }
        } else {
            $params->{warning} = string('PLUGIN_SIRIUSXM_ERROR_NO_CREDENTIALS');
        }
        
        return $class->SUPER::handler($client, $params, $callback, @args);
    }
    
    # Handle form submission
    if ($params->{saveSettings}) {
        
        # Store old values to check if proxy restart is needed
        my $old_username = $prefs->get('username');
        my $old_password = $prefs->get('password');
        my $old_port = $prefs->get('port');
        my $old_region = $prefs->get('region');
        my $old_quality = $prefs->get('quality');
        my $old_proxy_log_level = $prefs->get('proxy_log_level');
        
        # Save the settings first
        my $result = $class->SUPER::handler($client, $params, $callback, @args);
        
        # Check if proxy-related settings changed
        my $need_restart = (
            ($params->{pref_username} && $params->{pref_username} ne $old_username) ||
            ($params->{pref_password} && $params->{pref_password} ne $old_password) ||
            ($params->{pref_port} && $params->{pref_port} ne $old_port) ||
            ($params->{pref_region} && $params->{pref_region} ne $old_region) ||
            ($params->{pref_quality} && $params->{pref_quality} ne $old_quality) ||
            ($params->{pref_proxy_log_level} && $params->{pref_proxy_log_level} ne $old_proxy_log_level)
        );
        
        if ($need_restart) {
            $log->info("Settings changed, restarting proxy");
            
            # Restart proxy with new settings
            Plugins::SiriusXM::Plugin->stopProxy();
            
            # Give it a moment to shut down
            sleep(2);
            
            if (Plugins::SiriusXM::Plugin->startProxy()) {
                $params->{info} = string('PLUGIN_SIRIUSXM_PROXY_RESTARTED');
                
                # Test authentication right after starting proxy if credentials are provided
                if ($params->{pref_username} && $params->{pref_password}) {
                    Plugins::SiriusXM::API->authenticate(sub {
                        my $success = shift;
                        
                        if ($success) {
                            $params->{info} = ($params->{info} || '') . ' ' . string('PLUGIN_SIRIUSXM_AUTH_SUCCESS');
                            $log->info("Authentication test successful");
                        } else {
                            $params->{warning} = string('PLUGIN_SIRIUSXM_ERROR_LOGIN_FAILED');
                            $log->warn("Authentication test failed");
                        }
                    });
                }
            } else {
                $params->{warning} = string('PLUGIN_SIRIUSXM_PROXY_RESTART_FAILED');
            }
            
            # Clear cached channels since proxy settings changed
            Plugins::SiriusXM::API->cleanup();
        }
        
        return $result;
    }
    
    return $class->SUPER::handler($client, $params, $callback, @args);
}

sub beforeRender {
    my ($class, $params) = @_;
    
    # Add proxy status information
    my $is_running = Plugins::SiriusXM::Plugin->isProxyRunning();
    $params->{proxy_status} = $is_running ? 
        string('PLUGIN_SIRIUSXM_PROXY_RUNNING') : 
        string('PLUGIN_SIRIUSXM_PROXY_STOPPED');
    
    # Add process ID if proxy is running
    if ($is_running) {
        my $pid = Plugins::SiriusXM::Plugin->getProxyPid();
        $params->{proxy_pid} = $pid if $pid;
    }
    
    # Prepare template variables
    $params->{quality_options} = [
        { value => 'high',   text => string('PLUGIN_SIRIUSXM_QUALITY_HIGH') },
        { value => 'medium', text => string('PLUGIN_SIRIUSXM_QUALITY_MEDIUM') },
        { value => 'low',    text => string('PLUGIN_SIRIUSXM_QUALITY_LOW') },
    ];
    
    $params->{region_options} = [
        { value => 'US',     text => string('PLUGIN_SIRIUSXM_REGION_US') },
        { value => 'Canada', text => string('PLUGIN_SIRIUSXM_REGION_CANADA') },
    ];
    
    $params->{proxy_log_level_options} = [
        { value => 'OFF',   text => string('PLUGIN_SIRIUSXM_PROXY_LOG_OFF') },
        { value => 'ERROR', text => string('PLUGIN_SIRIUSXM_PROXY_LOG_ERROR') },
        { value => 'WARN',  text => string('PLUGIN_SIRIUSXM_PROXY_LOG_WARN') },
        { value => 'INFO',  text => string('PLUGIN_SIRIUSXM_PROXY_LOG_INFO') },
        { value => 'DEBUG', text => string('PLUGIN_SIRIUSXM_PROXY_LOG_DEBUG') },
        { value => 'TRACE', text => string('PLUGIN_SIRIUSXM_PROXY_LOG_TRACE') },
    ];

    # Add any additional template processing here
    $params->{plugin_version} = $Plugins::SiriusXM::Plugin::VERSION || '0.1.0';
    
    return $class->SUPER::beforeRender($params);
}

1;
