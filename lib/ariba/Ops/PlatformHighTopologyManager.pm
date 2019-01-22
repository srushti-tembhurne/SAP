##############################################################################################
# purpose of PlatformHighTopologyManager is to determine 
# change in topology and realm-community mapping,
# if both have changed ,it ignores the new realm-comunity mapping 
# and continue with add capacity (topology change)
#
# purpose of Truth Table to identify that at which stage which builds 
# are getting passed, to generate L2PMap and update Modjk 
#
#  Truth Table :
# -----------------
#
#                         oldBuild                 newbuild       bucketSelector
#
# Topology Change :
#        B0 Down           B1                       B0             undef
#        B1 Down           x                        B0+B1          undef   
#
# RCMapping Change:(In RR  oldbuild and newbuild will be the same)
#
#        B0 Down           B0+B1                    x      1       
#        B0 Start          B0+B1                    x      0
#        B1 Down           B0+B1                    x      undef
#
#############################################################################################

package ariba::Ops::PlatformHighTopologyManager;
use strict;
use ariba::rc::Globals;
use ariba::rc::Passwords;
use ariba::Ops::ControlDeploymentHelper;
use ariba::Ops::Startup::Common;
use ariba::Ops::L2PMap;
use ariba::Ops::PreCheck;

our @ISA=qw(ariba::Ops::TopologyManager);

sub launchCTF {

    my $self = shift;
    my $eventName = shift;
    my $useNewProduct = shift;

    my $file = $self->{clustertestFile};
    my $product = $self->oldProduct();
    return if ($product->service() eq 'prod');
    if(defined($file)) {
        my $oldTopologyFile = "/tmp/Topology_Old.table";
        my $newTopologyFile = "/tmp/Topology_New.table";
        ariba::Ops::Startup::Tomcat::composeClusterGroupArguments($self->oldProduct(),$oldTopologyFile);
        ariba::Ops::Startup::Tomcat::composeClusterGroupArguments($self->newProduct(),$newTopologyFile);
        if (defined ($useNewProduct)) {
            setSeleniumEnv($self->newProduct());
        }
        else {
            setSeleniumEnv($self->oldProduct());
        }
        my $command =   $product->installDir() . "/internal/bin/clusterTestExecutor -event $eventName -config $self->{clustertestFile} -oldTopology  $oldTopologyFile -newTopology $newTopologyFile ";
        
        #By default CTF will execute all tests specified for a given batch (aka 'event') 
        #in the configuration file, if annotation filter is not specified.
        #If annotation filter is specified, only those tests with that annotation will be executed. 
        my $rrOrRU = $self->isRRorRU();
        $command .= "-antnFilter $rrOrRU";
        
        print "launchCTF : launching command = '$command'\n";

        my $ret = ariba::Ops::Startup::Common::runCommandAndFeedMasterPassword($command);
    }
}

sub isRRorRU {

    my $self = shift;

    my $oldProductBuildName = $self->oldProduct()->buildName();
    my $newProductBuildName = $self->newProduct()->buildName();
    
    return ($oldProductBuildName eq $newProductBuildName) ? "RR" : "RU";
}

sub setSeleniumEnv {

    my $product = shift;
    my $role = 'seleniumrc';
    my $cluster = $product->currentCluster();
    my @instances = $product->appInstancesLaunchedByRoleInCluster($role,$cluster);
    if (scalar (@instances) != 0) {
            my $instance = $instances[0];
            my $seleniumHost = $instance->host();
            my $seleniumPort = $instance->port();
            $ENV{'ARIBA_SELENIUM_RC_HOST'} = $seleniumHost;
            $ENV{'ARIBA_SELENIUM_RC_PORT'} = $seleniumPort;
    }
}

sub preBucket0stop {

    my $self = shift;
    my $action = shift;

    return 1 unless $action eq "recycle";
    
    $self->checkForLayoutAndRCMappingChange();
    $self->launchCTF("PreBucket0stop");
    
    return 1;
}

sub dumpModjkFailure {
    my $self = shift;
    my $event = shift;
    my $failedHostRef = shift;
    my $cmdFlags = shift;

    my @failedHosts = @{$failedHostRef};
    print "reload has failed at $event for @failedHosts \n";
    print "run reload with : $cmdFlags option on failed webserver hosts\n";
}

sub postBucket0stop {

    my $self = shift;
    my $action = shift;

    return 1 unless $action eq "recycle";

    $self->launchCTF("PostBucket0stop");

    my $bucket0 = 0;
    my $bucket1 = 1;
    my $newProduct = $self->newProduct();
    my $oldProduct = $self->oldProduct();
    my ($oldBuildArgs,$newBuildArgs);
   
    my $postBucket0stopReturn; 

    if($self->{hasTopologyChanged}) {
        #update B0 balancer worker in modjk config  
        $oldBuildArgs = $oldProduct->buildName().":$bucket1";
        $newBuildArgs = $newProduct->buildName().":$bucket0";

        $postBucket0stopReturn =  $self->updateModJk("postBucket0stop",$oldBuildArgs,$newBuildArgs);
        
        if ($postBucket0stopReturn != -1) {
              #update ClusterTransitionTab to indicate that cluster is transitioning to new topology
              $postBucket0stopReturn = $self->updateClusterTransitionTab($bucket1,'enterCapacityChange','OK');
        }
 
        if ($postBucket0stopReturn != -1) {
             $postBucket0stopReturn = $self->refreshL2PMap($bucket1,$self->oldProduct());
        }
        return ($postBucket0stopReturn);
    }
    elsif($self->{hasRCMappingChanged}) {
        #Remove B0 balancer workers from modjk config,have only B1 'balanceworkers' in modjk
        $oldBuildArgs = $oldProduct->buildName().":$bucket1";
        $newBuildArgs = $oldProduct->buildName().":$bucket0";

        $postBucket0stopReturn = $self->updateModJk("postBucket0stop",$oldBuildArgs,$newBuildArgs,$bucket1);
       
        if ($postBucket0stopReturn != -1) {
              #update ClusterTransitionTab to indicate that cluster is transitioning to new topology
              $postBucket0stopReturn =  $self->updateClusterTransitionTab($bucket1,'enterRealmReabalance','OK');
        }
       
        if ($postBucket0stopReturn != -1) {
              #Execute a direct action on B1 QM nodes to inform them that cluster is transitioning
              $postBucket0stopReturn = $self->executeDAonQueueManagerNode($bucket1,'beginTransitionURL','OK');
        }
        return ($postBucket0stopReturn);
    }
}

sub preBucket0start {
    my $self = shift;
    my $action = shift;

    return 1 unless $action eq "recycle";

    $self->launchCTF("PreBucket0start");

    return 1;
}

sub postBucket0start {
  
    my $self = shift;
    my $action = shift;

    return 1 unless $action eq "recycle";

    $self->launchCTF("PostBucket0start");

    my $bucket0 = 0;
    my $bucket1 = 1;
    my $oldProduct = $self->oldProduct();
    my ($oldBuildArgs);
    my $postBucket0startReturn;

    if($self->{hasRCMappingChanged}) {
        #Replace B1 balancer workers with B0 workers,only have B0 'balanceworkers' in modjk
        my $oldBuildArgs   = $oldProduct->buildName().":$bucket0";
        my $newBuildArgs   = $oldProduct->buildName().":$bucket1";

        $postBucket0startReturn = $self->updateModJk("postBucket0start",$oldBuildArgs,$newBuildArgs,$bucket0);
        
        if ($postBucket0startReturn != -1) { 
             #Execute a direct action on B1 QM nodes to stop the backplane
             $self->executeDAonQueueManagerNode($bucket1,'stopBackplaneURL','OK');

             #Execute a direct action on B0 QM nodes to rebind messages
             $self->executeDAonQueueManagerNode($bucket0,'rebindMessagesURL','OK');
        }
    }
    return ($postBucket0startReturn);
}

sub preBucket1stop {
 
    my $self = shift;
    my $action = shift;

    return 1 unless $action eq "recycle";

    $self->launchCTF("PreBucket1stop");

    return 1;
}

sub postBucket1stop {

    my $self = shift;
    my $action = shift;

    return 1 unless $action eq "recycle";

    $self->launchCTF("PostBucket1stop");

    my $bucket0 = 0;
    my $bucket1 = 1;
    my $newProduct = $self->newProduct();
    my $oldProduct = $self->oldProduct();
    my ($oldBuildArgs,$newBuildArgs);
    my $postBucket1stopReturn;

    if($self->{hasTopologyChanged}) { 
        #update B1 balancer worker in modjk config  
        $oldBuildArgs   = $newProduct->buildName().":$bucket1";
        $newBuildArgs   = $newProduct->buildName().":$bucket0";

        $postBucket1stopReturn = $self->updateModJk("postBucket1stop",$oldBuildArgs,$newBuildArgs);
        
        if($postBucket1stopReturn != -1) {
           $postBucket1stopReturn = $self->refreshL2PMap($bucket0,$self->newProduct(), "topology");
        }
        
        if($postBucket1stopReturn != -1) {
           #update ClusterTransitionTab to indicate that cluster transition is completed
           $postBucket1stopReturn = $self->updateClusterTransitionTab($bucket0,'exitCapacityChange','OK');
        }

        return ($postBucket1stopReturn);
    }
    elsif($self->{hasRCMappingChanged}) {
        #Add B1 balancer workers in modjk config,have both B0+B1 workers 
        $oldBuildArgs   = $newProduct->buildName().":$bucket1";
        $newBuildArgs   = $newProduct->buildName().":$bucket0";

        $postBucket1stopReturn = $self->updateModJk("postBucket1stop",$oldBuildArgs,$newBuildArgs);
 
        if($postBucket1stopReturn != -1) {
            #update ClusterTransitionTab to indicate that cluster transition is completed
            $postBucket1stopReturn = $self->updateClusterTransitionTab($bucket0,'exitRealmReabalance','OK');
        }

        if($postBucket1stopReturn != -1) {
            #Execute a direct action on B0 QM nodes to inform them that cluster transition to new topology is complete 
            $postBucket1stopReturn = $self->executeDAonQueueManagerNode($bucket0,'endTransitionURL','OK');
        }

        return ($postBucket1stopReturn);
    }
}

sub preBucket1start {

    my $self = shift;
    my $action = shift;

    return 1 unless $action eq "recycle";

    $self->launchCTF("PreBucket1start");

    return 1;
}

sub postBucket1start {

    my $self = shift;
    my $action = shift;

    return 1 unless $action eq "recycle";

    $self->launchCTF("PostBucket1start","newProduct");
    $self->launchCTF("consolidateAllReports","newProduct");

    return 1;
}

sub updateModJk {

    my ($self,$event,$oldBuildArgs,$newBuildArgs,$bucketSelector) = @_;

    my (@command,@failedHostsConcurrently,@failedHostsSequentially,@firstFailedHost,@failedHost);
    my $cmd;

    my $updateModJkReturn = -1;
    my $newProduct = $self->newProduct();
    my $oldProduct = $self->oldProduct();
    my $master = ariba::rc::Passwords::lookup('master');
    my $rootDir = ariba::rc::Globals::rootDir('ssws', $newProduct->service());
    my $product = $oldProduct->name();
    my $oldBuildName = $oldProduct->buildName();
    my $newBuildName = $newProduct->buildName();
    my $cluster = $oldProduct->currentCluster();

    my $cmdFlags = "-cluster $cluster ";
    if (defined($master) && $master) {
        $cmdFlags .= "-readMasterPassword"; 
    }
    $cmdFlags .= " -product $product";
 
    $cmdFlags .= " -oldBuildArgs $oldBuildArgs";
    $cmdFlags .= " -newBuildArgs $newBuildArgs";
    #Would be defined only during rebalance in Flux state
    if(defined($bucketSelector)) { 
        $cmdFlags .= " -bucketSelector $bucketSelector"; 
    }

    $cmd = "$rootDir/bin/reload $cmdFlags"; 
    push(@command, $cmd);

    my @webServerHosts = ();
    @webServerHosts = $newProduct->hostsForRoleInCluster('httpvendor', $cluster);
    
    my $firstWebServer = pop(@webServerHosts);
    push(my @firstWebServerHost,$firstWebServer);

    #first try "reload" on one webserver , if that Succeed ,proceed with remaining webhosts,
    my $firstHostRef = $self->executeReload(\@firstWebServerHost,$newProduct,\@command,$master);
    @firstFailedHost = @{$firstHostRef};
    
    if (scalar(@firstFailedHost) == 0) {

        my $failedHostsRef  = $self->executeReload(\@webServerHosts,$newProduct,\@command,$master,"concurrent");
        @failedHostsConcurrently = @{$failedHostsRef};
        
        if (scalar(@failedHostsConcurrently) !=0 ) {
            my $failedHostsSequentiallyRef = $self->executeReload(\@failedHostsConcurrently,$newProduct,\@command,$master);
            @failedHostsSequentially = @{$failedHostsSequentiallyRef};
            push(@failedHost,@failedHostsSequentially);
        }
    
    }
    else {
        push(@failedHost,@firstFailedHost);
        push(@failedHost,@webServerHosts);
        $updateModJkReturn = -1;
    }
    
    $updateModJkReturn = 1 if (scalar(@failedHost) == 0);
    $self->dumpModjkFailure($event,\@failedHost,$cmdFlags) if ($updateModJkReturn == -1);
    return $updateModJkReturn;
}

sub executeReload {
    
    my $self       = shift;
    my $webHostRef = shift;
    my $newProduct = shift;
    my $commandRef = shift;
    my $master = shift;
    my $concurrent = shift;

    my @webServerHosts = @{$webHostRef};
    my @command = @{$commandRef};

    my @cdhReturn = ();

    for my $host (@webServerHosts) {
        my $user = ariba::rc::Globals::deploymentUser($newProduct->name(), $newProduct->service());
        my $password = ariba::rc::Passwords::lookup($user);
        my $cdh = ariba::Ops::ControlDeploymentHelper->newUsingProductServiceAndCustomer($newProduct->name(), $newProduct->service(), $newProduct->customer());
        $cdh->setSkipOnSshFailure(0);
        $cdh->launchCommandsInBackground(
            "recycle",
            $user,
            $host,
            "cd-" . $newProduct->name() . $newProduct->service(),
            $password,
            $master,
            "updating mod jk",
            @command,
        );
        push(@cdhReturn,$cdh);
        ariba::Ops::ControlDeploymentHelper->waitForBackgroundCommands() if (!defined($concurrent));
    }
    ariba::Ops::ControlDeploymentHelper->waitForBackgroundCommands() if (defined($concurrent));
    
    my @failedHost =  map { $_->host() } grep { $_->exitStatus() } @cdhReturn; 
    return (\@failedHost);
}

sub fetchInstances {

    my $requestedBucket  = shift;
    my $product = shift;   
    my @instanceList = $product->appInstances();
    my @filteredInstanceList = ();

    foreach my $instance (@instanceList) {
        my $currentBucket = $instance->recycleGroup();

        #Select instances belonging to the requested bucket
        if ($currentBucket != $requestedBucket) {            
            next;
        }                       
        push @filteredInstanceList , $instance;    
   }

   return(@filteredInstanceList);
}

sub executeDirectAction {

    my ($self,$url,$expectedResponseRef,$appInstances,$executeOnAllAppInstances) = @_;
    my @expectedResponse = @{$expectedResponseRef};
   
    my @failedNodes = ();
    my $appInstance;
    my $counter = 0;
    my $directActionReturn = -1;
    my $appInstancesCount = scalar(@$appInstances);

    my $expectedSucessCount = 1;
    $expectedSucessCount = $appInstancesCount if(defined($executeOnAllAppInstances));
    
    my $successCounter = 0;
    my $result;
    foreach my $appInstance (@$appInstances) {
        if ($appInstance->isTomcatApp()) {
            my $urlString = $appInstance->$url();
            print "$urlString\n";
            my $request = ariba::Ops::Url->new($urlString);
            $result = $request->request(60);
            if ( grep{$result =~ /$_/} @expectedResponse ) {
               $successCounter++;
               last if(!defined($executeOnAllAppInstances));
            }
            else {
                push(@failedNodes,$appInstance->logicalName());
             
                print "Warning: Node " . $appInstance->workerName() . " did not respond to $url";
                print " Or did not return expected response.\n";
                print "Expected response : @expectedResponse Returned Response :$result \n";
            } 
            $counter++;
        }
        if (!defined($executeOnAllAppInstances) && ($counter == 10)) {
            last;
        }
    }

    $directActionReturn = 1 if ($successCounter == $expectedSucessCount);
    return ($directActionReturn,\@failedNodes,$result);
}

sub refreshL2PMap {
   
    my ($self,$bucket,$product,$source) = @_;
    
    # By default use the hit the refreshL2PMap DA that refreshes using the webserver
    my $directActionToUse = 'refreshL2PMapURL';
    if (defined($source) && $source eq "topology") {
        $directActionToUse = 'refreshTopologyURL';
    }
    my @expectedResponse = qw(OK);
    my @appInstances = $product->appInstances();
    my @appInstancesInBucket = grep { $_->recycleGroup() == $bucket } @appInstances;

    print "\nExecuting refreshL2PMapDA on $bucket bucket node\n";
    my ($ret,$failedNodesRef) = $self->executeDirectAction($directActionToUse, \@expectedResponse,\@appInstancesInBucket);

    my @failedNodes = @{$failedNodesRef};
    print "failed nodes while refreshing L2PMap : @failedNodes\n" if($ret == -1);

    return $ret;
}

#determine change in topology and realm-community mapping
#if both have changed ,it ignores the new realm-comunity mapping 
#and continue with add capacity (topology change)
sub checkForLayoutAndRCMappingChange {

    my $self = shift;
    my $oldProduct = $self->{"oldProduct"};
    my $newProduct = $self->{"newProduct"};
    my $hasTopologyChanged = 0;
    my $hasRCMappingChanged = 0;
    $hasTopologyChanged = $self->hasTopologyChangedInBuilds($oldProduct, $newProduct);
    if( !$hasTopologyChanged ) {
        $hasRCMappingChanged = $self->hasRCMappingChanged($oldProduct,$newProduct);  
    }
    $self->{hasTopologyChanged} = $hasTopologyChanged;
    $self->{hasRCMappingChanged} = $hasRCMappingChanged;
    
}

#execute directaction on bucket1 node to find if 
#RC mapping has been changed
#returns 1 if rc mapping changed , 0 otherwise
sub hasRCMappingChanged {
    
    my $self       = shift;
    my $oldProduct = shift;
    my $newProduct = shift;
   
    my $bucket = 1;
    my @expectedResponse = qw(NOTUPDATED OK);
  
    #RCMappingChange is ignored if it is rolling upgrade
    my $oldProductBuildName = $oldProduct->buildName();
    my $newProductBuildName = $newProduct->buildName();
    if ($oldProductBuildName ne $newProductBuildName ) {
        return 0;
    }

    my @appInstances = $newProduct->appInstances();
    my @appInstancesInBucket1 = grep { $_->recycleGroup() == $bucket } @appInstances;
    my $rcmapReturn = 0;

    print "\nExecuting isRealmToCommunityMapUpToDate  on  bucket $bucket node\n";
    my ($ret,$failedNodesRef,$result) = $self->executeDirectAction('isRealmToCommunityMapUpToDateURL', \@expectedResponse,\@appInstancesInBucket1);

    my @failedNodes = @{$failedNodesRef};
    print "failed nodes while fetching RCMap version : @failedNodes\n" if($ret == -1);

    #if $result is OK - No change is RC Mapping, BucketState and Community tables are in Sync,
    #No need to execute any special steps.
    #if $result is NOTUPDATED - RC Mapping has changed.BucketState and Community tables are NOT in Sync,
    #Need to execute special steps.
    
    $rcmapReturn = 1 if(defined($result) && ($result =~ m/NOTUPDATED/i));
   
    return $rcmapReturn;
}


sub executeDAonQueueManagerNode {

    my ($self,$bucket,$directAction,$expectedResponse) = @_;
    
    push(my @expectedResponse,$expectedResponse);
    my $product  = $self->newProduct();
    my @appInstances = $product->appInstances();
    my @appInstancesInBucket = grep { $_->recycleGroup() == $bucket } @appInstances;
    my @qmInstancesInBucket = grep { $_->logicalName() =~ /Manager/i } @appInstancesInBucket;

    print "\nExecuting $directAction  on bucket $bucket node\n";

    ### Attempt DA on QM nodes 3 times to avoid err-ing on transient failures
    my $retryCount=3;
    my $ret;
    my $remainingNodesRef;
    for (my $count = 0; $count < $retryCount; $count++) {
        ($ret,$remainingNodesRef) = $self->executeDirectAction($directAction, \@expectedResponse,\@qmInstancesInBucket,'executeOnAllAppInstanes');
        last if($ret != -1);
        print "remaining nodes while executing $directAction on QMs : @{$remainingNodesRef} , attempt: " . ($count+1) . " \n";
        my @remainingInstances = ();
        foreach my $remainingNode (@$remainingNodesRef) {
            push(@remainingInstances,grep { $_->logicalName() =~ /$remainingNode/i } @appInstancesInBucket);
        }
        @qmInstancesInBucket = @remainingInstances;
    }

    print "failed nodes while executing $directAction on QMs : @{$remainingNodesRef}\n" if($ret == -1);
    return $ret;
}

sub updateClusterTransitionTab {
    
    my ($self,$bucket,$directAction,$expectedResponse) = @_;
    
    push(my @expectedResponse,$expectedResponse);
    my $product  = $self->newProduct();
    my @appInstances = $product->appInstances();
    my @appInstancesInBucket = grep { $_->recycleGroup() == $bucket } @appInstances;

    print "\nExecuting $directAction  on $bucket bucket node\n";
    my ($ret,$failedNodesRef) = $self->executeDirectAction($directAction, \@expectedResponse,\@appInstancesInBucket);
   
    my @failedNodes = @{$failedNodesRef};
    print "failed nodes while updating ClusterTransition : @failedNodes\n" if($ret == -1);

    return $ret;
}

sub hasTopologyChangedInBuilds {
    
    my $self       = shift;
    my $oldProduct = shift;
    my $newProduct = shift;
    return if ($oldProduct->name() eq 'mon');

    my $oldexe = $oldProduct->installDir() . "/bin/print-topology";
    my $newexe = $newProduct->installDir() . "/bin/print-topology";

    if( -x $oldexe && -x $newexe ) {
        my $oldLayoutString = "";
        my $newLayoutString = "";
        open(F, "$oldexe |");
        while(my $line = <F>) { $oldLayoutString .= $line if($line =~ /in bucket \d+$/); }
        close(F);

        open(F, "$newexe |");
        while(my $line = <F>) { $newLayoutString .= $line if($line =~ /in bucket \d+$/); }
        close(F);
        if($oldLayoutString eq "" || $newLayoutString eq "") {
                print "control-deployment failed to get the layout of one or more of the\n";
                return 0;
        }
        if($oldLayoutString ne $newLayoutString) {
                print "Instances have changed\n";
                return 1;
        }
    }
}

sub performPreCheck {
   
    my $self = shift;
    my $cluster = shift;
    my $action = shift;
    my $oldProduct = $self->{"oldProduct"};
    my $newProduct = $self->{"newProduct"};

    my $preCheckReturn = ariba::Ops::PreCheck::performPreCheck($oldProduct,$newProduct);
    return ($preCheckReturn);
}

sub generateTopology {
 
    my $self = shift;
    my $cluster = shift;
    my $action = shift;

    my $newProduct = $self->newProduct();
    my $productName = $newProduct->name();
    my $serviceName = $newProduct->service();

    my $master = ariba::rc::Passwords::lookup('master');
    my $rootDir = ariba::rc::Globals::rootDir('ssws', $serviceName);
    my $newBuildName = $newProduct->buildName();
    my $oldBuildName = $self->oldProduct()->buildName();
    
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
    for my $host (@webServerHosts) {
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

sub canTMHandleTopoChange {
    my $self = shift;
    return  1;
}

sub mclid {
    my $self = shift;
    my $event = shift;
    my $mclId="";

    if ((lc($event) eq lc("bucket0StartFailed")) ||(lc($event) eq lc("postBucket0stop")) ) {
       $mclId = "DC-RU-RollBack-mcl" if($self->{hasTopologyChanged});
       $mclId = "DC-RR-RollBack-mcl" if($self->{hasRCMappingChanged});
    }
    else {
       $mclId = "DC-RU-RollForward-mcl" if($self->{hasTopologyChanged});
       $mclId = "DC-RR-RollForward-mcl" if($self->{hasRCMappingChanged});
    }
  
    return $mclId;
}

sub initialize {
    my $topologyManagerClass = shift;
    my $oldProduct = shift;
    my $newProduct = shift; 
    my $baseTMonly = shift;
    
    my ($oldTmName,$oldTopologyChangeSupported,$oldV5Layout,$newTmName,$newTopologyChangeSupported,$newV5Layout);
    my $isSuccess = 0;
 
    if(defined($oldProduct)){
        $oldTmName = $oldProduct->default('Ops.Topology.TopologyManager')||'' ;
        $oldTopologyChangeSupported = $oldProduct->default('Ops.TopologyChangeSupported')||'' ;
        $oldV5Layout = $oldProduct->isLayout(5);
    } 

    if(defined($newProduct)){
        $newTmName = $newProduct->default('Ops.Topology.TopologyManager')||'' ;
        $newTopologyChangeSupported = $newProduct->default('Ops.TopologyChangeSupported')||'' ;
        $newV5Layout = $newProduct->isLayout(5);
    }
    #instantiation of TopologyManager if oldbuild and newbuild are -
    #on V5 layout
    #topologychange supported
    #TopologyManager class is same for both build in P.table
    $isSuccess = 1 if(($oldTopologyChangeSupported && ($oldTopologyChangeSupported eq "true"))&&
        ($oldV5Layout)&&
        ($newTopologyChangeSupported && ($newTopologyChangeSupported eq "true"))&& 
        ($newV5Layout)&&
        ($newTmName && $oldTmName &&($oldTmName eq $newTmName))&&
        (!$baseTMonly));

    return $isSuccess;
}

1;
