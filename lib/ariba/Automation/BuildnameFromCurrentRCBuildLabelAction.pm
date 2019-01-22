package ariba::Automation::BuildnameFromCurrentRCBuildLabelAction;

# Harrison was here: Revisions 6+7 of this module has been hacked up to
# add more debug code. When I am done testing, I will revert to 
# revision 5. 28-Apr-2010

use warnings;
use strict;

use ariba::Automation::Action;
use ariba::rc::Globals;
use ariba::Automation::Constants;
use ariba::Automation::Utils;
use ariba::rc::dashboard::Client;
use ariba::Automation::GlobalState;
use Data::Dumper;

use base qw(ariba::Automation::Action);

my $waitMinutes = 15;
my $sleepTimeInMinutes = ariba::Automation::Constants::sleepTimeForNewRCBuildInMinutes();
my $notificationWindow = 60 * 15; 

sub constructURL {
   my ($class,$logname,$logdirectory,$robotname) = @_;
   my $rootPath = "http://nashome.ariba.com/"."\~$robotname/"."logs/"."$logdirectory/"."$logname";
   return $rootPath;
}

sub validFields {
    my $class = shift;

    my $fieldsHashRef = $class->SUPER::validFields();

    $fieldsHashRef->{'archiveFinishTime'} = 1;
    $fieldsHashRef->{'buildName'} = 1;
    $fieldsHashRef->{'productName'} = 1;
    $fieldsHashRef->{'branch'} = 1;
    $fieldsHashRef->{'waitForNewBuild'} = 1;
    $fieldsHashRef->{'noQualWait'} = 1;
    $fieldsHashRef->{'pickOnlyStableBuild'} = 0;
    $fieldsHashRef->{'origin'} = 1;
    $fieldsHashRef->{'robotName'} = 1; # work around for no such method robotName

    return $fieldsHashRef;
}

sub execute {
    my $self = shift;

    my $logger = ariba::Ops::Logger->logger();
    my $logPrefix = $self->logPrefix();

    my $origin = $self->origin();
    my $link;
    
    my $prefix = "current-";
    $prefix = "stable-" if ( $self->pickOnlyStableBuild() );
    
    if ( $origin && -d $origin ) {
        $link = $origin . '/' . $prefix . $self->branch();
    }
    else {
        $link = ariba::rc::Globals::archiveBuilds($self->productName()) . '/' . $prefix . $self->branch();
    }

    my $buildName =  ariba::Automation::Utils::buildNameFromSymlink($link);
    return unless $buildName;

    $logger->info("$logPrefix The link = $link and the buildName = $buildName");

    my $archiveFinishTime = $self->_archiveFinishTime($buildName, $link);
    return unless $archiveFinishTime;

    my $notifiedForWait = 0;
    my $lastNotificationTime = time();

    while ( $self->waitForNewBuild() &&  
          $self->archiveFinishTime() && 
          ( $self->archiveFinishTime() == $archiveFinishTime )) {

        if ( !$notifiedForWait ) {
            $logger->info("$logPrefix Waiting for a new build for branch '" . $self->branch() . "'.");
            $notifiedForWait = 1;
        }

        sleep $sleepTimeInMinutes * 60;

        $buildName =  ariba::Automation::Utils::buildNameFromSymlink($link);

        return unless $buildName;

        $archiveFinishTime = $self->_archiveFinishTime($buildName, $link);

        return unless $archiveFinishTime;

        # print something every 15m; see ticket # 83266
        if (time() - $lastNotificationTime > $notificationWindow) {
            $logger->info ("$link pointing at $buildName (" . localtime ($archiveFinishTime) . ")");
            $lastNotificationTime = time();
            $notifiedForWait = 0;
        }
    }

    if ( $self->buildName() && $buildName eq $self->buildName() ) {
        $logger->info("Detected respin of '$buildName'");
    }

    unless ($self->noQualWait()) {
        my $globalState = ariba::Automation::GlobalState->newFromName($self->SUPER::attribute("robotName"));
        my $logName = $globalState->logFile();
        my $logDirectory = $globalState->logDir();
        my $robotName    = $self->robotName();
        my $logLocation  = $self->constructURL($logName,$logDirectory,$robotName);
        my $productName  = $self->productName();
        my $serviceName  = "personal_$robotName";
        
        my $client = new ariba::rc::dashboard::Client();
        $client->running ($buildName, "robot-bq", $logLocation, $productName, undef, undef, $serviceName );
        
        $logger->info("$logPrefix Waiting $waitMinutes minutes.");
        sleep $waitMinutes*60;
    }

    $logger->info("$logPrefix setting buildName '$buildName' from branch '" . $self->branch() . "'.");
    $self->setBuildName($buildName);
    $self->setArchiveFinishTime($archiveFinishTime);

    return 1;
}

sub _archiveFinishTime {
    my $self = shift;
    my $buildName = shift;
    my $link = shift;

    my $logger = ariba::Ops::Logger->logger();
    my $logPrefix = $self->logPrefix();

    my $archiveFinishTime = ariba::rc::Globals::archiveBuildFinishTime($self->productName(), $buildName);
    
    # If the FinishTime stamp isn't available, use the modify time of the symlink.
    unless ( $archiveFinishTime ) {
        $archiveFinishTime = (stat($link))[9];
        $logger->warn("Finish time of $buildName is not available, using symlink modify time: " . ariba::Ops::DateTime::prettyTime($archiveFinishTime));
    }

    unless ( $archiveFinishTime ) {
        $logger->error("Could not get time of '$link' to determine archive finish time");
        return;
    }

    return $archiveFinishTime;
}

sub pickOnlyStableBuild {
    my $self = shift;
    my $stableBuilds = $self->SUPER::pickOnlyStableBuild();

    $stableBuilds = 0 if !defined($stableBuilds);

    if ($stableBuilds && $stableBuilds =~ /^yes|true|1$/i) {
        return 1;
    }
    return 0;
}

1;
