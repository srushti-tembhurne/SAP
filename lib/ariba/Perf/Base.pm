package ariba::Perf::Base;

=head1 NAME

ariba::Perf::Base - base class for Perf data objects

=head1 SYNOPSIS

lower level data manipulation 
common defaults 

=cut

use strict;

use DBI;
use DateTime;
use File::Basename;
use File::Path;
use File::Copy;
use IO::Zlib;
use IO::File;
use Text::CSV_XS;

use ariba::monitor::misc;
use ariba::rc::InstalledProduct;

use base qw(ariba::Ops::PersistantObject);

my $DEBUG = 0;
my $VERBOSE = 0;

#
# these are used to reject extreme outliers for mean/median/etc. 
#
my $TRUNCATE_MIN = 20;     # in ms, minimum threshold for totaltimes to be included in reports
my $TRUNCATE_MAX = 99999;  # in ms, this is not used

# threshold for how slow things can get
# this is defined as 50% or more above 7 seconds
my $SLOWTHRESHOLD = 1.5 * 7 * 1000; # milliseconds

my $PERF_ROOT_DIR;
my $SAVE_REPORT_COPIES_TO_DIR;

sub slowThreshold { return $SLOWTHRESHOLD; }
sub setDebug { my $class = shift; $DEBUG = shift; }
sub debug { my $class = shift; return $DEBUG; }

sub fileNameForType {
	my $self = shift;
	my $type = shift;
	
	my $reportPrefix = $self->_fileNamePrefix();
	my $hours = $self->numOfHours() ? "-hours-" . $self->startHour() . "-" . $self->numOfHours() : "";
	my $reportDir = $self->perfDir();
	my $reportFile = "$reportDir/$reportPrefix-$type-" . $self->instance() . "$hours.csv";

	return $reportFile;
}

my ($SUMMARYTYPE, $TOOSLOWTYPE, $ERRORTYPE) = ('summary', 'too-slow', 'error');
sub summaryType { return $SUMMARYTYPE; }
sub tooslowType { return $TOOSLOWTYPE; }
sub errorType { return $ERRORTYPE; }

my @reportTypes = ($SUMMARYTYPE, $TOOSLOWTYPE, $ERRORTYPE);
sub reportTypes { return @reportTypes; }
sub detailReportTypes { return ($TOOSLOWTYPE, $ERRORTYPE); }

sub reportFileName {
	my $self = shift;
	return $self->fileNameForType($SUMMARYTYPE, @_);
}

sub tooslowFileName {
	my $self = shift;
	return $self->fileNameForType($TOOSLOWTYPE, @_);
}

sub errorFileName {
	my $self = shift;
	return $self->fileNameForType($ERRORTYPE, @_);
}

my ($REALM,  $AVG,      $P90,   $P80,   $P50,   $MIN,  $MAX,  $TOOSLOW,        $COUNT,       $SUM,  $PERCENTTOOSLOW,   $ERRORCOUNT,   $USERCOUNT,   $SESSIONCOUNT,   $SESSIONMINS) = 
   ('realm', 'avg(ms)', '90th', '80th', '50th', 'min', 'max', 'tooslow count', 'page count', 'sum', 'percent tooslow', 'error count', 'user count', 'session count', 'session mins');

my @DETAILCOLUMNS = ($TOOSLOW, $PERCENTTOOSLOW, $ERRORCOUNT);
sub detailColumns { return @DETAILCOLUMNS; }
sub detailColumnsTypeHash { 
	my %map = ( 
		$TOOSLOW => $TOOSLOWTYPE,
		$PERCENTTOOSLOW => $TOOSLOWTYPE,
		$ERRORCOUNT => $ERRORTYPE,
	);

	return %map;
}

my ($MILLISECONDS) = 'ms';
my %columnUnitsHash = (
	$AVG => $MILLISECONDS,
	$P90 => $MILLISECONDS,
	$P80 => $MILLISECONDS,
	$P50 => $MILLISECONDS,
	$MIN => $MILLISECONDS,
	$MAX => $MILLISECONDS,
	$SUM => $MILLISECONDS,
	$TOOSLOW => "> $SLOWTHRESHOLD $MILLISECONDS",
	$PERCENTTOOSLOW => '%',
);

sub unitForColumn { 
	my $self = shift;
	my $col = shift;
	return $columnUnitsHash{$col};
}

my $TIMES = 'times';
my $ALL = "_ALL_";  # represents data across all realms

sub aggregatePseudoRealm { return $ALL; }

my $CSVFILELINE = ('csvfileline');

my @reportColumns = ( $REALM, $AVG, $P90, $P80, $P50, $MIN, $MAX, $TOOSLOW, $PERCENTTOOSLOW, $COUNT, $ERRORCOUNT, $SUM, $USERCOUNT, $SESSIONCOUNT, $SESSIONMINS );
sub reportColumns { return @reportColumns; }

sub _statsByRealm {
	my $self = shift;
	# hash keyed off of realm name
	my $statsByRealmRef = shift;
	my $targetDate = shift;
	my $startEpoch = shift;
	my $endEpoch = shift;

	my $dbh = $self->dbh();

	my $dateRestrict = "";
	if ($targetDate && !($startEpoch && $endEpoch)) {
		$startEpoch = $targetDate->clone()->truncate( to => 'day' )->epoch();
		$endEpoch = $startEpoch + 86400;
	}
	if ($startEpoch && $endEpoch) { 
		$dateRestrict = "AND date >= $startEpoch AND date < $endEpoch";
	} 

	#
	# FIXME should use schemaColumnTypeHash
	#
	my $results; 
	my $sqlFmt = "SELECT user, realm, totaltime, date, appmodule, destpage, node, csvfileline, status%s
				  FROM daily
				  WHERE user IS NOT NULL $dateRestrict
				  ORDER by csvfileline asc";
	eval { 
		$results = $dbh->selectall_arrayref(sprintf($sqlFmt, ', sessionid'));
	}; 
	if ($@ =~ /no such column/) { 
		$results = $dbh->selectall_arrayref(sprintf($sqlFmt, ''));
	}

	# detect state in-between calls, as this may be called multiple
	# times.
	# This is kind of ugly, only used for inserting into TIMES array
	# below
	my %realmsSeenFirstThisCall = ();

	for my $row (@$results) {
		my ($user, $realm, $totaltime, $date, $appmodule, $destpage, $node, $csvfileline, $status, $sessionId) = @$row;

		if (!defined $totaltime || $totaltime eq '') {
			$self->bug(2, "rejecting $user $realm $date totaltime==''");
			next;
		}

		if ($totaltime < $TRUNCATE_MIN) {
			$self->bug(2, "rejecting $totaltime < $TRUNCATE_MIN from $realm/$user/$date");
			next;
		}

#		} elsif ($totaltime > $TRUNCATE_MAX) {
#			$self->bug(2, "rejecting $totaltime > $TRUNCATE_MAX from $realm/$user/$date");
#			next;
#		}

		#XXX is this still needed?
		$user =~ s/"//g;

		for my $key ($ALL, $realm) {
			if (!exists $statsByRealmRef->{$key}) {
				$statsByRealmRef->{$key}{$COUNT} = $statsByRealmRef->{$key}{$SUM} = $statsByRealmRef->{$key}{$MAX} = $statsByRealmRef->{$key}{$TOOSLOW} = 0;
				$statsByRealmRef->{$key}{$MIN} = undef;
				$statsByRealmRef->{$key}{$ERRORCOUNT} = 0;

				$realmsSeenFirstThisCall{$key} = 1;
			}

			$statsByRealmRef->{$key}{$COUNT}++;

			if ($status =~ /error/i) {
				$statsByRealmRef->{$key}{$ERRORCOUNT}++;
			}

			if ($totaltime >= $SLOWTHRESHOLD) {
				$statsByRealmRef->{$key}{$TOOSLOW}++;
			}

			if ($self->debug() >= 3) {
				if (!exists $statsByRealmRef->{$key}{$SUM}) {
					$self->bug(3, "non-existing sum for key $key $SUM $user $realm $date");
					$statsByRealmRef->{$key}{$SUM} = 0;
				} else {
					$self->bug(3, "$key SUM=", $statsByRealmRef->{$key}{$SUM}, " TOTALTIME=", $totaltime, " COUNT=", $statsByRealmRef->{$key}{$COUNT});
				}
			}

			push (@{$statsByRealmRef->{$key}{$TIMES}}, $totaltime);
			push (@{$statsByRealmRef->{$key}{$CSVFILELINE}}, $csvfileline);

			$statsByRealmRef->{$key}{$SUM} += $totaltime;
			if (!defined($statsByRealmRef->{$key}{$MIN})) { 
				$statsByRealmRef->{$key}{$MIN} = $totaltime;
			} else {
				$statsByRealmRef->{$key}{$MIN} = $totaltime if $totaltime < $statsByRealmRef->{$key}{$MIN};
			}
			$statsByRealmRef->{$key}{$MAX} = $totaltime if $totaltime > $statsByRealmRef->{$key}{$MAX};

			# use "$realm-$user" to be more unique so that the ALL stat works
			$statsByRealmRef->{$key}{$USERCOUNT}{"$realm-$user"} = 1 if ($user);
			if ($sessionId) {
				my $sessionTime = $date;  # $date is actually a Unix time

				if ($statsByRealmRef->{$key}{$SESSIONCOUNT} && 
					$statsByRealmRef->{$key}{$SESSIONCOUNT}{$sessionId}) {

					my $prevSessionTime = $statsByRealmRef->{$key}{$SESSIONCOUNT}{$sessionId};
					my $deltaMins = ($sessionTime - $prevSessionTime) / 60;

					# A continous session is less than 5 mins. Less than 0 should not happen.
					if ($deltaMins > 5 || $deltaMins < 0) {
						$statsByRealmRef->{$key}{$SESSIONMINS} += 5;
					} else {
						$statsByRealmRef->{$key}{$SESSIONMINS} += $deltaMins;
					}
				}
				$statsByRealmRef->{$key}{$SESSIONCOUNT}{$sessionId} = $sessionTime;
			}

		}
	}
}

#FIXME
sub _printDetailReport {
	my $self = shift;
	my $statsByRealmRef = shift;

	my $tooslowFileName = $self->tooslowFileName();
	File::Path::mkpath(dirname($tooslowFileName));
	my $reportfh = IO::File->new("$tooslowFileName", "w") or die "Couldn't create report file $tooslowFileName: $!";

	print $reportfh join(",", $self->reportColumns()), "\n";
	
	for my $key ($ALL, sort(grep { !/$ALL/ } keys %$statsByRealmRef)) {
		my $count = $statsByRealmRef->{$key}{$COUNT};
		next if !defined $count;
	}
}

sub _printReport {
	my $self = shift;
	my $statsByRealmRef = shift;

	my $reportFile = $self->reportFileName();
	File::Path::mkpath(dirname($reportFile));
	my $reportfh = IO::File->new("$reportFile", "w") or die "Couldn't create report file $reportFile: $!";

	print $reportfh join(",", $self->reportColumns()), "\n";
	
	for my $key ($ALL, sort(grep { !/$ALL/ } keys %$statsByRealmRef)) {

		my %results = ();

		$results{$REALM} = $key;

		my $count = $statsByRealmRef->{$key}{$COUNT};
		next if !defined $count;
		$results{$COUNT} = $count;
		$results{$ERRORCOUNT} = $statsByRealmRef->{$key}{$ERRORCOUNT};

		my $i90 = int(.9 * $count);
		my $i80 = int(.8 * $count);
		my $i50 = int(.5 * $count);

		my @sortedTimes = sort {$a <=> $b} @{$statsByRealmRef->{$key}{$TIMES}};

		$results{$P90} = $sortedTimes[$i90];
		$results{$P80} = $sortedTimes[$i80];
		$results{$P50} = $sortedTimes[$i50];

		my $tooSlow = $statsByRealmRef->{$key}{$TOOSLOW};
		$results{$TOOSLOW} = $tooSlow;
		$results{$PERCENTTOOSLOW} = sprintf("%.1f", 100 * $tooSlow / $count);
		$results{$AVG} = sprintf("%.1f", $statsByRealmRef->{$key}{$SUM} / $count);
		$results{$SUM} = $statsByRealmRef->{$key}{$SUM};
		$results{$MIN} = $statsByRealmRef->{$key}{$MIN};
		$results{$MAX} = $statsByRealmRef->{$key}{$MAX};

		$results{$USERCOUNT} = scalar(keys(%{ $statsByRealmRef->{$key}{$USERCOUNT} }));
		$results{$SESSIONCOUNT} = scalar(keys(%{ $statsByRealmRef->{$key}{$SESSIONCOUNT} }));
		$results{$SESSIONMINS} = int($statsByRealmRef->{$key}{$SESSIONMINS} || 0);
		$results{$SESSIONMINS} += $results{$SESSIONCOUNT} * 5;

		#FIXME this needs to use Text::CSV
		print $reportfh join(",",  map { $results{$_} } $self->reportColumns()), "\n";
	}

	$reportfh->close();
}

sub makeReportCopies {
	my $self = shift; 
	my $deleteOriginals = shift;
	my $saveReportCopiesToDir = $self->saveReportCopiesToDir();

	return unless ($saveReportCopiesToDir);

	my @filesToCopy;
	push(@filesToCopy, $self->reportFileName()) if (-e $self->reportFileName());
	push(@filesToCopy, $self->tooslowFileName()) if (-e $self->tooslowFileName()); 
	push(@filesToCopy, $self->errorFileName()) if (-e $self->errorFileName()); 

	foreach my $sourceFile (@filesToCopy) {
		my $targetFile = $saveReportCopiesToDir . "/" . basename($sourceFile);
		if (copy($sourceFile, $targetFile)) {
			print "Report copied to: $targetFile\n" if ($self->verbose());
		} else {
			print "Failed to copy from '$sourceFile' to '$targetFile': $!\n" if ($self->verbose());
		}
		$self->bug(1, "Failed to delete original report $sourceFile: $!") if ($deleteOriginals && !unlink($sourceFile)); 
	}
}

sub bug {
	my $something = shift;
	my $severity = shift;

	my $debugLevel = $DEBUG;

	if (defined($something) && scalar($something)) {
		$debugLevel = $something->debug();
	}

	my $time = localtime();
	if ($debugLevel >= $severity) {
		print __PACKAGE__."[$severity:$time]: ", join("", @_),"\n";
	}
}

sub setSaveReportCopiesToDir {
	my $class = shift; 
	my $dir = shift; 

	$SAVE_REPORT_COPIES_TO_DIR = $dir;
}

sub saveReportCopiesToDir {
	my $class = shift;

	return $SAVE_REPORT_COPIES_TO_DIR;
}

sub setPerfRootDir {
	my $class = shift; 
	my $dir = shift; 

	$PERF_ROOT_DIR = $dir;
}

sub perfRootDir {
	my $class = shift;

	return $PERF_ROOT_DIR || (ariba::Ops::Constants::monitorDir() . "/docroot/perf"); 
}

sub perfTopDir {
	my $class = shift;
	my $productName = shift;

	return $class->perfRootDir() . "/" . $productName;
}

sub perfDir {
	my $self = shift;

	my $instance = $self->instance();
	$instance =~ s!-!/!g;
	return $self->perfTopDir($self->productName()) . "/" . $instance;
}

sub tmpTopDir { return "/var/tmp/perf"; }

sub tmpDir {
	my $self = shift;

	return $self->tmpTopDir() . "/" . ($self->productName());
}

sub setDate {
	my $self = shift;
	my $date = shift;

	$self->setDateRef( \$date );
}

#
# this and setDate are a work-around for a PersistantObject 'bug';
# DateTime overrides the == comparitor and upon attribute fetch 
# PO will compare the value to '' which causes an exception
#
sub date {
	my $self = shift;

	my $dateRef = $self->dateRef();
	return $$dateRef;
}

sub setVerbose {
	my $class = shift;
	my $verbose = shift; 

	$VERBOSE = $verbose;
}

 sub verbose {
	my $class = shift;
	
	return $VERBOSE; 
}

1;
