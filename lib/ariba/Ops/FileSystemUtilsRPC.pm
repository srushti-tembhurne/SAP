package ariba::Ops::FileSystemUtilsRPC;
use base qw(ariba::Ops::PersistantObject);

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/FileSystemUtilsRPC.pm#23 $

use strict;
use File::Path;
use File::Basename;
use Carp;

use ariba::rc::Utils;
use ariba::rc::Passwords;
use ariba::rc::CipherStore;

my $EXECUTE_COMMAND_ATTEMPTS = 15;

my $BACKING_STORE = undef;

sub dir {
    my $class = shift;

    return $BACKING_STORE;
}

sub setDir {
    my $class = shift;
    my $dir = shift;

    $BACKING_STORE = $dir;
}

sub objectLoadMap {
        my $class = shift;

        my %map = (
                'vvList', '@SCALAR',
                'vxList', '@SCALAR',
        );

        return \%map;
}

sub fileSystemDeviceDetailsCommand {
    return("/usr/local/ariba/bin/filesystem-device-details");
}

sub newListOfVVInfoFromSID {
    my $class = shift;
    my $sid = shift;
    my $host = shift;
    my $service = shift;
    my $isBackup = shift;
    my $includeLogVolumes = shift;
    my $nullOk = shift;

    my $filesystem_device_details = fileSystemDeviceDetailsCommand();

    my $command = "sudo $filesystem_device_details -x -s $sid";

    return(
        $class->newListOfVVInfoWithCommand(
            $command, $host, $service, $isBackup, $includeLogVolumes, 0, $nullOk
        )
    );

}

sub newListOfVVInfoFromFiles {
    my $class = shift;
    my $fileList = shift;
    my $host = shift;;
    my $service = shift;
    my $isBackup = shift;

    my @mountPoints = mountPointsForFileList($fileList, $host, $service);
    my $filesystem_device_details = fileSystemDeviceDetailsCommand();
    my $mountFS = " " . join(" ", @mountPoints) if @mountPoints;
    my $command = "sudo su - -c \"$filesystem_device_details -x $mountFS\"";

    return(
        $class->newListOfVVInfoWithCommand(
            $command, $host, $service, $isBackup
        )
    );
}


# Verify the format of the info from filesystem-device-details
sub checkFilesystemInfoFormat {
    my $line = shift;
    my $noMountPoints = shift || 0;

    return 0 if $line =~ /uninitialized value/ || $line =~ / line \d+/ || $line =~ /Warning:/;

    # Add a dummy mountpoint to the line, so the rest of the parse check can be run
    if($noMountPoints) {
        $line = "/foobar:" . $line;
    }

    my @fsList = split('#', $line);
    foreach my $fs (@fsList) {
        my ($mountPoint, $vvInfo) = split(':', $fs);
        return 0 if $mountPoint !~ m|^/|o;
        my @vvList = split(' ', $vvInfo);
        foreach my $vv (@vvList) {
            my @data = split(',', $vv);
            # Assumption that the 3par device has "inserv" in the name
            # This is currently true, but may need to be revised if the convention changes
            if($data[-1] !~ m/inserv/o) {
                return 0;
            }
        }
    }
    return 1;
}

sub parseFilesystemInfo {
    my @output = @_;

    my %result;
    my $fs;
    my $info = {};
    foreach my $line (@output) {
        if($line =~ m/\s*Connection\s*to.*?closed/i) {
         next;
        }

        if($line =~ m|^#(.*):$|) {
            $fs = $1;
            $result{$fs} = [];
            next;
        } elsif(!defined($fs)) {
            # leading blank lines are fine
            next if $line =~ m/^\s*$/;
            # unexpected output
            return undef;
        }

        if($line =~ m/^----$/) {
            push(@{$result{$fs}}, $info);
            $info = {};
            next;
        }

        if($line =~ m/^(\w+): (\S+)$/) {
            $info->{$1} = $2;
            next;
        }

        # unexpected output
        return undef;
    }

    if(keys(%{$info})) {
        push(@{$result{$fs}}, $info);
    }

    return \%result;
}

sub newListOfVVInfoWithCommand {
    my $class = shift;
    my $command = shift;
    my $host = shift;;
    my $service = shift;
    my $isBackup = shift;
    my $includeLogVolumes = shift || 0;
    my $retry = shift || 0;
    my $nullOk = shift;

    my @cmdOutput =  _executeRemoteFSCommand($command, $host, $service, $nullOk);

    my @list;
    my ($remoteHostname) = _executeRemoteFSCommand("hostname -f", $host, $service);

    unless ($remoteHostname) {
        Carp::croak("Could not get hostname from remote host at " . $host);
        return;
    }

    #
    # if the format does not match, retry
    #
    my $infoRef = parseFilesystemInfo(@cmdOutput);
    if( !$infoRef && !$nullOk ) {
        if($retry < 5) {
            print STDERR "Failed to run filesystem-device-details on $host.. retrying.\n";
            sleep 1;
            return( $class->newListOfVVInfoWithCommand( $command, $host, $service, $isBackup, $includeLogVolumes, $retry+1 ) );
        }
        die("Cannot get filesystem details for $service on $host.");
    }

    unless($infoRef) {
        my @empty = ();
        return(undef, @empty);
    }

    foreach my $fs (keys %$infoRef) {
        #
        # our SID logic gets the log volumes too... 
        #
        next if(!$includeLogVolumes && $fs =~ /ora.+log\d+/);
        next if(!$includeLogVolumes && $fs =~ m|hana/log/|);

        my $instance = $host . $fs;
        $instance =~ s#/#_#;
        $instance = "DS-" . $instance if $isBackup;

        my $fsVVInfo = $class->SUPER::new($instance);

        $fsVVInfo->setFs($fs);
        $fsVVInfo->setHost($remoteHostname);

        my $vvRef = $infoRef->{$fs};

        my @vvList;
        my $dg;
        my $diskName;
        for my $fsInfo (@$vvRef) {
            my $vv = $fsInfo->{"VV"};
            $dg = $fsInfo->{"DiskGroup"};
            $diskName = $fsInfo->{"DiskName"};
            my $inservHostname = $fsInfo->{"Inserv"};
            push (@vvList, $vv);
            $fsVVInfo->setInserv($inservHostname) unless $fsVVInfo->inserv();
        }
        $fsVVInfo->setVvList(@vvList);
        $fsVVInfo->setDiskGroup($dg);
        $fsVVInfo->setDiskName($diskName);

        push (@list, $fsVVInfo);
    }

    return $infoRef, @list;
}

sub mountPointsForFileList {
    my $dbFilesRef = shift;
    my $host = shift;;
    my $service = shift;

    my %uniqueDbFileDirs;
    my $mountPoints;
    for my $dbFile (@$dbFilesRef) {
        my $dbFileDir = dirname($dbFile);
        $mountPoints .= "$dbFileDir " unless $uniqueDbFileDirs{$dbFileDir};
        $uniqueDbFileDirs{$dbFileDir} = 1;
    }

    my $command = "df -P $mountPoints";
    my @cmdOutput = _executeRemoteFSCommand($command, $host, $service);

    my %uniqueMountPoints;
    for my $line (@cmdOutput) {
        if ( $line =~ /\s+(\/[^\/]+)$/ ) {
            $uniqueMountPoints{$1} = 1;
        }
    }

    unless ( %uniqueMountPoints ) {
        Carp::croak("Unable to parse output from \"$command\": " . join("\n", @cmdOutput));
    }

    return keys(%uniqueMountPoints);
}

sub vvsForMountPoints {
    my $mountPointsRef = shift;
    my $host = shift;;
    my $service = shift;
    my $retry = shift || 0;

    my $filesystem_device_details = fileSystemDeviceDetailsCommand();
    my $mountFS = " " . join(" ", @$mountPointsRef) if $mountPointsRef;
    my $command = "sudo su - -c \"$filesystem_device_details -w $mountFS\"";

    my @cmdOutput = _executeRemoteFSCommand($command, $host, $service);


    # #/ora01data01:0096-0,50002ac00255031f 0096-1,50002ac00256031f 0096-2,50002ac00274031f 0096-3,50002ac00275031f#/ora01log01:0098-0,50002ac00258031f#/ora01log02:0097-0,50002ac00257031f
    # Find the list from the returned array and strip off the first # for the subsequent split
    my $cmdOutputString =  (grep(/^#/, @cmdOutput))[0];
    $cmdOutputString =~ s/^#//;

    #
    # if the format does not match, retry
    #
    if( !checkFilesystemInfoFormat($cmdOutputString) ) {
        if($retry < 5) {
            print STDERR "Failed to run filesystem-device-details on $host.. retrying.\n";
            sleep 1;
            return( vvsForMountPoints( $mountPointsRef, $host, $service, $retry+1));

        }
        die("Cannot get filesystem details for $service on $host.");
    }

    # split the command output into an array of filesystems
    my @fsList = split('#', $cmdOutputString);
    unless ( scalar(@fsList) ) {
        Carp::croak("Unable to parse output from \"$command\": " . join("\n", @cmdOutput));
    }

    return @fsList;
}

sub fileSystemsForSidAndHost {
    my $sid = shift;
    my $host = shift;
    my $service = shift;
    $service = ariba::rc::Passwords::service() unless($service);

    my $filesystem_device_details = fileSystemDeviceDetailsCommand();
    my $command = "sudo $filesystem_device_details -x -s $sid";

    my $enter = $main::quiet;
    $main::quiet = 1;
    my @cmdOutput = _executeRemoteFSCommand($command, $host, $service);
    $main::quiet = $enter;

    my @filesystems;


    foreach my $line (@cmdOutput) {
        if($line =~ /^#([^:]+):$/) {
            my $fs = $1;
            push(@filesystems, $fs);
        }
    }

    return(@filesystems);
}

sub vvsForFailover {
    my $host = shift;
    my $service = shift;
    my $retry = shift || 0;

    my $filesystem_device_details = fileSystemDeviceDetailsCommand();
    my $command = "sudo su - -c \"$filesystem_device_details -v -w\"";
    my @cmdOutput = _executeRemoteFSCommand($command, $host, $service);

    @cmdOutput = grep(/,/, @cmdOutput);
    my @vvList = split(/ /, $cmdOutput[0]);

    #
    # if the format does not match, retry
    # pass an argument to the checking function because the format is slightly different
    # but not different enough to justify a separate function
    #
    if( !checkFilesystemInfoFormat($cmdOutput[0], 1) ) {
        if($retry < 5) {
            print STDERR "Failed to run filesystem-device-details on $host.. retrying.\n";
            sleep 1;
            return( vvsForFailover( $host, $service, $retry+1));
        }
        die("Cannot get filesystem details for $service on $host.");
    }

    unless ( scalar @vvList) {
        Carp::croak("Unable to parse output from \"$command\":\n" . join("\n", @cmdOutput));
    }

    return @vvList;
}

sub deleteAdmOwnedHanaFile {
        my $class = shift;
        my $host = shift;
        my $service = shift;
        my $hanaadm = shift;
        my $filename = shift;

        my $command = "sudo -u $hanaadm rm -rf $filename";

        _executeRemoteFSCommand($command, $host, $service, undef, 1);

        return 1;
}

sub _executeRemoteFSCommand {
    my $command = shift;
    my $host = shift;
    my $service = shift;
    my $nullOk = shift;
    my $noOutputExpected = shift;

    my $username = "svc" . $service;
    my $password;

    # Try and get the password
    if (ariba::rc::Passwords::initialized()) {
        $password = ariba::rc::Passwords::lookup($username);
    } else {
        my $cipherStore = ariba::rc::CipherStore->new($service);
        $password = $cipherStore->valueForName($username);
    }

    unless ($password) {
        Carp::croak("Could not get password for '$username'");
    }

    $command = "ssh -l $username $host '$command'";

    my @output;
    if ($noOutputExpected) {
        unless ( ariba::rc::Utils::executeRemoteCommand($command, $password, 0, undef, undef, \@output) ) {
                my $errorMessage = join(';', @output);
                chop($errorMessage);
                Carp::croak("'$errorMessage'");
        }
        return @output;
    }

    my $attempt = 0;
    while (!grep(/\S/, @output) && $attempt++ < $EXECUTE_COMMAND_ATTEMPTS) {
        unless ( ariba::rc::Utils::executeRemoteCommand($command, $password, 0, undef, undef, \@output) ) {
            my $errorMessage = join(';', @output);
            chop($errorMessage);
            unless($nullOk) {
                Carp::croak("'$errorMessage'");
            }
        }
    }
    unless (scalar(@output)) {
        Carp::croak("'$command' returned no output after $EXECUTE_COMMAND_ATTEMPTS attempts.");
    }

    # weed out blank lines
    @output = grep($_ !~ /^\s*$/, @output);

    return @output;
}

return 1;

