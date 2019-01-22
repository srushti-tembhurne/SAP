package ariba::monitor::AppRecycleOutage;

# $Id: //ariba/services/monitor/lib/ariba/monitor/AppRecycleOutage.pm#2 $

use strict;
use ariba::monitor::misc;

use base qw(ariba::Ops::InstanceTTLPersistantObject);

sub dir {
	my $class = shift;
	return ariba::monitor::misc::outageStorageDir();
}

sub instanceName {
	my $class = shift;
	my $product = shift;
	my $appinstance = shift;

	return "outage-" . $product . "-" . $appinstance;
}

sub newWithDetails {
	my $class = shift;
	my $product = shift;
	my $appinstance = shift;
	my $ttl = shift;

	my $time = time();

	my $instanceName = $class->instanceName($product, $appinstance);

	my $self = $class->SUPER::new($instanceName);

	$self->setCreationTime($time);
	$self->setTtl($ttl);
	$self->setProduct($product);
	$self->setAppinstance($appinstance);

	return $self;
}

1;
