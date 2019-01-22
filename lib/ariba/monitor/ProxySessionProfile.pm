package ariba::monitor::ProxySessionProfile;

use ariba::Ops::PersistantObject;
use ariba::Ops::Constants;
use ariba::monitor::ProxySessionRWProfile;

use base qw(ariba::Ops::PersistantObject);

sub dir {
	return ariba::Ops::Constants->inspectorProxyProfileDir();
}


sub save {
	return undef;
}

sub recursiveSave {
	return undef;
}

sub objectLoadMap {
	my $class = shift;

	my $mapRef = $class->SUPER::objectLoadMap();
	$$mapRef{'authorizedProxyList'}          =  '@SCALAR';
	return $mapRef;
}

sub authorizedReadWriteProxyList {
	my $self = shift;

	my $class = ref($self);
	my $rwProfile = ariba::monitor::ProxySessionRWProfile->new( $self->instance() );

	return undef unless defined $rwProfile;
	return $rwProfile->authorizedReadWriteProxyList();
}

sub checkProxyPermission {
	my $self = shift;
	my $product = shift;
	my $customer = shift;
	my $inspectorType = shift;

	my $key = $product;
	$key .= "/$customer" if $customer;

	my @authorizedList;
	if ($inspectorType && $inspectorType eq "rw") {
		@authorizedList = $self->authorizedReadWriteProxyList();
	} else {
		@authorizedList = $self->authorizedProxyList();
	}

	my $proxyPermission = 0;
	for my $e (@authorizedList) {

		my ($authProduct, $authCustomer) = split("/", $e);

		my $prodPerm = (!$authProduct  || $product  eq $authProduct);
		my $custPerm = (!$authCustomer || $customer eq $authCustomer);

		$proxyPermission = $prodPerm && $custPerm;

		last if $proxyPermission;
	}
	return $proxyPermission;
}

1;
