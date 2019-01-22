#!/usr/local/bin/perl

#
# $Id: //ariba/services/monitor/lib/ariba/Veritas/Disk.pm#4 $
#

package ariba::Veritas::Disk;

use strict;
use base qw(ariba::Ops::PersistantObject);

sub dir { return '/dev/null'; }
sub save { return undef; }
sub recursiveSave { return undef; }
sub remove { return undef; }

sub volumes {
	my $self = shift;
	my @ret;

	foreach my $p ($self->plexes()) {
		push(@ret, $p->volume());
	}

	return(sort(@ret));
}

sub objectLoadMap {
	my $class = shift;

	my %map = (
		'diskGroup', 'ariba::Veritas::DiskGroup',
		'plexes', '@ariba::Veritas::Plex',
		'alternatePaths', '@SCALAR'
	);

	return(\%map);
}

sub new {
	my $class = shift;
	my $instance = shift;
	my $osName = shift;
	my $mylun;
	my %lunMap;

	my $self = $class->SUPER::new($instance);

	open(LSSCSI, "/usr/bin/lsscsi |");
	#
	# parsing:
	#
	# [0:0:0:15]   disk    3PARdata VV               0000  /dev/sdp
	# [1:0:0:0]    disk    3PARdata VV               0000  /dev/sdq
	#
	# the first number in the [1:0:0:0] maps to the scsi device number
	# (eg scsi0, scsi1) as the OS is concerned, but in the FC world, the
	# multiple SCSI interfaces to the OS represent distinct channels to
	# FC array.
	#
	while(my $line = <LSSCSI>) {
		if($line =~ m|^\[(\d+):(\d+:\d+\:\d+)\].*/dev/(\w+)$|) {
			my $channel = $1; 
			my $lun = $2; # technically not just the lun, but close enuff
			my $disk = $3;
			if($disk eq $osName) {
				$self->setChannel($channel);
				$mylun = $lun;
			} else {
				$lunMap{$disk} = $lun;
			}
		}
	}
	close(LSSCSI);

	#
	# XXX -- this makes an assumption that [0:0:0:0] and [1:0:0:0] are 
	# multiple channels to the same disk -- which Rich says is true for 3par
	# 
	# This should use a command like : vxdmpadm getdmpnode nodename=sda
	#
	# However, vxdmpadm requires super user access to work, so we're gonna
	# cheat for now...
	#
	foreach my $osDisk (keys %lunMap) {
		next unless(defined($mylun) and $lunMap{$osDisk} eq $mylun);
		$self->appendToAlternatePaths($osDisk);
	}

	return($self);
}

1;
