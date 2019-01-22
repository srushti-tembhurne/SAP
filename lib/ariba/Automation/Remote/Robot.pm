package ariba::Automation::Remote::Robot;

use strict;
use warnings;

use ariba::Automation::Robot;
use base qw(ariba::Automation::Robot);

use ariba::Automation::Constants;

{
no warnings;

INIT {
	my $rootDir = ariba::Automation::Constants->serverRootDir();
	ariba::Automation::Constants->setBaseRootDirectory($rootDir);
}
use warnings;
}

sub configFile {
	my $self = shift;

	return $self->configFileForRobotName($self->instance());
}

1;
