package ariba::Perf::TimeRange;

use strict;

use DBI;
use DateTime;
use HTTP::Date;
use File::Basename;
use File::Path;
use IO::Zlib;
use IO::File;
use Text::CSV_XS;

use ariba::monitor::misc;

use base qw(ariba::Perf::Base);

sub objectLoadMap {
	my $class = shift;

	my $mapRef = $class->SUPER::objectLoadMap();
	$mapRef->{dailyList} = '@ariba::Perf::Daily';

	return $mapRef;
}

sub _fileNamePrefix { 
	my $self = shift;
	return $self->productName() . "-perf-timerange";
}

sub generateReport {
	my $self = shift;
	my $targetDate = shift;

	my $reportFile = $self->reportFileName();
	my @dailies = sort { $a->date() <=> $b->date() } $self->dailyList();

	# bail if we don't have any valid dates 
	return unless (scalar(@dailies) && $dailies[0]);

	my $first = $dailies[0];
	my $last = $dailies[$#dailies];

	$self->bug(1, "working on $reportFile for range ", $first->date()->ymd('-'), " to ", $last->date->ymd('-'));

	my %statsByRealm = ();
	for my $daily (@dailies) {
		$daily->_statsByRealm(\%statsByRealm, undef, $self->startTime(), $self->endTime()); 
	}

	$self->_printReport(\%statsByRealm);
	for my $detailReportType ($self->detailReportTypes()) {
		$self->_printDetailReportForType($detailReportType, \@dailies);
	}

	$self->makeReportCopies(1);
}

sub _printDetailReportForType {
	my $self = shift;
	my $reportType = shift;
	my $dailiesRef = shift;

	# generate monthly detail report
	#FIXME this just concatenates all the relevant daily detail reports
	# this should probably do some type of sort
	#

	my $detailFileName = $self->fileNameForType($reportType);
	File::Path::mkpath(dirname($detailFileName));
	unlink $detailFileName if -e $detailFileName;
	my $reportfh = IO::File->new("$detailFileName", "w") or die "Couldn't create report file $detailFileName: $!";

	my $headerWritten = 0;;
	my $csv = Text::CSV_XS->new({ binary => 1 });

	for my $daily (@$dailiesRef) {

		my $dailyDetail = $daily->fileNameForType($reportType);
		$self->bug(1, "processing $dailyDetail");
		my $dailyfh = IO::File->new($dailyDetail, "r");

		next unless $dailyfh;

		my $header = <$dailyfh>; # discard header

		unless ($headerWritten) {
			print $reportfh $header;
			$headerWritten = 1;
		}

		# Find the date column in each daily log.
		chomp($header);
		$csv->parse(lc($header));
		my $dateIndex; 
		my @fields = $csv->fields();
		for (my $index = 0; $index <= $#fields; $index++ ) {
			$fields[$index] =~ s/^\s*(.+)\s*$/$1/;
			if ($fields[$index] eq 'date') {
				$dateIndex = $index; 
				last;
			}
		}

		unless (defined($dateIndex)) {
			print "Failed to find the 'date' column in $dailyDetail\n" if ($self->verbose());
			next;
		}

		while ( my $line = <$dailyfh> ) { 
			$csv->parse($line); 
			my @values = $csv->fields();
			my $dateString = $values[$dateIndex];
			my $time = HTTP::Date::str2time($dateString);

			print $reportfh $line if ($time >= $self->startTime() && $time <= $self->endTime());
		}

		$dailyfh->close();
	}

	$reportfh->close();
}

sub newFromProductNameAndDate {
	my $class = shift;
	my $productName = shift;
	my $date = shift;
	my $startHour = shift; 
	my $numOfHours = shift || return;
	defined($startHour) || return;
	my $startTime = $date->epoch() + $startHour * 3600;
	my $endTime = $startTime + $numOfHours * 3600;

	$class->bug(2, "newFromProductNameAndDate() startdate=" . $date->ymd("-") );

	if ($class->verbose()) {
		print "  Start Time: " . localtime($startTime) . "\n"; 
		print "    End Time: " . localtime($endTime) . "\n";
	}

	my $instance = $date->ymd("-");
	my $self = $class->new($instance);

	$self->setProductName($productName);
	$self->setDate($date);
	$self->setStartHour($startHour);
	$self->setNumOfHours($numOfHours);
	$self->setStartTime($startTime);
	$self->setEndTime($endTime);

	return $self;
}

1;
