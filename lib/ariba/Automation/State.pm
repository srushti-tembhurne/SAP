package ariba::Automation::State;

use ariba::Ops::PersistantObject;
use base qw(ariba::Ops::PersistantObject);

use ariba::Automation::Constants;
use ariba::Automation::GlobalState;

# 
# use new() constructor from PersistantObject
#

sub dir {
	my $class = shift;

	return ariba::Automation::Constants::stateDirectory();
}

1;
