package ariba::Ops::Startup::DB;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/DB.pm#15 $
# Common functions for startup.

use strict;
use File::Basename;

use ariba::Ops::DBConnection;
use ariba::Ops::Startup::Common;
use ariba::Ops::NetworkUtils;
use ariba::rc::Utils;
use dmail::LockLib;

sub createLinkFromTo
{
	my ($linkName,$from,$to) = @_;

	my $dropSql = "drop database link $linkName";

	my $sql = sprintf(
		"create database link $linkName connect to %s identified by %s " .
		"using '(description=(address=(host=%s)(protocol=tcp)(port=1521))(connect_data=(sid=%s)))'",
		$to->user(),$to->password(),$to->host(),$to->sid()
	);

	print "  will drop link using sql = $dropSql\n" if $main::debug;
	print "  will create link using sql = $sql\n" if $main::debug;

	return 1 if $main::testing;
    eval {
        require ariba::Ops::OracleClient;
        ariba::Ops::OracleClient->import();
        1;
    } or do {
        my $error = $@;
        print "unable to load OracleClient\n";
    };
	my $oc = ariba::Ops::OracleClient->newFromDBConnection($from);
	$oc->connect();
	$oc->executeSql($dropSql);
	$oc->executeSql($sql);
	$oc->disconnect();

	return 1;
}

sub createLink
{
	my ($linkName, $oc, $dstUser, $dstPassword, $dstSid, $dstHost) = @_;

	my $dropSql = "drop database link $linkName";
	my $connectString = ariba::rc::Utils::connectStringForSidOnHost($dstSid,$dstHost);

	my $sql = "create database link $linkName " .
			  "connect to $dstUser identified by $dstPassword " .
			  "using '(description=(address=(host=$dstHost)".
			         "(protocol=tcp)(port=1521))(connect_data=".
			         "(sid=$dstSid)))'";

	print "  will drop link using sql = $dropSql\n" if ($main::debug);
	print "  will create link using sql = $sql\n" if ($main::debug);

	return 1 if $main::testing;

	$oc->executeSql($dropSql);
	$oc->executeSql($sql);

	return 1;
}

sub connectToSrc
{
	my ($srcUser, $srcPassword, $srcSid, $srcHost) = @_;

	return 1 if ($main::testing);
    eval {
        require ariba::Ops::OracleClient;
        ariba::Ops::OracleClient->import();
        1;
    } or do {
        my $error = $@;
        print "unable to load OracleClient\n";
    };
	my $oc = ariba::Ops::OracleClient->new($srcUser, $srcPassword, $srcSid, $srcHost);
	$oc->connect() || return undef;

	return $oc;
}

sub disconnectFromSrc
{
	my $oc = shift;

	return if $main::testing;

	$oc->disconnect();
}

sub createLinksForCommunities
{
	my $product = shift;

	my $name = $product->name();
	my @connections = ariba::Ops::DBConnection->connectionsFromProducts($product);

	my $numConnections = scalar(@connections);
	print "$name has $numConnections dictionaries\n" if ($main::debug);

	return 1 unless ($numConnections > 1);

	for my $srcConnection (@connections) {
		my $srcUser = $srcConnection->user();
		my $srcPass = $srcConnection->password();
		my $srcSid  = $srcConnection->sid();
		my $srcHost = $srcConnection->hostname();

		next if ($srcUser eq "dummy" || 
                         $srcPass eq "dummy" ||
			 $srcSid  eq "dummy");

		print "\nsrc = $srcUser-$srcSid\n" if ($main::debug);

		for my $destConnection (@connections) {

			my $dstUser = $destConnection->user();
			my $dstPass = $destConnection->password();
			my $dstSid  = $destConnection->sid();
			my $dstHost = $destConnection->hostname();
			next if ($dstUser eq $srcUser and $dstSid eq $srcSid and $dstHost eq $srcHost);

			print "dst = $dstUser-$dstSid\n" if ($main::debug);

			next if ($dstUser eq "dummy" || 
				 $dstPass eq "dummy" ||
				 $dstSid  eq "dummy");

			my $linkName = "$dstUser-$dstSid";

			unless(createLinkFromTo($linkName, $srcConnection, $destConnection)) {
				print "ERROR: could not create dblink to $dstSid/$dstUser\n";
				return 0;

			}
		}
	}

	return 1;
}

#
# Returns true if the product name should / can run load meta. 
#
sub shouldRunLoadMetaForProduct { 
	my $productName = shift; 

	return grep { $productName eq $_ } (
		ariba::rc::Globals::sharedServiceSourcingProducts(), 
		ariba::rc::Globals::sharedServiceBuyerProducts(), 
		qw(s2 cdbuyer), 
		); 
}

#
# run loadmeta command if needed. return 0 on failure and 1 on success
#
sub runLoadMeta {
	my $me = shift;
	my $masterPassword = shift;
	my $fullStart = shift;
    my $cluster = shift;
    my $plannedDR = shift;

	my $releaseName = $me->releaseName();
	my $name = $me->name();

	# for other products there is no need to do loadmeta
	return 1 unless (shouldRunLoadMetaForProduct($name));

	my $lockFile = ariba::Ops::Startup::Common::loadmetaLock($me);
	my $successMarkerFile = ariba::Ops::Startup::Common::loadmetaSuccessMarker($me);
	my $failureMarkerFile = ariba::Ops::Startup::Common::loadmetaFailureMarker($me);

	#
	# Check to see if loadmeta has already been run.
	# return the right status.
	#
	if (-f $successMarkerFile) {
		return 1;
	}
	if (-f $failureMarkerFile) {
		return 0;
	}

	# now construct loadmeta command and launch it
	my $buildName = $me->buildName();
	my $installDir = ($me->isASPProduct() ? $me->baseInstallDir() : $me->installDir());
	my $logFile = "loadmeta.$buildName";
	my $initLogFile = "clusterinit.$buildName";
	my $hostname = ariba::Ops::NetworkUtils::hostname();

	my $command = "$installDir/bin/initdb -loadmeta -realmids 0 -buildName $buildName -logFile $logFile -overrideMainFileDisable -readMasterPassword";

	my $numCommunities = $me->numCommunities();

	if ($fullStart && -e "$installDir/bin/initcluster") {
        $command .= " -initcluster -numOfCommunities $numCommunities";        
	}
    if (defined($cluster)) {
       $command .= " -cluster $cluster"; 
    }    
    if ($plannedDR) {
        $command .= " -plannedDR";
    }
    
	#
	# check for lockfiles if run from active terminal.
	#
	if( -t STDIN && -t STDOUT && -e $lockFile ) {
		print "=============================================================\n";
		print "=============================================================\n";
		print "The lock file $lockFile exists which means one of two things:\n";
		print "\n";
		print "1) There is a stale lockfile which may prevent startup from\n";
		print "   succeeding.\n";
		print "2) A rolling upgrade or install is occuring now.\n";
		print "\n";
		print "You need to clear the lock file in the former case before you\n";
		print "run startup by hand.  In the latter case, you don't want to be\n";
		print "running startup at all.\n";
		print "=============================================================\n";
		print "=============================================================\n";
		exit(ariba::Ops::Startup::Common::EXIT_CODE_ABORT());
	}

	#
	# Grab lock to run loadmeta, wait for upto 30 mins to acquire lock
	#
	ariba::Ops::Startup::Common::mkdirRecursively(dirname($lockFile));
	if (dmail::LockLib::requestlock($lockFile, 7200, $hostname)) {
		#
		# Check to see if loadmeta has already been run.
		# return the right status.
		#
		if (-f $successMarkerFile) {
			dmail::LockLib::releaselock($lockFile);
			return 1;
		}

		if (-f $failureMarkerFile) {
			dmail::LockLib::releaselock($lockFile);
			return 0;
		}

		# Run loadmeta command
		my $ret = ariba::Ops::Startup::Common::runCommandAndFeedMasterPassword($command, $masterPassword);

		# record return status via marker files.
		if ($ret) {
			unlink($failureMarkerFile);
			if (open(FL, ">$successMarkerFile")) {
				print FL "Successfully finished loadmeta for $buildName on $hostname at " .  localtime(time), "\n";
				close(FL);
			} else {
				print "Error: Unable to create $successMarkerFile, $!\n";
				$ret = 0;
			}
		} else {
			unlink($successMarkerFile);
			if (open(FL, ">$failureMarkerFile")) {
				print FL "loadmeta finished with errors for $buildName on $hostname at " .  localtime(time), "\n";
				close(FL);
			} else {
				print "Error: Unable to create $failureMarkerFile, $!\n";
				$ret = 0;
			}
		}

		dmail::LockLib::releaselock($lockFile);
		return $ret;
	}

	return 0;
}

1;

__END__
