package ariba::Ops::Startup::PHP;

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


	my @fullframework  = ();
	my @pathComponents = ();

	# PHP will span this many processes to handle requests
	$ENV{'PHP_FCGI_CHILDREN'} = 4;
	# PHP will kill a process after handling this many requests (useful if memory leaks)
	$ENV{'PHP_FCGI_MAX_REQUESTS'} = 400;


	ariba::Ops::Startup::Common::setupEnvironment(\@fullframework, \@pathComponents, \@classes);

	$envSetup++;
}

sub launchApps 
{
	my ($me, $apps, $appArgs, $role, $community, $masterPassword) = @_;

	my $launched  = 0;
	my $cluster   = $me->currentCluster();
	my @instances = $me->appInstancesOnHostLaunchedByRoleInClusterMatchingFilter(ariba::Ops::NetworkUtils::hostname(),$role,$cluster,$apps);

	setRuntimeEnv($me);

	my @launchedInstances = ();
	for my $instance (@instances) {

		# include only PHP server apps
		next unless $instance->isPHPApp();

		my $prodname = uc($me->name());

		my $port = $instance->port();
		my $phpargs = "-b :$port";
		my $app = $instance->appName();

		my $instanceName = $instance->instance();

		# build keepRunning args
		my $krargs = "-kn $instanceName";
		$krargs .= " -ke \"$ENV{'NOTIFY'}\"";
		$krargs .= " -kg \"$ENV{'NOTIFYPAGERS'}\"";

		if (!(ariba::Ops::ServiceController::isProductionServicesOnly($me->service()))) {
			$krargs .= " -kc 2";
		}

		my $allArgs = "";
		my $exe = "php-cgi";
		my $exe_path = "$main::INSTALLDIR/bin/linux";

		my $progToLaunch = "$exe_path/$exe";

		my $com = "$main::INSTALLDIR/bin/keepRunning -d -kp $progToLaunch $phpargs $exe $krargs";

		#ariba::Ops::Startup::Common::runKeepRunningCommand($com, $masterPassword, '5.0');
		ariba::Ops::Startup::Common::runKeepRunningCommand($com);
		push(@launchedInstances, $instance);
	}

	return @launchedInstances;
}

1;

__END__
