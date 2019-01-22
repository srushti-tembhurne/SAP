#!/usr/local/bin/perl -w
package ariba::Ops::TopologyValidator;
use strict;

######################################################################################
####### This class consolidates methods to help in validating builds, it can be ######
####### used either during internal tests or at runtime in production           ######
######################################################################################

###############################################################################
## This is a generic method to find duplicate values in any field passed to it
## Input  : 1. Reference to an array of AppInstances
##          2. Name of the field for which we have to check for duplicates 
## Output :  Array of duplicate values for the requested field if there are duplicates 
##           or an empty array if there are no duplicates.
###############################################################################
sub getDuplicatesInField {
    my $instanceRef = shift;
    my @instances   = @{$instanceRef};
    my $wantedField = shift;

    my @duplicates = ();
    my %repetitionCounter = ();
    
    for my $instance (@instances) {
        my $wantedValue = $instance->attribute($wantedField);
        
        if( !defined($wantedValue) ) {
            next;           
        }
        
        if ($repetitionCounter{$wantedValue}){
            $repetitionCounter{$wantedValue} ++;
            push(@duplicates,$wantedValue);                
        }
        else{
                $repetitionCounter{$wantedValue} = 1;
        }
    }
    
    return @duplicates;
}

###############################################################################
## This method is used to fetch duplicate logical names if they exist
## Input  :  1. Reference to an array of AppInstances
##           2. Product object 
## Output :  Array of duplicate values of logicalName if there are duplicates,
##           or an empty array if there are no duplicates.
###############################################################################
sub getDuplicateLogicalNames {    
    my $instanceRef = shift;  
    my $product     = shift;	
    my @duplicateNames = ();
    
    #Logical names only exist in Ops layout 5 and above, if version is less than 5
    #we just return a empty array signifying there are no duplicates to client
    if(!$product->isLayout(5)) {
        return @duplicateNames;
    }

    my $wantedField = "logicalName";
    @duplicateNames = getDuplicatesInField($instanceRef , $wantedField);
    return(@duplicateNames);
}

###############################################################################
## This method is used to fetch duplicate worker names if they exist
## Input  :  Reference to an array of AppInstances
## Output :  Array of duplicate values of workerNames if there are duplicates,
##           or an empty array if there are no duplicates.
###############################################################################
sub getDuplicateWorkerNames {
    my $instanceRef = shift;
    my @duplicateNames = ();
    
    my $wantedField = "workerName";
    @duplicateNames = getDuplicatesInField($instanceRef , $wantedField);
    return(@duplicateNames);
}



###########################################################################################
## This method is used to fetch details of duplicate host:port combinations if they exist
## Input  :  Reference to an array of AppInstances
## Output :  Array of duplicate host:port details if there are duplicates,
##           or an empty array if there are no duplicates.
############################################################################################
## Note: This code is based on method AppInstanceManager:instancesHavePortNumberClash()
##       Its similar to it, except that this is a static method and return type is different
############################################################################################
sub getPortClashDetails {
    my $instanceRef = shift;
    my @instances   = @{$instanceRef};

    my @portNames;

    my %ports = ();
    my @duplicates = ();
    my @portsToIgnore = qw(communityPort clusterPort);

    for my $instance (@instances) {
        my $host = $instance->host();
        my $name = $instance->instanceName();

        my @instancePorts = ();
        my %portToPortName;

        my @portNames = grep { $_ =~ m/Port$/i } $instance->attributes();
        @portNames = filterArray(\@portNames,\@portsToIgnore);

        for my $portName ( @portNames ) {
            my $p = $instance->attribute($portName);

            if ( $p ) {
                push(@instancePorts, $p);
                $portToPortName{$p} = $portName;
            }

        }

        for my $p ( @instancePorts) {
            if ( $ports{$host}{$p} ) {
                my $duplicate =  "$name has $portToPortName{$p} ($p) port number clash with $ports{$host}{$p}\n";
                push(@duplicates,$duplicate); 
            } else {
                $ports{$host}{$p} = $name;
            }
        }
    }

    return @duplicates;
}

######################################################################################
## This is a helper method to return the appInstances during a Flux state.
## Input:  1. Reference to AppInstances from old build 
##         2. Reference to AppInstances from new build
## Output: Combined instances: OldInstances from bucket0 and NewInstances from bucket1
#######################################################################################
sub getAppInstancesDuringFluxState
{
    my $refOldInstances   = shift;
    my $refNewInstances   = shift;
    my @oldInstances   = @{$refOldInstances};
    my @newInstances   = @{$refNewInstances};
    
    my $bucket0 = 0;
    my $bucket1 = 1;    
    my @bucket0NewInstances = grep { $_->recycleGroup() == $bucket0 } @oldInstances ;
    my @bucket1OldInstances = grep { $_->recycleGroup() == $bucket1 } @newInstances ;
    my @mergedInstances = (@bucket0NewInstances , @bucket1OldInstances);
    
    return(@mergedInstances);
}

#################################################################################
## Utility method used to remove contents of one array from another
# Input: 1.Source Array 2.Array to remove from source
# Output: Filtered array
#################################################################################
sub filterArray
{
    my $sourceRef    = shift;
    my $filterRef    = shift;
    my @sourceArray  = @{$sourceRef};
    my @filterArray  = @{$filterRef};

    my %ignoreThese;
    @ignoreThese{@filterArray} = ();
    my @differenceArray =  grep { ! exists $ignoreThese{$_} } @sourceArray;
    return(@differenceArray);
}

1;
