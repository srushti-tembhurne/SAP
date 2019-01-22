package ariba::Ops::OpsToolsWrapper;

use strict;

use lib "/usr/local/ariba/lib/";
use ariba::Ops::Constants;
use ariba::Ops::Startup::Common;
use ariba::rc::Globals;
use ariba::rc::InstalledProduct;
use ariba::rc::ArchivedProduct;
use ariba::rc::Passwords;
use ariba::rc::Product;

#
# Wrappers for:
# - c-d, startup ops tools called by Jenkins for testing hadoop-type products
# - getting app instances, roles 
#

###########################################
# Control deployment tests
# [x] controlDeploymentStop: arches dev3
# [x] controlDeploymentStart: arches dev3
# [x] controlDeploymentTest: arches dev3, hadoop test
# [x] controlDeploymentRestart: arches dev3
# [] controlDeploymentUpgrade
#
# Node control tests
# [x] nodeStop (graceful): arches and hadoop dev3
# [x] nodeStart: arches and hadoop dev3
# [x] nodeRecycle
# [x] nodeKill (-9)

###########################################

sub controlDeploymentStop {
    my ($product, $service, $providedMaster, $cluster) = @_;
    
    controlDeploymentCommands($product, $service, $providedMaster, "stop");
}

sub controlDeploymentStart {
    my ($product, $service, $providedMaster, $cluster) = @_;
    
    controlDeploymentCommands($product, $service, $providedMaster, "start");

}

sub controlDeploymentTest {
    my ($product, $service, $providedMaster, $buildname, $cluster) = @_;
    
    controlDeploymentCommands($product, $service, $providedMaster, "test", $buildname);
}

sub controlDeploymentRestart {
    my ($product, $service, $providedMaster, $cluster) = @_;
    
    controlDeploymentCommands($product, $service, $providedMaster, "restart");
}

sub controlDeploymentUpgrade {
    my ($product, $service, $providedMaster, $cluster, $buildname) = @_;
    
    controlDeploymentCommands($product, $service, $providedMaster, "upgrade", $cluster, $buildname);
}


sub controlDeploymentCommands {
    my ($product, $service, $master, $action, $cluster, $buildname) = @_;
    my $productDir;
    $cluster = "primary" unless $cluster;

    if ($action eq "upgrade") {
        exit unless $buildname;
    }

    ariba::rc::Passwords::initialize($service, $master);

    if (ariba::rc::InstalledProduct->isInstalled($product, $service, $buildname)) {
        my $prod = ariba::rc::InstalledProduct->new($product, $service, $buildname);
	$productDir = $prod->installDir();
    } else {
        my $prod = ariba::rc::ArchivedProduct->new($product, $service, $buildname);
        $productDir = $prod->archiveDir();
    }

    my $cmd = "$productDir/bin/control-deployment $product $service $action -cluster $cluster";
    $cmd .= " -buildname $buildname" if(defined($buildname));

    print "Running $cmd\n";
    my $ret = ariba::Ops::Startup::Common::runCommandAndFeedMasterPassword($cmd, $master);

    unless ($ret) {
         print "ERROR: deployment failed\n";
	 print "Failed during $cmd\n";
    }
}

#
# nightly recycle for 50% of the nodes
#
sub nightlyRecycle {
    my ($product, $service, $providedMaster) = @_;

    nodeControl($product, $service, $providedMaster, undef, undef, "nightly");
}

#
# graceful node stop via stopsvc
#
sub nodeStop {
    my ($product, $service, $providedMaster, $instance, $cluster) = @_;

    nodeControl($product, $service, $providedMaster, $instance, $cluster, "stop");
}

#
# node start via startup
#
sub nodeStart {
    my ($product, $service, $providedMaster, $instance, $cluster) = @_;

    nodeControl($product, $service, $providedMaster, $instance, $cluster, "start");
}

#
# immediate kill (-9)
#
sub nodeKill {
    my ($product, $service, $providedMaster, $instance, $cluster) = @_;

    nodeControl($product, $service, $providedMaster, $instance, $cluster, "kill");
}

#
# graceful node recycle via cycle-wof-apps
#
sub nodeRecycle {
    my ($product, $service, $providedMaster, $instance, $cluster, $type) = @_;

    #
    # use stopsvc, startup to quickly unblock since currently new hadoopp-type nodes
    # require additional changes which can be done later
    #
    my $result = nodeControl($product, $service, $providedMaster, $instance, $cluster, "stop");
    nodeControl($product, $service, $providedMaster, $instance, $cluster, "start") if $result;
    #nodeControl($product, $service, $providedMaster, $instance, $cluster, "recycle");
}

sub nodeControl {
    my ($product, $service, $master, $instance, $cluster, $action) = @_;

    my $me = ariba::rc::InstalledProduct->new("mon", $service);
    my $prod = ariba::rc::InstalledProduct->new($product, $service);
    my $installDir = $prod->installDir();
    my $cmd = "$installDir/bin";
    my $ret;
    $cluster = "primary" unless $cluster;

    my ($host, $instanceName) = instanceHost($product, $service, $instance, $cluster);
    my $user = $prod->deploymentUser();
    my $password = ariba::rc::Passwords::lookup($user);

    if ($action eq "stop") {
        $cmd .= "/stopsvc $instanceName";
    } elsif ($action eq "start") {
        $cmd .= "/startup $instanceName";
    } elsif ($action eq "kill") {
        $cmd .= "/stopsvc -useSignal 9 $instanceName";
    } elsif ($action eq "nightly") {
        $cmd .= "/cycle-wof-apps -graceful 50 $product $service";
    }

    ## For personal services, run action command directly on the host command it is run on
    unless (ariba::rc::Globals::isPersonalService($service)) {
        $cmd = "ssh $user\@$host \"$cmd\"";
    }

    print "About to run $cmd\n";
    $ret = ariba::rc::Utils::sshCover($cmd, $password, $master);

    if ($ret) {
        print "no ret ERROR: node control failed running $cmd\n";
        exit;
    }
    return 1;
}

sub instanceHost {
    my ($thisProduct, $service, $thisInstance, $cluster) = @_;
    my $host;
    my $product = ariba::rc::InstalledProduct->new($thisProduct, $service);

    if ($thisInstance) {
        for my $instance ($product->appInstancesInCluster($cluster)) {
            my $name = $instance->instanceName();

            if ($name =~ /^$thisInstance/) {
                $host = $instance->host();

                return ($host, $name);
            }
        }
        print "No host found for $thisInstance in $service cluster $cluster. Exiting ...\n";
        exit unless ($host);
    } else {
        ## No specific instance provided, just returned any host to run command from
        $host = ($product->allHostsInCluster($cluster))[0];
        return ($host);
    }
}

#
# returns an array of all app instances on a particular host for a specified product, cluster
#
sub appInstancesOnHostInCluster {
    my ($product, $service, $host, $cluster) = @_;

    return undef unless (ariba::rc::InstalledProduct->isInstalled($product, $service));

    my $me = ariba::rc::InstalledProduct->new($product, $service);
    my @instances = ariba::rc::Product::appInstancesOnHostInCluster($me, $host, $cluster);
    my @instancesNames;

    for my $instances (@instances) {
        push(@instancesNames, $instances->instanceName());
    }

    return @instancesNames;
}

#
# returns app instances for a specific role 
#
sub appInstancesLaunchedByRoleInCluster {
    my ($product, $service, $role, $cluster) = @_;

    return undef unless (ariba::rc::InstalledProduct->isInstalled($product, $service));

    my $me = ariba::rc::InstalledProduct->new($product, $service);
    my @instances = ariba::rc::Product::appInstancesLaunchedByRoleInCluster($me, $role, $cluster);
    my @instancesNames;

    for my $instances (@instances) {
        push(@instancesNames, $instances->instanceName());
    }

    return @instancesNames;
}

#
# checks if app instance is up
# return 1 or 0 if true or false respectively
# app instances to be in the format ie. SearchCore-12820003@hdp104
#
sub checkIsUp {
    my ($product, $service, $instanceName, $cluster) = @_;

    return undef unless (ariba::rc::InstalledProduct->isInstalled($product, $service));

    my $me = ariba::rc::InstalledProduct->new($product, $service);
    my @instances = $me->appInstancesInCluster($cluster);

    my $matchedInstance = ($me->appInstancesMatchingFilter(\@instances, [$instanceName]))[0];

    return undef unless $matchedInstance;
    return $matchedInstance->checkIsUp();
}

#
# given a product, service, app instance name and cluster,
# returns arches health check url
# i.e. http://hdp104.lab1.ariba.com:23003/Arches/api/health/get
#
# NOTE: app instance must either be:
# node name: SearchCore # will return an array of all matched urls for that node type
# full app instance name: SearchCore-12820003@hdp104 # returns url only for that instance
#
# SearchCore-12820003 alone will not match
#
sub archesHealthStatusUrl {
    my ($product, $service, $instanceName, $cluster) = @_;

    my $me = ariba::rc::InstalledProduct->new($product, $service);

    return undef unless ($product eq 'arches');
    return undef unless (ariba::rc::InstalledProduct->isInstalled($product, $service));

    my @instances = $me->appInstancesInCluster($cluster);
    
    my @matchedInstances = $me->appInstancesMatchingFilter(\@instances, [$instanceName]);
    my @statusUrls;

    for my $instance (@matchedInstances) {
        my $statusUrl = $instance->archesHealthGetURL();
        print "instance " . $instance->instanceName() . " url: $statusUrl\n";
        push(@statusUrls, $instance);
    }

    return @statusUrls;
}

1;
