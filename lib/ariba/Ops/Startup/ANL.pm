package ariba::Ops::Startup::ANL;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/ANL.pm#31 $

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

	# setup configuration with integration with sourcing
	initializeDatabase($me);

	#
	# for -T instances, auto-set a lower niceness.
	# side-effect is that -T can never run as nice 0.
	#
	if ($me->customer() =~ /-T$/) {
		for my $instance ($me->appInstances()) {
			$instance->setNiceness(10) unless $instance->niceness();
		}
	}

	ariba::Ops::Startup::Tomcat::aspLaunch($me, "analysis", $apps, $role, undef, $masterPassword);

	# install startup hook for integrated deployment
	runStartupHookForIntegtration($me, 'install');

	return 1;
}

sub initializeDatabase {
	my $me = shift;

	my $baseInstallDir = $me->baseInstallDir();
	my $initDBScript = "$baseInstallDir/bin/initialize-database";

	my $masterPassword = ariba::rc::Passwords::lookup('master');

	#
	# initialize database and add sourcing source system if needed
	#
	if (-x $initDBScript) {
		open(INITDB, "|$initDBScript -d") || do {
				print "ERROR: $initDBScript, $!\n";
			};

		print INITDB "$masterPassword\n";

		close(INITDB) || do {
				print "ERROR: $initDBScript failed.\n";
			};

		#
		# XXXX: the steps above could have modified Parameters.table
		# refresh our copy of Parameters.table thats in memory. As
		# we might update the in memory copy and write it out later
		# (for ex. during launching of the server)
		#
		$me->reloadParametersTable();
	}
}

sub runStartupHookForIntegtration {
	my $me = shift;
	my $action = shift;

	#
	# If we are integrate with sourcing make sure we update the config
	# to create schema for data pulls from our integrated peers (e.g. AES or
	# AES/ACM).
	#
	if ($me->isInstanceSuiteDeployed()) {
		ariba::Ops::Startup::Common::runNamedStartupHookNoCheck($me, 'anl-aes-integrated', $action);
	}

	#
	# AN metrics integration is done via different cronjob. install that
	#
	if ($me->isTrue('Ops.IntegratedWithAN')) {
		ariba::Ops::Startup::Common::runNamedStartupHookNoCheck($me, 'anl-anmetrics', $action);
	}
}

sub createCustomerSpecificDirectories {
	my $me = shift;

	my $installDir = $me->installDir();
	my $baseInstallDir = $me->baseInstallDir();
	my $prodRoot  = dirname($installDir);

	#
	# customer can provide their data, which goes in data dir
	#
	my $customerDataDir = $me->default('Ops.DataFiles.Directory');

	if ($customerDataDir && ! -d $customerDataDir) {
		mkpath($customerDataDir) || die "ERROR: could not create $customerDataDir, $!\n";
	}

	#
	# customer can upload xls templates that goes in upload dir
	#
	my $customerUploadDir = $me->default('Ops.UploadFiles.Directory');

	if ($customerUploadDir && ! -d $customerUploadDir) {
		mkpath($customerUploadDir) || die "ERROR: could not create $customerUploadDir, $!\n";
	}

	#
	# an files are pulled and processed here
	#
	my $anUploadDir = $me->default('Ops.ANMetrics.ProcessingQueue.Directory');

	if ($anUploadDir && ! -d $anUploadDir) {
		mkpath($anUploadDir) || die "ERROR: could not create $anUploadDir, $!\n";
	}

	#
	# From Phobos onwards, there is just one toplevel dir and Analysis
	# manages all the data, it needs to, under that
	#
	my $customerSharedDir = $me->default('System.Analysis.InstanceFilesDirectory');

	if ($customerSharedDir && ! -d $customerSharedDir) {
		mkpath($customerSharedDir) || die "ERROR: could not create $customerSharedDir, $!\n";
	}

	#
	# No need for symlink to shared fs area. Pre Phobos, this path
	# used to be embedded in DataLoadEvents.table, and so there
	# was a need for 'service' independent path to this dir. This
	# can be taken out after all customers are on Phobos
	#
	for my $customerDir ($customerDataDir, $customerUploadDir) {
		next unless ($customerDir);

		my $createSymlink = "$prodRoot/" . basename($customerDir);

		#
		# in dev these would be in the same location, so no need
		# for a symlink
		#
		if ($createSymlink eq $customerDir) {
			print "warn: identical src and dest for symlink $createSymlink, skipped\n";
			next;
		}

		unlink($createSymlink) if (-e $createSymlink);
		symlink($customerDir, $createSymlink) || die "ERROR: could not create symlink, $createSymlink\n";
	}
	#
	# an directory needs to remain even post phobos
	#
	for my $dir ($anUploadDir) {
		next unless ($dir);
		next if ($dir =~ m|/$|);

		my $createSymlink = "$baseInstallDir/" . basename($dir);

		#
		# in dev these would be in the same location, so no need
		# for a symlink
		#
		if ($createSymlink eq $dir) {
			print "warn: identical src and dest for symlink $createSymlink, skipped\n";
			next;
		}

		unlink($createSymlink) if (-e $createSymlink);
		symlink($dir, $createSymlink) || die "ERROR: could not create symlink, $createSymlink\n";
	}
}

sub createDBExportDir {
	my $me = shift;

	#
	# we create db exports from monitor box as mon user, create
	# this directory so that mon user can write to it.
	#
	my $dbExportDir = $me->default('Ops.DBExportRootDirectory');
	if ($dbExportDir) {
		if (! -d $dbExportDir) {
			mkpath($dbExportDir) || die "ERROR: could not create $dbExportDir, $!\n";
		}
		my $chmod = ariba::rc::Utils::chmodCmd();
		r("$chmod 775 $dbExportDir");
	}
}

1;

__END__
