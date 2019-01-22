package ariba::Ops::FileSystemUtils;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/FileSystemUtils.pm#62 $

use strict;
use File::Path;
use File::Basename;
use Carp;

use ariba::rc::Utils;
use ariba::Ops::OracleSIDRemap;

my $debug = 0;

my $df = "/bin/df";

my $scsi_info = "/usr/sbin/scsi_info";
$scsi_info = "/usr/bin/scsi_info", unless(-e $scsi_info);

my $vxprint = "/usr/sbin/vxprint";
my $vxdisk = "/usr/sbin/vxdisk";
my $vxdmpadm = "/usr/sbin/vxdmpadm";
my $vxdg = "/usr/sbin/vxdg";
my $vxvol = "/usr/sbin/vxvol";
my $vxmake = "/usr/sbin/vxmake";
my $vxsd = "/usr/sbin/vxsd";
my $vxplex = "/usr/sbin/vxplex";
my $vxedit = "/usr/sbin/vxedit";
my $ERR = undef;

my $DISKGROUPDBPATH = "/var/tmp/fsutils-db";

my $arch = $^O;
my %uniqBase = ('ssspro20' => 'oras4pro20' , 'ssspro21' => 'oras4pro21' );

=pod

=head1 NAME

ariba::Ops::FileSystemUtils - Utilities to map a filesystem mount to backend
device details (type of storage, lun id).

=head1 DESCRIPTION

These set of utilities offer an API to take a filesystem mount, and query
the host to figure out what devices up that filesystem and what kind of
storage the space comes from. It can also provide lun information for the
storage blocks that are used to make up the filesystem.

=cut

sub setDebug {
    $debug = shift;
}

sub getError {
    return($ERR);
}

sub waitForDisksInErrorState {
    while(1) {
        my $ret = 1;
        open(VX, "$vxdisk list |");
        while(my $line = /<VX>/) {
            $ret = 0 if($line =~ /^\-.*failed was:/);
        }
        close(VX);
        return if($ret);
        sleep 1;
        system("$vxdisk scandisks");
    }
}

# given a list of files, this function returns a list of unique mount points
sub uniqueMountPointsForPathList {
    my $dbFilePaths = shift;

        my %uniqueMountPoints;
        my %uniqueDataDirs;

        for my $dbFilePath (@$dbFilePaths) {
        # To reduce the systems calls to DF, we only check the directories.
        # If the file itself is a symlink this logic fails so we return nothing.
        return () if -l $dbFilePath;
                $uniqueDataDirs{dirname($dbFilePath)} = 1;
        }
        
        for my $dataDirPath (keys %uniqueDataDirs) {
                print "DEBUG db file dir = $dataDirPath\n" if ($debug);
                
        my $mountPoint = mountPointForPath($dataDirPath);
        $uniqueMountPoints{$mountPoint} = 1;
        }
        
        print "DEBUG mount points db file list: ", keys(%uniqueMountPoints), "\n" if $debug;

        return sort(keys(%uniqueMountPoints));
}

=pod

=over

=item mountPointForPath(vol)

Given a filesystem path it returns the mount point for that filesystem.

=cut

sub mountPointForPath{
    my $path = shift;
    my $mountPoint;

    my $command = "$df -P $path";
    print "DEBUG running command: $command\n" if $debug;
    open(DF, "$command |") or croak("Can't run $command: $!");
    while (my $line = <DF>) {
        chomp $line;

        if ($line =~ /^\/dev.* (\/\S+)$/) {
            $mountPoint = $1;
            last;
        }
    }
    close(DF);

    return $mountPoint;
}

=pod

=item devicesForMountPoint(mount point)

Give a mount point it returns a list of devices that make that filesystem.
Each device in the list also has additional information about the backend
storage that makes up that device. This additional information includes
lun# and type (vendor -- EMC or 3Par), etc.

The device array object has the form of:
@devices
 [0] -> 'lun' => '3'
         'name' => 'sdd' # vxNodeName, name column in vxdisk list and
         'osVvWwn' => '50002ac04b3d031f'
         'vendor' => '3PARdata'
         'veritasVvWwn' => '50002ac04b3d031f'
         'veritasVolume' => 'ora09a'
         'veritasDiskgroup => 'ora09dg'
     'paths' => [0] -> 'controller' => '0'
                                 'name' => 'sda'
                          [1] -> 'controller' => '1'
                                 'name' => 'sdi'

=cut

#
# left here to handle any errant call
#
sub onlineDiskGroupFromLuns {
    return(scanAndOnlineDiskGroup(@_));
}

sub updateHanaConfig {
    my $lun = shift;
    my $sid = shift;
    my $oldId = shift;

    unless(defined($lun) && $sid && $oldId) {
        $ERR = "updateHanaConfig requires a lun, sid, and oldId";
        return(0);
    }

    if($<) {
        $ERR = "must run updatehana as root";
        return(0);
    }

    my $mapId;

    open(F, "/sbin/multipath -ll |");
    while(my $line = <F>) {
        if($line =~ /^([0-9a-f]+)\s+dm/) {
            $mapId = $1;
        }
        if($line =~ /(\d+:\d+:\d+:\d+)/) {
            my $lunStr = $1;
            my @l = split(/:/,$lunStr);
            my $thisLun = $l[3];
            last if($thisLun == $lun);
        }
    }

    unless($mapId) {
        $ERR = "Did not find multipath FS for $lun";
        return(0);
    }

    return(1) if($oldId eq $mapId); # nothing to do here

    $sid = uc($sid);
    my @configs = (
        "/usr/sap/$sid/SYS/global/hdb/custom/config/global.ini",
        "/etc/multipath.conf",
    );

    foreach my $config (@configs) {
        my $backupFileName = "/tmp/" . basename($config) . ".orig";
        my $newFileName = "/tmp/" . basename($config) . ".new";
        system("cp $config $backupFileName");
        my $IN;
        my $OUT;
        open($IN, $backupFileName);
        open($OUT, "> $newFileName");
        while(my $line = <$IN>) {
            $line =~ s/$oldId/$mapId/g;
            print $OUT $line;
        }
        close($IN);
        close($OUT);

        if($config eq "/etc/multipath.conf") {
            system("cp $newFileName $config");
        } else {
            my $admuser = lc($sid) . "adm";
            system("su $admuser -c 'cp $newFileName $config'");
        }
    }

    return(1);
}

sub mountMultiPathLunAsVolume {
    my $lun = shift;
    my $volume = shift;

    unless(defined($lun) && $volume) {
        $ERR = "mountMultiPathLunAsVolume requires a lun and volume";
        return(0);
    }

    my $mapId;

    open(F, "/sbin/multipath -ll |");
    while(my $line = <F>) {
        if($line =~ /^([0-9a-f]+)\s+dm/) {
            $mapId = $1;
        }
        if($line =~ /(\d+:\d+:\d+:\d+)/) {
            my $lunStr = $1;
            my @l = split(/:/,$lunStr);
            my $thisLun = $l[3];
            last if($thisLun == $lun);
        }
    }

    unless($mapId) {
        $ERR = "Did not find multipath FS for $lun";
        return(0);
    }

    my $cmd = "/bin/mount -t xfs /dev/mapper/$mapId $volume";

    print "issuing $cmd...\n";
    my @output;
    unless (ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1)) {
        $ERR = join('; ', "Failed to mount $volume with $lun", @output);
        return(0);
    }

    return(1);
}

sub loadHanaDisksByLuns {
    my $luns = shift;

    unless(defined($luns)) {
        $ERR = "loadHanaDisks requires a list of luns.\n";
        return(0);
    }

    return(0) unless(scsiScan());
    return(0) unless(clearUnusedLuns($luns));

    my %lunsList;
    map { $lunsList{$_} = 1 } split(/,/, $luns);

    #
    # now we need to run lsscsi to force multipath on these luns
    #
    my $tries = 0;
    my $count = 0;
    while($count != scalar(keys(%lunsList))) {
        my $FH;
        open($FH, "/usr/bin/lsscsi |");
        while(my $line = <$FH>) {
            my ($lunInfo, $ptype, $vendor, $ltype, $jnk, $device) = split(/\s+/, $line);
            next unless($ptype eq 'disk');
            next unless($ltype eq 'VV');
            next unless($vendor =~ /3PAR/);

            my $thisLun;
            if($lunInfo =~ /\d+:\d+:\d+:(\d+)/) {
                $thisLun = $1;
            } else {
                next;
            }

            if($lunsList{$thisLun} && $lunsList{$thisLun} !~ m|^/dev/| && $device =~ m|^/dev/s|) {
                $lunsList{$thisLun} = $device;
                $count++;
            }
        }
        sleep(2);
        $tries++;
        last if($tries > 30);
    }

    foreach my $thisLun (sort keys %lunsList) {
        my $device = $lunsList{$thisLun};
        if($device =~ m|^/dev/|) {
            my $cmd = "/sbin/multipath $device"; 
            my @output;
            print "Run $cmd...\n";
            unless (ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1)) {
                $ERR = join('; ', "Failed to run $cmd...", @output);
                return(0);
            }
        } else {
            print "Skipping $thisLun (did not find $device).\n";
        }
    }

    return(1);
}

sub clearUnusedLuns {
    my $luns = shift;
    my @output;

    unless(defined($luns)) {
        $ERR = "clearUnusedLuns requires a list of whitelisted luns.\n";
        return(0);
    }

    $luns =~ s/[^0-9,]//g;
    my %lunsHash;
    map { $lunsHash{$_} = 1 } split(/,/, $luns);

    my %removeLuns;
        
    #
    # get the disk devices for the luns
    #
    my $cmd = "/sbin/multipath -ll";
    print "Calling $cmd...\n";
    my $FH;
    open($FH, "$cmd |");
    while(my $line = <$FH>) {
        my $thisLun;
        if($line =~ /\d+:\d+:\d+:(\d+)/) {
            $thisLun = $1;
        } else {
            next;
        }

        unless(defined($lunsHash{$thisLun})) {
            $removeLuns{$thisLun} = 1;
        }
    }

    foreach my $lun (sort keys %removeLuns) {
        print "Removing unused lun $lun...\n";
        return(0) unless removeOSLun($lun);
    }

    return(1);
}

sub scsiScan {
    if( -e "/proc/scsi/qla2xxx/0" ) {
        print "doing scsi qlasscan...\n" if( -t STDOUT );
        echo("scsi-qlascan", "/proc/scsi/qla2xxx/0", 1);
        echo("- - -", "/sys/class/scsi_host/host0/scan");
        echo("scsi-qlascan", "/proc/scsi/qla2xxx/1", 1);
        echo("- - -", "/sys/class/scsi_host/host1/scan");
    } else {
        open(SCAN, "/usr/bin/find /sys/class/scsi_host/ |");
        while(my $scan = <SCAN>) {
            chomp $scan;
            next unless ($scan =~ m|^/sys/class/scsi_host/host\d+$|);
            $scan .= "/scan";
            print "rescan $scan\n";
            chomp $scan;
            echo("- - -", $scan);
        }
        close(SCAN);
    }
    return(1);
}

#
# the other onlineDiskGroup call assumes that the disk group was offlined
# by this script, and that we recorded meta data listing the disks.
#
# we can't use that for thin restore, because we recreated the disks, and
# they won't have the same OS mounts, but we do know the LUN assignment.
#
sub scanAndOnlineDiskGroup {
    my $dg = shift;

    unless($dg) {
        $ERR = "onlineluns requires a disk group.\n";
        return(0);
    }

    scsiScan();

    print "doing vxdisk scandisks...\n" if( -t STDOUT );
    system("$vxdisk scandisks");

    my @output;
    my $cmd;

    print "Running $vxdg -Cf import $dg\n" if(-t STDOUT);
    $cmd = "$vxdg -Cf import $dg";
    unless (ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1)) {
        $ERR = join('; ', "Failed to import $dg", @output);
        return(0);
    }

    print "Running $vxvol -g $dg startall\n";
    $cmd = "$vxvol -g $dg startall";
    unless (ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1)) {
        $ERR = join('; ', "Failed to start volumes for $dg", @output);
        return(0);
    }

    return(1);
}

sub joinDG {
    my $sourceDG = shift;
    my $targetDG = shift;

    my $cmd = "$vxdg join $sourceDG $targetDG";
    my @output;

    unless (ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1)) {
        croak("Failed to merge $sourceDG into $targetDG:" . join("; ", @output));
    }

    return(1);
}


sub mountedFilesystemsForSID {
    my $sid = shift;
    my @ret;

    my $base = ariba::Ops::OracleSIDRemap->mountPointForSid($sid, "/oracle/admin/pfile");
    $base = $uniqBase{$sid} if (defined $uniqBase{$sid}); 

    #
    # mountPointForSid will return ora14 -- in the real world the ACTUAL mount 
    # is /ora14a, /ora14data01, /ora14log01, etc.  The exception is rman, which
    # is why we also preserve $base eq $fs
    #

    foreach my $fs (mountedFileSystemsOfType("vxfs")) {
        if($fs =~ m|^/${base}a| || $fs =~ m|^/${base}log| || $fs =~ m|^/${base}data| || "/$base" eq $fs) {
            push(@ret,$fs);
        }
    }

    return(@ret);
}

sub growFS {
    my $dg = shift;
    my $volume = shift;
    my $lun = shift;

    unless($dg) {
        $ERR = "initdg requires a disk group.\n";
        return(0);
    }
    unless($volume) {
        $ERR = "initdg requires a volume.\n";
        return(0);
    }
    unless($lun) {
        $ERR = "initdg requires a lun.\n";
        return(0);
    }

    my @luns = split(',', $lun);

    if( -e "/proc/scsi/qla2xxx/0" ) {
        print "doing scsi qlasscan...\n" if( -t STDOUT );
        echo("scsi-qlascan", "/proc/scsi/qla2xxx/0", 1);
        echo("- - -", "/sys/class/scsi_host/host0/scan");
        echo("scsi-qlascan", "/proc/scsi/qla2xxx/1", 1);
        echo("- - -", "/sys/class/scsi_host/host1/scan");
    } else {
        open(SCAN, "/usr/bin/find /sys/class/scsi_host/ -name scan |");
        while(my $scan = <SCAN>) {
            print "rescan $scan";
            chomp $scan;
            echo("- - -", $scan);
        }
        close(SCAN);
    }

    print "doing vxdisk scandisks...\n" if( -t STDOUT );
    system("$vxdisk scandisks");

    my %paths;
    open(P, "/usr/bin/lsscsi |") || return(0);
    my @lsscsi = <P>;
    close(P) || return(0);

    my $ct = 1;
    foreach $lun (@luns) {
        print "running lsscsi to get os device names for lun $lun...\n" if(-t STDOUT );
        foreach my $line (@lsscsi) {
            chomp $line;
            next unless ($line =~ m|^\[(\d+):0:[01]:$lun\].*/([^/]+)$|);
            my $path = $1;
            my $device = $2;
            print "... found $device on path $path...\n" if( -t STDOUT );
            $paths{$device} = $ct;
        }
        $ct++;
    }

    my %vxdiskhash;
    print "Looking for vx disk name with vxdisk list...\n" if( -t STDOUT );
    open(P, "$vxdisk list -o alldgs -e |") || return(0);
    while(my $line = <P>) {
        chomp $line;
        next if($line =~ /DEVICE/);
        my ($vxdev, $type, $vxd, $vxgroup, $status, $osname) =
            split(/\s+/,$line);
        if($paths{$osname}) {
            # found it!
            print "... found $vxdev associated with $osname\n" if( -t STDOUT );
            $vxdiskhash{$vxdev} = $paths{$osname};
        } else {
            print "... running vxdisk list $vxdev to look for disk.\n" if( -t STDOUT );
            open(PP, "$vxdisk list $vxdev |");
            while(my $x = <PP>) {
                chomp $x;
                if($x =~ /^(\w+)\s+state=enabled/) {
                    $osname = $1;
                    if($paths{$osname}) {
                        # found it!
                        print "... found $vxdev associated with $osname\n" if( -t STDOUT );
                        $vxdiskhash{$vxdev} = $paths{$osname};
                    }
                }
            }
            close(PP);
        }
    }
    close(P) || return(0);

    my @vxdisks = (sort { $vxdiskhash{$a} <=> $vxdiskhash{$b} } keys %vxdiskhash);
    unless(scalar(@vxdisks)) {
        $ERR = "Unable to find VX device for OS device.\n";
        return(0);
    }

    foreach my $vxdsk (@vxdisks) {
        print "Running /etc/vx/bin/vxdisksetup -i $vxdsk format=cdsdisk privlen=2048\n" if( -t STDOUT );
        system("/etc/vx/bin/vxdisksetup -i $vxdsk format=cdsdisk privlen=2048");

        print "Running $vxdg -g $dg adddisk $vxdsk...\n" if( -t STDOUT );
        system("$vxdg -g $dg adddisk $vxdsk");

        open(P, "$vxprint -g $dg -d -F %pub_len $vxdsk |");
        my $length = <P>; chomp $length;
        close(P);
        print "Running $vxmake -g $dg sd ${vxdsk}-01 $vxdsk,0,$length\n" if( -t STDOUT );
        system("$vxmake -g $dg sd ${vxdsk}-01 $vxdsk,0,$length");

        my $cmd = "$vxsd -g $dg assoc ${volume}-01 ${vxdsk}-01";
        print "Running $cmd...\n" if( -t STDOUT );
        system("$cmd");
    }

    open(P, "$vxprint -g $dg -p -F %len ${volume}-01 |");
    my $length = <P>; chomp $length;
    close(P);

    my $cmd = "$vxvol -g $dg set len=$length $volume";
    print "Running $cmd...\n" if( -t STDOUT );
    system($cmd);

    open(P, "$vxprint -g $dg -v -F %len $volume |");
    $length = <P>; chomp $length;
    close(P);

    $cmd = "/opt/VRTS/bin/fsadm -t vxfs -b $length /$volume";
    print "Running $cmd...\n" if( -t STDOUT );
    system($cmd);

    return(1);
}

sub initDiskGroup {
    my $dg = shift;
    my $volume = shift;
    my $lun = shift;

    unless($dg) {
        $ERR = "initdg requires a disk group.\n";
        return(0);
    }
    unless($volume) {
        $ERR = "initdg requires a volume.\n";
        return(0);
    }
    unless($lun) {
        $ERR = "initdg requires a lun.\n";
        return(0);
    }

    my @luns = split(',', $lun);

    if( -e "/proc/scsi/qla2xxx/0" ) {
        print "doing scsi qlasscan...\n" if( -t STDOUT );
        echo("scsi-qlascan", "/proc/scsi/qla2xxx/0", 1);
        echo("- - -", "/sys/class/scsi_host/host0/scan");
        echo("scsi-qlascan", "/proc/scsi/qla2xxx/1", 1);
        echo("- - -", "/sys/class/scsi_host/host1/scan");
    } else {
        open(SCAN, "/usr/bin/find /sys/class/scsi_host/ -name scan |");
        while(my $scan = <SCAN>) {
            print "rescan $scan";
            chomp $scan;
            echo("- - -", $scan);
        }
        close(SCAN);
    }

    print "doing vxdisk scandisks...\n" if( -t STDOUT );
    system("$vxdisk scandisks");

    my %paths;
    open(P, "/usr/bin/lsscsi |") || return(0);
    my @lsscsi = <P>;
    close(P) || return(0);

    my $ct = 1;
    foreach $lun (@luns) {
        print "running lsscsi to get os device names for lun $lun...\n" if( -t STDOUT );
        foreach my $line (@lsscsi) {
            chomp $line;
            next unless ($line =~ m|^\[(\d+):0:[01]:$lun\].*/([^/]+)$|);
            my $path = $1;
            my $device = $2;
            print "... found $device on path $path...\n" if( -t STDOUT );
            $paths{$device} = $ct;
        }
        $ct++;
    }

    my %vxdiskhash;
    print "Looking for vx disk name with vxdisk list...\n" if( -t STDOUT );
    open(P, "$vxdisk list -o alldgs -e |") || return(0);
    while(my $line = <P>) {
        chomp $line;
        next if($line =~ /DEVICE/);
        my ($vxdev, $type, $vxd, $vxgroup, $status, $osname) =
            split(/\s+/,$line);
        if($paths{$osname}) {
            # found it!
            print "... found $vxdev associated with $osname\n" if( -t STDOUT );
            $vxdiskhash{$vxdev} = $paths{$osname};
        } else {
            print "... running vxdisk list $vxdev to look for disk.\n" if( -t STDOUT );
            open(PP, "$vxdisk list $vxdev |");
            while(my $x = <PP>) {
                chomp $x;
                if($x =~ /^(\w+)\s+state=enabled/) {
                    $osname = $1;
                    if($paths{$osname}) {
                        # found it!
                        print "... found $vxdev associated with $osname\n" if( -t STDOUT );
                        $vxdiskhash{$vxdev} = $paths{$osname};
                    }
                }
            }
            close(PP);
        }
    }
    close(P) || return(0);
    my @vxdisks = (sort { $vxdiskhash{$a} <=> $vxdiskhash{$b} } keys %vxdiskhash);
    unless(scalar(@vxdisks)) {
        $ERR = "Unable to find VX device for OS device.\n";
        return(0);
    }

    foreach my $vxdsk (@vxdisks) {
        print "Running /etc/vx/bin/vxdisksetup -i -f $vxdsk format=cdsdisk privlen=2048\n" if( -t STDOUT );
        system("/etc/vx/bin/vxdisksetup -i -f $vxdsk format=cdsdisk privlen=2048");
    }

    my $vxdsks = join(' ', @vxdisks);
    print "Running $vxdg init $dg cds=on $vxdsks\n" if( -t STDOUT );
    system("$vxdg init $dg cds=on $vxdsks");

    foreach my $vxdsk (@vxdisks) {
        open(P, "$vxprint -g $dg -d -F %pub_len $vxdsk |");
        my $length = <P>; chomp $length;
        close(P);
        print "Running $vxmake -g $dg sd ${vxdsk}-01 $vxdsk,0,$length\n" if( -t STDOUT );
        system("$vxmake -g $dg sd ${vxdsk}-01 $vxdsk,0,$length");
    }

    print "Running $vxmake -g $dg plex ${volume}-01 layout=concat\n" if( -t STDOUT );
    system("$vxmake -g $dg plex ${volume}-01 layout=concat");

    foreach my $vxdsk (@vxdisks) {
        my $cmd = "$vxsd -g $dg assoc ${volume}-01 ${vxdsk}-01";
        print "Running $cmd...\n" if( -t STDOUT );
        system("$cmd");
    }

    print "Running $vxmake -g $dg vol $volume\n" if( -t STDOUT );
    system("$vxmake -g $dg vol $volume");
    print "Running $vxplex -g $dg att $volume ${volume}-01\n" if( -t STDOUT );
    system("$vxplex -g $dg att $volume ${volume}-01");
    open(P, "$vxprint -g $dg -p -F %len ${volume}-01 |");
    my $length = <P>; chomp $length;
    close(P);

    my $cmd = "$vxvol -g $dg set len=$length $volume";
    print "Running $cmd...\n" if( -t STDOUT );
    system($cmd);
    print "Running $vxvol -g $dg start $volume\n" if( -t STDOUT );
    system("$vxvol -g $dg start $volume");

    return(1);
}

sub removeOSLun {
    my $lun = shift;

    unless(defined($lun)) {
        $ERR = "Must pass a LUN to removeOSLun()\n";
        return(0);
    }

    open(P, "/usr/bin/find /sys/devices/ -name delete | grep /rport | grep 0:[0-9]:$lun/ |") || return(0);

    while(my $file = <P>) {
        chomp $file;
        echo("1", $file) || return(0);
    }

    close(P);

    return(1);
}

sub echo {
    my $e = shift;
    my $f = shift;
    my $append = shift;

    if($append) {
        open(F, ">> $f") || return(0);
    } else {
        open(F, "> $f") || return(0);
    }

    print F "$e\n";
    close(F) || return(0);
}

sub offlineDiskgroup {
    my $dgname = shift;
    my $removeDisks = shift;

    my @devices;
    for my $volume (volumesForDiskgroup($dgname)) {
        # Identify and unmount the filesystem
        my $filesystem = filesystemForVolumeAndDiskgroup($volume, $dgname);
        if (isMounted($filesystem)) {
            print "DEBUG: unmounting $filesystem\n" if $debug;
            unless (unmountFilesystem($filesystem)) {
                $ERR = "Failed to unmount $filesystem.";
                return;
            }
        }
        
        push(@devices, devicesForVolumeAndDiskgroup($volume, $dgname));
    }

    print "DEBUG: Persisting disk information for $dgname\n" if $debug;
    unless (ariba::rc::Utils::mkdirRecursively($DISKGROUPDBPATH)) {
            croak("Could not create directory $DISKGROUPDBPATH");
    }

    my $cmd = "$vxprint -g $dgname -d -F '\%da_name'" . "> $DISKGROUPDBPATH/$dgname";
    unless (ariba::rc::Utils::executeLocalCommand($cmd)) {
            croak("Could not persist disk information to $DISKGROUPDBPATH/$dgname");
    }
    
    print "DEBUG: deporting $dgname\n" if $debug;
    unless (deportDiskgroup($dgname)) {
        $ERR = "Failed to deport $dgname.";
        return;
    }

    print "DEBUG: offlining devices\n" if $debug;
    unless (offlineDevices(\@devices, $removeDisks)) {
        $ERR = "Failed to offline disks.";
        return;
    }

    return 1;
}

sub onlineDiskgroup {
    my $dgname = shift;

    unless (isDiskGroupAvailable($dgname)) {
        print "DEBUG: onlining disks for $dgname\n" if $debug;
        return unless onlineDisksForDiskgroup($dgname);
    }

    print "DEBUG: importing $dgname\n" if $debug;
    return unless importDiskgroup($dgname);

    return 1;

}

sub mountFilesystemsForDiskgroup {
    my $dgname = shift;

    for my $volume (volumesForDiskgroup($dgname)) {
        # Identify and unmount the filesystem
        my $filesystem = filesystemForVolumeAndDiskgroup($volume, $dgname);
        next if isMounted($filesystem);
    
        print "DEBUG: mounting $filesystem\n" if $debug;
        return unless mountFilesystem($filesystem);
    }

    return 1;
}

sub isDiskGroupAvailable {
    my $dgname = shift;

    my $cmd = "$vxdisk list -e -o alldgs";
    my @output;
    unless (ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1)) {
        croak("running '$cmd' failed:\n" . join("\n", @output));
    }

    return 1 if grep($_ =~ m/\s\(?$dgname\)?\s/, @output);
    return 0;
}

sub isDiskgroupImported {
    my $dgname = shift;

    my $cmd = "$vxdg list $dgname";
    return 1 if ariba::rc::Utils::executeLocalCommand($cmd);
    return 0;
}

sub onlineDisksForDiskgroup {
    my $dgname = shift;

    return unless (-f "$DISKGROUPDBPATH/$dgname");

    open (DISKS, "$DISKGROUPDBPATH/$dgname") || return;
    for my $disk (<DISKS>) {
        chomp $disk;
        my $cmd = "$vxdisk online $disk";
        my @output;
        unless (ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1)) {
            croak("onlining $disk failed:\n" . join("\n", @output));
        }
    }
    
    close DISKS;

    return 1;

}

sub offlineDevices {
    my $devices = shift;
    my $removeDisks = shift;

    for my $device (@$devices) {

        my $disk = $device->name();
        my $cmd = "$vxdisk offline $disk";
        $cmd = "$vxdisk rm $disk" if($removeDisks);
        my @output;
        unless (ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1)) {
            croak("offlining $disk failed:\n" . join("\n", @output));
        }
    }

    return 1;
}

sub deportDiskgroup {
    my $dgname = shift;

    # deport the diskgroup
    my $cmd = "$vxdg deport $dgname";
    my @output;
    unless (ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1)) {
        croak("Failed to deport diskgroup $dgname:\n" . join("\n", @output));
    }

    return 1;
}

sub importDiskgroup {
    my $dgname = shift;

    return 1 if isDiskgroupImported($dgname);

    # import the diskgroup
    my $cmd = "$vxdg -Cf import $dgname";
    my @output;
    unless (ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1)) {
        croak("Failed to deport diskgroup $dgname:\n" . join("\n", @output));
    }

    $cmd = "$vxvol -g $dgname startall";
    unless (ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1)) {
        croak("Failed to start volumes for $dgname:\n" . join("\n", @output));
    }
    
    return 1;
}

sub removeDisksForMountPoint {
    my $mountPoint = shift;
    my @disks = @_;

    my ($dgname, $volume) = diskgroupAndVolumeForMountPoint($mountPoint);

    my $cmd = "$vxvol -g $dgname stop $volume";
    my @output;
    unless (ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1)) {
        croak("Failed to stop volume $volume in $dgname:\n" . join("\n", @output));
    }

    $cmd = "$vxedit -g $dgname rm -r $volume";
    unless (ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1)) {
        croak("Failed to remove volume $volume from $dgname:\n" . join("\n", @output));
    }

    $cmd = "$vxdg -g $dgname rmdisk " . join(" ", @disks);
    unless (ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1)) {
        croak("Failed to remove disks " . join(" ", @disks) . " from $dgname:\n" . join("\n", @output));
    }

    deportDiskGroup($dgname);

    $cmd = "$vxdisk rm " . join(" ", @disks);
    unless (ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1)) {
        croak("Failed to remove disks " . join(" ", @disks) . " from host:\n" . join("\n", @output));
    }

    return 1;
}

sub unmountFilesystem {
    my $filesystem = shift;

    my $cmd = "umount $filesystem";
    my @output;
    unless (ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1)) {
        croak("Failed to unmount $filesystem:\n" . join("\n", @output));
    }

    return 1;
}

sub mountFilesystem {
    my $filesystem = shift;

    my $cmd = "mount $filesystem";
    my @output;
    unless (ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1)) {
        croak("Failed to unmount $filesystem:\n" . join("\n", @output));
    }

    return 1;
}


sub isMounted {
    my $filesystem = shift;

    return 0 unless($filesystem);

    open(MTAB, "/etc/mtab") or return;
    my $isMounted = grep ($_ =~ m%\s$filesystem\s%, <MTAB>);
    close MTAB;

    return $isMounted;
}

sub xfsDevicesForMountPount {
    my $mountPoint = shift;
    my @ret;
    my $device;

    #
    # run /bin/mount to get the multipath ID
    #
    my $command = "/bin/mount";
    return(@ret) unless (open(MOUNT, "$command |"));
    while(my $line = <MOUNT>) {
        if($line =~ m|^([^\s]+) on $mountPoint type|) {
            $device = $1;
            last;
        }
    }
    close(MOUNT);

    return(@ret) unless($device);

    my $id = $device;
    $id =~ s|^/dev/mapper/||;

    my $d = ariba::Ops::FileSystem::Device->new($id);
    $d->setStorageProperties();
    $d->setDiskGroup("n/a");
    $d->setDiskName($device);


    push(@ret, $d);

    #
    # this call expects an array, so we give an array of one
    #
    return(@ret);
}

sub devicesForMountPoint {
    my $mountPoint = shift;
    my @vxDevices;

    croak "$mountPoint is not a valid mount point" unless $mountPoint =~ m|^/|;

    my $type = fstypeForMountPoint($mountPoint);

    if($type eq 'vxfs') {

        my ($dgname, $volume) = diskgroupAndVolumeForMountPoint($mountPoint);

        my @devices = devicesForVolumeAndDiskgroup($volume, $dgname);

        foreach my $device (@devices) {
            $device->setveritasVolume($volume);
            $device->setveritasDiskGroup($dgname);
        }

        checkForInvalidVvWwnForDevices(@devices);
        printDeviceDebugInformation(@devices) if $debug;

        return @devices;
    } elsif ($type eq 'xfs') {
        return(xfsDevicesForMountPount($mountPoint));
    }
}

sub devicesForVolumeAndDiskgroup {
    my $volume = shift;
    my $dgname = shift;

    if (mirroredPlexes($dgname, $volume)) {
        return _deviceDetailsForMirroredPlexes($dgname, $volume);
    } else {
        return _deviceDetailsForUnMirroredPlexes($dgname, $volume);
    }
}

sub diskgroupAndVolumeForMountPoint {
    my $mountPoint = shift;

    my $devicePath = devicePathForMountPoint($mountPoint);

    croak "Can't find devicePath for mountpoint: $mountPoint" if (!$devicePath);

    my ($dgname, $volume);
    if ($devicePath && $devicePath =~ m|^/dev/vx/dsk/([^/]+)/([^/]+)|) {
        $dgname = $1;
        $volume = $2;
    }
    croak "Can't find diskgroup for devicePath: $devicePath" if (!$dgname);

    return ($dgname, $volume);
}

sub diskgroupForMountPoint {
    my $mountPoint = shift;

    return (diskgroupAndVolumeForMountPoint)[0];
}

sub volumeForMountPoint {
    my $mountPoint = shift;

    return (diskgroupAndVolumeForMountPoint)[1];
}

sub mirroredPlexes {
    my $dgname = shift;
    my $volume = shift;

    my @devices;

    my $command = "$vxprint -g $dgname -p -q";
    print "DEBUG running command: $command\n" if $debug;
        open(VXPRINT, "$command |") or return;

    #pl test-inserv2-01 test01 ENABLED 1073694208 - ACTIVE - -
    #pl test01-01 test01 ENABLED 51364096 - ACTIVE - -
    my $matchedPlexes = 0;
        while (my $line = <VXPRINT>) {
        chomp $line;
        if ($line =~ /^pl\s+\S+\s+(\S+)\s+ENABLED.*/) {
            $matchedPlexes++ if ($1 eq $volume);
        }
    }
        close(VXPRINT);

    return 1 if $matchedPlexes >= 2;
    return 0 if $matchedPlexes == 1;
    return;
}

sub volumesForDiskgroup {
    my $dgname = shift;

    my @volumes;

    my $command = "$vxprint -g $dgname -v -F %vname";
    print "DEBUG running command: $command\n" if $debug;
    open(my $VXPRINT, "$command |") or return;
    while (my $volume = <$VXPRINT>) {
        chomp $volume;
        push(@volumes, $volume);
    }
    close $VXPRINT;

    return @volumes;
}

sub filesystemsForDiskgroup {
    my $dgname = shift;

    my @filesystems;
    for my $volume (volumesForDiskgroup($dgname)) {
        my $filesystem = filesystemForVolumeAndDiskgroup($volume, $dgname);
        push(@filesystems, $filesystem) if $filesystem;
    }

    return @filesystems;
}

sub filesystemForVolumeAndDiskgroup {
    my $volume = shift;
    my $dgname = shift;

    open(FSTAB, "/etc/fstab") or return;
    my @fstab = grep(!/^#/, <FSTAB>);
    close FSTAB;

    my $volumePath = "/dev/vx/dsk/$dgname/$volume";
    my ($matchingEntry) = grep($_ =~ m%^$volumePath\s%, @fstab);
    return undef unless($matchingEntry);
    my $filesystem = (split(/\s+/, $matchingEntry))[1];

    return $filesystem;
}

sub _deviceDetailsForMirroredPlexes {
    my $dgname = shift;;
    my $volume = shift;

    my @devices;
    my $gatherDeviceDetails = 0;

    my $command = "$vxprint -g $dgname $volume";
    print "DEBUG running command: $command\n" if $debug;
        open(my $VXPRINT, "$command |") or return @devices;
        while (my $line = <$VXPRINT>) {
        chomp $line;
        my ($type, $name, $assoc, $kstate, $length, $ploffs, $state) =
            split(/\s+/, $line);

        if ($type eq "pl" && $name !~ /mirror/) {
            $gatherDeviceDetails = 1;
        } elsif ($type ne "sd" && $gatherDeviceDetails) {
            $gatherDeviceDetails = 0;
        } elsif ($type eq "sd" && $gatherDeviceDetails) {

            my $command = "$vxprint -g $dgname $name -F %da_name";
            print "DEBUG running command: $command\n" if $debug;
                open(my $VXPRINT, "$command |") or return @devices;
            my $sd_assoc = <$VXPRINT>;
            close $VXPRINT;

            chomp $sd_assoc;
            my $device = ariba::Ops::FileSystem::Device->new($sd_assoc);
            $device->setDiskGroup($dgname);
            push @devices, $device if $device;
        }
    }
        close($VXPRINT);

    return @devices;
}

sub _deviceDetailsForUnMirroredPlexes {
    my $dgname = shift;;
    my $volume = shift;

    my @devices;

    my $command = "$vxprint -rg $dgname $volume";
    print "DEBUG running command: $command\n" if $debug;
        open(VXPRINT, "$command |") or return @devices;

        #TY NAME ASSOC KSTATE LENGTH PLOFFS STATE TUTIL0 PUTIL0
        #dm sdw sdw - 105373824 - - - -
        #dm sdx sdx - 105373824 - - - -
    print "DEBUG Veritas device names: " if $debug;
        while (my $line = <VXPRINT>) {
        chomp $line;

        if ($line =~ /^dm\s+/) {
            my ($ty, $name, $assoc, $rest) = split(/\s+/, $line, 4);
            print "$assoc " if $debug;
            my $device = ariba::Ops::FileSystem::Device->new($assoc);
            next unless($device);
            $device->setDiskGroup($dgname);
            push @devices, $device if $device;
        }
    }
        close(VXPRINT);
    print "\n" if $debug;

    return @devices;
}

=pod

=item devicesForSystem()

For all imported disk devices on the host and build out the devices
hash just the same as devicesForMountPoint sans volume.

=cut

sub devicesForSystem {
    my @devices;

    # Determine which naming scheme is used by Veritas.
    # - RHEL4/VX5.0 = Operating system native naming (e.g. sda, sdb, etc)
    # - RHEL5/VX5.1 = Enclosure based naming (3pardata0_VvID1, 3pardata0_VvID2, etc)
    my $enclosureBasedNamingScheme = 0;

    my $vxddladm = '/usr/sbin/vxddladm get namingscheme 2>/dev/null';
    open(VXDDLADM, "$vxddladm |") or return 0;
    while (my $line = <VXDDLADM>) {
        chomp $line;
        if ($line =~ /Enclosure Based/) {
            $enclosureBasedNamingScheme = 1;
            last;
        }
    }
    close(VXDDLADM);

    my $namePattern;
    if ($enclosureBasedNamingScheme) {
        $namePattern = '^(3pardata\d_\S+)';
    } else {
        $namePattern = '^(sd\S+)';
    }

    my $command = "$vxdisk list";
    print "DEBUG running command: $command\n" if $debug;
    open(VXDISK, "$command |") or croak "Cannot run $vxdisk list";
    while (my $line = <VXDISK>) {
        chomp $line;
        if ( my ($vxNodeName) = $line =~ /$namePattern/ ) {
            my $device = ariba::Ops::FileSystem::Device->new($vxNodeName);
            push @devices, $device if $device;
        }
    }
    close VXDISK;

    return @devices;
}

=pod

=pod

=item printDeviceDebugInformation(device list)

Takes the device list as argument and prints out a bunch of debug information.

=cut

sub printDeviceDebugInformation {
    my @devices= shift;

    for my $device (@devices) {
        print "vol = ", $device->veritasVolume(), "\n",
              " dev = ", $device->name(),
              " vendor = ", $device->vendor(),
              " lunId = ", $device->lun(),
              " Veritas VV WWN = ", $device->veritasVvWwn(),
              " OS VV WWN = ", $device->osVvWwn(), "\n";
        if ($device->isEMC()) {
            print " device is EMC\n";
        } elsif ($device->is3Par()) {
            print " device is 3PAR\n";
        }
    }

}

=pod

=item devicePathForMountPoint(mount point)

Takes a mountpoint for an argument and returns the corresponding device path

=cut

sub devicePathForMountPoint {
    my $mountpoint = shift;

    open(FSTAB, "/etc/fstab") or return;
    my @fstab = grep(!/^#/, <FSTAB>);
    close FSTAB;

    for my $entry (@fstab) {
        my ($device, $mountpointFromFstab, $rest) = split (/\s+/, $entry, 3);
        return $device if $mountpoint eq $mountpointFromFstab;
    }
        
    return "$mountpoint is missing from /etc/fstab, Please add $mountpoint in /etc/fstab";

}

=pod

=item checkForInvalidVvWwnForDevices(deviceList)

Given a list of devices check each one to see if their OS VV WWN and
Veritas VV WWN match. If they do not match there is an inconsistency
somewhere (most likely Veritas) mapping Veritas devices in a disk group
back to the OS devices with the same VV WWN.

=cut

sub checkForInvalidVvWwnForDevices {
    my @devices = @_;
    my @invalidDevices = ();

    foreach my $device (@devices) {
        if ( ($device->osVvWwn() ne $device->veritasVvWwn()) && 
             ($device->veritasVvWwn() ne $device->veritasVvTag()) ) {
            push @invalidDevices, $device;
        }
    }

    if (@invalidDevices) {
        foreach my $invalidDevice (@invalidDevices) {
            print "Invalid Device : ", $invalidDevice->name(), "\n",
                  " OS VV WWN : ", $invalidDevice->osVvWwn(), "\n",
                  " Veritas VV WWN: ", $invalidDevice->veritasVvWwn(), "\n",
                  " Veritas VV Tag: ", $invalidDevice->veritasVvTag(), "\n";
        }

        croak "ERROR: OS VV WWN did not match Veritas VV WWN for some devices";
    }

}

=pod

=item mountedFileSystemsOfType(type)

Takes a filesystem type and returns a list of mounted filesystems
that match.

=cut

sub mountedFileSystemsOfType {
    my $fsType = shift;

    my $mountCmd = "/bin/mount";
    my @filesystems;

    return @filesystems unless $fsType;

    if (open(MOUNT, "$mountCmd |"))
    {
        while (my $line = <MOUNT>)
        {
            # /dev/vx/dsk/ora01dg/ora01data01 on /ora01data01 type vxfs
            if ($line =~ m| on (\/\S+).*type $fsType| )
            {
                push @filesystems, $1;
            }
        }
        close(MOUNT);
    }
    return @filesystems;
}

sub fstypeForMountPoint {
    my $fs = shift;
    my $type;

    my $mountCmd = "/bin/mount";
    my @filesystems;

    if (open(MOUNT, "$mountCmd |")) {
        while (my $line = <MOUNT>) {
            # /dev/vx/dsk/ora01dg/ora01data01 on /ora01data01 type vxfs
            if ($line =~ m|on $fs type ([^\s]+)| )
            {
                $type = $1;
                last;
            }
        }
        close(MOUNT);
    }
    return $type;
}

sub WWIdBehindDeviceMapper {
     my $objectType = shift;
     my @ret;
     my $cmd = "mount | grep $objectType";
     print "Command: '$cmd' \n" if $debug;
     my @output;

     unless (ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1)) {
        #croak("running '$cmd' failed:\n" . join("\n", @output));
        return @output; ## return empty array
     }
     #the output1 will contain string such as:
     #/dev/mapper/350002acb17f00913 on /hana/data/A01/mnt00001 type xfs (rw)
     #need to look into the first token and type ext3
     foreach my $line (@output) {
       chomp($line);
       print "$line\n" if $debug;
       my ($fullpath,$onKeyword,$mountpoint,$typeKeyword,$type,$mode) = split(/\s+/,$line);
       if ($type eq 'xfs') {
           #fullpath is /dev/mapper/350002acb17f00913
           print "fullpath=$fullpath\n" if ($debug >= 2);

           #from full path need to look into the last token to get the WWId
           my $WWId = (split(/\//,$fullpath))[-1];
           print "WWId=$WWId\n" if ($debug >= 2);

           push(@ret, $WWId);
       }
     }

     return(@ret);
}

sub devicesForWWId {
    my $WWId = shift;
    my @devices;
    my $device = ariba::Ops::FileSystem::Device->new($WWId);
    push @devices, $device if $device;
    return @devices;

}

=pod

=item renameDG($oldName, $newName)

    FUNCTION: Renames a DiskGroup

   ARGUMENTS: old DG name, new DG name

     RETURNS: 1 for success, croak's on failure

=cut

sub renameDG {
    my $oldName = shift;
    my $newName = shift;

    my @output;
    my $cmd;

    if( isDiskgroupImported( $oldName ) ) {
        deportDiskgroup( $oldName );
    }

    $cmd = "$vxdg -n $newName import $oldName";
    unless ( ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1 ) ){
        croak "Failed to rename '$oldName' to '$newName': " . join '; ', @output . "\n";
    }

    return 1;
}

=pod

=item renameDGandVols($oldName, $newName)

    FUNCTION: Renames a DiskGroup and it's associated Volumes

   ARGUMENTS: old DG name, new DG name

     RETURNS: 1 for success, croak's on failure

=cut

sub renameDGandVols{
    my $oldName = shift || croak __PACKAGE__ . "::renameDGandVols(): old DG name required!\n";
    my $newName = shift || croak __PACKAGE__ . "::renameDGandVols(): new DG name required!\n";

    croak "'$oldName' invalid format, must end in 'dg'!\n" unless ( $oldName =~ m/.*dg$/ );
    croak "'$newName' invalid format, must end in 'dg'!\n" unless ( $newName =~ m/.*dg$/ );

    my $oldVol = $oldName;
    $oldVol =~ s/dg$/a/;
    my $newVol = $newName;
    $newVol =~ s/dg$/a/;

    print "oldName: '$oldName'\tnewName: '$newName'\n";
    print "oldVol: '$oldVol'\tnewVol: '$newVol'\n";

    my @output;

   renameDG($oldName, $newName);

    my $cmd = "$vxedit -g $newName rename $oldVol $newVol";
    unless ( ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1 ) ){
        print "Three:\n";
        print Dumper \@output;
        croak "Failed to rename '$oldVol' to '$newVol': " . join( ';\n', @output ) . "\n";
    }

    $cmd = "$vxedit -g $newName rename $oldVol-01 $newVol-01";
    unless ( ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1 ) ){
        print "Four:\n";
        print Dumper \@output;
        croak "Failed to rename '$oldVol-01' to '$newVol-01': " . join( ';\n', @output ) . "\n";
    }

    return 1; ## Success
}

package ariba::Ops::FileSystem::Device;
use Carp;
use ariba::Ops::PersistantObject;
use ariba::Ops::Machine;
use base qw(ariba::Ops::PersistantObject);

sub new {
    my $class = shift;
    my $vxDevice = shift;

    my $machine = ariba::Ops::Machine->new();

    if ($machine->os() eq 'suse') {
        my $cmd = "/sbin/multipath -ll $vxDevice ";

        print "Command: '$cmd' \n" if $debug;
        my @output;

        #3PARdata_1041-0 (350002acb1be00913) dm-1 3PARdata,VV
        #size=256G features='1 queue_if_no_path' hwhandler='0' wp=rw
        #`-+- policy='round-robin 0' prio=1 status=active
        # |- 7:0:0:0 sdb 8:16 active ready running
        # `- 8:0:0:0 sdd 8:48 active ready running

        $main::quiet = 1;
        unless (ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1)) {
             croak("running '$cmd' failed:\n" . join("\n", @output));
        }

        my $error = 0;
        my $lun = -1;
        my @pathList;

        foreach my $line (@output) {
            chomp($line);
            #remove leading and trailing spaces
            $line =~ s/^\s+|\s+$//g;
            print "$line\n" if $debug;

            if ($line =~ /0:0/) {
                 my ($ident1,$token,$osDevicePath,$ident2,$subPathState) = split(/\s+/,$line);
                 print "token=$token\n" if ($debug >= 2);

                 my $thislun = (split(/:+/,$token))[-1];
                 my $thisController = (split(/:+/,$token))[0];
                 print "thislun=$thislun thisController=$thisController osDevicePath=$osDevicePath subPathState=$subPathState\n" if ($debug >= 2);

                 my $pathInfo = ariba::Ops::FileSystem::DeviceSubPaths->new($osDevicePath);
                 $pathInfo->setAttribute('controller', $thisController);
                 $pathInfo->setSubPathState($subPathState);
                 push(@pathList, $pathInfo);

                 if ($lun eq -1) {
                      $lun = $thislun;
                 } else {
                      if ($lun ne $thislun) {
                          print "LUN nmbers do not match for multipath ports\n" if $debug;
                          $error = 1;
                      } else {
                          print "LUN matches\n" if ($debug >= 2);
                      }
                 }
            }
        }

        if ($error) {
            print "Error in detrmining LUN\n" ;
            $lun = -1;
        } else {
            print "LUN=$lun !!!!!\n" if ($debug >= 2);
        }
        my $self = $class->SUPER::new($vxDevice);
        $self->setName($vxDevice);
        $self->setPaths( @pathList );
        $self->setLun($lun);
        my $vendor = '3PARdata';
        $self->setVendor($vendor);

        return $self;

    }

    my ($nodeName, $diskName, $device, $veritasVvWwn, $veritasVvTag, $format);
    my @pathList;

    my $command = "$vxdisk -v list $vxDevice";
    print "DEBUG running command: $command\n" if $debug;
    open(VXDISK, "$command |") or do {
        Carp::cluck "ERROR: Can't run '$command'\n";
        return;
    };
    while (my $line = <VXDISK>) {
        chomp $line; 
        # Redhat 4, Veritas 5.0 UDID looks like 50002AC000C90913
        if ($line =~ /^udid:.*\%5F5000([A-F0-9]+)$/) {
            $veritasVvWwn = $1;
            print "DEBUG $vxDevice VV WWN is $veritasVvWwn\n" if $debug;
        }
        # 3PAR 7200 device UDID's start with a zero (000200008539).  See output of 'vxdisk list <3par device ID> | grep udid'
        # To match scsi_info we need to prefix the UDID with '0000'.  See the LUN field of 'scsi_info /dev/sdX'
        elsif ($line =~ /^udid:.*\%5F([A-F0-9]+)$/) {
            $veritasVvWwn = $1;
            print "DEBUG $vxDevice VV WWN is $veritasVvWwn\n" if $debug;
        # Redhat 5, Veritas 5.1 UDID looks like 2AC000C90913. To be backwards compatible we will prefix the UDID with '5000'.
        }elsif ($line =~ /^\s*tag.*\%5F([A-F0-9]+)$/ || $line =~ /^\s*tag.*\%5F5000([A-F0-9]+)$/ ) {
            $veritasVvTag = $1;
            print "DEBUG $vxDevice VV Tag is $veritasVvTag\n" if $debug;
        # Redhat 5, Veritas 5.1 UDID looks like 2AC000C90913. To be backwards compatible we will prefix the UDID with '5000'.
        } elsif ($line =~ /^Device:\s+(\w+)/) {
            $nodeName = $1;
        } elsif ($line =~ /^info:.*format=([^, ]+),/) {
            $format = $1;
        } elsif ($line =~ /^disk:.*name=(\w+)/) {
            $diskName = $1;
        } elsif ($line =~ /^(sd[a-z]+)\s+.*state=(enabled|disabled)/) {
            my $osDevicePath = $1;
            my $subPathState = $2;

            my $pathInfo = ariba::Ops::FileSystem::DeviceSubPaths->new($osDevicePath);
            $pathInfo->setSubPathState($subPathState);

            # get the target hba WWN (the 3par in this case)
            push(@pathList, $pathInfo);

            next;
        }
    }
    close(VXDISK);

    unless ($nodeName and $veritasVvWwn and $format) {
        Carp::croak "Can't nodeName or WWN information from vxdisk $vxDevice" if $format;
        return;
    }

    $veritasVvWwn =~ s/^0+//g; ## Removing leading zero, if any
    $veritasVvTag =~ s/^0+//g; ## Removing leading zero, if any
    my $self = $class->SUPER::new($nodeName);
    $self->setName($nodeName);
    $self->setDiskName($diskName);
    $self->setFormat($format);
    $self->setVeritasVvWwn( lc($veritasVvWwn) );
    $self->setVeritasVvTag( lc($veritasVvTag) );
    $self->setPaths( @pathList );
    $self->setStorageProperties();

    return $self;

}

sub dir {
    my $class = shift;
    return undef;
}

sub validAccessorMethods {
        my $class = shift;

    my $methodsRef = $class->SUPER::validAccessorMethods();

        $methodsRef->{'name'} = undef;
    $methodsRef->{'format'} = undef;
        $methodsRef->{'vendor'} = undef;
        $methodsRef->{'lun'} = undef;
    $methodsRef->{'osVvWwn'} = undef;
    $methodsRef->{'osDevName'} = undef;
    $methodsRef->{'veritasVvWwn'} = undef;
    $methodsRef->{'veritasVvTag'} = undef;
    $methodsRef->{'veritasDiskGroup'} = undef;
        $methodsRef->{'veritasVolume'} = undef;
    $methodsRef->{'paths'} = undef;
    $methodsRef->{'inserv'} = undef;
    $methodsRef->{'error'} = undef;
    $methodsRef->{'diskGroup'} = undef;
    $methodsRef->{'diskName'} = undef;

        return $methodsRef;
}

=pod

=item isEMC()

This is an instance method on one of the device objects, it return true
if the device is supported by EMC as the backend storage.

=cut

sub isEMC {
    my $self = shift;

    my $vendor = $self->vendor();

    if ($vendor eq "EMC") {
        return 1;
    }

    return 0;
}

=pod

=item is3Par()

This is an instance method on one of the device objects, it return true
if the device is supported by 3Par as the backend storage.

=cut

sub is3Par {
    my $self = shift;

    my $vendor = $self->vendor();

    if ($vendor eq "3PARdata") {
        return 1;
    }

    return 0;
}

sub hostTargetWWN {
    my $self = shift;

    return $self->paths() && ($self->paths())[0]->targetWWN();
}

sub inservForDevice {
    my $self = shift;
    my $inservsRef = shift;

    return $self->inserv() if $self->inserv();

    if ( my $hostTargetWWN = $self->hostTargetWWN() ) {

        for my $inservNM (@$inservsRef) {
            my @inservWWNs = $inservNM->machine->wwns();
            if (grep(lc($_) eq $hostTargetWWN, @inservWWNs)) {
                $self->setInserv($inservNM);
                return $inservNM;
            }
        }
    }

    return undef;
}

sub setStorageProperties {
    my $self = shift;

    #[root@quail ~]$ scsi_info /dev/sda
    #SCSI_ID="0,0,0,1":VENDOR="3PARdata":MODEL="VV":FW_REV="0000":SN="01A8031F":WWN="6e632e20416c6c20":LUN="50002ac001a8031f-0000000000000000":
    #[root@quail ~]$ scsi_info /dev/sdb
    #SCSI_ID="1,0,0,0":VENDOR="EMC":MODEL="SYMMETRIX":FW_REV="5567":SN="701202500270":WWN="0000000000000000":LUN="0001847012025359-4d35303000000000":

    my $deviceName = $self->name();

    my $osDeviceName = $self->getEnabledDevice();

    open(SCSIINFO, "$scsi_info /dev/$osDeviceName |") or do {
        $self->setError("Can't run $scsi_info /dev/$osDeviceName: $!");
        return;

    };
    my $line = <SCSIINFO>;
    close(SCSIINFO);

    $line =~ s/"//g;

    if ( $line =~ /(SCSI_ID=.*):(VENDOR=.*?):.*LUN=(\w+)-(\w+)/ ) {
        my $path = $1;
        my $vendor = $2;
        my $osVvWwnPart1 = $3;
        my $osVvWwnPart2 = $4;

        my $lunId;
        if ($path =~ s|.*,(\d+)$||) {
            $lunId = $1;
        }

        $vendor =~ s|VENDOR=||;

        my $osVvWwn;

        # Some devices contain the WWN in the first part of the lun while others use the second.
        # Newer 3PAR devices contain the WWN in the second part of the lun field '0000005500008539'
        # root@mastic ~ $ scsi_info /dev/sdd
        # SCSI_ID="3,0,0,1":VENDOR="3PARdata":MODEL="VV":FW_REV="3122":WWN="323030312d323031":LUN="60002ac000000000-0000005500008539"
        #
        # Older 3PAR devices contain the WWN in the first part of the lun field '50002acb07f10913'
        # root@oak ~ $ scsi_info /dev/sdn
        # SCSI_ID="1,0,0,87":VENDOR="3PARdata":MODEL="VV":FW_REV="3112":WWN="323030312d323031":LUN="50002acb07f10913-5656202020202020"
        # 
        # The first part of the lun field always starts with 6000 for newer devices.  Use that to decide which part of the lun field we want
        #
        if ($osVvWwnPart1 =~ /^6000/) {
            $osVvWwn = $osVvWwnPart2;
        } else {
            $osVvWwn = $osVvWwnPart1;
        }
        $osVvWwn =~ s/^5000//g; ##Removing leading 5000
        $osVvWwn =~ s/^0+//g;   ## Removing leading zero, if any

        if($deviceName =~ /^emc/) {
            #
            # EMC devices need to get the WWID this way
            #
            my $command = "/usr/symcli/bin/syminq -sym -nocap /dev/$osDeviceName";
            open(SCSIINFO, "$command |") or do {
                $self->setError("Can't run $command: $!");
                return;

            };

            while(my $line = <SCSIINFO>) {
                chomp $line;
                if($line =~ m|^/dev/sd.*\s([0-9A-F]+)\s*$|) {
                    $osVvWwn = $1;
                }
            }
            
            close(SCSIINFO);
        }
    
        $self->setVendor($vendor);
        $self->setLun($lunId);
        $self->setOsVvWwn( lc($osVvWwn) );
    }

    return 1;
}

sub getEnabledDevice {
    my $self = shift;

    foreach my $p ($self->paths()) {
        if ($p->subPathState() eq 'enabled') {
            return $p->instance();
        }
    }
    return "None of the path is enabled";
}


1;

package ariba::Ops::FileSystem::DeviceSubPaths;
use Carp;
use ariba::Ops::PersistantObject;
use base qw(ariba::Ops::PersistantObject);

sub dir {
    my $class = shift;
    return undef;
}

sub new {
    my $class = shift;
    my $instance = shift;
    my $state = shift;

    my $self = $class->SUPER::new($instance);
    $self->setName($instance);
    $self->setController();
    $self->setTargetWWN();
    $self->setSubPathState($state);

    return $self;

}

sub setSubPathState {
    my $self = shift;
    my $state = shift;

    $self->SUPER::setSubPathState($state);

    return 1;
}

sub setController {
    my $self = shift;

    my $osDevice = $self->name();
    my $machine = ariba::Ops::Machine->new();
    my $controller;
    if($machine->osVersion() =~ /6\.\d+/){
        ($controller) = readlink("/sys/block/$osDevice") =~ /\/host(\d+)\//;
    }
    else {
        ($controller) = readlink("/sys/block/$osDevice/device") =~ /\/host(\d+)\//;
    }

    $self->SUPER::setController($controller);

    return 1;
}

sub setTargetWWN {
    my $self = shift;

    my $controller = $self->controller();
    my $wwn;

    my $machine = ariba::Ops::Machine->new();

    if ($machine->os() eq 'suse') {
        my $osDevice = $self->name();
        my ($target) = readlink("/sys/block/${osDevice}") =~ /\/(target[^\/]+)\//;

        open(TARGET_PORT, "/sys/class/fc_transport/${target}/port_name") or return 0;
        my $targetInfo = <TARGET_PORT>;
        chomp $targetInfo;
        close(TARGET_PORT);

        $targetInfo =~ s/^0x//; # strip leading hex indicator
        $wwn = $targetInfo;

    } elsif ( -f "/proc/scsi/qla2xxx/${controller}" ) {
        my $driverInfoFile = "/proc/scsi/qla2xxx/$controller";
        my $DRIVER_INFO;
    
        open($DRIVER_INFO, $driverInfoFile) or return 0;
        my ($targetInfo) = grep($_ =~ /scsi-qla\d+-target-0.*/, <$DRIVER_INFO>);
        close $DRIVER_INFO;
        ($wwn) = $targetInfo =~ /=(.*);/;
    } else {
        # Assume Redhat 5 where kernel information is stored in different places.
        my $osDevice = $self->name();
        my $machine = ariba::Ops::Machine->new();
        my $target;
        if($machine->osVersion() =~ /6\.\d+/){
            ($target) = readlink("/sys/block/$osDevice") =~ /\/(target[^\/]+)\//;
        }
       else {
            ($target) = readlink("/sys/block/${osDevice}/device") =~ /\/(target[^\/]+)\//;
        }


        open(TARGET_PORT, "/sys/class/fc_transport/${target}/port_name") or return 0;
        my $targetInfo = <TARGET_PORT>;
        chomp $targetInfo;
        close(TARGET_PORT);

        $targetInfo =~ s/^0x//; # strip leading hex indicator
        $wwn = $targetInfo;
    }

    $wwn = lc($wwn);

    $self->SUPER::setTargetWWN($wwn);

    return 1;

}

sub validAccessorMethods {
    my $class = shift;

    my $methodsRef = $class->SUPER::validAccessorMethods();

    $methodsRef->{'name'} = undef;
    $methodsRef->{'controller'} = undef;
    $methodsRef->{'targetWWN'} = undef;
    $methodsRef->{'subPathState'} = undef;

    return $methodsRef;
}


1;

__END__

=pod

=back

=head1 AUTHOR

Manish Dubey <mdubey@ariba.com>

=cut
