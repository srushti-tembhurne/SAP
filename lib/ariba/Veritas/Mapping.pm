#!/usr/local/bin/perl

#
# $Id: //ariba/services/monitor/lib/ariba/Veritas/Mapping.pm#13 $
#

package ariba::Veritas::Mapping;

use strict;
use base qw(ariba::Ops::PersistantObject);
use ariba::Veritas::DiskGroup;
use ariba::Veritas::Volume;
use ariba::Veritas::Plex;
use ariba::Veritas::Disk;

use ariba::rc::Utils;
use Carp;

my $iterator = 1;

my $VXPRINT = '/usr/sbin/vxprint';

$main::quiet = 1;

sub new {
	my $class = shift;
	my $instance = $iterator++;

	my $self = $class->SUPER::new($instance);

	my $cmd = "$VXPRINT -A";

	#
	# This parses output that looks like:
	#
	# Disk group: ora03dg
	# 
	# TY NAME         ASSOC        KSTATE   LENGTH   PLOFFS   STATE    TUTIL0  PUTIL0
	# dg ora03dg      ora03dg      -        -        -        -        -       -
	# 
	# dm sdl          sdg          -        25682048 -        -        -       -
	# dm sdm          sdh          -        25682048 -        -        -       -
	# dm sdn          sdi          -        25682048 -        -        -       -
	# dm sdo          sdj          -        25682048 -        -        -       -
	# dm sdp          sdk          -        25682048 -        -        -       -
	# dm sdq          sdl          -        25682048 -        -        -       -
	# 
	# v  ora03data01  gen          ENABLED  102728192 -       ACTIVE   -       -
	# pl ora03data01-01 ora03data01 ENABLED 102728192 -       ACTIVE   -       -
	# sd sdl-01       ora03data01-01 ENABLED 25682048 0       -        -       -
	# sd sdm-01       ora03data01-01 ENABLED 25682048 25682048 -       -       -
	# sd sdn-01       ora03data01-01 ENABLED 25682048 51364096 -       -       -
	# sd sdo-01       ora03data01-01 ENABLED 25682048 77046144 -       -       -
	# 
	# v  ora03log01   gen          ENABLED  25682048 -        ACTIVE   -       -
	# pl ora03log01-01 ora03log01  ENABLED  25682048 -        ACTIVE   -       -
	# sd sdp-01       ora03log01-01 ENABLED 25682048 0        -        -       -
	# 
	# v  ora03log02   gen          ENABLED  25682048 -        ACTIVE   -       -
	# pl ora03log02-01 ora03log02  ENABLED  25682048 -        ACTIVE   -       -
	# sd sdq-01       ora03log02-01 ENABLED 25682048 0        -        -       -
	# [snip]
	#
	open(FH,"$cmd |");

	my $currentDG = undef;
	while(my $line = <FH>) {
		chomp $line;
		my ($type,$name,$assoc) = split(/\s+/,$line);

		next unless ($type);

		if($type eq 'dg') {
			my $dg = ariba::Veritas::DiskGroup->new($name);
			$self->appendToDiskGroups($dg);
			$currentDG = $dg;
		} elsif ($type eq 'dm') {
			$name = $currentDG->instance() . "/" . $name;
			my $osDiskName = $self->osNameFromAssoc($assoc);
			unless ($osDiskName) {
				Carp::croak "can't get os name for '$assoc'\n";
			}
			my $disk = ariba::Veritas::Disk->new($name, $osDiskName);

			$disk->setOsName($osDiskName);
			$disk->setDiskGroup($currentDG);
			$currentDG->appendToDisks($disk);

			#
			# we also have to look for alternate fibre channel (DMP) paths
			#
			foreach my $a ($disk->alternatePaths()) {
				my $n = $name . "-$a";
				my $ap = ariba::Veritas::Disk->new($n, $a);
				$ap->setOsName($a);
				$ap->setDiskGroup($currentDG);
				$currentDG->appendToDisks($ap);
			}
		} elsif ($type eq 'v') {
			$name = $currentDG->instance() . "/" . $name;
			my $volume = ariba::Veritas::Volume->new($name);
			$volume->setDiskGroup($currentDG);
			$currentDG->appendToVolumes($volume);
		} elsif ($type eq 'pl') {
			$name = $currentDG->instance() . "/" . $name;
			$assoc = $currentDG->instance() . "/" . $assoc;
			my $plex = ariba::Veritas::Plex->new($name);
			my $vol = $self->volumeFromName($assoc);
			$plex->setVolume($vol);
			$vol->appendToPlexes($plex);
			$currentDG->appendToPlexes($plex);
		} elsif ($type eq 'sd') {
			#
			# XXX -- for now we're throwing away "slice" since we aren't
			# going to use it.
			#
			# we can get away with it because:
			#
			# 1) the sysadmins never put a single disk into more than one
			#    volume, which means we never see a single disk sliced into
			#    multiple slices
			# 2) If the sysadmins ever break this rule, we can no longer map
			#    OS disks from iostat back to vx volumes anyway.
			#
			# In order to actually do this correctly we also have to ask
			# veritas to tell us which disk this slice belongs to.
			#
			my $diskAssoc = diskNameFromSliceName($name, $currentDG->instance());
			$name = $self->osNameFromAssoc($diskAssoc);

			$assoc = $currentDG->instance() . "/" . $assoc;

			my $disk = $self->diskFromOsName($name); 
			my $plex = $self->plexFromName($assoc);
			$plex->appendToDisks($disk);
			$disk->appendToPlexes($plex);

			#
			# we also need to look for alternate FC (DMP) paths
			#
			foreach my $a ($disk->alternatePaths()) {
				my $d = $self->diskFromOsName($a);
				$plex->appendToDisks($d);
				$d->appendToPlexes($plex);
			}
		}
	}

	close(FH);

	return($self);
}

sub osNameFromAssoc {
	my $self = shift;
	my $assoc = shift;

	my $cmd = "/usr/sbin/vxdisk list $assoc";

	my @output;
	unless ( ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1, undef, undef) ) {
		print "Running $cmd failed:\n", join("\t\n", @output), "\n";
		return;
	}
	
	my $osDisk;
	for my $line (@output) {
		chomp $line;
		next unless $line =~ /(\S+)\s+state=/;
		$osDisk = $1;
		last;
	}

	unless ($osDisk) {
		print "Can't get os disk from assoc '$assoc'.  Output from '$cmd':\n";
		print join("", @output);
		return;
	}

	return $osDisk;
}

sub diskNameFromSliceName {
	my $slice = shift;
	my $diskgroup = shift;

	#
	# Date: Thu, 17 May 2007 15:41:45 -0700
	# From: Richard Steenburg <rsteenburg@ariba.com>
	# To: joshua mcminn <jmcminn@ariba.com>
	# Subject: veritas command
	# 
	# vxprint -g ora23dg sdq-01 -F %da_name
	# 
	# NOTE -- This returns the OS name for a disk, not the VX name
	#
	unless ( open(SL, "$VXPRINT -g $diskgroup $slice -F %da_name |") ) {
		$slice =~ s/-\d+$//;
		return $slice; # take a guess
	}
	my $disk = <SL>;
	chomp $disk;
	close(SL);

	return($disk);
}

sub diskGroupFromName {
	my $self = shift;
	my $dgname = shift;

	foreach my $dg ($self->diskGroups()) {
		return($dg) if($dg->instance() eq $dgname);
	}

	return undef;
}

sub volumeFromName {
	my $self = shift;
	my $volname = shift;

	foreach my $dg ($self->diskGroups()) {
		my $vol = $dg->volumeFromName($volname);
		return($vol) if ($vol);
	}

	return undef;
}

sub channels {
	my $self = shift;
	my %ret;

	foreach my $d ($self->disks()) {
		$ret{$d->channel} = 1;
	}

	return(sort(keys(%ret)));
}

sub volumeFromMountPoint {
	my $self = shift;
	my $mount = shift;

	foreach my $dg ($self->diskGroups()) {
		my $vol = $dg->volumeFromMountPoint($mount);
		return($vol) if ($vol);
	}

	return undef;
}

sub volumes {
	my $self = shift;
	my @ret;

	foreach my $dg ($self->diskGroups()) {
		push(@ret, $dg->volumes());
	}

	return(sort(@ret));
}

sub plexFromName {
	my $self = shift;
	my $name = shift;

	foreach my $v ($self->volumes()) {
		my $plex = $v->plexFromName($name);
		return $plex if($plex);
	}

	return undef;
}

sub plexes {
	my $self = shift;
	my @ret;

	foreach my $v ($self->volumes()) {
		push(@ret, $v->plexes());
	}

	return(sort(@ret));
}

sub diskFromOsName {
	my $self = shift;
	my $name = shift;

	foreach my $i ($self->diskGroups()) {
		my $disk = $i->diskFromOsName($name);
		return $disk if ($disk);
	}

	return undef;
}

sub diskFromName {
	my $self = shift;
	my $name = shift;

	foreach my $i ($self->diskGroups()) {
		my $disk = $i->diskFromName($name);
		return $disk if ($disk);
	}

	return undef;
}

sub volumesFromOsName {
	my $self = shift;
	my $name = shift;

	my $disk = $self->diskFromOsName($name);
	return($disk->volumes());
}

sub disks {
	my $self = shift;
	my @ret;

	foreach my $dg ($self->diskGroups()) {
		push(@ret, $dg->disks());
	}

	return(sort(@ret));
}

sub dir { return '/dev/null'; }
sub save { return undef; }
sub recursiveSave { return undef; }
sub remove { return undef; }

sub objectLoadMap {
	my $class = shift;

	my %map = (
		'diskGroups', '@ariba::Veritas::DiskGroup',
		'disks', '@ariba::Veritas::Disk',
		'volumes', '@ariba::Veritas::Volume',
		'plexes', '@ariba::Veritas::Plex',
	);

	return(\%map);
}

#
# We use this to clear the PersistantObject Cache when we know we are going to
# remap.
#
sub clearCache {
	my $class = shift;

	$class->_removeAllObjectsFromCache();
	ariba::Veritas::DiskGroup->_removeAllObjectsFromCache();
	ariba::Veritas::Disk->_removeAllObjectsFromCache();
	ariba::Veritas::Plex->_removeAllObjectsFromCache();
	ariba::Veritas::Volume->_removeAllObjectsFromCache();
}

1;
