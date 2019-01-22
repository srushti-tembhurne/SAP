package ariba::rc::SeleniumAppInstance;

use strict;

use base qw(ariba::rc::AbstractAppInstance);

=pod

=head1 NAME

ariba::rc::SeleniumInstance

=head1 VERSION

$Id: //ariba/services/tools/lib/perl/ariba/rc/SeleniumAppInstance.pm#2 $

=head1 DESCRIPTION

An Selenium instance is a model of a SeleniumRC instance along with it's Xvfb process

=head1 SEE ALSO

ariba::rc::AbstractAppInstance, ariba::rc::AppInstanceManager, ariba::rc::Product

=cut

sub xvfbInstance {
	my $self = shift;

	my $instance = $self->instance();
	$instance =~ s/SeleniumRC/Xvfb/;

	return $instance;
}

sub isDispatcher {
	return 0;
}

sub xvfbDisplay {
	my $self = shift;

	return ":" . $self->xvfbPort() . ".0";
}

1;
