package ariba::Ops::Startup::SeleniumServer;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/SeleniumServer.pm#2 $

use strict;

use ariba::Ops::NetworkUtils;

use File::Path;
use File::Basename;
use ariba::rc::Utils;

my $envSetup = 0;

chomp(my $kernelName = `uname -s`);

sub setRuntimeEnv {
	my $me = shift;

	return if $envSetup;

	$ENV{'JAVA_HOME'} = ariba::Ops::Startup::Common::javaHomeForProduct($me);
	
	my @ldLibrary = (
			"$main::INSTALLDIR/lib/$kernelName",
			"$main::INSTALLDIR/internal/lib/$kernelName",
	);

	my @pathComponents = (
			"$ENV{'JAVA_HOME'}/bin",
			"$main::INSTALLDIR/bin",
			"$main::INSTALLDIR/internal/bin",
	);

	my @classes = (
			"$main::INSTALLDIR/internal/classes",
	);

	ariba::Ops::Startup::Common::setupEnvironment(\@ldLibrary, \@pathComponents, \@classes);

	chdir("$main::INSTALLDIR") || die "ERROR: could not chdir to $main::INSTALLDIR, $!\n";
	

	#Selenium Specific 
	$ENV{'ARIBA_INSTALL_ROOT'} = $main::INSTALLDIR;
	#FIXME there may eventually be more than one selenium rc server (e.g. ie, firefox)
	# so we may have more roles here, e.g. seleniumrc-firefox, etc.
	
	# 
	#  if on seleniumrc server, choose correct host
	#
	my @seleniumRcHostList = $me->hostsForRoleInCluster('seleniumrc');
	my $host = ariba::Ops::NetworkUtils::hostname();
	my ($seleniumHost) = grep(/^$host$/, @seleniumRcHostList);

	# 
	# if this is an app server, just pick the first seleniumrc host
	# to use; this is only used by manual testrunner on this node,
	# all automated qual tests go through TestServer which does the
	# seleniumrc multiplexing
	$seleniumHost = shift(@seleniumRcHostList) unless $seleniumHost;

	$ENV{'ARIBA_SELENIUM_RC_HOST'} = $seleniumHost;
	$ENV{'ARIBA_SELENIUM_RC_PORT'} = $me->default('Ops.SeleniumRc.Port') || 4444;

	# this needs to be set for now for seleniumrc to find the right (only?) firefox; having
	# the /usr/bin/firefox script in PATH doesn't seem to work
	my $additionalParameters = $me->default('Ops.SeleniumRc.AdditionalParameters') ||
		"-multiWindow -forcedBrowserMode \"*chrome /opt/firefox3/firefox-bin\"";
	$additionalParameters =~ s/'/"/g;
	$ENV{'ARIBA_SELENIUM_RC_ADDITIONAL_PARAMETERS'} = $additionalParameters;

	my $perlCmd = $^X or die ("Cannot find perl in PATH");
	$ENV{'ARIBA_PERL_COMMAND'} = $perlCmd;

	$envSetup++;
}

sub composeSeleniumArgs {
	my $me = shift;
	my $parameterPrefix = shift || "";
	my $seleniumAppParamsHashRef = shift || {};

	my $role = 'seleniumrc';
	my $cluster = $me->currentCluster();
	my @instances = $me->appInstancesLaunchedByRoleInCluster($role,$cluster);

	my $hostCount = 0;

	if ($parameterPrefix ne "" && $parameterPrefix !~ m/^.*\.$/) {
		$parameterPrefix .= ".";
	}

	if (@instances) {
		for my $instance (@instances) {
			++$hostCount;
			my $name = "Selenium$hostCount";
			$seleniumAppParamsHashRef->{"$parameterPrefix$name.Host"} = $instance->host();
			$seleniumAppParamsHashRef->{"$parameterPrefix$name.Port"} = $instance->port();
		}
	} else { # old way of calculating seleniumArgs
		my $port = $me->default('Ops.SeleniumRc.Port') || 4444;
		my @names = ();
		my $hostCount = 0;
		my @seleniumRcHosts = $me->hostsForRoleInCluster($role);

		for my $host (@seleniumRcHosts) {
			++$hostCount;
			my $name = "Selenium$hostCount";
			$seleniumAppParamsHashRef->{"$parameterPrefix$name.Host"} = $host;
			$seleniumAppParamsHashRef->{"$parameterPrefix$name.Host"} = $port;
		}
	}
	return $seleniumAppParamsHashRef;
}

sub stopSeleniumRCInstances {
	my $instancesRef = shift;
	my $me = shift;

	my $installDir = $me->installDir();

	my $seleniumStopCmd = "$installDir/internal/bin/stopSeleniumRc";

	unless (defined($instancesRef) && @$instancesRef) {
		# missing appInstances means old way of stopping selenium,
		# one per host; env should already be set for this from
		# stopsvc
		return r($seleniumStopCmd);
	}

	$ENV{'ARIBA_INSTALL_ROOT'} = $installDir;

	for my $instance (@$instancesRef) {
		my $instanceName = $instance->instance();

		$ENV{'ARIBA_SELENIUM_RC_HOST'} = $instance->host();
		$ENV{'ARIBA_SELENIUM_RC_PORT'} = $instance->port();
		$ENV{'DISPLAY'} = $instance->xvfbDisplay();
		$ENV{'ARIBA_SELENIUM_RC_ADDITIONAL_PARAMETERS'} = "-multiWindow -Dstopsvc=$instanceName";

		r($seleniumStopCmd);
	}
}

sub startSeleniumRC {
	my $me = shift;
	my $role = shift;
	my $apps = shift;

	my $cluster = $me->currentCluster();
	my @instances = $me->appInstancesOnHostLaunchedByRoleInClusterMatchingFilter(ariba::Ops::NetworkUtils::hostname(),$role,$cluster,$apps);
	my $installDir = $me->installDir();

	my $seleniumRcStartCmd = "$installDir/internal/bin/startSeleniumRc";

	unless (@$apps || @instances) {
		# missing appInstances means old way of starting selenium,
		# one per host; env should already be set for this from
		# startup
        # The return value of launchCommandFeedResponses is a pid,
        # which is not appropriate for startup to receive from
        # this function
        ariba::Ops::Startup::Common::launchCommandFeedResponses($seleniumRcStartCmd);
        return;
	}

	my $rotateInterval = 24 * 60 * 60; # 1 day

	$ENV{'ARIBA_INSTALL_ROOT'} = $installDir;

	my @launchedInstances = ();

	my $additionalParameters = $me->default('Ops.SeleniumRc.AdditionalParameters') ||
		"-multiWindow -forcedBrowserMode \"*chrome /opt/firefox3/firefox-bin\"";
	$additionalParameters =~ s/'/"/g;
	for my $instance (@instances) {
		my $instanceName = $instance->instance();

		$ENV{'ARIBA_SELENIUM_RC_HOST'} = $instance->host();
		$ENV{'ARIBA_SELENIUM_RC_PORT'} = $instance->port();
		$ENV{'DISPLAY'} = $instance->xvfbDisplay();
		$ENV{'ARIBA_SELENIUM_RC_ADDITIONAL_PARAMETERS'} = "-Dstopsvc=$instanceName " . $additionalParameters;

		my $result = ariba::Ops::Startup::Common::launchCommandFeedResponses($seleniumRcStartCmd . " -useKR $instanceName");
		if ($result == 0) {
			push(@launchedInstances, $instance);
		}
	}

	return @launchedInstances;
}

sub stopXVFBInstances {
	my $instancesRef = shift;

	my $result = 1;
	for my $instance (@$instancesRef) {
		my $display = $instance->xvfbDisplay();
		$result = $result && ariba::Ops::Startup::Common::stopVirtualFrameBufferServer($display, $instance->xvfbInstance());
	}

	return $result;
}

sub startXVFB {
	my $me = shift;
	my $role = shift;
	my $apps = shift;

	my $cluster = $me->currentCluster();

	my @instances = $me->appInstancesOnHostLaunchedByRoleInClusterMatchingFilter(ariba::Ops::NetworkUtils::hostname(),$role,$cluster,$apps);

	my $result = 1;

	if (@instances) {

		for my $instance (@instances) {
			my $display = $instance->xvfbDisplay();
			$result = $result && ariba::Ops::Startup::Common::startVirtualFrameBufferServer($display, $instance->xvfbInstance());
		}

	} elsif (!@$apps) {
		$result = ariba::Ops::Startup::Common::startVirtualFrameBufferServer($me->default('Ops.XDisplay'));
	}

	return $result;
}

1;
