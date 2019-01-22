package ariba::Automation::BuildAction;

use strict;
use warnings;

use ariba::Automation::Utils;
use ariba::Automation::Action;
use base qw(ariba::Automation::Action);
use File::Basename;

use ariba::rc::Globals;
use ariba::rc::BuildDef;
use ariba::rc::MavenBuild;
use ariba::Ops::NetworkUtils;
use Ariba::P4;
use Ariba::P5;

sub validFields {
    my $class = shift;

    my $fieldsHashRef = $class->SUPER::validFields();

    $fieldsHashRef->{'buildName'} = 1;
    $fieldsHashRef->{'buildNameTemplate'} = 1;
    $fieldsHashRef->{'productName'} = 1;
    $fieldsHashRef->{'branchName'} = 1;
    $fieldsHashRef->{'latestChange'} = 1;
    $fieldsHashRef->{'s4AutoLabelBranch'} = 1;
    $fieldsHashRef->{'buyerAutoLabelBranch'} = 1;
    $fieldsHashRef->{'performAutoLabel'} = 1;
    $fieldsHashRef->{'incremental'} = 1;
    $fieldsHashRef->{'buildAllInIncremental'} = 1;
    $fieldsHashRef->{'nosync'} = 1;
    $fieldsHashRef->{'mirroredBuild'} = 1;
    $fieldsHashRef->{'forceClean'} = 1;
    $fieldsHashRef->{'failMissingDepends'} = 1;
    $fieldsHashRef->{'backdrop'} = 1;
    $fieldsHashRef->{'reportDependsDAG'} = 1;
    $fieldsHashRef->{'whatIfCompatCompName'} = undef;
    $fieldsHashRef->{'whatIfIncompatCompName'} = undef;
    $fieldsHashRef->{'deltas'} = undef; # Comma separated component names to add to the incremental delta (great for dev and test)
    $fieldsHashRef->{'incrClean'} = undef;
    $fieldsHashRef->{'nobuild'} = undef;
    $fieldsHashRef->{'logFile'} = undef;
    $fieldsHashRef->{'maven'} = 0;
    $fieldsHashRef->{'tlp'} = undef;
    $fieldsHashRef->{'labelArtifact'} = undef;
    $fieldsHashRef->{'mavenProfiles'} = undef;
    $fieldsHashRef->{'mavenArgs'} = undef;
    $fieldsHashRef->{'mavenGoals'} = undef;
    $fieldsHashRef->{'mavenSubmitChanges'} = undef;

    return $fieldsHashRef;
}

sub execute {
    my $self = shift;

    my $logger = ariba::Ops::Logger->logger();
    my $logPrefix = $self->logPrefix();
    my $productName = $self->productName();
    my $branch = $self->branchName();
    my $buildName = $self->buildName();
    my $buildNameTemplate = $self->buildNameTemplate();
    my $incremental = $self->incremental();
    my $buildAllInIncremental = $self->buildAllInIncremental();
    my $nosync = $self->nosync();
    my $mirroredBuild = $self->mirroredBuild();
    my $forceClean = $self->forceClean();
    my $failMissingDepends = $self->failMissingDepends();
    my $backdrop = $self->backdrop();
    my $reportDependsDAG = $self->reportDependsDAG();
    my $whatIfCompatCompName = $self->whatIfCompatCompName();
    my $whatIfIncompatCompName = $self->whatIfIncompatCompName();
    my $deltas = $self->deltas();
    my $incrClean = $self->incrClean();
    my $nobuild = $self->nobuild();
    my $logfile = $self->logFile() || '/path/to/log/file';

    my $hostname = ariba::Ops::NetworkUtils::hostname();
    my $isIDC = ariba::Automation::Utils::isIdcRobotHost($hostname);

    my $mavenBuild = $self->maven();

    if (my $expectedDelay = Ariba::P4::isScheduledPerforceDowntimeApproaching($isIDC)) {
        sleep($expectedDelay);
    }
    Ariba::P4::waitForPerforce();


    if ($mirroredBuild) {
        $buildName = $mirroredBuild;
    }

    unless ($buildName) {
        $buildName = $buildNameTemplate;
    }

    unless ($buildName) {
        $logger->error("$logPrefix could not determine buildname from either buildNameTemplate or previous buildName");
        return;
    }

    #FIXME fix this tight coupling to bootstrap
    my $root = ariba::Automation::Utils->opsToolsRootDir();

    my $hasAutoLabels = 0;
    my $version = ariba::rc::Globals::versionNumberFromBranchName($branch);
    my $labelFile = ariba::Automation::Utils->buildRootDir() . "/label-components-$version.txt";

    unlink($labelFile) if -e $labelFile;

    my $s4AutoLabelBranch = $self->s4AutoLabelBranch();
    my $buyerAutoLabelBranch = $self->buyerAutoLabelBranch();
    my $genericAutoLabelBranch;
    my $genericUpdateLabelMasks;

    #
    # Simulate effects of autolabeling on s4/buyer robots:
    #
    #   a. guess at autolabel branch
    #     S4 and Buyer are so linked that this will always be the
    #     same for both;  it can still be overridden in the
    #     robot.conf
    #
    #   b. pretend product.bdf had its labelmasks updated by labelcomponents
    #     This is needed because the new label names will be
    #     incremented minor revisions and labelmasks with a
    #     patch part will not match anymore.
    #

    my ($s4UpdateLabelMasks, $buyerUpdateLabelMasks);

    my $isSandbox = ($branch =~ m!//ariba/sandbox/!);

    unless ($isSandbox) {
        if ($productName =~ /s4/) {
            $s4AutoLabelBranch = $branch unless $s4AutoLabelBranch;
            $s4UpdateLabelMasks = 1;
        } elsif ($productName =~ /buyer/) {
            $buyerAutoLabelBranch = $branch unless ($buyerAutoLabelBranch);
            unless ($s4AutoLabelBranch) {
                $s4AutoLabelBranch = $branch;
                $s4AutoLabelBranch =~ s/buyer/asm/;
                ## Arul: 14-Sep: Quick fix till we have a clear idea of the
                ## dependency between products
                $s4AutoLabelBranch =~ s/11s2/11s1/;
            }
            $buyerUpdateLabelMasks = 1;
        }
        elsif ( lc($self->performAutoLabel()) eq "true" )
        {
            # Some other component other than buyer/s4
            $genericAutoLabelBranch = $branch;
            $genericUpdateLabelMasks = 1;
        }
    }

    unless ($mirroredBuild || $mavenBuild) {
        if ($s4AutoLabelBranch) {
            $logger->info("$logPrefix labelcomponents for s4 branch $s4AutoLabelBranch");
            $self->populateLabelComponentFile("s4", $s4AutoLabelBranch, $labelFile, $s4UpdateLabelMasks);
            $hasAutoLabels = 1;
        }

        if ($buyerAutoLabelBranch) {
            $logger->info("$logPrefix labelcomponents for buyer branch $buyerAutoLabelBranch");
            $self->populateLabelComponentFile("buyer", $buyerAutoLabelBranch, $labelFile, $buyerUpdateLabelMasks);
            $hasAutoLabels = 1;
        }

        if ($genericAutoLabelBranch) {
            $logger->info("$logPrefix labelcomponents for $productName branch $genericAutoLabelBranch");
            $self->populateLabelComponentFile($productName, $genericAutoLabelBranch, $labelFile, $genericUpdateLabelMasks);
            $hasAutoLabels = 1;
        }
    }

    if ($mavenBuild) {
    	#pick up the build name from template initialization
   	    $self->setBuildName($buildName);
        return $self->runMaven();
    }

    #
    # setup ENV vars and p4 client
    #
    $logger->info("$logPrefix Setting up environment for $productName branch $branch");
    my $previousClient = ariba::Automation::Utils->setupLocalBuildEnvForProductAndBranch($productName, $branch);

    #
    # run build command
    #

    $logger->info("$logPrefix Starting build for $productName branch $branch");

    my $buildCmd = "$root/services/tools/bin/make-build2 -noarchive -product $productName -branch $branch -logfile $logfile -robot";

    if ($mirroredBuild) {
        $logger->info("$logPrefix Building using the mirrored build label $mirroredBuild");
        $buildCmd .= " -mirroredBuild $mirroredBuild";
    }
    else {
        $buildCmd .= " -buildname $buildName";

        # Find out the change at which we need to kick-off this build
        # The change need to be under this branch
        my $buildAtChange = ariba::Automation::Utils::getChangesForProduct (0, $self->productName(), $self->branchName());

        if ($buildAtChange && $buildAtChange != 0) {
            $logger->info("$logPrefix Building at $buildAtChange");
            $buildCmd .= " -atChange $buildAtChange";
        }
    }

    unless ($mirroredBuild) {
        if ($hasAutoLabels) {
            $buildCmd .= " -forceLabelFile $labelFile";
        }
    }

    $buildCmd .= " -nobuild" if ($nobuild); # archive step will happen when nobuild

    if ($incremental) {
        $buildCmd .= " -incremental";

        $buildCmd .= " -buildAll" if ($buildAllInIncremental);
        $buildCmd .= " -forceClean" if ($forceClean);
        $buildCmd .= " -failMissingDepends" if ($failMissingDepends);
        $buildCmd .= " -deltas $deltas" if (defined $deltas);
        $buildCmd .= " -whatIfCompatCompName $whatIfCompatCompName" if (defined $whatIfCompatCompName);
        $buildCmd .= " -whatIfIncompatCompName $whatIfIncompatCompName" if (defined $whatIfIncompatCompName);
    }

    unless ($nosync || $mirroredBuild) {
       $buildCmd .= " -sync";
    }

    $logger->info("$logPrefix Running $buildCmd");
    return unless ($self->executeSystemCommand($buildCmd));

    unless ($mirroredBuild) {
        #
        # update buildname for robot, make-build2 has just done this
        #
        my ($stem, $build) = ariba::rc::Globals::stemAndBuildNumberFromBuildName($buildName);
        $buildName = sprintf("%s-%s", $stem, ++$build);
    }

    if ($self->testing()) {
        $logger->debug("$logPrefix would update buildName var to $buildName");
    } else {
        $self->setBuildName($buildName);
    }

    #
    # run archive command
    #
    my $archiveCmd = "$root/services/tools/bin/make-build2 -nobuild -product $productName -branch $branch -buildname $buildName -logfile $logfile";
    $logger->debug("$logPrefix Running $archiveCmd");
    return unless ($self->executeSystemCommand($archiveCmd));

    $logger->info("$logPrefix Finished build for $productName branch $branch");

    $self->updateLastGoodChange();

    #
    # restore environment to previous state
    #
    ariba::Automation::Utils->teardownLocalBuildEnvForProductAndBranch($productName, $branch, $previousClient);

    return 1;
}

sub updateLastGoodChange {
    my $self = shift;

    my $logger = ariba::Ops::Logger->logger();

    my $lastChangeFile = $ENV{'ARIBA_LATEST_CHANGE_FILE'};
    unless ($lastChangeFile) {
        $logger->warn("ARIBA_LATEST_CHANGE_FILE not set in updateLastGoodChange");
        return;
    }

    unless (open (CHANGEFILE, "<$lastChangeFile")){
        $logger->error("Couldn't open $lastChangeFile: $!");
        return;
    }

    my $lastChange = <CHANGEFILE>;
    chomp($lastChange);
    close(CHANGEFILE);

    my $time = (stat($lastChangeFile))[9];

    my $globalState = ariba::Automation::GlobalState->newFromName($self->SUPER::attribute("robotName"));

    $globalState->setCurrentChange($lastChange);
    $globalState->setCurrentChangeTime($time);

    return 1;
}

sub populateLabelComponentFile {
    my $self = shift;
    my $prodName = shift;
    my $branch = shift;
    my $file = shift;
    my $updateLabelMasks = shift;

    my $logger = ariba::Ops::Logger->logger();
    my $logPrefix = $self->logPrefix();

    my $job = "labels_" . $prodName . "_" . ariba::rc::Globals::versionNumberFromBranchName($branch);

    my $root = ariba::Automation::Utils->opsToolsRootDir();
    my $labelCommand = "$root/services/tools/bin/labelcomponents -product $prodName -branch $branch -job $job -updateLabelFile $file";
    $labelCommand .= " -updateLabelMasks" if ($updateLabelMasks);

    $logger->info("$logPrefix $labelCommand");
    return $self->executeSystemCommand($labelCommand);
}

sub runMaven {
    my $self = shift;
    my $productName = $self->productName();
    my $logger = ariba::Ops::Logger->logger();
    my $logPrefix = $self->logPrefix();
    my $topLevelPom = $self->tlp();
    my $labelArtifact = $self->labelArtifact();
    my $mavenProfiles = $self->mavenProfiles();
    my $mavenSubmitChanges = $self->mavenSubmitChanges();
    my $mavenGoals = $self->mavenGoals();
    my $mavenArgs = $self->mavenArgs();
    my $mirroredBuild = $self->mirroredBuild();
    my $buildName = $self->buildName();
    my $branchName = $self->branchName();
    my $logfile = $self->logFile() || '/path/to/log/file';
  
    #FIXME fix this tight coupling to bootstrap
    my $root = ariba::Automation::Utils->opsToolsRootDir();
    
    #
    # setup ENV vars and p4 client
    #
    $logger->info("$logPrefix Setting up environment for $productName branch $branchName");
    my $previousClient = ariba::Automation::Utils->setupLocalBuildEnvForProductAndBranch($productName, $branchName);


    $logger->info("Starting Maven Build for $topLevelPom");
    
    my $mvnbuild = ariba::rc::MavenBuild->new();

    unless ($mirroredBuild) {
        #
        # update buildname for robot state.  This is copied from make-build2, 
        # and is a little hackish.  it makes a writable copy of BuildName file
        # which cannot be clobbered when syncing.  This makes the build name increment
        # on the local machine.
        #
          my $buildnamefile = $ENV{'BUILDNAME_FILE'};
          
          if (!$buildnamefile) {
          
            my $cmd = "p4 where $topLevelPom";
            my ($out, $ret) = _executeCommandWithOutput($cmd);
            if ($ret != 0) {
                $logger->error("The $cmd failed with status " . $ret);
                return 0;
            }
            my @parts = split(/ /, $out);
            my $pomfile = $parts[2];
            chomp($pomfile);
    
    
            my @toks = split(/pom.xml/, $pomfile);
    		$buildnamefile = $toks[0] . "BuildName";
          }
		  	$buildnamefile =~ s,\\,/,g;

		if (! -f $buildnamefile) {
		    $logger->warn("Cannot find build name file $buildnamefile, rewriting it!");
		}
		else {
			$buildName = ariba::rc::Utils::getBuildName(dirname($buildnamefile));
		}
		
		my $lastBuild  = $buildName;
        my ($stem, $build) = ariba::rc::Globals::stemAndBuildNumberFromBuildName($buildName);
        $buildName = sprintf("%s-%s", $stem, ++$build);
            $logger->info("\nUpdating build name from $lastBuild to $buildName\n");
    	open(FL, "> $buildnamefile.new") || $logger->error("%s: %s", $buildnamefile, $!);
    	print FL "$buildName\n";
    	close (FL);

        rename("$buildnamefile.new", $buildnamefile) || $logger->error("%s: %s", $buildnamefile, $!);
    }
    
    if ($self->testing()) {
        $logger->debug("$logPrefix would update buildName var to $buildName");
    } else {
        $self->setBuildName($buildName);
    }
  
    # the maven archive needs these properties like:
    # -Dariba.buildname=buyer_robot167-123
    # -Dariba.branchname=12s2
    # -Dariba.productname=buyer
    # -Dariba.archiveroot=/robots/personal_robot167/archive/builds

    my $abls = "ARIBA_ARCHIVEBUILDS_LOCATION_" . uc($productName);
    my $abl = $ENV{$abls};
    # The env variable result looks like: /robots/personal_robot167/archive/builds/arecibo
    # We don't want the product suffix - it gets appended later
    my $archiveroot = dirname($abl);

    # The branchName looks like: //ariba/cloudsvc/arecibo/build/R2
    # We don't want the p4 prefix, just the "R2" like portion
    my $branchpart = basename($branchName);
    $mavenArgs .= " -Dariba.buildname=$buildName -Dariba.branchname=$branchpart -Dariba.productname=$productName -Dariba.archiveroot=$archiveroot ";

    if ($mvnbuild->build($mavenProfiles,$topLevelPom,$mavenSubmitChanges,$labelArtifact,$mavenGoals,$mavenArgs,$buildName)) {
    

        $self->updateLastGoodChange();

        #
        # restore environment to previous state
        #
        ariba::Automation::Utils->teardownLocalBuildEnvForProductAndBranch($productName, $branchName, $previousClient);
        
        return 1;
    }
    
    # something failed,
    return 0;
}

sub _executeCommandWithOutput {
    my $cmd = join ' ', @_;
    ($_ = qx{$cmd 2>&1}, $? >> 8);
}


1;
