# $Id: //ariba/services/tools/lib/perl/dmail/LockLib.pm#11 $
# dmail version=16
#
# Translated to perl5 from the version=6 of this library
#

package dmail::LockLib;

use POSIX qw(:errno_h);

my $remoteStaleDetection = 1;
my $outputIsTTY = (-t STDERR);
my %currentlocks;

my %requestsPerResource;
my %triesPerResource;

my $debug = $main::debug;

my $quiet = 0;

sub forceQuiet {
	$quiet = 1;
}

sub removeQuiet {
	$quiet = 0;
}

sub printLockRequestStats {
	my $fd = shift || *STDERR;

	print $fd "    num resources locked: ", scalar(keys(%requestsPerResource)),"\n\n";

	my $totalRequests = 0;
	my $totalTries = 0;

	for my $resource ( keys(%requestsPerResource) ) {
		my $requests = $requestsPerResource{$resource};
		my $tries = $triesPerResource{$resource};

		$totalRequests += $requests;
		$totalTries += $tries;

		print $fd "    for $resource: $tries tries/$requests reqs";
		printf $fd (", avg # tries = %.1f\n", $tries/$requests);
	}

	print $fd "\n    globally: $totalTries tries/$totalRequests reqs";
	printf $fd ( ", avg # tries = %.1f", $totalTries/$totalRequests) if ( $totalRequests );
	print $fd "\n";
}

sub releaseAllLocks {
	releaselock(keys %currentlocks);
}

sub haslock {
	my $resource = shift;

	return exists($currentlocks{$resource});
}

sub releaselock {
	my @resources = @_;
	my $resource;

	foreach $resource (@resources){
		print "Deleting lock ${resource}.lock\n" if $debug;
		#
		# can we safely remove all other .requestlocks's?  no.  we might
		# leave turd files around...
		#
		unlink "${resource}.lock";
		delete $currentlocks{$resource};
	}
	#Hm.  What's a correct return value?
	return 1;
}
#
sub requestlock {
	my ($resource, $ntry, $hostname) = @_;
	my ($oldfd, $oldstate, $tries, $host, $pid);
	local(*LOCK);

	my $NTRIES = $ntry || 10;

	# be backwards compatible with perl4 version that used
	# main::hostname instead of passing it in	
	unless ( $hostname ) {
		if ( defined($main::hostname) ) {
			$hostname = $main::hostname;
		} else {
			$hostname = "";
		}
	}

	my $RSH = $main::mhstate{'rshproc:'} || $main::custom{'rshproc'} || "rsh";
	my $sleep = 0.25;	

	my $once = 1;

	# book keeping
	if ( defined($requestsPerResource{$resource}) ) {
		$requestsPerResource{$resource}++;
		$triesPerResource{$resource}++;
	} else {
		$requestsPerResource{$resource} = 1;
		$triesPerResource{$resource} = 1;
	}

	# add a unique identifier to reduce the possibility of a pid
	# collision in the case where many different processes from
	# different hosts are creating lock requests for the same lock
	my $uniqueRequestId = $$ . int(rand(2**32));
	$uniqueRequestId .= $hostname if ($hostname);

	request: while($once) {
		$once=0;

		$tries=0;
		open(LOCK, "> ${resource}.requestlock$uniqueRequestId") || return undef;
		printf LOCK "%d %s", $$, $hostname;
		close(LOCK);

		# request the lock, using link() as our atomic operation (works over nfs)

		while( ( !link("${resource}.requestlock$uniqueRequestId", "${resource}.lock") ) && $tries++ < $NTRIES ) {

			# more book keeping
			$triesPerResource{$resource}++;

			# failed, but not locked by someone else
			if ($! != EEXIST) {
				print STDERR __PACKAGE__," warning: Couldn't lock $resource - $!\n" unless $quiet;
				unlink "${resource}.requestlock$uniqueRequestId";
				return undef;
			}

			# lock exists.  Is it stale?  Find owner

			open(LOCK,"${resource}.lock") || next;  # if lock fails to open, it might have been removed
													# since we checked, so just try to grab it again.

			($pid, $host) = split(/\s+/o, <LOCK>);
			close(LOCK);

			# there's a chance that the $pid is tainted;
			# we _should_ check that out euid == the owner of 
			# the file.
			# as a somewhat insecure hack we untaint $pid

			$pid =~ /(\d+)/;
			$pid = $1;

			if( $host eq $hostname){
				$! = 0;
		
				# See if process exists using kill( sig == 0 ) trick

				if ( ( (kill 0,$pid) == 0 ) && ( $! != EPERM) ) {
					print STDERR 
						__PACKAGE__," warning: Breaking stale lock for $resource (pid $pid, host $host)\n" unless $quiet;
					if ( -e "${resource}.lock" && !unlink "${resource}.lock" ) {
						print STDERR __PACKAGE__," warning: Couldn't break lock for $resource: $!\n" unless $quiet;
						# something strange happened here, ie a permission problem or
						# transient failure on unlink().  We *continue* through the
						# loop for a few more tries, hoping the problem is fixed
					} else {
						$tries--;
						next;
					}
				}
			}

			# just print interactive warning

			$oldfd = select(STDERR);
			$oldstate = $|;
			$| = 1;
			print STDERR "$resource busy (pid $pid, host $host, $tries)...\r" if $outputIsTTY && !$quiet;
			$| = $oldstate;
			select($oldfd);

			select(undef, undef, undef, $sleep );
		}

		unlink "${resource}.requestlock$uniqueRequestId";

		if ( $tries >= $NTRIES ) {
			# we don't have the lock

			if( $remoteStaleDetection ){
				if( ( $hostname ne $host ) && ($host ne "") ){
					print __PACKAGE__," debug: remote stale lock detection on for $host via $RSH\n" if $debug;

					system("$RSH $host lock-unlock $resource");

					#XXX MUST return result from lock-unlock
					#or just test if the lock is still there :-)

					if( -f "${resource}.lock" ){
						return undef;
					}else{
						redo request; 
					}
				}
			}

			print STDERR __PACKAGE__," warning: $resource in use, try again later\n" unless $quiet;
			return undef;
		}

		$currentlocks{$resource} = 1;
		print STDERR __PACKAGE__," lock granted for $resource\n" if $debug;
		return 1;
	};
}

#
# this is not safe unless process already has this lock
#
sub updateLockWithCurrentPid {
	my ($resource, $hostname) = shift;

	$hostname = "" unless defined($hostname);

	open(LOCKTMP, "> ${resource}.lock.$$") || return;
	printf LOCKTMP "%d %s", $$, $hostname;
	close(LOCKTMP) || return;;

	rename("${resource}.lock.$$", "${resource}.lock") || return undef;
}

1;
