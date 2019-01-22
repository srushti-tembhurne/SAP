package ariba::Ops::DatabasePeers;
# vi:et ts=4 sw=4

use base qw(ariba::Ops::PersistantObject);

use strict;
use ariba::Ops::DBConnection;
use ariba::Ops::Constants;
use ariba::Ops::Logger;

INIT {
        ariba::Ops::PersistantObject->enableSmartCache();
}

my $logger = ariba::Ops::Logger->logger();

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

sub peerType {
	my $self = shift;

	return($self->primary()->peerType()) if($self->primary());
	return($self->secondary()->peerType()) if($self->secondary());
	return("unknown");
}

sub dbVersion {
	my $self = shift;
	return($self->primary()->dbVersion());
}

sub allPeerConnections {
	my $self = shift;
	my $location = shift || 'primary and secondary';
	my @ret;

	if($self->primary() && $location =~ /primary/) {
		push(@ret, $self->primary()) if($self->primary());
		push(@ret, $self->primary()->slaveNodes()) if($self->primary()->slaveNodes());
		push(@ret, $self->primary()->standbyNodes()) if($self->primary()->standbyNodes());
	}
	if($self->secondary() && $location =~ /secondary/) {
		push(@ret, $self->secondary()) if($self->secondary());
		push(@ret, $self->secondary()->slaveNodes()) if($self->secondary()->slaveNodes());
		push(@ret, $self->secondary()->standbyNodes()) if($self->secondary()->standbyNodes());
	}

	return(@ret);
}

sub peerConnsForFS {
	my $filesystem = shift;
	my @peers = (@_);
	my %dbPeers;

	foreach my $p (@peers) {
		foreach my $parentConn ($p->primary(), $p->secondary()) {
			next unless($parentConn);
			my $match = 0;
			foreach my $conn ($parentConn, $parentConn->slaveNodes(), $parentConn->standbyNodes()) {
				next unless($conn);
				foreach my $fs ($conn->dbFsInfo()) {
					if(
						$fs->fs() eq $filesystem->fs() &&
						$fs->host() eq $filesystem->host()
					) {
						$match = 1;
					}
				}
			}

			#
			# in Hana, all sibling peers match the filesystem
			#
			if($match) {
				foreach my $conn ($parentConn, $parentConn->slaveNodes(), $parentConn->standbyNodes()) {
					next unless($conn);
					$dbPeers{$conn->host . ":" . $conn->sid()} = $conn;
				}
			}
		}
	}

	my @ret;
	foreach my $k (sort (keys %dbPeers)) {
		push(@ret, $dbPeers{$k});
	}

	return(@ret);
}

sub volumesForPeers {
	my @peers = (@_);
	my %vols;
	my @ret;

	foreach my $p (@peers) {
		foreach my $conn ($p->primary(), $p->secondary) {
			next unless($conn);
			foreach my $fs ($conn->dbFsInfo()) {
				my $key = $fs->host() . ":" . $fs->fs();
				$vols{$key} = $fs;
			}
		}
	}

	foreach my $k (sort (keys %vols)) {
		push(@ret, $vols{$k});
	}

	return(@ret);
}

sub setDebug {
        my $class = shift;
        my $debugLevel = shift;

        return if $debugLevel < 1;
        my $debug = $debugLevel + $logger->logLevel();

        $logger->setLogLevel($debug);

	$class->SUPER::setDebug($debugLevel);

	return 1;
}

sub validAccessorMethods {
        my $class = shift;

        my $methodsRef = $class->SUPER::validAccessorMethods();

        $methodsRef->{'primary'}   = undef;
        $methodsRef->{'secondary'} = undef;
        $methodsRef->{'sid'}       = undef;
        $methodsRef->{'type'}      = undef;
        $methodsRef->{'debug'}     = undef;
        $methodsRef->{'adminID'}   = undef;

        return $methodsRef;
}

#TODO: Need to use ariba::Ops::HanaControl if hana. 
# Unfortunately, I don't know how to figure out whether hana without a dbc.
# However, I haven't seen any other module or script use this method, so we may be ok.
#
sub objectLoadMap {
        my $class = shift;

        my %map = (
        	'primary', 'ariba::Ops::OracleControl',
        	'secondary', 'ariba::Ops::OracleControl',
        );

        return \%map;
}

sub checkForXFS {
	my $host = shift;
	my $service = shift;

	my $user = "mon" . $service;
	my $password = ariba::rc::Passwords::lookup($user);
	my $command = "ssh $user\@$host /bin/mount -t xfs";

	my @output;

	my $ret = ariba::rc::Utils::executeRemoteCommand(
		$command, $password, 0, undef, undef, \@output
	);

	foreach my $line (@output) {
		return(1) if($line =~ /type xfs/);
	}

	return(0);
}

sub newListFromProduct {
	my $class = shift;
	my $product = shift;
	my $optionsRef = shift;

	my @dbConnections = ariba::Ops::DBConnection->connectionsFromProducts($product);

	return($class->newListFromDbcs($optionsRef, @dbConnections));
}

sub newListFromDbcs {
	my $class = shift;
	my $optionsRef = shift;
	my @dbConnections = (@_);

	my $dbc0 = $dbConnections[0];
	my $product = $dbc0->product();
	my $isHana = $dbc0->isHana; # dbc peers should always be of the same db type
	my $debug = $optionsRef->{'debug'};
	my $isBackup = $optionsRef->{'isBackup'};
	my $populateFsInfo = $optionsRef->{'populateFsInfo'};
	my $includeLogVolumes = $optionsRef->{'includeLogVolumes'};
	my $skipDR = $optionsRef->{'skipDR'};
	my @skipTypes = $optionsRef->{'skipTypes'};
	my $testing = $optionsRef->{'testing'};
	my $onlySid = $optionsRef->{'sid'};
	my $hanaIsClustered = 0;

	my @peersForProduct;

	my @uniqueDbcs;
	if($isHana) {
		# hana dbc's are unique by host and port
		@uniqueDbcs = ariba::Ops::DBConnection->uniqueConnectionsByHostAndPort(@dbConnections);
	}
	else {
		@uniqueDbcs = ariba::Ops::DBConnection->uniqueConnectionsByHostAndSid(@dbConnections);
	}

	for my $dbc (@uniqueDbcs) {

		next if $dbc->isDR();

		my $dbctype = $dbc->type();
		my $type = $dbctype;
		$type =~ s/.*-//;
		$type = lc($type);

		if (grep{$_ eq $type} @skipTypes) {
			$logger->info("Skipping Database type " . $dbc->type());
			next;
		}

        if ($onlySid && lc($onlySid) ne lc($dbc->sid())) {
            $logger->info("Skipping sid " . $dbc->sid());
            next;
        }

		my $instance = $dbc->sid();
		$instance = "DS-" . $instance if $isBackup;

		my $self = $class->SUPER::new($instance);
		$self->setDebug($debug) if $debug;

		for my $dbc ($dbc, $dbc->peers()) {

			next unless $dbc;
			next if $dbc->isDR() && $skipDR;

			my $dbPeer;
			if($dbc->isHana) {
				require ariba::Ops::HanaControl;
				$dbPeer = ariba::Ops::HanaControl->newFromDbc($dbc, $isBackup);
			} else {
				require ariba::Ops::OracleControl;
				$dbPeer = ariba::Ops::OracleControl->newFromDbc($dbc, $isBackup);
			}
			$dbPeer->setDebug($self->debug());
			$dbPeer->setTesting($testing);

			$self->setType($dbctype);

			if ($dbc->isDR()) {
				$self->setSecondary($dbPeer);
			} else {
				$self->setPrimary($dbPeer);
				$self->setSid($dbPeer->sid());
                $self->setAdminID($dbPeer->adminID) if $dbc->isHana; # HOA-163618: adminID only valid for hana type
			}

			if ($populateFsInfo) {
				return unless $dbPeer->setDbFsInfo($dbc, $includeLogVolumes);
				foreach my $slavePeer ($dbPeer->slaveNodes()) {
					return unless $slavePeer->setDbFsInfo($dbc, $includeLogVolumes);
				}
			}
		}

		push(@peersForProduct, $self);
	}

	return @peersForProduct;
}

sub checkDataguardLag {
	my $self = shift;

	# the rest of the higher level methods depend on the OracleControl private _runCommand and _executeSql
	# methods to handle testing mode.  That doesn't work in this case, so we just short circuit.
	return 1 if $self->primary->testing();

	# Get the most recent archive log sequence number on the primary
	my ($maxPrimarySequence) = $self->primary->maxSequenceNumber();
	return unless $maxPrimarySequence;

	$logger->debug("Requesting log switch on primary db");
	$self->primary->switchLogFile();
	if ($self->primary->error()) {
		$logger->error("Failed to shutdown dataguard: " . $self->primary->error());
		return;
	}

	#
	# This sometimes comes back empty without a sleep state... we'll retry and
	# introduce a sleep 1
	#
	my $maxPrimarySequenceAfterSwitch;
	my $attempt = 0;
	sleep(1);
	while($attempt < 5 && !$maxPrimarySequenceAfterSwitch) {
		($maxPrimarySequenceAfterSwitch) = $self->primary->maxSequenceNumber();
		$attempt++;
		sleep 1 unless($maxPrimarySequenceAfterSwitch);
	}

	unless($maxPrimarySequenceAfterSwitch) {
		$logger->error("Failed to get sequence number after switch");
		return(0);
	}

	$attempt = 0;
	while ($maxPrimarySequenceAfterSwitch == $maxPrimarySequence) {
		last if $attempt++ >= 5;

		$logger->warn("switch logfile sql has not happened, trying again");
		sleep 5;
		($maxPrimarySequenceAfterSwitch) = $self->primary->maxSequenceNumber();
	}

	if ( $maxPrimarySequence + 1 != $maxPrimarySequenceAfterSwitch ) {
		$logger->warn("The primary DB is moving too much: '$maxPrimarySequence' to '$maxPrimarySequenceAfterSwitch'");
		return 0;
	}

	# Get the most recent archive log sequence number on the secondary
	my ($secondarySequence) = $self->secondary->maxSequenceNumber();
	$attempt = 0;
	$logger->info("Starting Dataguard check: primary=$maxPrimarySequenceAfterSwitch and secondary=$secondarySequence");
	while ($maxPrimarySequenceAfterSwitch >= $secondarySequence+2) {
		last if $attempt++ >= 30;
		$logger->warn("Secondary DB has not caught up to primary.  Primary sequence: '$maxPrimarySequenceAfterSwitch', Secondary sequence: '$secondarySequence'");
		sleep 10;
		($secondarySequence) = $self->secondary->maxSequenceNumber();
	}

	if ( $maxPrimarySequenceAfterSwitch >= $secondarySequence+2 ) {
		$logger->warn("Secondary DB has not caught up. primary sequence: '$maxPrimarySequenceAfterSwitch'; secondary sequence: '$secondarySequence'");
		return 0;
	}

	return 1 ;
}

sub shutdownDataguard {
	my $self = shift;

	return unless $self->secondary();

	$self->secondary->shutdownDataguard();

	$logger->debug("Shutting down dataguard on " . $self->secondary->sid());
	if ($self->secondary->error()) {
		$logger->error("Shutting down dataguard on " . $self->secondary->sid() . " failed: " . $self->secondary->error());
		return;
	}

	return 1;
}

sub startupDataguard {
	my $self = shift;

	return unless $self->secondary();

	$self->secondary->startupDataguard();

	if ($self->secondary->error()) {
		$logger->error("Starging dataguard " . $self->secondary->sid() . " failed: " . $self->secondary->error());
		return;
	}

	return 1;
}

sub shutdownOracle {
	my $self = shift;
    my $abort = shift;
	my $ignoreError = shift;

	if ($self->secondary()) {
		$logger->debug("Shutting down Oracle " . $self->secondary->sid() . "@" . $self->secondary->host());
		unless ($self->secondary->shutdownOracleSid($abort, $ignoreError)) {
			$logger->error("Shutdown of " . $self->secondary->sid() . "@" . $self->secondary->host() . " failed: " . $self->secondary->error());
			return;
		}
	}

	$logger->debug("Shutting down Oracle " . $self->primary->sid() . "@" . $self->primary->host());
	unless ($self->primary->shutdownOracleSid($abort, $ignoreError)) {
		$logger->error("Shutdown of " . $self->primary->sid() . "@" . $self->primary->host() . " failed: " . $self->primary->error());
		return;
	}

	return 1;
}

sub startupOracle {
	my $self = shift;

	if ($self->secondary()) {
		$logger->debug("Starting up Oracle " . $self->secondary->sid() . "@" . $self->secondary->host());
		unless ($self->secondary->startupOracleSid()) {
			$logger->error("Startup of " . $self->secondary->sid() . "@" . $self->secondary->host() . " failed: " . $self->secondary->error());
			return;
		}
	}

	$logger->debug("Starting up Oracle " . $self->primary->sid() . "@" . $self->primary->host());
	unless ($self->primary->startupOracleSid()) {
		$logger->error("Startup of " . $self->primary->sid() . "@" . $self->primary->host() . " failed: " . $self->primary->error());
		return;
	}

	return 1;
}

sub checkDBFilesystemsForOpenFiles {
	my $self = shift;
	my $ret = 1;

	if($self->secondary()) {
		unless( $self->secondary()->checkFilesystemForOpenFiles() ) {
			$ret = 0;
		}
	}

	unless( $self->primary()->checkFilesystemForOpenFiles() ) {
		$ret = 0;
	}

	return($ret);
}

sub unmountDbFilesystems {
	my $self = shift;

	if ($self->secondary()) {
		unless ($self->secondary->unmountDbFilesystems()) {
			$logger->error("Unmounting filesystems on " . $self->secondary->host() . " failed: " . $self->secondary->error());
			return;
		}
	}

	unless ($self->primary->unmountDbFilesystems()) {
		$logger->error("Unmounting filesystems on " . $self->primary->host() . " failed: " . $self->primary->error());
		return;
	}

	return 1;
}

sub mountDbFilesystems {
	my $self = shift;

	if ($self->secondary()) {
		unless ($self->secondary->mountDbFilesystems()) {
			$logger->error("Mounting filesystems on " . $self->secondary->host() . " failed: " . $self->secondary->error());
			return;
		}
	}

	unless ($self->primary->mountDbFilesystems()) {
		$logger->error("Mounting filesystems on " . $self->primary->host() . " failed: " . $self->primary->error());
		return;
	}

	return 1;
}

sub suspendArchiveLogDeletions {
	my $self = shift;

	if ($self->secondary()) {
		$logger->debug("Suspending archive log deletions on " . $self->secondary->sid() . "@" . $self->secondary->host());
		unless ($self->secondary->suspendArchiveLogDeletions()) {
			$logger->error("Suspending archive log deletions on " . $self->secondary->sid() . "@" . $self->secondary->host() . " failed: " . $self->secondary->error());
			return;
		}
	}

	$logger->debug("Suspending archive log deletions on " . $self->primary->sid() . "@" . $self->primary->host());
	unless ($self->primary->suspendArchiveLogDeletions()) {
		$logger->error("Suspending archive log deletions on " . $self->primary->sid() . "@" . $self->primary->host() . " failed: " . $self->primary->error());
		return;
	}
	return 1;
}

sub resumeArchiveLogDeletions {
	my $self = shift;

	if ($self->secondary()) {
		$logger->debug("Resuming archive log deletions on " . $self->secondary->sid() . "@" . $self->secondary->host());
		unless ($self->secondary->resumeArchiveLogDeletions()) {
			$logger->error("Resuming archive log deletions on " . $self->secondary->sid() . "@" . $self->secondary->host() . " failed: " . $self->secondary->error());
			return;
		}
	}

	$logger->debug("Resuming archive log deletions on " . $self->primary->sid() . "@" . $self->primary->host());
	unless ($self->primary->resumeArchiveLogDeletions()) {
		$logger->error("Resuming archive log deletions on " . $self->primary->sid() . "@" . $self->primary->host() . " failed: " . $self->primary->error());
		return;
	}
	return 1;
}

1;
