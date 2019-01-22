package ariba::rc::OpenOfficeAppInstance;

use strict;

use base qw(ariba::rc::AbstractAppInstance);

=pod

=head1 NAME

ariba::rc::OpenOfficeAppInstance

=head1 VERSION

$Id: //ariba/services/tools/lib/perl/ariba/rc/OpenOfficeAppInstance.pm#2 $

=head1 DESCRIPTION

An OpenOfficeAppInstance is a model of an instance of OpenOffice.

=head1 SEE ALSO

ariba::rc::AbstractAppInstance, ariba::rc::AppInstanceManager, ariba::rc::Product

=cut

sub isDispatcher {
	return 0;
}

1;
