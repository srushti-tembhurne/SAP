package ariba::Automation::BuildnameFromDatasetAction;

use warnings;
use strict;

use ariba::Automation::Action;
use base qw(ariba::Automation::Action);

use ariba::rc::Globals;
use ariba::Ops::DatasetManager;

sub validFields {
	my $class = shift;

	my $fieldsHashRef = $class->SUPER::validFields();

	$fieldsHashRef->{'buildName'} = 1;
	$fieldsHashRef->{'datasetType'} = 1;
	$fieldsHashRef->{'productName'} = 1;

	return $fieldsHashRef;
}

sub execute {
	my $self = shift;

	my $logger = ariba::Ops::Logger->logger();
	my $logPrefix = $self->logPrefix();

	my $datasetType = $self->datasetType();
	my $productName = $self->productName();

	my ($dataset) = ariba::Ops::DatasetManager->listBaselineRestoreCandidatesForProductNameAndTypeByModifyTime($productName, $datasetType);

	unless ($dataset) {
		$logger->error("$logPrefix Can't find dataset for type '$datasetType'");
		return;
	}

	my $sourceBuildName = $dataset->buildName();
	$self->setBuildName($sourceBuildName);

	my $datasetId = $dataset->instance();

	$logger->info("$logPrefix set buildName '$sourceBuildName' from dataset ID '$datasetId'");

	return 1;
}

1;
