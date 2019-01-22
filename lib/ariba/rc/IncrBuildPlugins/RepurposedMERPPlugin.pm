package ariba::rc::IncrBuildPlugins::RepurposedMERPPlugin;

use strict;
use warnings;
use ariba::rc::CompMeta;

use base ("ariba::rc::IncrBuildPlugins::IncrBuildPluginBase");

#
# The Incr Build generic system does not handle this rare case specifically but exposes a plugin framework that was developed to offer the ability to 
# enhance Incr Build logic when such corner case shows up.
# 
# A change to RepurposeConfigFileProcessor.java should be marked as incompatible change and should force trigger a build for all the components.
# This will make sure that the repurposed suite files will be generated accurately.
#


# Input 1: ref to CompMeta for delta component to determine if it was changed in such a way that all comps that depend on it should be rebuilt
# Return 1 if the delta must be rebuilt (the p4 diff intersects the repurpose selenium table); else 0
sub isTransitiveRebuildRequired {
    my ($self, $deltaCompMeta) = @_;
    
    my $compname = $deltaCompMeta->getName() ;
    if (defined $compname && $compname eq 'test.framework') {
        
        my $fileDiffsRef = $deltaCompMeta->getFileDiffs();
        if (defined $fileDiffsRef) {
            my @fileDiffs = @{$fileDiffsRef};
            foreach my $diff (@fileDiffs) {
                if ($diff =~ /RepurposeConfigFileProcessor.java#/ && ($diff =~ /==== content/ || $diff =~ /<none>/)) {
                    return 1;
                }
            }
        }
    }
    return 0;
}

1;
