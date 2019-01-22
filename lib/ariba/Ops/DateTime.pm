package ariba::Ops::DateTime;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/DateTime.pm#10 $

use strict;
use Time::Local;
use Date::Parse;
use DateTime;
use POSIX qw(mktime strftime);

our @validIntervals = qw(15min hour day week month year);

sub timezoneAdjustmentInSeconds {

	my (@epoch) = localtime(0);

	my $tzmin = $epoch[2] * 60 + $epoch[1]; # minutes east of GMT

	my $dst=(localtime)[8];
	$tzmin= $tzmin + $dst * 60;

	if ($tzmin > 0) {
		$tzmin = 24 * 60 - $tzmin;      # minutes west of GMT
		if($epoch[5] == 70){            # for the date line
			$tzmin -= 24 * 60;
		}
	}

	my $tzsecs = $tzmin * 60;

	return $tzsecs;
}

sub computeStartAndEndDate {
	my $time = shift || time;
	my $report = shift;

	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($time);
	$year += 1900;
	$mon++;

	my $endyear = $year;

	# display last months data for the first few days in the new month
	# or in reporting mode
	if ( $mday < 4 || $report ){
		$mon--;
		if ( $mon == 0 ){
			$year--;
		}
	}
	my $nextmon = $mon + 1;
	$mon = 12 if ( $mon == 0 ) ;

	if ( $nextmon == 13 ){
		$nextmon = 1;
		$endyear++;
	}

	#stringfy these

	$mon = "0". $mon if ($mon < 10);
	$mday = "0". $mday if ($mday < 10);
	$nextmon = "0". $nextmon if ($nextmon < 10);

	#return in oracle format for use with between

	my $sDate="$year-$mon-01";    #used as >=
	my $eDate="$endyear-$nextmon-01";    #used as <

	return ($sDate, $eDate);
}

sub oracleToTimestamp {
	my $date = shift;
	my $time;

	($date, $time) = split(/:/, $date, 2);


	my ($y, $mon, $d) = split(/-/, $date);
	my ($h, $min, $s) = ( 0,0,0 );
	if($time) {
		($h, $min, $s) = split(/:/, $time);
	}

	$mon--; # perl uses 0..11 for month

	return(timelocal($s,$min,$h,$d,$mon,$y));
}

sub syslogToTimestamp {
	my $date = shift;

	return Date::Parse::str2time($date);
}

sub yearMonthDayFromTime {
        my $time = shift;

        my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($time);

        return ($year+1900, $mon + 1 ,$mday);
}

sub scaleTime {
	my $time = shift;

	my $retval;

	my @times = qw(31536000 604800 86400 3600 60 1);
	my @names = qw(yrs wks days hrs mins secs);

	if ($time && $time < 0) {
		$retval = '-';
		$time = -$time;
	}

	for (my $i = 0; $i <= $#times; $i++) {

		if (defined($times[$i]) && defined($time) && $time >= $times[$i]) {
			$retval .= sprintf("%d %s", $time / $times[$i], $names[$i]);
			$time %= $times[$i];
		}
	}

	return $retval || '0 secs';
}

sub prettyTime {
	my $time = shift || return 'n/a';

	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($time);

	$year -= 100 if $year > 99;

	sprintf("%04d-%02d-%02d %02d:%02d:%02d",$year+2000,$mon+1,$mday, $hour,$min,$sec);
}

sub prettyTimeForInterval {
	my $time = shift || return 'n/a'; 
	my $interval = shift || return 'n/a'; 

	my $prettierFmt = ''; 
	if ($interval =~ /year/) {
		$prettierFmt = '%Y'; 
	} elsif ($interval =~ /month/) {
		$prettierFmt = '%B %Y'; 
	} else {
		$prettierFmt = '%a %b %e';
		if ($interval =~ /hour|15min/) {
			$prettierFmt .= ' %l';
			$prettierFmt .= ':%M' if ($interval =~ /15min/); 
			$prettierFmt .= '%P';
		}
	}
	
	return strftime($prettierFmt, localtime($time));
}

sub prettyDate {
	my $time = shift || return 'n/a';

	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($time);

	$year -= 100 if $year > 99;

	sprintf("%04d-%02d-%02d",$year+2000,$mon+1,$mday);
}

sub datestamp {
	my $time = shift || time();

	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($time);

	sprintf("%04d%02d%02d%02d%02d%02d",$year+1900,$mon+1,$mday, $hour,$min,$sec);
}

sub timeForDatestamp {
	my $datestamp = shift;
	my $time;

	# yyyymmddhhmmss
	if ($datestamp && $datestamp =~ /(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})/) {
		my ($year, $month, $day, $hour, $min, $sec) = ($1, $2, $3, $4, $5, $6); 
		$time = str2time("$year-$month-$day $hour:$min:$sec");
	}

	return $time;
}

sub timesForTimeAndInterval {
	my $time = shift;
	my $interval = shift; 

	return timesForTimeIntervalAndCount($time, $interval, 1);
}

sub timesForTimeIntervalAndCount {
	my $time = shift;
	my $interval = shift; 
	my $count = shift;

	return unless $time && isValidInterval($interval);

	my $dt = DateTime->from_epoch(epoch => $time, time_zone => 'America/Los_Angeles');

	# Adjust time back an interval if prefixed with 'prev-' or 'next-'
	if ($interval =~ /^(prev|next)(\d+)?-(.*)$/) {
		my $direction = $1;
		my $multiplier = $2 || 1;
		$interval = $3; 
		$multiplier *= -1 if ($direction eq 'prev');

		if ($interval eq '15min') {
			$dt->add(minutes => 15 * $multiplier);
		} elsif ($interval eq 'hour') {
			$dt->add(hours => $multiplier);
		} elsif ($interval eq 'day') {
			$dt->add(days => $multiplier);
		} elsif ($interval eq 'week') {
			$dt->add(days => 7 * $multiplier);
		} elsif ($interval eq 'month') {
			$dt->add(months => $multiplier);
		} elsif ($interval eq 'year') {
			$dt->add(years => $multiplier);
		}
	}

	my ($startTime, $endTime);
	
	if ($interval eq '15min') {
		my $min = $dt->minute();
		if ($min < 15) {
			$min = 0;
		} elsif ($min < 30) {
			$min = 15; 
		} elsif ($min < 45) {
			$min = 30; 
		} elsif ($min < 60) {
			$min = 45; 
		} 
		$dt->set(second => 0, minute => $min); 
		$startTime = $dt->epoch(); 
		$dt->add(minutes => 15 * $count); 
		$endTime = $dt->epoch();
	} elsif ($interval eq 'hour') {
		$dt->set(second => 0, minute => 0); 
		$startTime = $dt->epoch(); 
		$dt->add(hours => $count); 
		$endTime = $dt->epoch();
	} elsif ($interval eq 'day') {
		$dt->set(second => 0, minute => 0, hour => 0); 
		$startTime = $dt->epoch(); 
		$dt->add(days => $count); 
		$endTime = $dt->epoch();
	} elsif ($interval eq 'week') {
		$dt->set(second => 0, minute => 0, hour => 0); 
		my $wday = $dt->day_of_week() % 7;
		$dt->subtract(days => $wday);
		$startTime = $dt->epoch(); 
		$dt->add(days => 7 * $count); 
		$endTime = $dt->epoch();
	} elsif ($interval eq 'month') {
		$dt->set(second => 0, minute => 0, hour => 0, day => 1); 
		$startTime = $dt->epoch(); 
		$dt->add(months => $count); 
		$endTime = $dt->epoch();
	} elsif ($interval eq 'year') {
		$dt->set(second => 0, minute => 0, hour => 0, day => 1, month => 1); 
		$startTime = $dt->epoch(); 
		$dt->add(years => $count); 
		$endTime = $dt->epoch();
	}

	return ($startTime, $endTime);
}

sub isValidInterval {
	my $interval = shift; 
	
	$interval =~ s/^(?:prev|next)(?:\d+)?-//;
	return $interval && grep(/^$interval$/, @validIntervals);
}

sub parseDateFromString {
	my $self = shift;
	my $dateString  = shift;

	my $unixtime = Date::Parse::str2time($dateString);
	return undef unless $unixtime;
	return DateTime->from_epoch( epoch => $unixtime );
}

sub isLastWeekOfMonth {
	my $sevenDaysInSeconds = 7 * 24 * 60 * 60;
	my ($mon) = (localtime)[4];
	my ($futureMon) = (localtime(time + $sevenDaysInSeconds))[4];

	if ($mon != $futureMon) {
		return 1;
	} else {
		return 0;
	}
}


1;

__END__
