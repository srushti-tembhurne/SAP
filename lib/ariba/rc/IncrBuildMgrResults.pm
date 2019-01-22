package ariba::rc::IncrBuildMgrResults;

use strict;
use warnings;
use Data::Dumper;

# IncrBuildMgrResults
#
# Defines a class that the IncrBuildMgr instantiates and returns to callers
# that contains information about what was rebuilt, what Java packages were added, deleted, etc.

#
# Constructor
sub new {
    my $class = shift;
    my $self = {};
    bless ($self, $class);

    my %bootstrapRebuildSet = ();
    $self->{'bootstrapRebuildSet'} = \%bootstrapRebuildSet;

    my %transitiveRebuildSet = ();
    $self->{'transitiveRebuildSet'} = \%transitiveRebuildSet;

    my %addvisRebuildSet = ();
    $self->{'addvisRebuildSet'} = \%addvisRebuildSet;

    my %filemergeRebuildSet = ();
    $self->{'filemergeRebuildSet'} = \%filemergeRebuildSet;

    my %compatibleRebuildSet = ();
    $self->{'compatibleRebuildSet'} = \%compatibleRebuildSet;

    my %incompatibleRebuildSet = ();
    $self->{'incompatibleRebuildSet'} = \%incompatibleRebuildSet;

    my %missingDependencies = (); # key is component name value is reference to set of component names representing missing dependencies
    $self->{'missingDependencies'} = \%missingDependencies;
    return $self;
}

# Add the component to a set of components in the incremental delta set that were found to be binary compatible
# Input 1: component name to add
sub addCompToRebuildSetAsCompatible {
    my ($self, $component) = @_;

    if (defined $component) {
        my $rebuildSet = $self->{'compatibleRebuildSet'};
        $rebuildSet->{$component} = $component;
    }
}

# Returns: reference to set of component names that were in the delta set and were determined to be binary compatible with respect to the previous build
sub getCompatibleRebuildSet {
    my ($self) = @_;

    return $self->{'compatibleRebuildSet'};
}

# Add the component to a set of components in the delta set that were marked as bootstrap
# Input 1: component name to add
sub addCompToRebuildSetAsBootstrap {
    my ($self, $component) = @_;

    if (defined $component) {
        my $rebuildSet = $self->{'bootstrapRebuildSet'};
        $rebuildSet->{$component} = $component;
    }
}

# Returns: reference to set of component names that were in the delta set and were marked as bootstrap
sub getBootstrapRebuildSet {
    my ($self) = @_;

    return $self->{'bootstrapRebuildSet'};
}

# Add the component to a set of components in the incremental delta set that were found to be binary incompatible
# Input 1: component name to add 
sub addCompToRebuildSetAsIncompatible {
    my ($self, $component) = @_;

    if (defined $component) {
        my $rebuildSet = $self->{'incompatibleRebuildSet'};
        $rebuildSet->{$component} = $component;
    }
}

# Returns: reference to set of component names that were in the delta set and were determined to be binary incompatible with respect to the previous build
sub getIncompatibleRebuildSet {
    my ($self) = @_;

    return $self->{'incompatibleRebuildSet'};
}

# Add the component to a set of components that were rebuilt because a dependent component in the delta set was binary incompatible
# Input 1: component name to add 
sub addCompToRebuildSetAsTransitive {
    my ($self, $component) = @_;

    if (defined $component) {
        my $rebuildSet = $self->{'transitiveRebuildSet'};
        $rebuildSet->{$component} = $component;
    }
}

# Returns: reference to set of component names that were in the delta set and were rebuilt because a dependent was binary incompatible
sub getTransitiveRebuildSet {
    my ($self) = @_;

    return $self->{'transitiveRebuildSet'};
}

# Add the component to a set of components that were rebuilt because it was in the addvis change set
# Input 1: component name to add 
sub addCompToRebuildSetAsAddVisChange {
    my ($self, $component) = @_;

    if (defined $component) {
        my $rebuildSet = $self->{'addvisRebuildSet'};
        $rebuildSet->{$component} = $component;
    }
}

# Returns: reference to set of component names that were in the delta set and were rebuilt because it is in the addvis set
sub getAddVisRebuildSet {
    my ($self) = @_;

    return $self->{'addvisRebuildSet'};
}

# Add the component to a set of components that were rebuilt because it was in the delta's filemerge set.
# Input 1: component name to add 
sub addCompToRebuildSetAsFilemerge {
    my ($self, $component) = @_;

    if (defined $component) {
        my $rebuildSet = $self->{'filemergeRebuildSet'};
        $rebuildSet->{$component} = $component;
    }
}

# Returns: reference to set of component names that were in the delta set and were rebuilt because it is in the filemerge set
sub getFilemergeRebuildSet {
    my ($self) = @_;

    return $self->{'filemergeRebuildSet'};
}

# Returns: reference to set of component names
sub getCompleteRebuildSet {
    my ($self) = @_;

    my %rebuildSet = ();

    my %rs = %{$self->{'compatibleRebuildSet'}};
    foreach my $c (keys %rs) {
        $rebuildSet{$c} = $c;
    }

    %rs = %{$self->{'incompatibleRebuildSet'}};
    foreach my $c (keys %rs) {
        $rebuildSet{$c} = $c;
    }

    %rs = %{$self->{'transitiveRebuildSet'}};
    foreach my $c (keys %rs) {
        $rebuildSet{$c} = $c;
    }

    %rs = %{$self->{'bootstrapRebuildSet'}};
    foreach my $c (keys %rs) {
        $rebuildSet{$c} = $c;
    }

    %rs = %{$self->{'addvisRebuildSet'}};
    foreach my $c (keys %rs) {
        $rebuildSet{$c} = $c;
    }

    %rs = %{$self->{'filemergeRebuildSet'}};
    foreach my $c (keys %rs) {
        $rebuildSet{$c} = $c;
    }

    return \%rebuildSet;
}

# return a string that contains the rebuild information
#
# It looks like: "compA:t compB:f compC:i compD:c"
#   The t suffix represents that the rebuilt comp was because a transitive effect
#   The f suffix represents that the rebuilt comp was because it is in the filemerge set
#   The i suffix represents that the rebuilt comp was because it is a delta that was binary incompatible
#   The c suffix represents that the rebuilt comp was because it is a delta that was binary compatible
#   The v suffix represents that the rebuilt comp was because it is a delta that had a method add|visibility change
sub getCompleteRebuildSetAsString {
    my ($self) = @_;

    my @list = ();

    my $transitiveRebuildSetRef = $self->getTransitiveRebuildSet();
    my %set = %{$transitiveRebuildSetRef};

    for my $c (keys %set) {
        push (@list, "$c:t");
    }

    my $addvisRebuildSetRef = $self->getAddVisRebuildSet();
    %set = %{$addvisRebuildSetRef};

    for my $c (keys %set) {
        push (@list, "$c:v");
    }

    my $filemergeRebuildSetRef = $self->getFilemergeRebuildSet();
    %set = %{$filemergeRebuildSetRef};

    for my $c (keys %set) {
        push (@list, "$c:f");
    }

    my $compatibleRebuildSetRef = $self->getCompatibleRebuildSet();
    %set = %{$compatibleRebuildSetRef};

    for my $c (keys %set) {
        push (@list, "$c:c");
    }

    my $bootstrapRebuildSetRef = $self->getBootstrapRebuildSet();
    %set = %{$bootstrapRebuildSetRef};

    for my $c (keys %set) {
        push (@list, "$c:b");
    }

    my $incompatibleRebuildSetRef = $self->getIncompatibleRebuildSet();
    %set = %{$incompatibleRebuildSetRef};
    for my $c (keys %set) {
        push (@list, "$c:i");
    }

    my $str = "";
    my @sortedList = sort @list;
    for my $c (@sortedList) {
        $str = "$str $c";
    }
    return $str;
}

# Input 1 : reference to a hash containing information about what Java packages were added and/or deleted
#           during this delta change / incremental rebuild cycle. There are two keys in the hash ('add' and 'delete')
#           See JavaPkgToCompsIndexer.pm for more information.
sub setDeltaAddedOrDeletedJavaPkgs {
    my ($self, $addedOrDeletedJavaPkgs) = @_;
    if (defined $addedOrDeletedJavaPkgs) {
        $self->{'addedOrDeletedJavaPkgs'} = $addedOrDeletedJavaPkgs;
    }
}

# Returns: Reference to hash containing information about what Java packages were added and/or deleted
#           See JavaPkgToCOmpsIndexer.pm for more information.
sub getDeltaAddedOrDeletedJavaPkgs {
    my ($self) = @_;
    return $self->{'addedOrDeletedJavaPkgs'};
}

# Input 1 : $component name of component that has missing dependencies
# Input 2 : $missingDependencies reference to list of component names representing components that 
#           are not declared as dependencies (but actually are needed)
sub addMissingDependenciesForComp {
    my ($self, $component, $missingDependencies) = @_;

    my $md = $self->{'missingDependencies'};

    if (defined $component && defined $missingDependencies) {
        $md->{$component} = $missingDependencies;
    }
}

# Return reference to a hash where key is component name and value is reference to list of component names (missing dependencies)
sub getMissingDependencies {
    my ($self) = @_;
    return $self->{'missingDependencies'};
}

# Update this object to reflect the same values as the supplied string
# Input 1: string representation (in toString frormat)
# BE CAREFUL - changing the format will affect toString parsing
#
sub fromString {
    my ($self, $fromString) = @_;

    # Looks like: "Rebuild set: {comp.A:t comp.B:f comp.C:i comp.D:i}"
    if ($fromString =~ /Rebuild set:/) {
        my @rebuildInfo = ($fromString =~ /[\w\.]+:[bcitf]/g);
        if ($#rebuildInfo >= 0) {
            for my $c (@rebuildInfo) {
                my @tokens = split(':', $c);
                if ($tokens[1] eq 'c') {
                    $self->addCompToRebuildSetAsCompatible($tokens[0]);
                }
                elsif ($tokens[1] eq 'b') {
                    $self->addCompToRebuildSetAsBootstrap($tokens[0]);
                }
                elsif ($tokens[1] eq 'i') {
                    $self->addCompToRebuildSetAsIncompatible($tokens[0]);
                }
                elsif ($tokens[1] eq 'f') {
                    $self->addCompToRebuildSetAsFilemerge($tokens[0]);
                }
                elsif ($tokens[1] eq 't') {
                    $self->addCompToRebuildSetAsTransitive($tokens[0]);
                }
                elsif ($tokens[1] eq 'v') {
                    $self->addCompToRebuildSetAsAddVis($tokens[0]);
                }
            }
        }
    }

    # Looks like: "Missing Dependencies: {comp.A => { comp.B comp.C } comp.D => { comp.E comp.F|comp.F2 }}"
    if ($fromString =~ /Missing Dependencies:/) {
        my @missingDependInfo = ($fromString =~ /[\w\.\|]+ => {[ \w\.\|]*}/g);
        if ($#missingDependInfo >= 0) {
            for my $c (@missingDependInfo) {
                my @tokens = split(' => ', $c);
                # tokens[0] is the component name that has missing dependencies
                # tokens[1] is a string like: { compB compC }
                my @md = ($tokens[1] =~ /[\w\.\|]+/g);
                if ($#md >= 0) {
                    $self->addMissingDependenciesForComp($tokens[0], \@md);
                }
            }
        }
    }
} # fromString

# Return string represntation of this object
# TODO Finish adding info on added/deleted Java packages
# BE CAREFUL - changing the format will affect fromString parsing
sub toString {
    my ($self) = @_;

    # Looks like: "Rebuild set: {compA:t compB:f compC:i compD:ci}"
    my $str = "Rebuild set: {" . $self->getCompleteRebuildSetAsString() . "}\n";

    # Looks like: "Missing Dependencies: { compA => { compB compC } compD => { compE compF|compF2 }}"
    my $mdRef = $self->getMissingDependencies();
    my %md = %{$mdRef};
    my $mdSize = keys %md;

    if ($mdSize > 0) {
        $str = "$str\tMissing Dependencies: { ";
        for my $c (keys %md) {
            $str = $str . "$c => {";
            my $mdcRef = $md{$c};
            my @mdc = @{$mdcRef};
            for my $d (@mdc) {
                $str = $str . " $d ";
            }
            $str = "$str} ";
        }
        $str = "$str }\n";
    }

#    $str = $str . "\tAdded Java Packages: ";
#    my $addedOrDeletedJavaPkgs = $self->getDeltaAddedOrDeletedJavaPkgs();
#
#    $str = $str . "\tDeleted Java Packages: ";
    return $str;
}

# Static Utility (not an instance method) to compare two sets
# Input 1,2: reference to a set (hash with key == value) where key is a component name
# returns 1 if identical; 0 otherwise
sub _compareComponentNameSet {
    my ($set1Ref, $set2Ref) = @_;

    if ((defined $set1Ref) && (! defined $set2Ref)) {
        return 0;
    }
    if ((defined $set2Ref) && (! defined $set1Ref)) {
        return 0;
    }
    if ((! defined $set1Ref) && (! defined $set2Ref)) {
        return 1;
    }
    my %set1 = %{$set1Ref};

    for my $c (keys %set1) {
        my $c2 = $set2Ref->{$c};
        if (! ((defined $c2) && ($c eq $c2))) {
            return 0;
        }
    }
    return 1;
}

# Static Utility (not an instance method) to compare two sets
# Input 1: reference to a list of component names
# returns 1 if identical; 0 otherwise
sub _compareComponentNameList {
    my ($list1Ref, $list2Ref) = @_;

    my @list1 = @{$list1Ref};
    my @list2 = @{$list2Ref};

    if ($#list1 != $#list2) {
        return 0;
    }
    for my $c (@list1) {
        my $found = 0;
        for my $c2 (@list2) {
            if ($c eq $c2) {
                $found = 1;
            }
        }
        if (! $found) {
            return 0;
        }
    }
    return 1;
}

# Input 1: reference to IncrBuildMgrResults or a string form (via toString) to compare with this
# returns : 1 if identical; 0 otherwise
sub compare {
    my ($self, $resultsOrString) = @_;

    my $results;

    my $is_results = $resultsOrString->isa("ariba::rc::IncrBuildMgrResults");

    if (! $is_results) {
        $results = ariba::rc::IncrBuildMgrResults->new();
        $results->fromString($resultsOrString);
    }
    else {
        $results = $resultsOrString;
    }

    my $setRef1 = $self->getTransitiveRebuildSet();
    my $setRef2 = $results->getTransitiveRebuildSet();
    my $identical = _compareComponentNameSet($setRef1, $setRef2);
    if (! $identical) {
        return 0;
    }

    $setRef1 = $self->getCompatibleRebuildSet();
    $setRef2 = $results->getCompatibleRebuildSet();
    $identical = _compareComponentNameSet($setRef1, $setRef2);
    if (! $identical) {
        return 0;
    }

    $setRef1 = $self->getFilemergeRebuildSet();
    $setRef2 = $results->getFilemergeRebuildSet();
    $identical = _compareComponentNameSet($setRef1, $setRef2);
    if (! $identical) {
        return 0;
    }

    $setRef1 = $self->getBootstrapRebuildSet();
    $setRef2 = $results->getBootstrapRebuildSet();
    $identical = _compareComponentNameSet($setRef1, $setRef2);
    if (! $identical) {
        return 0;
    }

    $setRef1 = $self->getIncompatibleRebuildSet();
    $setRef2 = $results->getIncompatibleRebuildSet();
    $identical = _compareComponentNameSet($setRef1, $setRef2);
    if (! $identical) {
        return 0;
    }

    # Recall the missing dependencies datastructure is 
    # a hash <key component name; value is a reference to a set <key component name; value component name>>
    my $mdRef1 = $self->getMissingDependencies();
    my $mdRef2 = $results->getMissingDependencies();

    my %md1 = %{$mdRef1};
    my %md2 = %{$mdRef2};

    my $md1Size = keys %md1;
    my $md2Size = keys %md2;

    if ($md1Size != $md2Size) {
        return 0;
    }

    for my $c (keys %md1) {
        my $list2Ref = $mdRef2->{$c};
        if (! defined $list2Ref) {
            return 0;
        }
        my $list1Ref = $mdRef1->{$c};
        $identical = _compareComponentNameList($list1Ref, $list2Ref);
        if (! $identical) {
            return 0;
        }
    }

    my $addDeletePkgsRef1 = $self->{'addedOrDeletedJavaPkgs'};
    my $addDeletePkgsRef2 = $results->{'addedOrDeletedJavaPkgs'};
    # TODO check the above also
    return 1;
} # compare

1;
