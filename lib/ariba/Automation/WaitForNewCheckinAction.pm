package ariba::Automation::WaitForNewCheckinAction;

use warnings;
use strict;
use ariba::Automation::Action;
use ariba::rc::Globals;
use File::Basename;
use Ariba::P4;
use ariba::Ops::NetworkUtils;
use ariba::Automation::Constants;
use ariba::Automation::Remote::Robot;
use ariba::Automation::RobotScheduler;
use base qw(ariba::Automation::Action);

my $logger = ariba::Ops::Logger->logger();

sub validFields {
    my $class = shift;

    my $fieldsHashRef = $class->SUPER::validFields();

    #$fieldsHashRef->{'archiveFinishTime'} = 1;
    $fieldsHashRef->{'branchName'} = 1;
    $fieldsHashRef->{'productName'} = 1;
    $fieldsHashRef->{'sleepTimeForNewCheckinsInMinutes'} = 1;
    $fieldsHashRef->{'additionalPerforcePath'} = 1;
    $fieldsHashRef->{'mavenTLP'} = 1;

    return $fieldsHashRef;
}

sub execute {
    my $self = shift;

    my $logPrefix = $self->logPrefix();
    my $sleepTimeBetweenChecks = $self->attribute ('sleepTimeForNewCheckinsInMinutes');
    my $latestChange;
    
    while (1) {
        if ($self->_buildNowFlagExists()) {
            $logger->info ("Building now...");
            last;
            }

        # break out of loop early if a scheduled build time is forthcoming
        my $globalState = ariba::Automation::GlobalState->newFromName($self->SUPER::attribute("robotName"));
    
        # nap until scheduled build time (optional)
        my $build_imminent = ariba::Automation::RobotScheduler::nap 
            ($globalState->lastElapsedRuntime(), $globalState->buildSchedule());
    
        my $status = $self->_canIRunNow();

        if (!$status) {
            # bail early if a scheduled build is happening soon
            last if $build_imminent;
            $logger->info("Cannot run now. Will sleep for $sleepTimeBetweenChecks minutes");
            sleep 60 * $sleepTimeBetweenChecks;
            next;
        } 
        elsif ($status == 99) {
            $logger->info("$logPrefix This is the first run");
            last;
        } 
        else {
            $latestChange = $status;
            $logger->info("$logPrefix This run will be at changelist $latestChange");
            $globalState->setAttribute("currentChange", $latestChange);
            $globalState->save();
            last;
        }
    }

    return 1;
}

sub _canIRunNow {
    my $self = shift;

    $logger->info("Checking if we can run now");

    # Is this the first run
    # Then go ahead and run
    # First, find out the change at which the last run happened
    #my $lastChange = $self->currentChange();

    my $globalState = ariba::Automation::GlobalState->newFromName($self->SUPER::attribute("robotName"));
    my $currentChange = $globalState->currentChange();
    my $lastChange = $currentChange;

    #my $lastChange = "1569704";
    #my $lastChange = "0";

    if (! $lastChange) {
        # This is the first run for this robot
        return 99;
    }

    # See if a new checkin has happened on this branch
    my $latestChange = $self->_getLatestChangeAfterLastRun($lastChange);
    return 0 if (!$latestChange);

    return $latestChange;
}

sub _getLatestChangeAfterLastRun {
    my $self = shift;
    my $lastChange = shift;

    # Find out the components.txt path
    my $branch = $self->attribute ('branchName');

    # Get the product name and build config dir path
    my $product = $self->attribute('productName');
    
    # Get the product name and build config dir path
    my $additionalPerforcePath = 0;
    $additionalPerforcePath = $self->attribute('additionalPerforcePath');
    
    # Get maven top level pom
    my $mavenTLP = $self->attribute('mavenTLP');
        
    

    # Use the global productName if there is no action level productName defined
    if (! $product)
    {
    	my $globalState = ariba::Automation::GlobalState->newFromName($self->SUPER::attribute("robotName"));
    	$product = $globalState->productName();
    }
 
    #check for perforce downtime before pinging the perforce
    my $hostname = ariba::Ops::NetworkUtils::hostname();
    my $isIDC = ariba::Automation::Utils::isIdcRobotHost($hostname);
    
    if (my $expectedDelay = Ariba::P4::isScheduledPerforceDowntimeApproaching($isIDC)) {
	sleep($expectedDelay);
    }
    Ariba::P4::waitForPerforce();

    
    my $latestChange;
    my $location = $branch;
    if($mavenTLP) {
        $logger->info("Checking for new checkins since $lastChange using paths in $mavenTLP");
       $latestChange = ariba::Automation::Utils::getChangesForMavenProduct($lastChange, $mavenTLP);
        $location = $mavenTLP;
    }
    else {
        $latestChange = ariba::Automation::Utils::getChangesForProduct ($lastChange, $product, $branch, $additionalPerforcePath);
    }
    
    if (!defined($latestChange) || $latestChange < $lastChange) {
        $logger->info("No new checkins to the paths in $location");
        return 0;
    } else {
       $logger->info("New checkins have come in after the last run related to paths in $location");
       return $latestChange;
    }
}

sub _buildNowFlagExists {
	my $self = shift;
	my $build_now_flag = ariba::Automation::Constants::buildNowFile();
	if (-e $build_now_flag) { 
		$logger->info ("Building now...");
		return 1;
	}
	return 0;
}


1;
