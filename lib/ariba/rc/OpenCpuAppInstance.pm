package ariba::rc::OpenCpuAppInstance;

use strict;

use base qw(ariba::rc::AbstractAppInstance);

=pod

=head1 NAME

ariba::rc::OpenCpuAppInstance

=head1 VERSION

$Id: //ariba/services/tools/lib/perl/ariba/rc/OpenCpuAppInstance.pm#1 $

=head1 DESCRIPTION

An OpenCpuAppInstance is an app instance that consists of OpenCpu.

=head1 SEE ALSO

ariba::rc::AbstractAppInstance, ariba::rc::AppInstanceManager, ariba::rc::Product

=cut

sub isDispatcher {
    return(0);
}

sub canCheckIsUp {
    my $self = shift;

    return 1;
}

sub checkIsUp {
    my $self = shift; 
    
    $self->setIsUpChecked(1);
    $self->setIsUp(0);

    my $host = $self->host();
    my $port = $self->manager()->product()->default('WebserverHTTPPort');
    my $command = "curl -L http://$host:$port//ocpu/library/sri/R/getPulse/json -d \"\"";

    my @output;
    ariba::rc::Utils::executeLocalCommand($command, undef, \@output, undef, 1);

    # successful output looks like this:
    # {
    #   "status": [true],
    #   "message": ["OK"]
    # }
    my $ret = join("\n", @output);
    if ( $ret && $ret =~ /status.+true.+message.+OK/s ) {
        $self->setIsUp(1);
    }

    return ( $self->isUp(), @output );
}

1;
