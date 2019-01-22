#!/usr/local/bin/perl

package ariba::Ops::MCL::Helpers::Database;

use ariba::Ops::Logger;
my $logger = ariba::Ops::Logger->logger();

use ariba::rc::InstalledProduct;
use ariba::Ops::OracleClient;
use ariba::Ops::DBConnection;
use ariba::Ops::DatabasePeers;

#
# This helper depends on rollbackTimeForProduct() being a prior part of your
# MCL.  It also is probably a good idea to have called waitForRollForward()
# before this too.
#
sub flashbackDatabase {
	my $product = shift;
	my $service = shift;
	my $buildname = shift;
	my $customer = shift;
	my $sid = shift;

	my $p = ariba::rc::InstalledProduct->new($product, $service, $buildname, $customer);
	my $mon = ariba::rc::InstalledProduct->new('mon', $service);

	my @dbcs = ariba::Ops::DBConnection->connectionsFromProducts($p);
	my %flashPoints;

	foreach my $d (@dbcs) {
		my $state = ariba::Ops::MCL::SavedState->new($d->sid());
		unless( $state->attribute('rollForwardTimestamp') ) {
			return("ERROR: rollForwardTimestamp not saved for $sid.  Did rollbackTimeForProduct() run for this product?");
		}
		$flashPoints{$state->attribute('rollForwardTimestamp')} = 1;
	}

	my $flashback = ( sort(keys(%flashPoints)) )[0];

	#
	# until I decouple the ALTER DATABASE OPEN RESETLOGS (which doesn't work unless you flashed back)
	# we will always flashback 1 second.  I am leaving the logic for handling "don't flash back" here
	# for now, so that when I fix the conditional logic, I can just remove this decrement.
	#
	$flashback--;
	
	my $state = ariba::Ops::MCL::SavedState->new($sid);

	my ($year, $month, $day, $hour, $minute, $second) = (localtime($flashback))[5,4,3,2,1,0];
	$year += 1900;
	$month++;
	my $dateTime = sprintf("%4d-%02d-%02d:%02d:%02d:%02d", $year, $month, $day, $hour, $minute, $second);

	if($flashback == $state->attribute('rollForwardTimestamp') ) {
		return("OK: $sid is already at $dateTime");
	}

	@dbcs = grep { $_->sid() eq $sid } @dbcs;
	@dbcs = grep { ! $_->isDR() } @dbcs;
	my $dbc = shift(@dbcs);

	my ($primary, $secondary) = ariba::Ops::DBConnection::sanitizeDBCs($dbc, $service);
	$dbc = $secondary;

	my $host = $dbc->host();
	my $user = ariba::Ops::MCL::userForService($service, 'svc');

	#
	# uncomment this to test the logic in it.
	#
	# my $sql = "flashback database to timestamp TO_TIMESTAMP('$dateTime','YYYY-MM-DD:HH24:MI:SS');";
	# return("OK: $sql");

	my $command = "ssh $user\@$host -x '/usr/local/ariba/bin/database-control -d -n flashback $sid -date $dateTime -readMasterPassword'";
	my $password = ariba::rc::Passwords::lookup( $user );

	my $master = ariba::rc::Passwords::lookup( "${service}Master" );
	$master = ariba::rc::Passwords::lookup( 'master' ) unless($master);

	$logger->info("Run: $command");
	$logger->info("==== $user\@$host ====");

	my @output;
	my $ret = ariba::rc::Utils::executeRemoteCommand(
		$command,
		$password,
		0,
		$master,
		undef,
		\@output,
	);

	my $error = 0;
	my @results;
	foreach my $line (@output) {
		if($line =~ /error/i) {
			$ret=0;
		}

		next if($line =~ /^\s*$/);
		next if($line =~ /Master Password is good./);
		next if($line =~ m|Reading /tmp/.*variables$|);

		$logger->info($line);
		push(@results, $line);
	}

	unless($ret) {
		return("ERROR: database-control returned error.\n" . join("\n", @results));
	}

	return("OK: " . join("\n", @results));
}

#
# This helper depends on rollbackTimeForProduct() being a prior part of your
# MCL.
#
sub waitForRollForward {
	my $product = shift;
	my $service = shift;
	my $buildname = shift;
	my $customer = shift;
	my $sid = shift;

	my $p = ariba::rc::InstalledProduct->new($product, $service, $buildname, $customer);
	my $mon = ariba::rc::InstalledProduct->new('mon', $service);

	my @dbcs = ariba::Ops::DBConnection->connectionsFromProducts($p);
	@dbcs = grep { $_->sid() eq $sid } @dbcs;
	@dbcs = grep { ! $_->isDR() } @dbcs;
	my $dbc = shift(@dbcs);

	my ($primary, $secondary) = ariba::Ops::DBConnection::sanitizeDBCs($dbc, $service);
	$dbc = $secondary;

	my $dbuser = "system";
	my $dbpass = $mon->default("dbainfo.$dbuser.password");
	my $state = ariba::Ops::MCL::SavedState->new($dbc->sid());

	unless( $state->attribute('rollForwardTimestamp') ) {
		return("ERROR: rollForwardTimestamp not saved for $sid.  Did rollbackTimeForProduct() run for this product?");
	}

	my $oc = ariba::Ops::OracleClient->new($dbuser, $dbpass, $dbc->sid(), $dbc->host());
	unless( $oc->connect() ) {
		return("ERROR: failed to connect to " . $dbc->sid() . ".");
	}

	my $hasGap = $state->attribute('hasGap');

	if($hasGap) {
		$logger->info("Waiting for $sid to roll forward ($sid has a log gap)");
	} else {
		$logger->info("Waiting for $sid to roll forward (no log gap)");
	}

	my @results;
	for(my $i=0; $i<60; $i++) {
		if($hasGap) {
			my $sql = 'select count(*) from v$archived_log where sequence#=(select sequence#-1 from v$managed_standby where status=\'WAIT_FOR_GAP\' and PROCESS like \'MRP%\') and applied=\'YES\';';
			unless( $oc->executeSqlWithTimeout($sql, 30, \@results) ) {
				return("ERROR: failed to execute SQL on " . $dbc->sid() . ".");
			}

			my $count = $results[0];
			if($count) {
				return("OK: roll forward is complete");
			}
		} else {
			my $sql = 'select SEQUENCE# "Missing Sequence" from V$MANAGED_STANDBY where status=\'WAIT_FOR_GAP\' and PROCESS like \'MRP%\';';
			unless( $oc->executeSqlWithTimeout($sql, 30, \@results) ) {
				return("ERROR: failed to execute SQL on " . $dbc->sid() . ".");
			}

			unless(scalar(@results)) {
				return("OK: roll forward is complete");
			}
		}
		$logger->info("roll forward not yet complete (check again in 10 seconds)");
		sleep(10);
	}
	
	return("ERROR: roll forward not yet complete after 10 minutes.");
}

sub rollbackTimeForProduct {
	my $product = shift;
	my $service = shift;
	my $buildname = shift;
	my $customer = shift;

	my $p = ariba::rc::InstalledProduct->new($product, $service, $buildname, $customer);
	my $mon = ariba::rc::InstalledProduct->new('mon', $service);

	my @dbcs = ariba::Ops::DBConnection->connectionsFromProducts($p);
	my %seenSID;
	my $dbuser = "system";
	my $dbpass = $mon->default("dbainfo.$dbuser.password");
	my %rollbackPoint;

	foreach my $dbc (@dbcs) {
		next if($dbc->isDR());

		my ($primary, $secondary) = ariba::Ops::DBConnection::sanitizeDBCs($dbc, $service);
		$dbc = $secondary;


		next if($seenSID{$dbc->sid()});
		$seenSID{$dbc->sid()}=1;
		my $state = ariba::Ops::MCL::SavedState->new($dbc->sid());

		$logger->info("Gathering Rollback Point for " . $dbc->sid() . "\@" . $dbc->host());

		my $oc = ariba::Ops::OracleClient->new($dbuser, $dbpass, $dbc->sid(), $dbc->host());
		unless( $oc->connect() ) {
			return("ERROR: failed to connect to " . $dbc->sid() . ".");
		}

		#
		# check for a log gap...
		#
		my $sql = 'select SEQUENCE# "Missing Sequence" from V$MANAGED_STANDBY where status=\'WAIT_FOR_GAP\' and PROCESS like \'MRP%\'';
		my @results;

		unless( $oc->executeSqlWithTimeout($sql, 30, \@results) ) {
			return("ERROR: failed to execute SQL on " . $dbc->sid() . ".");
		}

		if(scalar(@results)) {
			#
			# There is a log gap...
			#

			$state->setAttribute('hasGap',1);
			my $gapSequence = $results[0];
			$state->setAttribute('gapSequenceNumber',$gapSequence);

			$sql = 'select (cast(SYS_EXTRACT_UTC(cast(next_time as timestamp with time zone)) as date) - to_date(\'01-01-1970 00:00:00\',\'MM-DD-YYYY HH24:MI:SS\')) *86400 "unix timestamp" from v$archived_log where sequence#=(select SEQUENCE#-1 from V$MANAGED_STANDBY where status=\'WAIT_FOR_GAP\' and PROCESS like \'MRP%\')';

			unless( $oc->executeSqlWithTimeout($sql, 30, \@results) ) {
				return("ERROR: failed to execute SQL on " . $dbc->sid() . ".");
			}

			my $timeStamp = $results[0];
			$timeStamp =~ s/\.\d+$//;
			$state->setAttribute('rollForwardTimestamp', $timeStamp);
		} else {
			#
			# no gap
			#
			$state->setAttribute('hasGap',0);

			$sql = 'select (cast(SYS_EXTRACT_UTC(cast(max(next_time) as timestamp with time zone)) as date) - to_date(\'01-01-1970 00:00:00\',\'MM-DD-YYYY HH24:MI:SS\')) * 86400 "unix timestamp" from v$archived_log where sequence# >= (select max(sequence#) from v$archived_log where archived=\'YES\' and applied=\'YES\' and completion_time >= (select max(completion_time) from v$archived_log where archived=\'YES\' and applied=\'YES\'));';

			unless( $oc->executeSqlWithTimeout($sql, 30, \@results) ) {
				return("ERROR: failed to execute SQL on " . $dbc->sid() . ".");
			}

			my $timeStamp = $results[0];
			$timeStamp =~ s/\.\d+$//;
			$state->setAttribute('rollForwardTimestamp', $timeStamp);
		}
		$state->save();

		my $gap;
		if($state->attribute('hasGap')) {
			$gap = " (has a log gap)";
		} else {
			$gap = " (no gap)";
		}
		$rollbackPoint{$dbc->sid()} = $state->attribute('rollForwardTimestamp') . $gap;
	}

	my $ret = "WAIT: The SIDs for $product can be caught up to the following times:\n\n";

	my $earliestTime;
	foreach my $sid (sort { $rollbackPoint{$a} cmp $rollbackPoint{$b} } (keys %rollbackPoint)) {
		my ($timeStamp, $gap) = split(/\s+/, $rollbackPoint{$sid}, 2);
		$ret .= sprintf("%-15s: %s %s.\n", $sid, scalar(localtime($timeStamp)), $gap);
		$earliestTime = $timeStamp unless($earliestTime);
		
	}

	#
	# do to needing to flashback at least 1 second, we do this here.  See comment in flashbackDatabase
	#
	$earliestTime--;

	$ret .= "\nIf you continue, $product will be reset to " . scalar(localtime($earliestTime)) . ".\nTo accept this, mark this step complete in the UI.";

	return($ret);
}

sub lowestSCNForProduct {
	my $product = shift;
	my $service = shift;
	my $buildname = shift;
	my $customer = shift;

	my $sql = "select (cast(scn_to_timestamp(dbms_flashback.get_system_change_number) as DATE) - (to_date('01-01-1970 00:00:00','MM-DD-YYYY HH24:MI:SS'))) * 86400 from dual;";

	my $p = ariba::rc::InstalledProduct->new($product, $service, $buildname, $customer);
	my $mon = ariba::rc::InstalledProduct->new('mon', $service);

	my @dbcs = ariba::Ops::DBConnection->connectionsFromProducts($p);
	my %seenSID;
	my $lowestSCN;
	my $dbuser = "system";
	my $dbpass = $mon->default("dbainfo.$dbuser.password");

	foreach my $dbc (@dbcs) {
		next unless($dbc->isDR());
		next if($seenSID{$dbc->sid()});
		$seenSID{$dbc->sid()}=1;

		$logger->info("Gathering SCN for " . $dbc->sid() . "\@" . $dbc->host());


		my $oc = ariba::Ops::OracleClient->new($dbuser, $dbpass, $dbc->sid(), $dbc->host());
		unless( $oc->connect() ) {
			return("ERROR: failed to connect to " . $dbc->sid() . ".");
		}

		my $scn;
		unless( $oc->executeSqlWithTimeout($sql, 30, \$scn) ) {
			return("ERROR: failed to execute SQL on " . $dbc->sid() . ".");
		}

		#
		# this has to round down, just to be safe.
		#
		$scn =~ s/\.(\d+)$//;

		$logger->info("--> SCN for " . $dbc->sid() . " is $scn (" . scalar(localtime($scn)) . ")");

		if(!defined($lowestSCN) || $lowestSCN > $scn) {
			$lowestSCN = $scn;
		}
	}

	unless(defined($lowestSCN)) {
		return("ERROR: Did not find a lowest SCN");
	}

	return("OK: lowest SCN is $lowestSCN (" . scalar(localtime($lowestSCN)) . ")");
}

sub doArchiveLogSuspendOrResume {
	my $action = shift;
	my $sid = shift;
	my $product = shift;
	my $service = shift;
	my $buildname = shift;
	my $customer = shift;

	my $p = ariba::rc::InstalledProduct->new($product, $service, $buildname, $customer);
	
	my @peers = ariba::Ops::DatabasePeers->newListFromProduct($p, { 'debug' => 1, 'sid' => $sid });
	my $peer;

	foreach my $i (@peers) {
		$peer = $i if(lc($i->sid()) eq $sid);
		last if($peer);
	}

	unless($peer) {
		$logger->error("$sid does not exist in $product/$service");
		return("ERROR: $sid does not exist in $product/$service");
	}

	my $retVal;
	if($action eq 'suspend') {
		$retVal = $peer->suspendArchiveLogDeletions();
	} else {
		$retVal = $peer->resumeArchiveLogDeletions();
	}

	unless($retVal) {
		$logger->error("Failed to $action archive log deletion for $sid.");
		return("ERROR: Failed to $action archive log deletion for $sid.");
	}

	$logger->info("$action of archive logs for $sid succeeded.");
	return("OK: $action of archive logs for $sid succeeded.");
}

sub suspendArchiveLogDeletion {
	return( doArchiveLogSuspendOrResume("suspend", @_) );
}

sub resumeArchiveLogDeletion {
	return( doArchiveLogSuspendOrResume("resume", @_) );
}

sub startDataguard {
	controlDataguard("start", @_);
}

sub stopDataguard {
	controlDataguard("stop", @_);
}

sub controlDataguard {
	my $action = shift;
	my $sid = shift;
	my $product = shift;
	my $service = shift;
	my $buildname = shift;
	my $customer = shift;

	my $p = ariba::rc::InstalledProduct->new($product, $service, $buildname, $customer);
	
	my @peers = ariba::Ops::DatabasePeers->newListFromProduct($p, { 'debug' => 1 });
	my $peer;

	foreach my $i (@peers) {
		$peer = $i if(lc($i->sid()) eq $sid);
		last if($peer);
	}

	unless($peer) {
		$logger->error("$sid does not exist in $product/$service");
		return("ERROR: $sid does not exist in $product/$service");
	}

	unless($peer->secondary()) {
		$logger->info("$sid in $product/$service does not have DR.");
		return("INFO: $sid does not have DR in $product/$service, proceeding.");
	}

	my $retVal;
	if($action eq 'start') {
		$retVal = $peer->startupDataguard();
	} else {
		$retVal = $peer->shutdownDataguard();
	}

	unless($retVal) {
		$logger->error("Failed to $action dataguard for $sid.");
		return("ERROR: Failed to $action dataguard for $sid.");
	}

	$action = "stopp" if($action eq 'stop');

	$logger->info("Dataguard for $sid ${action}ed successfully.");
	return("OK: Dataguard for $sid ${action}ed successfully.");
}

sub waitForDataguard {
	my $sid = shift;
	my $product = shift;
	my $service = shift;
	my $buildname = shift;
	my $customer = shift;

	my $p = ariba::rc::InstalledProduct->new($product, $service, $buildname, $customer);
	
	my @peers = ariba::Ops::DatabasePeers->newListFromProduct($p, { 'debug' => 1 });
	my $peer;

	foreach my $i (@peers) {
		$peer = $i if(lc($i->sid()) eq $sid);
		last if($peer);
	}

	unless($peer) {
		$logger->error("$sid does not exist in $product/$service");
		return("ERROR: $sid does not exist in $product/$service");
	}

	unless($peer->secondary()) {
		$logger->info("$sid in $product/$service does not have DR.");
		return("INFO: $sid does not have DR in $product/$service, proceeding.");
	}

	my $retVal = $peer->checkDataguardLag();

	unless($retVal) {
		$logger->error("Dataguard for $sid is not caught up.");
		return("ERROR: Dataguard for $sid is not caught up.");
	}

	$logger->info("Dataguard for $sid is in sync.");
	return("OK: Dataguard for $sid is in sync.");
}

1;
