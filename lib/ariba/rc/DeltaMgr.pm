# $Id: //ariba/services/tools/lib/perl/ariba/rc/DeltaMgr.pm#9 $
package ariba::rc::DeltaMgr;

use strict;
use warnings;
use ariba::rc::Globals;
use ariba::rc::Utils;
use Ariba::Util;
use ariba::rc::CompMeta;
use ariba::rc::LabelUtils;
use Data::Dumper;

my $ARIBA_INSTALL_ROOT = $ENV{'ARIBA_INSTALL_ROOT'};

# Note: The IncrBuildMgr performs a form of bootstrapping by save/restore of
# certain subdirectories under ARIBA_BUILD_ROOT.
# That mechanism is sufficient except for especially large comps like ishield.
# The key in the hash is the name of the bootstrap component to add to the delta.
# The value of 1 means the component must have it's dependency network rebuilt
# The value of 0 means that it should be added as just a delta component

my %incrBootstrapComps = (
   "ishield" => 0,
   "ariba.app.basicdata" => 0,
   "ariba.catalog.basevalidation" => 0,
);

#
# Constructor
#
sub new
{
    my $class = shift;
    my $buildAll = shift;
    my $self = {};
    bless ($self, $class);

    $self->setFullBuild($buildAll);
    return $self;
}

# Input 1: non-zero value means this is a full incremental build (different bootstrap delta additions)
sub setFullBuild {
    my ($self, $buildAll) = @_;

    $self->{'buildAll'} = $buildAll;
}

#
# getDeltaProductDef
#
# Return a set of CompMeta objects that correspond
# to the components that were changed since a base label.
#
# the motivation for this utility is for the incremental build
# feature of Engineering services release 3. The incremental build
# will compute an ordered list of components that are to be rebuilt
# based on this delta change set.
#
# Input param 1 : reference to an array of CompMeta objects (that may encapsulate ProductDefinition objects)
# Input param 2 : String baseLabel
# Input param 3 : String product
# Input param 4 : String name of component for what-if testing (only bottstrap and this comp allowed in delta)
# Input param 5 : String comma separated list of component names to include in the delta set
# Returns :  Returns : array of CompMeta objects
#           or calls the error subroutine
sub getDeltaProductDef {
    my $self = shift;
    my $compMetaUniverseRef = shift;
    my $baseLabel = shift;
    my $product = shift;
    my $whatIfCompName = shift;
    my $manuallyAddedDeltas = shift;

    # TODO: All the print statements starting with Error: will
    # eventually need to be a call to an error handler. Tip: We can think of
    # including a callback for error sub routines for now.

    # Question: How do we handle removal of components?
    #    - We should detect component removals. TODO.
    #    - We can think of forcing a full build when a component removal is detected

    # Question: Should we check if the base label's branch name is same as that for the current build run? May be yes.
    # Question: Are we supporting Incr build for RC builds on sandboxes? If yes, the deltaManager piece will need some changes.
    # Question: Are we supporting Incr build for the robot builds? If yes, the deltaManager piece will need some changes.

    # Will use this scalar to track the actual base label name, if the base label
    # issued is a sym link. By default this is same as the base label.
    my $actualBaseLabel = $baseLabel;

    # Find out the exact label, if we have a * in the name
    if ($baseLabel =~ /\*/)
    {
        print "Finding out the exact label for $baseLabel ... \n";
        $baseLabel = ariba::rc::LabelUtils::exactLabel($baseLabel);
        print "Base label now is $baseLabel \n";
    }

    # Find out the archive location for the product
    my $archiveRoot = ariba::rc::Globals::archiveBuilds($product);
    my $baseLabelRoot = $archiveRoot . "/$baseLabel";
    my $baseComponentsFile = $baseLabelRoot . "/config/components.txt";

    # Check if the base label exists
    if (! -d $baseLabelRoot)
    {
        #TODO: Call the standard error routine here
        print "Warning: the base label, $baseLabel, doesn't exist at $baseLabelRoot\n";
    }

    # Check if the base label has the components.txt file
    if (! -e $baseComponentsFile)
    {
        #TODO: Call the standard error routine here
        print "Warning: the components.txt file is not present under the baseLabel at $baseComponentsFile \n";
    }

    # If the baseLabel is a sym link, find out the actual buildName and mention
    # it in the logs for audit purposes
    if (-l $baseLabelRoot)
    {
        # Read the buildName file to find out the actual buildName
        $actualBaseLabel = ariba::rc::Utils::getBuildName("$baseLabelRoot/config");

        if ($actualBaseLabel =~ /Unknown-/i)
        {
            #TODO: Call the standard error routine here
            print "Error: Unable to find the actual label name for $baseLabel. Got $actualBaseLabel \n";
            print "Error: Something is wrong."
        }

        print "The given base label ($baseLabel) is a sym link \n";
        print "The actual base build name is $actualBaseLabel \n";
    }

    my @hubComponentLines;
    if (lc($product) eq 'an') {
        #TODO? Put this in a DeltaMgrAN.pm
        my $componentshubtxt = "$ARIBA_INSTALL_ROOT/internal/build/componentshub.txt";
        if (-e $componentshubtxt) {
            @hubComponentLines = Ariba::Util::readFile($componentshubtxt);
        }
    }

    # Read in the components.txt file of the baseLabel and load it into a hash
    my @baseComponentLines = Ariba::Util::readFile("$baseLabelRoot/config/components.txt");
    my %baseComponents;
    foreach my $line (@baseComponentLines,@hubComponentLines)
    {
        chomp($line);
        # Sample line (3 fields separated by space):
        # ariba.app.approvable app.approvable-11.64 //ariba/platform/app/approvable/...
        my @data = split (/\s+/,$line);

        my $cname = $data[0];
        my $lbl = $data[1];
        my $p4dir = $data[2];

        if ($cname eq "shared") {
           # Why does components.txt list shared yet we name it prod_shared in product.bdf ?
           # We did we skip including the shared comp?
           # Why does prod_shared list many comps as it's dependency? It's backwards, the tools.build should depend on shared
           # Certainly, building shared at the end is not necessary
           # Note the painful difference between shared and prod_shared; why do we need this naming diff?
           $cname = "prod_shared";
            print "Found component=\"$cname\" with label=\"$lbl\" and p4dir=\"$p4dir\"\n";
        }

        # Store it in a hash with component name as the key and label as the value
        $baseComponents{$cname}{"label"} = $lbl;
        $baseComponents{$cname}{"p4dir"} = $p4dir;
    }

    # Compare the base components with the current ones (loaded in productDefinition)
    my ($delta,$newComps,$deletedComps) = $self->_computeDelta (
        $product, $compMetaUniverseRef,\%baseComponents,$baseLabel,$actualBaseLabel, $whatIfCompName, $manuallyAddedDeltas);

    # Take care of the deleted components.
    # We need to create compMeta objects and add them to the universe
    # Also, return the compMeta objects instead of product deinfition objects
    my @deletedCompsMeta;
    foreach my $del (@$deletedComps)
    {
        my $delCompMeta = ariba::rc::CompMeta->new();
        $delCompMeta->setName($del);
        $delCompMeta->markAsDeleted();
        push (@$compMetaUniverseRef,$delCompMeta);
        push (@deletedCompsMeta,$delCompMeta);
    }

    return ($delta,$newComps,\@deletedCompsMeta);
}

# Subroutine that computes the delta
# Input Param 1: Product name
# Input Param 2: Array reference to productDefinition
# Input Param 3: Hash reference to baseComponents
# Input Param 4:
# Input Param 5:
# Input Param 6: optional name of what-if component to add to delta (only this and bootstrap allowed)
# Input Param 7: optional String comma separated component names to include in delta set
# Returns three array references of the updated,new,deleted comps
sub _computeDelta
{
    my $self = shift;
    my $product = shift;
    my $compMetaUniverseRef = shift;
    my $baseComponentsRef = shift;
    my $baseLabel = shift;
    my $actualBaseLabel = shift;
    my $whatIfCompName = shift;
    my $manuallyAddedDeltas = shift;

    my %baseComponents = %$baseComponentsRef;
    my (@delta,@newComps);

    my %manuallyAddedDeltasSet = ();
    if ($manuallyAddedDeltas) {
        my @deltasList = split (/,/,$manuallyAddedDeltas);
        foreach my $compname (@deltasList) {
            $manuallyAddedDeltasSet{$compname} = $compname;
        }
    }

    foreach my $currentComp (@$compMetaUniverseRef) {
        my $currentCompName = $currentComp->getName();

        if (defined $whatIfCompName) {
            if ($whatIfCompName eq $currentCompName) {
                print "DeltaMgr: Adding $currentCompName to the delta as it is a what-if expected results component \n";
                push (@delta, $currentComp);
            }
            delete ($baseComponents{$currentCompName});
            next;
        }

        my $currentCompLabel = $currentComp->getLabel();
        my $currentCompP4Dir = $currentComp->getP4Dir(); # does not have trailing '/...'

        # productDefinition array has an object at the product level for which
        # the modname attrib is not set. Skip if we come across the product level object.
        # TODO: We may want to think of stripping the productDefinition object off
        # the product level object(s).
        if (! $currentCompName) {
            print "Skipping the following dumped component because it is missing the module name\n";
            print Dumper($currentComp);
            next;
        }

        my $baseCompLabel = $baseComponents{$currentCompName}{"label"};
        my $baseCompP4Dir = $baseComponents{$currentCompName}{"p4dir"}; # has trailing '/...'

        # Check if this is a new component
        if (! $baseCompLabel)
        {
            push (@newComps, $currentComp);

            # Also, mark this as a new component
            $currentComp->markAsNew();

            delete ($baseComponents{$currentCompName});

            unless ($self->{'buildAll'}) {
                print "The component \"$currentCompName\" is considered new as there is no base label so it's being skipped\n";
            }
            next;  # We can move on to the next component
        }

        my $baselineP4Spec = $baseCompP4Dir . "\@";
        if ($actualBaseLabel) {
            $baselineP4Spec .= $actualBaseLabel;
        }
        else {
            $baselineP4Spec .= $baseLabel;
        }
        $currentComp->setBaselineP4Spec($baselineP4Spec); # will be used to sync prior build for cleaning

        my $inManuallyAddedDeltasSet = $self->_isInManuallyAddedDeltasList(\%manuallyAddedDeltasSet, $currentCompName);

        #
        # If either the new label or the base label is mentioned as "latest",
        # we will need to do more analysis to find if the componet has
        # changed. Otherwise, we can just compare the label names
        #

        if (($currentCompLabel =~ /latest/i) ||
            ($baseCompLabel =~ /latest/i) ||
            $inManuallyAddedDeltasSet ||
            (lc($product) eq 'an') ||
            ($currentCompLabel ne $baseCompLabel)) {

            # At the least one component has "latest" as the label
            $currentCompP4Dir .= "/...";
            $currentCompP4Dir .= "\@$currentCompLabel" if ($currentCompLabel ne "latest");

            # Look up the base comp at the base product label if it is set to "latest"
            my $baseProdLabelForDiff = $baseLabel;
            $baseProdLabelForDiff = $actualBaseLabel if ($actualBaseLabel);
            $baseCompLabel = $baseProdLabelForDiff if ($baseCompLabel eq "latest");
            $baseCompP4Dir .= "\@" . $baseCompLabel;

            my $cmd = "p4 diff2 $currentCompP4Dir $baseCompP4Dir";
            my @diffout = qx "$cmd";
            my $ret = $? ;
            if ($ret > 0) {
                # perldoc -f system (must >> 8 to get actual value)
                $ret = $ret >> 8;
                print "DeltaMgr: Error $ret getting p4 differences: The command = $cmd\n";
            }
            else {
                #Perforce presents the diffs in UNIX diff format, prepended with a header. The header is formatted as follows:
                #==== file1 (filetype1) - file2 (filetype2) ==== summary
                #The possible values and meanings of summary are:
                # content: the file revisions' contents are different,
                # types: the revisions' contents are identical, but the filetypes are different,
                # identical: the revisions' contents and filetypes are identical.
                # <none>: If either file1 or file2 does not exist at the specified revision, like a new file was added
                my $anydiff = 0;

                if ($inManuallyAddedDeltasSet) {
                    $anydiff = 1;
                }

                unless ($manuallyAddedDeltas) {
                    foreach my $diffline (@diffout) {
                        if ($diffline =~ /==== content/ || $diffline =~ /==== <none>/ || $diffline =~ /<none> ===/) {
                            $anydiff = 1;
                            last;
                        }
                    }
                }

                if ($anydiff) {
                    $currentComp->setFileDiffs(\@diffout);
                    push (@delta, $currentComp);
                }
            }
        }

        unless ($self->{'buildAll'}) {
            my $bsref = \%incrBootstrapComps;
            my @bs = keys %incrBootstrapComps;

            my $searchPattern = $currentCompName;
            $searchPattern =~ s/\./\\\./g;
            if (grep(/^$searchPattern$/i,@bs))
            {
                my $v = $bsref->{$currentCompName};
                if ($v) {
                    print "DeltaMgr: Adding $currentCompName to the delta as a transitive bootstrap component \n";
                    $currentComp->markAsBootstrap(1);
                }
                else {
                    print "DeltaMgr: Adding $currentCompName to the delta as a lone bootstrap component \n";
                    $currentComp->markAsBootstrap(0);
                }
                push (@delta, $currentComp);
            }
        }

        # Remove this component from the baseComponents list
        # This will help to find out if any components are deleted
        # in the new definition
        delete ($baseComponents{$currentCompName});
    }

    my @deletedComps = keys %baseComponents;

    return (\@delta,\@newComps,\@deletedComps);
}

# Return compname if it is in the supplied reference to set of manually added component names; else undef
sub _isInManuallyAddedDeltasList {
    my $self = shift;
    my $deltasSetRef = shift;
    my $compname = shift;

    my $v = $deltasSetRef->{$compname};
    if ($v) {
        print "DeltaMgr: The component \"$compname\" is listed in the manually supplied list of components to be built\n";
    }
    return $v;
}

1;
