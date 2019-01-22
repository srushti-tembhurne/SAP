package ariba::rc::PerlAppInstance;

use strict;

use base qw(ariba::rc::AbstractAppInstance);

=pod

=head1 NAME

ariba::rc::PHPInstance

=head1 VERSION

$Id: //ariba/services/tools/lib/perl/ariba/rc/PerlAppInstance.pm#3 $

=head1 DESCRIPTION

An Perl instance is a model of a Perl based app instance

=head1 SEE ALSO

ariba::rc::AbstractAppInstance, ariba::rc::AppInstanceManager, ariba::rc::Product

=cut

sub isDispatcher {
	return(0);
}

sub monitorStatsURL {
	my $self = shift;
	return($self->_directActionURLForCommand("monitorStats"));
}

sub _directActionURLForCommand {
	my $self    = shift;
	my $command = shift;

	my $host      = $self->host();
	my $port      = $self->port();

	my $urlPrefix = "http://$host:$port/";
	my $urlSuffix = $command;

	return "$urlPrefix/$urlSuffix";
}

sub supportsRollingRestart {
	my $self = shift;

	return 1;
}

#
1;
