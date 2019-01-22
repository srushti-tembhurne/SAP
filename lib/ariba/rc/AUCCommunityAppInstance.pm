package ariba::rc::AUCCommunityAppInstance;

use strict;

use base qw(ariba::rc::AbstractAppInstance);

use Net::Telnet;

=pod

=head1 NAME

ariba::rc::AUCCommunityAppInstance

=head1 VERSION

$Id: //ariba/services/tools/lib/perl/ariba/rc/AUCCommunityAppInstance.pm#2 $

=head1 DESCRIPTION

AUCCommunityApp instance is an instance communityapp and communityadminapp
for the AUC/Community Drupal product. Community app consists of Apache server
with php5_module enabled configured using default worker-based configuration.

=head1 CONFIGURATION NOTES



=head1 SEE ALSO

ariba::rc::AbstractAppInstance, ariba::rc::AppInstanceManager, ariba::rc::Product

=cut


=item * isUpResponseRegex() 

@Override

=cut

sub COMMUNITY_APP_NAME      { return 'community'; }
sub COMMUNITY_ADMIN_APP_NAME       { return 'communityadmin'; }

sub isUpResponseRegex {
    my $self = shift; 

    if ( $self->appName() == COMMUNITY_APP_NAME ||
	     $self->appName() == COMMUNITY_ADMIN_APP_NAME ) { 
        return '<!DOCTYPE html'; #phpinfo should return this as beginning of the response
    } 

    return '\w';
}

=pod

=item * canCheckIsUp() 

Returns true if the app can be checked for up / down.

=cut

sub canCheckIsUp {
    my $self = shift; 

    return 1;
}

=item * checkIsUp() 

@Override 

=cut 

sub checkIsUp {
    my $self = shift; 
    
    if ( $self->appName() == COMMUNITY_APP_NAME ||
	     $self->appName() == COMMUNITY_ADMIN_APP_NAME ) { 
        my $host = $self->host();
        my $output;
        my $port = $self->manager()->product->default('ApachePort');

        eval {
            my $telnet = Net::Telnet->new(Host => $host, Port => $port, Telnetmode => 1);
            $telnet->print("GET /internal/phpinfo.php");
            $output = $telnet->getline();
        };

        $self->setIsUpChecked(1);
        $self->setIsUp(0);

        my $isUpResponseRegex = $self->isUpResponseRegex();
        if ( $output && $output =~ /$isUpResponseRegex/ ) {
            $self->setIsUp(1);
        }

        return $self->isUp();
    } else { 
        return $self->SUPER::checkIsUp(); 
    }
}

sub supportsRollingRestart {
    my $self = shift;

    if ( $self->appName() == COMMUNITY_APP_NAME ||
	     $self->appName() == COMMUNITY_ADMIN_APP_NAME ) {
        return 1;
    } else {
        return 0;
    }
}

#
1;
