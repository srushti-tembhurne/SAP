package ariba::Perf::Daily;

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
use ariba::rc::InstalledProduct;

use base qw(ariba::Perf::Base);

#
# these are used to reject extreme outliers for mean/median/etc. 
#
my $TRUNCATE_MIN = 0;
my $TRUNCATE_MAX = 99999;

sub _fileNamePrefix { 
	my $self = shift;
	return return $self->productName() . "-perf-daily";
}

sub generateReport {
	my $self = shift;
	my $targetDate = shift;

	return if $self->useCSVDB();

	my %statsByRealm = ();
	$self->_statsByRealm(\%statsByRealm, $targetDate);

	$self->_printReport(\%statsByRealm);

	$self->makeReportCopies();
}

# this is for one-off report testing
sub newFromProductNameAndFile {
	my $class = shift;
	my $productName = shift;
	my $perfCSVFile = shift;

	$class->bug(1, "newFromFile() file=$perfCSVFile");

	my ($instance) = basename($perfCSVFile);
	$instance =~ s/\.csv(\.gz)?//;
	my $self = $class->_new($productName, $instance);

	my $sqlDir = $self->tmpDir();
	my $dbfile = "$sqlDir/daily-" . basename($perfCSVFile);
	$dbfile =~ s/\.gz$//;
	$self->setDbFile($dbfile);
	$self->setPerfCSVFiles([$perfCSVFile]);
	$self->setUseCSVDB(1);

	return $self;
}

sub _listCSVFilesForDate {
	my $class = shift;
	my $date = shift;
	my $archiveDir = shift;

	my $dateString =  $date->ymd("-");
	my $dateFolder =  $date->ymd("/");
	$archiveDir .= "/$dateFolder";

	$class->bug(1, "looking for $dateString in $archiveDir");

	my @perfCSVFiles = ();
	opendir(DIR, $archiveDir) or return @perfCSVFiles;
	for my $file ( grep 
			# perf-Admin6610004.2009-05-25_23.59.30.csv
			# perf-2009-05-22-all.csv.gz
			#
			{ /perf-$dateString-all\.csv|perf-(\w+)\.$dateString.+\.csv/ } 
			readdir( DIR )) {

		$class->bug(1, "found $file for $dateString");

		push (@perfCSVFiles, "$archiveDir/$file");
	}
	close(DIR);

	return @perfCSVFiles;
}

sub newFromProductNameAndDate {
	my $class = shift;
	my $productName = shift;
	my $date = shift;
	my $archiveDir = shift;

	my $instance = $date->ymd("-");
	my $self = $class->_new($productName, $instance);

	my @perfCSVFiles;
	@perfCSVFiles = $class->_listCSVFilesForDate($date, $archiveDir) if ($archiveDir);
	$self->setPerfCSVFiles([@perfCSVFiles]);

	$class->bug(1, "newFromProductNameAndDate() no_files=".scalar(@perfCSVFiles).", date=" . $date->ymd("-"));

	my $sqlDir = $self->tmpDir() . "/sqlite";
	my $dbfile = "$sqlDir/perf-".$date->ymd("-").".sqlite";
	$self->setDbFile($dbfile);
	$self->setDate($date);
	$self->setUseSQLiteDB(1);

	return $self;
}

sub _new {
	my $class = shift;
	my $productName = shift;
	my $instance = shift;

	my $self = $class->new($instance);
	$self->setProductName($productName);

	return $self;
}

sub dbConnect {
	my $self = shift;
	my $retry = shift || 0; 

	my $dbfile = $self->dbFile();
	my $sqlDir = dirname($dbfile);

	eval {
		File::Path::mkpath($sqlDir);
	};
	if ($@) {
		$self->bug(1, "Error creating $sqlDir: $@");
		return undef;
	}

	return 1 if ($self->useCSVDB());


	my $dbh = $self->dbh();
	if ($dbh) {
		$dbh->disconnect();
	}

	eval {
		$dbh = DBI->connect("dbi:SQLite:dbname=$dbfile","","", {
				PrintError => 0,
				RaiseError => 1,
				AutoCommit => 0,
				});
		die $DBI::errstr unless defined($dbh);
		$self->bug(2, "Connected to $dbfile");

		$dbh->do("PRAGMA journal_mode = OFF");
		$dbh->do("PRAGMA cache_size = 2000");
		$dbh->do("PRAGMA page_size = 8192");
		$dbh->commit();
	};

	if ($@) { 
		if ($retry) {
			die; # propagate the error.
		} else {
			$dbh->disconnect() if ($dbh);
			unlink($dbfile); # Delete possibly corrupted db. Data will be re-populated.
			$self->bug(2, "Deleted $dbfile as an attempt to rebuild the db due to $@");
			$dbh = $self->dbConnect(1);
		} 
	}

	$self->setDbh($dbh);

	return $dbh;
}

sub generateCSVDatabase {
	
}

sub generateDatabase {
	my $self = shift;
	my $force = shift;

	# recreate/populate report schema and too-slow detail file if necessary
	#
	my @perfCSVFiles = $self->perfCSVFiles();

	my $dbfile = $self->dbFile();
	my $dbExists = $self->dbExists();

	#$self->bug(2, "generateDatabase() force=$force dbExists=$dbExists\n** db settings **\n" . $self->dbStats());

	if (!$dbExists || $force || $self->shouldRefreshDB()) {
		$self->dropSchema() unless $self->useCSVDB();
		$self->createSchema() unless $self->useCSVDB();

		# setup daily too-slow detail CSV
		# 
		my $tooslowFile = $self->tooslowFileName();
		my $errorFile = $self->errorFileName();

		unlink($tooslowFile) if -f $tooslowFile;
		unlink($errorFile) if -f $errorFile;
		$self->set_overwriteDetailFile(1);

		for my $perfCSVFile (@perfCSVFiles) {
			$self->bug(1, "Working on $perfCSVFile output to db $dbfile, too-slow-detail $tooslowFile, error-detail $errorFile");
			my $fh = IO::Zlib->new($perfCSVFile, "r");

			unless ($fh) {
				warn "Could not open $perfCSVFile: $!";
				next;
			}

			$self->populateSchemaFromFileHandle($fh);
			$fh->close();
		}
	}

}

sub populateSchemaFromFileHandle {
	my $self = shift;
	my $fh   = shift;

	my $csv = Text::CSV_XS->new({ binary => 1 });

	my $headerLine = $fh->getline();
	chomp($headerLine);
	$csv->parse(lc($headerLine));
	my @csvHeaders = map { $_ =~ s/^\s*(.+)\s*$/$1/; $_ } $csv->fields();

	my %csvHeadersIndex;
	for (my $i = 0; $i < scalar(@csvHeaders); ++$i ) { $csvHeadersIndex{$csvHeaders[$i]} = $i; }

	my $date_col = $csvHeadersIndex{'date'};
	my $user_col = $csvHeadersIndex{'user'};
	my $realm_col = $csvHeadersIndex{'realm'};
	my $node_col = $csvHeadersIndex{'nodename'};
	my $destpage_col = $csvHeadersIndex{'destpage'};
	my $totaltime_col = $csvHeadersIndex{'runtimemillis'};
	my $status_col = $csvHeadersIndex{'status'};
	my $type_col = $csvHeadersIndex{'type'};
	my $sourcearea_col = $csvHeadersIndex{'sourcearea'};
	my $sourcepage_col = $csvHeadersIndex{'sourcepage'};
	my $sessionid_col = $csvHeadersIndex{'sessionid'};

	my $slowThreshold = ariba::Perf::Base->slowThreshold();

	my $count = 0;
	my $insertedCount = 0;
	my $tooslowRowCount = 0;
	my $errorRowCount = 0;

	my $tooslowFile = $self->tooslowFileName();
	my $errorFile = $self->errorFileName();

	my $tooslowDir = dirname($tooslowFile);
	my $errorDir = dirname($errorFile);

	my ($tooslowfh, $errorfh);
	my $useCSVDB = $self->useCSVDB();
	my ($csvDB, $csvDBFile, $csvDBfh);

	my ($dbh, $sth);

	my $startTime = time();

	if ($useCSVDB) {

		$csvDB = Text::CSV_XS->new({ binary => 1 });
		$csvDBFile = $self->dbFile();
		$csvDBfh = IO::File->new($self->dbFile(), "w") or die "Can't create $csvDBFile: $!";

		$csvDB->print($csvDBfh, 
			[ "date", "user", "realm", "node", "totaltime", "appmodule", "destpage", "status", "csvfileline", "type", "sourcearea", "sourcepage" ],
		);
		$csvDBfh->print("\n");

	} else {

		eval {
			File::Path::mkpath($tooslowDir);
			File::Path::mkpath($errorDir);
		};
		if ($@) {
			warn "Error creating dir : $@\n";
			return undef;
		}

		my $mode = ($self->_overwriteDetailFile() ? "w" : "a");
		$tooslowfh = IO::File->new("$tooslowFile", $mode) or do {
			warn "Couldn't open tooslow file $tooslowFile: $!";
			next;
		};

		if ($self->_overwriteDetailFile()) {
			$csv->print($tooslowfh, \@csvHeaders);
			print $tooslowfh "\n";
		}

		$errorfh = IO::File->new("$errorFile", $mode) or do {
			warn "Couldn't create error file $errorFile: $!";
			next;
		};

		if ($self->_overwriteDetailFile()) {
			$csv->print($errorfh, \@csvHeaders);
			print $errorfh "\n";
		}

		$dbh = $self->dbConnect();

		$sth = $dbh->prepare_cached(q`
			INSERT INTO daily 
			( date, user, realm, node, totaltime, appmodule, destpage, status, csvfileline, type, sourcearea, sessionid )
			VALUES 
			( ?,    ?,    ?,     ?,    ?,         ?,         ?,        ?,      ?,           ?,    ?,          ?  )
			`);
	}

	#XXX
	my $unalignedCount = 0;
	my $unfixableUnalignedCount = 0;
	my $undefinedTotaltimeCount = 0;

	while (my $line = $fh->getline()) {
		chomp($line);

		# count is also CSV-row-number, where row 0 is the header
		++$count;

		# skip the CSV header
		next if ($headerLine eq $line);

		unless ($csv->parse($line)) {
			$self->bug(1, "Failed to parse line $count: ",$csv->error_input());
			next;
		}

		my @values = $csv->fields();

		# we want to preserve rows with SourceAea==login since these
		# are the initial login page requests and they may not have a
		# user specified yet
		#
		if ($values[$sourcearea_col] && $values[$sourcearea_col] eq 'login') {
			
			# realm column could be empty for login sourcarea pages,
			# use System realm as a catch-all for these 
			unless ($values[$realm_col] && $values[$realm_col] ne '') {
				$values[$realm_col] = 'System';
			}

		} else {

			# this weeds out non-user actions, such as long downloads
			next unless ($values[$type_col] && $values[$type_col] eq 'User');

			next unless ($values[$user_col] && $values[$user_col] ne '');

			next if ($values[$sourcepage_col] && $values[$sourcepage_col] eq 'ariba.ui.sso.SSOActions');

			# skip non-user requests, e.g. monitor or resource requests
			# this gets rid of many/all not relevant very fast or very slow outliers
			next if ( $values[$sourcearea_col] && ($values[$sourcearea_col] eq 'poll' 
													|| $values[$sourcearea_col] eq 'awres' 
													|| $values[$sourcearea_col] eq 'awimg'
													|| $values[$sourcearea_col] eq 'monitorStats'
													|| $values[$sourcearea_col] eq 'clientKeepAlive')
			);
		}

		my $fieldCount = scalar(@values) - scalar(@csvHeaders);
		if ($fieldCount != 0) {
			++$unalignedCount;
			for (my $i=0; $i<= $#values; ++$i) {
				my $field = $values[$i];
				if ($values[$i] =~ /^\s*ltd|llc|inc/i && $values[$i] !~ /^"/) {
					$values[$i-1] .= ',' . $values[$i];
					splice(@values, $i, 1);
				}
			}

			if ( scalar(@values) != scalar(@csvHeaders) ) {
				# if we were unable to fix the problem, reject this
				# row outright
				$self->bug(1, "Failed to fix unescaped comma in line $count: $line");
				++$unfixableUnalignedCount;
				next;
			}
		}

		my $appmodule;
		if ($values[$destpage_col] =~ /sourcing/i) {
			$appmodule = "sourcing";
		} elsif ($values[$destpage_col] =~ /collaborate/i) {
			$appmodule = "acm";
		} elsif ($values[$destpage_col] =~ /analytics/i) {
			$appmodule = "analysis";
		} elsif ($values[$destpage_col] =~ /dashboard|sso|login/i) {
			$appmodule = "dashboard";
		}  else {
			$appmodule = "general";
		}

		# date format is:
		# Sun Sep 30 22:33:34 PDT 2007
		my $epoch = HTTP::Date::str2time($values[$date_col]);

		unless ($epoch) {
			print "bad date: $line\n";
			next;
		}

		unless (defined $values[$totaltime_col] && $values[$totaltime_col] ne '') {
			++$undefinedTotaltimeCount;
			next;
		}

		if ($values[$totaltime_col] >= $slowThreshold) {
			print $tooslowfh "$line\n" unless $useCSVDB;
			++$tooslowRowCount;
		}

		if ( $values[$status_col] =~ /error/i ) {
			print $errorfh "$line\n" unless $useCSVDB;
			++$errorRowCount;
		}
 
 		if ($useCSVDB) {
			$csvDB->print($csvDBfh, [
					$epoch,
					$values[$user_col],
					$values[$realm_col],
					$values[$node_col],
					$values[$totaltime_col],
					$appmodule,
					$values[$destpage_col],
					$values[$status_col],
					$count,
					$values[$type_col],
					$values[$sourcearea_col],
					$values[$sourcepage_col],
				]);
			$csvDBfh->print("\n");
		} else {
			$sth->execute ( $epoch,
					$values[$user_col],
					$values[$realm_col],
					$values[$node_col],
					$values[$totaltime_col],
					$appmodule,
					$values[$destpage_col],
					$values[$status_col],
					$count,
					$values[$type_col],
					$values[$sourcearea_col],
					$values[$sessionid_col],
					);
		}

		++$insertedCount;
	}

	if ($useCSVDB) {
		$csvDBfh->close();
	} else {

		$dbh->commit();

		$tooslowfh->close() or warn "Error closing tooslow file: $!";
		$errorfh->close() or warn "Error closing error file: $!";
		$self->set_overwriteDetailFile(undef);
	}

	my $endTime = time();
	my $duration = $endTime - $startTime;
	$self->bug(1, "processed $count lines, inserted $insertedCount rows, $tooslowRowCount tooslow rows, $errorRowCount error rows in $duration seconds");
	$self->bug(1, "$unalignedCount lines longer than header ($unfixableUnalignedCount unfixable), $undefinedTotaltimeCount lines without totaltime");
}

sub error { my $self = shift; return $DBI::errstr; }

sub dropSchema {
	my $self = shift;

	if ($self->dbExists()) {
		my $dbh = $self->dbh();
		$dbh->disconnect() if $dbh;
	}
	my $dbfile = $self->dbFile();
	unlink($dbfile);
}

sub dbStats {
	my $self = shift;

	my $dbh = $self->dbConnect();

	my $statsString = "";
	for my $pragma ("cache_size", "page_size") {
		my $sth = $dbh->prepare("PRAGMA $pragma");
		$sth->execute();
		my $results = $sth->fetchrow_arrayref();
		$statsString .= "\tpragma $pragma ". join(",", @$results). "\n";
	}

	return $statsString;
}

sub shouldRefreshDB {
	my $self = shift;

	my $dbFile = $self->dbFile();
	my @perfCSVFiles = $self->perfCSVFiles();

	my $dbFileMTime = (stat($dbFile))[10];

	for my $perfCSVFile (@perfCSVFiles) {
		if ( $dbFileMTime < (stat($perfCSVFile))[10] ) {
			return 1;
		}
	}

	return 0;
}

sub dbExists {
	my $self = shift;

	return 0 unless (-f $self->dbFile());

	return 1 if $self->useCSVDB();

	my $dbh = $self->dbConnect() or return 0;

	my $results = [];

	eval {
		my $sth = $dbh->prepare("SELECT tbl_name FROM sqlite_master");
		$sth->execute();
		$results = $sth->fetchall_arrayref();
	};

	if ($@) {
		$self->bug(1, "dbExists eval failed: $@");
	}

	return @$results;
	
}

sub schemaColumnTypeHash { 
	my $self = shift;

	my %colHash = (
		date       => "INTEGER",
		user       => "TEXT",
		realm      => "TEXT",
		node       => "TEXT",
		totaltime  => "INTEGER",
		appmodule  => "TEXT",
		destpage   => "TEXT",
		csvfileline => "INTEGER",
		status     => "TEXT",
		type       => "TEXT",
		sourcearea => "TEXT",
		sessionid  => "TEXT",
	);

	return %colHash;
}

sub createSchema {
	my $self = shift;

	my $dbh = $self->dbConnect();
	return 0 unless $dbh;
	
	my %colsHash = $self->schemaColumnTypeHash();

	my @schemaColumns = ();
	while (my($name, $type) = each %colsHash ) {
		push (@schemaColumns, "$name $type"); 
	}

	my $createSql = q`CREATE TABLE daily (` . join(", ", @schemaColumns) .  q`)`;

	$dbh->do($createSql);

	$dbh->commit();
}

sub perfLogsExist {
	my $self = shift;

	my @perfCSVFiles = $self->perfCSVFiles();

	if ( @perfCSVFiles ){
		return 1;
	}

	return 0;
}

1;
