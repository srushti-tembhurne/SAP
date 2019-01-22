package ariba::monitor::CDBFactory;

use ariba::rc::Globals;

# Class method
# URI looks like :
#  - outage://an/dev/uptime 
#  - file://snmp/jay.ariba.com/Percent_Mem_Usage
sub new {
	my $class = shift;
	my $uri = shift;

	return undef unless ($uri);

	if ($uri =~ m|^file:|) {
		return circularDBFactory($uri);
	}
	elsif ($uri =~ m|^outage:|) {
		return outageDBFactory($uri);
	}

	# By default it will be considered as a regular Circular DB
	return ariba::monitor::CircularDB->new($uri);

}


sub circularDBFactory {
	my $uri = shift;

	use ariba::monitor::CircularDB;

	$uri =~ m/^file:\/\/(.*)$/i; 
	my $cdb = $1;
	return ariba::monitor::CircularDB->new($cdb);

}


sub outageDBFactory {
	my $uri = shift;

	use ariba::monitor::SyntheticCDB::SLAUptimeCDB;
	use ariba::monitor::SyntheticCDB::UptimeCDB;
	use ariba::monitor::SyntheticCDB::UnplannedDowntimeCDB;


	$uri =~ m/^outage:\/\/(.*)$/i;
	my $cdb = $1;

	my @args = split( /\//, $cdb);

	my $product = shift @args;
	my $service = shift @args;

	my $customer = undef;
	$customer = shift @args if (ariba::rc::Globals::isASPProduct($product));

	my $outageType = shift @args;

	if (lc($outageType) eq 'uptimesla') {
		return ariba::monitor::SyntheticCDB::SLAUptimeCDB->newFromProductAndServiceAndCustomer($product, $service, $customer);
	} elsif (lc($outageType) eq 'uptime') {
		return ariba::monitor::SyntheticCDB::UptimeCDB->newFromProductAndServiceAndCustomer($product, $service, $customer);
	} elsif (lc($outageType) eq 'unplanneddowntime') {
		return ariba::monitor::SyntheticCDB::UnplannedDowntimeCDB->newFromProductAndServiceAndCustomer($product, $service, $customer);
	}

	return undef;
}

1;
