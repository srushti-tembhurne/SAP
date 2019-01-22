package ariba::Automation::DeployLocalAction;

use warnings;
use strict;

use ariba::Automation::Action;
use ariba::Automation::Utils;
use ariba::rc::InstalledProduct;

use base qw(ariba::Automation::DeployAction);

sub execute {
	my $self = shift;

	my $logger = ariba::Ops::Logger->logger();
	my $logPrefix = $self->logPrefix();

	my $productName = $self->productName();
	my $buildName = $self->buildName();
	my $branch = undef;

	my $root = ariba::Automation::Utils->opsToolsRootDir();
	my $service = ariba::Automation::Utils->service();

	#
	# make sure this var is set so that we pull build from 'local'
	# archive builds location
	#
	my $previousClient = ariba::Automation::Utils->setupLocalBuildEnvForProductAndBranch($productName, $branch);

	my $deploymentStatus = $self->SUPER::execute();
	#
	# return ENV to previous state
	ariba::Automation::Utils->teardownLocalBuildEnvForProductAndBranch($productName, $branch, $previousClient);

	return $deploymentStatus;
}
1;
