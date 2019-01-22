package ariba::monitor::BaseUptimeCDB;

use ariba::Ops::DateTime;
use DateTime;
use ariba::rc::InstalledProduct;
use ariba::rc::ArchivedProduct;
use ariba::monitor::DowntimeEntry;
use ariba::monitor::Outage;
use Date::Parse;
use POSIX qw(strftime);

sub newFromProductAndServiceAndCustomer {
	my $class = shift;
	my $productName = shift;
	my $serviceName = shift;
	my $customerName = shift;
	my $buildName = shift;

	my $self = {};

	my $product = ariba::rc::InstalledProduct->new($productName, $serviceName, $buildName, $customerName);
	if (!defined($product)) {
		$product = ariba::rc::ArchivedProduct->new($productName, $serviceName, $buildName, $customerName);
	}

	$self->{'product'} = $product;

	bless($self, $class);

	my $mon = ariba::rc::InstalledProduct->new("mon");
	ariba::monitor::DowntimeEntry->connectToDatabase($mon);

	return $self;
}

sub newFromProduct {
	my $class = shift;
	my $product = shift;

	my $self = {};

	$self->{'product'} = $product;

	bless($self, $class);

	my $mon = ariba::rc::InstalledProduct->new("mon");
	ariba::monitor::DowntimeEntry->connectToDatabase($mon);

	return $self;
}

sub product {
	my $self = shift;

	return $self->{'product'};
}


sub longerName {
	my $self = shift;

	return $self->name();
}

sub units
{
	my $class = shift();
	return "percent";
}

sub dataType
{
	my $class = shift();
	return "gauge";
}

#	string dataType(); [optional]
sub _printRecord
{
	my $fh = shift;
	my $date = shift;
	my $value = shift;
	my $dateFormat = shift;
	my $tzadj = shift;

	if (defined($dateFormat)) {
		$date = $date . " [" . POSIX::strftime($dateFormat, localtime($date)) . "]";
	} else {
		$date -= $tzadj;
	}

	$value = defined($value) ? $value : '?';
	syswrite($fh, "$date $value\n");
}

sub printRecords {
	my $self = shift;
	my $start = shift;
	my $end = shift;
	my $numRequested = shift;
	my $outFH = shift || *STDOUT;
	my $dateFormat = shift;
	my $cookedForGraphing = shift;

	my $tzadj  = 0;

	if ($cookedForGraphing) {
		# gnuplot has a bug where time() is converted to gmtime when
		# plotting. we need to artificially move time forward so that
		# the resulting graph has time shown correctly for local timezone.
		unless ($convert) {
			$tzadj = ariba::Ops::DateTime::timezoneAdjustmentInSeconds();
		}
	}

	my @records = ();
	$self->readRecords($start, $end, $numRequested, \@records);
	my $n = @records;

	return (0, 0) unless ($n);

	foreach my $record (@records) {
		_printRecord($outFH, $$record[0], $$record[1], $dateFormat, $tzadj);
	}

	return ($records[0][0]-$tzadj, $records[-1][0]-$tzadj);

}

sub readRecords {
	my $self = shift();
	my $start = shift();
	my $end = shift();
	my $numRequested = shift();
	my $arrayRef = shift();

	if (defined($start) && defined($end) && $end < $start) {
		die "end $end has to be >= start $start in time interval requested\n";
	}

	my $recordsRef;

	if (defined($arrayRef)) {
		$recordsRef = $arrayRef;
	} else {
		$recordsRef = [];
	}

	#
	# get the number of requested records:
	#
	# -ve indicates n records from the beginning
	# +ve indicates n records off of the end.
	# 0 or undef means the whole thing.
	#
	# switch the meaning of -ve/+ve to be more array like
	#
	if (defined($numRequested)) {
		$numRequested = -$numRequested;
	}


	# If $start is not defined, we need to obtain the time of the earliest entry in the downtime db
	unless ($start) {

		# Returns something like :
		#  [
		#  	[
		#  		"1982-12-01:16:16:34"
		#  	]
		#  ]
		#
		my @start = ariba::monitor::DowntimeEntry->earliestEntryForProduct( $self->product() );
		my $startStr = $start[0][0];

		# Fix Date-time separator so str2time() can convert it to unix time 
		$startStr =~ s/:(\d+:\d+)/T$1/;

		$start = dateToTime($startStr);

	}

	# If $end is not defined, we need to obtain the time of the latest entry in the downtime db
	unless ($end) {

		# Returns something like :
		#  [
		#  	[
		#  		"1982-12-01:16:16:34"
		#  	]
		#  ]
		#
		my @end = ariba::monitor::DowntimeEntry->latestEntryForProduct( $self->product() );
		my $endStr = $end[0][0];

		# Fix Date-time separator so str2time() can convert it to unix time 
		$endStr =~ s/:(\d+:\d+)/T$1/;

		$end = dateToTime($endStr);


	}

	my ( $startYear, $startMonth, $startDay )   =  ariba::Ops::DateTime::yearMonthDayFromTime($start);
	my ( $endYear,   $endMonth,   $endDay   )   =  ariba::Ops::DateTime::yearMonthDayFromTime($end);

	my $startDt = DateTime->new( year   => $startYear,
									month  => $startMonth,
									day    => $startDay,
									hour   => 0,
									minute => 0,
									second => 0,
									time_zone => 'local',
                        );

	my $endDt = DateTime->new( year   => $endYear,
									month  => $endMonth,
									day    => $endDay,
									hour   => 0,
									minute => 0,
									second => 0,
									time_zone => 'local',
                        );


	# For each month within that time frame
	
	my $currentDt = $startDt;
	my $numStored = 0;
	while ( $currentDt <= $endDt) {

		# convert dates
		my ($startCurrentDate, $endCurrentDate) = ariba::Ops::DateTime::computeStartAndEndDate($currentDt->epoch());

		($sDate,$eDate) = dateInRangeSQL($startCurrentDate, $endCurrentDate);

		# Get a list of outages
		my (@outages) = ();
		@outages = ariba::monitor::Outage->entriesForDateRangeAndProductAndCustomer(
			$sDate, $eDate, $self->product()->name(), $customer
		);

		my $sTime = dateToTime($sDate);
		my $eTime = dateToTime($eDate);

		
		# computeRecord() has to be implemented by classes inherited from this class
		my ($recordTime, $recordValue) = $self->computeRecord($sTime, $eTime, \@outages);



		push(@{$recordsRef->[$numStored++]},
				$recordTime, $recordValue );

		# Go to next month
		$currentDt->add( months => 1);
	}

	#
	# only return num of records requested
	#
	if ($numRequested && @$recordsRef >= abs($numRequested)) {
		if ($numRequested > 0 ) {
			@$recordsRef = @$recordsRef[0..$numRequested-1];
		} else {
			@$recordsRef = @$recordsRef[$numRequested..-1];
		}
	}

	return $recordsRef;

}

sub dateToTime {
	my $date = shift;

	if ( $date =~ m/-/ ) {
		return str2time($date);
	} else {
		return $date;
	}
}

sub dateInRangeSQL {
	my $sDate = shift;
	my $eDate = shift;

	$sDate .= ":00:00:00";
	$eDate .= ":00:00:00";

	if (wantarray()) {
		return ($sDate, $eDate);
	} else {
		return "timestamp between '$sDate' and '$eDate'";
	}
}

sub fileNameForTypeAndKind {
	my $self = shift;
	my $type = shift;
	my $kind = shift;

	my $productName = $self->product()->name();
	my $serviceName = $self->product()->service();
	my $customerName = $self->product()->customer();

	my $fileName = "$type://$productName/$serviceName/";
	$fileName .= "$customerName/" if ($customerName);
	$fileName .= "$kind";

	return $fileName;
}


1;
