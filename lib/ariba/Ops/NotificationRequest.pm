package ariba::Ops::NotificationRequest;

#$Id: //ariba/services/tools/lib/perl/ariba/Ops/NotificationRequest.pm#18 $

use strict;
use vars qw(@ISA);

use ariba::Ops::PersistantObject;
use ariba::Ops::PageRequest;
use ariba::Ops::PageUtils;
use ariba::Ops::Constants;
use ariba::Ops::Utils;
use ariba::Ops::NetworkUtils;

@ISA = qw(ariba::Ops::PersistantObject);

my $unique = 0;

# class methods

sub newMessage {
    my $class = shift;
    my $severity = shift;
    my $sendingProgram = shift;
    my $product = shift;
    my $service = shift;
    my $customer = shift;
    my $cluster = shift;
    my $subject = shift;
    my $body = shift;
    my @requestedTo = @_;

    return $class->newMessageHashArgs(
        severity => $severity,
        sendingProgram => $sendingProgram,
        product => $product,
        service => $service,
        customer => $customer,
        cluster => $cluster,
        subject => $subject,
        body => $body,
        requestedTo => \@requestedTo,
    );
}
        
sub newMessageHashArgs {
    my $class = shift;
    my %args = (@_);

    my $severity = $args{ 'severity' };
    my $sendingProgram = $args{ 'sendingProgram' };
    my $product = $args{ 'product' };
    my $service = $args{ 'service' };
    my $customer = $args{ 'customer' };
    my $cluster = $args{ 'cluster' };
    my $subject = $args{ 'subject' };
    my $body = $args{ 'body' };
    my $queryObjectFile = $args{ 'queryObjectFile' };
    my @requestedTo = $args{ 'requestedTo' };

    my $time = time();
    my $pid = $$;
    my $host = ariba::Ops::NetworkUtils::hostname();

    my $instanceName = "notificationrequest-" . $unique++ . "-" . $host . "-" . $pid . "-" . $time;

    my $self = $class->SUPER::new($instanceName); 

    $self->setSeverity($severity);  

    $self->setSendingProgram($sendingProgram);
    $self->setProduct($product);
    $self->setService($service);
    $self->setCustomer($customer);
    $self->setCluster($cluster);
    $self->setQueryObjectFile($queryObjectFile);

    $self->setRequestedTo(@requestedTo);
    $self->setSubject($subject);
    $self->setBody($body);
        
    $self->setSendingHost($host);
    $self->setCreationTime($time);

    return $self;
}

sub newCrit {
    my $class = shift;
    $class->newMessage("crit", @_);
}

sub newWarn {
    my $class = shift;
    $class->newMessage("warn", @_);
}

sub newInfo {
    my $class = shift;
    $class->newMessage("info", @_);
}

sub dir {
    my $class = shift;

    return undef;
}

sub setDebug {
    my $self = shift;
    my $debug = shift;

    $self->setAttribute('debug', $debug);
}

sub send {
    my $self = shift;
    my $pageServerHost = shift || ariba::Ops::PageUtils::pageServer();

    my $return;

    my $severity = $self->severity();
    my $service = $self->service();

    my $debug = $self->debug();

    print "ariba::Ops::NotificationRequest->send(): severity = $severity, service = $service\n" if $debug;

    #XXX temp: allow QA service to use paged
    if ( $severity eq "crit" && ariba::Ops::PageUtils::usePagedForService($service) && !$self->treatCritAsWarn() ) {

        print "ariba::Ops::NotificationRequest->send(): will page\n" if $debug;

        # turn this into a pageRequest
        my $pageRequest = ariba::Ops::PageRequest->newWithErrorHashArgs(
            sendingProgram => $self->sendingProgram(),
            product => $self->product(),
            service => $self->service(),
            subject => $self->subject(),
            customer => $self->customer(),
            cluster => $self->cluster(),
            body => $self->body(),
            queryObjectFile => $self->queryObjectFile(),
            requestedTo => $self->requestedTo(),
        );

        # send the pageRequest to server
        # if that fails, email it it directly, overriding the requestedTo() 
        # to be the ops pager email address

        unless ( $return = $pageRequest->sendToServer($pageServerHost, $debug) ) {
            print "ariba::Ops::NotificationRequest->send() failed to send a pageRequest to $pageServerHost defaulting to direct email.\n";

            my $to = ariba::Ops::Constants::failsafePagerAddressForService($service);

            #
            # Add text to the page body to indicate problems with
            # paged
            #
            my $body = $self->body() . "\n" .
                        "paged [$pageServerHost] down?";

            $self->setBody($body);

            $self->setCc($self->requestedTo());

            $self->setRequestedTo($to);
            $return = $self->sendAsEmail();
        } else {
            print "ariba::Ops::NotificationRequest->send()  was able to send pageRequest to $pageServerHost, return = $return\n" if $debug;
        }


    } else {
         # email this to someone
         #$return = $self->sendAsEmail();
    }
    
    return  $return;
}

sub sendAsEmail {
    my $self = shift;

    print "ariba::Ops::NotificationRequest->sendAsEmail()\n" if $self->debug();

    my $to      = join(", ", $self->requestedTo());
    my $subject = ariba::Ops::PageUtils::emailSubjectForSubject($self->subject(), $self->product(), $self->service(), $self->customer(), $self->cluster());
    my $body    = $self->body();
    my $cc      = $self->cc();

    #
    #XXX  need to allow ariba::Ops::Utils::email() to set the From:?
    #
    return ariba::Ops::Utils::email($to, $subject, $body, $cc);
}

1;

