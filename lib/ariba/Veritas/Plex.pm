#!/usr/local/bin/perl

#
# $Id: //ariba/services/monitor/lib/ariba/Veritas/Plex.pm#2 $
#

package ariba::Veritas::Plex;

use strict;
use base qw(ariba::Ops::PersistantObject);

sub dir { return '/dev/null'; }
sub save { return undef; }
sub recursiveSave { return undef; }
sub remove { return undef; }

sub diskGroup {
	my $self = shift;
	my $vol = $self->volume() || return undef;
	return($vol->diskGroup());
}

sub objectLoadMap {
	my $class = shift;

	my %map = (
		'disks', '@ariba::Veritas::Disk',
		'volume', 'ariba::Veritas::Volume',
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
