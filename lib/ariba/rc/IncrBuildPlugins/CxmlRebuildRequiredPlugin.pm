package ariba::rc::IncrBuildPlugins::CxmlRebuildRequiredPlugin;

use strict;
use warnings;
use ariba::rc::CompMeta;

use base ("ariba::rc::IncrBuildPlugins::IncrBuildPluginBase");

# The cxmldtd component must be built if certain children are changed as it acts like an installer
# for the files contributed by its children.

sub isTransitiveRebuildRequired {
    my ($self, $deltaCompMeta) = @_;

    my $compName = $deltaCompMeta->getName();
    if ($compName && $compName =~ /ariba.cxml/) {
        my $fileDiffsRef = $deltaCompMeta->getFileDiffs();
        if (defined $fileDiffsRef) {
            my @fileDiffs = @{$fileDiffsRef};
            foreach my $diff (@fileDiffs) {
                if ($diff =~ /content/) {
                    print "IncrBuildPlugins::CxmlRebuildRequiredPlugin detected a change that demands that cxmldtd be rebuilt (The transitive rebuild flag will be set)\n";
                    return 1;
                }
                if ($diff =~ /<none>/) {
                    print "IncrBuildPlugins::CxmlRebuildRequiredPlugin detected an addition or deletion that demands that cxmldtd be rebuilt (The transitive rebuild flag will be set)\n";
                    return 1;
                }
            }
        }
    }
    return 0;
}

1;
