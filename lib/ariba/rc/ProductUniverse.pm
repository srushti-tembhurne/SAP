package ariba::rc::ProductUniverse;

#
# This class represents the product universe. This acts as the link between the
# productDeifnition and the new CompMeta object.
#
#

use strict;
use warnings;
use ariba::rc::CompMeta;
use ariba::rc::PublishedArtifactIndexer;

#
# Constructor
#
sub new {
    my $class = shift;
    my $self = {};
    bless ($self, $class);

    return $self;
}

sub _isDebug {
    my ($self) = @_;
    return $self->{'debug'};
}

sub setDebug {
    my ($self, $flag) = @_;
    $self->{'debug'} = $flag;
}

# Base class no-op
sub updateCompMetaUniverseBuildCommand {
    my ($self, $productUniverse, $buildAll) = @_;
}

# set the cleanCommand if the comp was using 'gnu make install' to 'gnu make clean'
# Ideally, the component.bdf declares the clean command
# Input 1: A reference to CompMeta
sub determineAndSetCleanCommand {
    my ($self, $compMeta) = @_;

    if ($compMeta && $compMeta->getBuildCommand()) {
        my $cmd = $compMeta->getBuildCommand();
        if ($cmd =~ /gnu\smake\s$/) {
            $cmd =~ s/gnu\smake\s/gnu make clean/;
            $compMeta->setCleanCommand($cmd);
        }
        elsif ($cmd =~ /gnu\smake\sinstall/) {
            $cmd =~ s/gnu\smake\sinstall/gnu make clean/;
            $compMeta->setCleanCommand($cmd);
        }
    }
}

# Input1: Array Ref to the productDefinition
# Returns an array ref to compMeta objects
sub getCompMetaUniverse {
    my ($self, $productDefinition, $buildAll) = @_;

    my @compMetaUniverse;

    # Inject productDefinition into the compMeta objects
    foreach my $component (@$productDefinition) {
        # We have an item in the productUniverse that represnts the product.
        # The modname for this item is not set. We do not need this in IcrBuild
        # Skipping this item.
        next if (! $component->modname());

        my $compMetaObj = $self->_getCompMetaForComp($component);
        push (@compMetaUniverse,$compMetaObj);
    }

    $self->_updateCompMetaUniverseWithPublishedArtifactInfo(\@compMetaUniverse);

    # TODO: Check the return value for the above call against the number of components in Universe

    return \@compMetaUniverse;
}

# Input 1: reference to ProductDefinition object to wrap
# Return: CompMeta reference
sub _getCompMetaForComp {
    my ($self, $prodDef) = @_;

    my $compMeta = ariba::rc::CompMeta->new($prodDef);
    $self->determineAndSetCleanCommand($compMeta);
    return $compMeta;
}

# Input 1: reference to list of CompMeta objects in the universe
# Input 2: non-zero scalar to append to published artifact list
# Input 3: non-zero scalar means to search only the root directory
sub _updateCompMetaUniverseWithPublishedArtifactInfo {
    my ($self, $compMetaUniverseListRef, $update, $rootOnly) = @_;

    my $pa = ariba::rc::PublishedArtifactIndexer->new();
    $pa->updateCompMetaWithPublishedArtifactsViaSearch($compMetaUniverseListRef, $update, $rootOnly);
}

1;
