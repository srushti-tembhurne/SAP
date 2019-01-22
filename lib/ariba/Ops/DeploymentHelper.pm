#
# $Id: //ariba/services/tools/lib/perl/ariba/Ops/DeploymentHelper.pm#2 $
#
# A lib to manage commands launched by control-deployment, push-deployment, etc
#
#

package ariba::Ops::DeploymentHelper;

use strict;
use POSIX;
use ariba::Ops::SharedMemoryChild;
use ariba::rc::Utils;
use ariba::rc::Globals;
use ariba::Ops::NetworkUtils;


sub sshWhenNeeded {
	my $user = shift;
	my $dest = shift;
	my $service = shift;

	my $useSSH = 1;

	my $hostname = ariba::Ops::NetworkUtils::hostname();

	if ( $dest eq $hostname ) {
		$useSSH = 0;
	}

	if ( $dest =~ /^localhost/ ) {
		$useSSH = 0;
	}

	if ( $user ne $ENV{'USER'} ) {
		$useSSH = 1;
	}

	if ( $service && !ariba::rc::Globals::isPersonalService($service) ) {
		$useSSH = 1;
	}

	return $useSSH ? "ssh $user\@$dest"  : "";
}

sub shouldSkipHostForUserAndService {
	my $host = shift;
	my $user = shift;
	my $service = shift;

	#
	# I'd like to avoid testing $service like this here, but until
	# robots can handle multiple hosts this is how to prevent c-d
	# from trying other hosts while preserving the old behaviour for
	# non-personal-service
	return unless ariba::rc::Globals::isPersonalService($service);

	my $sshNeeded = sshWhenNeeded($user, $host);

	return 1 if ($sshNeeded);

	return 0;
}

1;
