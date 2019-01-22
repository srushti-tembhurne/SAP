package ariba::Automation::CleanAction;

use warnings;
use strict;
use ariba::Automation::Constants;
use ariba::Automation::Utils;
use ariba::Automation::Action;
use base qw(ariba::Automation::Action);

use ariba::Ops::Logger;
use ariba::rc::ArchivedProduct;
use ariba::rc::Globals;
use ariba::Ops::Constants;

sub validFields {
	my $class = shift;

	my $fieldsHashRef = $class->SUPER::validFields();

	$fieldsHashRef->{'productName'} = 1;
	$fieldsHashRef->{'keep'}        = 1;

	return $fieldsHashRef;

}

sub execute {
	my $self = shift;

	my $logger = ariba::Ops::Logger->logger();
	my $logPrefix = $self->logPrefix();

	my $service = ariba::Automation::Utils->service();

	my $productName = $self->productName();
	my $numberToKeep = $self->keep();

	my $root = ariba::Automation::Utils->opsToolsRootDir();

	# 
	# clean up logfiles 
	#
	my $cleaner = "$root/services/tools/bin/clean-old-files-from-dir";
	my $days = ariba::Automation::Constants::daysToExpireLogs();

	# ~/public_doc/logs
	my $publicDocLogs = join "/", 
		ariba::Automation::Constants::baseRootDirectory(), 
		ariba::Automation::Constants::logDirectory();

	# ~/logs/{s4,buyer}
	my $productLogs = join "/",
		ariba::Automation::Constants::baseRootDirectory(), 
		"logs",
		$productName;
	
	# TODO: Figure out who is expiring these logs
	#
	# ~/logs/ssws
	# my $sswsLogs = join "/",
		# ariba::Automation::Constants::baseRootDirectory(), 
		# "logs",
		# "ssws";

	# TODO: Figure out who is expiring these logs
	#
	# ~/personal_robotXX/{s4,buyer}/logs
	# my $personalServiceProductLogs = join "/",
		# ariba::Automation::Constants::baseRootDirectory(), 
		# ariba::rc::Globals::personalServicePrefix() . $ENV{'USER'},
		# $productName,
		# "logs";

	# ~/personal_robotXX/{s4,buyer}/archives/logs/
	my $personalServiceArchiveLogs = join "/",
		ariba::Automation::Constants::baseRootDirectory(), 
		ariba::rc::Globals::personalServicePrefix() . $ENV{'USER'},
		$productName,
		"archives",
		"logs";

      my $personalServiceSQLLogs = join "/",
                "/var",
                "tmp",
                $productName,
                ariba::rc::Globals::personalServicePrefix() . $ENV{'USER'},
                "application";

	# TODO: Add these dirs at some point:
	#	$sswsLogs,
	#	$personalServiceProductLogs, 

    # maintain one-to-one relationship between dirs/days
    my @dirs = 
		( 
		$publicDocLogs, 
		$productLogs, 
		$personalServiceArchiveLogs, 
                $personalServiceSQLLogs,
		ariba::Ops::Constants::archiveLogBaseDir(),
		ariba::Automation::Constants::apacheLogDir(),
		);

    # time to expire for logfiles in @dirs can be adjusted
    # on a per-logfile basis if necessary. at the moment they
    # all happen to share the same expire time.
    my @days = 
		(
		$days,
		$days,
                $days,  
		0, #delete all the SQL Collector logs before the run starts.
		$days,
		$days,
		);
	foreach my $i (0 .. $#dirs) {
		my $logdir = $dirs[$i];
		my $expire = $days[$i];
		$logger->info("$logPrefix Cleaning logs dir : $logdir older than $expire days");
		next unless -d $logdir;
		my $cleanLogsCmd = "$cleaner -d $expire $logdir";
		$logger->info("$logPrefix Cleaning logs with $cleanLogsCmd");
		system ("$cleanLogsCmd &");
	}

	my $rcscrubber = "$root/services/tools/bin/everywhere/rc-scrubber2";

	#
	# clean deployments
	#
	my $cleanDeploymentsCmd = "$rcscrubber archived-deployments"
		. " -force -bydate"
		. " -product " . $productName
		. " -service " . $service;
	$cleanDeploymentsCmd .= " -keep $numberToKeep" if ($numberToKeep);
	$logger->info("$logPrefix cleaning deployments for $productName with $cleanDeploymentsCmd");
	system ("$cleanDeploymentsCmd &");

	#
	# clean builds
	#
	my $previousClient = ariba::Automation::Utils->setupLocalBuildEnvForProductAndBranch($productName);
	my $cleanBuildsCmd =  "$rcscrubber archived-builds"
		. " -force -bydate"
		. " -product " . $productName;
	$cleanBuildsCmd .= " -keep $numberToKeep" if ($numberToKeep);
	$logger->info("$logPrefix cleaning builds for $productName with $cleanBuildsCmd");
	system ("$cleanBuildsCmd &");

	ariba::Automation::Utils->teardownLocalBuildEnvForProductAndBranch($productName, undef, $previousClient);

	# since we run rc-scrubber2 in the background, we don't know
	# whether the action failed...
	return 1;
}

1;
