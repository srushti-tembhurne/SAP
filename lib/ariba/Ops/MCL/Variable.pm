#!/usr/local/bin/perl

package ariba::Ops::MCL::Variable;

use strict;
use base qw(ariba::Ops::PersistantObject);

sub validAccessorMethods {
	my $class = shift;

	my $ref = $class->SUPER::validAccessorMethods();
	my @accessors = qw( mcl name value type usageHint );

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
    my $store = "/var/mcl/$mclname/variables/$var";
    return($store);
}

sub isStatic {
	my $self = shift;
	return(1) if($self->type() eq 'static');
	return(0);
}

sub isDynamic {
	my $self = shift;
	return(1) if($self->type() eq 'dynamic');
	return(0);
}

sub newFromParser {
	my $class = shift;
	my $mcl = shift;
	my $variable = shift;

	my $instance = $mcl . "--" . $variable;

	my $self = $class->SUPER::new($instance);

	$self->setMcl($mcl);
	$self->setName($variable);
	$self->setType('static') unless($self->type());

	return($self);
}

sub setValue {
	my $self = shift;
	my $val = shift;

	if($val && $val =~ s/^loop:\s+//) {
		$val =~ s/\s+/\n/g;
	}

	$self->SUPER::setValue($val);
}

1;
