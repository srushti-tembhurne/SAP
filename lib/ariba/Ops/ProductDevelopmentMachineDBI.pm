package ariba::Ops::ProductDevelopmentMachineDBI;

use strict;
use base qw(ariba::Ops::ClassDBIBase);

BEGIN {
	my $class = __PACKAGE__;

	# these should be somewhere else.
	my $host = 'pence.ariba.com';
	my $sid  = 'SO920DEV';
	my $user = 'machinedb';
	my $pass = 'machinedb';

	my %dbiSettings = (
		PrintError => 0,
		RaiseError => 1,
		AutoCommit => 1,
	);

	my $dsn = sprintf("dbi:Oracle:host=%s;sid=%s", $host, $sid);

	# this is Class::DBI notation for connecting to the db.
	$class->set_db('Main', $dsn, $user, $pass, \%dbiSettings);
}

1;
