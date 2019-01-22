package ariba::Ops::TopologyManager;

use strict;
use ariba::rc::InstalledProduct;
use ariba::Ops::Startup::Common;
use ariba::Ops::NetworkUtils;

# TopologyManager class to use from Environment variable 
my $dcTopologyManagerClassFromEnv = $ENV{'TEST_DC_TOPOLOGY_MANAGER_CLASS'};

# Initialize TopologyManager instance based on P.table or the environment variable.
# Class mentioned in the environment variable takes precedence over p.table. 
# 
# Example: 
# Environment variable is used to override the TopologyManager class mentioned in p.table during testing.
# TestSimulationTopologyManager is an implementation of TopologyManager which is used to simulate various 
# failure cases in the cluster and is configured using the environment variable property.  
sub new {
    my $className = shift;
    my $oldProduct = shift;
    my $newProduct = shift;
    my $baseTMonly = shift;
    my $clustertestFile = shift;

    my $service = $newProduct->service();   
    my $defaultTopologyManagerClass = "TopologyManager";
    my $newTmName = $newProduct->default('Ops.Topology.TopologyManager')||'' ;
    
    if(defined $dcTopologyManagerClassFromEnv) {
        my @devlabServices = ariba::rc::Globals::servicesForDatacenter('devlab');
        my @opslabServices = ariba::rc::Globals::servicesForDatacenter('opslab');
        if ((grep /^$service$/, @devlabServices) || 
            (grep /^$service$/, @opslabServices) || 
            (ariba::rc::Globals::isPersonalService($service)) ) {
                print "Topology Manager class overriden from environment variable - [$dcTopologyManagerClassFromEnv]\n";
                $newTmName = $dcTopologyManagerClassFromEnv;
        }        
    }
     
    my $topologyManagerClass = "ariba::Ops::" . $newTmName;
    print "Topology Manager class to be initialized - [$topologyManagerClass]\n";
    
    my $self = {
        "oldProduct" => $oldProduct,
        "newProduct" => $newProduct,
        "clustertestFile" => $clustertestFile
    };

    my $isSuccess = 0;

    if($newTmName) {
        eval "require $topologyManagerClass";
        if( $@ ) {
            print "Failed to load $topologyManagerClass\n";
            die($@);
        }
        
        if (defined($oldProduct) && defined($newProduct)) {
            $isSuccess = $topologyManagerClass->initialize($oldProduct,$newProduct,$baseTMonly);
        }
    }

    #if initialization is successful , TM instance will be created based on newProduct's p.table entry
    #else Default TopologyManager will be instantiated.
    #example :
    #oldProduct          newProduct    TM type
    #TM                   TM           TM from NewProduct
    #TM-A                 TM           TM from NewProduct
    #TM                   TM-A         TM-A from NewProduct
    #TM-A                 TM-B         TM-B from NewProduct
    #TM                   PHTM         default TM (TopologyManager)
    #PHTM                 TM           TM from NewProduct
    #PHTM                 PHTM         PHTM from NewProduct
    #TM-A                 PHTM         default TM (TopologyManager)

    if($isSuccess) {
        bless($self,$topologyManagerClass);
    }
    else {
        $topologyManagerClass = "ariba::Ops::" . $defaultTopologyManagerClass;
        bless($self,$topologyManagerClass);
    }
    
    return $self;
}

sub callback {
    my $self = shift; 
    my $method = shift;
    my @args = @_;

    my $ret;
    print "Method Name : ",$method . "\n";

    if($self->can($method)) {
        $ret = $self->$method(@args);
    } else {
        $ret = 1; # if method does not exist return 1
    }

    return $ret;
}

sub initialize {
    my $topologyManagerClass = shift;
    my $oldProduct = shift;
    my $newProduct = shift; 
    my $baseTMonly = shift;
    return 1;
}

sub oldProduct {
    my $self = shift;
    return $self->{"oldProduct"};
}

sub newProduct {
    my $self = shift;
    return $self->{"newProduct"};
}

sub hasRCMapChanged {
    my $self = shift;
    return $self->{"hasRCMappingChanged"};
}

#base class should always return 0
sub canTMHandleTopoChange {
    my $self = shift;
    return  0;
}

sub mclid {
    my $self = shift;
    return "";
}

1;
