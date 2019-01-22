# This is really ariba::Ops::ProductDevelopmentMachine, but it is swizzled at
# startup time to be a drop in replacement for ariba::Ops::Machine
package ariba::Ops::Machine;

use strict;
use base qw(ariba::Ops::CommonMachineMethods ariba::Ops::ProductDevelopmentMachineDBI);

use ariba::Ops::MachineFields;
use ariba::Ops::ProductDevelopmentMachineService;

my $fields = $ariba::Ops::MachineFields::fields;

{
	my $class = __PACKAGE__;

	# We can't use Class::DBI::Oracle here because we have columns with studlyCaps
	$class->table('MACHINEDB');

	# keep this up to date automatically.
	my @fields = ();

	# these are special, weed them out.
	for my $field (ariba::Ops::CommonMachineMethods->listFields()) {
		next if $field eq 'hostname';
		next if $field eq 'datacenter';
		next if $field eq 'maintenance';
		next if $field eq 'providesServices';

		push @fields, $field;
	}

	$class->columns('Primary'   => 'hostname');
	$class->columns('Essential' => @fields);
	$class->columns('TEMP'      => qw/
		tier oldStatus oldTime newStatus newTime newError 
		notifyError notifyStatus oldError notifyTime maintenance
	/);

	# setup the one-many mapping
	$class->has_many(
		'providesServices',
		'ariba::Ops::ProductDevelopmentMachineService' => 'hostname'
	);
}

sub _matchPropertiesInObjects {
	my ($class, $fieldMatchMap) = @_;

	my %search = ();

	while (my ($field, $value) = each %{$fieldMatchMap}) {

		unless ($fields->{$field}) {
			warn $class,"->_matchPropertiesInObjects() called with non-existant field: [$field]\n" .
			"This is an API mistake, fix caller of ", $class, "->machinesWithProperties().\n\n";
		}

		for my $subValue (split /,/, $value) {

			$subValue =~ s/^\s*//g;
			$subValue =~ s/\s*$//g;

			push @{$search{$field}}, $subValue;
		}
	}

	# see Class::DBI::AbstractSearch
	return $class->search_where(%search);
}

sub databaseName {
	my $class = shift;
	
	return "Product Development";
}

sub datacenter {
	my $self = shift;
	return 'pd';
}

1;

__END__
