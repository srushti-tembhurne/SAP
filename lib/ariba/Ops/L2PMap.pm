#!/usr/local/bin/perl -w
package ariba::Ops::L2PMap;
use strict;

######################################################################################
####### This class is responsible for writing logical to physical mapping file #######
######################################################################################

#Should be called with arguments pathToL2PFile & reference to appInstance list 
sub generateL2PMapFile{
    my $productSSWS        = shift;
    my $productName        = shift;
    my $instRef            = shift;
    my $l2pContentSource  = shift;
   
    my $pathToMappingFile = getL2PFilePath($productSSWS, $productName) ;
    validateArguments($pathToMappingFile,$instRef);    

    open(F, "> $pathToMappingFile") || die "Could not create logical to physical mapping file: $pathToMappingFile, Error: $!";   
    
    print F "{\n";
    print F "Source = {\n";     
    print F "    contentSource = $l2pContentSource;\n"; 
    print F " };\n";  

    print F "L2PMap = {\n";    

    my @instanceList      = @{ $instRef }; 
    my @instancesNamesWithServerRoles  = ();
    my %instanceMap; #Hashmap to store logicalName => workerInstance
    for my $currentInstance (@instanceList) {
        if (defined $currentInstance->serverRoles()) {
            $instanceMap{$currentInstance->logicalName()} = $currentInstance;
            push @instancesNamesWithServerRoles , $currentInstance->logicalName();
        }
    }
    

    @instancesNamesWithServerRoles  = sort(@instancesNamesWithServerRoles );

    for my $currentInstanceName ( @instancesNamesWithServerRoles ) {
        my $instance = $instanceMap{ $currentInstanceName };
    
        print F "  " . $instance->logicalName() . " = {\n";     
        print F "   host = " . $instance->host() . ";\n";
        print F "   port = " . $instance->httpPort() . ";\n";
        print F "   failPort = " . $instance->failPort() . ";\n";
        print F "   rpcPort = " . $instance->rpcPort() . ";\n";
        print F "   udpPort = " . $instance->internodePort() . ";\n";
        if (defined $instance->backplanePort()) {
           print F "   backplanePort = " . $instance->backplanePort() . ";\n";
        }
        print F "   physicalName = " . $instance->workerName() . ";\n";
        print F "   groups = { 0 = " . $instance->clusterPort() . ";";
        if ($instance->community() && $instance->community() > 0) {
            print F $instance->community() . " = " . $instance->communityPort() . ";";
        }
        print F "};\n";
       
        print F "  };\n";
    }
    
    print F " };\n";
    print F "}\n";
    close(F);

    if (-e $pathToMappingFile)
    {
      my $success=1;
      return $success;  
    }

}

sub validateArguments
{   
    my $pathToMappingFile = shift;
    my $instRef           = shift;
    my @instanceList      = @{ $instRef };

    if(! @instanceList)
    {
       die "Empty instance list passed to L2PMap generator\n";
    }

    if( (not defined $pathToMappingFile) || ($pathToMappingFile eq "") )
    {
       die "Empty L2P Mapfile path passed to L2PMap generator\n";
    } 
}


###############################################################################
## This method is responsible for generating appinstances based on bucket and
## build number passed
###############################################################################
sub generateL2PMapInstances 
{
   my ($changingProductName,$currentSSWS , $buildName,$bucket) = @_;
   my $product;
   
   if(ariba::rc::InstalledProduct->isInstalled($changingProductName, $currentSSWS->service(), $buildName)) {
        $product = ariba::rc::InstalledProduct->new($changingProductName, $currentSSWS->service(), $buildName);
   } else {
        die "Unable to find product: $changingProductName, buildname: $buildName to generate L2P Map\n";
   }

   my @appInstances =  grep { $_->recycleGroup() == $bucket } $product->appInstances();
   return (@appInstances);
}

###############################################################################
## This method is responsible for getting the path tol2p mapping files based
## on the product
###############################################################################
sub getL2PFilePath
{
   my $productSSWS = shift;
   my $productName = shift;
   my $l2pFileName = "l2pmap.txt";
   my $sswsDocRoot = $productSSWS->docRoot(); 
   my $fullPath = $sswsDocRoot . "/topology/" . "$productName/" . $l2pFileName;
   return($fullPath);
}

1;
