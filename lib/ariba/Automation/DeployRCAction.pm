package ariba::Automation::DeployRCAction;

use ariba::Automation::Action;
use ariba::Automation::Utils;
use ariba::Ops::NetworkUtils;
use ariba::rc::InstalledProduct;

use base qw(ariba::Automation::DeployAction);

sub execute {
    my $self = shift;

    my $logger = ariba::Ops::Logger->logger();
    my $logPrefix = $self->logPrefix();

    my $productName = $self->productName();
    my $buildName = $self->buildName();
    my $origin = $self->origin();

    # 
    # make sure we are pulling from rc archive
    ariba::Automation::Utils->teardownLocalBuildEnvForProductAndBranch($productName, $branch);
    
    if ( $origin && -d $origin ) {
        ariba::rc::Globals::setArchiveBuildOverrideForProductName($productName, $origin);
    }
    else {
        #
        # in case of an IDC robot, pull from local rc mirror of
        # archive/builds
        my $hostname =  ariba::Ops::NetworkUtils::hostname();
        if (ariba::Automation::Utils::isIdcRobotHost($hostname)) {
            my $archiveBuildRoot =  "/home/idcrc/rcmirror/$productName";
            ariba::rc::Globals::setArchiveBuildOverrideForProductName($productName, $archiveBuildRoot);
        }
    }
    return $self->SUPER::execute();
}
1;
