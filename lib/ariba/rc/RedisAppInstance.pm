package ariba::rc::RedisAppInstance;

use strict;

use base qw(ariba::rc::AbstractAppInstance);

=pod

=head1 NAME

ariba::rc::RedisAppInstance

=head1 VERSION

$Id: //ariba/services/tools/lib/perl/ariba/rc/RedisAppInstance.pm#2 $

=head1 DESCRIPTION

A RedisAppInstance is an app instance that consists of Redis.

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

    my $redisProgram = $self->manager()->product->installDir() . "/" . $self->manager()->product->default('Ops.Redis.CLIProgram');

    my $host = $self->host();
    my $port = $self->port();
    my $redisCommand = "$redisProgram -c -h $host -p $port PING";

    my @output;
    ariba::rc::Utils::executeLocalCommand($redisCommand, undef, \@output, undef, 1);

    # the valid ping response is 'PONG'
    my $ret = join("\n", @output);
    if ( $ret && $ret =~ /PONG/ ) {
        $self->setIsUp(1);
    }

    return ( $self->isUp(), @output );
}

1;
