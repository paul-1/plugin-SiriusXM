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
        
        # Test authentication if credentials are provided
        if ($params->{pref_username} && $params->{pref_password} && 
            $params->{pref_port} ) {
            
            # Temporarily set prefs for testing
            my $old_username = $prefs->get('username');
            my $old_password = $prefs->get('password');
            my $old_port = $prefs->get('port');
            
            $prefs->set('username', $params->{pref_username});
            $prefs->set('password', $params->{pref_password});
            $prefs->set('port', $params->{pref_port});
            
            # Test authentication
            Plugins::SiriusXM::API->authenticate(sub {
                my $success = shift;
                
                if ($success) {
                    $params->{info} = string('Authentication successful');
                    $log->info("Authentication test successful");
                } else {
                    $params->{warning} = string('PLUGIN_SIRIUSXM_ERROR_LOGIN_FAILED');
                    $log->warn("Authentication test failed");
                }
                
                # Continue with normal settings handling
                $class->SUPER::handler($client, $params, $callback, @args);
            });
            
            return;
        }
    }
    
    # Prepare template variables
    $params->{quality_options} = [
        { value => 'low',    text => string('PLUGIN_SIRIUSXM_QUALITY_LOW') },
        { value => 'medium', text => string('PLUGIN_SIRIUSXM_QUALITY_MEDIUM') },
        { value => 'high',   text => string('PLUGIN_SIRIUSXM_QUALITY_HIGH') },
    ];
    
    return $class->SUPER::handler($client, $params, $callback, @args);
}

sub beforeRender {
    my ($class, $params) = @_;
    
    # Add any additional template processing here
    $params->{plugin_version} = $Plugins::SiriusXM::Plugin::VERSION || '0.1.0';
    
    return $class->SUPER::beforeRender($params);
}

1;
