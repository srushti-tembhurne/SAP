#!/usr/local/bin/perl

=pod

=head1 NAME

ariba::monitor::Outage

=head1 VERSION

# $Id: //ariba/services/monitor/lib/ariba/monitor/Outage.pm#9 $

=head1 DESCRIPTION

This script is an add-on for ariba::monitor::Downtime, and returns an
object such that each object represents an outage window... in other
words, this object represents a down and an up paired together.

This also has class methods to take arrays of outages, and calculate
various downtime metrics, and find subsets of data that need to be drawn
to the attention of prodops (either missing endpoints, or un-annotated
outages).

=cut

package ariba::monitor::Outage;
use strict;
use ariba::monitor::DowntimeEntry;
use ariba::rc::InstalledProduct;
use Time::Local;

use base qw(ariba::Ops::PersistantObject);

my $_debug;
my $instanceUniq = 1;

# constants -- this makes the code easier to read
sub UP { 1; }
sub DOWN { 2; }
sub PLANNED { 1; }
sub UNPLANNED { 0; }

sub dir {
	return undef;
}

sub save {
	return undef; # perhaps this should eventually be able to write?
}

sub recursiveSave {
	return undef;
}

sub remove {
	return undef;
}

=head1 PUBLIC CLASS METHODS

=over 8

=item * $class->connect()

Activate the database connection.  This should be called before any other
methods.

=cut

sub connect {
	my $me = ariba::rc::InstalledProduct->new("mon");
	ariba::monitor::DowntimeEntry->connectToDatabase($me);
}

=pod

=item * $class->setDebug($debugValue)

Set debugging on (debug==1) or off (debug==0).

=cut

sub setDebug {
	my $class = shift;
	my $debug = shift;

	$_debug = $debug;
}

=pod

=item * $class->unannotatedDowntimes(@outageList)

This call takes an array of Outage objects, and returns the subset of them
that are in need of ops annotation.  It limits itself to items within the
last 3 months, since for the sake of monitoring, we're not likely to go back
and fix omissions from 2006 or earlier.

=cut

sub unannotatedDowntimes {
	my $class = shift;
	my (@outages) = (@_);
	my @ret;
	my $threeMonthsAgo = time() - (30*24*60*60);

	foreach my $o (@outages) {
		next if($o->opsnote());
		next if($o->planned() == PLANNED);
		next if($o->badData());
		push(@ret, $o);
	}

	return(@ret);
}

=pod

=item * $class->badDownTimes(@outageList)

This call takes an array of Outage objects and returns the subset that
are missing an end point.  In some cases, we assume that a missing end
point signifies the end of a query range rather than broken data.

=cut

sub badDownTimes {
	my $class = shift;
	my (@outages) = (@_);
	my @ret;

	foreach my $o (@outages) {
		#
		# XXX -- ignore these until we fix downtime db bug
		#
		next if($o->note() && $o->note =~ /in scheduled outage/);
		if($o->badData()) {
			push(@ret, $o);
		}
	}

	return(@ret);
}

=pod

=item * $class->entriesForDateRange($startDate, $endDate)

This function takes a pair of endpoints in "YYYY-MM-DD" or
"YYYY-MM-DD:HH:mm:SS" format, and returns an array of Outage objects
for that date range.

=cut

sub entriesForDateRange {
	my $class = shift;
	my $startDate = shift;
	my $endDate = shift;

	my $iterator = ariba::monitor::DowntimeEntry->entriesForDateRange( $startDate, $endDate );

	return($class->_processEntries($iterator, $startDate, $endDate));
}

=pod

=item * $class->entriesForDateRangeAndProductAndCustomer($sDate, $eDate, $prod, $cust, $type)

This function takes a pair of endpoints in "YYYY-MM-DD" or
"YYYY-MM-DD:HH:mm:SS" format, a product, and a customer, and returns
an array of Outage objects for that date range.  It handles an undefined
customer tranparently in the case of shared service products.

=cut

sub entriesForDateRangeAndProductAndCustomer {
	my $class = shift;
	my $startDate = shift;
	my $endDate = shift;
	my $product = shift;
	my $customer = shift;
	my $type = shift;
	my $debug = $_debug;
	
	my $iterator;

	if(!defined($product)) {

		if(defined($type)) {
			$iterator = ariba::monitor::DowntimeEntry->entriesForDateRangeAndCustomerPlanned( $startDate, $endDate, $customer, $type );
		} else {
			$iterator = ariba::monitor::DowntimeEntry->entriesForDateRangeAndCustomer( $startDate, $endDate, $customer );
		}

	} elsif($product eq 'ss-suite') {
		
		if(define($type)) {
			$iterator = ariba::monitor::DowntimeEntry->SSSuiteEntriesForDateRangePlanned( $startDate, $endDate, $type );
		} else {
			$iterator = ariba::monitor::DowntimeEntry->SSSuiteEntriesForDateRange( $startDate, $endDate );
		}

	} elsif ( $product =~ /\+/ || $product =~ /\// ) {

		#
		# We need to construct a where clause here
		#
		my $whereClause;

		foreach my $p (split(/\+/, $product)) {
			$whereClause .= " OR " if($whereClause);
			if($p =~ m|([^/]+)/([\w\-]+)|) {  # all/orange-ftgroup
				$p = $1;
				my $c = $2;
				if($p eq '*' || uc($p) eq 'ALL') {
					$whereClause .= "customer = '$c'";
				} else {
					$whereClause .= "(productname = '$p' AND customer = '$c')";
				}
			} else {
				$whereClause .= "productname = '$p'";
			}

			if ($type eq 1) { $whereClause .= " AND planned = '$type'"; }
		}
		print "where: $whereClause\n" if($debug);
		$iterator = ariba::monitor::DowntimeEntry->entriesForDateRangeAndWhereClause( $startDate, $endDate, $whereClause);

	} else {

		if($customer) {
			if (defined($type)) {
				$iterator = ariba::monitor::DowntimeEntry->entriesForDateRangeAndProductAndCustomerPlanned( $startDate, $endDate, $product, $customer, $type );
			} else {
				$iterator = ariba::monitor::DowntimeEntry->entriesForDateRangeAndProductAndCustomer( $startDate, $endDate, $product, $customer );
			}			

		} else {
			if (defined($type)) {
				$iterator = ariba::monitor::DowntimeEntry->entriesForDateRangeAndProductPlanned( $startDate, $endDate, $product, $type );
			} else {
				$iterator = ariba::monitor::DowntimeEntry->entriesForDateRangeAndProduct( $startDate, $endDate, $product );
			}
		}

	}

	return($class->_processEntries($iterator, $startDate, $endDate));
}

sub _processEntries {
	my $class = shift;
	my $iterator = shift;
	my $startDate = shift;
	my $endDate = shift;
	my $debug = $_debug;

	my $startTimestamp = ariba::Ops::DateTime::oracleToTimestamp($startDate);
	my $endTimestamp = ariba::Ops::DateTime::oracleToTimestamp($endDate);

	my @ret;
	my %appStatus;

	print "\n===== List of DB entries from opsmetrics =====\n\n" if($debug);
	while(my $entry = $iterator->next()) {
		if($debug) {
			printf("%6d %-32s %-4s at %s\n",
				$entry->id(),
				$entry->appname(),
				($entry->transitiontype()) ? "up" : "down",
				scalar (localtime($entry->timestamp()))
			);

		}
		my $hashKey = $entry->productname() . ":" . $entry->appname();
		if($entry->transitiontype() == UP) {
			if(ref($appStatus{$hashKey})) {
				# this up corresponds to the saved "down"
				my $outage = $appStatus{$hashKey};
				$outage->populateData($entry);
				$outage->setUpTimestamp($entry->timestamp());
				$outage->setUpEntry($entry);
				$outage->setUpId($entry->id());
			} elsif ($appStatus{$hashKey}) {
				# bad data!  means we have an "up" and no "down"
				my $outage = $class->newFromUpEntry($entry);
				$outage->setRangeStart($startTimestamp);
				$outage->setRangeEnd($endTimestamp);
				push(@ret, $outage);
			} else {
				# first time we've seen this app, fake a down at start of range
				my $outage = $class->newFromUpEntry($entry);
				$outage->setRangeStart($startTimestamp);
				$outage->setRangeEnd($endTimestamp);
				$outage->setDownTimestamp($startTimestamp);
				push(@ret, $outage);
			}
			$appStatus{$hashKey} = "up";
		} else {
			my $outage;
			if(ref($appStatus{$hashKey})) {
				# this is a second "down" without an "up" -- also BAD	
				$outage = $appStatus{$hashKey};
				$outage = $class->newFromDownEntry($entry);
			} else {
				# start a new outage record.
				$outage = $class->newFromDownEntry($entry);
			}
			$outage->setRangeStart($startTimestamp);
			$outage->setRangeEnd($endTimestamp);
			$appStatus{$hashKey} = $outage;
			push(@ret, $outage);
		}
	}

	#
	# close off any lingering downtimes that cross the time range
	#
	foreach my $k (keys(%appStatus)) {
		if(ref($appStatus{$k})) {
			my $outage = $appStatus{$k};
			$outage->setUpTimestamp($endTimestamp);
		}
	}

	return(@ret);
}

=pod

=item * $object->badData()

This call returns 1 if the object represents data that is missing an end
point in the database.  It assumes that in some cases, data can be missing
end points and still be "ok" if the data is at the start or end of the
time range that data was collected for.

=cut

sub badData {
	my $self = shift;
	my $threeDays = (3*24*60*60);

	if(defined($self->upId()) && defined($self->downId())) {
		return(0);
	}

	#
	# open ended downtime might be ok as long as we're within a few days
	#
	if(defined($self->downId()) && $self->downTimestamp() && $self->downTimestamp() > $self->rangeEnd() - $threeDays) {
		return(0);
	}
	if(defined($self->upId()) && $self->upTimestamp() && $self->upTimestamp() < $self->rangeStart() + $threeDays) {
		return(0);
	}

	return(1);
}

=pod

=item * $class->microThreshold()

returns the threshold for being considered a micro outage as far as the SLA.

=cut

sub microThreshold {
	my $class = shift;

	return(15*60); # 15mins
}

=pod

=item * $class->SLAChangeTime();

returns the timestamp of when the SLA changed over

=cut

sub SLAChangeTime {
	my $class = shift;

	# Note, the SLA changes on 5-15-2007, but we're saying 5-1-2007, since
	# the new SLA operates on calendar months, so it's safer to apply the
	# stricter SLA to the whole month.

	# timestamp for 2007-05-01:00:00:01
	my $SLAChangeTime = timelocal(1,0,0,1,4,107);

	return($SLAChangeTime);
}

=pod

=item * $class->unplannedDowntime(@outageList)

=cut

=item * $class->plannedDowntime(@outageList)

=cut

=item * $class->SLADowntime(@outageList)

=cut

=item * $class->totalDowntime(@outageList)

These methods take a list of outage objects and count outages, and calcualte
the total amount of outage time.  plannedDowntime() counts planned outages
only, unplannedDowntime counts only unplanned outages, SLADowntime counts
unplanned outages that count against the SLA, and totalDowntime counts all
downtime unconditionally.

These methods return the amount of downtime in seconds if called in scalar
context, or an array consisting of the count of downtimes, and the amount
of downtime if called in array context.

=cut

sub unplannedDowntime {
	my $class = shift;
	my @outages = (@_);

	my ($count, $time) = $class->_countDowntime(sub { my $a = shift; return ($a->planned() == UNPLANNED); }, @outages);

	return($count, $time) if(wantarray());
	return($time);
}

sub plannedDowntime {
	my $class = shift;
	my @outages = (@_);

	my ($count, $time) = $class->_countDowntime(sub { my $a = shift; return ($a->planned() == PLANNED); }, @outages);

	return($count, $time) if(wantarray());
	return($time);
}

sub SLADowntime {
	my $class = shift;
	my $debug = $_debug;
	my @outages = (@_);
	my $microThreshold = $class->microThreshold(); # 15mins
	my $SLAChangeTime = $class->SLAChangeTime();
	my $rangeEnd = $outages[0] ? $outages[0]->rangeEnd() : time();

	my $outageCount = 0;
	my $microCount = 0;
	my $outageTime = 0;

	print "\n" if($debug);
	while(my $outage = shift(@outages)) {
		next if($outage->planned() == PLANNED);
		next if($outage->badData());
		my $start = $outage->downTimestamp();
		my $end = $outage->upTimestamp();
		while(my $subOut = shift(@outages)) {
			next if($outage->planned() == PLANNED);
			next if($outage->badData());
			if($subOut->downTimestamp() > $end) {
				unshift(@outages, $subOut);
				last;
			}
			$end = $subOut->upTimestamp() if($end < $subOut->upTimestamp());
		}
		if(($end - $start) < $microThreshold) {
			$microCount++ unless($rangeEnd < $SLAChangeTime);
			next unless($microCount > 3);
		}
		if($debug) {
			print "adding Downtime from ", scalar(localtime($start)), " to ", scalar(localtime($end)), " (", $end-$start, " seconds)\n";
		}
		$outageTime += ($end - $start);
		$outageCount++;
	}

	return($outageCount, $outageTime) if(wantarray());
	return($outageTime);
}

sub totalDowntime {
	my $class = shift;
	my @outages = (@_);

	my ($count, $time) = $class->_countDowntime(sub { return 1; }, @outages);

	return($count, $time) if(wantarray());
	return($time);
}

sub _countDowntime {
	my $class = shift;
	my $sub = shift;
	my $debug = $_debug;
	my @outages = (@_);

	my $outageCount = 0;
	my $outageTime = 0;

	print "\n" if($debug);
	while(my $outage = shift(@outages)) {
		next unless(&{$sub}($outage));
		next if($outage->badData());
		my $start = $outage->downTimestamp();
		my $end = $outage->upTimestamp();
		while(my $subOut = shift(@outages)) {
			next unless(&{$sub}($subOut));
			next if($outage->badData());
			if($subOut->downTimestamp() > $end) {
				unshift(@outages, $subOut);
				last;
			}
			$end = $subOut->upTimestamp() if($end < $subOut->upTimestamp());
		}
		if($debug) {
			print "adding Downtime from ", scalar(localtime($start)), " to ", scalar(localtime($end)), " (", $end-$start, " seconds)\n";
		}
		$outageTime += ($end - $start);
		$outageCount++;
	}

	return($outageCount, $outageTime);
}

=pod

=item * $class->groupOutages(@outageList)

This function will take an array or outages and group them together.  It
returns an array of outages, that are generalized -- you do NOT get detailed
data for the outages returned by this call, but you do get an array with
all the sub outages that make up these.

=cut

sub groupOutages {
	my $class = shift;
	my @outages = (@_);
	my @ret;

	while(my $outage = shift(@outages)) {
		my @subList;
		next if($outage->badData());
		my $start = $outage->downTimestamp();
		my $planned = $outage->planned();
		my $end = $outage->upTimestamp();
		@subList = ( $outage );
		while(my $subOut = shift(@outages)) {
			next if($outage->badData());
			if($subOut->downTimestamp() > $end) {
				unshift(@outages, $subOut);
				last;
			}
			push(@subList,$subOut);
			$end = $subOut->upTimestamp() if($end < $subOut->upTimestamp());
		}
		push(@ret, $class->newFromTimesAndSubOutages($start,$end,\@subList));
	}

	return(@ret);
}

=pod

=item * $class->printOutages(@outageList)

This function will print the outage data to stdout in PersistantObject
format.  This is mainly a debugging tool.

=cut

sub printOutages {
	my $class = shift;
	my @outages = (@_);

	foreach my $o (@outages) {
		$o->print();
		print "\n******************\n\n";
	}

}

=item * $class->outageSummary(@outageList)

This method will print a short sumary of an outage object, useful for
listing data, for example on the mon page when detecting bad data or data
needing annotation.

=cut

sub outageSummary {
	my $class = shift;
	my (@outages) = (@_);
	my $ret;

	foreach my $o (@outages) {
		my $timestr = $o->downTimestamp() || $o->upTimestamp();
		if($timestr) {
			$timestr = scalar(localtime($timestr));
		} else {
			$timestr = "unknown";
		}
		$ret .= sprintf( "%s,%s %-5s %-14s %s\n",
			$o->downId() || "xxxxx",
			$o->upId() || "xxxxx",
			$o->productName() || "unknown",
			$o->appName() || "unknown",
			$timestr,
		);
	}

	return($ret);
}

=pod

=item $class->newFromDownEntry($entry)

=cut

=item $class->newFromUpEntry($entry)

=cut

=item $class->newFromTimesAndPlanned($entry)

=cut

=item $object->populateData($entry)

While not strictly private, these calls are used internally to create
the objects returned by methods such as entriesForTimeRange().  Generally
These should not be called externally.

=cut

sub populateData {
	my $self = shift;
	my $entry = shift;

	$self->setProductName($entry->productname());
	$self->setAppName($entry->appname());
	$self->setPlanned($entry->planned()) unless($self->planned() && $self->planned() == PLANNED);
	$self->setNote($entry->note()) unless ($self->note());
	$self->setOpsnote($entry->opsnote()) unless ($self->opsnote());
}

sub newFromDownEntry {
	my $class = shift;
	my $entry = shift;
	my $id = $instanceUniq++;

	my $self = $class->new($id);

	$self->setDownTimestamp($entry->timestamp());
	$self->setDownEntry($entry);
	$self->setDownId($entry->id());
	$self->populateData($entry);

	return($self);
}

sub newFromUpEntry {
	my $class = shift;
	my $entry = shift;
	my $id = $instanceUniq++;

	my $self = $class->new($id);

	$self->setUpTimestamp($entry->timestamp());
	$self->setUpEntry($entry);
	$self->setUpId($entry->id());
	$self->populateData($entry);

	return($self);
}

sub newFromTimesAndSubOutages {
	my $class = shift;
	my $start = shift;
	my $end = shift;
	my $subOutages = shift;
	my $id = "$start-$end";

	my $self = $class->new($id);

	my $firstOutage = $$subOutages[0];
	if($firstOutage) {
		$self->setPlanned($firstOutage->planned());
		$self->setError($firstOutage->error());
		$self->setNote($firstOutage->note());
		$self->setUpId($firstOutage->upId());
		$self->setDownId($firstOutage->downId());
	}

	$self->setDownTimestamp($start);
	$self->setUpTimestamp($end);
	$self->setSubOutages(@{$subOutages});

	return($self);
}

=pod

=item * $object->productName()

=cut

=item * $object->appName()

=cut

=item * $object->upId()

=cut

=item * $object->upTimestamp()

=cut

=item * $object->downId()

=cut

=item * $object->downTimestamp()

=cut

=item * $object->planned()

=cut

=item * $object->note()

=cut

=item * $object->opsnote()

=cut

=item * $object->downtime()

These are the valid accessors for the data in the Outage object.  Most are
self explainitory, except as below:

$object->planned() - 0 is unplanned, 1 is planned

$object->downtime() - returns the length of downtime in seconds for this Outage

=cut

sub downtime {
	my $self = shift;

	return(0) unless ($self->upTimestamp() && $self->downTimestamp());
	return($self->upTimestamp() - $self->downTimestamp());
}

=pod

=back

=head1 AUTHORS

Josh McMinn <jmcminn@ariba.com>

=cut

1;
