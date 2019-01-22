package ariba::Automation::BuildnameFromCurrentRCBuildLabelNonQualAction;

# Derivation of BuildnameFromCurrentRCBuildLabelAction that can be used for non qual
# robot purposes like comparing builds
#
# In other words, the Robot.pm is tightly coupled with BuildnameFromCurrentRCBuildLabelAction
# in that if BuildnameFromCurrentRCBuildLabelAction is used it is considered a qual robot.
#
# Because we want to use BuildnameFromCurrentRCBuildLabelAction in a non-qual robot case,
# like executing BuildDiffAction instead of a migrate action, then we need a way to tell
# the system BuildnameFromCurrentRCBuildLabelAction is not for a qual robot. 
# We do this by using BuildnameFromCurrentRCBuildLabelNonQualAction instead of BuildnameFromCurrentRCBuildLabelAction
# 
use warnings;
use strict;

use ariba::Automation::BuildnameFromCurrentRCBuildLabelAction;

use base qw(ariba::Automation::BuildnameFromCurrentRCBuildLabelAction);

1;
