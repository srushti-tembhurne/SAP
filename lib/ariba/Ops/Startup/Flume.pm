package ariba::Ops::Startup::Flume;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/Flume.pm#6 $

use strict;

use File::Path;
use File::Basename;
use ariba::Ops::Startup::Common;
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

    $ENV{'JAVA_HOME'} = ariba::Ops::Startup::Common::javaHomeForProduct($me);
    $ENV{'FLUME_HOME'} = "$installDir/flume";
    $ENV{'FLUME_CONF_DIR'} = "$ENV{'FLUME_HOME'}/conf"; 
    $ENV{'TEMP'} = '/tmp';

    my @ldLibrary = (
        );

    my @pathComponents = (
        "$ENV{'FLUME_HOME'}/bin",
        "$ENV{'JAVA_HOME'}/bin",
        "$installDir/bin",
        );

    my @classes = (
        "$ENV{'FLUME_HOME'}",
        "$ENV{'FLUME_HOME'}/lib",
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

        my $prog = "$main::INSTALLDIR/flume/bin/flume";

        my $progToLaunch = join(' ',
            $prog,
            $progArgs,
            );

        my $com = "$main::INSTALLDIR/bin/keepRunning $krArgs -kp $progToLaunch";
        if ($main::debug) { 
            print "Will run: $com\n"; 
        } else {
            local $ENV{'JAVA_HOME'} = $me->javaHome($instance->appName());
            local $ENV{'UOPTS'} = $jvmArgs if ($jvmArgs);

            ariba::Ops::Startup::Common::runKeepRunningCommand($com);
        }
    }

    return @launchedInstances;
}

sub composeLaunchArguments {
    my($me, $instance) = @_;

    my $rotateInterval = 24 * 60 * 60; # 1 day

    my $instanceName = $instance->instance();
    my $service  = $me->service();

    my $krArgs = join(" ",
            "-d",
            "-kn $instanceName",
            "-ko",
            "-ks $rotateInterval",
            "-ke $ENV{'NOTIFY'}",
            "-kk",
            );

    if (!(ariba::Ops::ServiceController::isProductionServicesOnly($service))) {
        $krArgs .= " -kc 2";
    }

    my $serverRoles = $instance->serverRoles();
    my $progArgs = $serverRoles . '_nowatch';

    my $jvmArgs = ariba::Ops::Startup::Common::composeJvmArguments($me, $instance);

    return ($progArgs, $krArgs, $jvmArgs);
}

sub refreshConfigs {
    print "Refreshing Flume configurations\n";
    system('flume-config -refreshAll');
}


1;

__END__
