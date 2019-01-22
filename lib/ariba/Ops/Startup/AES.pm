package ariba::Ops::Startup::AES;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/AES.pm#39 $

use strict;

use File::Path;
use File::Basename;
use ariba::rc::Utils;
use ariba::rc::Passwords;
use ariba::util::Encryption;
use ariba::Ops::NetworkUtils;
use ariba::Ops::Startup::Common;

use Digest::SHA1;

my %envSetupHash;
my $passwordChanged = 0;

sub launch {
	my $me = shift;
	my $role = shift;

	my $baseMajorRelease = $me->baseMajorReleaseName();

	launchAdminServer($me, $baseMajorRelease)        if $role eq 'sourcingadmin';
	launchSourcingServer($me, $baseMajorRelease)     if $role eq 'sourcing';

	return 1;
}

sub launchApp {
	my $me = shift;
	my $baseMajorRelease = shift();

	my $rotateInterval = 24 * 60 * 60; # 1 day

	#
	# To avoid launching the app with username/password on the command
	# line, we must feed password to the app's STDIN from keepRunning. (4.2)
	#
	my $systemPassword = $me->default('admin_password');

	my @nodeNames = ();

	my @instances = $me->appInstancesVisibleViaRoleInCluster('aes-webserver');

	if (@instances) {

		my $host = ariba::Ops::NetworkUtils::hostname();
		my $nodeNum = 0;

		for my $instance (@instances) {
			++$nodeNum;
			next unless $instance->host() eq $host;
			push (@nodeNames, { "Node$nodeNum" => $instance->instanceName() });
		}
	} else {
		push(@nodeNames, { "Node1" => "sourcing" });
	}

	for my $nameHash (@nodeNames) {

		my ($nodeName, $instanceName) = each %$nameHash;
		my $shellCommand = "$main::INSTALLDIR/base/bin/startsourcing -waitForAdminServer -noRestart -node $nodeName -adminPasswordViaStdin";

		my $cmd = join(' ', (
					"$main::INSTALLDIR/bin/keepRunning -d -kn \u$instanceName",
					"-ke $ENV{'NOTIFY'}",
					"-ks $rotateInterval",
					"-ki",
					"-ko",
					"-km -",
					"-kt",
					"-kp",
					"$shellCommand",
					));

		ariba::Ops::Startup::Common::launchCommandFeedResponses(
				$cmd, $systemPassword, $systemPassword
				);
	}
}

sub waitForConfigurationToFinish {
	my $me = shift;
	my $baseMajorRelease = shift();

	#
	# See if the config is ready for us to launch
	#
	my $markerFile = $me->default('WAIT_FOR_CONFIG_MARKER');

	my $count = 1;
	while ($markerFile && ! -e $markerFile) {
		sleep(5);
		$count++;

		if ($count >= 100) {
			die "ERROR: sourcing server waited too long for config to get created, quiting!\n";
		}
	}

	#
	# now wait for adminserver to come up. This script is available
	# only in releases >= 4.1.4
	#
	my $shellCommand = "$main::INSTALLDIR/base/bin/waitforadminserver";
	if (-e $shellCommand) {
		system($shellCommand);

		my $rebuildClassPath = 0;
		$shellCommand = "$main::INSTALLDIR/base/bin/";

		$rebuildClassPath = 1;
		$shellCommand .= "rebuildclasspath";

		if ($rebuildClassPath && -e $shellCommand) {
			system($shellCommand);
		}
	}
}

sub launchSourcingServer {
	my $me = shift;
	my $baseMajorRelease = shift();

	waitForConfigurationToFinish($me, $baseMajorRelease);

	launchApp($me, $baseMajorRelease);
}

sub launchAdminServer {
	my $me = shift;
	my $baseMajorRelease = shift();

	my $domainDir;
	my $shellCommand;
	my $rotateInterval = 24 * 60 * 60; # 1 day

		$domainDir = $me->default('domain_directory');
		$domainDir .= '/'. $me->default('domain');
		rmtree($domainDir);

		if ($me->appInstancesWithNameInCluster("Sourcing") > 1) {
			#
			# multi-node configuration
			# 
			$shellCommand = "$main::INSTALLDIR/base/bin/configuremultiserver -silent";
			ariba::rc::Utils::executeLocalCommand($shellCommand);
		} else {

			#
			# single-node configuration
			#
			$shellCommand = "$main::INSTALLDIR/base/bin/configureappserver -silent";
			ariba::rc::Utils::executeLocalCommand($shellCommand);
		}

		#
		# Run j2eesetup
		#
		$shellCommand = "$main::INSTALLDIR/base/bin/j2eesetup weblogic8 -configFile $main::INSTALLDIR/base/etc/install/install.sp -property ISUNIX=true -xmlFile=$main::INSTALLDIR/config/weblogic-ops.xml -xmlFile=$main::INSTALLDIR/base/etc/j2ee/sourcing/weblogic8-defaultconfig.xml -xmlFile=$main::INSTALLDIR/base/etc/j2ee/sourcing/weblogic8-deploy.xml -xmlFile=$main::INSTALLDIR/base/etc/j2ee/sourcing/weblogic8-appsettings.xml -stopAdminServer -adminPasswordViaStdin";

		my $adminPass = $me->default('admin_password');

		open(CMD, "|$shellCommand") || die "ERROR: Unable to launch [$shellCommand]\n";
		print CMD "$adminPass\n";
		close(CMD);

	#
	# we have a config drop the marker file now.
	#
	my $markerFile = $me->default('WAIT_FOR_CONFIG_MARKER');
	mkpath(dirname($markerFile));

	open(FL, ">$markerFile") || die "ERROR: could not create $markerFile, $!\n";
	print FL "config finished on ", scalar(localtime()), "\n";
	close(FL);

	#
	# start the standalone admin server now
	#
	chdir($domainDir);
	$shellCommand = "$domainDir/startWebLogic.sh";

	my ($adminInstance) = $me->appInstancesWithNameInCluster("SourcingAdmin");
	my $instanceName = $adminInstance ? $adminInstance->instanceName() : "AdminServer";

	my $cmd = join(' ', (
		"$main::INSTALLDIR/bin/keepRunning -d -kn $instanceName",
		"-ke $ENV{'NOTIFY'}",
		"-ks $rotateInterval",
		"-kp",
		"$shellCommand",
	));

	ariba::Ops::Startup::Common::runKeepRunningCommand($cmd);
}

sub makeAttachmentDir {
	my $me = shift;

	my $attachmentDir = $me->default('attachment_dir');

	unless (-d $attachmentDir) {
		mkpath($attachmentDir) or die "Can't create directory - error: $!";
	}
}

sub setupFontProperties {
	my $me = shift;

	my $productName = $me->name();
	my $installDir = $me->installDir();
	my $lib = "$installDir/lib";

	chomp(my $arch = lc(`uname -s`));

	#
	# Create font.properties file for use by mcharts in foreign
	# languages.
	#
	my $fontProperties = "font.properties";
	my $srcFontProps = "/usr/local/ariba/lib/jre/lib/$fontProperties.ariba.$arch.$productName";
	if ( -f $srcFontProps) {
		unlink("$lib/$fontProperties");
		symlink($srcFontProps, "$lib/$fontProperties") || print "ERROR: Could not create symlink to $srcFontProps from $lib\n";
	}

}

sub setRuntimeEnv {
	my $me = shift;
	my $role = shift;

	return if $envSetupHash{$role};

	setupFontProperties($me);

	#
	# base classes is where gsd and customer compiled extensions are
	# stored.
	#
	$ENV{'EXT_CLASSPATH'} = "$main::INSTALLDIR/base/extclasses";

	$envSetupHash{$role}++;
}

1;

__END__
