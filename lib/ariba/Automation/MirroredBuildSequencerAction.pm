package ariba::Automation::MirroredBuildSequencerAction;

# $Id: //ariba/services/tools/lib/perl/ariba/Automation/MirroredBuildSequencerAction.pm#1 $
# Determine the next mirroredBuild for a sequence of mirrored builds
# Use before a BuildAction that uses mirroredBuild instead of builName to reproduce a build
#
# Example of robot config file:
#   action.sequence-mirrored-build-target.type=mirroredBuildSequencer
#   action.sequence-mirrored-build-target.mirroredBuildSequence=S4R3-263:S4R3-264:1
#   action.sequence-mirrored-build-target.mirroredBuild=[mirroredBuild]
#
#   action.build-target.type=build
#   action.build-target.mirroredBuild=[mirroredBuild]
#   action.build-target.productName=[productName]
#   action.build-target.branchName=[targetBranchname]
#   action.build-target.incremental=true

use warnings;
use strict;

use ariba::Automation::Action;
use ariba::rc::Globals;

use base qw(ariba::Automation::Action);

# state is kept local
# TODO? add to global state (to support continued sequencing between robot restarts, but how to reset the accumulator?

my $mirroredBuildIncrementAccumulator;
my $mirroredBuildIncrement;
my $mirroredBuildStopVersion;

sub validFields {
    my $class = shift;

    my $fieldsHashRef = $class->SUPER::validFields();

    $fieldsHashRef->{'mirroredBuildSequence'} = 1; # syntax: S4R3-123[:S4R3-789:1] (the latter  is start build : stop build inclusive: increment)
    $fieldsHashRef->{'mirroredBuild'} = 1;
    $fieldsHashRef->{'robotName'} = 1; # work around for no such method robotName

    return $fieldsHashRef;
}

sub execute {
    my $self = shift;

    my $mirroredBuild;
    my $mirroredBuildSequence = $self->mirroredBuildSequence();

    my $logger = ariba::Ops::Logger->logger();
    my $logPrefix = $self->logPrefix();

    if ($mirroredBuildSequence) {
        my @toks = split(/:/, $mirroredBuildSequence);
        my $tokssize = @toks;
        if ($tokssize == 3) {
            $mirroredBuild = $toks[0];
            $mirroredBuildStopVersion = $toks[1];
            $mirroredBuildIncrement = $toks[2];
            print "The BuildAction can perform a sequence of mirrored builds from $mirroredBuild to $mirroredBuildStopVersion (inclusive) at steps of $mirroredBuildIncrement\n";
        }

        unless (defined $mirroredBuildIncrementAccumulator) {
            # The first sequential mirroredBuild case
            $mirroredBuildIncrementAccumulator = 0;
        }
        elsif ($mirroredBuildIncrement) {
            #
            # The following optional feature supports spinning robots that perform a seqeunce of mirror builds.
            # - It starts at $mirroredBuild
            # - Then it increments the version number by $mirroredBuildIncrement
            # - Finally stopping when beyond the $mirroredBuildStopVersion
            #
            # Each spin the increment is accumulated to the global state variable $mirroredBuildIncrementAccumulator
            #
            # The $mirroredBuild and $mirroredBuildStopVersion should be existing build labels
            #
            my ($stem, $build) = ariba::rc::Globals::stemAndBuildNumberFromBuildName($mirroredBuild);
            $build += $mirroredBuildIncrementAccumulator;
            $mirroredBuildIncrementAccumulator += $mirroredBuildIncrement;

            $build += $mirroredBuildIncrement;
            $mirroredBuild = sprintf("%s-%s", $stem, $build);

            if ($mirroredBuildStopVersion) {
                my ($stem2, $build2) = ariba::rc::Globals::stemAndBuildNumberFromBuildName($mirroredBuildStopVersion);
                if ($build > $build2) {
                    print "Exiting robot as mirroredBuild sequencing reached the stop version $mirroredBuildStopVersion\n";
                    exit (123);
                }
            }
        }
    }

    $logger->info("$logPrefix setting mirroredBuild to $mirroredBuild");
    $self->setMirroredBuild($mirroredBuild);

    return 1;
}

1;
