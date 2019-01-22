package ariba::Ops::NetworkDevice::enginuity;

use strict;

use Date::Parse;
use Expect 1.11;
use ariba::Ops::NetworkDevice::BaseDevice;
use ariba::Ops::Startup::Common;
use ariba::Ops::Inserv::VolumeLun;

use base qw(ariba::Ops::NetworkDevice::BaseDevice);

sub cmdShowPolicyForVv {
    my $self = shift;
    my $name = shift;

    # no-op for EMC
    my $dummy = ariba::Ops::NetworkDevice::enginuity::Container->new("policy-$name");
    $dummy->setPolicies("stale_ss,no_stale_ss");
    my @ret = ($dummy);
    return(@ret);
}

sub cmdSetPolicyForVv {
    # no-op for EMC
    my @ret;
    return(@ret);
}

sub virtualVolumesByName {
    my $name = shift;
    my @arr;

    my $ret = ariba::Ops::NetworkDevice::enginuity::Container->new("vv-$name");
    $ret->setName($name);

    push(@arr, $ret);

    return(@arr);
}

sub volumeTagsForDevices {
    my $self = shift;
    my @devices = (@_);
    my @ret;

    foreach my $device (@devices) {
        my $vv = $device->name();
        $vv =~ s/^emc\d+_//;

        my $dsk = ariba::Ops::NetworkDevice::enginuity::Container->new("vlun-$vv");
        $dsk->setName($vv);

        push(@ret, $dsk);
    }

    return(@ret);
}

sub virtualVolumesForLunsOnHost {
    my @ret = ();
    return @ret;
}

sub symSid {
    my $self = shift;
    my $sid = $self->machine()->serialNumber() % 1000;

    return($sid);
}

sub dgAndDeviceForVV {
    my $self = shift;
    my $vv = shift;
    my $symSid = $self->symSid();

    my ($dg, $device);

    open(SYMDEV, "/usr/symcli/bin/symdev -sid $symSid show $vv |");
    while(my $line = <SYMDEV>) {

        if($line =~ /^\s*Device Group Name\s*:\s*([^\s]+)/) {
            $dg = $1;
        }
        if($line =~ /^\s*Device Logical Name\s*:\s*([^\s]+)/) {
            $device = $1;
        }

    }
    
    return($dg, $device);
}

sub _runCommandAndCheckResult {
    my $self = shift;
    my $command = shift;
    my $regex = shift;
    my $progress = shift;

    my $storedQuiet = $main::quiet;
    $main::quiet = 1;

    print "Run: $command\n" if(-t STDIN && !$progress);
    my @output;
    my $ret = ariba::rc::Utils::executeLocalCommand( $command, 0, \@output, undef, 1 );

    my $sawSuccess = 0;
    my $progressFeedback;
    foreach my $line (@output) {
        $sawSuccess = 1 if($line =~ /$regex/);
        if($progress && $line =~ /$progress/) {
            $progressFeedback = $1;
        }
    }

    if($progress && !defined($progressFeedback) && !$sawSuccess) {
        $main::quiet = $storedQuiet;
        return(-1);
    }

    if(defined($progressFeedback) && -t STDIN) {
        print "\rCopy progress: $progressFeedback\%";
    }

    unless($sawSuccess) {
        $main::quiet = $storedQuiet;
        return(0);
    }


    $main::quiet = $storedQuiet;
    return(1);
}

sub makePhysicalCopyForVirtualVolumes {
    my $self = shift;
    my $vvRef = shift;
    my $bcvId = shift;
    my $incremental = shift; # for now we ignore this

    $bcvId = 1; # for now this is all we support

    my $vv = shift(@$vvRef);

    my $symSid = $self->symSid();
    my ( $dg, $device ) = $self->dgAndDeviceForVV($vv);
    my $target = "CLONE-" . $bcvId . "-" . $device;

    my $command;
    my $regex;

    unless($incremental) {
        $command = "/usr/symcli/bin/symclone -sid $symSid -g $dg terminate $device sym ld $target -noprompt -force";
        $regex = '(?:A\s+Copy\s+session\s+has\s+not\s+been\s+created\s+for\s+the\s+specified\s+device|operation\s+successfully\s+executed\s+for\s+device)';
        unless( $self->_runCommandAndCheckResult($command, $regex) ) {
            $self->setError("Failed to terminate target");
            return(0);
        }

        $command = "/usr/symcli/bin/symclone -sid $symSid -g $dg create $device sym ld $target -noprompt";
        $regex = 'operation\s+successfully\s+executed\s+for\s+device';
        unless( $self->_runCommandAndCheckResult($command, $regex) ) {
            $self->setError("Failed to create target");
            return(0);
        }
    }

    my $action = "activate";
    $action = "establish" if($incremental);

    $command = "/usr/symcli/bin/symclone -sid $symSid -g $dg $action $device sym ld $target -noprompt";
    $regex = 'operation\s+successfully\s+(?:initiated|executed)\s+for\s+device';
    unless( $self->_runCommandAndCheckResult($command, $regex) ) {
        $self->setError("Failed to $action target");
        return(0);
    }

    if(-t STDIN) {
        print "\n";
        $| = 1;
    }

    $command = "/usr/symcli/bin/symclone -g $dg query -multi";
    $regex = 'CLONE-' . $bcvId . '.*Copied\s+100';
    my $progressRegex = 'CLONE-' . $bcvId . '.*CopyInProg\s+(\d+)';
    my $retVal = 0;
    while( ! $retVal ) {
        $retVal = $self->_runCommandAndCheckResult($command, $regex, $progressRegex);
        sleep(10) if($retVal);
    }

    if(-t STDIN) {
        print "\n\n";
    }

    if($retVal < 0) {
        $self->setError("Failed to finish physical copy");
        return(0);
    }

    return(1);

}

sub makeSnapCopyForVirtualVolumes {
    my $self = shift;
    my $vvRef = shift;
    my $bcvId = shift;
    my $snapCopy = shift;  # unused?

    $bcvId=3 if($bcvId < 0 || $bcvId > 2);

    my $vv = shift(@$vvRef);

    my $symSid = $self->symSid();
    my ( $dg, $device ) = $self->dgAndDeviceForVV($vv);
    my $target = "VPSNAP-" . $bcvId . "-" . $device;

    my $command = "/usr/symcli/bin/symclone -sid $symSid -g $dg terminate $device sym ld $target -noprompt -force";
    my $regex = '(?:A\s+Copy\s+session\s+has\s+not\s+been\s+created\s+for\s+the\s+specified\s+device|operation\s+successfully\s+executed\s+for\s+device)';
    unless( $self->_runCommandAndCheckResult($command, $regex) ) {
        $self->setError("Failed to terminate snapshot");
        return(0);
    }


    $command = "/usr/symcli/bin/symclone -sid $symSid -g $dg create -vse $device sym ld $target -noprompt";
    $regex = 'operation\s+successfully\s+executed\s+for\s+device';
    unless( $self->_runCommandAndCheckResult($command, $regex) ) {
        $self->setError("Failed to create snapshot");
        return(0);
    }

    $command = "/usr/symcli/bin/symclone -sid $symSid -g $dg activate $device sym ld $target -noprompt";
    unless( $self->_runCommandAndCheckResult($command, $regex) ) {
        $self->setError("Failed to activate snapshot");
        return(0);
    }

    return(1);
}

sub symcfg {
    my $self = shift;
    my $symSid = $self->symSid();

    my $storedQuiet = $main::quiet;
    $main::quiet = 1;

    my $command = "/usr/symcli/bin/symcfg -sid $symSid list -v";
    my @output;
    my $retCode = ariba::rc::Utils::executeLocalCommand( $command, 0, \@output, undef, 1 );

    $main::quiet = $storedQuiet;

    unless( $retCode ) {
        print "FAIL\n";
        $self->setError("Failed to run $command");
        return(0);
    }

    my $ret = {};

    foreach my $line (@output) {
        chomp($line);
        if($line =~ /:/) {
            my ($key, $val) = split(/\s*:\s*/, $line, 2);
            $key =~ s/^\s+//;
            $val =~ s/\s+$//;
            $ret->{$key} = $val;
        }
    }

    return($ret);
}

sub connect {}
sub disconnect {}

package ariba::Ops::NetworkDevice::enginuity::Container;
use base qw(ariba::Ops::PersistantObject);
sub dir { return(undef) }

1;
