package ariba::SNMP::Config;

# $Id: //ariba/services/tools/lib/perl/ariba/SNMP/Config.pm#1 $
#
# This package corresponds to one section of the snmp config file.
# It holds the machineMatchQuery and the list of oidStrings specified
# in the config file.

package ariba::SNMP::Config;

use base qw(ariba::Ops::PersistantObject);

# class methods
sub objectLoadMap {
	my $class = shift;

	my %map = (
		'oids'		=> '@SCALAR',
		'oidsNames'	=> '@SCALAR',
		'walkOids'	=> '@SCALAR',
		'walkOidsNames'	=> '@SCALAR',
		'matches'	=> '@SCALAR',
	);

	return \%map;
}

sub dir {
	my $class = shift;

	# don't have a backing store
	return undef;
}

1;

__END__
