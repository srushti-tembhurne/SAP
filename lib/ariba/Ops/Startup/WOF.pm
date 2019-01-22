package ariba::Ops::Startup::WOF;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/WOF.pm#28 $

use strict;

use ariba::Ops::Startup::Common;
use ariba::Ops::ServiceController;
use ariba::rc::Utils;
use Text::ParseWords;
use File::Path;

my $SUDO     = ariba::rc::Utils::sudoCmd();
my $envSetup = 0;

sub setRuntimeEnv
{
	my $me = shift;

	return if $envSetup;

	# add Ariba-built frameworks
	opendir(DIR,"$main::INSTALLDIR/WebObjects/Frameworks");
	my @frameworks = grep(/framework$/o,readdir(DIR));
	close(DIR);

	my (@fullframework, @pathComponents, @classes);

	chomp(my $arch = lc(`uname`));

	for my $framework (@frameworks){
		push(@fullframework,"$main::INSTALLDIR/WebObjects/Frameworks/$framework");
	}

	# add Foundation framework (which has a shared lib)
	push(@fullframework,"$ENV{'NEXT_ROOT'}/Library/Frameworks/Foundation.framework/Versions/Current");

	push(@fullframework, 
			 "$ENV{'ARIBA_DEPLOY_ROOT'}/WebObjects/Executables",
			 "$ENV{'NEXT_ROOT'}/Library/JDK/lib/sparc/native_threads",
			 "$ENV{'NEXT_ROOT'}/Library/Executables",
			 "$ENV{'ORACLE_HOME'}/lib"
	);
	
	push(@pathComponents,
		"$ENV{'ARIBA_DEPLOY_ROOT'}/bin/$arch",
		"$ENV{'ARIBA_DEPLOY_ROOT'}/bin",
		"$ENV{'NEXT_ROOT'}/Developer/Executables",
		"$ENV{'NEXT_ROOT'}/Developer/Executables/Utilities",
		"$ENV{'NEXT_ROOT'}/Local/Library/Executables",
		"$ENV{'NEXT_ROOT'}/Library/JDK/bin",
		"$ENV{'NEXT_ROOT'}/Library/Executables",
		"$ENV{'ARIBA_DEPLOY_ROOT'}/WebObjects/Executables",
		"$ENV{'ORACLE_HOME'}/bin",
		"."
	);

	push(@classes, "$main::INSTALLDIR/classes");

	$ENV{'JAVA_HOME'} = ariba::Ops::Startup::Common::javaHomeForProduct($me);

	ariba::Ops::Startup::Common::setupEnvironment(\@fullframework, \@pathComponents, \@classes);

	# Cleanup default NSProjectSerachPath from any build
	my $cleannsprojcmd = "defaults delete NSGlobalDomain";
	r("$cleannsprojcmd");
	$cleannsprojcmd = "defaults write NSGlobalDomain NSProjectSearchPath '()'";
	r("$cleannsprojcmd");

	# Certs need to be under current dir, when using entrust stuff!
	if (-d "$main::INSTALLDIR/lib" ) {
		chdir("$main::INSTALLDIR/lib") || die "can't chdir to $main::INSTALLDIR/lib";
	}

	$envSetup++;
}

sub launchApps 
{
	my($me, $apps, $appArgs, $role, $community, $masterPassword, $additionalAppArgsHashRef) = @_;

	my $cluster   = $me->currentCluster();
	my @instances = $me->appInstancesOnHostLaunchedByRoleInClusterMatchingFilter(ariba::Ops::NetworkUtils::hostname(),$role,$cluster,$apps);
	my $woVersion = $me->woVersion() || 4.0;

	ariba::Ops::Startup::Common::prepareHeapDumpDir($me);

	my @launchedInstances;

	for my $instance (@instances) {

		my $instanceName = $instance->instance();

		# skip java server apps
		next if $instance->isJavaApp();

		my $instanceCommunity = $instance->community();

		if ($instanceCommunity && $community && $instanceCommunity != $community) {
			next;
		}

		push(@launchedInstances, $instance);
		my %wofargs  = ();
		my $prodname = $ENV{'ARIBA_PRODUCT'} = $wofargs{'Product'} = uc($me->name());

		if (defined $instance->shortName()) {
			$wofargs{'DispatcherName'} = $instanceName;
		}
		if (defined $instance->monPort()) {
			$wofargs{'ListenerPort'} = $instance->monPort();
		} 
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

		if (defined $instance->attribute('communityClusterEnabled') &&
		    $instance->attribute('communityClusterEnabled') eq 'yes') {
		    $wofargs{'CommunityClusterEnabled'} = 'true';
		}

		my $app = $instance->appName();
		my $exe = $instance->exeName();

		$wofargs{'WOApplicationName'} = $exe;
		if (defined $instance->alias()) {
			$wofargs{'WOApplicationNameAlias'} = $instance->alias();
		}

		$wofargs{'WOPort'} = $instance->port();
		if (defined($me->default('woworkerthreadcount'))) {
		  $wofargs{'WOWorkerThreadCount'} = $me->default('woworkerthreadcount');
		}
		if (defined($me->default('woworkerthreadcountmax'))) {
		  $wofargs{'WOWorkerThreadCountMax'} = $me->default('woworkerthreadcountmax');
		}
		$wofargs{'WODebuggingEnabled'} = $me->default('wodebuggingenabled');
		$wofargs{'AWWebserverDocumentRootPath'} = "$ENV{'ARIBA_DEPLOY_ROOT'}/WebObjects";
		$wofargs{'InstanceID'} = $instance->instanceId();

		my $vmargs = $me->default('jvmargs') if $woVersion >= 5.0;

		my $extraArgs = $me->default('launchappargs');

		# allow super user access to apps via admin server
		# also override some URLs to point to admin web server
		if ($instance->launchedBy() eq "adminapps") {

			my %override = ariba::Ops::Startup::Apache::overrideAdminURLs($me);

			for my $arg (keys(%override)) {
				$wofargs{$arg} = $override{$arg};
			}

			$wofargs{'SuperUser'} = "yes";
		}

		# set application specific overrides for defaults.
		my $keyName = lc($app);

		my $nsMaxHeapsize = $me->default("$keyName.nsjavamaxheapsize");
		if ($nsMaxHeapsize) {
			$wofargs{'NSJavaMaxHeapSize'} = $nsMaxHeapsize;
		}

		my $timeout = $me->default("$keyName.wosessiontimeout");
		if ($timeout) {
			$wofargs{'WOSessionTimeOut'} = $timeout;
		}

		my $directConnect = $me->default("$keyName.wodirectconnectenabled");
		if ($directConnect) {
			$wofargs{'WODirectConnectEnabled'} = $directConnect;
		}
		my $awDirectConnect = $me->default("$keyName.awdirectconnectenabled");
		if ($awDirectConnect) {
			$wofargs{'AWDirectConnectEnabled'} = $awDirectConnect;
		}

		# Adding additional arguments
		if ($additionalAppArgsHashRef) {
			while ( my ($name, $value) = each(%$additionalAppArgsHashRef) ) {
				$wofargs{$name} = $value;
			}
		}


		my $aribaSecurityProperties = $me->default("Ops.AribaSecurityProperties");
		if ($aribaSecurityProperties) {
			$vmargs .= " -Djava.security.properties=file:${aribaSecurityProperties}";
		}


		if ($woVersion >= 5.0) {

			# Allow an app to completely override the jvm args
			my $overrideVMArgs = $me->default("$keyName.jvmargs");
			$vmargs = $overrideVMArgs if $overrideVMArgs;

			my $overrideExtraArgs = $me->default("$keyName.launchappargs");
			$extraArgs = $overrideExtraArgs if $overrideExtraArgs;

			# Allow an app to append to the jvm args
			my $appendVMArgs = $me->default("$keyName.jvmargsappend");

			if ($appendVMArgs) {
				if ($vmargs) {
					$vmargs .= " $appendVMArgs";
				} else {
					$vmargs = $appendVMArgs;
				}
			}

			my $appendExtraArgs = $me->default("$keyName.launchappargsappend");
			if ($appendExtraArgs) {
				if ($extraArgs) {
					$extraArgs .= " $appendExtraArgs";
				} else {
					$extraArgs = $appendExtraArgs;
				}
			}
		}

        my $prettyName = $instanceName;
        $prettyName .= "--" . $instance->logicalName() if $instance->logicalName();
		my $krargs = "-kn $prettyName";
		$krargs .= " -kh 1";
		$krargs .= " -ke \"$ENV{'NOTIFY'}\"";
		$krargs .= " -kg \"$ENV{'NOTIFYPAGERS'}\"";

		# Only for AN, not for EBS or any other WOF-based apps
		if($me->name() eq "an") {
			$krargs .= " -kb";
		}

		#
		# XXX -- WOF apps ignore Address in use errors
		# see TMID:44083
		#
		$krargs .= " -kr";

		#
		# rotate logs on a daily basis; this keeps perf/ebs logs
		# from being deleted by cleanup scripts
		my $rotateInterval = 24 * 60 * 60; # 1 day
		$krargs .= " -ks $rotateInterval";

		if (!(ariba::Ops::ServiceController::isProductionServicesOnly($me->service()))) {
			$krargs .= " -kc 2";
		}

		# in WO 5.0 args of format:
		#
		# -Darg=value instead of
		# -arg value
		my $progToLaunch;
		my $allArgs = $extraArgs;
		if ($woVersion < 5.0) {
			$progToLaunch = "$main::INSTALLDIR/WebObjects/Apps/${exe}.woa/${exe}";
		} else {
			$progToLaunch = "$main::INSTALLDIR/bin/launch-app -stop ${instanceName} -app ${exe}";
		}

		for my $arg (keys(%wofargs), @$appArgs) {
			if ($woVersion < 5.0) {
				$allArgs .= " -$arg $wofargs{$arg}";
			} else {
				$allArgs .= " -D$arg=$wofargs{$arg}";
			}
		}

		if ($woVersion >= 5.0) {
			if (defined $wofargs{'NSJavaMaxHeapSize'}) {
				print STDERR "Warning: NSJavaMaxHeapSize is set for WebObjects 5.0 or later; this parameter has no effect (try JVMArgs and JVMArgsAppend)\n";
			}

			#
			# Split up the JVMArgs from DD.xml into words.  Note that
			# the words will be subject to at least one more round of
			# word-splitting and expansion (by the shell that parses
			# this keepRunning command line), and possibly more
			# (depending, e.g., on whether launch-app uses the scalar
			# or array form of exec, etc.).  For this reason, using
			# shell metacharacters in the JVMArgs is not recommended.
			# This is the same situation as for %wofargs, etc.
			#

			# expand some run-time tokens
			
			$vmargs = ariba::Ops::Startup::Common::expandJvmArguments($me, $prettyName, $vmargs, $instanceCommunity);

			if (defined $vmargs) {
				foreach my $arg (shellwords($vmargs)) {
					$allArgs .= " -jvmArg ";
					$allArgs .= $arg;
				}
			}

			$allArgs .= " -jvm $ENV{'JAVA_HOME'}/bin/java";
		}

		my $com = "$main::INSTALLDIR/bin/keepRunning -d -kp $progToLaunch $allArgs $krargs";

		ariba::Ops::Startup::Common::runKeepRunningCommand($com, $masterPassword, $woVersion);
	}

	return @launchedInstances;
}

1;

__END__
