#!/usr/local/bin/perl

#
# $Id: //ariba/services/monitor/lib/ariba/Veritas/DiskGroup.pm#2 $
#

package ariba::Veritas::DiskGroup;

use strict;
use base qw(ariba::Ops::PersistantObject);

sub dir { return '/dev/null'; }
sub save { return undef; }
sub recursiveSave { return undef; }
sub remove { return undef; }

sub diskFromOsName {
	my $self = shift;
	my $name = shift;

	foreach my $d ($self->disks()) {
		return $d if($d->osName() eq $name);
	}
	return undef;
}

sub diskFromName {
	my $self = shift;
	my $name = shift;

	foreach my $d ($self->disks()) {
		return $d if($d->instance() eq $name);
		return $d if($self->instance() . "/" . $name eq $d->instance());
	}
	return undef;
}

sub volumeFromName {
	my $self = shift;
	my $name = shift;

	foreach my $v ($self->volumes()) {
		return $v if($v->instance() eq $name);
		return $v if($self->instance() . "/" . $name eq $v->instance());
	}
	return undef;
}

sub volumeFromMountPoint {
	my $self = shift;
	my $name = shift;

	foreach my $v ($self->volumes()) {
		return $v if($v->mountPoint() eq $name);
	}
	return undef;
}

sub objectLoadMap {
	my $class = shift;

    my %map = (
		'disks', '@ariba::Veritas::Disk',
		'volumes', '@ariba::Veritas::Volume',
		'plexes', '@ariba::Veritas::Plex',
	);

	return(\%map);
}

sub new {
	my $class = shift;
	my $instance = shift;

	my $self = $class->SUPER::new($instance);

	return($self);
}

1;
