package ariba::Ops::Startup::TestServer;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/TestServer.pm#17 $

use strict;

use ariba::Ops::Startup::Tomcat;
use ariba::Ops::NetworkUtils;
use ariba::Ops::Startup::SeleniumServer;

use File::Path;
use File::Basename;
use ariba::rc::Utils;

my $envSetup = 0;

sub setRuntimeEnv {
	my $me = shift;
	
	return if $envSetup;
	
	ariba::Ops::Startup::Tomcat::setRuntimeEnv($me, 1);

	$envSetup = 1;
}

sub composeSeleniumArgs {
	my $me = shift;
	my $paramsHash = shift || {};

	# Gets the ports of selenium servers
	ariba::Ops::Startup::SeleniumServer::composeSeleniumArgs($me, "Test.System.Framework.SeleniumServers", $paramsHash);
	return $paramsHash;
}

sub launch {
	my $me = shift;
	my $webInfSubDir = shift;
	my $apps = shift;
	my $role = shift;
	my $community = shift;
	my $masterPassword = shift;
	my $appArgs = shift || "";

	#FIXME these should come from p.table

	my $runQualOnStartup = "true";
	my $reportsDirectory = $me->default("System.Logging.DirectoryName");
	my $testProductName = $me->name();
	my $buildName = $me->buildName();

	my %additionalAppParamsHashRef = (
					"Test.System.Framework.DefaultTestProductName" => $testProductName,
					"Test.System.Framework.ReportsDirectory" => $reportsDirectory,
					"Test.System.Framework.ProductName" => $testProductName,
					"Test.System.Framework.BuildName" => $buildName,
					"Test.System.Framework.Report.FromRecipients" => "devbuild",
					"Test.System.Framework.Report.IncludeComponentsOwnersOnFailure" => "false",
	);

	# Gets the ports of selenium servers
	ariba::Ops::Startup::TestServer::composeSeleniumArgs($me, \%additionalAppParamsHashRef);
	
	return ariba::Ops::Startup::Tomcat::launch($me, $webInfSubDir, $apps, $role, $community, $masterPassword, $appArgs, \%additionalAppParamsHashRef);
}

1;
