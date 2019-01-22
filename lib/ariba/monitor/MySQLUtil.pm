# $Id: //ariba/services/monitor/lib/ariba/monitor/MySQLUtil.pm#1 $
package ariba::monitor::MySQLUtil;

use strict;

use Date::Calc;
use DateTime;
use POSIX;

my $debug = 0;

sub alertLogSubsetByTimeRange {
	my $class = shift;
	my $alertLogFileName = shift;
	my $utcStart = shift; #inclusive, UOM = second
	my $utcEnd = shift;   #inclusive, UOM = second

	# If file cannot be read, return undef
	unless ( -r $alertLogFileName ) {
		return;
	}

	unless ( $utcEnd ) {
		$utcEnd = time();
	}

	my $logDataRef = undef;
	my @filteredLogData = ();

	$logDataRef = $class -> _alertLogReadAndNormalizeTimestamp(
															  $alertLogFileName,
															  $utcStart,
															  $utcEnd
															  );

	for my $hLine ( @$logDataRef ) {
		my $utc = $hLine -> {timestampRangeEnd};
		if ( $utcStart <= $utc and $utc <= $utcEnd ) {
			if( $debug ) {
				print($utc . "\t" . $hLine -> {message} . "\n");
			}
			push( @filteredLogData, $hLine );
		}
	}

	return(\@filteredLogData);
}

sub _alertLogReadAndNormalizeTimestamp {
	my $class = shift;
	my $alertLogFileName = shift;
	my $utcStart = shift; #inclusive, UOM = second
	my $utcEnd = shift;   #inclusive, UOM = second

	my $logDataRef = undef;

	print("log file location: $alertLogFileName \n") if $debug;

	$logDataRef = $class -> _alertLogRead($alertLogFileName, $utcStart, $utcEnd);
	$logDataRef = $class -> _alertLogNormalizeTimestamp($logDataRef);

	if ( $debug ) {
		my $i = 0;

		for my $hLine ( @$logDataRef ) {

			my $utc = $hLine -> {timestampRangeEnd};
			if ( $utc ) {
				print($utc . "\t");
			} else {
				print("UNKNOWN###\t");
			}

			print($hLine -> {message} . "\n");

			$i++;
		}
	} # end if debug

	return($logDataRef);
}

sub _alertLogNormalizeTimestamp {
	my $class = shift;
	my $logDataRef = shift;
	my $lastTimestamp = undef;
	my $currentTimeUTC = time();
	my $lastIndexWithTimestamp = -1;
	my $j;
	my $utc = undef;

	my $i = 0;
	for my $hLine ( @$logDataRef ) {

		$utc = $hLine -> {timestamp};
		if ( $utc ) {
#			print($utc . "\t");
			
			$hLine -> {timestampRangeEnd} = $utc;
 
			# event has happend before or at timestampRangeEnd
			# even though we may not know exactly when.

			# if there are any lines without timestamp before. 
			if( $lastIndexWithTimestamp != ($i - 1) ) {
				for (
					 $j = $lastIndexWithTimestamp + 1;
					 $j < $i;
					 $j++ ) {
					$logDataRef -> [$j] -> {timestampRangeEnd} = $utc; 
				}
			}

			$lastIndexWithTimestamp = $i;
		} else {
#			print("UNKNOWN!!!\t");
		}

#		print($hLine -> {message} . "\n");

		$i++;
	}

	# If the last set of data do not contain timestamp
	# populate it with the current timestamp for the range end.

	$utc = $currentTimeUTC;
	if( $lastIndexWithTimestamp != ($i - 1) ) {
		for (
			 $j = $lastIndexWithTimestamp + 1;
			 $j < $i;
			 $j++ ) {
			$logDataRef -> [$j] -> {timestampRangeEnd} = $utc; 
		}
	}

	return($logDataRef);
}

sub _alertLogRead {
	my $class = shift;
	my $alertLogFileName = shift;
	my $utcStart = shift; #inclusive, UOM = second
	my $utcEnd = shift;   #inclusive, UOM = second

	my @rawLogData = ();

	print("log file location: $alertLogFileName \n") if $debug;
	print("scan start range: $utcStart \n") if $debug;
	print("scan end range: $utcEnd \n") if $debug;

	unless ( defined($alertLogFileName) ) {
		warn("alert log file name is not specified.\n");
		return;
	}

    # Open the error log file
	open(LOG, $alertLogFileName) || return undef;

	my $lineCount = 0;
	my $blankLineCount = 0;

    # Loop for each line in the log file and parse
	while (my $line = <LOG>) {

		if ($debug) {
			++$lineCount;
			print "Processing line $lineCount\r" if ($lineCount % 100 == 0);
		}

		if($line =~ m/^$/o) { # skip blank line
			++$blankLineCount;
			next;
		}

		my %hLine = ();

		my ($message, $utcRead) = $class -> decodeLineToDateAndMessage( $line );

 		# If the data is logged before the scan start range, reset the log data
		# This is to keep the rawLogData structure from getting inflated
		# when the error log is huge.
		if( defined($utcRead) and ($utcRead < $utcStart) ) {
			@rawLogData = ();
			next;
		}

		$hLine{message} = $message;
		$hLine{timestamp} = $utcRead;

		push(@rawLogData, \%hLine);

		if( defined($utcRead) and ($utcRead > $utcEnd) ) {
			last;
		}
	}

	if ($debug) {
		print "Processed $lineCount lines\n";
	}

    # Close the log file
	close(LOG);

	return(\@rawLogData);
}

#
# Sample location : /mysql/admin/UTDEV01/errors/UTDEV01.err
#
sub alertLogFilePathForPort {
	my $class = shift;
	my $port = shift;

	my $sid = undef;

	$sid = $class -> getSIDFromConfig($port);
	unless ( $sid ) {
		return;
	}

	# Example: '/mysql/admin/UTDEV01/errors/UTDEV01.err'
	my $logFilePath = '/mysql/admin/' . $sid . '/errors/' . $sid . '.err';

	return($logFilePath);
}

sub getSIDFromConfig {
	my $class = shift;
	my $port = shift;

	my $configPath = '/etc/mysqltab';

	my $sid;

	unless ( -r $configPath ) {
		return;
	}

	# File format
    #  UTDEV01:3306:/mysql/admin/UTDEV01/run/UTDEV01.sock:/mysql/app/mysql-5.1.41

	open FH, $configPath or return;

	my $matchFound = undef;

	while ( <FH> ) {
		my $line = $_;

		$line =~ s/#.*$//;

		chomp($line);

		my ($sidDefined, $portDefined, $socketDefined, $baseDirDefined) = split /:/, $line;
		
		unless ( $sidDefined and $portDefined ) {
			next;
		}

		if (  $port eq $portDefined ) {
			$matchFound = 1;
			$sid = $sidDefined;
			last;
		}
	}

	close FH;

	return($sid);
}

#
# Example of error log:
# 1) With timestamp 
# 091113 11:59:23 [Note] /usr/local/mysql/bin/mysqld: ready for connections.
# 
# 2) Without timestamp
# InnoDB: The first specified data file ./ibdata1 did not exist:
#

# input:
#   a single line from a log 
# returns:
#   an array:
#   [0] : message
#   [1] : epoch time (UTC) if timestamp is found, or undef if timestamp is not found
# 
sub decodeLineToDateAndMessage {
	my $class = shift;
	my $line = shift;

	my @messageAndTimestamp = (undef, undef);

    #
    # The log line may or may not contain a timestamp.
    #
	chomp($line);

	if ($line =~ m/^(\d{6}\s+\d?\d:\d\d\:\d\d)\s+(.*)$/o) { # if the line contains the timestamp
		my $timestampMySQL = $1;
		my $message = $2;

		my $utc = $class -> alertLogDateToUTC($timestampMySQL);

		if( $utc > 0 ) {
			$messageAndTimestamp[1] = $utc;
		} else {
			$messageAndTimestamp[1] = undef;
		}

		$messageAndTimestamp[0] = $message;

	} else { # if the line does not contain a timestamp
		$messageAndTimestamp[0] = $line;
		$messageAndTimestamp[1] = undef;
	}

	return(@messageAndTimestamp);
}

sub alertLogDateToUTC {
	my $class = shift;
	my $dateString = shift();

	#print "Decoding: $dateString\n";
	my ($yearMonthDay, $hourMinSec, $junk) = split(/\s+/, $dateString, 3);
	my $year = substr($yearMonthDay, 0, 2);
	my $month = substr($yearMonthDay, 2, 2);
	my $day = substr($yearMonthDay, 4, 2);

	my ($hour, $min, $sec) = split(/:/, $hourMinSec);

	$year += 2000;

	my $utime = Date::Calc::Mktime($year,$month,$day, $hour,$min,$sec);

	#print "utime = $utime\n";

	#print "date from this utime = " . localtime($utime) . "\n";

	return $utime;
}

sub alertLogUTCToLocalTime {
	my $class = shift;
	my $utc = shift();

	my $timeString = "";

	unless ( defined $utc ) {
		return "";
	}

	$timeString = POSIX::strftime("%a %b %d %Y %H:%M:%S", localtime($utc));

	return $timeString;
}

1;

__END__
