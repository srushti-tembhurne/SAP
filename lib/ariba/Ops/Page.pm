package ariba::Ops::Page;

#$Id: //ariba/services/tools/lib/perl/ariba/Ops/Page.pm#26 $

use strict;
use vars qw(@ISA);

use ariba::Oncall::OperationsEngineer;
use ariba::Oncall::Schedule_v2;
use ariba::Ops::PersistantObject;
use ariba::Ops::UDPTransport;
use ariba::Ops::PageAck;
use ariba::Ops::PageRequest;
use ariba::Ops::Constants;
use ariba::Ops::PageUtils;
use ariba::Ops::DateTime;
use ariba::rc::Utils;

@ISA = qw(ariba::Ops::PersistantObject);

my $hackyPageNumber = 0;
my $rootDir = ariba::Ops::Constants->pagedir() . "/page-storage";

my $debug = 0;

# class methods

sub newFromPageRequest {
    my $class = shift;
    my $pageRequest = shift;

    # for now
    #XXX don't forget to change _instanceNameToYearMonthDay()
    #
    # what's the last page sent for this pageRequest?

    my $pageId;
    
    if ( $pageRequest->pages() ) {
        my @pages = $pageRequest->pages();
        my $lastPage = pop(@pages);
        my $lastPageName = $lastPage->instance();
        
        my ($number, $letter, $hour) = __pageIdToNumberLetterHour($lastPageName);

        if ( $letter eq "z" ) {
            # we're done.  This can't be resent again.
            return undef;
        }

        $pageId = $number . chr(ord($letter) + 1) . $hour;

    } else {    
        # never been paged for this before
        $pageId = $class->nextPageId();
    }

    my $instanceName = __pageIdToInstanceName($pageId);

    my $self = $class->SUPER::new($instanceName); 

    $self->setCreationTime(time());
    $self->setPageRequest($pageRequest);

    $self->setPageId($pageId);

    $self->setPageAck(undef);
    $self->setSendTime(undef);
    $self->setSentTo(undef);

    $pageRequest->appendToAttribute("pages", $self);

    return $self;
}

sub newFromPageId {
    my $class  = shift;
    my $pageId = shift;

    # given a page id find the instanceName and alloc the object

    return $class->new( __pageIdToInstanceName($pageId) );
}

sub __pageIdToInstanceName {
    my $pageId = shift;

    my $time = time();
    my $currentHour = (localtime($time))[2];
    my ($number, $letter, $hour) = __pageIdToNumberLetterHour($pageId); 

    my ($year, $month, $day);
    if ( $hour > $currentHour )  {
        # must be from yesterday
        ($year, $month, $day) = ariba::Ops::DateTime::yearMonthDayFromTime($time - 24 * 60 * 60);
        print "DEBUG: lookes like $pageId is from yesterday: $year, $month, $day\n";
    } else {
        ($year, $month, $day) = ariba::Ops::DateTime::yearMonthDayFromTime($time);
        print "DEBUG: lookes like $pageId is from today: $year, $month, $day\n";
    }

    my $instanceName = "$year/$month/$day/$pageId";

    return $instanceName;
}

sub __pageIdToNumberLetterHour {
    my $instanceName = shift;

    # our "instanceName" could be a page ID *or* an instanceName
    # deal with  both

    $instanceName =~ m/(\d+)([a-z])(\d+)$/;

    print "DEBUG: parsed $1, $2, $3 from $instanceName\n" if $debug;

    return ($1, $2, $3);
}

sub nextPageId {
    my $class = shift;

    my $currentHour = (localtime(time()))[2];

    my $hackyPageNumber = 1;
    my $proposedId;

    do {
        $proposedId = $hackyPageNumber++ . "a". $currentHour;

    } until (! $class->objectWithPageIdExists($proposedId));

    return  $proposedId;
}

sub objectWithPageIdExists {
    my $class = shift;
    my $pageId = shift;

    my $instanceName = __pageIdToInstanceName($pageId);

    return $class->objectWithNameExists($instanceName);
}

sub objectLoadMap {
    my $class = shift;

    my $mapRef = $class->SUPER::objectLoadMap();

    $mapRef->{'pageRequest'} = 'ariba::Ops::PageRequest';
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

sub _computeBackingStoreForInstanceName {
    my $class = shift;
    my $instanceName = shift;

    my $dir = $class->dir();
    my $file = "$dir/${instanceName}.page";

    print "DEBUG: Backing store for Page($instanceName) is $file\n" if $debug;

    return $file;
}

sub recentUnackedPages {
    my $class = shift;

    my @newlist;

    my $dir = $class->dir();

    my $time = time();
    # hack up some dates
    
    my ($year, $month, $day) = ariba::Ops::DateTime::yearMonthDayFromTime($time - 24 * 60 * 60);
    my $yesterdayDir = "$year/$month/$day";

    ($year, $month, $day) = ariba::Ops::DateTime::yearMonthDayFromTime($time);
    my $todayDir = "$year/$month/$day";

    # allocate all the objects in $yeterdayDir and $todayDir
    # return the recentUnackedOnes by checking if it's been acked

    my %seenPageRequest;
    for my $pdir ( $yesterdayDir, $todayDir ) {

        opendir(DIR, "$dir/$pdir");
        my @files = grep($_ !~ /^\./o, readdir(DIR));
        closedir(DIR);

        for my $file (sort @files) {

            my $instanceName = "$pdir/$file";
            $instanceName =~ s/\.page$//;
        
            print "DEBUG: Page->new($instanceName)\n" if $debug;

            my $page = $class->new($instanceName);

            unless ( $page->creationTime() ) {
                next;
            }

            unless ( ariba::Ops::Utils::_objectCreatedWithinLastDay($page) ) {
                next;
            }

            #XXX unique on page request!
            my $pageRequest = $page->pageRequest();
            my $key = $pageRequest->instance();

            if ( $pageRequest->pageAck() ) { 
                print "DEBUG: $class found Page $instanceName is acked\n" if $debug;
            } elsif ( $seenPageRequest{$key} ) {
                print "DEBUG: $class found Page $instanceName already delt with\n" if $debug;
            } else {
                $seenPageRequest{$key}++;
                print "DEBUG: $class found Page $instanceName is unacked\n" if $debug;
            }
        }
    }

    for my $prid ( keys %seenPageRequest ) {
        print "DEBUG: $class found PageRequest $prid with recent unacked pages\n" if $debug;
        my $pr = ariba::Ops::PageRequest->new($prid);
        my @ps = $pr->pages();
        if (@ps) {
            my $p = $ps[$#ps];
            print "DEBUG: $class found Page ". $p->instance(). " is recent unacked, will return\n" if $debug;
            push(@newlist, $ps[$#ps]);
        }
    }

    return @newlist;
}


# instance methods

sub _escalationAddress {
    my $self = shift;
    my $scheduleHomePath = '/home/svcops/on-call/schedule';
    my $userDataPath = '/home/svcops/on-call/people';
    my $pager;

    eval {

        my %MONTH_NUM_HASH = (1 =>  'Jan', 2 =>  'Feb', 3 =>  'Mar', 4 =>  'Apr', 5 =>  'May', 6 =>  'Jun',
                                            7 =>  'Jul', 8 =>  'Aug', 9 =>  'Sep', 10 => 'Oct', 11 => 'Nov', 12 => 'Dec',
        );
        my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
        $mon++;
        $year+=1900;
        my $monthAbbrev = lc($MONTH_NUM_HASH{$mon});
        my @v2MonthSchedule = ariba::Oncall::Schedule_v2::readMonthSchedule($monthAbbrev, $year, $scheduleHomePath, '-v2');
        my @v2DaySchedule = ariba::Oncall::Schedule_v2::getDaySchedule($mday, \@v2MonthSchedule);
        my $currHHMM = ariba::Oncall::Schedule_v2::getCurrTimeHHMM();
        my $onCallEntry = ariba::Oncall::Schedule_v2::findOnCallPerson($currHHMM, 'SRE', \@v2DaySchedule);
        my @details  = split /\,/, $onCallEntry;
        my $primary = ariba::Oncall::Person->new($details[3]);
        my $backupid = ariba::Oncall::Schedule_v2::findOnCallBackup($currHHMM, 'SRE', \@v2DaySchedule);
        my $backup = ariba::Oncall::Person->new($backupid);
        my $service = $self->pageRequest()->service();
        unless (ariba::Ops::PageUtils::usePagedForService($service)) {
            # this should never happen;  we should never get called like this;
            die "ariba::Ops::Page->_escalationAddress($service) was called and ariba::Ops::Utils::usePagedForService($service) is false";
        }
    
        #
        my @pages    = $self->pageRequest()->pages();
        my $numPages = scalar(@pages);
    
        # find page escalation for this service
        # if uses schedule or a person, get that way
        my @escalation = ariba::Ops::Constants::pagerEscalationForService($service);
        my @to = ();
        for my $token (@escalation) {
    
            if ($token eq 'PRIMARY') {
                if (my $email = $primary->pagerEmail()){
                    my $name = $primary->fullname();
                    $email = "\"$name\" <$email>";
                    push(@to, $email);
                }
                next;
            }
            if ($token eq 'BACKUP') {
                if (my $email = $backup->pagerEmail()){
                    my $name = $backup->fullname();
                    $email = "\"$name\" <$email>";
                    push(@to, $email);
                }
                next;
            }
    
            if (my $email = ariba::Oncall::OperationsEngineer->emailStringForPerson($token)) {
                push(@to, $email);
                next;
            }
    
            if ($token =~ /\@/) {
                push(@to, $token);
                next;
            }
        }
    
    
    
        # it's unclear if we want this here or further up in the stack.
        # Put here to keep next to allocation of the schedule objects
        # and to make sure we're always reading a fresh schedule from disk
        # since we know paged won't send that many pages.
        # However, it's only really need iff the schedule changes.
        # The schedule class should really cache based on last-mod time,
        #ariba::Oncall::Schedule->_removeSchedulesFromCache();
        ariba::Oncall::OperationsEngineer->_removeAllObjectsFromCache();
    
        my $escalationLength = scalar(@to);
        # 
        my $offset = $numPages % $escalationLength;
        $pager  = $to[$offset - 1];
    
        print "DEBUG: ariba::Ops::Page escalationLength=$escalationLength, numPages = $numPages, offset = $offset, pager = $pager\n";
    
        $pager = ariba::Ops::Constants::failsafePagerAddressForService($service) unless $pager;
    };
    if($@) {
        $pager="";
    }

    return $pager;
}

sub send {
    my $self = shift;

    my $service = $self->pageRequest()->service();
    my $to = $self->_escalationAddress();

    my $subject = "[" . $self->pageId() . "] " . ariba::Ops::PageUtils::emailSubjectForSubject(
        $self->pageRequest()->subject(),
        $self->pageRequest()->product(),
        $self->pageRequest()->service(),
        $self->pageRequest()->customer(),
        $self->pageRequest()->cluster(),
    );

    my $body = $self->pageRequest()->body();
    my $cc = join(", ", $self->pageRequest()->requestedTo());

    if($to =~/^\s*$/) {

        $to = 'an_auto_ops_ariba@sap.com';
        print "DEBUG : on-call primary not set.sending pages to team mailing list \n";

        if($cc =~/^\s*$/) {
            $cc='DL_52815EFCFD84A05CF4004B96@exchange.sap.corp';
        }

        $body = 'CRITICAL:No schedule for SRE primary.This leads to paged crash.'.$body;
    }

    if (-e '/var/tmp/no_stratus' && $self->pageRequest()->subject() =~ /Stratus/)
    {
        print "page email is suppressed\n" if ($debug);
    }
    elsif (-e '/var/tmp/no_cookies' && $self->pageRequest()->subject() !~ /Stratus/)
    {
        print "page email is suppressed\n" if ($debug);
    }
    else
    {
        ariba::Ops::Utils::email($to, $subject, $body, $cc, undef, undef, 'special-delivery');
    }
    # in parent set to whom and when this was sent
    $self->setSendTime(time());
    $self->setSentTo($to);
}   

sub setPageAck {
    my $self = shift;
    my $ack  = shift;

    # set ack on self and on our pageRequest
    $self->setAttribute('pageAck', $ack);

    my $pageRequest = $self->pageRequest();
    $pageRequest->setPageAck($ack);
}

sub DESTROY {
    my $self = shift;
    
    $self->deleteAttribute('pageRequest');
    $self->deleteAttribute('pageAck');
}       

1;
