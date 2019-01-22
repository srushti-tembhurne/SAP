#!/usr/local/bin/perl

package ariba::Ops::MCL::SavedState;

use strict;
use base qw(ariba::Ops::PersistantObject);

sub validAccessorMethods {
	my $class = shift;

	my $ref = $class->SUPER::validAccessorMethods();
	my @accessors = qw( mcl name );

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

    my ($mclname, $var) = split(/\-\-/, $instance);
    my $store = "/var/mcl/$mclname/savedstate/$var";
    return($store);
}

sub new {
	my $class = shift;
	my $name = shift;

	my $mcl = ariba::Ops::MCL->currentMclObject();
	my $mclname = $mcl->instance();

	my $instance = $mclname . "--" . $name;

	#
	# we always want to load fresh status from disk here
	#
	my $self = $class->SUPER::new($instance);
	$class->_removeObjectFromCache($self);
	$self = $class->SUPER::new($instance);

	$self->setMcl($mcl);
	$self->setName($name);

	return($self);
}

#
# use setAttribute() and attribute() with this class, since by design it can't
# list valid accessors
#

1;
