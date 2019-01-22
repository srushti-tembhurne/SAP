package ariba::Oncall::Schedule_v2;

use strict;
use warnings;

# Read file schedule entries for a specified month.
sub readMonthSchedule {
	my $monthNameAbbrev = $_[0];
	my $year = $_[1];
	my $scheduleHomePath = $_[2];
	my $calMonthDataSuffix = $_[3];

	my @returnArray = ();

	my $dataFile = "$scheduleHomePath/$year/$monthNameAbbrev$calMonthDataSuffix";

	# Return if datafile does not exist.
	unless (-e $dataFile) {
		return @returnArray;
	}

	open my $fh, $dataFile or die "Could not open $dataFile: $!";

	while (my $record = <$fh>) {
		chomp($record);
		$record = trimStr($record);

		# Skip blank lines and comment lines.
		if ( ($record eq '') || ($record =~ m/^#/) ) {
			next;
		}

		my ($dayNum, $team, $tier, $userId, $startTime, $endTime) = split(',', $record);
		$dayNum = trimStr($dayNum);
		$team = trimStr($team);
		$tier = trimStr($tier);
		$userId = trimStr($userId);
		$startTime = trimStr($startTime);
		$endTime = trimStr($endTime);

		my $trimmedRec = "$dayNum,$team,$tier,$userId,$startTime,$endTime";

		push(@returnArray, $trimmedRec);
	}

	close($fh);

	return @returnArray;
}

# Extract schedule entries for a specified day from an array for an entire month.
sub getDaySchedule {
	my $desiredMonthDay = $_[0];
	my @monthSchedule = @{$_[1]};

	my @returnArray = ();

	foreach my $record (@monthSchedule) {
		my ($dayNum, $team, $tier, $userId, $startTime, $endTime) = split(',', $record);

		# Skip days not matching specified day of month.
		if ($dayNum != $desiredMonthDay) {
			next;
		}

		push(@returnArray, $record);
	}

	return @returnArray;
}

# Find on-call person for a specific team for a specific day.
sub findOnCallPerson {
	my $desiredHHMM = $_[0];
	my $desiredTeam = $_[1];
	my @daySchedule = @{$_[2]};

	my $returnStr = '';

	my $lowestTierFound = 9999;
	my $highestStartTimeFound = 0000;
	foreach my $record (@daySchedule) {
		my ($dayNum, $team, $tier, $userId, $startTime, $endTime) = split(',', $record);

		# Skip the entry if specified team does not match.
		if ($team ne $desiredTeam) {
			next;
		}

		# Skip the entry if the current time is not within the entry start and end time.
		if ( ($desiredHHMM < $startTime) || ($desiredHHMM > $endTime) ) {
			next;
		}

		# If a lower number tier is found, then select the entry.
		# Or, if the tier number matches, then select the entry if the start time is equal or greater.
		if ( ($tier < $lowestTierFound) ||
				( ($tier == $lowestTierFound) && ($startTime >= $highestStartTimeFound) ) ) {
			$returnStr = $record;
			$lowestTierFound = $tier;
			$highestStartTimeFound = $startTime;
		}

	}

	return $returnStr;
}

# Calculate prev/next month.
sub changeMonth {
	my $monthNum = $_[0];
	my $year = $_[1];
	my $delta = $_[2];

	my $returnStr = '';

	if ($delta < 0) {
		$monthNum--;
		if ($monthNum < 1) {
			$monthNum = 12;
			$year--;
		}
	}
	elsif ($delta > 0) {
		$monthNum++;
		if ($monthNum > 12) {
			$monthNum = 1;
			$year++;
		}
	}

	$returnStr = "$monthNum~$year";

	return $returnStr;
}

# Trim leading and trailing whitespace from specified string.
sub trimStr {
	my $string = $_[0];

    $string = '' unless $string;

	$string =~ s/^\s+//;
	$string =~ s/\s+$//;
	return $string;
}

sub getCurrYear {
	my $returnStr = `/bin/date "+%Y"`;
	chomp($returnStr);

	return $returnStr;
}

# Get current month number, no leading zeros.
sub getCurrMonthNum {
	my $returnStr = `/bin/date "+%m"`;
	chomp($returnStr);
    $returnStr =~ s/^0*//g;

	return $returnStr;
}

# Get current day of the month, no leading zeros.
sub getCurrMonthDay {
	my $returnStr = `/bin/date "+%d"`;
	chomp($returnStr);
    $returnStr =~ s/^0*//g;

	return $returnStr;
}

sub getCurrTimeHHMM{
	my $returnStr = `/bin/date "+%H%M"`;
	chomp($returnStr);

	return $returnStr;
}

# Write to output to debug file.
sub writeDebug {
	my $record = $_[0];

	my $fileName = '/tmp/show-sched-v2-debug.txt';

	open (OUTFILE, ">>$fileName") or die "Could not open file '$fileName' $!";
	print OUTFILE ("$record");
	close(OUTFILE);
}


sub findOnCallBackup {
	    my $desiredHHMM = $_[0];
        my $desiredTeam = $_[1];
        my @daySchedule = @{$_[2]};

        my $returnStr = '';

        my $lowestTierFound = 9999;
        my $highestStartTimeFound = 0000;
        foreach my $record (@daySchedule) {
                my ($dayNum, $team, $tier, $userId, $startTime, $endTime) = split(',', $record);

                # Skip the entry if specified team does not match.
                if ($team ne $desiredTeam) {
                        next;
                }

                # Skip the entry if the current time is not within the entry start and end time.
                if ( ($desiredHHMM < $startTime) || ($desiredHHMM > $endTime) ) {
                        next;
                }

                # If a lower number tier is found, then select the entry.
                # Or, if the tier number matches, then select the entry if the start time is equal or greater.
                if ( $tier == 2){
                        $returnStr = $userId;
            			last;
                }

        }

        return $returnStr;
}
return 1;
