package ariba::monitor::LogMiner::ErrorCollector;

#
# Collect errors from node logs and print frequency report 
#

use strict;
use English;
use File::Basename;
use IO::Zlib;
use IO::File;
use ariba::monitor::LogMiner::Plugin;
use base qw(ariba::monitor::LogMiner::Plugin);


my $NUM_LINES_ABOVE = 0;
my $NUM_LINES_BELOW = 5;

my $NONE_STATE       = 0;
my $STACKTRACE_STATE = 1;
my $ERROR_STATE      = 2;

my $STACKTRACE_PATTERN = "^\\tat\\s";

# Regular log messages are of the form:
#   Mon Jan 05 00:23:00 PST 2009 (T50:prealm_111:U8019875:PasswordAdapter1:c4502v:UI12220000) (catalog:WARN) [ID5819]:
#   CatalogFieldPropertie# s: no field menuitemmasteragreement on type system:catalogitem
#
#                   Mon             Jan              05          00:23:00             PST
my $LOG_PATTERN = "^[A-Z][a-z][a-z] [A-Z][a-z][a-z] (\\d|\\d\\d) \\d\\d:\\d\\d:\\d\\d [A-Z][A-Z][A-Z] " .
#                  2009         (T50...)    (...:WARN)  [ID...]
                  "\\d\\d\\d\\d \\((.*?)\\) \\((.*?)\\) \\[(ID\\d+)\\]: (.*)";
my $LOG_RE = qr/$LOG_PATTERN/;
#print "log: $LOG_RE\n";

# 21568.338: [GC 708596K->578612K(1179648K), 0.0717190 secs]
my $GC_PATTERN = "^\\d+\\.\\d+: \\[GC";
my $GC_RE = qr/$GC_PATTERN/;

# (T223:prealm_121:*:*:8chgx9:UI22320070)
#                       T223  : realm : *     : *     : 8chgx9: UI22320070
my $CONTEXT_PATTERN = "([^:]+):([^:]+):([^:]+):([^:]+):([^:]+):([^:]+)";
my $CONTEXT_RE = qr/$CONTEXT_PATTERN/;

my $ERROR_PATTERN = qr/:ERROR/;
my $WARN_ERROR_PATTERN = qr/:(WARN|ERROR)/;

my $MEGA_IN_BYTES = 1056784;

my $OUTPUT_AUTOFLUSH = 1;

my $DEFAULT_NUMBEROFLINES = 6;



sub new {
	my $class = shift;

	my $self = $class->SUPER::new("foobar");

	$self->setEntryProcessorMethodRef(\&_processNewEntry);
	$self->setNumberOfLines($DEFAULT_NUMBEROFLINES);

	my $entries = {};
	my $fileCounts = {};
	my $realmCounts = {};

	$self->setEntries($entries);
	$self->setFileCounts($fileCounts);
	$self->setRealmCounts($realmCounts);

	return $self;
}

sub processFile {
	my $self = shift;
	my $file = shift;

	my $errorFH = $self->errorFH();

	if (! -f $file) {
		print $errorFH "'$file' does not exist or is not a file\n";
		return 0;
	}

	my $inputFH;
	if (!($inputFH = IO::Zlib->new($file, 'rb'))) {
		print $errorFH "Unable to open $file: $!\n";
		return 0;
	}

	my $debug = $self->debug();
	my $entryProcessor = $self->entryProcessorMethodRef();
	my $numberOfLines = $self->numberOfLines();
	my $keep = $self->keep();
	my $ignore = $self->ignore();
	my $realms = $self->realms();
	my $showRealm = $self->showRealm();
	my $errorsOnly = $self->errorsOnly();

	my @previousLines = ();
	my $lineNumber = 0;
	my $state = $NONE_STATE;
	my $skipEntry = 0;
	my @entry = ();
	my $realm;

	while (my $line = <$inputFH>) {
		$lineNumber++;
		my ($id, $context, $category, $msg, $currentRealm, $error, $actualError) = ();
		$currentRealm = "<none>";
		if ($line =~ /$LOG_RE/) {
			print $errorFH "match: $line" if $debug;
			$context = $2;
			$category = $3;
			$id = $4;
			$msg = $5;
			if ($context =~ /$CONTEXT_RE/) {
				$currentRealm = $2;
				print $errorFH "context: $context\n" if $debug;
			}
			if ($category =~ /$WARN_ERROR_PATTERN/) {
				$error = 1;
				$actualError = ($1 eq "ERROR");
			}
		}

		if ($state == $ERROR_STATE) {
			if ($id) {
				# new log entry, process the old one
				$self->$entryProcessor($file, $lineNumber, $realm, \@previousLines, \@entry) unless $skipEntry;
				$state = $NONE_STATE;
				@entry = ();
				$skipEntry = 0;
			}
			elsif ($line =~ /$STACKTRACE_PATTERN/) {
				if (!$skipEntry && $numberOfLines > @entry) {
					push (@entry, $line);
				}
			}
			else {
				# skip other lines
			}
		}
		elsif ($state == $STACKTRACE_STATE) {
			if ($line =~ /$STACKTRACE_PATTERN/) {
				if (!$skipEntry && $numberOfLines > @entry) {
					push (@entry, $line);
				}
			}
			elsif ($line !~ /$STACKTRACE_PATTERN/) {
				$state = $NONE_STATE;
				unless ($skipEntry) {
					$self->$entryProcessor($file, $lineNumber, $realm, \@previousLines, \@entry);
				}
				@entry = ();
				$skipEntry = 0;
				$realm = $currentRealm;
			}
		}
		elsif ($state == $NONE_STATE) {
			if ($line =~ /$STACKTRACE_PATTERN/) {
				$skipEntry = ($keep && $line !~ /$keep/) ||
					($ignore && $line =~ /$ignore/) ||
					($realms && $currentRealm !~ /$realms/);
				if (!$skipEntry) {
					my $entry = "-->> [ID0] (:) " . ($showRealm ? "($realm) " : " ") . $line;
					push (@entry, $entry);
				}
				$realm = $currentRealm;
				$state = $STACKTRACE_STATE;
			}
		}

		if ($error) {
			$realm = $currentRealm;
			$skipEntry = ($errorsOnly && !$actualError) ||
				($keep && $line !~ /$keep/) ||
				($ignore && $line =~ /$ignore/) ||
				($realms && $realm !~ /$realms/);
			if ($debug) {
				print $errorFH "keep: " . (!$keep || $line =~ /$keep/) . "\n";
				print $errorFH "skip: " . ($skipEntry ? "true" : "false") . "\n";
				print $errorFH "!skip: " . (!$skipEntry ? "true" : "false") . "\n";
			}
			if (!$skipEntry) {
				my $entry = "-->> [$id] ($category) " . ($showRealm ? "($realm) " : " ") . $msg . "\n";
				push (@entry, $entry);
			}
			$state = $ERROR_STATE;
		}
		push(@previousLines, $line) if $NUM_LINES_ABOVE;
		if (@previousLines > $NUM_LINES_ABOVE) {
			shift(@previousLines);
		}
	}

	close($inputFH);

	return 1;
}

sub _sumAggregator {
	my $self = shift;

	my ($aggregate, $value) = @_;
	return ($aggregate ? $aggregate + $value : $value);
}

sub _countAggregator {
	return _sumAggregator(@_, 1);
}

sub _update {
	my $self = shift;

	my $hash = shift;
	my $aggregator = pop;
	my $value = pop;
	my $lastKey = pop;
	my @firstKeys = @_;

	if ($self->debug()) {
		my $errorFH = $self->errorFH();

		print $errorFH "firstKey: " . ($firstKeys[0] ? $firstKeys[0] : "") . "\n";
		print $errorFH "lastKey: $lastKey\n";
		print $errorFH "aggregator: $aggregator\n";
	}

	my $parent = $hash;
	foreach my $key (@firstKeys) {
		my $child = $parent->{$key};
		if (!$child) {
			$child = {};
			$parent->{$key} = $child;
		}
		# descend
		$parent = $child;
	}
	my $oldValue = $parent->{$lastKey};
	$parent->{$lastKey} = $self->$aggregator($oldValue, $value);
}

sub _updateCount {
	my $self = shift;

	return $self->_update(@_, 1, \&_sumAggregator);
}

sub _processNewEntry {
	my $self = shift;
	my ($filename, $linenumber, $realm, $lines, $entry) = @_;

	my $key = "";
	foreach my $line (@$entry) {
		$key = $key . $line;
	}

	my $entries = $self->entries();
	my $fileCounts = $self->fileCounts();
	my $realmCounts = $self->realmCounts();

	my $count = $entries->{$key};
	$entries->{$key} = ($count ? $count + 1 : 1);
	$self->_updateCount($fileCounts, $key, $filename);
	if ($self->debug() && $realm eq "*") {
		my $errorFH = $self->errorFH();

		print $errorFH "realm: $realm\n";
		print $errorFH "line: ${$entry}[0]";
		print $errorFH "linenumber: $linenumber\n";
	}
	$self->_updateCount($realmCounts, $key, $realm);

}


#
# processing methods:
#
sub printNewEntry {
	my ($filename, $linenumber, $realm, $lines, $entry) = @_;
	print "\n---- $filename:$linenumber\n\n";
	foreach my $line (@$lines) {
		print $line;
	}
	foreach my $line (@$entry) {
		print $line;
	}
	print "\n";
}

sub printReport {
	my $self = shift;
	my $filePath = shift;

	my $entries = $self->entries();
	my $fileCounts = $self->fileCounts();
	my $realmCounts = $self->realmCounts();

	my $errorFH = $self->errorFH();

	my $outputFH = IO::File->new("$filePath", "w");
	unless ($outputFH) {
		print $errorFH "ERROR: Can't open output $filePath: $!";
		return 0;
	}

    my @list = sort {$entries->{$b} <=> $entries->{$a}} keys %$entries;
	foreach my $entry (@list) {
		my $count = $entries->{$entry};
		print $outputFH "count=$count ";
		my $countHash = $fileCounts->{$entry};
		my @bigCounts = sort {$countHash->{$b} <=> $countHash->{$a}} keys %{$countHash};
		print $outputFH "$bigCounts[0]=$countHash->{$bigCounts[0]} ";
		$countHash = $realmCounts->{$entry};
		@bigCounts = sort {$countHash->{$b} <=> $countHash->{$a}} keys %{$countHash};
		my $len = @bigCounts;
		print $outputFH "realms:";
		for (my $idx = 0; $idx < 3 && $idx < $len; $idx++) {
			print $outputFH "$bigCounts[$idx]=$countHash->{$bigCounts[$idx]}" . (($idx < $len - 1) ? "," : "");
		}
		print $outputFH "\n";
		print $outputFH $entries->{$entry}, " ", $entry;
	}

	unless ($outputFH->close()) {
		print $errorFH "ERROR: problem closing $filePath: $!\n";
		return 0;
	}

	return 1;
}

sub descriptionString { return "ErrorCollector"; }

sub usage {
	print <<END;

	This module goes through multiple log files stored to collect and
	report on all the errors, warnings and stack traces contained in
	the logs.

	numberOfLines=<N>: number of lines of including the error or the
		warning line and lines of stacktrace to keep (default 6)

	realms=<regex>: regex to be matched against the realms in which
		errors are found should be something like "110|111|112"

	keep=<regex>: regex against which each error line is matched to
		determine whether it should be kept

	ignore=<regex>: regex against which each error line is matched to
		determine whether it should be ignored

	showRealm=[<1|0>]: if 1, the realm will be shown in the output

	errorsOnly=[<1|0>]: if specifed this script only collects errors,
		otherwise it collects errors and warnings
	
	verbose: more verbose output
	debug: debug level output

	The ignore option takes a regular expression for the warnings and
	the errors to ignore.

	For instance:.
		ignore=\"(ID4748|ID8223|ID1004|ID6736|ID8940)\"
	will extract all errors and warnings except the ones with the ID
	mentioned above.

	A sample of the output you will see is:

	count=931 keepRunning-UI-23110050\@app217-17654.4-EXIT=69 realms:prealm_663=128,prealm_720=123,prealm_560=93,
	931 -->> [ID9082] (awf:WARN)  Unhandled exception from UI:
		at ariba.ui.aribaweb.core.AWRequestContext.checkRemoteHostAddress(AWRequestContext.java:432)
		at ariba.ui.aribaweb.core.AWRequestContext.restoreHttpSessionForId(AWRequestContext.java:406)
		at ariba.ui.aribaweb.core.AWRequestContext.httpSession(AWRequestContext.java:468)
		at ariba.ui.aribaweb.core.AWRequestContext.session(AWRequestContext.java:503)
		count=219 keepRunning-UI-2310139\@app19-8246.2=15 realms:prealm_201=30,prealm_394=28,prealm_663=26,
	219 -->> [ID9082] (awf:WARN)  Unhandled exception from UI:
		at ariba.base.server.SchemaTransaction.doExecuteStatement(SchemaTransaction.java:2988)
		at ariba.base.server.SchemaTransaction.doCommit(SchemaTransaction.java:2759)
		at ariba.base.server.SchemaTransaction.commitTransaction(SchemaTransaction.java:220)
		at ariba.base.server.Transaction.commitTransaction(Transaction.java:280)
		count=116 keepRunning-UI-12410071\@app112-22483.3=11 realms:*=67,<none>=49
		116 -->> [ID9082] (awf:WARN)  Unhandled exception from UI:
		at ariba.util.core.Assert.assertFatal(Assert.java:456)
		at ariba.util.core.Assert.assertFatal(Assert.java:450)
		at ariba.util.core.Assert.that(Assert.java:89)
		at ariba.ui.sso.AWSSOBaseAuthenticator.updateSessionKeepAliveTime(AWSSOBaseAuthenticator.java:1205)

END
}

1;
