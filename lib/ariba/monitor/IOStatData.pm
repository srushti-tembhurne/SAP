#!/usr/local/bin/perl
#
# $Id: //ariba/services/monitor/lib/ariba/monitor/IOStatData.pm#3 $
#
package ariba::monitor::IOStatData;
use strict;

use base qw(ariba::Ops::PersistantObject);

sub dir {
	return undef;
}

sub save {
	return undef;
}

sub recursiveSave {
	return undef;
}

sub remove {
	return undef;
}

my %headersToKeys = (
	'rrqm/s' => 'mergedReadRequestsQueuedPerSecond',
	'wrqm/s' => 'mergedWriteRequestsQueuedPerSecond',
	'r/s' => 'readRequestsPerSecond',
	'w/s' => 'writeRequestsPerSecond',
	'rsec/s' => 'sectorsReadPerSecond',
	'wsec/s' => 'sectorsWrittenPerSecond',
	'rkB/s' => 'kilobytesReadPerSecond',
	'wkB/s' => 'kilobytesWrittenPerSecond',
	'avgrq-sz' => 'averageSectorSizeOfRequests',
	'avgqu-sz' => 'averageRequestQueueLength',
	'await' => 'averageWaitTimeForRequests',
	'svctm' => 'averageServiceTimeForRequests',
	'qtime' => 'averageQueueTimeForRequests',
	'%util' => 'percentUtilization',
);

my %aggregationMethod = (
	'mergedReadRequestsQueuedPerSecond' => \&sum,
	'mergedWriteRequestsQueuedPerSecond' => \&sum,
	'readRequestsPerSecond' => \&sum,
	'writeRequestsPerSecond' => \&sum,
	'sectorsReadPerSecond' => \&sum,
	'kilobytesReadPerSecond' => \&sum,
	'kilobytesWrittenPerSecond' => \&sum,
	'sectorsWrittenPerSecond' => \&sum,
	'averageSectorSizeOfRequests' => \&max,
	'averageRequestQueueLength' => \&max,
	'averageWaitTimeForRequests' => \&max,
	'averageServiceTimeForRequests' => \&max,
	'percentUtilization' => \&max,
);

my %unitsForField = (
	'mergedReadRequestsQueuedPerSecond' => "requests",
	'mergedWriteRequestsQueuedPerSecond' => "requests",
	'readRequestsPerSecond' => "requests/second",
	'writeRequestsPerSecond' => "requests/second",
	'sectorsReadPerSecond' => "sectors/second",
	'kilobytesReadPerSecond' => "kB/second",
	'kilobytesWrittenPerSecond' => "kB/second",
	'megabitsReadPerSecond' => "Mb/second",
	'megabitsWrittenPerSecond' => "Mb/second",
	'sectorsWrittenPerSecond' => "sectors/second",
	'averageSectorSizeOfRequests' => "sectors",
	'averageRequestQueueLength' => "requests",
	'averageWaitTimeForRequests' => "milliseconds",
	'averageServiceTimeForRequests' => "milliseconds",
	'averageQueueTimeForRequests' => "milliseconds",
	'percentUtilization' => "percent",
);

sub unitsForField {
	my $class = shift;
	my $field = shift;

	return($unitsForField{$field});
}

my %prettyNamesForField = (
	'mergedReadRequestsQueuedPerSecond' => 'Merged Read Requests Queued Per Second',
	'mergedWriteRequestsQueuedPerSecond' => 'Merged Write Requests Queued Per Second',
	'readRequestsPerSecond' => 'Read Requests Per Second',
	'writeRequestsPerSecond' => 'Write Requests Per Second',
	'sectorsReadPerSecond' => 'Sectors Read Per Second',
	'kilobytesReadPerSecond' => 'Kilobytes Read Per Second',
	'kilobytesWrittenPerSecond' => 'Kilobytes Written Per Second',
	'megabitsReadPerSecond' => 'read Mb/sec',
	'megabitsWrittenPerSecond' => 'write Mb/sec',
	'sectorsWrittenPerSecond' => 'Sectors Written Per Second',
	'averageSectorSizeOfRequests' => 'Average Sector Size Of Requests',
	'averageRequestQueueLength' => 'Average Request Queue Length',
	'averageWaitTimeForRequests' => 'Average Wait Time For Requests (in milliseconds)',
	'averageServiceTimeForRequests' => 'Average Service Time For Requests (in milliseconds)',
	'averageQueueTimeForRequests' => 'Average Queue Time For Requests (in milliseconds)',
	'percentUtilization' => 'Percent Utilization',
);

sub new {
	my $class = shift;
	my $disk = shift;

	die "need disk in constructor" unless($disk);

	my $self = $class->SUPER::new($disk);

	return $self;
}

sub dataFields {
	my $class = shift;

	return(sort(values(%headersToKeys)));
}

sub prettyNameForField {
	my $class = shift;
	my $field = shift;

	return($prettyNamesForField{$field});
}

sub recordData {
	my $self = shift;
	my $headerStr = shift;
	my @valueStrs = (@_);
	my %arrays;
	my $invalid = 0;

	my @headers = split(/\s+/, $headerStr);

	foreach my $str (@valueStrs) {
		my @v = split(/\s+/, $str);
		for(my $i=0; $i < $#v; $i++) {
			#
			# XXX -- iostat occasionally will return a completely off the
			# wall result, way beyond what any sane value could be.  
			#
			# The calling code will discard this data when we see that.
			#
			# We are using string length to check this because these bogus
			# values are large enough to overflow integers, and might not
			# numerically compare as expected.
			#
			my $str = $v[$i];
			$str =~ s/\.\d+$//;
			$invalid = 1 if(length($str) > 10);

			push(@{$arrays{$headers[$i]}}, $v[$i]);
		}
	}

	foreach my $h (@headers) {
		next if($h =~ /Device:/); # this is redundant;

		my $field = $headersToKeys{$h};
		next unless $field;
		my $aggregator = $aggregationMethod{$field};
		my $value = &$aggregator(@{$arrays{$h}});
		$value = sprintf("%.3f",$value);

		$self->setAttribute($field, $value);
	}

	return($invalid);
}

sub sum {
	my @arr = (@_);
	my $ret=0;

	foreach my $i (@arr) {
		$ret += $i;
	}

	return($ret);
}

sub average {
	my @arr = (@_);
	my $sum=0;
	my $count=0;

	foreach my $i (@arr) {
		$sum += $i;
		$count++;
	}

	return($sum / $count);
}

sub max {
	my @arr = (@_);
	my $ret = 0;

	foreach my $i (@arr) {
		$ret = $i if($i > $ret);
	}

	return($ret);
}

#
# derived data elements
#
sub averageQueueTimeForRequests {
	my $self = shift;

	my $ret = $self->averageWaitTimeForRequests() - $self->averageServiceTimeForRequests();
	$ret = sprintf("%.3f", $ret);

	return($ret);
}

sub megabitsReadPerSecond {
	my $self = shift;

	my $ret = $self->kilobytesReadPerSecond();
	$ret *= 8; # there are 8 kiloBITS/sec per kiloBYTE/sec
	$ret /= 1024; # there is 1 MEGAbit/sec per 1024 KILObits/sec
	$ret = sprintf("%.3f",$ret);
	return $ret;
}

sub megabitsWrittenPerSecond {
	my $self = shift;

	#
	# 1 megabyte/sec per 1024 kilobytes/sec, so /1024 to get megabytes
	# 8 bits per byte gives megabits from megabytes so *8
	# and 8/1024 is 1/128 so net operation is divide by 128
	#
	my $ret = $self->kilobytesWrittenPerSecond();
	$ret *= 8; # there are 8 kiloBITS/sec per kiloBYTE/sec
	$ret /= 1024; # there is 1 MEGAbit/sec per 1024 KILObits/sec
	$ret = sprintf("%.3f",$ret);
	return $ret;
}

1;
