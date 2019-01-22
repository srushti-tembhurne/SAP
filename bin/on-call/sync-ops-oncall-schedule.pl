#!/usr/local/bin/perl

use strict;
use warnings;

use File::Copy qw(copy);
use File::Copy qw(move);
use File::Slurp;

use lib "/usr/local/ariba/lib";
use ariba::Ops::Utils;

#use lib "/home/monprod/mon-sre/show-schedule-v2";
#use Schedule_v2;
#use lib "/home/monprod/lib/ariba/Oncall";
#use Schedule_v2;

use FindBin;
use lib "$FindBin::Bin/../../lib";
use ariba::Oncall::Schedule_v2;

#my $scheduleHomePath = '/home/svcops/on-call/schedule';
#my $userDataPath = '/home/svcops/on-call/people';

my $scheduleHomePath = '';
my $userDataPath = '';
my $outputHomePath = '';
my $desiredYear = '';
my $desiredMonthNum = '';
my $errorEmail = '';

my $V2_DATA_SUFFIX = '-v2';

my $V1_SRE_SHIFT1_TIER1 = '1';
my $V1_SRE_SHIFT1_TIER2 = 'a';
my $V1_SRE_SHIFT2_TIER1 = '2';
my $V1_SRE_SHIFT2_TIER2 = 'b';
my $V1_SRE_SHIFT3_TIER1 = '3';
my $V1_SRE_SHIFT3_TIER2 = 'c';

my $V1_DBA_TEAM = 'd';
my $V1_NETWORK_TEAM = 'n';
my $V1_SYSADMIN_TEAM = 's';
my $V1_TOOLS_TEAM = 't';
my $V1_DEPLOY_TEAM = 'z';
my $V1_OUT_TEAM = 'out';

my $V2_DBA_TEAM = 'DBA';
my $V2_DEPLOY_TEAM = 'DEP';
my $V2_NETWORK_TEAM = 'NET';
my $V2_SRE_TEAM = 'SRE';
my $V2_SYSADMIN_TEAM = 'SYS';
my $V2_TOOLS_TEAM = 'TLS';
my $V2_OUT_TEAM = 'OUT';

my $SRE_SHIFT1_START = '1000';
my $SRE_SHIFT1_END = '1759';
my $SRE_SHIFT2_START1 = '1800';
my $SRE_SHIFT2_END1 = '2400';
my $SRE_SHIFT2_START2 = '0000';
my $SRE_SHIFT2_END2 = '0159';
my $SRE_SHIFT3_START = '0200';
my $SRE_SHIFT3_END = '0959';

my %MONTH_NUM_HASH = (1 =>  'Jan', 2 =>  'Feb', 3 =>  'Mar', 4 =>  'Apr', 5 =>  'May', 6 =>  'Jun',
					7 =>  'Jul', 8 =>  'Aug', 9 =>  'Sep', 10 => 'Oct', 11 => 'Nov', 12 => 'Dec',
);

my $STOP_NOTICE = <<END;
#
# STOP!
# STOP! Do not edit this file which was obsolete as of 12Aug2014. Edit the '-v2' version instead.
# STOP! This file is now auto-generated via a script, any manual changes made to this file will be lost.
# STOP!
#
END

# This script performs the following tasks:
#   - Parses the data file for current month and updates the data file
#     for the v1 schedule, i.e., keeps the data files in sync since
#     there is other monitoring code that depends on the v1 data file format.
#
#   - Sample data to be generated matching the data format of the v1 schedule:
#
#     1 1=mishah, 2=asaproo, 3=plenka, a=acaruana, b=smishra, c=bramnath, n=pnoganihal, t=mkandel, d=dbaoncall, s=thdonnelly, z=deployment-oncall # out, asyed
#     2 1=ttong, 2=asaproo, 3=bramnath, a=mishah, b=nratnakaram, c=avalipe, n=pnoganihal, t=nsullivan, d=dbaoncall, s=thdonnelly, z=deployment-oncall # out, asyed
#     3 1=ttong, 2=smishra, 3=avalipe, a=eustaris, b=nratnakaram, c=plenka, n=ckirkman, t=nsullivan, d=dbaoncall, s=kvenkatesan, z=deployment-oncall # Level3 ISP maint EU, out, asyed
#     4 1=ttong, 2=asaproo, 3=bramnath, a=mishah, b=nratnakaram, c=avalipe, n=ckirkman, t=nsullivan, d=dbaoncall, s=kvenkatesan, z=deployment-oncall # out, smishra, asyed

sub usage {
        my $helpText = <<EOD;

Usage: $0 -s <source_path> -u <user_data_path> [-o <output_path>] [-y <desired_year>] [-m <desired_month>] [-e <error_email>] [-h]

This script creates a report showing page alerts received
for specified dates.

The following options must specified:
  -s source path containing input data file
  -u path location where user data is stored

The following options can be specified:
  -h for this help
  -o output path where sync file will be saved, default is source path
     example for Aug 2014, this script will try to save file as '/tmp/2014/aug'
     if '/tmp' is specified, thus ensure that '2014' sub-dir exists
  -y desired year
  -m desired month number
  -e email address to send error notifications
EOD

        print "Error: $_[0]\n" if $_[0];
        print "$helpText\n";
        exit(1);
}

sub main {
	while (my $arg = shift(@ARGV)) {
		if ($arg =~ /^-h/o) { usage();}
		if ($arg =~ /^-s/o) { $scheduleHomePath = shift(@ARGV); next; }
		if ($arg =~ /^-u/o) { $userDataPath = shift(@ARGV); next; }
		if ($arg =~ /^-o/o) { $outputHomePath = shift(@ARGV); next; }
		if ($arg =~ /^-y/o) { $desiredYear = shift(@ARGV); next; }
		if ($arg =~ /^-m/o) { $desiredMonthNum = shift(@ARGV); next; }
		if ($arg =~ /^-e/o) { $errorEmail = shift(@ARGV); next; }
	}

	&usage() unless ($scheduleHomePath);
	&usage() unless ($userDataPath);

	$outputHomePath = $scheduleHomePath if ($outputHomePath eq '');
	$desiredYear = ariba::Oncall::Schedule_v2::getCurrYear() if ($desiredYear eq '');
	$desiredMonthNum = ariba::Oncall::Schedule_v2::getCurrMonthNum() if ($desiredMonthNum eq '');

	syncScheduleData($scheduleHomePath, $userDataPath, $outputHomePath, $desiredMonthNum, $desiredYear, $errorEmail);
}

#-------------------------------------------------------------------------------
# Subroutines.

# Sync data from v2 schedule to v1 schedule for specified month and year.
sub syncScheduleData {
	my $scheduleHomePath = $_[0];
	my $userDataPath = $_[1];
	my $outputHomePath = $_[2];
	my $desiredMonthNum = $_[3];
	my $desiredYear = $_[4];
	my $errorEmail = $_[5];

	my $monthAbbrev = lc($MONTH_NUM_HASH{$desiredMonthNum});
	my $v2DataFile = "$scheduleHomePath/$desiredYear/$monthAbbrev$V2_DATA_SUFFIX";
	my $v1DataFile = "$outputHomePath/$desiredYear/$monthAbbrev";

	# Ensure v2 data file exists.
	if ( (! -e $v2DataFile) && ($errorEmail ne '') ) {
		sendEmail($errorEmail, "Ops schedule", "Missing v2 data file: $v2DataFile");
		return;
	}

	saveOriginalV1Schedule($v1DataFile);

	# Initialize v1 month schedule output string.
	my $v1MonthSchedStr = '';

	my @v2MonthSchedule = ariba::Oncall::Schedule_v2::readMonthSchedule($monthAbbrev, $desiredYear, $scheduleHomePath, $V2_DATA_SUFFIX);
	my $currYear = ariba::Oncall::Schedule_v2::getCurrYear();
	my $currMonthNum = ariba::Oncall::Schedule_v2::getCurrMonthNum();
	my $currMonthDay = ariba::Oncall::Schedule_v2::getCurrMonthDay();
	my $currHHMM = ariba::Oncall::Schedule_v2::getCurrTimeHHMM();

	# Get last day of desired month.
	my $lastMonthDay = `/bin/echo \$(/usr/bin/cal $desiredMonthNum $desiredYear) | /usr/bin/awk '{print \$NF}'`;
	chomp($lastMonthDay);

	for (my $calMonthDay = 1; $calMonthDay <= $lastMonthDay; $calMonthDay++) {
		$v1MonthSchedStr .= "$calMonthDay ";
		my @v2DaySchedule = ariba::Oncall::Schedule_v2::getDaySchedule($calMonthDay, \@v2MonthSchedule);

		# Get SRE schedule for the three shifts for each day.
		# Monitoring sends notices to SRE for upcoming shifts.
		# Monitoring send notices for missing OCR report for past shifts. ???
		$_ = getSreDayScheduleStr($scheduleHomePath, $desiredMonthNum, $desiredYear, $calMonthDay, $lastMonthDay, \@v2DaySchedule, \@v2MonthSchedule);
		$v1MonthSchedStr .= "$_";

#		# For all teams other than SRE, only show who is currently on-call for the current day.
#		# Ignore other days since there would not be any appropriate user to display as there
#		# could be multiple users on the schedule for the day.
#		if ( ($desiredYear == $currYear) && ($desiredMonthNum == $currMonthNum) && ($calMonthDay == $currMonthDay) ) {
#		}

		my $onCallEntry;
		my ($dayNum, $team, $tier, $userId, $startTime, $endTime);

		# Get DBA on-call.
		$onCallEntry = ariba::Oncall::Schedule_v2::findOnCallPerson($currHHMM, $V2_DBA_TEAM, \@v2DaySchedule);
		($dayNum, $team, $tier, $userId, $startTime, $endTime) = split(',', $onCallEntry);
#		# Include entry only if people db entry exists.
#		if (-e "$userDataPath/$userId") {
#			$v1MonthSchedStr .= ", $V1_DBA_TEAM=$userId";
#		}
		$v1MonthSchedStr .= ", $V1_DBA_TEAM=$userId";

		# Get Network on-call.
		$onCallEntry = ariba::Oncall::Schedule_v2::findOnCallPerson($currHHMM, $V2_NETWORK_TEAM, \@v2DaySchedule);
		($dayNum, $team, $tier, $userId, $startTime, $endTime) = split(',', $onCallEntry);
		$v1MonthSchedStr .= ", $V1_NETWORK_TEAM=$userId";

		# Get Sysadmin on-call.
		$onCallEntry = ariba::Oncall::Schedule_v2::findOnCallPerson($currHHMM, $V2_SYSADMIN_TEAM, \@v2DaySchedule);
		($dayNum, $team, $tier, $userId, $startTime, $endTime) = split(',', $onCallEntry);
		$v1MonthSchedStr .= ", $V1_SYSADMIN_TEAM=$userId";

		# Get Tools on-call.
		$onCallEntry = ariba::Oncall::Schedule_v2::findOnCallPerson($currHHMM, $V2_TOOLS_TEAM, \@v2DaySchedule);
		($dayNum, $team, $tier, $userId, $startTime, $endTime) = split(',', $onCallEntry);
		$v1MonthSchedStr .= ", $V1_TOOLS_TEAM=$userId";

		# Get Deployment on-call.
		$onCallEntry = ariba::Oncall::Schedule_v2::findOnCallPerson($currHHMM, $V2_DEPLOY_TEAM, \@v2DaySchedule);
		($dayNum, $team, $tier, $userId, $startTime, $endTime) = split(',', $onCallEntry);
		$v1MonthSchedStr .= ", $V1_DEPLOY_TEAM=$userId";

		# Get list of users out of office.
		$onCallEntry = ariba::Oncall::Schedule_v2::findOnCallPerson($currHHMM, $V2_DEPLOY_TEAM, \@v2DaySchedule);
		$_ = getUserOutList($currHHMM, $V2_OUT_TEAM, \@v2DaySchedule);
		$v1MonthSchedStr .= " # $V1_OUT_TEAM$_\n";
	}

	$v1MonthSchedStr = $STOP_NOTICE . $v1MonthSchedStr . $STOP_NOTICE;
#	print "$v1MonthSchedStr";

	updateV1Schedule($v1DataFile, $v1MonthSchedStr);
}

# Create an original backup of the specified schedule if it does not exist yet.
sub saveOriginalV1Schedule {
	my $dataFile = $_[0];

	my $dataFileBackup = "$dataFile.orig";

	# Do not do anything if backup file already exists.
	if (-e "$dataFileBackup") {
		return;
	}

	copy("$dataFile", "$dataFileBackup");
	chmod(0444, "$dataFileBackup");
}

# Update the contents of the specified datafile.
sub updateV1Schedule {
	my $dataFile = $_[0];
	my $monthScheduleStr = $_[1];

	my $dataFileNew = "$dataFile.new";
	my $dataFileBackup = "$dataFile.bak";

	# Write schedule to new temp datafile.
	open (OUTFILE, ">$dataFileNew") or die "Could not open file '$dataFileNew' $!";
	print OUTFILE ("$monthScheduleStr");
	close(OUTFILE);

	# If existing file does not exist, then simply create it.
	if (! -e $dataFile) {
		move($dataFileNew, $dataFile);
		return;
	}

	# Check if new datafile is different from existing data file.
	my $diffResult = `/usr/bin/diff -q $dataFileNew $dataFile`;
    chomp($diffResult);
	if ($diffResult eq '') {
#		print "No diffs found\n";
		return;
	}

	copy("$dataFile", "$dataFileBackup");
	move($dataFileNew, $dataFile);
}

# Get SRE schedule for specified day.
sub getSreDayScheduleStr {
	my $scheduleHomePath = $_[0];
	my $desiredMonthNum = $_[1];
	my $desiredYear = $_[2];
	my $calMonthDay = $_[3];
	my $lastMonthDay = $_[4];
	my @v2DaySchedule = @{$_[5]};
	my @v2MonthSchedule = @{$_[6]};

	my $returnStr = '';

	my $shift1Tier1Oncall = '';
	my $shift1Tier2Oncall = '';
	my $shift2Tier1Oncall = '';
	my $shift2Tier2Oncall = '';
	my $shift3Tier1Oncall = '';
	my $shift3Tier2Oncall = '';

	my $desiredHHMM;
	my $desiredTier;
	my $onCallEntry;
	my ($dayNum, $team, $tier, $userId, $startTime, $endTime);

	my $currYear = ariba::Oncall::Schedule_v2::getCurrYear();
	my $currMonthNum = ariba::Oncall::Schedule_v2::getCurrMonthNum();
	my $currMonthDay = ariba::Oncall::Schedule_v2::getCurrMonthDay();
	my $currHHMM = ariba::Oncall::Schedule_v2::getCurrTimeHHMM();

	# Need to retrieve schedule for next day since 2nd shift rolls into next day,
	# 3rd shift starts at 2:00 am next day.
	my @v2TomorrowSchedule;

	# Use current month schedule as long as it's not the last day of the month.
	if ($calMonthDay < $lastMonthDay) {
		@v2TomorrowSchedule = ariba::Oncall::Schedule_v2::getDaySchedule( ($calMonthDay + 1), \@v2MonthSchedule);
	}
	else {
		# Retrieve the schedule for the next month and use the first day.
		my ($nextMonthNum, $nextYear) = split('~', ariba::Oncall::Schedule_v2::changeMonth($desiredMonthNum, $desiredYear, +1) );
		my $nextMonthAbbrev = lc($MONTH_NUM_HASH{$nextMonthNum});
		my @v2NextMonthSchedule = ariba::Oncall::Schedule_v2::readMonthSchedule($nextMonthAbbrev, $nextYear, $scheduleHomePath, $V2_DATA_SUFFIX);
		@v2TomorrowSchedule = ariba::Oncall::Schedule_v2::getDaySchedule(1, \@v2NextMonthSchedule);
	}

	# Get SRE shift 1 info --------------------------------------------------------
	$desiredHHMM = $SRE_SHIFT1_START;

	# Use current time if it falls within SRE shift1.
	if ( ($currHHMM >= $SRE_SHIFT1_START) && ($currHHMM <= $SRE_SHIFT1_END) ) {
#		$desiredHHMM = $currHHMM;
	}

	# Get SRE on-call, shift 1, tier-1.
	$desiredTier = '1';
	$onCallEntry = findOnCallTierPerson($desiredHHMM, $V2_SRE_TEAM, $desiredTier, \@v2DaySchedule);
	($dayNum, $team, $tier, $userId, $startTime, $endTime) = split(',', $onCallEntry);
#	# Include entry only if people db entry exists.
#	if (-e "$userDataPath/$userId") {
#		$shift1Tier1Oncall = $userId;
#	}
	$shift1Tier1Oncall = $userId;

	# Get SRE on-call, shift-1, tier-2.
	$desiredTier = '2';
	$onCallEntry = findOnCallTierPerson($desiredHHMM, $V2_SRE_TEAM, $desiredTier, \@v2DaySchedule);
	($dayNum, $team, $tier, $userId, $startTime, $endTime) = split(',', $onCallEntry);
	$shift1Tier2Oncall = $userId;

	# Get SRE shift 2 info --------------------------------------------------------
	$desiredHHMM = $SRE_SHIFT2_START1;

#	# Use current time if it falls within SRE shift2.
#	if ( 
#		(($desiredMonthNum == $currMonthNum) && ($desiredYear == $currYear))
#		&&
#		(
#		(($currHHMM >= $SRE_SHIFT2_START1) && ($currHHMM <= $SRE_SHIFT2_END1)) ||
#		(($currHHMM >= $SRE_SHIFT2_START2) && ($currHHMM <= $SRE_SHIFT2_END2))
#		)
#		) {
#			$desiredHHMM = $currHHMM;
#	}

	# Get SRE on-call, shift 2, tier-1.
	$desiredTier = '1';
	$onCallEntry = findOnCallTierPerson($desiredHHMM, $V2_SRE_TEAM, $desiredTier, \@v2DaySchedule);
	($dayNum, $team, $tier, $userId, $startTime, $endTime) = split(',', $onCallEntry);
	$shift2Tier1Oncall = $userId;

	# Get SRE on-call, shift-2, tier-2.
	$desiredTier = '2';
	$onCallEntry = findOnCallTierPerson($desiredHHMM, $V2_SRE_TEAM, $desiredTier, \@v2DaySchedule);
	($dayNum, $team, $tier, $userId, $startTime, $endTime) = split(',', $onCallEntry);
	$shift2Tier2Oncall = $userId;

	# Get SRE shift 3 info --------------------------------------------------------
	$desiredHHMM = $SRE_SHIFT3_START;

	# Use current time if it falls within SRE shift3.
	if ( ($currHHMM >= $SRE_SHIFT3_START) && ($currHHMM <= $SRE_SHIFT3_END) ) {
			$desiredHHMM = $currHHMM;
	}

	# Get SRE on-call, shift-3, tier-1.
	$desiredTier = '1';
	$onCallEntry = findOnCallTierPerson($desiredHHMM, $V2_SRE_TEAM, $desiredTier, \@v2TomorrowSchedule);
	($dayNum, $team, $tier, $userId, $startTime, $endTime) = split(',', $onCallEntry);
	$shift3Tier1Oncall = $userId;

	# Get SRE on-call, shift-3, tier-2.
	$desiredTier = '2';
	$onCallEntry = findOnCallTierPerson($desiredHHMM, $V2_SRE_TEAM, $desiredTier, \@v2TomorrowSchedule);
	($dayNum, $team, $tier, $userId, $startTime, $endTime) = split(',', $onCallEntry);
	$shift3Tier2Oncall = $userId;

	$returnStr  = "$V1_SRE_SHIFT1_TIER1=$shift1Tier1Oncall";
	$returnStr .= ", $V1_SRE_SHIFT2_TIER1=$shift2Tier1Oncall";
	$returnStr .= ", $V1_SRE_SHIFT3_TIER1=$shift3Tier1Oncall";
	$returnStr .= ", $V1_SRE_SHIFT1_TIER2=$shift1Tier2Oncall";
	$returnStr .= ", $V1_SRE_SHIFT2_TIER2=$shift2Tier2Oncall";
	$returnStr .= ", $V1_SRE_SHIFT3_TIER2=$shift3Tier2Oncall";

	return $returnStr;
}

# Find on-call backup person for a specific team, tier, and day.
sub findOnCallTierPerson {
	my $desiredHHMM = $_[0];
	my $desiredTeam = $_[1];
	my $desiredTier = $_[2];
	my @daySchedule = @{$_[3]};

	my $returnStr = '';

	my $highestStartTimeFound = 0000;
	foreach my $record (@daySchedule) {
		my ($dayNum, $team, $tier, $userId, $startTime, $endTime) = split(',', $record);

		# Skip the entry if specified team or tier does not match.
		if ( ($team ne $desiredTeam) || ($tier ne $desiredTier) ) {
			next;
		}

		# Skip the entry if the current time is not within the entry start and end time.
		if ( ($desiredHHMM < $startTime) || ($desiredHHMM > $endTime) ) {
			next;
		}

		# If a lower number tier is found, then select the entry.
		# Or, if the tier number matches, then select the entry if the start time is equal or greater.
		if ($startTime >= $highestStartTimeFound) {
			$returnStr = $record;
			$highestStartTimeFound = $startTime;
		}

	}

	return $returnStr;
}

# Get list of people that are out.
sub getUserOutList {
	my $desiredHHMM = $_[0];
	my $desiredTeam = $_[1];
	my @daySchedule = @{$_[2]};

	my $returnStr = '';

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

		$returnStr .= ",$userId";
	}

	return $returnStr;
}

sub sendEmail {
	my $to = $_[0];
	my $subject = $_[1];
	my $body = $_[2];

	my $from = 'nobody@ariba.com';
	my $replyto = $from;
	my $cc;

	ariba::Ops::Utils::email($to, $subject, $body, $cc, $from, $replyto);
}

main();

__END__