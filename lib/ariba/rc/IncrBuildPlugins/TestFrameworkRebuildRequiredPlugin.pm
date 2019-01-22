package ariba::rc::IncrBuildPlugins::TestFrameworkRebuildRequiredPlugin;

use strict;
use warnings;
use ariba::rc::CompMeta;

use base ("ariba::rc::IncrBuildPlugins::IncrBuildPluginBase");

# Defensive transitive rebuild of all components depending on 
# test-framework.
sub isTransitiveRebuildRequired {
    my ($self, $deltaCompMeta) = @_;

    my $compName = $deltaCompMeta->getName();
    if ($compName eq "test.framework") {
        print "IncrBuildPlugins::TestFrameworkPlugin has detected a change to test.framework; forcing transitive rebuilds\n";
        return 1;
    }
    return 0;
}

1;