package ariba::Ops::ProductDevelopmentMachineService;

use strict;
use base qw(ariba::Ops::ProductDevelopmentMachineDBI);

BEGIN {
	# this is Class::DBI notation for connecting to the db.
	my $class = __PACKAGE__;

	# We can't use Class::DBI::Oracle here because we have columns with studlyCaps
	$class->table('MACHINESERVICES');

	$class->columns('All' => qw/service hostname/);
}

1;
