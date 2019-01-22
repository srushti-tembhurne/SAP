package ariba::Ops::Startup::ANTestRunner;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/ANTestRunner.pm#1 $

use strict;

use ariba::Ops::Startup::WOF;
use ariba::Ops::NetworkUtils;

use File::Path;
use File::Basename;
use ariba::rc::Utils;

my $envSetup = 0;

sub setRuntimeEnv {
	my $me = shift;

	return if $envSetup;

	ariba::Ops::Startup::WOF::setRuntimeEnv($me);
	
	my $perlCmd = $^X or die ("Cannot find perl in PATH");
	$ENV{'ARIBA_PERL_COMMAND'} = $perlCmd;

	$envSetup++;
}

sub composeSeleniumArgs {
	my $me = shift;

	# Gets the ports of selenium servers
	my %seleniumServers = ();
	ariba::Ops::Startup::SeleniumServer::composeSeleniumArgs($me, "TestAutomation.Selenium.Servers", \%seleniumServers);   
	
	return \%seleniumServers;
}

1;
