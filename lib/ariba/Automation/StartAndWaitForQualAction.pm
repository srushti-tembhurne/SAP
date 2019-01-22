package ariba::Automation::StartAndWaitForQualAction;

use warnings;
use strict;

use ariba::Automation::Action;
use base qw(ariba::Automation::Action);
use ariba::Ops::Url;
use ariba::Automation::Utils;
use ariba::Ops::ProcessTable;                            
use ariba::Ops::QualManager;
use ariba::Ops::Logger; 
use ariba::Ops::Constants;
use ariba::rc::dashboard::Client;
use ariba::rc::InstalledProduct;
use XML::Simple;
use Data::Dumper;

my $logger = ariba::Ops::Logger->logger();


my $logLocation="";

sub constructURL {
  
   my ($class,$logname,$logdirectory,$robotname) = @_;
   my $rootPath = "http://nashome.ariba.com/"."\~$robotname/"."logs/"."$logdirectory/"."$logname";
   return $rootPath;
}


sub validFields {
	my $class = shift;

	my $fieldsHashRef = $class->SUPER::validFields();

	$fieldsHashRef->{'productName'} = 1;
	$fieldsHashRef->{'timeToWait'} = 1;
	$fieldsHashRef->{'qualType'} = 1;
	$fieldsHashRef->{'components'} = 1;
	$fieldsHashRef->{'keywordFilter'} = 1;
	$fieldsHashRef->{'emailTo'} = 1;
	$fieldsHashRef->{'emailFrom'} = 1;

	return $fieldsHashRef;

}

sub execute {
	my $self = shift;

	my $logPrefix = $self->logPrefix();

	my $service = ariba::Automation::Utils->service();

	my $productName = $self->productName();
	my $qualType = $self->qualType();
	my $components = $self->components();
	my $keywordFilter = $self->keywordFilter();
	my $emailTo = $self->emailTo();
	my $emailFrom = $self->emailFrom();
    my $client = new ariba::rc::dashboard::Client();
	
	my $globalState = ariba::Automation::GlobalState->newFromName($self->SUPER::attribute("robotName"));
	my $logName = $globalState->logFile();
	my $logDirectory = $globalState->logDir();
	my $robotName    = $self->robotName();
	my $logLocation  = $self->constructURL($logName,$logDirectory,$robotName);
	
	
	# We should always send out qual failure results
	$self->setNotifyOnFailure(1);

	# Clear the testId for each run so we don't remember the last one.
	$self->setQualTestId(undef);

	$logger->info("$logPrefix Kicking off " . ($components?"partial ($components) ":'') . "$qualType for $productName" .
	    ($keywordFilter?" with keyword filter $keywordFilter":''));
	
	unless (ariba::rc::InstalledProduct->isInstalled($productName, $service)) {
		$logger->error("'$productName' is not installed, cannot run qual");
		$self->setActionError(1);
		return;
	}

	my $product = ariba::rc::InstalledProduct->new($productName, $service);

	# this also appears in ariba::Ops::Startup::TestServer;
	# should probably be located in something like
	# ariba::rc::TestServerAppInstance
	my $logsDir = $product->default('System.Logging.DirectoryName');
	my $testReportLink = ariba::Automation::Constants::baseRootDirectory() . "/" . ariba::Automation::Constants::testReportDirectory() . "-$productName";

	my $shouldTry = 1;

	if (-e $testReportLink) {
		if (-l $testReportLink) {

			unless (unlink($testReportLink)) {
				$logger->warn("Failed to remove old link $testReportLink : $!");
				$logger->warn("test reports may not be accessable via nashome.ariba.com");
				$shouldTry = 0;
			}

		} else {
			$logger->warn("$testReportLink exists and is not a symlink, cannot create symlink for nashome access");
			$shouldTry = 0;
		}
	}

	unless ($shouldTry && symlink($logsDir, $testReportLink)) {
		$logger->warn("Failed to create link $testReportLink : $!");
		$logger->warn("test reports will not be accessable via nashome.ariba.com until this exists");
	}

       if ( $productName eq "an" && $qualType eq "BQ" )  { 
        my $qualResult = $self->runAnBQTests($product);
        return $qualResult;
       } # end of an changes
	
        my $qual = ariba::Ops::QualManager->new($productName, $service, $qualType, $components, $keywordFilter);

	$qual->lockSystemAccess();
	

	my $testId = $qual->kickOffQualAndGetTestId();

	unless ($testId) {
		$self->setActionError(1);
		$qual->unlockSystemAccess();
	    $client->fail ($product->buildName(), 'robot-bq', $logLocation, $productName, undef, undef, $service );
		return;
	}

	$self->setQualTestId($testId);
	$logger->warn("qual object testid: " . $self->qualTestId());

        my $timeToWait = $self->timeToWait();
        unless ( $timeToWait ) {
                $timeToWait = 4*60*60 if $qualType eq "BQ";
                $timeToWait = 35*60*60 if $qualType eq "LQ";
        }
	my $timeWaited = 0;
	my $sleepTime = 60;
	my $isQualPhaseDone;
        my $startTime = time();
	my ($diff, @chunks);

	while ( $timeWaited < $timeToWait) {
		$isQualPhaseDone = $qual->isQualPhaseDone($testId);
		if ( !defined ($isQualPhaseDone) ) {
			$self->setActionError(1);
			$qual->unlockSystemAccess();
			return;
		}

		last if $isQualPhaseDone;

		# show elapsed time
		$diff = ariba::Automation::Utils::elapsedTime (time() - $startTime);
		@chunks = split /,/, $diff;

		# remove seconds from display
		if ($#chunks > 0 && substr ($chunks[$#chunks], -1, 1) eq "s") {
			pop @chunks;
			$diff = join ",", @chunks;
		}
		# don't print anything if we haven't slept long enough
		if ($diff eq "n/a") {
			$diff = "";
		} else {
			$diff = " ($diff)";
		}
		$logger->info("DA to qual is still running, sleeping $sleepTime seconds to check again$diff");
		sleep $sleepTime;
		$timeWaited += $sleepTime;
	}

	if (!$isQualPhaseDone) {
		$logger->error("qual $qualType timed out after " . 
			ariba::Ops::DateTime::scaleTime($timeWaited) . 
			" .");
		$self->setActionError(1);
		$qual->unlockSystemAccess();
	    $client->fail ($product->buildName(), 'robot-bq', $logLocation, $productName, undef, undef, $service );
		return;
	} 

	my $qualStatus = $qual->isQualSuccessfull($testId);

	#
	# record some details in global state for 
	# BQ - LQ hookup
	#
	$globalState = ariba::Automation::GlobalState->newFromName($self->SUPER::attribute("robotName"));

	my $lastStatus = $globalState->qualStatus();

	if (!defined($lastStatus) || $lastStatus ne $qualStatus) {
		$globalState->setQualStatusChangeTime(time());
	}
	$globalState->setQualStatus($qualStatus);
	$globalState->setQualBuildName($product->buildName());
	$globalState->setQualProductName($product->name());

	# 
	# refresh list of latest qual IDs, to display links
	# on robot king page
	#
	my @qualIds = $qual->listQualTestIDs();
	@qualIds = @qualIds[0..3] if (scalar(@qualIds) > 4);
	$globalState->setLatestQualIds(@qualIds);

	$qual->unlockSystemAccess();

	if ($qualStatus) {
		$logger->info("qual $qualType finished successfully with no errors or failures");
	    $client->success( $product->buildName(), 'robot-bq', $logLocation, $productName, undef, undef, $service );
		return 1;
	} else {
		$logger->info("qual $qualType NOT successfull, DA returned: " . $qual->qualStatus());
	    $client->fail ($product->buildName(), 'robot-bq', $logLocation, $productName, undef, undef, $service );
		return 0;
	}			
}

sub attachment {
	my $self = shift;

	my $qualOutputDir = $self->_qualOutputDir();
	return unless $qualOutputDir;
	my $qualStatusFile = $qualOutputDir . "/" .  "runtests.output.all.email.html";

	return $qualStatusFile;
}

sub notifyMessage {
	my $self = shift;
	my $htmlEmail = shift;
	$htmlEmail = $htmlEmail || "text";

	my $qual = ariba::Ops::QualManager->new($self->productName(), ariba::Automation::Utils->service(), $self->qualType());
	my $testId = $self->qualTestId();
	return if (! $testId);
	$qual->getQualDetailedSummaryForEmail($testId, $htmlEmail ? "html" : "text");
	my $summary = $qual->emailSummary();
	$summary = "----\n" . $summary if ($summary && $htmlEmail eq "text");	
	return ($summary);
}

sub _qualOutputDir {
    my $self = shift;

	return unless $self->qualTestId();

	my $service = ariba::Automation::Utils->service();
	my $productName = $self->productName();
	unless (ariba::rc::InstalledProduct->isInstalled($productName, $service)) {
		$logger->error("'$productName' is not installed, add attachment");
		return;
	}

	my $product = ariba::rc::InstalledProduct->new($productName, $service);
	my $outputDir = $product->default("System.Logging.DirectoryName") . "/" .  $self->qualTestId();

	return $outputDir;
}


sub runAnBQTests {
   my $self = shift;
   my $product = shift;
   my $anBuildName = $product->buildName();  
   my $service = ariba::Automation::Utils->service();
   my $productName = $self->productName();

   unless ($product->deploymentDefaults()) {
   print "ERROR: Could not find defaults for $productName or an for service $service\n";
   return 0;
   	} 


	my $testServerURL = $product->default('TestAutomation.Selenium.TestServerUrl'); 
	my $testResultDir = $product->default('TestAutomation.ReportDir');
    print "\nStarting EDI tests ...";
	my $ediTestResult = $self->runEdiTests($testServerURL,$testResultDir,$anBuildName);
   if ($ediTestResult == 0 ) {
   print "\n EDI tests for $anBuildName failed!!";
   return 0;
   }

   print "\nStarting AN tests ...";
   my $anTestResult = $self->runAnTests($testServerURL,$testResultDir,$anBuildName);
   if ($anTestResult == 0 ) {
   print "\n AN tests for $anBuildName failed!!";
   return 0;
   }

 return 1;

 }
 
 
 sub runEdiTests {
 my ($self,$testServerURL,$testResultDir,$anBuildName) = @_;
      my $UrlToRun = "$testServerURL". '/TestRunner.aw/ad/runTests?qual=BQ&component=edi';
      my $result = $self->runUrlAndGetResult($testResultDir,$anBuildName,$UrlToRun);
	  
	return $result;
 }

 sub runAnTests{
 my ($self,$testServerURL,$testResultDir,$anBuildName) = @_;
      my $UrlToRun = "$testServerURL". '/TestRunner.aw/ad/runTests?qual=BQ&component=an';
      my $result = $self->runUrlAndGetResult($testResultDir,$anBuildName,$UrlToRun);
	  
	return $result;
 }


sub runUrlAndGetResult{
my ($self,$testResultDir,$anBuildName,$UrlToRun) = @_;
	my $timeout = 1000;
	my $urlObj = ariba::Ops::Url->new($UrlToRun);
	$urlObj->setUseOutOfBandErrors(1);
	my $results = $urlObj->request($timeout);
	chomp($results);    
	my $finalResDir = "$testResultDir/$anBuildName/$results"; 
	sleep(10); 

	unless (-d "$finalResDir"){
     print "Error : No result dir found : $finalResDir \n";
     return 0;
     }

     #search for the result file 

    my $time = 0;
    $timeout = 35*60*60;
    my $sleepAn = 60;
    my $resultXml =  "$finalResDir/runtests.output.all.xml";

    while ( $time < $timeout){
    last if( -f "$resultXml");
    sleep($sleepAn);
    $time += $sleepAn;
     }
 
 
    if ( -f "$resultXml") {
	   #    print " EDI Qual Results available";
	   # create object
	   my $xml = new XML::Simple;
	   # read XML file
	   my $data = $xml->XMLin("$resultXml");
		 my $noFailures = $data->{Product}->{nbFailures};
		 if ( $noFailures == 0 ){
			print "EDI tests passed";
			return 1;
		  } else { 
			print "No of test  Failures : " . $data->{Product}->{nbFailures};
			return 0;
		  }
  
     } else {
		print "Qual Failed";
		return 0;
    }

return 0;

}

1;
