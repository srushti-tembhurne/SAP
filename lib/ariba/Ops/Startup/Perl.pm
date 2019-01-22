package ariba::Ops::Startup::Perl;

use strict;

use ariba::Ops::NetworkUtils;
use ariba::Ops::Startup::Common;
use ariba::Ops::ServiceController;

sub launchApps 
{
	my ($me, $apps, $appArgs, $role, $community, $masterPassword) = @_;

	my $launched  = 0;
	my $cluster   = $me->currentCluster();
	my @instances = $me->appInstancesOnHostLaunchedByRoleInClusterMatchingFilter(ariba::Ops::NetworkUtils::hostname(),$role,$cluster,$apps);

	my @launchedInstances = ();
	for my $instance (@instances) {

		# include only Perl server apps
		next unless $instance->isPerlApp();

		my $prodname = uc($me->name());

		my $port = $instance->port();
		my $app = $instance->appName();
		my $instanceName = $instance->instance();

		my $perlargs = "-port $port -name $instanceName -exe $app";

		# build keepRunning args
		my $krargs = "-kn $instanceName";
		$krargs .= " -ke \"$ENV{'NOTIFY'}\"";
		$krargs .= " -kg \"$ENV{'NOTIFYPAGERS'}\"";

		if (!(ariba::Ops::ServiceController::isProductionServicesOnly($me->service()))) {
			$krargs .= " -kc 2";
		}

		my $allArgs = "";
		my $exe = "perl-appinstance";
		my $exe_path = "$main::INSTALLDIR/bin/";

		my $progToLaunch = "$exe_path/$exe";

		my $com = "$main::INSTALLDIR/bin/keepRunning -d -kp $progToLaunch $perlargs $exe $krargs";

		ariba::Ops::Startup::Common::runKeepRunningCommand($com,$masterPassword);
		push(@launchedInstances, $instance);
	}

	return @launchedInstances;
}

1;

__END__
