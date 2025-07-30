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
    return ($prefs, qw(username password quality port));
}

sub handler {
    my ($class, $client, $params, $callback, @args) = @_;
    
    $log->debug("Handling settings request");
    
    # Handle form submission
    if ($params->{saveSettings}) {
        
        # Store old values to check if proxy restart is needed
        my $old_username = $prefs->get('username');
        my $old_password = $prefs->get('password');
        my $old_port = $prefs->get('port');
        
        # Save the settings first
        my $result = $class->SUPER::handler($client, $params, $callback, @args);
        
        # Check if proxy-related settings changed
        my $need_restart = (
            ($params->{pref_username} && $params->{pref_username} ne $old_username) ||
            ($params->{pref_password} && $params->{pref_password} ne $old_password) ||
            ($params->{pref_port} && $params->{pref_port} ne $old_port)
        );
        
        if ($need_restart) {
            $log->info("Settings changed, restarting proxy");
            
            # Restart proxy with new settings
            Plugins::SiriusXM::Plugin->stopProxy();
            
            # Give it a moment to shut down
            sleep(1);
            
            if (Plugins::SiriusXM::Plugin->startProxy()) {
                $params->{info} = string('PLUGIN_SIRIUSXM_PROXY_RESTARTED');
            } else {
                $params->{warning} = string('PLUGIN_SIRIUSXM_PROXY_RESTART_FAILED');
            }
            
            # Clear cached channels since proxy settings changed
            Plugins::SiriusXM::API->cleanup();
        }
        
        # Test authentication if credentials are provided
        if ($params->{pref_username} && $params->{pref_password} && 
            $params->{pref_port}) {
            
            # Test authentication
            Plugins::SiriusXM::API->authenticate(sub {
                my $success = shift;
                
                if ($success) {
                    $params->{info} = ($params->{info} || '') . ' ' . string('PLUGIN_SIRIUSXM_AUTH_SUCCESS');
                    $log->info("Authentication test successful");
                } else {
                    $params->{warning} = string('PLUGIN_SIRIUSXM_ERROR_LOGIN_FAILED');
                    $log->warn("Authentication test failed");
                }
                
                return $result;
            });
            
            return $result;
        }
        
        return $result;
    }
    
    return $class->SUPER::handler($client, $params, $callback, @args);
}

sub beforeRender {
    my ($class, $params) = @_;
    
    # Add proxy status information
    $params->{proxy_status} = Plugins::SiriusXM::Plugin->isProxyRunning() ? 
        string('PLUGIN_SIRIUSXM_PROXY_RUNNING') : 
        string('PLUGIN_SIRIUSXM_PROXY_STOPPED');
    
    # Prepare template variables
    $params->{quality_options} = [
        { value => 'low',    text => string('PLUGIN_SIRIUSXM_QUALITY_LOW') },
        { value => 'medium', text => string('PLUGIN_SIRIUSXM_QUALITY_MEDIUM') },
        { value => 'high',   text => string('PLUGIN_SIRIUSXM_QUALITY_HIGH') },
    ];
    
    # Add any additional template processing here
    $params->{plugin_version} = $Plugins::SiriusXM::Plugin::VERSION || '0.1.0';
    
    return $class->SUPER::beforeRender($params);
}

1;
