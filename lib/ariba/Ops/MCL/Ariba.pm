#!/usr/local/bin/perl

package ariba::Ops::MCL::Ariba;

use ariba::Ops::Logger;
my $logger = ariba::Ops::Logger->logger();

use ariba::rc::InstalledProduct;
use ariba::Ops::OracleClient;
use ariba::Ops::DBConnection;
use ariba::Ops::DatabasePeers;
use ariba::rc::Globals;
use ariba::Ops::Machine;

sub machinesForProperties {
	my %match;

	while (my $arg = shift) {
		my ($k, $v) = split(/\=/, $arg, 2);
		$match{$k} = $v;
	}

	my @machines = ariba::Ops::Machine->machinesWithProperties(%match);

	#
	# in the context of JMCL, we never want these since we can't login to
	# them anyway
	#
	@machines = grep { !$_->provides('safeguard','bastion') } @machines;
	
	my %hostlist;
	map { $hostlist{$_->hostname()} = 1 } @machines;
	return(join(' ', sort(keys(%hostlist))));
}

sub servicesForDatacenter {
	my $datacenter = shift;

	return(join(' ', ariba::rc::Globals::servicesForDatacenter($datacenter)));
}

sub allProducts {
	return(join(' ', ariba::rc::Globals::allProducts()));
}

sub databaseServersForProduct {
	my $product = shift;
	my $service = shift;
	my $buildname = shift;
	my $customer = shift;

	unless($service) {
		my $mcl = ariba::Ops::MCL->currentMclObject();
		$service = $mcl->service();
	}

	my $p = ariba::rc::InstalledProduct->new($product, $service, $buildname, $customer);

	my @dbc = ariba::Ops::DBConnection->connectionsFromProducts($p);
	@dbc = grep { $_->dbServerType ne 'hana' } @dbc;
	@dbc = grep { $_->sid !~ /rman/ } @dbc;
	my %hosts;
	map { $hosts{$_->host()} = 1 } @dbc;

	return(join(" ", sort(keys(%hosts))));
}

sub sidsForProduct {
	my $product = shift;
	my $service = shift;
	my $buildname = shift;
	my $customer = shift;

	$buildname = undef if($buildname && $buildname eq 'undef');

	my $p = ariba::rc::InstalledProduct->new($product, $service, $buildname, $customer);

	my @dbc = ariba::Ops::DBConnection->connectionsFromProducts($p);
	@dbc = grep { $_->dbServerType ne 'hana' } @dbc;
	my %sids;
	map { $sids{$_->sid() . '@' . $_->host() } = 1 } @dbc;

	return(join(" ", sort(keys(%sids))));
}

sub hostsForProduct {
	my ($product, $service, $role, $buildname, $cluster);
	my $mcl = ariba::Ops::MCL->currentMclObject();

	$service = $mcl->service() if($mcl);
	$cluster = "primary";

	foreach my $arg (@_) {
		my ($opt, $val) = split(/=/, $arg);
		if($opt eq 'product') { $product = $val; } 
		if($opt eq 'service') { $service = $val; } 
		if($opt eq 'role') { $role = $val; } 
		if($opt eq 'build') { $buildname = $val; } 
		if($opt eq 'cluster') { $cluster = $val; } 
	}

	my $p = ariba::rc::InstalledProduct->new($product, $service, $buildname);

	my @hosts;
	if($role) {
		if($role =~ s/^\!//) {
			my %exclude;
			map { $exclude{$_} = 1 } $p->hostsForRoleInCluster($role, $cluster);
			@hosts = grep { !$exclude{$_} } $p->allHostsInCluster($cluster);
		} else {
			@hosts = $p->hostsForRoleInCluster($role, $cluster);
		}
	} else {
		@hosts = $p->allHostsInCluster($cluster);
	}

	return(join(" ", sort(@hosts)));
}

sub webserverRoleForProduct {
	my $product = shift;
	my $mcl = ariba::Ops::MCL->currentMclObject();
	my $service = $mcl->service();

	my $p = ariba::rc::InstalledProduct->new($product, $service);

	foreach my $role ($p->allRolesInCluster('primary')) {
		return($role) if($role =~ /webserver$/);
	}

	return("unknown");
}

sub maxParallelForListAndPercent {
	my $var = shift;
	my $pct = shift;

	my @items = split(/ /,$var);
	my $value = scalar(@items);
	$value = ($value * $pct) / 100 ;
	$value =~ s/\.\d+$//;

	$value = 1 if($value < 1);

	return($value);
}

sub primarySidsForProduct {
	my $product = shift;
	my $service = shift;
	my $buildname = shift;
	my $customer = shift;

	$buildname = undef if($buildname && $buildname eq 'undef');

	my $p = ariba::rc::InstalledProduct->new($product, $service, $buildname, $customer);

	my @dbc = ariba::Ops::DBConnection->connectionsFromProducts($p);
	@dbc = grep { $_->dbServerType ne 'hana' } @dbc;
	@dbc = grep { $_->isDR() == 0 } @dbc;
	my %sids;
	map { $sids{$_->sid() . '@' . $_->host() } = 1 } @dbc;

	return(join(" ", sort(keys(%sids))));
}

sub drSidsForProduct {
	my $product = shift;
	my $service = shift;
	my $buildname = shift;
	my $customer = shift;

	$buildname = undef if($buildname && $buildname eq 'undef');

	my $p = ariba::rc::InstalledProduct->new($product, $service, $buildname, $customer);

	my @dbc = ariba::Ops::DBConnection->connectionsFromProducts($p);
	@dbc = grep { $_->dbServerType ne 'hana' } @dbc;
	@dbc = grep { $_->isDR() } @dbc;
	my %sids;
	map { $sids{$_->sid() . '@' . $_->host() } = 1 } @dbc;

	return(join(" ", sort(keys(%sids))));
}

sub sidsForService {
	my $service = shift;

	my @products;
	foreach my $pname (ariba::rc::Globals::allProducts()) {
		if(ariba::rc::InstalledProduct->isInstalled($pname, $service)) {
			push(@products, ariba::rc::InstalledProduct->new($pname, $service));
		}
	}

	my @dbc = ariba::Ops::DBConnection->connectionsFromProducts(@products);
	@dbc = grep { $_->dbServerType ne 'hana' } @dbc;
	my %sids;
	map { $sids{$_->sid() . '@' . $_->host() } = 1 } @dbc;
	return(join(" ", sort(keys(%sids))));
}

sub schemasForProduct {
	my $product = shift;
	my $service = shift;
	my $buildname = shift;
	my $customer = shift;

	$buildname = undef if($buildname && $buildname eq 'undef');

	my $p = ariba::rc::InstalledProduct->new($product, $service, $buildname, $customer);

	my @dbc = ariba::Ops::DBConnection->connectionsFromProducts($p);
	@dbc = grep { $_->dbServerType ne 'hana' } @dbc;
	my %sids;
	map { $schemas{$_->user . "@" . $_->sid() . '@' . $_->host() } = 1 } @dbc;

	return(join(" ", sort(keys(%schemas))));
}

sub primarySchemasForProduct {
	my $product = shift;
	my $service = shift;
	my $buildname = shift;
	my $customer = shift;

	$buildname = undef if($buildname && $buildname eq 'undef');

	my $p = ariba::rc::InstalledProduct->new($product, $service, $buildname, $customer);

	my @dbc = ariba::Ops::DBConnection->connectionsFromProducts($p);
	@dbc = grep { $_->dbServerType ne 'hana' } @dbc;
	@dbc = grep { $_->isDR() == 0 } @dbc;
	my %sids;
	map { $schemas{$_->user . "@" . $_->sid() . '@' . $_->host() } = 1 } @dbc;

	return(join(" ", sort(keys(%schemas))));
}

sub drSchemasForProduct {
	my $product = shift;
	my $service = shift;
	my $buildname = shift;
	my $customer = shift;

	$buildname = undef if($buildname && $buildname eq 'undef');

	my $p = ariba::rc::InstalledProduct->new($product, $service, $buildname, $customer);

	my @dbc = ariba::Ops::DBConnection->connectionsFromProducts($p);
	@dbc = grep { $_->dbServerType ne 'hana' } @dbc;
	@dbc = grep { $_->isDR() } @dbc;
	my %sids;
	map { $schemas{$_->user . "@" . $_->sid() . '@' . $_->host() } = 1 } @dbc;

	return(join(" ", sort(keys(%schemas))));
}

sub productsForService {
	my $service = shift;

	my @p = ariba::rc::InstalledProduct->installedProductsList($service);
	@p = grep { !$_->isASPProduct() } @p;
	
	my %products;
	map { $products{$_->name()}=1 } @p;
	return(join(" ", sort(keys(%products))));
}

1;
