package ariba::Automation::Robot;

use strict;
use warnings;

use Carp;

use ariba::Ops::PersistantObject;
use base qw(ariba::Ops::PersistantObject);

use ariba::Automation::Constants;
use ariba::Automation::GlobalState;
use ariba::Automation::ConfigReader;
use ariba::Automation::Action;
use ariba::Automation::Utils;
use ariba::Automation::Utils::FileSize;
use ariba::Automation::RobotCommunicator;
use ariba::Automation::Remote::Client;
use ariba::Automation::RobotScheduler;
use ariba::Automation::RobotServiceURLDelivery;
use ariba::Ops::Logger;
use ariba::Ops::DateTime;
use ariba::Ops::NetworkUtils;
use ariba::Automation::BuildInfo;

use Ariba::P4::User;

use ariba::rc::Globals;
use ariba::rc::BuildContactInfo;
use ariba::rc::events::Constants;
use ariba::rc::events::client::Event;
use ariba::rc::BuildDef;
use ariba::rc::ChangeReport;

use File::Copy;
use File::Basename;
use File::Find;
use IO::Handle;
use MIME::Lite;
use LWP::Simple;

my $VERSION = 2.18;
my $logger = ariba::Ops::Logger->logger();

my $STATUS_SUCCESS = "success";
my $STATUS_FAILURE = "FAILURE";
my $STATUS_NEW = "new";

my $STATE_INIT = "init";
my $STATE_RUNNING = "running";
my $STATE_WAITING = "waiting";
my $STATE_PAUSED = "paused";
my $STATE_STOPPED = "stopped";

my $ACTION_ERROR = "action error";
my $CONFIG_ERROR = "config error";

my $MAX_BUILDINFO_ENTRIES = 4;

my $SCHEDULE_STRICT = "strict";
my $SCHEDULE_LOOP = "loop";

my $DISK_FULL_NOTIFY_THRESHOLD = 60 * 60 * 3;
my @DISK_FULL_MONITOR_VOLUMES = qw (/ /robots);
my $LARGE_LOGFILE_THRESHOLD = 1250000000; # 1.25GB
my $UPDATE_CHECK_THRESHOLD = 60 * 60 * 4;

my $PAUSE_AT_NEXT_ACTION = 1;
my $PAUSE_AT_NAMED_ACTION = 2;

my $RESTART_NAP_TIME = 15;

sub setDebug {
    my $self = shift;
    my $debug = shift;

    if ($debug) {
        $logger->setLogLevel(ariba::Ops::Logger::DEBUG_LOG_LEVEL());
        $self->SUPER::setDebug(1);
    } else {
        $logger->setLogLevel(ariba::Ops::Logger::INFO_LOG_LEVEL());
        $self->SUPER::setDebug(0);
    }
}

sub newFromNameNoInit {
    my $class = shift;
    my $robotName = shift;

    my $self = $class->SUPER::new($robotName);

    $self->setReadOnly(1);
    $self->_initFromConfigFile(0);
    $self->setRobotName($robotName);

    return $self;
}

sub newFromName {
    my $class = shift;
    my $robotName = shift;

    my $self = $class->SUPER::new($robotName);

    $self->setReadOnly(0);
    $self->setPid($$);
    $self->setRobotName($robotName);

    my $client = ariba::Automation::Remote::Client->newFromRobot($self);
    $client->postConfig();

    $self->setState($STATE_INIT);
    $self->setHostname(ariba::Ops::NetworkUtils::hostname());
    $self->handlePerforceDowntime();
    $self->_initFromConfigFile(1);

    return $self;
}

sub handlePerforceDowntime {
    my $self = shift;
    my $hostname = ariba::Ops::NetworkUtils::hostname();
    my $isIDC = ariba::Automation::Utils::isIdcRobotHost($hostname);

    if (my $expectedDelay = Ariba::P4::isScheduledPerforceDowntimeApproaching($isIDC)) {
        sleep($expectedDelay);
    }
    Ariba::P4::waitForPerforce();
}

sub run {
    my $self = shift;

    my $shouldRun = 1;
    my $runNumber = 0;

    my $globalState = ariba::Automation::GlobalState->newFromName($self->instance());

    $self->setLastRuntime(time());
    $self->setRobotVersion ($VERSION);
    $self->setupLogDirectory();
    $self->setShutdownReason("");

    # initialize lastBuildTime if it isn't available
    $self->setLastBuildtime(time()) unless $self->lastBuildtime();

    # build number tracks total number of builds made by a robot.
    # this value is used to correlate against test reports and CL#s.
    my $buildNumber = $self->buildNumber() || 0;

    #
    # reset stopped state if any
    #
    my $rbc = ariba::Automation::RobotCommunicator->new();
    $rbc->ackStop();

    #
    # waiting is true if robot is waiting to make a scheduled build
    #
    my $waiting = 0;

    while ($shouldRun) {
      if (! $waiting) {
            unless ($self->debug()) {
                $self->redirectOutputToFile($runNumber);
            } else {
                $self->setLogFile("");
                $logger->debug("Debug is set, all output will go to the console.");
            }
            $logger->info("[Robot/$VERSION] Starting up");
        }

        #
        # See if a new release of robot software is available
        #
        $self->checkForUpdates() unless $self->debug();

        #
        # Keep run number around
        #
        $self->setRunNumber ($runNumber);

        #
        # reload config file at top of loop: default is true
        #
        my $reloadConfigFile = $self->reloadConfigFile() || "";
        if (! length ($reloadConfigFile)) {
            $reloadConfigFile = 1;
            $self->setReloadConfigFile ($reloadConfigFile);
        }
        if ($runNumber && ! $waiting && $reloadConfigFile) {
            $logger->info ("Reloading robot.conf");
            $self->handlePerforceDowntime();
            $self->_initFromConfigFile(1);

            # send config to robot server
            my $client = ariba::Automation::Remote::Client->newFromRobot($self);
            $client->postConfig();
        }

        #
        # force state update before actions/scheduler begins
        #
        $self->setState ($self->state()) unless $waiting;

        #
        # nap until scheduled build time (optional)
        #
        my $buildSchedule = $self->buildSchedule() || "";

        if ($buildSchedule) {
            #
            # nap returns true if RobotScheduler slept in anticipation of
            # an upcoming build
            #
            $self->setState($STATE_WAITING);
            my $slept = ariba::Automation::RobotScheduler::nap
                ($self->lastElapsedRuntime(), $buildSchedule);

            #
            # there are two build schedule types:
            #
            # strict = only build on schedule (default)
            # loop = build around schedule waiting if build time is imminent
            #
            my $buildScheduleType = $self->buildScheduleType || $SCHEDULE_STRICT;

            # if we didn't sleep and schedule type is strict, continue.
            if (! $slept && $buildScheduleType eq $SCHEDULE_STRICT) {
                $logger->info ("Waiting for scheduled build: $buildSchedule") if ! $waiting;
                $waiting = 1;
                sleep 60;
                next;
            }
        }
        $waiting = 0;

        my $TIMINGFH = $self->setupTimingFile($runNumber);
        my $actionRunTime;
        my $lastGoodChangeNumber = $self->lastGoodChange() || 0;

        $self->setBuildNumber (++$buildNumber);

        #
        # track whether this robot ran qual or not
        #
        my $_isQualMachine = $self->isQualMachine() || "";
        my $isQualMachine = $self->isQualMachine() || 0;

        # set isQualMachine for the first time we run
        $self->setIsQualMachine ($isQualMachine) if $_isQualMachine eq "";

        # true if qual generated xml report
        $self->setDidQualRun (0);

        $logger->info("Starting main robot loop");

        my @actions = $self->actionsOrder();
        my @executedActions;

        if (scalar(@actions) < 1) {
            $logger->error("No actions found! Exiting.");
            $self->setStatus($STATUS_FAILURE);
            $self->setErrorType($ACTION_ERROR);
            $self->notifyOnFailure("No actions found!\n");
            $shouldRun = 0;
            last;
        }

        my $actionCounter = 0;

        if ($runNumber) {
            $self->setState($STATE_WAITING);
            my $sleepTime = defined $self->waitTimeInMinutes() ? $self->waitTimeInMinutes() : 5;
            $logger->info("Robot waiting for $sleepTime minutes before starting run");
            $sleepTime *= 60;
            sleep($sleepTime);
        }

        $self->setLastBuildtime(time());

        my $failedInsideLoop = 0;
        my $shortCircuitActions = 0;
        my $rbc;
        my $stopWasRequested = 0;
        my $qualTestId = 0;
        my $attemptNotifyAtPause = 0;

        while (scalar(@actions)) {

            $rbc = ariba::Automation::RobotCommunicator->new();

            # if a stop is requested, skip running the actions
            if ($rbc->stopRequested()) {
                $stopWasRequested = 1;
                $self->setBuildResult($STATE_STOPPED);
                last;
            }

            # pause the robot if the action is configured to do so
            if ($actions[0]->pause() && $self->state() ne $STATE_PAUSED) {
                $attemptNotifyAtPause = $PAUSE_AT_NEXT_ACTION;
                $rbc->pause();
            }

            if ( $rbc->pauseRequested() ) {
                $self->setState($STATE_PAUSED);
                $logger->info("Robot is paused.");
                $attemptNotifyAtPause = $PAUSE_AT_NEXT_ACTION;
                $rbc->ackPause();
            }

            if ( $rbc->pauseAtActionRequested() && $rbc->pauseAtActionRequested() eq $actions[0]->instance() ) {
                $self->setState($STATE_PAUSED);
                $logger->info("Robot is paused.");
                $attemptNotifyAtPause = $PAUSE_AT_NAMED_ACTION;
                $rbc->ackPauseAtAction();
            }

            $self->notifyOnPause ($attemptNotifyAtPause, $actions[0]->instance()) if $attemptNotifyAtPause;

            if ( $self->state() eq $STATE_PAUSED ) {
                if ( $rbc->resumeRequested() )  {
                    $rbc->ackResume();
                } else {
                    sleep 15;
                    next;
                }
            }

            my $action = shift(@actions);

            $action->setActionError(0);

            ++$actionCounter;
            $action->setTesting($self->testing());

            if ($action->skip()) {
                $logger->debug("Skipping action " . $action->instance());
                next;
            }

            $self->setLastActionName($action->instance());
            push(@executedActions, $action);

            $self->setState($STATE_RUNNING);

            $action->setPreviousStartTime($action->startTime())
                if $action->startTime();;

            $action->setStartTime(time);

            printf $TIMINGFH "%30s |%20s",
                $action->instance(),
                    ariba::Ops::DateTime::prettyTime($action->startTime());

            # Explicitly populating logfile for RC DB
            $action->setLogFile($self->logFileLink());

            unless ( $action->execute() ) {

                my $lastSystemCommand = $action->lastSystemCommand();
                my $lastExitStatus = $action->lastExitStatus();

                if ($lastSystemCommand && $lastExitStatus) {
                    $logger->info("Last system command was \n\t".$lastSystemCommand);
                    $logger->info("Last system command exited with $lastExitStatus");
                }

                $rbc = ariba::Automation::RobotCommunicator->new();
                if ( $rbc->stopRequested() ) {
                    $self->setBuildResult($STATE_STOPPED);
                    $logger->info("Last action was killed due to stop request.");
                    $shortCircuitActions = 1;
                    $stopWasRequested = 1;
                } else {
                    $logger->error("Failed to execute " . $action->instance());
                    if ($action->stopOnError()) {
                        $failedInsideLoop = 1;
                        $shortCircuitActions = 1;
                    } else {
                        $logger->info("Continuing with run, stopOnError is set to false making this a non-fatal error");
                    }
                }
            }

            $self->checkFreeDiskSpace();

            $action->setPreviousEndTime($action->endTime()) if $action->endTime();;
            $action->setEndTime(time);

            printf $TIMINGFH " |%20s | %-20s\n",
                   ariba::Ops::DateTime::prettyTime($action->endTime()),
                   ariba::Ops::DateTime::scaleTime($action->endTime() - $action->startTime());

            $actionRunTime += $action->endTime() - $action->startTime();

            # note whether we ran qual or not for notification purposes
            my $actionType = $action->type() || "";
            if ($actionType eq "buildnameFromCurrentRCBuildLabel") {
                $logger->info ("This is a qual robot: actionType=buildnameFromCurrentRCBuildLabel");
                $isQualMachine = 1;
            }
            elsif ($actionType eq "startAndWaitForQual") {
                if (! $action->actionError()) {
                    $qualTestId = $action->qualTestId() || 0;
                    if ($qualTestId) {
                        $self->setDidQualRun (1);
                    }
                }
            }
            last if $shortCircuitActions || $action->shortCircuit();
        }

        $self->cleanUp();

        my $lastErrorAction;

        # Don't set the status and error stuff if a stop was requested.  The stop
        # will cause actions to error out when they're kill abrubtly
        if ($self->dontSpin() || $rbc->stopRequested()) {
            $self->setState($STATE_STOPPED);
            $self->setBuildResult($STATE_STOPPED);
            $rbc->ackStop();
            if ($self->dontSpin()) {
                $logger->info("Stop requested via global.dontSpin configuration, exiting.");
            }
            elsif ($rbc->stopRequested()) {
                $logger->info("Stop requested, exiting.");
            }
            $stopWasRequested = 1;
            $shouldRun = 0;
        } elsif ($failedInsideLoop) {
            $self->setStatus($STATUS_FAILURE);
            $self->setBuildResult($STATUS_FAILURE);
            $self->setErrorType($ACTION_ERROR);
            $self->setPreviousErrorAction($self->errorAction());
            $self->setErrorAction($self->lastActionName());
        } else {
            $self->setStatus($STATUS_SUCCESS);
            $self->setBuildResult($STATUS_SUCCESS);

            #
            # set lastgoodChange here, after we declare success.
            #
            my $lastChange = $self->currentChange();
            my $lastChangeTime = $self->currentChangeTime();

            if ($lastChange) {
                my $lastGoodChange = $self->lastGoodChange();

                if ($lastGoodChange) {
                    # don't process the same "good" changelist twice
                    if ($lastGoodChange ne $lastChange) {
                        $self->appendToLastGoodChangeList($lastChange);
                        $self->appendToLastGoodChangeTimeList($lastChangeTime);
                    }
                } else {
                    $self->setLastGoodChangeList($lastChange);
                    $self->setLastGoodChangeTimeList($lastChangeTime);
                }
            }

            $self->setErrorType("");
            $self->setErrorAction("");
        }

        my $forceFailure = $self->forceFailure() || 0; # induce failure via robot.conf
        my $mailAlways = $self->mailAlways() || 0; # always send e-mail

        #
        # track whether this robot ran qual
        #
        $self->setIsQualMachine ($isQualMachine);

        #
        # notification
        #
        my $lastAction = $self->lastAction();

        my $predicate = 0;
        if ($self->status() && $self->previousStatus() && ($self->status() ne $self->previousStatus())) {
            $predicate = 1;
        }

        if ($self->status() && $self->errorAction() && $self->previousErrorAction() &&
            ($self->status() eq $STATUS_FAILURE) &&
            (($self->errorAction() ne $self->previousErrorAction()) || ($lastAction && $lastAction->notifyOnFailure()))) {
            $predicate = 1;
        }

        if ( $predicate || $forceFailure || $mailAlways ) {

            if ($forceFailure) {
                $self->setStatus ($STATUS_FAILURE);
                $self->setBuildResult($STATUS_FAILURE);
                $logger->info ("Failing build based on forceFailure flag in config file");
            }

            if ($self->status() eq $STATUS_FAILURE) {
                # track the number of times the build has failed in a row
                my $failCount = $self->failCount() || 0;
                $self->setFailCount (++$failCount);

                # track the first fail time
                my $failDate = $self->failDate() || 0;
                if (! $failDate) {
                    $self->setFailDate (time());
                }

                # track the first CL# to fail
                my $failChangeList = $self->currentChange() || $self->lastGoodChange() || 0;
                $self->setFailChangeList ($failChangeList) unless $failChangeList;

                $self->notifyOnFailure(\@executedActions, $qualTestId)
                    unless $stopWasRequested;

                # if this is the first time we've run after an error, let
                # someone know we're back on track
            } elsif ( $self->status() eq $STATUS_SUCCESS) {
                $self->notifyOnSuccess(\@executedActions, $qualTestId)
                    unless $stopWasRequested;
                $self->setFailCount (0);
                $self->setFailDate (0);
                $self->setFailChangeList (0);
            }
        }

        if ($self->status() eq $STATUS_SUCCESS) {
            if ($stopWasRequested == 0) {
                # store the last time-to-run if the run was successful
                $self->setLastElapsedRuntime ($actionRunTime);
                $logger->info("Last elapsed runtime was " . ariba::Ops::DateTime::scaleTime($actionRunTime));

                # write total time-to-run to timing file
                printf $TIMINGFH "%74s | %s\n", "Total", ariba::Ops::DateTime::scaleTime($actionRunTime);
            }
        }

        close $TIMINGFH;
        $runNumber++;

        # generate runtime graph
        if ($stopWasRequested == 0) {
            # RobotTimingGraph calls CDB which calls die if something goes wrong
            eval {
                # work around difference between mars and robots by including
                # the required module at runtime
                require ariba::Automation::RobotTimingGraph;
                ariba::Automation::RobotTimingGraph::makeTimingOverview();
            };

            if ($@) {
                $logger->warn ("Couldn't make robot timing graph: $@");
            }
        }

        # send RC event
        if (! $stopWasRequested) {
            if ($self->status() eq $STATUS_SUCCESS) {
                $self->sendRcEvent ($STATUS_SUCCESS, $qualTestId, \@executedActions);
            } elsif ($self->status() eq $STATUS_FAILURE) {
                $self->sendRcEvent ($STATUS_FAILURE, $qualTestId, \@executedActions);
            }
        }

        # send service URLs to Robot King
        my $productName  = $self->productName() || "";
        if ($productName && $stopWasRequested == 0) {
            my $delivery = new ariba::Automation::RobotServiceURLDelivery();
            if (! $delivery->send_update ($productName)) {
                $logger->warn ("RobotServiceURLDelivery failed to send update to Robot King: " . $delivery->get_last_error());
            }
        }

        #
        # Correlate build info map: test reports and CL#s to build number
        #
        $self->updateBuildInfo ($qualTestId, $lastGoodChangeNumber) if $stopWasRequested == 0;

        $logger->info("[Robot/$VERSION] Ending main robot loop run #$runNumber");
    }
}

sub notifyOnSuccess {
    my $self = shift;
    my $actions = shift;;
    my $qualTestId = shift || "";
    $self->setState ($self->state());
    $self->_notify_html ($STATUS_SUCCESS, $actions);
}

sub notifyOnFailure {
    my $self = shift;
    my $actions = shift;
    my $qualTestId = shift || "";
    $self->setState ($self->state());
    $self->_notify_html ($STATUS_FAILURE, $actions);
}

sub notifyOnPause {
    my $self = shift;
    my $pauseType = shift;
    my $actionName = shift;

    # get global state
    my $globalState = $self->globalState();
    my @notifications = $globalState->notifications();
    if ($#notifications == -1) {
        $globalState->deleteAttribute ("notifications");
        $globalState->save() unless $self->readOnly();
        return;
    }

    # send notifications if we're paused in the right place
    my @unsent;
    foreach my $notify (@notifications) {
        # notifications are broken into 3 parts:
        # - email address of recipient
        # - name of action to pause at or dash ("-") to pause at next action
        # - timestamp
        $notify = $notify || "";
        next unless $notify;

        my ($email, $action, $when) = split /:/, $notify;

        if ($pauseType == $PAUSE_AT_NEXT_ACTION && $action eq "-") {
            $self->_sendPauseNotification ($email, $action, $when);
        } elsif ($pauseType == $PAUSE_AT_NAMED_ACTION && $action eq $actionName) {
            $self->_sendPauseNotification ($email, $action, $when);
        } else {
            push @unsent, $notify;
        }
    }

    # save unsent notifications back to disk
    if ($#unsent == -1) {
        $globalState->deleteAttribute ("notifications");
    } elsif ($#unsent == 0) {
        $globalState->setNotifications ($unsent[0]);
    } else {
        $globalState->setNotifications (shift @unsent);
        foreach my $unsent (@unsent) {
            $globalState->appendToNotifications ($unsent);
        }
    }

    # save changes
    $globalState->save() unless $self->readOnly();
}

sub globalState {
    my $self = shift;

    my $globalState = ariba::Automation::GlobalState->newFromName($self->instance());
    return $globalState;
}

sub getLogTail {
    my $self = shift;
    my $numOfLines = shift;

    return unless $self->hasRun();

    my $logFile = $self->logPath() . '/' . $self->logDir() . '/' . $self->logFile();
    unless (open (LOG, $logFile)) {
        $logger->warn("Could not open '$logFile'");
        return;
    }
    my @lines = <LOG>;
    close LOG;

    my @tail;
    my $linesProcessed = 0;
    while (my $line = pop @lines) {
        if($line =~ /<[^>]*>/) {  # fix: Check for valid html tag only (which starts with < and ends with > )
           $line =~ s/</&lt;/g;   # replace  < with &lt;
           $line =~ s/>/&gt;/g;   # replace  > with &gt;
        }
        unshift @tail, $line;
        $linesProcessed++;
        last if $linesProcessed >= $numOfLines
    }

    return @tail;
}

sub logDirLink {
    my $self = shift;

    my $link = ariba::Automation::Constants->linkBaseUrl() . "~" . $self->instance() . "/logs";
    return $link;
}

sub logFileLink {
    my $self = shift;

    if (!$self->logDirLink() || !$self->logDir() || !$self->logFile()) {
        return;
    }

    my $link = $self->logDirLink() . "/" . $self->logDir() . '/' . $self->logFile();
    return $link;
}

sub _additional_recipients {
    my $self = shift;
    my $status = shift;

    # location of product.bdf based on branch name
    my $targetBranchname = $self->targetBranchname() || "";
    return "" unless $targetBranchname;

    # get contact info + number of failures required from product.bdf
    my ($email, $threshold) =
        ariba::rc::BuildContactInfo::get_contact_info ($targetBranchname);

    # bail early if an e-mail address hasn't been specified
    return "" unless $email;

    # use a reasonable default for failure count
    $threshold = $threshold || 0;

    # how many consecutive failures has the robot seen?
    my $failCount = $self->failCount() || 0;

    # bail early if we're not experiencing any failures
    return "" unless $failCount;

    # return contact info if number of consecutive failures
    # is greater-than the specified threshold
    if ($failCount >= $threshold && $status eq $STATUS_FAILURE) {
        return $email;
    }

    # return contact info if qual fails
    if ($self->isQualMachine() && $status eq $STATUS_FAILURE) {
        return $email;
    }

    # nothing bad is happening
    return "";
}

#
# Send RC Event
#
sub sendRcEvent {
    my $self = shift;
    my $status = shift;
    my $qualTestId = shift;
    my $actions = shift;

    my $instance = $self->instance();
    my $robotHost = $self->hostname() || "";
    my $robotKingURL = ariba::Automation::Constants->serverFrontdoor() .
        ariba::Automation::Constants->serverRobotKingUri() .
        ($robotHost ? "?robot=$robotHost" : "");
    my $robotKingURLlabel = $robotHost || "RobotKing";
    my $robotName = $self->name() || $instance;
    my $productName  = $self->productName() || "n/a";
    my $targetBranchName = $self->targetBranchname();

    #
    # Link to changelist browser
    #
    my $changeListLink = <<FIN;
Changelist: n/a
FIN
    my $changeStart = $self->lastGoodChange() || 0;
    my $changeEnd = $self->currentChange() || 0;
    if ($changeStart || $changeEnd) {
        my $changeListLabel = $changeStart == $changeEnd ? $changeStart : "$changeStart-$changeEnd";
        $changeListLink = <<FIN;
Changelist: <a href="http://rc.ariba.com:8080/cgi-bin/robot-status?action=changelist&robot=buildbox19.ariba.com&branch=$targetBranchName&start=$changeStart&end=$changeEnd&productName=$productName">$changeListLabel</a>
FIN
    }

    #
    # Link to test report
    #

    my $testReportLink = <<FIN;
Test Report: n/a
FIN
    if ($qualTestId) {
        my $now = localtime ($qualTestId / 1000); # test id expressed in milliseconds since epoch
        $testReportLink = <<FIN;
Test Report: <a href="http://nashome/~$instance/testReports-$productName/$qualTestId/runtests.output.all.email.html">$now</a>
FIN
    }

    my $subject = $self->_makeBriefSubjectLine ($status);

    my $body = <<FIN;
Robot: <a href="$robotKingURL">$robotKingURLlabel</a><br>
Product: $productName<br>
$testReportLink<br>
$changeListLink<br>
FIN

    #
    # Link to logfile
    #
    if ($self->logFile()) {
        my $logFileLink = $self->logFileLink();
        my $logDir = $self->logDir();
        my $logFile = $self->logFile();
        my $headLink = <<FIN;
<a href="/cgi-bin/robot-status?action=head&instance=$instance&lines=40&dir=$logDir&file=$logFile">head</a>
FIN
        my $tailLink = <<FIN;
<a href="/cgi-bin/robot-status?action=tail&instance=$instance&lines=40&dir=$logDir&file=$logFile">tail</a>
FIN

        $body .= <<FIN;
Log: <a href="$logFileLink">$logFile</a> - $headLink - $tailLink<br>
FIN
    }

    my ($changesInfo, $submitters) = $self->generateChangelist();
    if ($changesInfo) {
        $body .= "<br/>" . $changesInfo;
    }

    my @attached;

    # Append available attachments to event description
    for my $action (@$actions) {
        my $attachment = $action->attachment();
        if ( $attachment && !$action->actionError() ) {
            if (open ATTACHMENT, $attachment) {
                push @attached, "Report from " . $action->instance() . ":\n";
                while (<ATTACHMENT>) {
                    next if $self->disgardAttachmentLines ($_);
                    push @attached, $_;
                }
                close ATTACHMENT;
            }
        }

        my $actionInstance = $action->instance();
        my ($message,$toList) = $action->notifyMessage(1);
        if ($message) {
            push @attached, <<FIN;
<table style="font-family: sans-serif; border: 1px solid #666;" border=0 cellpadding=2 cellspacing=1>
<tr>
<td align=left valign=top colspan=2 bgcolor="#efefef">
<b>$actionInstance:</b><br>
$message
</td>
</tr>
</table>
<br>
FIN
        }
    }

    if (@attached) {
        $body .= join "\n", @attached;
    }

    if ($self->logFile()) {
        my $logFileLink = $self->logFileLink();
        my $tailLength = 20;
        my @logTail = $self->getLogTail($tailLength);
        my $logOutput = join "", @logTail;
        $body .= <<FIN;
<br>
<span style="font-family: sans-serif">
<b>Log File:</b> <a href="$logFileLink">$logFileLink</a>
</span>
<table width="100%" border=0 cellpadding=2 cellspacing=1>
<tr>
<td align=left valign=top bgcolor="#efefef"><tt><pre>$logOutput</pre></tt></td></tr>
</table>
FIN
    }


    #
    # Send RC Event
    #
    my $event = new ariba::rc::events::client::Event
    (
        {
            channel_name => $self->name(),
            channel => $self->instance(),
            title => $subject,
            description => $body,
        }
    );

    if (! $event->publish()) {
        $logger->info ("Failed to publish event: " . $event->get_last_error());
    }
}

#
# Remove unwanted html tags from RSS items
#
sub disgardAttachmentLines {
    my ($self, $line) = @_;

    # strip html head and body tags
    if ($line =~ m#(xml version="1.0"|<html>|<body>|</body>|</html>)#i) {
        return 1;
    }

    return 0;
}

sub _sendPauseNotification {
    my ($self, $email, $action, $when) = @_;
    my $instance = $self->instance();
    my $robotVersion = $self->robotVersion() || "n/a";
    my $subject = "$instance has paused";
    my $now = localtime ($when);
    my $robotHost = $self->hostname() || "";
    my $robotKingURL = ariba::Automation::Constants->serverFrontdoor() .
        ariba::Automation::Constants->serverRobotKingUri() .
        ($robotHost ? "?robot=$robotHost" : "");
    my $actionLabel = "";
    if ($action ne "-") {
        $actionLabel = "Action: $action<br>\n";
    }
    my $body = <<FIN;
You requested a notification when $instance paused.<br>
<br>
Robot: <a href="$robotKingURL">$instance</a><br>$actionLabel
Request Time: $now
FIN

    $logger->info ("Paused" . ($action eq "-" ? "" : " at $action") . ", sending notification to $email");
    my $event = new ariba::rc::events::client::Event
    (
        {
            channel => $email,
            title => $subject,
            description => $body,
        }
    );

    if (! $event->publish()) {
        $logger->info ("Failed to publish event: " . $event->get_last_error());
    }
}

#
# HTML-ify list of changes in this run if available + generate list of
# submitters' usernames
#
sub generateChangelist {
    my $self = shift;

    # Get details about the changes that happened since the last successful run
    my ($changesInfo, $submitters) = $self->_getHtmlListOfChangesInThisRun();

    # _getHtmlListOfChangesInThisRun() might return "" or " ", checking for both
    if ($changesInfo && $changesInfo ne " ") {
        $changesInfo = <<FIN;
<span style="font-family: sans-serif"><b>Changes:</b>
<br>
$changesInfo
</span>
<br>
FIN
    }

    return ($changesInfo, $submitters);
}

#
# Send E-Mail Notification
#
sub _notify_html {
    my $self = shift;
    my $status = shift;
    my $actions = shift;

    my $robotHost = $self->hostname() || "";

    my $robotKingURL = ariba::Automation::Constants->serverFrontdoor() .
        ariba::Automation::Constants->serverRobotKingUri() .
        ($robotHost ? "?robot=$robotHost" : "");
    my $robotKingURLlabel = $robotHost || "RobotKing";
    my $robotName = $self->name() || $self->instance();
    my $responsibleParty = $self->responsible() || "Ask_RC";
    my $lastActionName = $self->lastActionName() || "";
    my $productName  = $self->productName() || "n/a";
    my $lastStatusChangeTime = ariba::Ops::DateTime::prettyTime($self->statusChangeTime());
    my $emailTo = "";
    my $statusPhrase = $status eq $STATUS_FAILURE ? "FAILURE" : "SUCCESS";
    my $statusColor  = $status eq $STATUS_FAILURE ? "FF0000" : "33CC66";
    my $statusLabel = <<FIN;
<b><span style="color: #$statusColor">$statusPhrase</span></b>
FIN

    my $body = <<FIN;
<center>
<span style="font-family: sans-serif; font-size: 150%; color: #0069C6">
<b>$robotName</b> run ended with status: $statusLabel
</span>
<p>
<table style="font-family: sans-serif; border: 1px solid #666;" border=0 cellpadding=2 cellspacing=1>
<tr>
<td align=right valign=middle><b>Robot:</b></td>
<td align=left valign=middle><A href="$robotKingURL">$robotKingURLlabel</a></td>
</tr>
<tr>
<td align=right valign=middle><b>Product:</b></td>
<td align=left valign=middle>$productName</td>
</tr>
<tr>
<td align=right valign=middle><b>Last Action Ran:</b></td>
<td align=left valign=middle>$lastActionName</td>
</tr>
<tr>
<td align=right valign=middle><b>Last Status Change Time:</b></td>
<td align=left valign=middle>$lastStatusChangeTime</td>
</tr>
FIN

    my $actionOutput = "";

    # Get details about the changes that happened since the last successful run
    my ($changesInfo, $submitters) = $self->generateChangelist();

    $emailTo .= $submitters if ($submitters);

    ## loop over @$actions, looking and call attachment method for each one that has been executed
    ## and build an attach hash.
    $logger->debug("Checking to see if there are any attachments");
    my $attachmentNumber = 1;
    my @attachments;
    for my $action (@$actions) {
        my $attachment = $action->attachment();
        if ( $attachment && !$action->actionError() ) {
            my $attachHash = {
                'Type'     => 'text/html',
                'Path'     => $attachment,
                'Name'     => $action->instance() . '-' . basename($attachment),
            };
            # $body .= "Report from " . $action->instance() . " is attachment number $attachmentNumber\n";

            push @attachments, $attachHash;
            $attachmentNumber++;
        }

        my $actionInstance = $action->instance();
        # Temporary fix to modify the To List of the email
        my ($message,$toList) = $action->notifyMessage(1);
        if ( $message ) {
            $actionOutput .= <<FIN;
<table style="font-family: sans-serif; border: 1px solid #666;" border=0 cellpadding=2 cellspacing=1>
<tr>
<td align=left valign=top colspan=2 bgcolor="#efefef">
<b>$actionInstance:</b><br>
$message
</td>
</tr>
</table>
<br>
FIN
        }

        # Add the emails of the component owners to the 'To' list only
        # if this is not a sandbox robot
        $emailTo .= ",$toList" if ($toList && !ariba::Automation::Utils::isSandboxRobot($self));
    }

    # extra information in notification e-mails to show:
    # - number of consecutive failures
    # - when the build started failing
    # - at what changelist the build started failing
    if ($status eq $STATUS_FAILURE) {
        my $failCount = $self->failCount() || 0;
        if ($failCount) {
            my $failChangeList = $self->lastGoodChange() || 0;
            my $failDate = localtime ($self->failDate());
            my $failCount= $self->failCount();
            $body .= <<FIN;
<tr>
<td align=right valign=middle><b>Number of consecutive failures:</b></td>
<td align=left valign=middle>$failCount</td>
</tr>
<tr>
<td align=right valign=middle><b>Robot started failing on:</b></td>
<td align=left valign=middle>$failDate</td>
</tr>
FIN

        if ($failChangeList) {
            $body .= <<FIN;
<tr>
<td align=right valign=middle><b>Started failing at changelist:</b></td>
<td align=left valign=middle>$failChangeList</td>
</tr>
FIN
            }
        }
    }
    $body .= "</table></center><br>";

    if ($changesInfo) {
        $body .= $changesInfo;
    }

    if ($actionOutput) {
        $body .= $actionOutput;
    }

    if ($self->logFile()) {
        my $logFileLink = $self->logFileLink();
        my $tailLength = 20;
        my @logTail = $self->getLogTail($tailLength);
        my $logOutput = join "", @logTail;
        $body .= <<FIN;
<span style="font-family: sans-serif">
<b>Log File:</b> <a href="$logFileLink">$logFileLink</a>
</span>
<table width="100%" style="font-family: sans-serif" border=0 cellpadding=2 cellspacing=1>
<tr>
<td align=left valign=top bgcolor="#efefef"><tt><pre>$logOutput</pre></tt></td></tr>
</table>
<br>
FIN
    }

    my $to = $self->emailTo();
    my $noSpam = $self->noSpam() || 0;
    if ($emailTo) {
        if ($noSpam) {
            $logger->info ("noSpam enabled: Only e-mailing [$to]");
        } else {
            $to .= "," . $emailTo;
        }
    }

    my $release_captains = $self->_additional_recipients ($status);

    # respect noSpam flag _and_ don't send if this is a sandbox robot
    if ($release_captains &&
        ! $noSpam &&
        ! ariba::Automation::Utils::isSandboxRobot($self))
        {
            $to .= "," . $release_captains;
        }

    my $subject = $self->_makeSubjectLine ($status);

    #
    # Send e-mail
    #
    $body .= <<FIN;
<br>
<font size="-1" color="#909090">
This is an automated message from $robotName version $VERSION.<br>
Contact <a href="mailto:$responsibleParty">$responsibleParty</a> for any questions concerning this message.<br>
&copy; Ariba, Inc.
</font>
FIN

    $logger->info ("Sending e-mail to: $to");
    my $msg = MIME::Lite->new(
            'From'     => $self->emailFrom(),
            'To'       => $to,
            'Cc'       => $self->emailCc() || undef,
            'Reply-To' => $self->emailReplyTo() || undef,
            'Subject'  => $subject,
            'Type'     => 'text/html',
            'Data'     => $body,
            );

    for my $attachHash (@attachments) {
        my $attachment = $attachHash->{'Path'};
        $logger->info("Attaching '$attachment' to notification email");
        $msg->attach(
                'Type'  =>  $attachHash->{'Type'},
                'Path'  =>  $attachHash->{'Path'},
                'Name'  =>  $attachHash->{'Name'},
                )
    }

    eval { $msg->send() };
    if ($@) {
        $logger->error("Couldn't send HTML notification: " . $@);
    }
}

#
# private methods
#

sub _makeBriefSubjectLine {
    my ($self, $status) = @_;
    return $self->_makeSubjectLine ($status, 1);
}

sub _makeSubjectLine {
    my ($self, $status, $brief) = @_;

    $brief = $brief || 0;

    # name of robot defaults to robot13 if name isn't set in robot.conf
    my $robotName = $self->prettyPrintRobotName();

    # true if this is a qual robot
    my $isQualMachine = $self->isQualMachine() || 0;

    # fetch build name if available e.g. SSP10s2-420
    my $buildName = $self->buildnameFromLabel() || "";

    # brief subject line applies to RSS feed item titles
    if ($brief) {
        my $bn = "";

        # optional: don't include build name if it isn't available
        if ($buildName) {
            $bn = "[$buildName] ";
        }

        return "$bn$robotName run ended with $status";
    }

    my $robotType = "sandbox";
    if (!ariba::Automation::Utils::isSandboxRobot($self)) {
        $robotType = "mainline";
    }

    # qual machines should include build name in subject if available
    if ($isQualMachine) {
        if ($buildName) {
            return "[qual" .
                ($status eq $STATUS_FAILURE ? "/FAIL" : "") .
                "] $buildName: $robotName run ended with $status";
        }
    }

    return "[$robotType" .
        ($status eq $STATUS_FAILURE ? "/FAIL" : "") .
        "] Robot $robotName run ended with $status";
}

sub _getHtmlListOfChangesInThisRun {
    my $self = shift;

    # Get the list of changes between the last good run and this run
    my $lastGoodChangeForComparison = $self->lastGoodChange();

    if (! $lastGoodChangeForComparison) {
        return " ";
    }

    if ($self->lastGoodChange() == $self->currentChange()) {
        my @list = $self->lastGoodChangeList();
        pop(@list);
        $lastGoodChangeForComparison = pop(@list);
        return " " if (! $lastGoodChangeForComparison);
    }

    my ($buildAction) = grep { lc($_->type()) eq 'build' } $self->actionsOrder();
    if (!$buildAction) {
        # this robot does not have a build section, no point in going further
        return " ";
    }
    my $branch = $buildAction->branchName();

    return ariba::rc::ChangeReport::generateHtmlReport ($self->productName(), $branch, $lastGoodChangeForComparison, $self->currentChange());
}

sub _initFromConfigFile {
    my $self = shift;

    my $shouldInit = !$self->readOnly();

    my $configFile = $self->configFile();

    my %configHash = ();
    my %sectionsHash = ();
    my %globalItems = ();

    $self->setStatus($STATUS_NEW) unless $self->status();

    my $configReader = new ariba::Automation::ConfigReader;
    my $lines = $configReader->load ($configFile);

    if (! $lines) {
        $logger->error("Robot can't open config file $configFile: $!");
        if ($shouldInit) {
            $self->setStatus($STATUS_FAILURE);
            $self->setErrorType($CONFIG_ERROR);
        }
        die "Config error: can't open $configFile: $!";
    };

    foreach my $i (0 .. $#$lines) {
        my $line = $$lines[$i];
        if ($line =~ /^\s*\#/ || $line !~ /=/) {
            next;
        }

        my ($key, $value) = split(/\s*=\s*/, $line, 2);

        $key =~ s/^\s*//;   # remove leading whitespace from keys; trailing is done by split
        $value =~ s/\s*$//; # remove trailing whitespace from value; leading is done by split

        $configHash{$key} = $value;

        my ($section, $item) = split(/\./, $key, 2);
        push(@{$sectionsHash{$section}}, $item);
    }

    $self->setConfigHash(%configHash);

    # iterate over config hash, pulling out parts we care about
    #
    # e.g. create action objects
    #
    my $globalState = ariba::Automation::GlobalState->newFromName($self->instance());
    my $configHasErrors = 0;

    for my $section (keys %sectionsHash) {
        if ($section eq ariba::Automation::Constants::GLOBAL_SECTION()) {
            for my $item (@{$sectionsHash{$section}}) {
                my $value = $configHash{$section . '.' . $item};
                    # overwrite any explicitly set global variables from
                    # config
                    $globalState->setAttribute($item, $value) if ($shouldInit);
                    $globalItems{$item}=1;
                    $self->_addConfigOrigin ($item);
            }

        } elsif ($section eq ariba::Automation::Constants::IDENTITY_SECTION()) {
            for my $item (@{$sectionsHash{$section}}) {
                # just set attributes on self
                $self->setAttribute($item, $configHash{join('.', $section, $item)}) if ($shouldInit);
            }

        } elsif ($section eq ariba::Automation::Constants::ACTION_SECTION()) {
            # FIXME this should be factored out into a separate
            # package

            my %actionsByNameHash = ();
            my @actionsList = ();

            for my $actionString (@{$sectionsHash{$section}}) {
                my ($actionName, $key) = split(/\./, $actionString, 2);
                my $value = $configHash{$section . '.' . $actionString};

                # add to the action list, keeping it in order
                # that we saw the action
                unless (exists $actionsByNameHash{$actionName}) {
                    push(@actionsList, $actionName);
                }

                $actionsByNameHash{$actionName}->{$key} = $value;
            }

            # reset list of actions
            $self->setActionsOrder();

            # if action sequence is available, run actions in specified sequence
            # instead of the order they appear in robot.conf
            if ($self->actionSequence()) {
                my @actionSequence = split /,/, $self->actionSequence();
                if (@actionSequence) {
                    @actionsList = @actionSequence;
                    $logger->info ("Using action sequence: " . (join ",", @actionsList));
                }
            }

            for my $actionName (@actionsList) {

                $logger->debug("Creating $actionName with\n\t" . join("\n\t", map { "$_ => ".$actionsByNameHash{$actionName}->{$_} } keys %{$actionsByNameHash{$actionName}}));
                my $action;
                eval {
                    $action = ariba::Automation::Action->newForNameFromHash($actionName, $actionsByNameHash{$actionName}, $self->instance());
                };
                if ($@) {
                    $configHasErrors = 1;
                    $logger->error("FATAL: $@ in " . $self->instance());
                    $self->setErrorType($CONFIG_ERROR) if ($shouldInit);
                    $self->setStatus($STATUS_FAILURE) if ($shouldInit);
                } else {
                    $self->addAction($action);
                }
            }

        } else {
            $logger->error("FATAL: Unknown config section $section in robot " . $self->instance());
            $self->setStatus($STATUS_FAILURE) if ($shouldInit);
            $self->setErrorType($CONFIG_ERROR) if ($shouldInit);
            $configHasErrors = 1;
        }
    }

    if ($shouldInit) {
        my @origins = $self->configOrigin();
        if ($#origins != -1) {
            my $globalStateChanged = 0;
            foreach my $item (@origins) {
                if ($globalState->hasAttribute ($item) && ! exists $globalItems{$item}) {
                    $globalStateChanged = 1;
                    $globalState->deleteAttribute ($item);
                }
            }
            if ($globalStateChanged && ! $self->readOnly()) {
                $globalState->save();
            }
        }
    }

    if ($configHasErrors) {
        carp "Could not load robot from config";
        return;
    }

    return 1;
}

# add configuration item to list of items origininating from config file
sub _addConfigOrigin {
    my ($self, $item) = @_;
    my @origins = $self->configOrigin();
    my %originMap = map { $_ => 1 } @origins;
    return if exists $originMap{$item}; # don't add dupes

    if ($#origins == -1) {
            $self->setConfigOrigin ($item);
    } else {
            $self->appendToConfigOrigin ($item);
    }
}

sub lastAction {
    my $self = shift;

    my $actionString = $self->lastActionName() || $self->SUPER::lastAction();

    return unless $actionString;

    my @actionsOrder = $self->actionsOrder();
    my $action;
    for my $a (@actionsOrder) {
        if ($a->instance() eq $actionString) {
            $action = $a;
            last;
        }
    }

    return $action;
}

sub addAction {
    my $self = shift;
    my $action = shift;

    my $actionsOrder = $self->actionsOrder();

    if ($actionsOrder) {
        $self->appendToActionsOrder($action);
    } else {
        $self->setActionsOrder($action);
    }

    return 1;
}

sub lastGoodChangeTime {
    my $self = shift;

    my @lastGoodChangeTimeList = $self->lastGoodChangeTimeList();

    return pop(@lastGoodChangeTimeList);
}

sub lastGoodChange {
    my $self = shift;

    my @lastGoodChangeList = $self->lastGoodChangeList();

    return pop(@lastGoodChangeList);
}

sub name {
    my $self = shift;

    my $name = $self->SUPER::name();

    return $name || $self->instance();
}

#
# this overriden to keep statusChangeTime updated
#
sub setStatus {
    my $self = shift;
    my $status = shift;
    my $type = shift;

    my $globalState = ariba::Automation::GlobalState->newFromName($self->instance());

    my $previousStatus = $globalState->status() || $STATUS_NEW;
    $globalState->setAttribute("status", $status);
    $globalState->setAttribute("previousStatus", $previousStatus);
    $globalState->setAttribute("statusChangeTime", time());
    $globalState->save() unless $self->readOnly();
}

sub status {
    my $self = shift;

    return $self->SUPER::status() || $STATUS_NEW;
}

sub setState {
    my $self = shift;
    my $state = shift;

    $self->SUPER::setState($state);

    my $client = ariba::Automation::Remote::Client->newFromRobot($self);
    $client->postUpdate();
}

sub state {
    my $self = shift;

    # make this check valid even if the robot was killed, but only
    # do this if it's possible to know (if we are on the same host as
    # robot)
    my $robotHost = $self->hostname() || "";
    if ($robotHost eq ariba::Ops::NetworkUtils::hostname() && !$self->isRunning()) {
        return $STATE_STOPPED;
    }

    return $self->SUPER::state();
}

sub isRunning {
    my $self = shift;

    my $pid = $self->pid();

    return unless ($pid && kill(0, $pid));
}

sub hasRun {
    my $self = shift;

    return $self->pid();
}


# configFile() - default robot config location
sub configFile {
    my $self = shift;

    return $self->configFileForRobotName();
}

sub baseRobotConfigDir {
    my $class = shift;

    return ariba::Automation::Constants::baseRootDirectory()
        . "/" . ariba::Automation::Constants::configDirectory();
}

sub listRobots {
    my $class = shift;

    my $configDir = $class->baseRobotConfigDir();

    opendir(DIR,$configDir);
    my @dirs = grep { !/^[.]{1,2}/ } readdir(DIR);
    closedir(DIR);

    my @robots = ();

    foreach my $robotName (@dirs) {
        my $robot = $class->newFromNameNoInit($robotName);
        next unless $robot; # skip robots with damaged configuration files
        push(@robots, $robot);
    }

    return @robots;
}

sub configFileForRobotName {
    my $class = shift;
    my $name = shift;

    my $configFile = $class->baseRobotConfigDir();
    $configFile .= "/$name" if $name;

    # maintain backwards compatibility with old robots
    if (-e "$configFile/robot.conf.local") {
        $configFile .= "/robot.conf.local";
    } else {
        $configFile .= "/robot.conf";
    }
    return $configFile;
}

sub setupLogDirectory {
    my $self = shift;

    my $time = $self->lastRuntime() || time();
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)
                                        = localtime($time);

    my $logDir = sprintf "%04d%02d%02d-%02d%02d%02d", $year+1900, $mon+1, $mday, $hour, $min, $sec;
    $self->setLogDir($logDir);
    my $logDirFullPath = $self->logPath() . '/' . $logDir;
    unless (ariba::rc::Utils::mkdirRecursively($logDirFullPath)) {
        $logger->error("Failed to create dir $logDirFullPath:  $!");
        return;
    }

    unless (copy($self->configFile(), $logDirFullPath)) {
        $logger->error("Copying " . $self->configFile() . "to $logDirFullPath failed: $!");
        return;
    }

    $logger->info("Setting log directory to '$logDirFullPath', please check there for the individual run logs");
}

sub redirectOutputToFile {
    my $self = shift;
    my $runNumber = shift;

    $self->setLogFile("run_$runNumber.log");
    my $logFile = $self->logPath() . '/' . $self->logDir() . '/' . $self->logFile();

    close STDERR;
    close STDOUT;
    open (STDOUT, ">$logFile");
    open (STDERR, ">&STDOUT");
    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    #
    # Maintain links to 2 newest logfiles in ~/logs/latest.log
    # and ~/logs/previous.log (handy for debugging)
    #
    my $previousLogFile = join "/",
        $self->logPath(),
        ariba::Automation::Constants::previousLogfileLinkName();

    if (-e $previousLogFile) {
        if (! unlink $previousLogFile) {
            $logger->error ("redirectOutputToFile: Couldn't unlink $previousLogFile");
        }
    }

    my $latestLogFile = join "/",
        $self->logPath(),
        ariba::Automation::Constants::latestLogfileLinkName();

    # remove old link if any
    if (-e $latestLogFile) {
        if (! move ($latestLogFile, $previousLogFile)) {
            $logger->error ("redirectOutputToFile: Couldn't move $latestLogFile to $previousLogFile");
        }
    }

    # link logfile to latest.log
    if (! symlink ($logFile, $latestLogFile)) {
        $logger->error ("redirectOutputToFile: Couldn't make symlink from $logFile to $latestLogFile");
    }

    return 1;
}

sub setupTimingFile {
    my $self = shift;
    my $runNumber = shift;

    $self->setTimingFile("timing_$runNumber.log");
    my $timingFile = $self->logPath() . '/' . $self->logDir() . '/' . $self->timingFile();

    my $TIMINGFH;
    open ($TIMINGFH, ">$timingFile");
    $TIMINGFH->autoflush(1);

    printf $TIMINGFH "%30s | %-19s | %-19s | %-20s\n", "Action", "Start", "End", "Elapsed";

    return $TIMINGFH;
}

#
# PersistantObject methods
#

sub dir {
    my $class = shift;

    return undef;
}

#
# these are not saved to the global persisted object space
#
my $internalMethodsHashRef = {
        'actionSequence'      => 1,
        'actionsOrder'        => 1,
        'configHash'          => 1,
        'readOnly'            => 1,
        'lastUpdateCheck'     => 1,
        # 'sswsBuildName'       => 1,  # TODO: Is this necessary now that we have wsBuildnameFromCurrentRCBuildLabel ?
};

sub _isInternalAutoMethod {
    my $class = shift;
    my $methodName = shift;

    return exists($internalMethodsHashRef->{$methodName});
}

sub objectLoadMap {
    my $class = shift;

    my $mapRef = $class->SUPER::objectLoadMap();

    $mapRef->{'actionsOrder'} = '@ariba::Automation::Action';
    $mapRef->{'configHash'} = '@SCALAR';

    return $mapRef;
}

sub attribute {
    my $self = shift;
    my $attribute = shift;

    if ($self->_isInternalAutoMethod($attribute)) {
        return $self->SUPER::attribute($attribute);
    }

    my $globalState = ariba::Automation::GlobalState->newFromName($self->instance());
    return $globalState->attribute("$attribute");

}

sub setAttribute {
    my $self = shift;
    my $attribute = shift;
    my @value = @_;

    if ($self->_isInternalAutoMethod($attribute)) {
        return $self->SUPER::setAttribute($attribute, @value);
    }

    my $globalState = ariba::Automation::GlobalState->newFromName($self->instance());

    $globalState->setAttribute("$attribute", @_);
    $globalState->save() unless $self->readOnly();

}

sub logPath {
    my $class = shift;

    my $rootPath = ariba::Automation::Constants::baseRootDirectory();
    return $rootPath . "/" . ariba::Automation::Constants::logDirectory();
}

#
# Keep build history
#
sub updateBuildInfo {
    my ($self, $qualTestId, $lastGoodChangeNumber) = @_;

    # get runlog + build + qual info
    my $status = $self->buildResult() || "";
    my $productBuildName = $self->buildnameFromLabel() || $self->qualBuildName() || "";
    my $productName = $self->qualProductName() || "";
    my $buildNumber = $self->buildNumber() || 0;
    my $logPath = $self->logPath() || "";
    my $logDir = $self->logDir() || "";
    my $logFile = $self->logFile() || "";

    # something horrible happened
    if (! $buildNumber || ! $logDir || ! $logFile) {
        return;
    }

    # get range of CL#s
    my $changeStart = $lastGoodChangeNumber;
    my $changeEnd = $self->currentChange() || 0;
    my $qualTime = 0;

    # make sure xml results file exists
    if ($qualTestId) {
        # path to xml results
        my $xmlResults = "/home/" . $self->instance() .
            "/personal_" . $self->instance() .
            "/" . $productName . "/logs/" . $qualTestId .
            "/" . "runtests.output.all.xml";

        if (! -e $xmlResults) {
            $logger->info ("Qual status file not found: " . $xmlResults);
            $qualTestId = 0;
        } else {
            $qualTime = (stat($xmlResults))[9];
            $logger->info ("Qual status file: " . $xmlResults . " at " . localtime ($qualTime));
        }
    }

    my $logfile = join "/", $logPath, $logDir, $logFile;
    my $logFileDate = (stat($logfile))[9] || 0;
    if ($logFileDate) {
        $logger->info ("Robot logfile $logfile at " . localtime ($logFileDate));
    } else {
        $logger->info ("updateBuildInfo: Robot couldn't determine buildTime from $logFileDate");
    }

    # hand off to BuildInfo object
    my $buildInfo = new ariba::Automation::BuildInfo (
        'buildNumber' => $buildNumber,
        'logDir' => $logDir,
        'logFile' => $logFile,
        'changeStart' => $changeStart,
        'changeEnd' => $changeEnd,
        'qualTestId' => $qualTestId,
        'qualStatus' => $status,
        'productBuildName' => $productBuildName,
        'productName' => $productName,
        'buildTime' => $logFileDate,
        'qualTime' => $qualTime,
    );

    my $buildInfos = $self->_expireBuildInfo();
    $self->_addBuildInfo ($buildInfos, $buildInfo);
}

#
# Expire build history at $MAX_BUILDINFO_ENTRIES
#

sub _expireBuildInfo {
    my ($self) = @_;

    # get old build data
    my @buildInfoList = $self->buildInfo();

    # expire old data
    while (($#buildInfoList+1) >= $MAX_BUILDINFO_ENTRIES) {
        shift @buildInfoList;
    }

    return \@buildInfoList;
}

#
# Add to build history.
# Optional feature: Force a rebuild of buildInfo list by passing undef
# as first argument. Handy for debugging expiration.
#

sub _addBuildInfo {
    my ($self, $buildInfos, $buildInfo) = @_;

    $buildInfo = $buildInfo || 0;

    # add new data to end of list
    if ($buildInfo) {
        push @$buildInfos, $buildInfo->pack();
    }


    # update build history
    foreach my $i (0 .. $#$buildInfos) {
        if ($i == 0) {
            $self->setBuildInfo ($$buildInfos[$i]);
        } else {
            $self->appendToBuildInfo ($$buildInfos[$i]);
        }
    }
}

sub getVersionNumber {
    my ($self) = @_;
    return $VERSION;
}

sub getStoppedState {
    my ($self) = @_;
    return $STATE_STOPPED;
}

sub cleanUp {
    my ($self) = @_;

    # clean up build-now flag
    my $build_now_flag = ariba::Automation::Constants::buildNowFile();
    if (-e $build_now_flag) {
        unlink $build_now_flag;
    }
}

#
# If global.notifyOnShutdown=1 in robot.conf i.e. robot is expected
# to run 24/7/365, tell somebody.
#
sub sendNotificationOnShutdown {
    my ($self, $reason) = @_;

    if (! $reason) {
        my $shutdownReason = $self->shutdownReason() || "";
        if ($shutdownReason) {
            $reason = $self->shutdownReason();
        }
        elsif ($self->buildResult() eq $STATE_STOPPED) {
            $reason = "Stop was requested";
        }
    }
    $reason = $reason || "n/a";

    my $notifyOnShutdown = $self->notifyOnShutdown() || 0;
    return unless $notifyOnShutdown;

    my $instance = $self->instance();
    my $name = $self->prettyPrintRobotName();
    my $robotHost = $self->hostname() || "";

    my $robotKingURL = ariba::Automation::Constants->serverFrontdoor() .
        ariba::Automation::Constants->serverRobotKingUri() .
        ($robotHost ? "?robot=$robotHost" : "");

    my $logfileLink = $self->logFileLink();

    my $description = <<FIN;
Robot $instance stopped unexpectedly.
<p>
FIN

    if ($reason) {
        $description .= <<FIN;
Reason: $reason
FIN
    }

    $description .= <<FIN;
</p>
<a href="$robotKingURL">[RobotKing]</a> <a href="$logfileLink">[log]</a>
FIN

    my $event = new ariba::rc::events::client::Event
    (
        {
            channel_name => $self->name(),
            channel => "$notifyOnShutdown",
            title => "$name stopped running",
            description => $description,
        }
    );

    if (! $event->publish()) {
        $logger->info ("Failed to publish shutdown event: " . $event->get_last_error());
    }
}

#
# Generate a pleasant-looking robot name
#
sub prettyPrintRobotName {
    my ($self) = @_;
    my $instance = $self->instance();

    my $name = $self->name() || $instance;
    if ($name ne $instance) {
        $name .= " ($instance)";
    }
    return $name;
}

#
# Locate files in dir > n bytes
#
sub locateLargeLogfiles {
    my ($self) = @_;

    my @usual_suspects = (
        ariba::Automation::Constants::apacheLogDir(),
        ariba::Ops::Constants::archiveLogBaseDir(),
        "/tmp/" . ariba::rc::Globals::personalServicePrefix() . $self->instance() . "/" . $self->productName(),
    );

    my %large;
    my $coderef = sub {
        my $name = $File::Find::name;
        my $size = -s $name;
        if ($size > $LARGE_LOGFILE_THRESHOLD) {
            $large{$name} = $size;
        }
    };
    no warnings 'File::Find';
    find ($coderef, @usual_suspects);
    return %large;
}

sub largeLogfileReport {
    my ($self) = @_;
    my %logfiles = $self->locateLargeLogfiles();
    my $large_logfile_count = keys %logfiles;
    my $large_logfile_notice = "";
    if ($large_logfile_count) {
        $large_logfile_notice = <<FIN;
<p>The following large logfiles were discovered:<ul>
FIN
        my $size;
        foreach my $file (sort keys %logfiles) {
            $size = ariba::Automation::Utils::FileSize::prettyPrint ($logfiles{$file});
            $large_logfile_notice .= <<FIN;
<li> $file ($size)
FIN
        }
        $large_logfile_notice .= <<FIN;
</ul></p>
FIN
    }
    return $large_logfile_notice;
}

#
# Check for free disk space on interesting volumes.
# Send e-mail notification to Dept_Release when disk is full.
#
sub checkFreeDiskSpace {
    my ($self) = @_;

    my $now = time();
    my $when = $self->lastFreeDiskNotification() || 0;

    # make list of volumes to monitor
    my @volumes = @DISK_FULL_MONITOR_VOLUMES;
    push @volumes, "/home/$ENV{'USER'}" if exists $ENV{'USER'};
    my %volumeMap = map { $_ => 1 } @volumes;

    # keep hash of mountpoint to remaining space for problem volumes
    my %problems;

    # raw output of df command
    my $df;

    # execute df command across all mounted volumes
    my $command = $self->pathToDf() || "/bin/df";

    eval { $df = `$command -h`; };

    if ($@) {
        $logger->error("Free disk space check: Failure executing df command: " . $@);
        return;
    }

    # break df output into lines
    my @lines = split /\n/, $df;
    if ($#lines == -1) {
        $logger->warn("Free disk space check: No output from df command: " . $@);
        return;
    }

    my @df;

    # Parse output of /bin/df to extract free disk space
    #
    # Sample output:
    # /dev/sdc1             37152364   7663024  27602108  22% /robots
    foreach my $line (@lines) {
        push @df, $line;
        my (@chunks) = split /\s+/, $line;

        my $filesystem = $chunks[0];
        my $mount = $chunks[$#chunks];

        # skip remote disks: we assume I.T. is monitoring these
        next unless substr ($filesystem, 0, 4) eq "/dev";
        next unless substr ($filesystem, 0, 1) eq "/";

        my $capacity = $chunks[$#chunks-1];
        my $available = $chunks[$#chunks-2];

        # Find full disks
        if (exists $volumeMap{$mount} && $capacity eq "100%") {
            $problems{$mount} = $available;
        }
    }

    # Bail early if disks have enough free space
    my $problemCount = keys %problems;
    if (! $problemCount) {
        return;
    }

    # only send updates every x hours
    if ($when && ($now - $when < $DISK_FULL_NOTIFY_THRESHOLD)) {
        return;
    }

    my $large_logfile_notice = $self->largeLogfileReport();

    # Prepare an RC Event
    my $df_pretty = join "<br>", @df;
    my $fail = join ", ", keys %problems;
    my $plural = $problemCount == 1 ? "" : "s";
    my $subject = $self->prettyPrintRobotName() . " disk$plural full: $fail";
    my $body = <<FIN;
Robot $ENV{'USER'} out of disk space on $fail
<br><br>
Output of df command:
<br><br>
<tt><pre>$df_pretty</pre></tt>
$large_logfile_notice
FIN

    #
    # Send RC Event
    #
    my $instance = $self->instance();
    my $event = new ariba::rc::events::client::Event
    (
        {
            channel_name => $self->name(),
            channel => ariba::rc::events::Constants::channel_critical(),
            title => $subject,
            description => $body,
        }
    );

    if (! $event->publish()) {
        $logger->error ("Failed to publish event: " . $event->get_last_error());
    }

    # reset last send time
    $self->setLastFreeDiskNotification ($now);
}

#
# Fetch latest stable robot version number frmo mars
#
sub getStableRobotVersion {
    my ($self) = @_;
    my $url = ariba::Automation::Constants::stableRobotVersionUrl();
    my $version = get ($url);
    $version = $version || "";
    chomp $version;
    return $version;
}

#
# Notify user if newer robot release is available
#
sub checkForUpdates {
    my ($self) = @_;

    # robots can optionally ignore automatic bootstrap feature
    # (handy for testing)
    if ($self->skipAutomaticBootstrap()) {
        $logger->info ("Not checking for upgrades, skipAutomaticBootstrap is set");
        return;
    }
    my $now = time();

    # force update check on the first run
    my $lastUpdateCheck = $self->lastUpdateCheck() || ($now - $UPDATE_CHECK_THRESHOLD);
    return unless $now - $lastUpdateCheck >= $UPDATE_CHECK_THRESHOLD;

    $self->setLastUpdateCheck ($now);

    # bail early if version number hasn't changed
    my $version = $self->getStableRobotVersion() || "";
    return if ! $version || $VERSION >= $version;

    $logger->info ("Updates are available: Bootstrapping to $version");

    my $start_time = time();

    # -noexec won't open a shell when bootstrapping is finished
    system (ariba::Automation::Constants::bootstrapCommand() . " -noexec");

    my $elapsed = ariba::Automation::Utils::elapsedTime (time() - $start_time);

    my $robotHost = $self->hostname() || "";
    my $robotKingURL = ariba::Automation::Constants->serverFrontdoor() .
        ariba::Automation::Constants->serverRobotKingUri() .
        ($robotHost ? "?robot=$robotHost" : "");
    my $robotName = $self->instance();

    my $description = <<FIN;
Upgraded: <a href="$robotKingURL">$robotName</a><br>
Time to upgrade: $elapsed
FIN

    # send event: upgrade notice
    my $event = new ariba::rc::events::client::Event
    (
        {
            channel => "robot_bootstrap",
            title => $self->instance() . " bootstrapped from $VERSION to $version",
            description => $description,
        }
    );

    if (! $event->publish()) {
        $logger->info ("Failed to publish upgrade event: " . $event->get_last_error());
    }

    # restart robot
    $self->setShutdownReason ("Robot upgraded to $version");
    $logger->info ("Restarting");
    system ("/robots/machine-global-cache-for-personal-service/usr/local/services/tools/bin/robot-control -nap $RESTART_NAP_TIME start &");
    exit (0);
}

1;
