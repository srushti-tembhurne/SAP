package ariba::Automation::WaitForStartupAction;

use warnings;
use strict;

use ariba::Automation::Utils;
use ariba::Automation::Action;
use base qw(ariba::Automation::Action);

use ariba::Ops::Logger;
use ariba::rc::InstalledProduct;
use ariba::Ops::Startup::Common;

sub validFields {
	my $class = shift;

	my $fieldsHashRef = $class->SUPER::validFields();

	$fieldsHashRef->{'buildName'} = 1;
	$fieldsHashRef->{'timeToWait'} = 1;
	$fieldsHashRef->{'productName'} = 1;

	return $fieldsHashRef;

}

sub execute {
	my $self = shift;

	my $logger = ariba::Ops::Logger->logger();
	my $logPrefix = $self->logPrefix();

	my $service = ariba::Automation::Utils->service();

	my $productName = $self->productName();
	my $buildName = $self->buildName();
	my $timeToWait = $self->timeToWait();

	my $product = ariba::rc::InstalledProduct->new($productName, $service, $buildName);
	unless ($product) {
		die "Could not load $productName\n";
	}

	my @appInstances = grep { $_->appName() ne "TestServer" } $product->appInstances();

	$logger->info("Waiting for all nodes of $productName to start");

	unless (ariba::Ops::Startup::Common::waitForAppInstancesToInitialize(\@appInstances, $timeToWait, 15, 1)) {

		# report error here (e.g. send email, etc.).
		$logger->error("Not all instances came up");
		$logger->error("The following were still down:"
				. join("\n", map { $_->instance() } grep { $_->isUpChecked() && !$_->isUp() } @appInstances));

		return;
	}

	$logger->info("All for $productName nodes are up");

	return 1;
}

1;
