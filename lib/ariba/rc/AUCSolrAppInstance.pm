package ariba::rc::AUCSolrAppInstance;

use strict;

use base qw(ariba::rc::AbstractAppInstance);

use Net::Telnet;

=pod

=head1 NAME

ariba::rc::AUCSolrAppInstance

=head1 VERSION

$Id: //ariba/services/tools/lib/perl/ariba/rc/AUCSolrAppInstance.pm#3 $

=head1 DESCRIPTION

An AUC Solr instance is a Solr instance for the AUC/Community Drupal product

=head1 SEE ALSO

ariba::rc::AbstractAppInstance, ariba::rc::AppInstanceManager, ariba::rc::Product

=cut


=item * isUpResponseRegex() 

@Override

=cut

sub AUCSOLRINDEXER_APP_NAME      { return 'AUCSolrIndexer'; }
sub AUCSOLRSEARCH_APP_NAME       { return 'AUCSolrSearch'; }

sub isUpResponseRegex {
    my $self = shift; 

    if ( $self->appName() == AUCSOLRINDEXER_APP_NAME ||
	     $self->appName() == AUCSOLRSEARCH_APP_NAME ) { 
        return '"status":0'; 
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
    
    if ( $self->appName() == AUCSOLRINDEXER_APP_NAME ||
	     $self->appName() == AUCSOLRSEARCH_APP_NAME ) { 
        my $host = $self->host();
        my $port = $self->port();
        my $output;

        eval {
            my $telnet = Net::Telnet->new(Host => $host, Port => $port, Telnetmode => 1);
            $telnet->print("GET /solr/admin/cores?wt=json");
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

    if ( $self->appName() == AUCSOLRINDEXER_APP_NAME ||
	     $self->appName() == AUCSOLRSEARCH_APP_NAME ) {
        return 1;
    } else {
        return 0;
    }
}

#
1;
