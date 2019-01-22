package ariba::rc::IncrBuildPlugins::RepurposeSeleniumRebuildRequiredPlugin;

use strict;
use warnings;
use ariba::rc::CompMeta;

use base ("ariba::rc::IncrBuildPlugins::IncrBuildPluginBase");

#
# Some test components when changed, require that comps that depend on them to be rebuilt
# in the incremental build system. In this case changing a repurposed selenium script (like in test.expense)
# should trigger components that depend on that comp should be rebuilt (like test.buyer.base)
#

# Input 1: filename of the config-repurpose-blocks.table to read/cache
sub _loadRepurposeTable {
    my ($self, $f) = @_;

    my @tableLineEntries = ();

    open(INPUTFILE, "<" . $f)  || die("Cannot open config-repurpose-blocks.table file \"$f\"\n"); 

    while(<INPUTFILE>) {
        my($line) = $_;
        chomp($line);

        if ($line =~ /"selenium\//) {
            my @linea = split(/\//, $line);
            my $lasttok = pop (@linea); # matching only the basename is good enough for our incr build safety
            $lasttok =~ s/\".*$//;
            push (@tableLineEntries, $lasttok);
        }
    }
    close(INPUTFILE);

    $self->{'tableLineEntriesRef'} = \@tableLineEntries;
}

# Load the repurpose table when the passed in CompMeta comp contains the repurpose table
# Input 1: reference to hash key is component name and value is CompMeta object reference
sub _preloadComp {
    my ($self, $productUniverseMap) = @_;

    # Register special components that need preloading for this plugin to work correctly.
    # For example, the component 'test.buyer.base'
    # contains a .table file that lists repurposed selenium scripts. 
    # This file has to be preloaded so
    # that if a component that depends on test.buyer.base is changed (like test.expense),
    # such that one of the repurposed files is touched, then that component change is to 
    # be considered as an incompatible change, which triggers test.buyer.base to be rebuilt. 
    my $preloadCompMeta = $productUniverseMap->{'test.buyer.base'};
    if (! defined $self->{'tableLineEntriesRef'} && $preloadCompMeta) {
        my $srcDir = $preloadCompMeta->getSrcPath();
        my $fn = "$srcDir/config-repurpose-blocks.table";
        if (-f $fn) {
            $self->_loadRepurposeTable($fn);
        }
    }
}

# Input 1: string p4 diff2 line 
# Return 1 if the diff refers to a file that intersects the reporpose table
sub _diffIntersectsTable {
    my ($self, $diffLine) = @_;

    if (defined $self->{'tableLineEntriesRef'}) {
        my @tableLineEntries = @{$self->{'tableLineEntriesRef'}};
        foreach my $tle (@tableLineEntries) {
            if ($diffLine =~ /$tle/) {
                return 1;
            }
        }
    }
    return 0;
}

# Input 1: ref to CompMeta for delta component to determine if it was changed in such a way that all comps that depend on it should be rebuilt
# Return 1 if the delta must be rebuilt (the p4 diff intersects the repurpose selenium table); else 0
sub isTransitiveRebuildRequired {
    my ($self, $deltaCompMeta) = @_;

    my $fileDiffsRef = $deltaCompMeta->getFileDiffs();
    if (defined $fileDiffsRef && defined $self->{'tableLineEntriesRef'}) {
        my @fileDiffs = @{$fileDiffsRef};
        foreach my $diff (@fileDiffs) {
            if (($diff =~ /==== content/ || $diff =~ /<none>/) && ($diff =~ /config-repurpose-blocks.table/ || $self->_diffIntersectsTable($diff))) {
                return 1;
            }
        }
    }
    return 0;
}

1;
