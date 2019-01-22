package ariba::Ops::QualManager;

use warnings;
use strict;

use Carp;

use ariba::Ops::PersistantObject;
use ariba::Ops::DateTime;
use base qw(ariba::Ops::PersistantObject);

use ariba::Ops::Logger;
use ariba::Ops::Url;
use ariba::rc::InstalledProduct;
use ariba::rc::Globals;
use ariba::Ops::DateTime;
use ariba::Ops::Utils;
use ariba::rc::dashboard::Client;
use Data::Dumper;

use XML::Simple;
use XML::XPath;
use XML::XPath::XMLParser;
use Sys::Hostname;

my $logger = ariba::Ops::Logger->logger();
my $client = new ariba::rc::dashboard::Client();

sub new {
    my $class          = shift;
    my $productName    = shift;
    my $service        = shift;
    my $qualType       = shift;
    my $components     = shift;
    my $keywordFilter  = shift;
    my $migrationMode  = shift;
    my $executionPhase = shift;
    my $recipients     = shift;
    my $sender         = shift;
    my $cdsService     = shift;
    my $delayTime      = shift;

    my $self = $class->SUPER::new( 'qual' );
    $self->setProductName( $productName );
    $self->setService( $service );
    $self->setQualType( $qualType );
    $self->setComponents( $components )         if $components;
    $self->setKeywordFilter( $keywordFilter )   if $keywordFilter;
    $self->setMigrationMode( $migrationMode )   if $migrationMode;
    $self->setExecutionPhase( $executionPhase ) if $executionPhase;
    $self->setRecipients( $recipients )         if $recipients;
    $self->setSender( $sender )                 if $sender;
    $self->setCdsService( $cdsService )         if $cdsService;
    $self->setDelayTime( $delayTime )           if $delayTime;

    # Populating the Object with Extra values. We needs these values
    # for RC DB and creating the same object all the time, I have set
    # those values in the default object of Qual Manager. It should
    # NOT break anything theoritically.
    my $installedProduct = ariba::rc::InstalledProduct->new( $productName, $service );
    $self->setBuildName( $installedProduct->buildName() )     if ( defined ( $installedProduct ) );
    $self->setBranchName( $installedProduct->branchName() )   if ( defined ( $installedProduct ) );
    $self->setReleaseName( $installedProduct->releaseName() ) if ( defined ( $installedProduct ) );

    # remove self from PO cache here to avoid problems later with
    # saved state across instances
    $self->remove();

    return $self;
}

sub checkBuyerCatalogIndexPublish {
    my $self = shift;

    # Only check for buyer
    return 1 unless $self->productName eq "buyer";

    my $testServerInstance = $self->_getTestServerAppInstance();

    # Invalidating Search Versions will force the immediate reindexing
    # rather than waiting for 30 mins before starting it.
    my $invalidateBuyerCatalogSearchVersionsURL = $testServerInstance->invalidateBuyerCatalogSearchVersionsURL();
    $logger->info( "Invalidating Buyer Catalog search versions..." );

    my $status = $self->_hitDA( $invalidateBuyerCatalogSearchVersionsURL, 5 * 60 );
    if ( $status ) {
        $logger->info( "Invalidating Buyer Catalog search versions returned '$status'." );
    } else {
        $logger->info( "Invalidating Buyer Catalog search versions did not return a valid status. Unsupported?" );
    }

    my $buyerCatalogPublishStatusDA = $testServerInstance->buyerCatalogIndexPublishStatus();

    # This will block for up to 30 minutes waiting for the index rebuild to finish
    $logger->info( "Checking to status of Buyer Catalog Publish status.  This  can take up to 30 mins..." );

    ## Valid states returned from the DA:
    ## PublisherWaiting: Success
    ## PublisherWaitingAfterFailedAttempt: Errors during publishing and the publisher is not retrying
    ## PublisherWaitingNoAuto: This state is only for CD versions of the product
    ## anything else: failure

    $status = undef;
    for my $i ( 1 .. 3 ) {
        $status = $self->_hitDA( $buyerCatalogPublishStatusDA, 35 * 60 );
        $logger->info( "Buyer Catalag Publish status DA returned '$status'" );

        last if $status eq "PublisherWaiting" or $status eq "PublisherWaitingAfterFailedAttempt";
        sleep 5;
    }

    if ( !$status || $status !~ /Publisher/ ) {
        $logger->info( "DA did not return a valid status which probably means this is an older buyer build, returning success" );
        return 1;
    }

    return unless $status eq "PublisherWaiting";

    return 1;
}

my $MAX_TIME_TO_WAIT_FOR_POSTTASKS = 3 * 60 * 60;    # in seconds. Bumping up for 13s1. Revisit this and make it a configurable. Now bumping up for 13s2
my $POST_MIGRATION_URL_TIMEOUT     = 20;
my $MAX_TIME_TO_WAIT_FOR_ALL_NODES = 2 * 60;         #  We'll update this with a reliastic number once the DA is implemented
my $MAX_TIME_TO_WAIT_FOR_PRELQ     = 30 * 60;        # We'll update this with a reliastic number once the DA is implemented

my $MIG_STATUS_FAILED      = "Failed";
my $MIG_STATUS_SUCCESS     = "Completed";
my $MIG_STATUS_RUNNING     = "Running";
my $MIG_STATUS_NOT_STARTED = "Not Started";

sub checkPostMigrationTasks {
    my $self = shift;

    my $testServerInstance     = $self->_getTestServerAppInstance();
    my $migrationTaskStatusURL = $testServerInstance->canStartQualURL();

    unless ( $migrationTaskStatusURL ) {
        $logger->info( "This application does not implement migration Task status, skipping" );
        return 1;
    }

    #
    # TEMP: Add 2 Hrs to the max time out if this is LQ
    # We have open task with us to parameterize the timeout value.
    #
    my $maxTimeout = $MAX_TIME_TO_WAIT_FOR_POSTTASKS;
    if ( lc ( $self->qualType() ) eq "lq" ) {
        $maxTimeout = 2 * 60 * 60 + $maxTimeout;
    }
    my $endTime = time () + $maxTimeout;

    $logger->info( "Checking status of migration post-tasks, will wait up to " . ariba::Ops::DateTime::scaleTime( $maxTimeout ) );

    my $migTaskStatus;
    my $migTaskInfo;

    while ( time () < $endTime ) {
        my $xmlString = $self->_hitDA( $migrationTaskStatusURL, $POST_MIGRATION_URL_TIMEOUT );

        if ( $xmlString ) {
            my $xs        = XML::Simple->new();
            my $xmlResult = $xs->XMLin( $xmlString );

            if ( ref ( $xmlResult ) ) {
                $migTaskStatus = $xmlResult->{ 'status' };
                $migTaskInfo   = $xmlResult->{ 'Task-Info' };
            }

            if ( $migTaskStatus ) {

                my $prevStatus = $self->migTaskStatus();
                if ( !$prevStatus || $prevStatus ne $migTaskStatus ) {
                    $logger->info( "migration task status updated to $migTaskStatus" );
                }

                $self->setMigTaskStatus( $migTaskStatus );

                if ( lc ( $migTaskStatus ) eq lc ( $MIG_STATUS_FAILED ) ) {
                    $logger->error( "Some migration tasks have failed!" );
                    $logger->error( $migTaskInfo ) if ( $migTaskInfo );
                    return;

                } elsif ( lc ( $migTaskStatus ) eq lc ( $MIG_STATUS_SUCCESS ) ) {
                    $logger->info( "All migration tasks report success" );
                    return 1;

                }
            } elsif ( $xmlString =~ /HTTP 404: Not Found Error/ ) {
                $logger->warn( "Post-task DA at $migrationTaskStatusURL not implemented, continuing with qual" );
                return 1;
            } else {
                $logger->error( "Error parsing status from post migration DA: $xmlString" );
                return;
            }
        }
        sleep 60;
    }

    # getting here means we timed out waiting on status=Running  or
    # status=not_started
    $logger->error( "Timed-out waiting for post migration tasks after " . ariba::Ops::DateTime::scaleTime( $MAX_TIME_TO_WAIT_FOR_POSTTASKS ) . ", last result from DA was: $migTaskStatus" );
    $logger->error( $migTaskInfo ) if ( $migTaskInfo );
    return;
}

sub lockSystemAccess {
    my $self = shift;
    return $self->_systemAccess( 'lock' );
}

sub unlockSystemAccess {
    my $self = shift;
    return $self->_systemAccess( 'unlock' );
}

sub systemAccessStatus {
    my $self = shift;
    return $self->_systemAccess( 'status' );
}

sub _systemAccess {
    my $self   = shift;
    my $action = shift;

    my $testServerInstance = $self->_getTestServerAppInstance();
    my $systemAccessURL;
    if ( $action eq 'lock' ) {
        $systemAccessURL = $testServerInstance->testSystemAccessLockURL();
    } elsif ( $action eq 'unlock' ) {
        $systemAccessURL = $testServerInstance->testSystemAccessUnlockURL();
    } elsif ( $action eq 'status' ) {
        $systemAccessURL = $testServerInstance->testSystemAccessStatusURL();
    } else {
        carp "Invalid action $action";
        return;
    }

    my $results = $self->_hitDA( $systemAccessURL, 30 );

    if ( $results ) {
        if ( $results =~ m/HTTP 404/ ) {
            $logger->warn( "SystemLock $action attempt failed with 404, not supported?" );
            return;
        } elsif ( $results =~ m/^ok/i ) {
            $logger->info( "SystemLock $action attempt succeeded" );
        } else {
            $logger->info( "SystemLock $action attempt returned with $results" );
        }
    } else {
        $logger->info( "SystemLock $action attempt failed, node is down/unreachable ?" );
        return;
    }

    return 1;
}

sub isReadyForQual {
    my $self      = shift;
    my $preQualDA = 0;

    # Kick off mon checks only for LQ
    if ( lc ( $self->qualType() ) eq "lq" ) {
        unless ( $self->checkMonData() ) {
            $logger->error( "Mon checks DA failed. Cannot kick off " . $self->qualType() );
            return 0;
        }
    }

    # Check the status of Pre Qual DA. Failure => 0, Success => 1, Not Implemented => 2
    $preQualDA = $self->checkPreQualData();

    if ( $preQualDA == '2' ) {
        # Falling back to old style DAs
        $logger->warn( "PreQual DA is not implemented. Continuing with Old DAs..." );

        unless ( $self->checkBuyerCatalogIndexPublish() ) {
            $logger->error( "Buyer Catalog rebuild failed, cannot kick off qual" );
            return 0;
        }

        unless ( $self->checkPostMigrationTasks() ) {
            $logger->error( "Error running post-migration tasks, cannot kick-off qual" );
            if ( $self->migTaskStatus() ) {
                $logger->error( "last post-migration status was:" . $self->migTaskStatus() );
            } else {
                $logger->error( "No status available for post-migration tasks (something wrong with DA)?" );
            }

            return 0;
        }

        unless ( $self->areAllNodesUp() ) {
            $logger->error( "Check for areAllNodesUp DA failed. Cannot kick-off LQ" );
            return 0;
        }
    } elsif ( !$preQualDA ) {
        $logger->error( "Pre Qual Check DA failed. Cannot kick-off " . $self->qualType() );
        return 0;
    }

    unless ( $self->checkCDSIntegratedProduct() ) {
        $logger->error( "CDS integrated product check failed, cannot kick-off qual" );
        return 0;
    }

    return 1;
}

sub generateStackDiffReport {
    my $self   = shift;
    my $product = shift;
    my $service = shift;
    my $testId = shift;
    my $installDir = shift;
    my $outputDir = shift;
    my $useLastRunAsBase = shift;

    if (!($product eq "buyer" || $product eq "s4")) {
        $logger->info("Stack diff report generation is not supported for product $product");
        return 0;
    }
    my $scriptLoc = "$installDir/internal/bin/reportstacks.pl";
    unless (-e $scriptLoc) {
        $logger->info("Cannot find reportstacks script at $scriptLoc. Will not run stack diff command");
        return 0;
    }

    # the testid is the unix time at which the qual was kicked off. This is in millis. Convert to seconds and get the date
    my ($sec,$min,$hour,$day,$month,$year) = localtime($testId / 1000);
    my $startDate = sprintf("%02d/%02d/%04d:%02d:%02d", $month+1, $day, $year+1900, $hour, $min);
    my $cmd = "$installDir/internal/bin/reportstacks.pl -product $product -service $service -startDate $startDate -outputDir $outputDir -installDir $installDir";
    if ($useLastRunAsBase) {
        $cmd = $cmd . " -useLastRunAsBase";
    }
    my $cmdOutput = "$outputDir/reportstacks_$testId.out";
    $cmd = $cmd . " > $cmdOutput &";
    my $host = hostname();
    $logger->info("Host -> $host, testId -> $testId running stackdiff command in background > $cmd");
    system($cmd);
    return 1;
}

sub kickOffQualAndGetTestId {
    my $self   = shift;
    my $testId = shift;

    # Fetching all the values for populating RC DB
    my $productName = $self->productName();
    my $serviceName = $self->service();
    my $qualType    = $self->qualType();
    my $releaseName = $self->releaseName();
    my $buildName   = $self->buildName();
    my $branchName  = $self->branchName();
    my $logfile     = $self->logFile();

    # Start the run to populate Pre Qual Action in RC DB
    $client->running( $buildName, "PreQual-$qualType", $logfile, $productName, $branchName, $releaseName, $serviceName );

    if ( !$self->isReadyForQual() ) {
        $client->fail( $buildName, "PreQual-$qualType", $logfile, $productName, $branchName, $releaseName, $serviceName );
        return;
    }

    # Completed the PreQual Run and populate the RC DB
    $client->success( $buildName, "PreQual-$qualType", $logfile, $productName, $branchName, $releaseName, $serviceName );

    # Hack for SSP only
    my $delayTime = $self->delayTime() || 0;
    $delayTime = $delayTime * 60;

    if ( defined ( $delayTime ) and $delayTime > 0 ) {
        $logger->info( "Sleeping for next $delayTime seconds..." );
        # If the delay for SSP is present via Auto LQ, then log it into RC DB
        $client->running( $buildName, "PreQual-Delay-$qualType", $logfile, $productName, $branchName, $releaseName, $serviceName );
        sleep ( $delayTime );
        $client->success( $buildName, "PreQual-Delay-$qualType", $logfile, $productName, $branchName, $releaseName, $serviceName );
    }

    # Start the Qualification for RC DB
    $client->running( $buildName, "Qualification-$qualType", $logfile, $productName, $branchName, $releaseName, $serviceName );

    my $testServerInstance = $self->_getTestServerAppInstance();
    my $runQualDA = $testServerInstance->testServerRunQual( $self->qualType(), $self->components(), $self->keywordFilter(), $testId, $self->migrationMode(), $self->executionPhase(), $self->recipients(), $self->sender() );

    $logger->debug( "Hitting DA '$runQualDA' to kick off " . $self->qualType() );

    $testId = $self->_hitDA( $runQualDA, 720 );

    unless ( defined $testId ) {
        $logger->error( "Direct Action to $runQualDA did not return a valid id within 360s." );
        $client->fail( $buildName, "Qualification-$qualType", $logfile, $productName, $branchName, $releaseName, $serviceName );
        return;
    }

    if ( $testId !~ /^\d+$/ ) {
        $logger->error( "Direct Action to $runQualDA did not return a valid id: '$testId'" );
        $client->fail( $buildName, "Qualification-$qualType", $logfile, $productName, $branchName, $releaseName, $serviceName );
        return;
    }

    $logger->debug( "DA returned the test id: '$testId'" );

    return $testId;
}

sub qualPhase {
    my $self   = shift;
    my $testId = shift;

    my $testServerInstance = $self->_getTestServerAppInstance();
    my $qualDA = $testServerInstance->testServerCheckQualPhase( $testId, $self->executionPhase() );

    $logger->debug( "Hitting DA '$qualDA' to check if phase qual is done" );
    my $results = $self->_hitDA( $qualDA, 90 ) || "";
    unless ( $results =~ /^(Starting|Preparing|Running|Finishing|Done)$/ ) {
        $logger->error( "Unknown test phase state: '$results'" );
        return;
    }

    $logger->debug( "Qual is currently in phase: $results" );
    $self->setQualPhaseDone( 1 ) if $results eq "Done";

    return $results;
}

sub isQualPhaseDone {
    my $self   = shift;
    my $testId = shift;

    if ( $self->qualPhaseDone() ) {
        return 1;
    } else {
        my $qualPhase = $self->qualPhase( $testId );
        return unless $qualPhase;
        if ( $qualPhase eq "Done" ) {
            return 1;
        } else {
            return 0;
        }
    }
}

sub isQualSuccessfull {
    my $self   = shift;
    my $testId = shift;

    my $testServerInstance = $self->_getTestServerAppInstance();
    my $qualDA = $testServerInstance->testServerCheckQualStatus( $testId, $self->executionPhase() );

    $logger->debug( "Hitting DA '$qualDA' to check qual status" );
    my $results = $self->_hitDA( $qualDA, 90 );

    $self->setQualStatus( $results );

    if ( $results eq "Ok" ) {
        $logger->debug( "Qual finished with status 'Ok'" );
        return 1;
    } else {
        $logger->debug( "Qual finished with not 'Ok' status: '$results'" );
        return 0;
    }
}

sub listQualTestIDs {
    my $self = shift;

    my $productName = $self->productName();
    my $service     = $self->service();

    my $product = ariba::rc::InstalledProduct->new( $productName, $service );
    unless ( $product ) {
        $logger->error( "Could not build product instance for listQualTestIDs()" );
        return;
    }
    my $resultsDir = $product->default( "System.Logging.DirectoryName" );

    my @idList;

    $logger->info( "Looking in $resultsDir" );

    if ( !opendir DIR, $resultsDir ) {
        $logger->error( "Can't open product directory $resultsDir: $!" );
        return;
    }

    my @files = readdir ( DIR );
    closedir DIR;

    foreach my $file ( @files ) {
        next unless $file =~ m/^(\d+)$/;

        push @idList, $file;
    }

    @idList = sort { $b <=> $a } @idList;

    return @idList;
}

sub parseQualResultsFile {
    my $self   = shift;
    my $testId = shift;

    my $productName = $self->productName();
    my $service     = $self->service();

    my $product = ariba::rc::InstalledProduct->new( $productName, $service, undef, undef );
    unless ( $product ) {
        $logger->error( "Could not build product instance." );
        return;
    }

    my $qualStatusFile =
      $product->default( "System.Logging.DirectoryName" ) . "/" . $testId . "/" . ( defined ( $self->executionPhase() ) ? $self->executionPhase() . "/" : "" ) . "runtests.output.all.xml";

    $logger->debug( "XML Path is: $qualStatusFile" );

    unless ( -f $qualStatusFile ) {
        $logger->error( "Qual status file '$qualStatusFile' doesn't exist" );
        return;
    }

    my $qualStatus;
    eval { $qualStatus = XMLin( $qualStatusFile, KeyAttr => [ 'Name' ], ForceArray => 1 ); };
    
    if ( $@ ) {
        $logger->error( "XMLin could not parse the '$qualStatusFile'. Something wrong with the XML file" );
        return;
    }
    
    if ( !$qualStatus || !$qualStatus->{ 'Product' } ) {
        $logger->error( "Could not parse '$qualStatusFile'" );
        return;
    }

    $self->setQualNbTests( $qualStatus->{ 'Product' }->{ $productName }->{ 'nbTests' } );
    $self->setQualNbErrors( $qualStatus->{ 'Product' }->{ $productName }->{ 'nbErrors' } );
    $self->setQualNbFailures( $qualStatus->{ 'Product' }->{ $productName }->{ 'nbFailures' } );
    $self->setQualNbSkipped( $qualStatus->{ 'Product' }->{ $productName }->{ 'nbSkipped' } );
    $self->setQualNbNotRun( $qualStatus->{ 'Product' }->{ $productName }->{ 'nbNotRun' } );
    $self->setQualNbPerfFailures( $qualStatus->{ 'Product' }->{ $productName }->{ 'nbPerfFailures' } );
    $self->setQualNbReRun( $qualStatus->{ 'Product' }->{ $productName }->{ 'nbReRun' } );
    $self->setQualElapsedTime( $qualStatus->{ 'Product' }->{ $productName }->{ 'TotalElapsedTime' } / 1000 );
    $self->setQualComponentsStatus( $qualStatus->{ 'Component' } );
    $self->setQualType( $qualStatus->{ 'Info' }->[ 0 ]->{ 'QUAL' } ) if ( !$self->qualType() );

    if ( lc ( $self->qualType() ) eq "lq" ) {
        my $xp;

        eval { $xp = XML::XPath->new( filename => $qualStatusFile ); };

        if ( $@ ) {
            $logger->error( "Could not parse '$qualStatusFile'" );
            return;
        }

        $logger->debug( "Calculating the Combine Passed Tests and Passrate" );

        $self->setCombinePassTest( $self->qualNbTests() - ( $self->qualNbErrors() + $self->qualNbFailures() ) - $self->qualNbSkipped() );
        $self->setCombineTotalTest( $self->qualNbTests() - $self->qualNbSkipped() );

        eval { $self->setCombinePassRate( sprintf ( "%.2f", ( ( $self->qualNbTests() - $self->qualNbErrors() - $self->qualNbFailures() - $self->qualNbSkipped() ) / ( $self->qualNbTests() - $self->qualNbSkipped()) * 100 )) ); };

        if ( $@ ) {
            $logger->error( "Could not set Overall Passed Rate: \n $@ " );
            return;
        }

        $logger->debug( 'Calculating Number of Statble Tests and Passrate' );

        my $numStable = sprintf ( "%d", $xp->find( "count(//Case[not(contains(\@Keywords,'Flaky')) and not(contains(\@Keywords,'WIP')) and not(contains(\@Keywords,'New')) and not(contains(\@Status,'SKIP')) and (contains(\@Rerun,'FALSE'))  ])" ) );
        my $passFalse = sprintf ( "%d", $xp->find( "count(//Case[not(contains(\@Keywords,'Flaky')) and not(contains(\@Keywords,'WIP')) and not(contains(\@Keywords,'New')) and (contains(\@Status,'PASS')) and (contains(\@Rerun,'FALSE'))  ])" ) );
        my $passTrue  = sprintf ( "%d", $xp->find( "count(//Case[not(contains(\@Keywords,'Flaky')) and not(contains(\@Keywords,'WIP')) and not(contains(\@Keywords,'New')) and (contains(\@Status,'PASS')) and (contains(\@Rerun,'TRUE'))  ])" ) );

        my $numStablePassTests = $passFalse + $passTrue;
        $self->setConsistentPassTest( $numStablePassTests );
        $self->setConsistentTotalTest( $numStable );

        eval { $self->setConsistentPassRate( sprintf ( "%.2f", ( ( $numStablePassTests ) / $numStable ) * 100 ) ); };

        if ( $@ ) {
            $logger->error( "Could not set Stable Pass Rate: \n $@ " );
            return;
        }

        foreach my $keyword ( 'Flaky', 'WIP', 'New' ) {
            $logger->debug( "Calculating Number of $keyword Tests and Passrate" );

            my $function = 'set' . ucfirst $keyword;
            my $numFlagTotal = sprintf ( "%d", $xp->find( "count(//Case[(contains(\@Keywords,'$keyword')) and not(contains(\@Status,'SKIP')) and (contains(\@Rerun,'FALSE'))])" ) );

            my $sub1 = $function . 'TotalTest';
            my $sub2 = $function . 'PassTest';
            my $sub3 = $function . 'PassRate';

            $self->$sub1( $numFlagTotal );

            my $numFlagRerunPassFalse = sprintf ( "%d", $xp->find( "count(//Case[contains(\@Keywords,'$keyword') and (contains(\@Status,'PASS')) and (contains(\@Rerun,'FALSE')) ])" ) );
            my $numFlagRerunPassTrue  = sprintf ( "%d", $xp->find( "count(//Case[contains(\@Keywords,'$keyword') and (contains(\@Status,'PASS')) and (contains(\@Rerun,'TRUE')) ])" ) );
            my $numFlagPassTests      = $numFlagRerunPassFalse + $numFlagRerunPassTrue;

            $self->$sub2( $numFlagPassTests );

            if ( $numFlagTotal > 0 ) {
                eval { $self->$sub3( sprintf ( "%.2f", ( ( $numFlagPassTests ) / $numFlagTotal ) * 100 ) ); };

                if ( $@ ) {
                    $logger->warn( "could not perform $function: \n $@ " );
                    return;
                }
            }
        }
    }

    $self->setQualResultsParsed( 1 );

    return 1;
}

sub printQualResults {
    my $self   = shift;
    my $testId = shift;

    $self->parseQualResultsFile( $testId ) unless $self->qualResultsParsed();

    print "Total Number of tests run: " . $self->qualNbTests() . "\n";
    print "Errors: " . $self->qualNbErrors() . "\n";
    print "Failures: " . $self->qualNbFailures() . "\n";
    print "Tests Skipped: " . $self->qualNbSkipped() . "\n";
    print "Tests Not Run: " . $self->qualNbNotRun() . "\n";
    print "Elapsed time: " . ariba::Ops::DateTime::scaleTime( $self->qualElapsedTime() ) . "\n";

    return 1;
}

sub getQualDetailedSummaryForEmail {
    my $self   = shift;
    my $testId = shift;
    my $format = shift;

    $format = "html" if ( !$format );

    my $productName = $self->productName();
    my $service     = $self->service();
    my $product     = ariba::rc::InstalledProduct->new( $productName, $service, undef, undef );

    my $summary;
    my @failedComps;
    my @passedComps;
    my $ownersOfFailedComps;
    my $formatForText;

    my $rc = 1;
    $rc = $self->parseQualResultsFile( $testId ) unless $self->qualResultsParsed();
    if ( !$rc ) {
        print "Unable to fetch qual details. \n";
        return;
    }

    $self->isQualSuccessfull( $testId );    # just to set the qualStatus
    my $qualEmailFilePath = $product->default( "System.Logging.DirectoryName" ) . "/" . $testId . "/" . "runtests.output.all.email.html";
    my $qualEmailWinPath  = $qualEmailFilePath;
    $qualEmailWinPath =~ s/\/home/file:\/\/maytag\/export\/home/;
    my $qualHttpPath = $qualEmailFilePath;
    $qualHttpPath =~ s/\/home/https:\/\/anrc.ariba.com/;
    
    # Prepare the summary
    if ( $format =~ /html/i || $format =~ /text/i) {
        $summary .= "<b>Qual Type</b>: " . $self->qualType() . "<br>";
        $summary .= "<b>Product</b>: " . $productName . "<br>";
        $summary .= "<b>Service</b>: " . $service . "<br>";
        $summary .= "<b>Overall Status</b>: " . $self->qualStatus();
        $summary .= " (" . ( $self->qualNbErrors() + $self->qualNbFailures() + $self->qualNbPerfFailures()) . " tests failed out of " . $self->qualNbTests() . ")<br>";
        $summary .= "<b>Qual Time</b>: " . ariba::Ops::DateTime::scaleTime( $self->qualElapsedTime() ) . "<br>";
        $summary .= "<b>File Path to Email Report</b>: <a href = $qualEmailWinPath>$qualEmailFilePath</a><BR>";
        $summary .= "<b>HTTP Path to Email Report </b>: <a href = $qualHttpPath>$qualHttpPath</a><BR>";
        
        # Get content of summary file and attach it to summary email body
        if(-e $qualEmailFilePath)
        {
            my @emailsummary;
            open ( EMAILSUMMARY, "<", $qualEmailFilePath )
            or ( print( "Unable to read the Email LQ Report: " . $qualEmailFilePath . "\n"), return 1 );
            push(@emailsummary, "<BR>");
            while (my $line = <EMAILSUMMARY>)  {
                last if($line =~m/\<a name="Error Tests"\>Error tests:\<\/a\>/i );
                push(@emailsummary, $line);
            }
            push(@emailsummary, "</h2></html>");
            my $emailsummarystr = join('', @emailsummary);
            close ( EMAILSUMMARY );
            $summary .= join('', @emailsummary);
        }
        else
        {
            $logger->error( "Email LQ Report Doesn't exists: " . $qualEmailFilePath);
            $summary .= "Email LQ Report Doesn't exists: " . $qualEmailFilePath;
        }
    }

    # Set the path of the email attachment
    my $qualEmailFile = $product->default( "System.Logging.DirectoryName" ) . "/" . $testId . "/" . "runtests.output.all.email.html";

    $self->setQualEmailAttachmentPath( $qualEmailFile ) if ( -e $qualEmailFile );

    $self->setEmailSummary( $summary );
    $self->setOwnersOfFailedComps( $ownersOfFailedComps );
}

sub _getTestServerAppInstance {
    my $self = shift;

    my $productName = $self->productName();
    my $service     = $self->service();

    my $product = ariba::rc::InstalledProduct->new( $productName, $service, undef, undef );
    unless ( $product ) {
        $logger->error( "Could not build product instance." );
        return;
    }

    my ( $testServerInstance ) = $product->appInstancesWithNameInCluster( 'TestServer' );
    unless ( $testServerInstance ) {
        $logger->error( "Could not find 'TestServer' appinstance" );
        return;
    }

    return $testServerInstance;
}

sub _hitDA {
    my $self    = shift;
    my $url     = shift;
    my $timeout = shift;

    my $urlObj = ariba::Ops::Url->new( $url );
    $urlObj->setUseOutOfBandErrors( 1 );
    my $results = $urlObj->request( $timeout );

    $self->lastURLError( $urlObj->error() );

    if ( !$results ) {
        $logger->error( "DirectAction to $url returned no results\n" );
        if ( $urlObj->error() ) {
            $logger->error( "DirectAction url returned error: " . $urlObj->error() );
        }

        $logger->error( "Content of request object: \n" . $urlObj->printToString() );
        return;
    }

    return $results;
}

sub checkCDSIntegratedProduct {
    my $self = shift;

    my $productName = $self->productName();
    my $service     = $self->service();
    my $cds_service = $self->cdsService();
    my $cdsIntegratedInstanceKey;
    my $cdsIntegratedProductName;

    #
    #
    # get CDS front door: for buyer product this will be ACM, for
    # s4, Buyer
    #
    if ( grep { $productName eq $_ } ariba::rc::Globals::sharedServiceSourcingProducts() ) {
        $cdsIntegratedInstanceKey = 'Buyer';
        $cdsIntegratedProductName = 'buyer';
    } elsif ( grep { $productName eq $_ } ariba::rc::Globals::sharedServiceBuyerProducts() ) {
        $cdsIntegratedInstanceKey = 'ACM';
        $cdsIntegratedProductName = 's4';
    } else {
        #
        # no need to check for products that are not buyer or ACM
        #
        $logger->warn( "Unsuported product $productName, cannot check CDS integration, continuing" );
        return 1;
    }

    my $product = ariba::rc::InstalledProduct->new( $productName, $service, undef, undef );
    unless ( $product ) {
        $logger->error( "Could not build product instance for $productName in service $service" );
        return;
    }

    my $appInfo = $product->appInfo();
    unless ( $appInfo && -f $appInfo ) {
        $logger->error( "Could not find appinfo at $appInfo" );
        return;
    }

    my $xs      = XML::Simple->new();
    my $xmlHash = $xs->XMLin( $appInfo );

    unless ( $xmlHash ) {
        $logger->error( "Failed to parse appinfo $appInfo" );
        return;
    }

    # check to see if we're integrated
    #
    my $cdsVal = $xmlHash->{ Instance }->{ $cdsIntegratedInstanceKey }->{ Param }->{ Type };
    if ( !$cdsVal ) {
        # not integrated, so just return true
        $logger->info( "$productName is not CDS integrated" );
        return 1;
    }

    my $incommingHttpServletURL = $xmlHash->{ Instance }->{ $cdsIntegratedInstanceKey }->{ Param }->{ IncomingHttpServerURL }->{ value };
    my $contextRoot             = $xmlHash->{ Instance }->{ $cdsIntegratedInstanceKey }->{ Param }->{ ContextRoot }->{ value };
    my $customerSitesURL        = "$incommingHttpServletURL/$contextRoot/Main/ad/ss";

    my $MAX_TIME_TO_WAIT_FOR_INTEGRATED_PRODUCT = 3.5 * 60 * 60;    # in seconds

    my $endTime = time () + $MAX_TIME_TO_WAIT_FOR_INTEGRATED_PRODUCT;

    $logger->info( "Checking CDS integrated site at $customerSitesURL, will wait up to " . ariba::Ops::DateTime::scaleTime( $MAX_TIME_TO_WAIT_FOR_INTEGRATED_PRODUCT ) );

    while ( time () < $endTime ) {
        my $results = $self->_hitDA( $customerSitesURL, 20 );

        if ( $results ) {
            if ( $results =~ /503 Service Temporarily Unavailable/ ) {
                # site is stil down
                #
            } else {
                # site is up
                $logger->info( "CDS integrated site is up" );
                # Now will check for all the tasks on suite integrated service to see if its ready for qual.
                if ( defined ( $cds_service ) && $cds_service ne "" ) {
                    my $cdsQual = ariba::Ops::QualManager->new(
                        $cdsIntegratedProductName, $cds_service, $self->qualType(), $self->components(),
                        $self->keywordFilter(),
                        $self->migrationMode(),
                        $self->executionPhase(),
                        $self->reportRecipients(),
                        $self->reportSender() );
                    my $ret_val = $cdsQual->isReadyForQual() || 0;
                    return $ret_val;
                }

                return 1;
            }
        }

        sleep 30;
    }

    return;
}

sub checkPreLQ {
    my $self    = shift;
    my $endTime = time () + $MAX_TIME_TO_WAIT_FOR_PRELQ;
    $logger->info( "Starting the preLQ DA. Will wait upto " . ariba::Ops::DateTime::scaleTime( $MAX_TIME_TO_WAIT_FOR_PRELQ ) );

    my $testServerInstance = $self->_getTestServerAppInstance();
    my $preLQURL           = $testServerInstance->_directActionURLForCommand( "preLQ" );

    my ( $preLQStatus, $preLQTaskInfo );
    while ( time () < $endTime ) {
        my $xmlString = $self->_hitDA( $preLQURL, 30 );

        if ( $xmlString ) {
            my $xs        = XML::Simple->new();
            my $xmlResult = $xs->XMLin( $xmlString );

            if ( ref ( $xmlResult ) ) {
                $preLQStatus   = $xmlResult->{ 'status' };
                $preLQTaskInfo = $xmlResult->{ 'Task-Info' };
            }

            if ( $preLQStatus ) {
                my $prevStatus = $self->preLQTaskStatus();
                if ( !$prevStatus || $prevStatus ne $preLQStatus ) {
                    $logger->info( "The task status updated to $preLQStatus" );
                }
                $self->setPreLQStatus( $preLQStatus );

                if ( lc ( $preLQStatus ) eq "failed" ) {
                    $logger->error( "PreLQ task has failed!" );
                    $logger->error( $preLQTaskInfo ) if ( $preLQTaskInfo );
                    return;

                } elsif ( lc ( $preLQStatus ) eq "success" ) {
                    $logger->info( "PreLQ tasks are complete!" );
                    return 1;
                }
            }
            # Note: We should ideally be checking for the http return code
            elsif ( $xmlString =~ /HTTP 404: Not Found Error/ || $xmlString =~ /HTTP Status 404 - Not Found/ ) {
                $logger->warn( "PreLQ DA is not implemented. Continuing with qual" );
                return 1;
            } else {
                $logger->error( "Error parsing status from preLQ DA: $xmlString" );
                return;
            }
        }
        sleep ( 60 );
    }

    $logger->error( "Timed-out waiting for preLQ tasks after " . ariba::Ops::DateTime::scaleTime( $MAX_TIME_TO_WAIT_FOR_PRELQ ) );
    $logger->error( $preLQTaskInfo ) if ( $preLQTaskInfo );
    return;
}

sub areAllNodesUp {

    my $self    = shift;
    my $endTime = time () + $MAX_TIME_TO_WAIT_FOR_ALL_NODES;
    $logger->info( "Starting the areAllNodesUP DA. Will wait upto " . ariba::Ops::DateTime::scaleTime( $MAX_TIME_TO_WAIT_FOR_ALL_NODES ) );

    my $testServerInstance = $self->_getTestServerAppInstance();
    my $areAllNodesUpURL   = $testServerInstance->_directActionURLForCommand( "areAllNodesUp" );
    # you will get an URL like this : https://hornbill.ariba.com:7452/Buyer/Main/ad/areAllNodesUp/MonitorActions
    my $allNodesStatus;

    while ( time () < $endTime ) {
        my $xmlString = $self->_hitDA( $areAllNodesUpURL, 30 );

        #it returns an xml in following format

        # <AllNodesStatus>
        # <AreAllNodesUp>false</AreAllNodesUp>
        # <UpNodes>
        # <Node>upnode-1</Node>
        # .....
        # <Node>upnode-n</Node>
        # </UpNodes>
        # <DownNodes>
        # <Node>downnode-1</Node>
        # ...
        # <Node>downnode-n</Node>
        # </DownNodes>
        # </AllNodesStatus>
        #

        if ( $xmlString ) {
            my $xs        = XML::Simple->new();
            my $xmlResult = $xs->XMLin( $xmlString );

            if ( ref ( $xmlResult ) ) {
                $allNodesStatus = $xmlResult->{ 'AreAllNodesUp' };
            }

            if ( $allNodesStatus ) {
                if ( lc ( $allNodesStatus ) eq "false" ) {
                    $logger->error( "DA returned errors, For details visit: $areAllNodesUpURL  " );
                    return;

                } elsif ( lc ( $allNodesStatus ) eq "true" ) {
                    $logger->info( "All nodes are up and running!" );
                    return 1;
                }
            }
            # Note: We should ideally be checking for the http return code
            elsif ( $xmlString =~ /HTTP 404: Not Found Error/ || $xmlString =~ /HTTP Status 404 - Not Found/ ) {
                $logger->warn( "PreLQ DA is not implemented. Continuing with qual" );
                return 1;
            } else {
                $logger->error( "Error parsing status from preLQ DA: $xmlString" );
                return;
            }
        }
        $logger->info( "DA to AllNodesUp is still running, sleeping 60 seconds to check again" );
        sleep ( 5 );
    }

    $logger->error( "Timed-out waiting for areAllNodesUP tasks after " . ariba::Ops::DateTime::scaleTime( $MAX_TIME_TO_WAIT_FOR_ALL_NODES ) );
    $logger->error( "For more details,  visit $areAllNodesUpURL" );

    return;
}

# Checks the Mon XML for various Mon Checks
# Return values: Success => 1, Failure => 0
sub checkMonData {
    my $self = shift;

    my $product = $self->productName();
    my $service = $self->service();
    my $result;

    my $monInstanceURL;
    # Creating an object for Installed Product to find details related to this service
    my $productObj = ariba::rc::InstalledProduct->new( $product, $service, undef, undef );
    my $appinfo = $productObj->appInfo();

    unless ( $productObj ) {
        $logger->error( "Could not build product instance." );
        return;
    }

    # Forning location for config directory to get location of csv file
    my $configDir   = $productObj->configDir();
    my $monCheckCSV = "$configDir/mon-prequal-checks.csv";
    my @monChecks;

    # reading the csv file. Use case is to continue with other checks if mon-checks.csv file is not present
    # Thsi is under the impression that not all products have started considering Mon Chceks for Qual.
    open ( CSV, "<", $monCheckCSV )
      or ( $logger->warn( "Looks like mon checks are not configured for Product $product on [ $service ] service. Continuing...\n" ), return 1 );
    @monChecks = <CSV>;
    close ( CSV );

    # removing empty lines and heading
    @monChecks = grep ( !/^\s+$/, @monChecks );
    @monChecks = grep ( !/^\#/,   @monChecks );

    # The input from csv comes in this format
    # First value is query manager name
    # Second Value is query manager xml root
    # third value is any query filter token (we resolve it seperately)
    # forth value is failure pattern, condition on which mon check should fail.
    foreach my $line ( @monChecks ) {
        chomp $line;
        my $daURL;
        my ( $qm, $xmlRoot, $queryToken, $failPattern, $subGroup, $checkName ) = split ( ',', $line );

        my ( $prefix, $suffix ) = split ( "/", $qm ) if ( $qm =~ /\// );

        unless ( $xmlRoot ) {
            $logger->error( "XML Root node is missing in CSV File. This is mandatory field for finding the check value in XML. Exiting... " );
            return 0;
        }

        if ( lc $prefix eq 'an' ) {
            my $anservice = $self->getANServiceName( $appinfo );
            $monInstanceURL = ariba::Ops::Utils::monXMLUrlForService( $anservice );
        } else {
            $monInstanceURL = ariba::Ops::Utils::monXMLUrlForService( $service );
        }

        $daURL = "$monInstanceURL\?dataTypes=queryManager";
        $daURL .= "\&qm=$qm" if ( defined $qm & $qm ne "" );

        if ( defined $queryToken && $queryToken ne "" ) {
            # Removing * from token
            $queryToken =~ s/\*//g;

            my $query = ( $prefix eq 'an' ) ? $queryToken : $self->getQueryFromMonToken( $queryToken, $product, $service );
            $daURL .= "\&query=$query" if ( defined $query && $query ne "" );
        }

        $logger->info( "Hitting $qm Query Manager Node on MON URL [$xmlRoot check]: $daURL" );
        my $xml = $self->_hitDA( $daURL, $MAX_TIME_TO_WAIT_FOR_PRELQ );

        unless ( $xml ) {
            $logger->error( "Could not get xml after hitting direct action url: $daURL " );
            return 0;
        }

        $result = $self->parseMonXMLForResult( $xml, $xmlRoot, $failPattern, $subGroup, $checkName );

        if ( $result ) {
            $logger->error( "Pre Qual Mon Check failed. Returning..." );
            return 0;
        }
    }
    return 1;
}

# Read the appInfo.xml file and returns the AN service confirgured for any Buyer/S4 product
# The way AN service is figured out is that we read the Front Door URL for AN and strip it
# down to get the AN service
# Example : https://svcsp.ariba.com/service/transaction/cxml.asp => gives sp after trimming svc
sub getANServiceName {
    my $self    = shift;
    my $appinfo = shift;

    my $xsObj      = XML::Simple->new();
    my $xmlResult  = $xsObj->XMLin( $appinfo );
    my $serviceURL = $xmlResult->{ 'Instance' }->{ 'AribaNetwork' }->{ 'Param' }->{ 'IncomingHttpServerURL' }->{ 'value' };
    my ( $service, undef ) = split ( '\.', $serviceURL );
    $service =~ s#https\:\/\/svc##g;

    return $service;
}

# Based on a given token, resolves the list of hosts needed for the action
sub getQueryFromMonToken {
    my $self    = shift;
    my $token   = shift;
    my $product = shift;
    my $service = shift;

    my @hosts = ();

    # I tried passing the productObj from the calling method but it was not working.
    # Thats why I have to create this object again.
    my $insProductObj = ariba::rc::InstalledProduct->new( $product, $service, undef, undef );

    # Now converting the names of products as  the config expects
    $product = 'buyer' if ( $product eq 'ssp' );
    $product = 'asm'   if ( $product eq 's4' );

    if ( $token eq "DEFAULT-ALL" ) {
        # All nodes includes Admin nodes, web server nodes, Tasks Nodes, UI nodes
        push ( @hosts,
            $insProductObj->hostsForRoleInCluster( $product . "admin",      "primary" ),
            $insProductObj->hostsForRoleInCluster( $product . "ui",         "primary" ),
            $insProductObj->hostsForRoleInCluster( $product . "task",       "primary" ),
            $insProductObj->hostsForRoleInCluster( $product . "globaltask", "primary" ),
            $insProductObj->hostsForRoleInCluster( "httpvendor",            "primary" ),
        );
    } elsif ( $token =~ /^PRODUCT-/ ) {
        $token =~ s/^PRODUCT-/$product/;
        @hosts = $insProductObj->hostsForRoleInCluster( $token, "primary" );
    } else {
        @hosts = $insProductObj->hostsForRoleInCluster( $token, "primary" );
    }

    # Since the delimeter for Mon URL is pipe '|', returning the value in desired format.
    return join ( "|", unique( @hosts ) );
}

# Parsing the XML received from Mon URL hitting. This will only fail if error pattern is found
# Return value: Success => 0, Failure => 1 (Return values are inverse than others because I wanted
# to capture the failures and continue to qual manager script)
sub parseMonXMLForResult {
    my $self        = shift;
    my $xml         = shift;
    my $xmlRoot     = shift;
    my $failPattern = shift;
    my $subGroup    = shift;
    my $checkName   = shift;

    my @allStatus;

    if ( $xml ) {
        my $xsObj = XML::Simple->new();
        my $xmlResult;

        eval { $xmlResult = $xsObj->XMLin( $xml ); };

        # Catching the exception thrown by XML/Simple.pm if input is non xml
        if ( $@ ) {
            $logger->error( "MON URL Failed because an error occured: \n $@ " );
            return 1;
        }

        my $metrics = $xmlResult->{ 'queryManager' }->{ $xmlRoot }->{ 'groups' }->{ 'group' }->{ 'metrics' }->{ 'metric' };

        my @metrics = keys %$metrics;

        # While writing this code, i found out that xml::simple object takes in the name
        # element of the repeating elements of xml as key to the hash if forms for xml.
        # Thats why you will see $metrics is equal to $metrics->{$metric}->{'name'}
        #
        #The logic below is that check name is the special filter which if defined means
        #special processing is needed for them. I have done this in order to accomodate
        #special reuqest to handle AN monitoring URLs, where only few particular nodes
        #are required to be check. Check Name and Sub Group names are those special cases
        if ( defined $checkName and $checkName ne '' ) {
            $checkName =~ s/\*//g;
            $subGroup =~ s/\*//g;
            @metrics = grep { /\Q$checkName\E/ } @metrics;

            foreach my $metric ( @metrics ) {
                my $status = $metrics->{ $metric }->{ 'status' };
                my $subgrp = $metrics->{ $metric }->{ 'subGroups' };
                if ( $subgrp =~ $subGroup && $status =~ $failPattern ) {
                    $logger->error( "Failing Pattern [$failPattern] matched for $subgrp. Printing the metric..." );

                    my $line = "<metric> \n\t";
                    $line .= "<subGroups>" . $metrics->{ $metric }->{ 'subGroups' } . "</subGroups> \n\t";
                    $line .= "<name>" . $metric . "</name> \n\t";
                    $line .= "<results>" . $metrics->{ $metric }->{ 'results' } . "</results> \n\t"
                      if ( exists ( $metrics->{ $metric }->{ 'results' } ) && ref ( $metrics->{ $metric }->{ 'results' } ne 'HASH' ) );
                    $line .= "<status>" . $metrics->{ $metric }->{ 'status' } . "</status>\n\t";
                    $line .= "<note>" . $metrics->{ $metric }->{ 'note' } . "</note>\n" if ( exists ( $metrics->{ $metric }->{ 'note' } ) );
                    $line .= "<severity>" . $metrics->{ $metric }->{ 'severity' } . "</severity>\n"
                      if ( exists ( $metrics->{ $metric }->{ 'severity' } ) );
                    $line .= "</metric> \n";
                    print $line;

                    return 1;
                }
            }
        } else {
            foreach my $metric ( @metrics ) {
                my $status = $metrics->{ $metric }->{ 'status' };
                if ( $status =~ $failPattern ) {
                    $logger->error( "Failing Pattern [$failPattern] matched. Printing the metric..." );
                    my $line = "<metric> \n\t";
                    $line .= "<subGroups>" . $metrics->{ $metric }->{ 'subGroups' } . "</subGroups> \n\t";
                    $line .= "<name>" . $metric . "</name> \n\t";
                    $line .= "<results>" . $metrics->{ $metric }->{ 'results' } . "</results> \n\t";
                    $line .= "<status>" . $metrics->{ $metric }->{ 'status' } . "</status>\n\t";
                    $line .= "<note>" . $metrics->{ $metric }->{ 'note' } . "</note>\n" if ( exists ( $metrics->{ $metric }->{ 'note' } ) );
                    $line .= "</metric> \n";
                    print $line;
                    return 1;
                }
            }
        }
    }

    return 0;
}

# Initializing status hash to avoid uninitialized error message
sub initStatusHash {
    my $self     = shift;
    my %initHash = ();

    foreach my $key ('OK','ERROR','WARNING','IN PROGRESS', 'NOT STARTED') {
        $initHash{$key} = "";
    }

    return %initHash;
}

# Checks the PreQual failures by hitting PreQual DAs
# Return: Success => 1 , Failure => 0 , Not Implemented => 2
sub checkPreQualData {
    my $self     = shift;
    my $qualType = $self->qualType();
    my $product  = $self->productName();
    my $service  = $self->service();
    my %checks   = $self->initStatusHash();

    # Creating Front Door URL using Installed Product Object's default values
    my $productObj = ariba::rc::InstalledProduct->new( $product, $service, undef, undef );
    my $preQualUrl = $productObj->default( 'VendedUrls.FrontDoor' );

    $preQualUrl .= "/ad/preQual?qualType=$qualType";
    $logger->info( "Hitting PreQual DA: $preQualUrl" );

    # Using the Max time out for 2 hrs
    my $endTime       = time () + $MAX_TIME_TO_WAIT_FOR_POSTTASKS;
    my $count503error = 0;

    # Looping till Max Wait time because some checks takes upto 1 hr to come up
    while ( time () < $endTime ) {
        my $xml = $self->_hitDA( $preQualUrl, $MAX_TIME_TO_WAIT_FOR_PRELQ );

        # Checking for 503  Error. Mainly the Catalog Issue which takes sometime to come up
        # Default time for now is 15 mins else gracefully return
        if ( $xml =~ /Service (Temporarily )?Unavailable|Gateway Timeout/ ) {
            $count503error++;
            $logger->info( "Receiving 503 Service Temporarily Unavailable. Sleeping for 60 seconds. Attempt # $count503error" );
            sleep ( 60 );

            if ( $count503error == 15 ) {
                $logger->error( "Attempted $count503error times, service still not up to return back PreQual Status XML. Exiting ..." );
                return 0;
            }

            next;
        }

        unless ( $xml ) {
            $logger->warn( "Could not get xml after hitting direct action url: $preQualUrl " );
            return 2;
        }

        my $xmlObj = XML::Simple->new();
        # perl5.22 XML:Simple chokes on '&' chars.  Change them to '&amp;' for proper parsing.
        $xml =~ s/&/&amp;/g;

        my $xmlIn;
        eval { $xmlIn = $xmlObj->XMLin( $xml ); };

        # Catching the exception thrown by XML/Simple.pm if input is non xml
        if ( $@ ) {
            $logger->error( "DA Failed because XML object has throwed an error: \n $@ " );
            return 0;
        }

        # Using return  value 2 to fall back on Old DAs
        if ( $xmlIn =~ /HTTP 404: Not Found Error/ || $xmlIn =~ /HTTP Status 404 - Not Found/ ) {
            return 2;
        }

        # Count values for exiting while loop on early check coompletion
        my $checkCount  = scalar ( keys %{ $xmlIn->{ 'check' } } );
        my $statusCount = 0;

        foreach my $check ( keys %{ $xmlIn->{ 'check' } } ) {
            my $status = $xmlIn->{ 'check' }->{ $check }->{ 'status' };
            my $xmlout;

            if ( $status eq 'ERROR' ) {
                my $line = "<check>\n\t";
                $line .= "<name>" . $check . "</name>";
                $line .= "<description>" . $xmlIn->{ 'check' }->{ $check }->{ 'description' } . "</description>\n\t";
                $line .= "<status>" . $status . "</status> \n\t";
                $line .= "<reason>" . $xmlIn->{ 'check' }->{ $check }->{ 'reason' } . "</reason> \n";
                $line .= "</check>\n";
                print $line;
                $logger->error( "Pre Qual Checks failed. Returning ..." );
                return 0;
            } elsif ( $status eq 'WARNING' or $status eq 'NOT STARTED' or $status eq 'IN PROGRESS' or $status eq 'OK' ) {

                if ( $status ne 'OK' and $status ne $checks{ $check } ) {
                    $logger->warn( "Status of $check is presently: $status" );
                }

                $checks{ $check } = $status;
            } else {
                $logger->warn( "Unknown status for $check : $status" );
                next;
            }
        }

        $statusCount = scalar ( grep { $checks{ $_ } =~ /(OK|WARNING)/ } keys %checks );
        last if ( $statusCount == $checkCount );

        sleep ( 60 );
    }

    if ( time () >= $endTime ) {
        $logger->error( "PreQual Checks timed out for maximun time of " . $MAX_TIME_TO_WAIT_FOR_POSTTASKS / 3600 . " Hours. Exiting... " );
        return 0;
    } else {
        $logger->info( "Pre Qual Actions from DA are successful." );
        return 1;
    }

}

sub unique {
    return keys %{ { map { $_ => 1 } @_ } };
}

sub stringToNumber {
    my $input = shift || 0;
    return $input + 0;
}

# Read the Test Results XML and populates the Hana DB for Test DB Information
sub postQualDataToHana {
    my $self      = shift;
    my $buildname = shift || "";
    my $service   = shift || "";
    my $logfile   = shift || "";
    my $testId    = shift || "";
    
    if ( lc ( $self->qualType() ) ne "lq" ) {
        $logger->info ("Qual Type is not LQ. Returning..");
        return;
    }

    # If XML is not already parsed, parsing it. Error if not able to do so
    my $parse = $self->qualResultsParsed() ? 1 : $self->parseQualResultsFile( $testId ) ;
    if ( !$parse ) {
        $logger->error( "Unable to Parse the results xml for posting data to Hana." );
        return 0;
    }

    $logger->debug( "Forming Hash to publish Qual Data" );

    my %data = ();
    $data{ 'buildname' } = $buildname;
    $data{ 'service' }   = $service;
    $data{ 'logfile' }   = $logfile;

    foreach my $keyword ( 'combine', 'consistent', 'flaky', 'wIP', 'new' ) {
        my $sub1 = $keyword . 'TotalTest';
        my $sub2 = $keyword . 'PassTest';
        my $sub3 = $keyword . 'PassRate';

        $data{ $sub1 } = stringToNumber ( $self->$sub1() );
        $data{ $sub2 } = stringToNumber ( $self->$sub2() );
        $data{ $sub3 } = stringToNumber ( $self->$sub3() );
    }

    $data{ 'nbTests' }        = stringToNumber( $self->qualNbTests() );
    $data{ 'nbErrors' }       = stringToNumber( $self->qualNbErrors() );
    $data{ 'nbFailures' }     = stringToNumber( $self->qualNbFailures() );
    $data{ 'nbSkipped' }      = stringToNumber( $self->qualNbSkipped() );
    $data{ 'nbNotRun' }       = stringToNumber( $self->qualNbNotRun() );
    $data{ 'nbPerfFailures' } = stringToNumber( $self->qualNbPerfFailures() );
    $data{ 'nbReRun' }        = stringToNumber( $self->qualNbReRun() );

    $client->publishQualData( \%data );
    return 1;
}


1;
