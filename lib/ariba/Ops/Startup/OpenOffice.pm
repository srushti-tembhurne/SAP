package ariba::Ops::Startup::OpenOffice;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/OpenOffice.pm#2 $

use strict;

use File::Path;
use File::Basename;
use ariba::Ops::Startup::Common;
use ariba::rc::Utils;

sub launch {
	my $me = shift;
	my $webInfSubDir = shift;
	my $apps = shift;
	my $role = shift;
	my $community = shift;
	my $masterPassword = shift;
	my $appArgs = shift || "";

	my $rotateInterval = 24*60*60; # 1 day
	my $cluster = $me->currentCluster();

	my @instances = $me->appInstancesOnHostLaunchedByRoleInClusterMatchingFilter(ariba::Ops::NetworkUtils::hostname(),$role,$cluster,$apps);

	my @launchedInstances;

	foreach my $instance (@instances) {
		my $instanceName = $instance->instance();
		my $port = $instance->port();

		my $krArgs = join( " ",
				"-kn $instanceName",
				"-ks $rotateInterval",
				"-ke $ENV{'NOTIFY'}"
		);

		my $openOffice = "/usr/bin/soffice";

		#
		# XXX - as a hack, we're using jarek's copy in dev for now
		#
		$openOffice = "/home/jarek/work/openoffice/opt/openoffice.org2.4/program/soffice.bin";
		my $com = "$main::INSTALLDIR/bin/keepRunning $krArgs -kp $openOffice \"-accept=socket,host=0,port=${port};urp;StarOffice.ComponentContext\" -nologo -headless -nofirststartwizard";

		ariba::Ops::Startup::Common::runKeepRunningCommand($com);

		push (@launchedInstances, $instance) ;
	}

	return @launchedInstances;

}

1;
