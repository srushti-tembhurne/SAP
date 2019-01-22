#!/usr/local/bin/perl

package ariba::Ops::MCL::RunGroup;

use strict;
use base qw(ariba::Ops::PersistantObject);

sub validAccessorMethods {
	my $class = shift;

	my $ref = $class->SUPER::validAccessorMethods();
	my @accessors = qw( mcl maxParallelProcesses name locked );

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

    my ($mclname, $group) = split(/\-\-/, $instance);
    my $store = "/var/mcl/$mclname/rungroups/$group";
    return($store);
}

sub newFromParser {
	my $class = shift;
	my $mcl = shift;
	my $group = shift;

	my $instance = $mcl . "--" . $group;

	my $self = $class->SUPER::new($instance);

	$self->setMcl($mcl);
	$self->setName($group);

	return($self);
}

sub parse {
	my $self = shift;
	my $mcl = shift;
	my $stream = shift;

	while(my $line = shift(@$stream)) {
		chomp($line);
		$line = $mcl->expandVariables($line);
		last if($line =~ /^\s*\}\s*$/);

		next if($line =~ /^\s*$/);
		next if($line =~ /^\s*\#/);

		if($line =~ /^\s*MaxParallelProcesses:\s*(\d+)$/) {
			my $max = $1;
			$self->setMaxParallelProcesses($max);
		} elsif($line =~ /^\s*Locked\s*$/) {
			$self->setLocked(1);
		} else {
			my $name = $self->name();
			die("Unrecognized syntax in RunGroup $name: $line");
		}
	}
}

1;
