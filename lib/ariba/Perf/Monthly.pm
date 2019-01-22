package ariba::Perf::Monthly;

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
	return $self->productName() . "-perf-monthly";
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
		$daily->_statsByRealm(\%statsByRealm); 
	}

	$self->_printReport(\%statsByRealm);

	for my $detailReportType ($self->detailReportTypes()) {
		$self->_printDetailReportForType($detailReportType, \@dailies);
	}

	$self->makeReportCopies();
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

		while ( my $line = <$dailyfh> ) { print $reportfh $line; }

		$dailyfh->close();
	}

	$reportfh->close();
}

sub newFromProductNameAndDate {
	my $class = shift;
	my $productName = shift;
	my $date = shift;

	$class->bug(2, "newFromProductNameAndDate() month=" . $date->ymd("-") );

	my $instance = $date->ymd("-");
	$instance =~ s!-\d+$!!;
	my $self = $class->new($instance);

	$self->setProductName($productName);
	$self->setDate($date);

	# recreate/populate report schema and tooslow file if necessary
	#
	my $dbExists = $self->exists();

	return $self;
}

1;
