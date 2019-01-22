package ariba::Ops::Startup::LilyNode;

# $Id $

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
        $ENV{'LOGSDIR'} = ariba::Ops::Startup::Common::logsDirForProduct($me) unless ($ENV{'LOGSDIR'});

        $ENV{'JAVA_HOME'} = ariba::Ops::Startup::Common::javaHomeForProduct($me);
        $ENV{'LILY_LOG_DIR'} = "$ENV{'LOGSDIR'}/lily";
        $ENV{'TEMP'} = '/tmp';

        # we're not using cfengine
        $ENV{'LILY_HOME'} = "$installDir/lily";

        my @ldLibrary = (
        );

        my @pathComponents = (
                "$ENV{'LILY_HOME'}/bin",
                "$ENV{'JAVA_HOME'}/bin",
                "$installDir/bin",
        );

        my @classes = (
                "$ENV{'LILY_HOME'}",
                "$ENV{'LILY_HOME'}/lib/org/kauriproject/kauri-runtime-launcher/0.4-r1959/kauri-runtime-launcher-0.4-r1959.jar",
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


                my $additionalVmArgs =join(" ",
                                     );

                 my $extrajvmArgs = join(" ",
                ariba::Ops::Startup::Common::expandJvmArguments($me,$instanceName, $additionalVmArgs),
                "-Dkauri.launcher.repository=$ENV{'LILY_HOME'}/lib",
                "-Dlily.plugin.dir=$ENV{'LILY_HOME'}/plugins",
                "-Dlily.logdir=$main::INSTALLDIR/logs/lily",
                        );

                my $prog = join(" ",
                                $me->javaHome($instance->appName()) . "/bin/java",
                                $jvmArgs,
                                $extrajvmArgs,
                                "org.kauriproject.launcher.RuntimeCliLauncher",
                                "--repository $ENV{'LILY_HOME'}/lib",
                                "--confdir $main::INSTALLDIR/config/lily/conf",
                                "--log-configuration $main::INSTALLDIR/config/lily/lily-log4j.properties",
                                );




                my $progToLaunch = join(' ',
                        $prog,
                        $progArgs,
                        );

                my $com = "$main::INSTALLDIR/bin/keepRunning $krArgs -kp $progToLaunch";
                if ($main::debug) {
                        print "Will run: $com\n";
                } else {
                        local $ENV{'JAVA_HOME'} = $me->javaHome($instance->appName());
                        local $ENV{'JVMFLAGS'} = $jvmArgs;

                        print "$com\n";
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
        my $progArgs = '';

        my $jvmArgs = ariba::Ops::Startup::Common::composeJvmArguments($me, $instance);

        return ($progArgs, $krArgs, $jvmArgs);
}



1;

__END__
