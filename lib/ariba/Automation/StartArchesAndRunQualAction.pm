package ariba::Automation::StartArchesAndRunQualAction;

=pod

=head1 NAME

ariba::Automation::StartArches - Base class for Deployment actions

=head1 DESCRIPTION

This is the base deploy action.  Don't use this directly; instead, 
use DeployRCAction and DeployLocalAction.

=cut


use ariba::Automation::Action;
use ariba::Automation::Utils;
use ariba::Ops::NetworkUtils;
use ariba::rc::ArchivedProduct;

use base qw(ariba::Automation::Action);

sub validFields {
	my $class = shift;

	my $fieldsHashRef = $class->SUPER::validFields();

	$fieldsHashRef->{'buildName'} = 1;
	$fieldsHashRef->{'productName'} = 1;

	return $fieldsHashRef;
}

sub execute {
	my $self = shift;

	my $logger = ariba::Ops::Logger->logger();
	my $logPrefix = $self->logPrefix();

	my $productName = $self->productName();
	my $buildName = $self->buildName();

	my $service = ariba::Automation::Utils->service();
	my $globalState = ariba::Automation::GlobalState->newFromName($self->SUPER::attribute("robotName"));
	ariba::rc::Globals::setPersonalServiceType($globalState->serviceType());

	my $product = ariba::rc::ArchivedProduct->new($productName, $service, $buildName);
	my $archiveDir = $product->archiveDir();

	#
	# TODO: Just starting the qual ... will need to add stuff to look at the results etc etc
	#

	my $qualCmd = "$archiveDir/bin/startqual.sh"; 
	$logger->info("$logPrefix Executing $qualCmd");
	return unless ($self->executeSystemCommand($qualCmd));

	# wait to make sure the test is deployed and started
	$logger->info ("$logPrefix Sleeping for 2 minutes for the test plan to be deployed and started...");
	sleep(120);

	my $hostname = ariba::Ops::NetworkUtils::hostname();
	my $qualURL = "http://$hostname:7080/Arches/api/testrunner/run/BQ";
        $logger->info("$logPrefix Running the Qual Command by hitting the URL $qualURL");

	my $curlOut = `curl $qualURL`;
	$logger->info("$logPrefix Qual output is: $curlOut");
	# Tests are running. Once finished reports will be at /home/robot260/public_doc/testReports-Arches/1325890900507
	$curlOut =~ /public_doc\/testReports-Arches\/(\d+)/ig;
	my $testId = $1;
	
	if (! $testId)
	{
		$logger->error ("TestId is null. The qual couldn't be kicked-off successfully");
		return 0;
	} 
	$logger->info("$logPrefix TestId is $testId");
	$self->setQualTestId($testId);

	return 1;
}
1;
