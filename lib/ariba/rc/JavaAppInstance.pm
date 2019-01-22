package ariba::rc::JavaAppInstance;

use strict;

use base qw(ariba::rc::WOFAppInstance);

=pod

=head1 NAME

ariba::rc::JavaAppInstance

=head1 VERSION

$Id: //ariba/services/tools/lib/perl/ariba/rc/JavaAppInstance.pm#3 $

=head1 DESCRIPTION

A JavaAppInstance is a model of a Java-based application instance.

=head1 SEE ALSO

ariba::rc::AbstractAppInstance, ariba::rc::AppInstanceManager, ariba::rc::Product

=over 8

=item * $self->logURL()

Return the URL where logviewer makes the keepRunning logs for this instance available.

=cut

1;
