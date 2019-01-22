package ariba::rc::CompMeta;

use strict;
use warnings;
use Data::Dumper;

#
# CompMeta
#
# Defines a wrapper/ generic abstraction layer object that represents
# component metadata. A CompMeta object may encapsulate a ProductDefinition 
# described component (Platform products). It may also describe the metadata
# for non ProductDefinition described objects like the AN specific components
# or unit test objects.
#
# In all cases, if a value for an attribute is injected via a set method
# then that value will be what is returned via the getter. If no attribute
# was injected via a set method AND the object wraps a ProductDefinition,
# then the get methods will return the ProductDefinition values.
#
# In other words, the local values defined on this object will take precedence
# over values on a wrapped ProductDefinition.

#
# Constructor
sub new {
    my $class = shift;
    my $productDefinition = shift;
    my $self = {};
    bless ($self, $class);

    if ($productDefinition) {
        $self->setProductDefinition($productDefinition);
    }
    return $self;
}

# Returns a reference to CompMeta that is identical to this
sub clone {
    my ($self) = @_;
    my $compMetaClone = ariba::rc::CompMeta->new();
    $compMetaClone->setProductDefinition($self->getProductDefinition());

    my $n = $self->getName(1);
    if ($n) {
        $compMetaClone->setName($n);
    }

    $n = $self->getSrcPath(1);
    if ($n) {
        $compMetaClone->setSrcPath($n);
    }

    $n = $self->getPublishedArtifactPaths(1);
    if ($n) {
        $compMetaClone->setPublishedArtifactPaths($n);
    }

    $n = $self->getDependencyNames(1);
    if ($n) {
        $compMetaClone->setDependencyNames($n);
    }

    $n = $self->getLabel(1);
    if ($n) {
        $compMetaClone->setLabel($n);
    }

    $n = $self->getBaselineP4Spec();
    if ($n) {
        $compMetaClone->setBaselineP4Spec($n);
    }

    $n = $self->getCleanCommand();
    if ($n) {
        $compMetaClone->setCleanCommand($n);
    }

    $n = $self->getBuildCommand(1);
    if ($n) {
        $compMetaClone->setBuildCommand($n);
    }

    $compMetaClone->setBuildOrder($self->getBuildOrder());
    $compMetaClone->setBootstrap($self->isBootstrap());
    if ($self->isNew()) {
        $compMetaClone->markAsNew();
    }
    if ($self->isDeleted()) {
        $compMetaClone->markAsDeleted();
    }

    if ($self->isMarkedAsHubDoNotIndex()) {
        $compMetaClone->markAsHubDoNotIndex();
    }
    if ($self->isMarkedToAlwaysBuild()) {
        $compMetaClone->markToAlwaysBuild();
    }

    my $diffsref = $self->getFileDiffs();
    my @diffs = ();
    push (@diffs, @{$diffsref});
    $compMetaClone->setFileDiffs(\@diffs);

    return $compMetaClone;
}

# Input 1: reference to list of p4 diff2 diffs
sub setFileDiffs {
    my ($self, $diffsRef) = @_;
    $self->{'diffsRef'} = $diffsRef;
}

# Return reference to list of p4 diff2 diffs
sub getFileDiffs {
    my ($self) = @_;
    return $self->{'diffsRef'};
}

# mark this as a component that is not to be indexed 
# like for AN 'no name' components (those with nested projects)
sub markAsHubDoNotIndex {
    my ($self) = @_;
    $self->{'hubDoNotIndex'} = 1;
}

# Return 1 if this component should not be indexed
sub isMarkedAsHubDoNotIndex {
    my ($self) = @_;
    return $self->{'hubDoNotIndex'};
}

# mark this this component to always be built
sub markToAlwaysBuild {
    my ($self) = @_;
    $self->{'alwaysBuild'} = 1;
}

# Return 1 if this component should always be built
sub isMarkedToAlwaysBuild {
    my ($self) = @_;
    return $self->{'alwaysBuild'};
}

# Input 1: number representing the relative build order for this component
# This is used to determine the order to build the product universe roots
sub setBuildOrder {
    my ($self, $buildOrder) = @_;
    $self->{'buildOrder'} = $buildOrder;
}

# Returns: number representing the relative build order for this component
# This is used to determine the order to build the product universe roots
sub getBuildOrder {
    my ($self) = @_;
    return $self->{'buildOrder'};
}

# Call this to mark this as a bootstrap component (requires transitive rebuilds)
# Input 1: Pass 1 if this is bootstrap comp requires transitive builds of components that depend on it; 0 if it can be build standalone
sub markAsBootstrap {
    my ($self, $buildTransitively) = @_;

    if ($buildTransitively) {
        $self->{'markAsBootstrap'} = 2;
    }
    else {
        $self->{'markAsBootstrap'} = 1;
    }
}

# Return 2 if this comp is marked as a boostrap component (requires transitive rebuilds)
sub isTransitiveBootstrap {
    my ($self) = @_;
    if (defined $self->{'markAsBootstrap'} && $self->{'markAsBootstrap'} == 2) {
        return 2;
    }
    return 0;
}

# Return 1 if this comp is marked as a boostrap component (does not require transitive rebuilds)
sub isStandaloneBootstrap {
    my ($self) = @_;
    if (defined $self->{'markAsBootstrap'} && $self->{'markAsBootstrap'} == 1) {
        return 1;
    }
    return 0;
}

# Return non-zero if this comp is marked as a boostrap component (either standalone or transitive)
sub isBootstrap {
    my ($self) = @_;
    return $self->{'markAsBootstrap'};
}

sub setBootstrap {
    my ($self, $bs) = @_;
    $self->{'markAsBootstrap'} = $bs;
}

#
# Components that are newly added into the product universe should be marked
# as new. The IncrementalBuildMgr uses this fact when considering whether
# or not to perform Binary compatibility checks (obviously there is no prior
# artifacts for this component if it's new)
#
sub markAsNew {
    my ($self) = @_;
    $self->{'markedAs'} = "new";
}

# Return 1 if the component is marked as new; 0 otherwise
sub isNew {
    my ($self) = @_;
    my $markedAs = $self->{'markedAs'};
    if (defined $markedAs && $markedAs eq "new") {
        return 1;
    }
    return 0;
}

#
# Components that are deleted from the product universe should be marked
# as new. The IncrementalBuildMgr uses this fact when considering whether
# or not to perform Metadata validation and binary compatibility checks.
#
sub markAsDeleted {
    my ($self) = @_;
    $self->{'markedAs'} = "deleted";
}

# Return 1 if the component is marked as deleted; 0 otherwise
sub isDeleted {
    my ($self) = @_;
    my $markedAs = $self->{'markedAs'};
    if (defined $markedAs && $markedAs eq "deleted") {
        return 1;
    }
    return 0;
}

# In cases where a product component is described by a ProductDefinition,
# this routine should be used to inject that into this CompMeta instance.
#
# The IncrBuildMgr will use this API for Platform products (including the
# AN hub component)
#
# Input param 1 : reference to an instance of ProductDefinition
sub setProductDefinition {
    my ($self, $productDefinition) = @_;

    $self->{'productDefinition'} = $productDefinition;
}

#
# The IncrBuildMgr will use this API for Platform products (including the
# AN hub component)
# Returns : reference to an instance of ProductDefinition (if defined)
sub getProductDefinition {
    my ($self) = @_;

    return $self->{'productDefinition'};
}

# In cases where a product component is not described by a ProductDefinition,
# this routine should be used to inject the component name into this CompMeta instance.
# If there is a ProductDefinition, this local value will take precedence
#
# Input param 1 : String name for the component
sub setName {
    my ($self, $name) = @_;

    $self->{'name'} = $name;
}

# Input 1: scalar non-zero to not consider productDefintion
# Return the name for this component
sub getName {
    my ($self, $wrapperOnly) = @_;

    if ($self->{'name'}) {
        return $self->{'name'};
    }
    unless ($wrapperOnly) {
        my $prodDef = $self->getProductDefinition();
        if ($prodDef) {
            return $prodDef->modname();
        }
    }
    return undef;
}

# In cases where a product component is described by a ProductDefinition,
# this routine should be used to inject that into this CompMeta instance.
# If there is a ProductDefinition, this local value will take precedence
#
# Input param 1 : String path to the component source directory
sub setSrcPath {
    my ($self, $srcPath) = @_;

    $self->{'srcPath'} = $srcPath;
}

# Input 1: scalar non-zero to not consider productDefintion
# Return the source path for this component
sub getSrcPath {
    my ($self, $wrapperOnly) = @_;

    if ($self->{'srcPath'}) {
        return $self->{'srcPath'};
    }
    unless ($wrapperOnly) {
        my $prodDef = $self->getProductDefinition();
        if ($prodDef) {
            return $prodDef->clientDir();
        }
    }
    return undef;
}

# Set the published artifact paths for this instance
#
# Input param 1 : reference to a list of String paths to each of the component's published artifacts
sub setPublishedArtifactPaths {
    my ($self, $artifactPaths) = @_;

    if ($artifactPaths) {
        my @ap = ();
        push (@ap, @$artifactPaths);
        $self->{'artifactPaths'} = \@ap;
    }
}

# Set the clean command
# Input 1: string command to invoke to clean this component
sub setCleanCommand {
    my ($self, $cmd) = @_;

    $self->{'cleancommand'} = $cmd;
}

#
# Return the string clean command
#
sub getCleanCommand {
    my ($self) = @_;

    return $self->{'cleancommand'};
}

# Set the p4 path spec includes baseline product label
# Input 1: p4 path to component at baseline label
sub setBaselineP4Spec {
    my ($self, $spec) = @_;

    $self->{'baselineP4Spec'} = $spec;
}

#
# Return the string p4 path spec
#
sub getBaselineP4Spec {
    my ($self) = @_;

    return $self->{'baselineP4Spec'};
}

# Set the build command (overrides any defined on a wrapped ProductDefinition
# Input 1: string command to invoke to build this component
sub setBuildCommand {
    my ($self, $cmd) = @_;

    $self->{'command'} = $cmd;
}

#
# Input 1: scalar non-zero to not consider productDefintion
# Return the string build command
#
sub getBuildCommand {
    my ($self, $wrapperOnly) = @_;

    if ($self->{'command'}) {
        return $self->{'command'};
    }
    unless ($wrapperOnly) {
        my $prodDef = $self->getProductDefinition();
        if ($prodDef) {
            return $prodDef->command();
        }
    }
    return undef;
}

# Update the published artifact paths for this instance
#
# Input param 1 : reference to a list of String paths to each of the component's published artifacts
sub updatePublishedArtifactPaths {
    my ($self, $artifactPaths) = @_;

    if ($artifactPaths) {
        push (@{$self->{'artifactPaths'}}, @$artifactPaths);
    }
}

# Return a reference to an array of String representing the path to an artifact (jar|zip file) published by this component
sub getPublishedArtifactPaths {
    my ($self) = @_;
    
    # artifactPaths is not set in productDefinition.
    # Hence, we'll not check for the productDefinition object
    unless ($self->{'artifactPaths'}) {
        my @ap = ();
        $self->{'artifactPaths'} = \@ap;
    }
    return $self->{'artifactPaths'};
}

# set an array of component names that this component depends on.
# In cases where a product component is described by a ProductDefinition,
# we typically do not expect this API to be used. In other cases like
# non-hub AN components this API should be used.
#
# Input param 1 : reference to an array of String representing the component names being depended on
sub setDependencyNames {
    my ($self, $dependencyNames) = @_;

    if ($dependencyNames) {
        my @dn = ();
        push (@dn, @$dependencyNames);
        $self->{'dependencyNames'} = \@dn;
    }
}

# In cases where a product component is described by a ProductDefinition,
# this routine should be used to inject that into this CompMeta instance.
#
# Input 1: scalar non-zero to not consider productDefintion
# Return an array of String representing component names that this COmpMeta described object depends upon
# Return a reference to an array of String representing component names that this COmpMeta described object depends upon
# Return a ref to an array of String representing component names that this COmpMeta described object depends upon
sub getDependencyNames {
    my ($self, $wrapperOnly) = @_;

    if ($self->{'dependencyNames'}) {
        return $self->{'dependencyNames'};
    }
    unless ($wrapperOnly) {
        my $prodDef = $self->getProductDefinition();
        if ($prodDef) {
            my $dependencyList = $prodDef->depends() || "";
            my @dependencyNames = split(/,/,$dependencyList);
            return \@dependencyNames;
        }
    }
    my @dn = ();
    $self->{'dependencyNames'} = \@dn;
    return \@dn;
}

#In cases where a product component is not described by a ProductDefinition,
# this routine should be used to inject the component name into this CompMeta instance.
#
# Input param 1 : String label for the component
sub setLabel {
    my ($self, $label) = @_;

    $self->{'label'} = $label;
}

# Input 1: scalar non-zero to not consider productDefintion
# Return the label for this component
sub getLabel {
    my ($self, $wrapperOnly) = @_;

    if ($self->{'label'}) {
        return $self->{'label'};
    }
    unless ($wrapperOnly) {
        my $prodDef = $self->getProductDefinition();
        if ($prodDef) {
            return $prodDef->label();
        }
    }
    return undef;
}

sub setP4Dir {
    my ($self, $p4Dir) = @_;

    $self->{'p4dir'} = $p4Dir;
}

# Input 1: scalar non-zero to not consider productDefintion
sub getP4Dir {
    my ($self, $wrapperOnly) = @_;

    if ($self->{'p4dir'}) {
        return $self->{'p4dir'};
    }
    unless ($wrapperOnly) {
        my $prodDef = $self->getProductDefinition();
        if ($prodDef) {
            return $prodDef->p4dir();
        }
    }
    return undef;
}

1;
