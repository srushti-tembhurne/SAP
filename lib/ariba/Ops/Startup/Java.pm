package ariba::Ops::Startup::Java;

use strict;

use ariba::Ops::NetworkUtils;
use ariba::Ops::ServiceController;
use ariba::Ops::Startup::Common;

my $envSetup = 0;

sub setRuntimeEnv
{
	my $me = shift;
	my @classes = @_;

	return if $envSetup;

	if (scalar @classes == 0) {
		@classes = ("$main::INSTALLDIR/classes", "$main::INSTALLDIR/JavaApps");
	}

	my @fullframework  = ();
	my @pathComponents = ();

	$ENV{'JAVA_HOME'} = ariba::Ops::Startup::Common::javaHomeForProduct($me);

	ariba::Ops::Startup::Common::setupEnvironment(\@fullframework, \@pathComponents, \@classes);

	$envSetup++;
}

sub launchApps 
{
	my ($me, $apps, $appArgs, $role, $community, $masterPassword) = @_;

	my $launched  = 0;
	my $cluster   = $me->currentCluster();
	my @instances = $me->appInstancesOnHostLaunchedByRoleInClusterMatchingFilter(ariba::Ops::NetworkUtils::hostname(),$role,$cluster,$apps);

	for my $instance (@instances) {

		# include only java server apps
		next unless $instance->isJavaApp();

		my $instanceCommunity = $instance->community();

		if ($instanceCommunity && $community && $instanceCommunity != $community) {
			next;
		}

		my %wofargs  = ();

		my $prodname = uc($me->name());

		my $app = $instance->appName();
		my $exe = $instance->javaLaunchPath();

		$wofargs{'Product'} 	     = $ENV{'ARIBA_PRODUCT'} = $prodname;
		$wofargs{'ApplicationName'}  = $app;
		$wofargs{'InstanceID'}       = $instance->instanceId();
		$wofargs{'DebuggingEnabled'} = 'NO';
		$wofargs{'readMasterPassword'} = 'YES';

		if (defined $instance->killPort()) {
			$wofargs{'KillPort'} = $instance->killPort();
		} 

		if (defined $instance->securePort()) {
			$wofargs{'SecureListenerPort'} = $instance->securePort();
		} 

		if (defined $instance->transportPort()) {
		  $wofargs{'TransportListenerPort'} = $instance->transportPort();
		}

		if (defined $instanceCommunity) {
			$wofargs{'Community'} = $instanceCommunity;
		} 

		my $instanceName = $instance->instance();

		# build keepRunning args
		my $krargs = "-kn $instanceName";
		$krargs .= " -ke \"$ENV{'NOTIFY'}\"";
		$krargs .= " -kg \"$ENV{'NOTIFYPAGERS'}\"";

		if (!(ariba::Ops::ServiceController::isProductionServicesOnly($me->service()))) {
			$krargs .= " -kc 2";
		}

		my $allArgs = "";
		my $progToLaunch = "$ENV{'JAVA_HOME'}/bin/java -classpath $ENV{'CLASSPATH'}";

		for my $arg (keys(%wofargs), @$appArgs) {
			$allArgs .= " -D$arg=$wofargs{$arg}";
		}

		my $com = "$main::INSTALLDIR/bin/keepRunning -d -kp $progToLaunch $allArgs $exe $krargs";

		ariba::Ops::Startup::Common::runKeepRunningCommand($com, $masterPassword, '5.0');
		$launched = 1;
	}

	return $launched;
}

1;

__END__
