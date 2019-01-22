package ariba::rc::WOFAppInstance;

use strict;

use base qw(ariba::rc::AbstractAppInstance);

=pod

=head1 NAME

ariba::rc::WOFAppInstance

=head1 VERSION

$Id: //ariba/services/tools/lib/perl/ariba/rc/WOFAppInstance.pm#11 $

=head1 DESCRIPTION

A WOFAppInstance is a model of a Web Objects Framework application instance.

=head1 PUBLIC INSTANCE METHODS

=over 8

=item * $self->logURL()

Return the URL where logviewer makes the keepRunning logs for this instance available.

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

=pod

=item * $self->refuseNewSessionURL()

Return the URL for the "refuseNewSessions" direct action

=cut

sub refuseNewSessionURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("refuseNewSessions"));
}

=pod

=item * $self->refuseNewSessionsAndDieURL()

Return the URL for the "refuseNewSessionsAndDie" direct action

=cut

sub refuseNewSessionsAndDieURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("refuseNewSessionsAndDie"));
}

=pod

=item * $self->activeSessionCountURL()

Return the URL for the "activeSessionCount" direct action

=cut

sub activeSessionCountURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("activeSessionCount"));
}

=pod

=item * $self->monitorStatsURL()

Return the URL for the "monitorStats" direct action

=cut

sub monitorStatsURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("monitorStats"));
}

sub monitorBpmURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("monitorBpm"));
}

sub isDispatcher {
    my $self = shift;

    return($self->appType() =~ /dispatchers/io);
}

sub isUIApp {
    my $self = shift;

    return($self->appType() =~ /uiapps/io);
}

sub supportsRollingRestart {
    my $self = shift;

    return 1;
}

sub isUpResponseRegex {
    my $self = shift;

    return 'Catalog Load';
}

=pod

=back

=head1 PRIVATE INSTANCE METHODS

=over 8

=item * $self->_directActionURLForCommand($command)

=cut

sub _directActionURLForCommand
{
    my $self    = shift;
    my $command = shift;

    my $host      = $self->host();
    my $port      = $self->securePort();
	my $instance  = $self->instance();

    # This url will be used for all cases except when the product is mobile, when monitorStats is the command.
    my $urlPrefix = "http://$host:$port/$instance/ad";
    my $urlSuffix;

    if ($command eq "monitorStats")
    {
        if ($self->productName() eq 'mobile')
        {
            if ($instance =~ /^(Kafka|Notif|Oauth|Zoo)/)
            {
                $urlSuffix = 'jolokia/';
                $port = $self->jolokiaPort();
            }
            elsif ($instance =~ /^Nginx/)
            {
                $urlSuffix = 'nginx_status';
                # $port = $self->default ('nginx.mobile.port'); # I can't get this to work.  No error, but nothing is returned. ;<
                # So, get it directly.
                $port = $self->{'_info'}->{'manager'}->{'product'}->{'defaults'}->{'nginx.mobile.port'};
            }
            elsif ($instance =~ /^Redis/)
            {
                #$urlSuffix = '';
                #$port = $self->port();
                return undef;
            }
            # This completely resets the url prefix to what is needed for mobile, eliminating the "instance/ad" that's not needed.
            $urlPrefix = "http://$host:$port";
        }
        else
        {
            $urlSuffix = $command;
        }
    }
    else
    {
        $urlSuffix = "$command?awpwd=awpwd";
    }

    # Due to addition for mobile 2.0, it's possible for the url suffix to be empty, so must check it here.
    return $urlSuffix ? "$urlPrefix/$urlSuffix" : "$urlPrefix";
}

=back

=head1 SEE ALSO

ariba::rc::AbstractAppInstance, ariba::rc::AppInstanceManager, ariba::rc::Product

=cut

1;
