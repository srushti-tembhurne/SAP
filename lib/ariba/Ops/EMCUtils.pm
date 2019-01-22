package ariba::Ops::EMCUtils;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/EMCUtils.pm#11 $

use strict;
use File::Path;

my $debug = 0;

my $binDir = "/usr/symcli/bin";

my $symdg  = "$binDir/symdg";
my $symmir = "$binDir/symmir";
my $symld  = "$binDir/symld";
my $syminq = "$binDir/syminq";

my $vgchgid  = "/usr/sbin/vgchgid";
my $vgimport = "/usr/sbin/vgimport";
my $vgchange = "/usr/sbin/vgchange";
my $vgcfgbak = "/usr/sbin/vgcfgbackup";
my $vgdisplay = "/usr/sbin/vgdisplay";

my $vxdisk = "/usr/sbin/vxdisk";
my $vxprint = "/usr/sbin/vxprint";

my $MAJOR = 64;

my $hexRe  = qr/[a-fA-F0-9]{4}/;

sub setDebug {
	$debug = shift;
}

sub currentBcvGroupForVolume {
	my $realVolume = shift;

	my $curBCV;
	my $cmd = "$symdg list";

	print "ariba::Ops::EMCUtils::currentBcvGroupForVolume($realVolume) cmd = $cmd\n" if ($debug);

	open(SYMDG, "$cmd |") || return $curBCV;

	while (my $line = <SYMDG>) {
		chomp($line);
		if ($line =~ /$realVolume/) {
			$line =~ s|^\s*||;
			my ($tempBCV, $numDevices) = (split(/\s+/, $line))[0,4];
			if ($numDevices > 0) {
				$curBCV = $tempBCV;
			}
		}
	}

	close(SYMDG);

	return($curBCV);
}

sub moveBcvGroup {
	my $curGroup = shift;
	my $newGroup = shift;

	my $cmd = "$symld -g $curGroup moveall $newGroup";
	print "ariba::Ops::EMCUtils::moveBcvGroup($curGroup, $newGroup) cmd = $cmd\n" if ($debug);

	my $ret = 1;
	if ($debug <= 2) {
		$ret = (system("$cmd >/dev/null 2>&1") == 0);
	}
	return $ret;
}

sub checkIfSymmirDone {
	my $group = shift;
	my $option = shift;

	my $cmd;
	if ( $option ) {
		$cmd = "$symmir -g $group verify -$option";
	} else {
		$cmd = "$symmir -g $group verify";
	}

	print "ariba::Ops::EMCUtils::checkIfSymmirDone($group) cmd = $cmd\n" if ($debug);

	open(SYMMIR, "$cmd |") || return 1;
	my @result = <SYMMIR>;
	close(SYMMIR);

	if ( @result && $result[1] =~ /^All/i ) {
		return 1;
	} 

	return 0;
}

sub waitUntilSymmirDone {
	my $group = shift;
	my $option = shift;

	print "ariba::Ops::EMCUtils::waitUntilSymmirDone($group)\n" if ($debug);

	my $finished;

	do {
		$finished = ariba::Ops::EMCUtils::checkIfSymmirDone($group, $option);
		sleep(30);
	} until ( $finished );

	return 1;
}

sub executeSymmir {
	my $group = shift;
	my $action = shift;

	my $cmd = "$symmir -noprompt -g $group $action";

	print "ariba::Ops::EMCUtils::executeSymmir($group) cmd = $cmd\n" if ($debug);
	my $ret = 1;
	if ($debug <= 2) {
		$ret = (system("$cmd >/dev/null 2>&1") == 0);
	}
	return $ret;
}

sub dataToSync {
	my $group = shift;
	my $cmd = "$symmir -noprompt -g $group query";

	print "ariba::Ops::EMCUtils::dataToSync($group) cmd = $cmd\n" if ($debug);

	my $dataToSync = -1 ;

	open(SYMMIR, "$cmd |") || return $dataToSync;
	while(my $line = <SYMMIR>) {
		#   MB(s)               0.0                                  0.0
		if ($line =~ s|^\s*MB\(s\)\s*||) {
			my ($stdMB, $bcvMB) = split(/\s+/, $line);
			$dataToSync = $bcvMB;
		}
	}
	close(SYMMIR);

	return $dataToSync;
}

sub symmBCVDeviceListForDeviceGroup {
        my $deviceGroup = shift;

	return symmDeviceListForDeviceGroup($deviceGroup, 'BCV'); 
}

sub symmSTDDeviceListForDeviceGroup {
        my $deviceGroup = shift;

	return symmDeviceListForDeviceGroup($deviceGroup, 'DEV'); 
}

sub symmDeviceListForDeviceGroup {
        my $deviceGroup = shift;
	my $deviceType  = shift;

        my @deviceOrder = ();
	my %list = ();

	#
	# HPUX Output
	#
        #BCV001                /dev/rdsk/c14t8d2       074       RW     11619
        #BCV002                /dev/rdsk/c14t8d3       075       RW     11619

	#
	# Redhat output
	#
        #BCV001                /dev/sdh                0001      RW      9959
        #BCV002                /dev/sdi                0002      RW      9959

	#
	# If the BCV device is not mapped on the host
	#
	#BCV001                N/A                     0099 (M)  RW     58097
	#BCV002                N/A                     01C3 (M)  RW     58097

	print "Getting $deviceType listing for deviceGroup: $deviceGroup...\n" if $debug;

        open(SYMDG, "$symdg show $deviceGroup |") or die "Can't get $deviceType listing for $deviceGroup!: $!";
        while (<SYMDG>) {
                chomp;

		s/^\s*//g;
		s/\s*$//g;

		next unless /^$deviceType\d{3}/;

		my ($primaryPath, $symmDevice) = (split(/\s+/))[1,2];

		next unless $primaryPath =~ m#^(/dev/|N/A)#;
		next unless $symmDevice  =~ /^$hexRe$/;

		# we'll search for the secondary path shortly. assuming we have one.
		push @{$list{$symmDevice}}, $primaryPath;
		push @deviceOrder, $symmDevice;
        }
        close(SYMDG);

	if (scalar @deviceOrder == 0) {
		die "No devices were found! Aborting!";
	}

	return (\%list,\@deviceOrder);
}

sub findSecondaryPathsForSymmDevices {
	my $symmList = shift;

	# /dev/rdsk/c16t8d2  BCV  EMC       SYMMETRIX        5567 64074000  11898240

	print "Searching for SCSI devices with syminq.. this will take a minute.\n" if $debug;

        open(SYMINQ, "$syminq |") or die "Can't get $syminq listing: $!";
	while (<SYMINQ>) {
                chomp;

		s/^\s*//g;
		s/\s*$//g;

		my ($devicePath, $symmDeviceSerial) = (split(/\s+/))[0,5];

		my ($symmDevice) = ($symmDeviceSerial =~ /^\d\d($hexRe)\d{3}$/);

		# skip unless we have this device in our list. Only looking 
		# to verify the primary fiber path, and add the secondary.
		next unless defined $symmList->{$symmDevice};

		unless ($symmList->{$symmDevice}->[0] eq $devicePath) {
			push @{$symmList->{$symmDevice}}, $devicePath;
		}
	}
	close(SYMINQ);
}

sub allPathsForSymmDeviceList {
	my $symmList = shift;
	my $deviceOrder = shift;

	return map { @{$symmList->{$_}} } @$deviceOrder;
}

sub primaryPathsForSymmDeviceList {
	my $symmList = shift;
	my $deviceOrder = shift;

	return map { $symmList->{$_}->[0] } @$deviceOrder;
}

sub secondaryPathsForSymmDeviceList {
	my $symmList = shift;
	my $deviceOrder = shift;

	return map { $symmList->{$_}->[1] } @$deviceOrder;
}


#
# HPUX specific commands
#
sub characterToBlockDevices {
	return map { s/rdsk/dsk/; $_ } @_;
}

sub writePathListToFile {
	my $filename = shift;
	my @paths = @_;

	print "Writing out device paths to: [$filename]\n" if $debug;
	open(PATHS, ">$filename") or die "Can't open [$filename] for writing: $!";
	print PATHS join("\n", @paths) . "\n";
	close(PATHS);

	return 1;
}

sub freeMinorNumberForVolumeGroup {

	# from vgcreate(1)
	# The minor number for the group file should be unique among all
	# the volume groups on the system.  It has the format 0xNN0000,
	# where NN runs from 00 to 09.  The maximum value of NN is
	# controlled by the kernel tunable parameter maxvgs.

	# crw-r--r--   1 root       sys         64 0x030000 Apr  1 10:53 group
	my %taken = ();
	my $start = 10;
	my $minor = 0;

	# pull in major(), minor(), etc
	require 'sys/sysmacros.ph';

	opendir(DEV, '/dev') or die "Can't open /dev: $!";
	while(my $dir = readdir(DEV)) {

		my $group = "/dev/$dir/group";

		next unless -c "/dev/$dir/group";

		my $rdev = (stat($group))[6];

		my $major = major($rdev);
		my $minor = sprintf(MINOR_FORMAT(), minor($rdev));

		next unless $major == $MAJOR;

		$taken{$minor} = 1;

		print "Existing: $major, $minor - $group\n" if $debug > 1;
	}
	close(DEV);

	while ($start < $MAJOR) {
		next if exists $taken{$start++};
		
		$minor = sprintf("0x%d0000", $start);
		last;
	}

	return $minor;
}

sub createVolumeGroupForDeviceGroup {
	my $deviceGroup = shift;
	my $symmList = shift;
	my $deviceOrder = shift;
	my $fsck = shift || 0;

	my $deviceFile = "/dev/$deviceGroup";

	if (-d $deviceFile) {

		if (-e "$deviceFile/lvol1") {
			print "A $deviceFile/lvol1 already exists! Please check and remove it first!\n";
			exit;
		}

		print "Removing old $deviceFile ...\n";
		rmtree($deviceFile);
	}

	my @primaryPaths = primaryPathsForSymmDeviceList($symmList, $deviceOrder);

	system("$vgchgid @primaryPaths") == 0 or 
		die "Failed to run $vgchgid on the primary paths!: $!";

	mkpath($deviceFile) unless -d $deviceFile;

	my $minor = freeMinorNumberForVolumeGroup();

	my $cmd   = "/sbin/mknod $deviceFile/group c $MAJOR $minor";

	print "Running $cmd\n" if $debug;

	system($cmd) == 0 or die "Can't create group special file: [$cmd]: $!";

	my @allPaths = characterToBlockDevices(
		allPathsForSymmDeviceList($symmList, $deviceOrder)
	);

	print "Running $vgimport on $deviceFile with all device paths..\n" if $debug;
	system("$vgimport $deviceFile @allPaths") == 0 or
		die "Can't run $vgimport for $deviceFile: $!";

	print "Running $vgchange -a y $deviceFile ...\n" if $debug;
	system("$vgchange -a y $deviceFile") == 0 or
		die "Can't run $vgchange for $deviceFile: $!";

	print "Running $vgcfgbak $deviceFile ...\n" if $debug;
	system("$vgcfgbak $deviceFile") == 0 or
		die "Can't run $vgcfgbak for $deviceFile: $!";

	unless (-d "/$deviceGroup") {
		mkpath("/$deviceGroup") or die "Can't mkdir /$deviceGroup : $!";
	}

	if ($fsck) {
		system("/usr/sbin/fsck $deviceFile/lvol1") == 0 or
			die "fsck $deviceFile/lvol1 returned non-zero and needs attention!: $! - $?";
	}

	print "You can now [mount -F vxfs $deviceFile/lvol1 /$deviceGroup] safely.\n";
}

sub pvCountForVolumeGroup {

        my $volume = shift;

        my @vgInfo  = ();
        my $pvCount = 0;
        my $vgName  = "/dev/${volume}";

        die "Unable to find [$vgName]: $!" if (! -d $vgName);

        open(VG, "$vgdisplay $vgName |") or die "Unable to run [$vgdisplay]: $!";

        while (my $line = <VG>) {

		chomp $line;

		if ($line =~ /^Act PV\s+(\d+)/) {
			$pvCount = $1;
			last;
		}
	}

        close(VG);

        return $pvCount;
}

#
# Redhat specific commands
#
sub changeDeviceGroupIdsOnBCVDisksForDeviceGroup {
	my $deviceGroup = shift;

	my $ret = 1; # success to begin with

	my ($bcvDevicesHashRef, $bcvDevicesOrderRef) = symmBCVDeviceListForDeviceGroup($deviceGroup);

	#
	#
	# This is the process to change the disk group ids on each BCV disk, we
	# should run this after each successfull bcv backup:
	#
	# 1. Find the vendor name for each device using 'vxdisk path' command
	#
	# 2. vxdisk -f init <bcv-vendor-disk-name> $(vxdisk list
	#       <std-vendor-disk-name> | \
	#               awk '/^public:/ {printf("pub%s pub%s ", $3, $4)} /^private:/
	#               {printf("priv%s priv%s", $3, $4)}')
	#
	#    This command reinitializes bcv disk with a new disk group id
	#
	#

	my @bcvDiskNames;

	my $cmd = "$vxdisk path";
	print "ariba::Ops::EMCUtils::changeDeviceGroupIdsOnBCVDisksForDeviceGroup($deviceGroup) cmd = $cmd\n" if ($debug);

	open(VX, "$cmd |") or die "Unable to run [$cmd]: $!";

	#SUBPATH                     DANAME               DMNAME       GROUP        STATE
	#sdp                         EMC0_0               -            -            ENABLED
	#sdg                         EMC0_0               -            -            ENABLED
	#sdo                         EMC0_1               -            -            ENABLED
	#sdf                         EMC0_1               -            -            ENABLED
	#sdn                         EMC0_2               -            -            ENABLED
	#sde                         EMC0_2               -            -            ENABLED
	while (my $line = <VX>) {

		my ($deviceName, $vendorName) = (split(/\s+/, $line))[0,1];
		for (my $i = 0; $i < @$bcvDevicesOrderRef; $i++) {
			my $bcvSymName = $bcvDevicesOrderRef->[$i];

			my $bcvDeviceName = ${$bcvDevicesHashRef->{$bcvSymName}}[0];

			#
			# Skip if the bcv device is not mapped
			#
			next if ($bcvDeviceName eq "N/A");

			# basename of the path
			$bcvDeviceName =~ s|^.*/([^/]*)|$1|;

			if ($deviceName eq $bcvDeviceName) {
				push(@bcvDiskNames, $vendorName);
				last;
			}
		}
	}

	close(VX);

	for (my $i = 0; $i < @bcvDiskNames; $i++) {

		my $bcvVendorName = $bcvDiskNames[$i];

		my ($publicString,  $privateString);

		$cmd = "$vxdisk list $bcvVendorName";
		print "ariba::Ops::EMCUtils::changeDeviceGroupIdsOnBCVDisksForDeviceGroup($deviceGroup) cmd = $cmd\n" if ($debug);

		open(VX, "$cmd |") or die "Unable to run [$cmd]: $!";

		# Device:    EMC0_0
		# devicetag: EMC0_0
		# type:      auto
		# hostid:
		# disk:      name= id=1115688033.8.goose.opslab.ariba.com
		# group:     name= id=
		# info:      format=cdsdisk,privoffset=256,pubslice=3,privslice=3
		# flags:     online ready private autoconfig autoimport
		# pubpaths:  block=/dev/vx/dmp/EMC0_0s3 char=/dev/vx/rdmp/EMC0_0s3
		# version:   3.1
		# iosize:    min=512 (bytes) max=256 (blocks)
		# public:    slice=3 offset=2304 len=20391936 disk_offset=0
		# private:   slice=3 offset=256 len=2048 disk_offset=0
		# update:    time=1115688033 seqno=0.1
		# ssb:       actual_seqno=0.0
		# headers:   0 240
		# configs:   count=1 len=1280
		# logs:      count=1 len=192
		# Defined regions:
		#  config   priv 000048-000239[000192]: copy=01 offset=000000 disabled
		#   config   priv 000256-001343[001088]: copy=01 offset=000192 disabled
		#    log      priv 001344-001535[000192]: copy=01 offset=000000 disabled
		#     lockrgn  priv 001536-001679[000144]: part=00 offset=000000
		#     Multipathing information:
		#     numpaths:   2
		#     sdp     state=enabled
		#     sdg     state=enabled
		#
		while (my $line = <VX>) {
			if ($line =~ /^public/) {
				my ($offsetString, $lenString) = (split(/\s+/, $line))[2,3];
				$publicString = "pub$offsetString pub$lenString";

			}

			if ($line =~ /^private/) {
				my ($offsetString, $lenString) = (split(/\s+/, $line))[2,3];
				$privateString = "priv$offsetString priv$lenString";
			}

			if ($publicString && $privateString) {
				#
				# Now reinit this bcv disk to have a differnt disk group id
				#
				$cmd = "$vxdisk -f init $bcvVendorName $publicString $privateString";
				print "ariba::Ops::EMCUtils::changeDeviceGroupIdsOnBCVDisksForDeviceGroup($deviceGroup) cmd = $cmd\n" if ($debug);

				if ($debug <= 2) {
					$ret = (system("$cmd >/dev/null 2>&1") == 0) && $ret;
				}
				last;
			}
		}
		close(VX);
	}

	return ($ret);
}

sub numberOfSubDisksInVolume {
        my $volume = shift;

        my $vxCount = 0;

	my $dgname = $volume;
	$dgname =~ s|\w$|dg|;

        open(VX, "$vxprint -g $dgname $volume |") or die "Unable to run [$vxprint $volume]: $!";

        while (my $line = <VX>) {

		chomp $line;

		#
		#sd EMC0_3-01    ora01a-01    ENABLED  20391936 0        -        -       -
		#sd EMC0_4-01    ora01a-01    ENABLED  20391936 0        -        -       -
		#
		if ($line =~ /^sd\s+.*ENABLED/) {
			$vxCount++;
		}
	}

        close(VX);

        return $vxCount;
}

1;

__END__
