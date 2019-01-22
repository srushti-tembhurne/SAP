package ariba::Automation::DeployAction;

=pod

=head1 NAME

ariba::Automation::DeployAction - Base class for Deployment actions

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
    $fieldsHashRef->{'force'} = 1;
    $fieldsHashRef->{'opsConfigLabel'} = 1;

    return $fieldsHashRef;
}

sub execute {
    my $self = shift;

    my $logger = ariba::Ops::Logger->logger();
    my $logPrefix = $self->logPrefix();

    my $productName = $self->productName();
    my $buildName = $self->buildName();
    my $opsConfigLabel = $self->opsConfigLabel();

    my $root;
    if ($opsConfigLabel) {
        $root = "/home/rc/bin"; # The make-deployment with the -opsconfiglabel option may not be in other ops tool branches
    }
    else {
        $root = ariba::Automation::Utils->opsToolsRootDir() . "/services/tools/bin";
    }

    my $service = ariba::Automation::Utils->service();

    my $globalState = ariba::Automation::GlobalState->newFromName($self->SUPER::attribute("robotName"));
    ariba::rc::Globals::setPersonalServiceType($globalState->serviceType());

    #
    # honor requests to short-circuit deployment (for src builds)
    #

    if (!$self->force() && ariba::rc::ArchivedProduct->isArchived($productName, $service, $buildName)) {
        my $product = ariba::rc::ArchivedProduct->new($productName, $service, $buildName);

        my $buildDate = (lstat(ariba::rc::Globals::archiveBuilds($productName) . "/" . $buildName))[9];
        my $archivedDate = $product->archivedOn();

        if ($buildDate > $archivedDate) {
            $logger->warn("$logPrefix build is newer than deployment for $buildName, will attempt re-deploy");
        #
        # test for broken / interrupted deployments
        #
        } elsif ($product->deploymentInProgress()) {
            $logger->warn("$logPrefix deployment in progress for $buildName, assuming this is an interrupted deployment, will attempt re-deploy");
        } elsif ($product->deploymentFailed()) {
            $logger->warn("$logPrefix failed deployment found for $buildName, will attempt to re-deploy");
        } else {
            $logger->info("$logPrefix $buildName already deployed on service $service, will not re-deploy");

            # touch something in this build to avoid having it scrubbed
            # by rc-scrubber later

            my $installDir = $product->installDir();
            my $oldMode = (stat($installDir))[2];
            chmod(0755, $installDir);
            open(MARKER, ">$installDir/robot-marker$$");
            print MARKER "noRedploy marker file\n";
            close(MARKER) || do {
                $logger->error("$logPrefix Could not create noRedeploy marker: $!");
                return 0;
            };
            unlink("$installDir/robot-marker$$");
            chmod($oldMode, $installDir);

            return 1;
        }
    }

    #
    # perform the deployment
    #
    $logger->info("$logPrefix Starting make-deployment for $productName build $buildName to service $service");

    my $makeDeploymentCmd = "$root/make-deployment -b $buildName -product $productName -service $service";
    if ($opsConfigLabel) {
        $makeDeploymentCmd .= " -opsconfiglabel $opsConfigLabel";
    }
    return unless ($self->executeSystemCommand($makeDeploymentCmd));

    $logger->info("$logPrefix Finished make-deployment for $productName build $buildName to service $service");

    return 1;
}
1;
