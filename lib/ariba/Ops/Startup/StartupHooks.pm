package ariba::Ops::Startup::StartupHooks;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/StartupHooks.pm#1

# This library should be used to house cron jobs that are common to multiple startup hooks

use strict;
use ariba::Ops::Constants;
use ariba::Ops::ServiceController;

sub manageLogDirs {
    my $crontab = shift;
    my $productName = shift;
    my $service = shift;
    my $sqlLogsDir = shift;

    if (!defined $ENV{'ARIBA_DEPLOY_ROOT'}) {
        die "ERROR: \$ARIBA_DEPLOY_ROOT must be set\n";
    }
    if (!defined $ENV{'LOGSDIR'}) {
        die "ERROR: \$LOGSDIR must be set\n";
    }

    my $clean = "$ENV{'ARIBA_DEPLOY_ROOT'}/bin/clean-old-files-from-dir";
    my $logDir = $ENV{'LOGSDIR'};
    my $archivedLogDir = ariba::Ops::Constants::archiveLogDir($service, $productName);

    return unless -x $clean;

    my $daysToKeep;
    if ( $productName =~ /hadoop/ && !ariba::Ops::ServiceController->isProductionServices($service) ) {
        if ( $service eq 'dev' ) {
            $daysToKeep = 21;
        } else {
            $daysToKeep = 7;
        }
    } else {
        $daysToKeep = ariba::Ops::Constants->archiveLogKeepDays($service);
    }
   
    # clean up corefiles once a week
    # Delete anything older than 7 days.
    $crontab->addEntryToCron(
                    "cores-cleanup",
                    "$clean -d 7 $ENV{'HOME'}/cores",
                    "Clean up $ENV{'HOME'}/cores",
                    "0 2 * * *");

    # Tag KeepRunning Logs in the products /tmp/<service>/<product> dir
    # This will add a '-ARCHIVE' suffix to logs older than 1 day.
    # This does not delete any logs.
    $crontab->addEntryToCron(
        "tag-keepRunning-logs-$productName",
        "$clean -d 1 -t '$logDir/keepRunning*\.\\d+' '$logDir/keepRunning*DEAD' '$logDir/keepRunning*EXIT'",
        "Tag Logs in $logDir",
        "0 0 * * *");
 
    # This archives tagged keepRunning logs from /tmp/<service>/<product> to /var/tmp/applogs/<service>/<product>
    # This archives logs older than 3 days in /tmp/<service>/<product>.
    # This does not delete any logs.
    $crontab->addEntryToCron(
        "archive-keepRunning-logs-$productName",
        "$clean -z -a $archivedLogDir -at $logDir",
        "Archive tagged logs from $logDir to $archivedLogDir",
        "0 1 * * *");

    # Prune the $archiveLogsDir
    $crontab->addEntryToCron(
        "archived-log-cleanup-$productName",
        "$clean -d $daysToKeep $archivedLogDir",
        "Clean up $archivedLogDir",
        "30 1 * * *");
 
    # All tagged logs should always be archived.  Anything not "*.pid" more than 7
    # days old in the $logDir is cruft and should be deleted.
    $crontab->addEntryToCron(
        "log-cleanup-$productName",
        "$clean -d 7 -x 'keepRunning.*pid' $logDir",
        "Clean up $logDir",
        "30 1 * * *");

    # clean up sql collector logs every 12 hours
    # Not sure what this is for.  This was copied here from the 'presentation' startup hook
    if ( $sqlLogsDir ) {
        $crontab->addEntryToCron(
            "SQL-collector-log-$productName",
            "$clean -d 0.5 '$sqlLogsDir/SQLCollectorLog.1*'",
            "Clean up $sqlLogsDir",
            "0,30 * * * *");
    }
}

1;

__END__

