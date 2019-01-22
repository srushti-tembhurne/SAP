package ariba::monitor::MachineHelper;

# $Id: //ariba/services/monitor/lib/ariba/monitor/MachineHelper.pm#15 $
#
# This package contains common code between dns-watcher and machine-watcher.
# Implementing hysteresis checking, and batch notification.

use strict;
use ariba::monitor::Query;
use ariba::Ops::NotificationRequest;
use ariba::Ops::ServiceController;

my $debug = 0;

sub debug {
    return $debug;
}

sub setDebug {
    $debug = shift;
}

sub computeStatusChange {
    my $machine    = shift;
    my $hysteresis = shift;

    my $host       = $machine->hostname();

    my $query      = $ariba::monitor::Query::_ourGlobalQuerySelf;
    my $newStatus  = $query->results();
    my $oldStatus  = $query->previousResults()  || $newStatus;
    my $oldTime    = $query->statusChangeTime();
    my $time       = $query->checkTime();

    # 4 possible old status
    #   1. unknown
    #   2. sick
    #   3. down
    #   4. up
    # 2 new statuses
    #   a. down <now>
    #   b. <uptime>
    #
    # Actions for following transitions:
    #
    # 1->a:mark sick, note time, no notification
    # 2->a:check hystersis, notify if expired, maintain old time
    #      otherwise
    # 3->a:maintain old time, no notification
    # 4->a:mark sick, note time, no notification
    #
    # 1->b:newly up, note time, no notification
    # 2->b:mark new time, no notification
    # 3->b:notify host up, note uptime
    # 4->b:update uptime, no notification
    #
    # Update: Whenever we have a status change to 'up' and the machine
    # reports a shorter uptime than previously reported, we page.

    if ($newStatus && $newStatus eq "down") {

        # the machine is down, was unknown before
        if (!$oldStatus || $oldStatus eq "up") {

            $newStatus = "sick";
            print "  $host is newly $newStatus.\n" if $debug;
            $machine->setNewStatus($newStatus);
        }
        
        # was either, sick or down or up before
        if ($oldStatus eq "sick") {

            my $oldDownTime = $oldTime;
            my $newDownTime = $machine->newTime()  || $time;
            my $newError    = $machine->newError();

            # check hysteresis, notify if has been, sick for a while
            $machine->setNewTime($oldDownTime);

            if ($newDownTime - $oldDownTime >= $hysteresis) {

                print "  $host is now down from sick\n" if $debug;
                $machine->setNotifyStatus($newStatus);
                $machine->setNotifyTime($oldDownTime);
                $machine->setNotifyError($newError);

            } else {

                print "  $host is still $newStatus.\n" if $debug;
                $machine->setNewStatus($oldStatus);
            }

        } elsif ($oldStatus eq "down") {

            print "  $host is still $newStatus.\n" if $debug;
            $machine->setNewStatus($oldStatus);
            $machine->setNewTime($oldTime);
        } 

    } else {

        # the machine is up, was down before. notify!
        if ($oldStatus && $oldStatus eq "down") {
            print "  $host is newly $newStatus.\n" if $debug;
            $machine->setNotifyStatus($newStatus);
            $machine->setNotifyTime($time - $machine->newTime());
            $machine->setNotifyError($machine->newError());
        }
    }

    # Check for reboots, in case it happened faster than a monitoring
    # cycle period.
    #
    # Only do this if the machine is up
    #
    if ($newStatus eq 'up') {

        # if $query->machineUpTime is not defined this is the first time this
        # query is run.  In that case just skip the "did the machine reboot
        # within 2 monitoring runs" check.
        #
        if (defined($query->machineUpTime())) {
            # check for fast reboots unless we already know that the machine was
            # down (in which case we have already been notified)
            if ( $oldStatus ne 'down' && $machine->newTime() < $query->machineUpTime()) {

                ## Check for roll-over of uptime counter
                #
                # Because units for uptime from SNMP are hundredths of a
                # second this counter can roll over after approx. 497 days,
                # add the time since last check to the prevous machine uptime
                # and see if that would cause the counter to roll over.


                # since both hrSystemUptime and sysUpTime are in hundredths of
                # a second, this is the roll-over time in seconds
                my $MAX_UPTIME_VALUE = 42949672.95; 

                # for cyclades and local directors, sysUpTime is in milliseonds
                if ($machine->os eq 'ldir' || 
                    $machine->os eq 'cyclades' ||
                    $machine->os eq 'servertech') {

                    $MAX_UPTIME_VALUE = 4294967.295;
                }

                my $timeSinceLastCheck = $query->checkTime() - $query->previousCheckTime();

                #     previous machine uptime + time since that sample
                unless ( ($query->machineUpTime() + $timeSinceLastCheck) > $MAX_UPTIME_VALUE) {
                    $machine->setNotifyStatus($newStatus);
                    $machine->setNotifyTime($time - $machine->newTime());
                    $machine->setNotifyError("Reboot detected: old uptime was ". 
                            ariba::Ops::DateTime::scaleTime($query->machineUpTime()) .
                            ", new uptime is ". 
                            ariba::Ops::DateTime::scaleTime($machine->newTime()));
                    # bit of a hack: we set the status change time here because
                    # QueryManager::checkStatus will not recognize that there has been
                    # a status change (since status has been 'up'
                    $query->setStatusChangeTime($query->checkTime());
                }
            }
        }

        $query->setMachineUpTime($machine->newTime());
    }

    # Allow this to propagate
    $query->setError( $machine->newError() || undef );

    my $return = $machine->newStatus();

    if ($machine->status() && $machine->status() eq "spare") {
        my $hwType = $machine->hardwareType();
        $return = "[$hwType] $return";
    }

    return $return;
}

sub notifyPeople {
    my ($me, $sendingProgram, $pager, $sendPage, $machines) = @_;

    my (@down, @up);
    my $downHost = "";
    my $upHost = "";

    for my $machine (@$machines) {

        my $host         = $machine->hostname();
        my $notifyStatus = $machine->notifyStatus();
        my $notifyError  = $machine->notifyError() || '';
        my $datacenter   = $machine->datacenter()  || '';

        next unless $notifyStatus;

        my $notifyTime = localtime($machine->notifyTime() || time());

        if ($notifyStatus eq "down") {
            push(@down,"$host $datacenter $notifyStatus $notifyTime $notifyError\n");
            $downHost = $host;
        }

        if ($notifyStatus eq "up") {
            push(@up,"$host $datacenter $notifyStatus $notifyTime $notifyError\n");
            $upHost = $host;
        }
    }

    if ($debug) {
        print "recent downs:\n  ", join("  ", @down), "\n" if @down;
        print "recent ups:\n  ",   join("  ", @up), "\n"   if @up;
        return;
    }

    if (@down) {
        if(scalar(@down) == 1) {
            sendNotificationRequest($me, $sendingProgram, $pager, "$downHost down", @down) if $sendPage;
        } else {
            sendNotificationRequest($me, $sendingProgram, $pager, scalar(@down) . " servers down", @down) if $sendPage;
        }
    }

    if (@up) {
        if(scalar(@up) == 1) {
            sendNotificationRequest($me, $sendingProgram, $pager, "$upHost up", @up) if $sendPage;
        } else {
            sendNotificationRequest($me, $sendingProgram, $pager, scalar(@up) . " servers up", @up) if $sendPage;
        }
    }
}

sub sendNotificationRequest {
    my ($me, $sendingProgram, $to, $subject, @text) = @_;

    my $body = join("", @text);

    my $notificationRequest = ariba::Ops::NotificationRequest->newCrit(
        $sendingProgram, $me->name(), $me->service(), undef, $me->currentCluster(), $subject, $body, $to,
    );

    $notificationRequest->setDebug($debug);
    $notificationRequest->send();
}

1;
