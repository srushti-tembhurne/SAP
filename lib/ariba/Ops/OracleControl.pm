package ariba::Ops::OracleControl;
use strict;
use base qw(ariba::Ops::DatabaseControl);


use FindBin;
use ariba::rc::InstalledProduct;
use ariba::Ops::FileSystemUtilsRPC;
use ariba::Ops::OracleClient;
use ariba::Ops::Machine;
use ariba::Ops::NetworkDeviceManager;

sub vlunsForVirtualVolumeAndFS {
	my $self = shift;
	my $vv = shift;
	my $fs = shift;
	my $nm = shift;

	my $fsName = $fs->fs();

	my $key = "vlunsFor${vv}${fsName}";

	my @ref = $self->attribute($key);
	return(@ref) if(@ref && $ref[0]);

	unless($nm) {
		my $inserv = $fs->inserv();
		my $m = ariba::Ops::Machine->new($inserv);
		$nm = ariba::Ops::NetworkDeviceManager->newFromMachine($m);
	}

	my @vluns = $nm->vLunsforVirtualVolumesOfFilesystem({
		'vvlist' => [ $vv ], 'fs' => $fs->fs()
	});

	$self->setAttribute($key, @vluns);
	return(@vluns);
}

sub diskToLunMapForHost {
	my $self = shift;
	my $nm = shift;
	my $targetHost = shift;
	my %ret;

	foreach my $fs ($self->dbFsInfo()) {
		unless($nm) {
			my $inserv = $fs->inserv();
			my $m = ariba::Ops::Machine->new($inserv);
			$nm = ariba::Ops::NetworkDeviceManager->newFromMachine($m);
		}

		next if($targetHost && $fs->host() ne $targetHost);

		my @vvList = $fs->vvList();
		foreach my $vv (@vvList) {
			my @vluns = $self->vlunsForVirtualVolumeAndFS($vv, $fs, $nm);
			foreach my $vlun (@vluns) {
				foreach my $export ($vlun->exports()) {
					my $lun = $export->lun();
					my $exhost = $export->host();
					if($exhost eq $fs->host()) {
						$ret{$lun} = $fs->diskName();
					}
				}
			}
		}
	}

	return(\%ret);
}

sub activeLunsOnHost {
	my $self = shift;
	my $nm = shift;
	my @luns;

	foreach my $fs ($self->dbFsInfo()) {
		unless($nm) {
			my $inserv = $fs->inserv();
			my $m = ariba::Ops::Machine->new($inserv);
			$nm = ariba::Ops::NetworkDeviceManager->newFromMachine($m);
		}

		my @vvList = $fs->vvList();
		foreach my $vv (@vvList) {
			my @vluns = $self->vlunsForVirtualVolumeAndFS($vv, $fs, $nm);
			foreach my $vlun (@vluns) {
				foreach my $export ($vlun->exports()) {
					my $lun = $export->lun();
					my $exhost = $export->host();
					if($exhost eq $fs->host()) {
						push(@luns, $lun);
					}
				}
			}
		}
	}

	return(@luns);
}


# These empty calls are to keep the hana and oracle interfaces the same
#

#############################
# if these aren't called anywhere, then delete 'em
sub slaveNodes {
	my @empty=();
	return(@empty);
}

sub standbyNodes {
	my @empty=();
	return(@empty);
}

sub clusterRole {
	return undef;
}

sub peerType {
	return 'oracle';
}
# down to here
#############################

sub objectLoadMap {
        my $class = shift;

        my %map = (
        	'dbFsInfo', '@ariba::Ops::FileSystemUtilsRPC',
        );

        return \%map;
}

sub newFromDbc {
	my $class = shift;
	my $dbc = shift;
	my $isBackup = shift;

	my $instance = $dbc->host() . "_" . $dbc->sid();
	$instance = "DS-" . $instance if $isBackup;

	my $self = $class->SUPER::new($instance);

	$self->setIsBackup(1) if $isBackup;

	$self->setSid($dbc->sid());
	$self->setService($dbc->product->service());
	$self->setHost($dbc->host());
	$self->setUser("mon" . $dbc->product->service());
	$self->setPhysicalReplication(1) if $dbc->isPhysicalReplication();
	$self->setPhysicalActiveRealtimeReplication(1) if $dbc->isPhysicalActiveRealtimeReplication();

	$self->setIsSecondary(1) if $dbc->isDR();

	return $self;
}

sub setDbFsInfo {
	my $self = shift;
	my $dbc = shift;
	my $includeLogVolumes = shift;
	my $logger = $self->logger();
	$logger->debug("Gathering filesystem details on " . $self->host() . " for " . $dbc->sid());
	my ($dbFsRef, @fileSystemInfoForDbFiles) = ariba::Ops::FileSystemUtilsRPC->newListOfVVInfoFromSID($dbc->sid(), $self->host(), $self->service(), $self->isBackup(), $includeLogVolumes);
	return unless (scalar @fileSystemInfoForDbFiles);

	$self->SUPER::setAttribute('dbFsInfo', @fileSystemInfoForDbFiles);
    $self->SUPER::setAttribute('dbFsRef', $dbFsRef);

	return 1;
}

sub oracleDbFiles {
	my $self = shift;

	my @dataFiles;

	if ($self->physicalReplication() && $self->isSecondary()) {
		@dataFiles = $self->executeSql(q/SELECT NAME FROM V$DATAFILE/, "testingoverride");
	} else {
		@dataFiles = $self->executeSql(q/SELECT FILE_NAME FROM DBA_DATA_FILES/, "testingoverride");
	}
	my $logger = $self->logger();
	unless (@dataFiles) {
		$logger->error("Failed to get list of database volumes: " . $self->error());
		return;
	}

	my @logFiles = $self->executeSql(q/SELECT MEMBER FROM V$LOGFILE/, "testingoverride");
	unless (@logFiles) {
		$logger->error("Failed to get list of database volumes: " . $self->error());
		return;
	}

	return (@dataFiles, @logFiles);;
}


sub filesystemUtilityCmd {
	my $bin = $FindBin::Bin;
	if($bin =~ m|^/home/([^/]+)|) {
		my $user = $1;
		my $cmd = "/home/$user/ariba/services/monitor/bin/everywhere/filesystem-utility";
		if( -x $cmd ) {
			return($cmd);
		}
	}
	return("/usr/local/ariba/bin/filesystem-utility");
}

sub onlineOfflineDisks {
	my $self = shift;
	my $command = shift;

	return unless $command =~ /^(offline|online|offlineremove)$/;

	for my $diskgroup ($self->diskgroupsForPeer()) {
		my $fsUtil = filesystemUtilityCmd();
		my $command = "sudo $fsUtil -d -g $diskgroup $command";

		return unless $self->runRemoteCommand($command);
	}

	return 1;
}

sub diskgroupsForPeer {
	my $self = shift;

	my @diskgroups = ();
	for my $oracleFilesystem ( $self->dbFsInfo() ) {
		push @diskgroups, $oracleFilesystem->diskGroup() unless grep($_ eq $oracleFilesystem->diskGroup(), @diskgroups);
	}

	return @diskgroups;
}

sub shutdownOracleSid {
	my $self = shift;
    my $abort = shift;
	my $ignoreError = shift;

	my $sid = $self->sid();
	my $service = $self->service();
    my $stop = "stop";
    $stop = "abort" if $abort;
	$stop = "-k $stop" if $ignoreError;
	my $command = "/usr/local/ariba/bin/database-control -d -n $stop $sid -readMasterPassword";

	return unless $self->runRemoteCommand($command);

	return 1;
}

sub startupOracleSid {
	my $self = shift;

	my $sid = $self->sid();
	my $service = $self->service();

	my $command;
	if ($self->physicalReplication() && $self->isSecondary()) {
		$command = "/usr/local/ariba/bin/database-control -d startmount $sid -readMasterPassword";
	} else {
		$command = "/usr/local/ariba/bin/database-control -d start $sid -readMasterPassword";
	}

	return unless $self->runRemoteCommand($command);

	return 1;
}

#
# This will online a diskgroup based on a specified lun set.  The other
# online code assumes that the exports don't change, and caches the disk
# list, which we can't rely on -- we have to look up the os devices to get
# the disk names.
#
sub onlineFromLuns {
	my $self = shift;
	my $dg = shift;
	my $lun = shift;

	my $fctl = filesystemUtilityCmd();

	my $command = "sudo $fctl onlineluns -g $dg -l $lun";

	unless( $self->runRemoteCommand($command) ) {
		return 0;
	}

	return 1;
}

sub removeSCSIMapForLun {
	my $self = shift;
	my $lun = shift;

	my $fctl = filesystemUtilityCmd();

	my $command = "sudo $fctl removelun -l $lun";
	unless( $self->runRemoteCommand($command) ) {
		print STDERR "ERROR: ", $self->error(), "\n";
		return 0;
	}

	return 1;
}

sub checkFilesystemForOpenFiles {
	my $self = shift;
	my $ret = 1;

	my $logger = $self->logger();
	foreach my $oraFs ( $self->dbFsInfo() ) {
		my $fs = $oraFs->fs();

		#
		# the pipe to cat is so that the exit status is 0 normally
		# since lsof exits with 1 if there is no output
		#
		my $cmd = "/usr/bin/sudo /usr/sbin/lsof $fs | /bin/cat";

		my @output;
		$logger->info("Checking for open files on $fs on " . $self->host());

		if( $self->runRemoteCommand($cmd, \@output) ) {
			foreach my $line (@output) {
				chomp($line);
				if($line =~ m|(\d+)\s+\w+\s+cwd\s+DIR.*$fs|) {
					my $pid = $1;
					print "INFO: killing $pid with open handle on $fs.\n";
					my $scmd = "/usr/bin/sudo /usr/bin/kill -9 $pid";
					unless( $self->runRemoteCommand($scmd) || $self->error() =~ /No such process/ ) {
						print STDERR "Failed to kill $pid that had open files on $fs:\n\t$line\n";
						$ret = 0;
					}
				}
			}
		} else {
			print STDERR "failed to run $cmd for $fs.\n";
			print STDERR "-------------\n",$self->error(),"\n-------------\n";
			$ret = 0;
		}
	}

	return($ret);
}

sub unmountDbFilesystems {
	my $self = shift;


	for my $oracleFilesystem ( $self->dbFsInfo() ) {
		my $fs = $oracleFilesystem->fs();
		my $command = "sudo umount -fl $fs";

		return unless $self->runRemoteCommand($command);
	}

	return 1;
}

sub mountDbFilesystems {
	my $self = shift;

	for my $oracleFilesystem ( $self->dbFsInfo() ) {
		my $fs = $oracleFilesystem->fs();
		my $command = "sudo mount $fs";

		return unless $self->runRemoteCommand($command);
	}

	return 1;
}

sub maxSequenceNumber {
	my $self = shift;

	if ($self->isSecondary()) {
		if ($self->physicalReplication()) {
			return $self->executeSql(q/SELECT MAX(SEQUENCE#) FROM V$ARCHIVED_LOG WHERE REGISTRAR='RFS' AND APPLIED='YES' AND completion_time >= (select max(completion_time) from v$archived_log where archived='YES' and applied='YES')/);
		} else {
			return $self->executeSql(q/SELECT MAX(SEQUENCE#) FROM DBA_LOGSTDBY_LOG WHERE APPLIED IN ('YES','CURRENT')/);
		}
	} else {
		return $self->executeSql(q/SELECT SEQUENCE# FROM V$ARCHIVED_LOG WHERE DEST_ID=1 AND FIRST_TIME = (SELECT MAX(FIRST_TIME) FROM V$ARCHIVED_LOG)/);
	}

	return;
}

sub switchLogFile {
	my $self = shift;

	return if $self->isSecondary();

	return $self->executeSql(q/ALTER SYSTEM SWITCH LOGFILE/);

}

sub dbVersion {
	my $self = shift;

	my @rows = $self->executeSql(q/select distinct version from PRODUCT_COMPONENT_VERSION/);

	my $version = shift(@rows);
	return($version);
}

sub shutdownDataguard {
	my $self = shift;

	return unless $self->isSecondary();

	if ($self->physicalReplication()) {
		$self->executeSql(q/ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL/);
	} else {
		$self->executeSql(q/ALTER DATABASE STOP LOGICAL STANDBY APPLY/);
	}

	return if $self->error();
	return 1;

}

sub startupDataguard {
	my $self = shift;

	return unless $self->isSecondary();

	if ($self->physicalActiveRealtimeReplication()) {
		$self->executeSql(q/ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION/);
	} elsif ($self->physicalReplication()) {
		$self->executeSql(q/ALTER DATABASE RECOVER MANAGED STANDBY DATABASE DISCONNECT FROM SESSION/);
	} else {
		$self->executeSql(q/ALTER DATABASE START LOGICAL STANDBY APPLY IMMEDIATE/);
	}

	return if $self->error();
	return 1;
}

sub suspendArchiveLogDeletions {
	my $self = shift;

	my $sid = $self->sid();
	my $service = $self->service();
	my $command = "/home/mon$service/bin/clean-archivelogs -service $service -sid $sid -suspend";

	return unless $self->runRemoteCommand($command);

	return 1;
}

sub resumeArchiveLogDeletions {
	my $self = shift;

	my $sid = $self->sid();
	my $service = $self->service();
	my $command = "/home/mon$service/bin/clean-archivelogs -service $service -sid $sid -resume";
	my $logger = $self->logger();
	$logger->info("Running '$command'");

	return unless $self->runRemoteCommand($command);

	return 1;
}

sub executeSql {
	my $self = shift;
	my $sql = shift;
	my $testingOverride = shift;

	my $testing = $self->testing();
	$testing = 0 if $testingOverride;

	$self->setError(undef);

	my $mon;
	if (ariba::rc::InstalledProduct->isInstalled("mon", $self->service())) {
		$mon = ariba::rc::InstalledProduct->new("mon", $self->service());
	} else {
		$self->setError("Error: could not load mon product");
		return;
	}

	my $username;
	if ($self->physicalReplication()) {
		$username = 'sys';
	} else {
		$username = 'system';
	}
	my $password = $mon->default("dbainfo.$username.password");
	unless ($password) {
		$self->setError("mon product does not have $username password set in the config");
		return;
	}

	my $sid = $self->sid();
	my $host = $self->host();
	my $logger = $self->logger();
	$logger->debug("Connecting to $username\@$sid on $host") if $self->debug();
	my $oc = ariba::Ops::OracleClient->new($username, $password, $sid, $host);
	if ( !$oc->connect() ) {
		$self->setError("Connection to $username\@$sid failed: [" . $oc->error() . "].");
		return;
	}

	$oc->setDebug(1) if $self->debug() >= 2;

	my @output = ();
	if ($testing) {
		$logger->debug("DRYRUN: Would run '$sql'");
	} else {
		$logger->debug("executing '$sql'") if $self->debug();
		@output = $oc->executeSql($sql);

		if ($oc->error()) {
			$self->setError("Executing sql '$sql' on " . $self->sid() . "failed [" . $oc->error() . "]");
			return;
		}

	}

	$oc->disconnect();

	return @output;
}

1;
