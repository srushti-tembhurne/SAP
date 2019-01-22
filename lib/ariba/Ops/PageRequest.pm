package ariba::Ops::PageRequest;

#$Id: //ariba/services/tools/lib/perl/ariba/Ops/PageRequest.pm#20 $

use strict;
use vars qw(@ISA);

use ariba::Ops::PersistantObject;
use ariba::Ops::UDPTransport;
use ariba::Ops::PageAck;
use ariba::Ops::PageUtils;
use ariba::Ops::Utils;
use ariba::Ops::Constants;
use ariba::Ops::NetworkUtils;
use ariba::Ops::DateTime;

@ISA = qw(ariba::Ops::PersistantObject);

my $rootDir = ariba::Ops::Constants->pagedir() . "/pagerequest-storage";
my $unique = 0;

# class methods

sub newWithError {
    my $class = shift;
    my $sendingProgram = shift;
    my $product = shift;
    my $service = shift;
    my $subject = shift;
    my $customer = shift;
    my $cluster = shift;
    my $body = shift;
    my @requestedTo = @_;

	return $class->newWithErrorHashArgs(
        sendingProgram => $sendingProgram,
        product => $product,
        service => $service,
        subject => $subject,
        customer => $customer,
        cluster => $cluster,
        body => $body,
        requestedTo => \@requestedTo,
	);
}

sub newWithErrorHashArgs {
    my $class = shift;
    my %args = (@_);

    my $sendingProgram = $args{ 'sendingProgram' };
    my $product = $args{ 'product' };
    my $service = $args{ 'service' };
    my $subject = $args{ 'subject' };
    my $customer = $args{ 'customer' };
    my $cluster = $args{ 'cluster' };
    my $body = $args{ 'body' };
    my $queryObjectFile = $args{ 'queryObjectFile' };
    my @requestedTo = $args{ 'requestedTo' };

    # 
    # don't forget to change _instanceNameToYearMonthDay() if you change this
    #
    my $time = time();
    my $pid = $$;
    my $host = ariba::Ops::NetworkUtils::hostname();

    my $instanceName = "pagerequest-" . $unique++ . "-" . $host . "-" . $pid . "-" . $time;

    my $self = $class->SUPER::new($instanceName); 
    
    $self->setSendingProgram($sendingProgram);
    $self->setProduct($product);
    $self->setService($service);
    $self->setSubject($subject);
    $self->setCustomer($customer);
    $self->setCluster($cluster);
    $self->setQueryObjectFile($queryObjectFile);
    $self->setRequestedTo(@requestedTo);

    #truncate body so we don't overflow underlying transport

    my $maxSize = ariba::Ops::UDPTransport->maxMessageSize() - 1000;

    if ( $body && length($body) > $maxSize ) {
        $body = substr($body, 0, $maxSize);
        $body .= "\n[...TRUNCATED...]\n";
    }
    

    $self->setBody($body);
        
    $self->setSendingHost($host);
    $self->setCreationTime($time);

    # list of real pages that have been sent for this

    $self->setPages(undef);


    return $self;
}


sub objectLoadMap {
    my $class = shift;

    my $mapRef = $class->SUPER::objectLoadMap();

    $mapRef->{'pages'} = '@ariba::Ops::Page';
    $mapRef->{'pageAck'} = 'ariba::Ops::PageAck';

    return $mapRef;
}

sub listObjects {
    my $class = shift;
    
    die "listObjects() not supported";
}

sub dir {
    my $class = shift;

    return $rootDir;
}


sub _instanceNameToYearMonthDay {
    my $class = shift;
    my $instanceName = shift;

    # grab creation time from instance name
    $instanceName =~ m/(\d+)$/;
    my $time = $1;

    return ariba::Ops::DateTime::yearMonthDayFromTime($time);
}

sub _computeBackingStoreForInstanceName {
    my $class = shift;
    my $instanceName = shift;

    # this takes the instance name as an arg
    # so that the class method objectExists() can call it

    my $dir = $class->dir();
    my ( $year, $month, $day ) = $class->_instanceNameToYearMonthDay($instanceName);

    my $file = "$dir/$year/$month/$day/$instanceName";

    return $file;
}

# This uses _objectCreatedWithinLastDay, which does some rounding to the date range.
sub recentPageRequests {
    my $class = shift;

    my @list;

    my $dir = $class->dir();

    my $time = time();
    
    my ($year, $month, $day) = ariba::Ops::DateTime::yearMonthDayFromTime($time - 24 * 60 * 60);
    my $yesterdayDir = "$dir/$year/$month/$day";

    ($year, $month, $day) = ariba::Ops::DateTime::yearMonthDayFromTime($time);
    my $todayDir = "$dir/$year/$month/$day";

    # allocate all the objects in $yeterdayDir and $todayDir
    # return only those less than 24 hours old

    for my $dir ( $yesterdayDir, $todayDir ) {
        opendir(DIR, $dir);
        my @files = grep($_ !~ /^\./o, readdir(DIR));
        closedir(DIR);

        for my $file (sort @files) {
            my $pageRequest = $class->new($file);

            if ( ariba::Ops::Utils::_objectCreatedWithinLastDay($pageRequest) ) {
                push(@list, $pageRequest);
            } 
        }
    }

    return @list;
}

# This uses a user-specified date range, with time resolution of 1 second.
sub pageRequestsForDateRange {
    my $class = shift;
    my $start = shift;
    my $end = shift;

    my @list;
    my @dirs;
    my $dir = $class->dir();

    my ($year, $month, $day) = ariba::Ops::DateTime::yearMonthDayFromTime($start);
    my $startDir = "$dir/$year/$month/$day";

    push (@dirs, $startDir);

    my $thisDate = $start + 24 * 60 * 60;

    while ($thisDate <= $end - 24 * 60 * 60) {
        ($year, $month, $day) = ariba::Ops::DateTime::yearMonthDayFromTime($thisDate);
        my $thisDir = "$dir/$year/$month/$day";
        push (@dirs, $thisDir);

        $thisDate += 24 * 60 * 60;
    }

    ($year, $month, $day) = ariba::Ops::DateTime::yearMonthDayFromTime($end);
    my $endDir = "$dir/$year/$month/$day";

    push (@dirs, $endDir) unless ($startDir eq $endDir);

    for my $dir (@dirs) {
        opendir(DIR, $dir);
        my @files = grep($_ !~ /^\./o, readdir(DIR));
        closedir(DIR);

        for my $file (sort @files) {
            my $pageRequest = $class->new($file);

            if ($dir ne $startDir && $dir ne $endDir) {
                push(@list, $pageRequest);
            } elsif ($pageRequest->creationTime() >= $start && $pageRequest->creationTime() <= $end) {
                push(@list, $pageRequest);
            }
        }
    }

    return @list;
}


# instance methods

sub sendToServer {
    my $self = shift;
    my $server = shift;
    my $debug = shift;
    my $port = shift;

    my $transport = ariba::Ops::UDPTransport->new();
    $transport->setDebug($debug);
    $transport->initAsClient($server, $port);

    return $transport->sendMessageToServer($self->saveToString(1) );
}

sub sendAsEmail {
        my $self = shift;

    #
    # A PageRequest is sent as email in only one case: when
    # the page server needs to downgrade a page from a crit to a warn
    # (like if /etc/nopage is set)
    #
    # Paged also sets a squelchReason if this is the case.
    #

    my $to = "";

    $to = join(", ", $self->requestedTo()) if ($self->requestedTo());


    #
    # As a temporary workaround as our API is adopted everywhere
    # make sure an_oncall_pagers@ansmtp.ariba.com is never used as To:
    # Use an_auto instead.
    #
    #

    if ( $to eq ariba::Ops::Constants->operationsPagerAddress() ) {
        $to = ariba::Ops::Constants->operationsEmailNotificationAddress();
    }

    my $subject = ariba::Ops::PageUtils::emailSubjectForSubject($self->subject(), $self->product(), $self->service(), $self->customer(), $self->cluster());
    my $body    = $self->body();

    if ( $self->squelchReason() ) {
        $body .= "\n" . $self->squelchReason() . "; this would have been a page.\n";
    }

    ariba::Ops::Utils::email($to, $subject, $body);
}

sub DESTROY {
    my $self = shift;

    $self->deleteAttribute('pages');
    $self->deleteAttribute('pageAck');
}

1;

