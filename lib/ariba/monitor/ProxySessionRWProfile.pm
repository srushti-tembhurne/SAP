package ariba::monitor::ProxySessionRWProfile;

use ariba::Ops::Constants;
use ariba::Ops::PersistantObject;
use base qw(ariba::Ops::PersistantObject);

sub dir {
	return ariba::Ops::Constants->inspectorProxyProfileDir() . "/rw";
}

sub objectLoadMap {
	my $class = shift;

	my $mapRef = $class->SUPER::objectLoadMap();
	$$mapRef{'authorizedReadWriteProxyList'} =  '@SCALAR';
	return $mapRef;
}


1;
