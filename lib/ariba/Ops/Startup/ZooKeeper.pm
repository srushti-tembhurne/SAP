package ariba::Ops::Startup::ZooKeeper;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/ZooKeeper.pm#8 $

use strict;

use File::Path;
use File::Basename;
use ariba::Ops::Startup::Common;
use ariba::Ops::Machine;
use ariba::Ops::ServiceController;
use ariba::rc::Utils;

my $envSetup = 0;

# Only do this once.
chomp(my $arch = lc(`uname -s`));
chomp(my $kernelName = `uname -s`);

sub setRuntimeEnv {
    my $me = shift;

    return if $envSetup;

    my $installDir = $me->installDir();
    $main::INSTALLDIR = $installDir;    # ariba::Ops::Startup::Common->setupEnvironment started to use this.

    $ENV{'LOGSDIR'} = ariba::Ops::Startup::Common::logsDirForProduct($me) unless ($ENV{'LOGSDIR'});

    $ENV{'JAVA_HOME'} = ariba::Ops::Startup::Common::javaHomeForProduct($me);
    $ENV{'JAVA'} = $ENV{'JAVA_HOME'} . "/bin/java";
    $ENV{'ZOOKEEPER_HOME'} = "$installDir/zookeeper";
    $ENV{'ZOO_LOG_DIR'} = "$ENV{'LOGSDIR'}/zookeeper";
    $ENV{'TEMP'} = '/tmp';


    my @ldLibrary = (
        );

    my @pathComponents = (
        "$ENV{'ZOOKEEPER_HOME'}/bin",
        "$ENV{'JAVA_HOME'}/bin",
        "$installDir/bin",
        );

    my @classes = (
        "$ENV{'ZOOKEEPER_HOME'}",
        "$ENV{'ZOOKEEPER_HOME'}/lib",
        );

    ariba::Ops::Startup::Common::setupEnvironment(\@ldLibrary, \@pathComponents, \@classes);

    $envSetup++;
}

sub launch {
    my $me = shift;
    my $apps = shift;
    my $role = shift;
    my $community = shift;

    return launchAppsForRole($me, $apps, $role, $community);
}

sub launchAppsForRole {
    my($me, $apps, $role, $community) = @_;

    my $cluster   = $me->currentCluster();

    my @instances = $me->appInstancesOnHostLaunchedByRoleInClusterMatchingFilter(
        ariba::Ops::NetworkUtils::hostname(), $role, $cluster, $apps);

    my @launchedInstances;
    for my $instance (@instances) {

        my $instanceName = $instance->instance();
        my $instanceCommunity = $instance->community();

        if ($instanceCommunity && $community && $instanceCommunity != $community) {
            next;
        }
        
        push (@launchedInstances, $instance) ;

        my ($progArgs, $krArgs, $jvmArgs) = composeLaunchArguments($me, $instance);

        my $prog = "$main::INSTALLDIR/zookeeper/bin/zookeeper";

        my $progToLaunch = join(' ',
            $prog,
            $progArgs,
            );
        setZooKeeperId($me);

        my $com = "$main::INSTALLDIR/bin/keepRunning $krArgs -kp $progToLaunch";
        if ($main::debug) { 
            print "Will run: $com\n"; 
        } else {
            local $ENV{'JAVA_HOME'} = $me->javaHome($instance->appName());
            local $ENV{'JVMFLAGS'} = $jvmArgs;

            ariba::Ops::Startup::Common::runKeepRunningCommand($com);
        }
    }

    return @launchedInstances;
}

sub composeLaunchArguments {
    my($me, $instance) = @_;

    my $rotateInterval = 24 * 60 * 60; # 1 day

    my $instanceName = $instance->instanceName();
    my $nodeName;
        if ($me->isLayout(5)) {
                $nodeName = $instance->logicalName();
        }
        else {
            $nodeName = $instance->workerName();
        }

    my $service  = $me->service();


    my $prettyName = $instanceName;
    $prettyName .= "--" . $instance->logicalName() if $instance->logicalName();
    my $krArgs = join(" ",
            "-d",
            "-kn $prettyName",
            "-ko",
            "-ks $rotateInterval",
            "-ke $ENV{'NOTIFY'}",
            "-kk",
            );

    if (!(ariba::Ops::ServiceController::isProductionServicesOnly($service))) {
        $krArgs .= " -kc 2";
    }

    my $serverRoles = $instance->serverRoles();
    my $progArgs = 'start';

    my $jvmArgs = ariba::Ops::Startup::Common::composeJvmArguments($me, $prettyName);

    return ($progArgs, $krArgs, $jvmArgs);
}

sub setZooKeeperId {
    my $me = shift;

    my $machine = ariba::Ops::Machine->new();
    my $ipAddr = $machine->ipAddr(); 

    if ($ipAddr && $ipAddr =~ /\.(\d+)$/) {
        my $id = $1;
        my $idFile = $me->default('ZooKeeper.DataDir') . '/myid';
        if (open(my $fh, ">$idFile")) {
            print $fh $id;
            close($fh) || do {
                print "Error: Failed to close file ($idFile): $!\n";
            };
        } else {
            print "Error: Failed to open file ($idFile) for writing: $!\n";
        }
    } else {
        print "Error: Invalid ipAddr set in machine db for ", $machine->hostname(), "\n";
    }
}


1;

__END__
