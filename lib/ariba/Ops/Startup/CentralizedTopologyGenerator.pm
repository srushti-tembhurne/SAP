#!/usr/local/bin/perl -w
package ariba::Ops::Startup::CentralizedTopologyGenerator;
use strict;

use ariba::rc::Globals;
use ariba::rc::Passwords;
use ariba::Ops::ControlDeploymentHelper;
use ariba::Ops::Startup::Common;


######################################################################################
####### This class is responsible for writing topology file to web server      #######
######################################################################################

sub generateTopologyFileAndDeployToWebServers {
    
   my $cluster = shift;
   my $action = shift;
   my $newProduct = shift;
   my $oldBuildName = shift;
   my $productName = $newProduct->name();
   my $serviceName = $newProduct->service();
   my $master = ariba::rc::Passwords::lookup('master');
   my $rootDir = ariba::rc::Globals::rootDir('ssws', $serviceName);
   my $newBuildName = $newProduct->buildName();
    
   my $cmdFlags = "-cluster $cluster ";
   if (defined($master) && $master) {
       $cmdFlags .= "-readMasterPassword";
   }

   $cmdFlags .= " -productName $productName";
   if (defined($oldBuildName)) {
       $cmdFlags .= " -oldBuildName $oldBuildName";
   }
   $cmdFlags .= " -newBuildName $newBuildName";

   my $cmd = "$rootDir/bin/centraltopogen $cmdFlags";
   my @command = ();
   push(@command, $cmd);
   my @webServerHosts = ();
   @webServerHosts = $newProduct->hostsForRoleInCluster('httpvendor', $cluster);
   
   copyCentralizedFileToAllWebservers($cluster, $action, $newProduct, $oldBuildName);
   
   for my $host (@webServerHosts) {
     print "web server host : $host\n";
     my $user = ariba::rc::Globals::deploymentUser($productName, $serviceName);
     my $password = ariba::rc::Passwords::lookup($user);
     my $cdh = ariba::Ops::ControlDeploymentHelper->newUsingProductServiceAndCustomer($productName, $serviceName, $newProduct->customer());
     # Setting SSH error mode only during upgrade.
     # Cluster start should not be affected for some ssh failure. 
     if( $action eq "upgrade" ) {
        $cdh->setSkipOnSshFailure(0);
     }
     $cdh->launchCommandsInBackground(
         $action,
          $user,
          $host,
          "cd-" . $productName . $serviceName,
          $password,
          $master,
          "creating centralized topology",
          @command,
          );
    }
}


# This function will copy the old build Centralized topology file to all webservers.
# When a new ssws host is added, the Centralized topology file will not be present
# in the newly added host, this function will take care of copying file to all the ssws host,
# including newly added host.
sub copyCentralizedFileToAllWebservers {
   my $cluster = shift;
   my $action = shift;
   my $thisProduct = shift;
   my $buildName = shift;
   
   my $productName = $thisProduct->name();
   my $serviceName = $thisProduct->service();
   
   if ($action eq "recycle") {
      my $temp = ariba::Ops::Startup::Common::tmpdir();
      my $tempFolder = $temp."/CentralizedTopologies";
      mkdirRecursively([$tempFolder]) unless -d $tempFolder;    
      my $centralizedTopologyFile = "CentralizedTopology_" . $buildName. ".table";
      my $tempFile = $tempFolder."/".$centralizedTopologyFile;         
      my $srcRoot = ariba::rc::Globals::rootDir("ssws", $serviceName);
      my $centralizedTopologyDirectory = $srcRoot."/docroot/topology/" . $productName . "/CentralizedTopologyTables";  
      my $useCompress = 0;           
      my @webServers = $thisProduct->hostsForRoleInCluster('httpvendor', $cluster);
      my $webUser  = ariba::rc::Globals::deploymentUser($productName, $serviceName);

      foreach my $webserver (@webServers)
      {
        ariba::rc::Utils::transferFromSrcToDest($webserver, $webUser,
                                                $centralizedTopologyDirectory,
                                                undef, undef, $webUser, $tempFolder,
                                                undef, $useCompress);
        last if (-e $tempFile);
      }

      if (-e $tempFile) {
         foreach my $webserver (@webServers)
         {
            ariba::rc::Utils::transferFromSrcToDest(undef, $webUser, $tempFolder, undef,
                                                    $webserver, $webUser,
                                                    $centralizedTopologyDirectory,
                                                    undef, $useCompress);
         }
      }
   }	
}


1;
