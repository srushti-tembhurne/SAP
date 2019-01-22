package ariba::rc::SpringbootAppInstance;

use strict;
use Data::Dumper;

use base qw(ariba::rc::AbstractAppInstance);

=pod

=head1 NAME

ariba::rc::PHPInstance

=head1 VERSION

$Id: //ariba/services/tools/lib/perl/ariba/rc/SpringbootAppInstance.pm#13 $

=head1 DESCRIPTION

A Springboot instance is a model of a Springboot based app instance

=head1 SEE ALSO

ariba::rc::AbstractAppInstance, ariba::rc::AppInstanceManager, ariba::rc::Product

=cut

sub isDispatcher {
	return(0);
}

# Both http-watcher and instance-heap-usage need to get URLs to get data for DMS, but the URL is different.
# The initial attempt to set this up simply modified the private method _directActionURLForCommand() to
# return the heap usage URL for all DMS products, but this broke http-watcher, which requires the 'jolokia'
# suffix, rather than 'metrics'.  The simplest way to deal with this is to create a new method for the
# instance-heap-usage, and have it call _directActionURLForCommand() with an arg to get the metrics,
# which should leave the http-watcher path intact.
sub metricsURL {
    my $self = shift;

    return($self->_directActionURLForCommand ('metrics'));
}

# return the URL used for monitoring to ping if the JVM is up
sub monitorStatsURL {
	my $self = shift;
	return($self->_directActionURLForCommand( 'monitorStats' ));
}

=item * $self->killURL()

Return the URL for the "kill" direct action

=cut

sub killURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("kill"));
}

=pod

=item * $self->shutdownURL()

Return the URL for the "shutdown" direct action

=cut

sub shutdownURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("shutdown"));
}


# Some springboot instances have inspector access (buyer), other do not (sellerdirect)
# Only return an inspector url if the product uses it.
sub inspectorURL {
    my $self = shift;

    my $hasInspector = $self->manager()->product()->default( 'System.Inspector.Enabled' ) || '';

    my $url = $self->_directActionURLForCommand( 'inspector' ) if $hasInspector;

    return ($url || '');
}

sub _directActionURLForCommand {
	my $self    = shift;
    my $command = shift;

	my $host = $self->host();
    my $context = $self->applicationContext();
    my $secureDirectAction = $self->manager()->product()->default( 'Ops.Monitoring.SecureDirectAction' );
    my $requireHttps = $self->manager()->product()->default('RequireHTTPS')||'';
    my $protocol = ($secureDirectAction || ($requireHttps =~ /YES/i) ) ? 'https' : 'http';
    my $port;

    my $urlSuffix;
    if ( $command eq 'inspector' || $command eq 'buyermobileapp/monitor/stats') {
        $urlSuffix = "$context/$command";
        $port = $self->httpPort();
    } elsif ($command eq 'metrics') {
       $urlSuffix = 'metrics/';
       $port = $self->jolokiaPort();
    } elsif ($command eq 'kill' || $command eq 'shutdown') {
       $urlSuffix = 'shutdown';
       $port = $self->jolokiaPort();
    } elsif ( $command eq 'dms/monitor/metrices/node' || $command eq 'dms/monitor/datasource' ) {
        $urlSuffix = $command;
        $port = $self->httpPort();
    } else { # monitorStats
        $urlSuffix = 'jolokia/';
        $port = $self->jolokiaPort();
    }
    my $urlPrefix = "$protocol://$host:$port";

	return "$urlPrefix/$urlSuffix";
}

sub supportsRollingRestart {
	my $self = shift;

	return 1;
}

sub isUpResponseRegex {
    my $self = shift;

    # The isup ping for monitoring hits jolokia.  jolokia returns a json structure.
    # For backwards compatibility we simply define the regex string to search for: '"status":200'

    return '"status":200';
}

sub mobileBackendMonitorURL {
    my $self = shift;
    my $url = $self->_directActionURLForCommand("buyermobileapp/monitor/stats");
    return $url;
 }

sub dmsNodeLevelMetricsURL {
    my $self = shift;
    my $url = $self->_directActionURLForCommand("dms/monitor/metrices/node");
    return $url;
}

sub dmsDatasourceMetricsURL {
    my $self = shift;
    my $url = $self->_directActionURLForCommand("dms/monitor/datasource");
    return $url;
}

1;

