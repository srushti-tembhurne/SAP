package ariba::Automation::WsBuildnameFromCurrentRCBuildLabelAction;

use warnings;
use strict;

use ariba::Automation::Action;
use ariba::rc::Globals;
use File::Basename;
use ariba::Automation::Constants;
use ariba::Automation::Utils;

use base qw(ariba::Automation::Action);

sub validFields {
	my $class = shift;

	my $fieldsHashRef = $class->SUPER::validFields();

	$fieldsHashRef->{'buildName'} = 1;
	$fieldsHashRef->{'productName'} = 1;
	$fieldsHashRef->{'branchName'} = 1;

	return $fieldsHashRef;
}

sub execute {
	my $self = shift;

	my $logger = ariba::Ops::Logger->logger();
	my $logPrefix = $self->logPrefix();

	my $productName = $self->productName();

	my $branch = ariba::rc::Globals::getLogicalNameForBranch($self->branchName()); 

	my $link = ariba::rc::Globals::archiveBuilds($productName) . '/' .  "stable-$branch";

	my $buildName =  ariba::Automation::Utils::buildNameFromSymlink($link);
	unless ($buildName) {
		$logger->error("$logPrefix Can't get current build name for '$productName'");
		return;
	}

	$self->setBuildName($buildName);

	$logger->info("$logPrefix set buildName '$buildName' from 'stable-$branch' rc label for '$productName'");

	return 1;
}

1;
