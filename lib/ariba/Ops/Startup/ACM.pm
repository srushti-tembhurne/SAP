package ariba::Ops::Startup::ACM;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/ACM.pm#6 $

use strict;

use File::Path;
use File::Basename;
use ariba::Ops::Startup::Common;
use ariba::Ops::Startup::Tomcat;
use ariba::rc::Utils;
use ariba::rc::Passwords;

my %envSetupHash;

sub launch {
	my $me = shift;
	my $apps = shift;
	my $role = shift;
	my $masterPassword = shift;

	#this product does not support master password encrypted strings yet
	$masterPassword = undef;


	# start xvfb server
	ariba::Ops::Startup::Common::startVirtualFrameBufferServer($me->default('Ops.XDisplay'));

	#
	# Call this to run initdb -loadmeta and initdb -reshapedb
	#
	initializeDatabase($me);

	ariba::Ops::Startup::Tomcat::aspLaunch($me, $me->name(), $apps, $role, undef, $masterPassword);

	return 1;
}

sub initializeDatabase {
	my $me = shift;

	my $baseInstallDir = $me->baseInstallDir();
	my $initDBScript = "$baseInstallDir/bin/initialize-database";

	#
	# initialize database and add sourcing source system if needed
	#
	if (-x $initDBScript) {
		open(INITDB, "|$initDBScript -d") || do {
				print "ERROR: $initDBScript, $!\n";
			};

		close(INITDB) || do {
				print "ERROR: $initDBScript failed.\n";
			};
	}
}

1;

__END__
