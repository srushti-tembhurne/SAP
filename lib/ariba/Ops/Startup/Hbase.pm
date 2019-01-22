package ariba::Ops::Startup::Hbase;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/Hbase.pm#6 $

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

	$ENV{'JAVA_HOME'} = ariba::Ops::Startup::Common::javaHomeForProduct($me);
	$ENV{'HBASE_HOME'} = "$installDir/hbase";
	$ENV{'HBASE_OPTS'} = "-server";
	$ENV{'HBASE_CONF_DIR'} = "$ENV{'HBASE_HOME'}/conf"; 
	$ENV{'TEMP'} = '/tmp';

	my @ldLibrary = (
        );

	my @pathComponents = (
		"$ENV{'HBASE_HOME'}/bin",
		"$ENV{'JAVA_HOME'}/bin",
		"$installDir/bin",
        );

	my @classes = (
		"$ENV{'HBASE_HOME'}",
		"$ENV{'HBASE_HOME'}/lib",
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

		my ($progArgs, $krArgs, $jvmArgs, $heapSize) = composeLaunchArguments($me, $instance);

		my $prog = "$main::INSTALLDIR/hbase/bin/hbase";

		my $progToLaunch = join(' ',
			$prog,
			$progArgs,
			);

		my $com = "$main::INSTALLDIR/bin/keepRunning $krArgs -kp $progToLaunch";
		if ($main::debug) { 
			print "Will run: $com\n"; 
		} else {
			local $ENV{'JAVA_HOME'} = $me->javaHome($instance->appName());
			local $ENV{'HBASE_HEAPSIZE'} = $heapSize if ($heapSize);
			local $ENV{'HBASE_OPTS'} = $jvmArgs if ($jvmArgs);

			ariba::Ops::Startup::Common::runKeepRunningCommand($com);
		}
	}

	return @launchedInstances;
}

sub composeLaunchArguments {
	my($me, $instance) = @_;

	my $rotateInterval = 24 * 60 * 60; # 1 day

	my $instanceName = $instance->instance();
    my $prettyName = $instanceName;
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
	my $progArgs = "$serverRoles start";
	$progArgs .= ' -p ' . $instance->port() if ($serverRoles eq 'thrift');

	my ($jvmArgs, $maxHeapSize) = ariba::Ops::Startup::Common::composeJvmArguments($me, $instance);
    $jvmArgs = ariba::Ops::Startup::Common::expandJvmArguments($me, $prettyName, $jvmArgs);

	return ($progArgs, $krArgs, $jvmArgs, $maxHeapSize);
}


1;

__END__
