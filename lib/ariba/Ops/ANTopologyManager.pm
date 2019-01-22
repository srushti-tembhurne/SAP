package ariba::Ops::ANTopologyManager;

use strict;
use base qw(ariba::Ops::TopologyManager);
use ariba::Ops::ControlDeploymentHelper;
use ariba::rc::InstalledProduct;
use ariba::rc::Passwords;

sub postBucket0start {
    my $self = shift;
    my $action = shift;

    return 1 unless $action eq "recycle";

    # Save the current parallel value for later, but we want to do webservers fast
    my $maxParallel = ariba::Ops::ControlDeploymentHelper->maxParallelProcesses();
    ariba::Ops::ControlDeploymentHelper->setMaxParallelProcesses(100);

    my $master = ariba::rc::Passwords::lookup('master');
    my $ws = ariba::rc::InstalledProduct->new("ws");
    my $cluster = $ws->currentCluster();
    my $command = $ws->installDir() . "/bin/reload -cluster $cluster";
    $command .= " -readMasterPassword" if $master;
    
    my @hosts = $ws->hostsForRoleInCluster('webserver', $cluster);
    push(@hosts, $ws->hostsForRoleInCluster('adminserver', $cluster));
    my $user = $ws->deploymentUser();
    my $password = ariba::rc::Passwords::lookup($user);
    my $product = $self->newProduct();
    my @command = ($command);
    foreach my $host (@hosts) {
        my $cdh = ariba::Ops::ControlDeploymentHelper->newUsingProductServiceAndCustomer($product->name(), $product->service(), $product->customer());
        $cdh->launchCommandsInBackground(
            "recycle",
            $user,
            $host,
            "cd-$host-" . $product->name() . $product->service(),
            $password,
            $master,
            "restarting webserver",
            @command
        );
    }
    ariba::Ops::ControlDeploymentHelper->waitForBackgroundCommands();
    ariba::Ops::ControlDeploymentHelper->setMaxParallelProcesses($maxParallel);
    return 1;
}

sub canTMHandleTopoChange {
    my $self = shift;
    return 1;
}

1;
