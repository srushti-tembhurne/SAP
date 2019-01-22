package ariba::rc::WebLogicAppInstance;

use strict;

use base qw(ariba::rc::AbstractAppInstance);

=pod

=head1 NAME

ariba::rc::WebLogicAppInstance

=head1 VERSION

$Id: //ariba/services/tools/lib/perl/ariba/rc/WebLogicAppInstance.pm#4 $

=head1 DESCRIPTION

A WebLogicAppInstance is a model of a WebLogic-based application instance.

=head1 PUBLIC INSTANCE METHODS

=over 8

=item * $self->logURL()

Return the URL where logviewer makes the keepRunning logs for this instance available.

=item * $self->monitorStatsURL()

Return the URL for the "monitorStats" direct action

=cut

sub monitorStatsURL {
	my $self = shift;

	my $appName = $self->appName();

	# AES AdminServer uses SNMP-based monitoring, not URL-based
	return undef if $appName =~ /admin/i;

	return sprintf("http://%s:%s/%s/status", $self->host(), $self->port(), $appName);
}

sub securePort {
	my $self = shift;

	my $port;

	if ($self->appName() =~ /admin/i) {
		$port = $self->SUPER::port();
	}

	return $port;
}

sub port {
	my $self = shift;

	my $port = $self->SUPER::port();

	if ($self->appName() =~ /admin/i) {
		$port++;
	}

	return $port;
}

=pod

=item * $self->killURL()

Return the URL for accessing kill functionality

=cut

sub killURL {
	my $self = shift;


	my $host      = $self->host();
	my $port      = $self->port();
	my $appName   = $self->appName();

	my $urlPrefix = "http://$host:$port/$appName";
	my $urlSuffix = "status?shutdown";


	return "$urlPrefix/$urlSuffix";
}


=pod

=item * $self->shutdownURL()

Return the URL for accessing shutdown functionality

=cut

sub shutdownURL {
	my $self = shift;

	return $self->killURL();
}

=pod

=back

=head1 SEE ALSO

ariba::rc::AbstractAppInstance, ariba::rc::AppInstanceManager, ariba::rc::Product

=cut

1;
