#!/usr/local/bin/perl

#
# $Id: //ariba/services/monitor/lib/ariba/Veritas/Volume.pm#2 $
#

package ariba::Veritas::Volume;

use strict;
use base qw(ariba::Ops::PersistantObject);

sub dir { return '/dev/null'; }
sub save { return undef; }
sub recursiveSave { return undef; }
sub remove { return undef; }

sub plexFromName {
	my $self = shift;
	my $name = shift;

	foreach my $p ($self->plexes()) {
		return $p if($p->instance() eq $name);
	}
	return undef;
}

sub disks {
	my $self = shift;
	my @ret;

	foreach my $p ($self->plexes()) {
		push(@ret,$p->disks());
	}

	return(sort(@ret));
}

sub objectLoadMap {
	my $class = shift;

	my %map = (
		'diskGroup', 'ariba::Veritas::DiskGroup',
		'plexes', '@ariba::Veritas::Plex',
	);

	return(\%map);
}

sub new {
	my $class = shift;
	my $instance = shift;

	my $self = $class->SUPER::new($instance);

	#
	# map the veritas volume to an OS System mount point
	#
	open(DF, "/bin/df -P |");
	# /dev/vx/dsk/ora05dg/ora05a 471827968 245737760 224323960      53% /ora05a
	while(my $line = <DF>) {
		if($line =~ m|/vx/dsk/([^/]+/\w+)|) {
			my $vol = $1;
			next unless($vol eq $instance);
			my $mount = (split(/\s+/,$line))[5];
			$self->setMountPoint($mount);
		}
	}
	close(DF);

	return($self);
}

1;
