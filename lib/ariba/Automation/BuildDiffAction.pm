package ariba::Automation::BuildDiffAction;

use strict;
use warnings;

use ariba::Automation::Utils;
use ariba::Automation::Action;
use base qw(ariba::Automation::Action);

use ariba::rc::Globals;

# Example robot.conf.local
# To wait for an rc inc build of SSPR2
# Then launch a classic build of the same label
# Then to compare the images and generate a report
#
#   identity.dept=RC
#   identity.description=SSPR2-classicincbuilddiff
#   identity.name=SSPR2-classicincbuilddiff
#   identity.responsible=rmauri@ariba.com
#   identity.team=RC
#   
#   global.emailTo=rmauri@ariba.com
#   global.productName=buyer
#   global.waitTimeInMinutes=5
#   global.emailFrom=devbuild@ariba.com <SSPR2-classicincbuilddiff>
#   global.targetBranchname=//ariba/buyer/build/R2
#   global.buildNameTemplate=buyer_robot359-0
#   global.noSpam=1
#   
#   action.clean.type=Clean
#   action.clean.keep=3
#   action.clean.productName=[productName]
#   
#   action.waitForRCBuild.type=buildnameFromCurrentRCBuildLabelNonQual
#   action.waitForRCBuild.branch=R2
#   action.waitForRCBuild.productName=[productName]
#   action.waitForRCBuild.buildName=[labeledBuildName]
#   action.waitForRCBuild.waitForNewBuild=true
#   action.waitForRCBuild.noQualWait=true
#   
#   action.build-target.type=build
#   action.build-target.mirroredBuild=[labeledBuildName]
#   action.build-target.productName=[productName]
#   action.build-target.branchName=[targetBranchname]
#   
#   action.buildDiff-target.type=buildDiff
#   action.buildDiff-target.mirroredBuildPath=/home/rc/archive/builds/buyer
#   action.buildDiff-target.currentBuildPath=/robots/personal_robot359/archive/builds/buyer
#   action.buildDiff-target.mirroredBuild=[labeledBuildName]
#   For AN: do not define imageDir; for S4/SSP set to image
#   action.buildDiff-target.imageDir=image
#   action.buildDiff-target.reportPath=/home/robot359/public_doc/mirroredBuildDiffs

sub validFields {
    my $class = shift;

    my $fieldsHashRef = $class->SUPER::validFields();

    $fieldsHashRef->{'buildName'} = 1;
    $fieldsHashRef->{'mirroredBuild'} = 1;
    $fieldsHashRef->{'mirroredBuildPath'} = 1;
    $fieldsHashRef->{'currentBuildPath'} = 1;
    $fieldsHashRef->{'reportPath'} = 1;
    $fieldsHashRef->{'imageDir'} = 1;

    return $fieldsHashRef;
}

sub execute {
    my $self = shift;

    my $logger = ariba::Ops::Logger->logger();
    my $logPrefix = $self->logPrefix();
    my $mirroredBuild = $self->mirroredBuild();
    my $mirroredBuildPath = $self->mirroredBuildPath();
    my $currentBuildPath = $self->currentBuildPath();
    my $imageDir = $self->imageDir();
    my $reportPath = $self->reportPath();

    if ($mirroredBuild && $mirroredBuildPath && $currentBuildPath) {
        my $root = ariba::Automation::Utils->opsToolsRootDir();
        my $bd1 = "$mirroredBuildPath/$mirroredBuild";
        my $bd2 = "$currentBuildPath/$mirroredBuild";
        my $rawdiffsdir = $bd2 . "/logs/buildDiffs";
        if ($imageDir) {
            $bd1 .= "/$imageDir";
            $bd2 .= "/$imageDir";
        }
        my $buildDiffCmd = "perl $root/tools/build/bin/buildDiffs.pl -builddir1 $bd1 -builddir2 $bd2 -label $mirroredBuild -reportdir $reportPath -rawdiffsdir $rawdiffsdir";
        $logger->info("$logPrefix Running build diff command \"$buildDiffCmd\"");
        $self->executeSystemCommand($buildDiffCmd);
    }

    return 1;
}

1;
