#!/usr/local/bin/perl

package ariba::Ops::MCL::VIPMapping;

use strict;
use base qw(ariba::Ops::PersistantObject);

sub validAccessorMethods {
	my $class = shift;

	my $ref = $class->SUPER::validAccessorMethods();
	my @accessors = qw( vipName realHost );

	foreach my $accessor (@accessors) {
		$ref->{$accessor} = 1;
	}

	return($ref);
}

sub dir {
    return('/var/mcl');
}

sub _computeBackingStoreForInstanceName {
    my $class = shift;
    my $instance = shift;

	my ( $mclname, $vipname ) = split(/\-\-/, $instance);

    my $store = "/var/mcl/$mclname/vip-map/$vipname";
    return($store);
}

sub new {
	my $class = shift;
	my $mcl = shift;
	my $vipname = shift;
	my $realhost = shift;

	my $instance = $mcl . "--" . $vipname;

	my $self = $class->SUPER::new($instance);

	$self->setVipName($vipname);
	$self->setRealHost($realhost) if($realhost);

	return($self);
}

1;
