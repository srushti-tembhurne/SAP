#!/usr/local/bin/perl -w
#
# $Id: //ariba/services/monitor/lib/ariba/monitor/CircularDB.pm#65 $
#
package ariba::monitor::CircularDB;
#
# This package manages a fixed size database of samples collected over time
# Each record stores info like: "time: value"
#
# The database grows dynamically upto a predetermined size n, (user specified)
# and then stop growing and maintains last n records
#
# It is intended to as a replacement of mrtg and rrd, neither of which do
# just the easy storage management that we need.
#
#

use strict;
use Config;
use File::Path;
use Fcntl;
use Symbol;

use POSIX qw(strftime);

use ariba::monitor::misc;
use ariba::Ops::DateTime;
use ariba::Ops::Utils;

my @publicHeaderFields = (
	    'name',         # name of the database 80 chars
	    'description',  # short description 120 chars
	                    # This field is used by snmp queries to store
	                    #   some additional informations
	    'units',        # units of the quantity recorded (like kb/s) 80 chars
	    'type',         # type of the quantity (gauge/counter) 40 chars
	    'maxRecords',   # maximum # of records in the DB
);

my @privateHeaderFields = (
	    '_version',
	    '_byteOrder',
	    '_numRecords',
	    '_startRecord',
	    '_recordLength',
	    '_lastUpdated',
);

my @headerFields = (
		@publicHeaderFields,
		@privateHeaderFields,
);
my $headerTemplate = "a80a120a80a40Na10LNNNN";
my $headerLength = length(pack($headerTemplate));

my @recordFields = (
		'time',
		'value',
);

my $recordTemplate = "Nd";
my $recordLength = length(pack($recordTemplate));
my $circularDBVersion = '1.0';
my $cdbExt = "cdb";
my $myByteOrder = $Config{byteorder};

my $scratchRoot = "/var/tmp/dat$$" . (localtime)[3,4,5];

my $MINDOUBLE = -POSIX::DBL_MAX();

my $MAXRECORDS = 1_000_000;

=pod

=head1 NAME

ariba::monitor::CircularDB - Circular Database (fixed size)

=head1 SYNOPSIS

	use ariba::monitor::CircularDB

	#
	# Create a new database or load an existing one.
	# Store maximum of 8 last values in it.
	# the type of data stored is gauge (as opposed to counter or event)
	#
	my $cdb = ariba::monitor::CircularDB->new("test/foo", 8, "gauge");

	#
	# initialize values to store in it
	#
	my @records;
	for ( my $i = 0; $i < 13; $i++) {
		$records[$i][0] = $time[$i];
		$records[$i][1] = $value[$i];
	}
	#
	# store data in the database
	#
	$cdb->writeRecords(@records);
	$cdb->writeRecord(14, 14);

	#
	# print entire db
	#
	$cdb->print();

	# get last 10 records
	@records = $self->readRecords(undef, undef, 10);
	for (my $i = 0; $i < @records; $i++) {
		print "sample $i time = $records[$i][0], value = $records[$i][1]\n";
	}

	# print first 3 records in time range 9 and 18
	$cdb->printRecords(9, 18, -3); print "-" x 30, "\n";

	# print last 2 records in the db
	$cdb->printRecords(undef, undef, 2); print "-" x 30, "\n";

	# print first 4 records in the db
	$cdb->printRecords(undef, undef, -4); print "-" x 30, "\n";

	#
	# get all the dbs in the storage area
	#
	my @cdbs = ariba::monitor::CircularDB->listDBs();
	print "Found following circular dbs in the storage area:\n";
	for my $c (@cdbs) {
		print $c->name(), "\n";
	}


=head1 DESCRIPTION

CircularDB provides a filesystem based way to store samples taken over
a period of time in a fixed size database.   The db will grow up to a
maximum size, and then will grow no futher, replacing the oldest samples
with the newest.

Each sample consists of a (time, value) pair.  
Time is a unixtime, in seconds since the epoch.  Value is a double.

This class provides an easy way to store and retrieve sample, retrieve
meta information about the quantity in the database and retrieve samples over a 
specified time range.

It has been heavily optimized for speed.


=cut

#
# class methods
#
=pod

=head1 PUBLIC CLASS METHODS

=over 4

=item * listDBs() or listDBs(directory)

Return an array of cdb objects, one per each circular db in the named directory 
or the default storage area (recursively).

=cut

sub listDBs
{
	my $class  = shift;
	my $topDir = shift;
	my $filter = shift;

	unless (defined($topDir)) {
		$topDir = ariba::monitor::misc::circularDBDir();
	} elsif ($topDir !~ m#^(/|\.)#) {
		$topDir = ariba::monitor::misc::circularDBDir() . "/$topDir";
	}

	my @cdbs = ();
	if (-d $topDir)  {
		opendir(DIR, $topDir) || die "cannot open $topDir, $!";
		my @contents = grep (! /^\./, readdir(DIR));
		@contents = map {$_ = "$topDir/$_"} @contents;
		@contents = grep(/$filter/, @contents) if $filter;

		my @files = grep (-f $_, @contents);
		my @dirs  = grep (-d $_, @contents);
		closedir(DIR);

		for my $file (@files) {

			if ($file =~ /\.$cdbExt$/) {
				push(@cdbs, $class->new($file));
			} elsif ($file =~ /\.a$cdbExt$/) {
				eval 'use ariba::monitor::AggregateCDB';
				push(@cdbs, ariba::monitor::AggregateCDB->new($file));
			}
		}

		for my $dir (@dirs) {
			next if ($dir eq "." || $dir eq "..");
			push(@cdbs, $class->listDBs($dir));
		}
	} elsif (-f $topDir)  {
		push(@cdbs, $class->new($topDir));
	}

	if (wantarray) {
		return @cdbs;
	} else {
		return \@cdbs;
	}
}

=pod

=item * createDirForFile()

create work directory

=cut

sub createDirForFile
{
	my $class = shift;
	my $file  = shift;

	my $dirname = ariba::Ops::Utils::dirname($file);
	if (($dirname) && !(-d $dirname) ) {
		mkpath($dirname); 
	}
}

=pod

=item * removeDirForFile()

remove work directory

=cut

sub removeDirForFile
{
	my $class = shift;
	my $file  = shift;

	my $dirname = ariba::Ops::Utils::dirname($file);

	if (-d $dirname) {
		rmtree($dirname);
	}
}

=pod

=item * scratchDir()

returns the current scratchDir

=cut

sub scratchDir
{
	my $class = shift;
	return $scratchRoot;
}

=pod

=item * createScratchDir()

create a temporary work directory

=cut

sub createScratchDir
{
	my $class = shift;
	my $file  = shift;

	unless (-d $scratchRoot) {
		mkpath($scratchRoot);
	}
}

=pod

=item * removeScratchDir()

remove the temporary work directory

=cut

sub removeScratchDir
{
	my $class = shift;
	my $file  = shift;

	if (-d $scratchRoot) {
		rmtree($scratchRoot);
	}
}

=pod

=item * defaultDataType()

default data type for quantity being stored in the db (gauge).

=cut

sub defaultDataType 
{
	my $class = shift();
	return "gauge";
}

=pod

=item * defaultDataUnits()

default data units of the quantity being stored in the db (absolute)

=cut

sub defaultDataUnits 
{
	my $class = shift();
	return "absolute";
}

=pod

=item * new(filename) or 

new(filename, name, maxRecords, type, units, desc)

This will create (or load) a circular database. 'filename' 
is the only required parameter. 

Even when creating all other params have default values.

Name is the pretty name of database.

Maxrecords is the maximum number of records the database can
store.  Databases will grow up to but not larger than maxrecords.
After that point old records are replaced with new records. 
The maximum value for this is 1000000.

Type can be one of 'gauge', 'counter', 'event' or 'integer'.
Defaults to 'gauge'.

Units can be one of 'absolute', 'per sec', 'per min', 
'per hour', 'per day', 'per month' or undef.  Defaults to 'absolute'.

Description is just a descriptive string.

Returns a CDB instance.

=cut

sub new
{
	my $class = shift;
	my $fileName = shift;
	# optional
	my $name = shift;
	my $maxRecords = shift;
	my $type = shift;
	my $units = shift;
	my $description = shift;

	my $loadingExisting = 0;
	unless ($name) {
		$loadingExisting = 1;
	}
	unless ($loadingExisting) {
		$name = $fileName unless ($name);
		$maxRecords = 180000 unless ($maxRecords);
		$maxRecords = $MAXRECORDS if ($maxRecords > $MAXRECORDS);
		$type = $class->defaultDataType() unless ($type);
		$units = $class->defaultDataUnits() unless ($units);
		$description = "Circular DB $name/$type with $maxRecords entries" 
								unless ($description);
	}


	if ($fileName !~ m#^(/|\.)#) {
		$fileName = ariba::monitor::misc::circularDBDir() . "/$fileName";
		# this cleans up query names when used as nasty proxies for cdb names
		# see Query.pm's constructor
		$fileName =~ s#[^\w\d_:\.\/-]#_#go;
	}

	if ($fileName !~ m|\.$cdbExt$|) {
		$fileName .= ".$cdbExt";
	}

	if ($units) {

		$units = lc($units);

		if ($units =~ m|\s*(per)[\s-]*(\w*)\s*|) {
			my $period = $2;
			$period =~ s|^sec.*|sec|;
			$period =~ s|^min.*|min|;
			$period =~ s|^h.*|hour|;
			$period =~ s|^d.*|day|;
			$period =~ s|^w.*|week|;
			$period =~ s|^mon.*|month|;
			$period =~ s|^q.*|quarter|;
			$period =~ s|^y.*|year|;
			$units = "per $period";
		}

		$units =~ s/.*(pct|percent|per cent).*/percent/;
	}

	my $self = {};
	bless($self, $class);

	$self->_setFileName($fileName);

	my $header = {
		'name'	      => $name,
		'description' => $description,
		'units'       => $units,
		'type'        => $type,
		'maxRecords'  => $maxRecords,
	};

	$self->_setHeader($header);

	return $self;
}

sub DESTROY
{
	my $self = shift();

	$self->_closeDB();
}

#
# private instance methods
#
#

sub _setFileName
{
	my $self = shift();
	my $fileName = shift();

	$self->{_fileName} = $fileName;
}

sub _setFileHandle
{
	my $self = shift();
	my $fileHandle = shift();

	$self->{_fileHandle} = $fileHandle;
}

sub _setHeader
{
	my $self = shift();
	my $header = shift();

	$self->{_header} = $header;
	$self->_assignPrivateHeaderFields();
}

sub _assignPrivateHeaderFields
{
	my $self = shift();
	my $isWrite = shift();

	my $header = $self->{_header};

	if ($header) {
		$header->{'_version'} = $circularDBVersion;
		$header->{'_recordLength'} = $recordLength;
		$header->{'_lastUpdated'} = time() if not defined $header->{'_lastUpdated'} or  $isWrite;

		$header->{'_byteOrder'} = $myByteOrder unless defined $header->{'_byteOrder'};
		$header->{_numRecords}  = 0 unless defined $header->{_numRecords};
		$header->{_startRecord} = 0 unless defined $header->{_startRecord};
	}

	return $header;
}

sub _readCurrentPhysicalRecord
{
	my $self = shift();

	my $fh = $self->{_fileHandle};

	my $record;
	my $bytesRead = sysread($fh, $record, $recordLength);

	my @record;
	if (defined($bytesRead) && $bytesRead > 0) {
		@record = unpack($recordTemplate, $record);
	}

	return @record;
}

sub _readPhysicalRecord
{
	my $self = shift();
	my $physicalRec = shift();

	my $offset = $headerLength + $physicalRec * $recordLength;

	my $fh = $self->{_fileHandle};

	if (sysseek($fh, $offset, 0) != $offset) {
		die "could not seek to record $physicalRec ($offset)\n";
	}

	return $self->_readCurrentPhysicalRecord();
}

sub _physicalRecordForLogicalRecord
{
	my $self = shift();

	#
	# -ve indicates nth record from the end
	# +ve indicates nth record from the beginning (zero based counting for
	#     this case)
	#
	# -3 = seek to 3rd record from the end
	#  5 = seek to 6th record from the beginning
	#  0 = seek to first record (start) from the beginning
	#
	my $logicalRec = shift(); 

	my $header = $self->{_header};
	my $numRecs = $header->{_numRecords};
	my $startRec = $header->{_startRecord};

	#
	# change the request for -nth record (nth record from the end)
	# to a request for mth record from the beginning, where:
	#
	# m = N + n (n is -ve)
	#
	# N : total num of records.
	#
	if ($logicalRec < 0) {
		my $recNumFromStart = $numRecs + $logicalRec; 

		# if asking for records more than there are in the db,
		# just give as many as we can
		$logicalRec = $recNumFromStart >= 0 ? $recNumFromStart : 0;
	}

	if ($logicalRec >= $numRecs) {
		die "Cannot seek to record $logicalRec with only $numRecs in db\n";
	}

	#
	# nth logical record (from the beginning) maps to mth physical record
	# in the file, where:
	# 
	# m = (n+s) % N
	#
	# s = physical record that is 0th logical record
	# N = total number of records in the db.
	#
	# 
	my $physicalRec = $logicalRec + $startRec;
	$physicalRec = ($physicalRec % $numRecs) if ($numRecs);

	return $physicalRec;
}

sub _seekToLogicalRecordForReading
{
	my $self = shift();
	my $logicalRec = shift(); 

	my $physicalRec = $self->_physicalRecordForLogicalRecord($logicalRec);

	my $offset = $headerLength + $physicalRec * $recordLength;

	my $fh = $self->{_fileHandle};

	if (sysseek($fh, $offset, 0) != $offset) {
		die "could not seek to record $physicalRec ($offset)\n";
	}

	return ($logicalRec, $physicalRec);
}

sub _readLogicalRecord
{
	my $self = shift();
	my $logicalRec = shift(); 

	my ($time, $value);

	#
	# skip over any record that has undef time or bad time values
	# Such datapoints in cdb indicate a corrupted cdb.
	#
	while (!$time || $time < 0) {
		$self->_seekToLogicalRecordForReading($logicalRec++);
		($time, $value) = $self->_readCurrentPhysicalRecord();
	}

	return ($time, $value);
}



sub _timeFromLogicalRecord
{
	my $self = shift();
	my $logicalRec = shift();

	my ($time, $val) = $self->_readLogicalRecord($logicalRec);

	return ($time);
}

# note - if no exact match, will return a record with a time
# greater than the requested value - ekay
sub _logicalRecordForTime
{
	my $self = shift();
	my $reqTime = shift();

	my $startLogicalRec = shift();
	my $endLogicalRec = shift();
	my $firstTime = 0;

	my $centerLogicalRec;
	my $header = $self->{_header};
	my $numRecs = $header->{_numRecords};

	#
	# for the very first time find start and end
	#
	if (!defined($startLogicalRec) && !defined($endLogicalRec)) {
		$startLogicalRec = 0;
		$endLogicalRec = $numRecs -1 ;

		$firstTime = 1;
	} 

	#
	# if no particular time was requested, just return the first one.
	#
	return $startLogicalRec unless($reqTime);

	#
	# if there is 2 or 1 record in the search space, return the first
	#
	if ($endLogicalRec - $startLogicalRec <= 1) {
		return $endLogicalRec;
	}

	my $startTime = $self->_timeFromLogicalRecord($startLogicalRec);

	#
	# if requested time is less than starttime, starttime is the
	# best we can do.
	#
	if ($reqTime <= $startTime) {
		return $startLogicalRec;
	}
	if ($startLogicalRec + 1 >= $numRecs) {
		return $startLogicalRec;
	}

	my $nextLogicalRec = $startLogicalRec;
	my $nextTime = $startTime;

	#
	# if readLogicalRecord encounters bad data it fabricates and
	# returns next good value. Try to get the *real* next rec.
	#
	while (($nextTime - $startTime) == 0) {
		if (++$nextLogicalRec >= $numRecs) {
			last;
		} else {
			$nextTime = $self->_timeFromLogicalRecord($nextLogicalRec);
		}
	}

	my $delta = $nextTime - $startTime;

	#
	# delta = 0 means that readLogicalRecord fabricated data on the fly
	#
	if ($delta == 0) {
		return $startLogicalRec;
	#
	# if we have wrapped over, or if the requested time is in the range
	# of start and next, return start
	#
	} elsif ($delta < 0) {
		return $startLogicalRec;
	} elsif ($reqTime <= $nextTime) {
		return $nextLogicalRec;
	}

	#
	# for the very first binary search pivot point, take an aggressive guess
	# to make search converge faster
	#
	if ($firstTime) {
		$centerLogicalRec = ($reqTime - $startTime)/($nextTime - $startTime)-1;
	} else {
		$centerLogicalRec = $startLogicalRec + 
				  ($endLogicalRec - $startLogicalRec)/2;
	}
	$centerLogicalRec = ($centerLogicalRec % $numRecs) if ($numRecs);

	my $centerTime = $self->_timeFromLogicalRecord($centerLogicalRec);
	if ($reqTime >= $centerTime) {
		$startLogicalRec = $centerLogicalRec;
	} else {
		$endLogicalRec = $centerLogicalRec;
	}

	return $self->_logicalRecordForTime($reqTime, 
						$startLogicalRec, 
						$endLogicalRec);
}

sub _openDB
{
	my $self = shift();

	my $fileName = $self->{_fileName};
	my $fh = $self->{_fileHandle};

	unless ($fh) {
		my $dirname = ariba::Ops::Utils::dirname($fileName);

		# this looks deceiving-
		# perl umask() sets the new umask and returns the previous one
		my $prevUmask = umask 002;

		File::Path::mkpath($dirname) unless -d $dirname;

		umask $prevUmask;

		$fh = gensym();

		sysopen($fh, $fileName, O_CREAT|O_RDWR) or die "Can't open $fileName: $! ";
	}

	$self->{_fileHandle} = $fh;
	return $fh;
}

sub _closeDB
{
	my $self = shift();

	my $fh = $self->{_fileHandle};

	if ($fh) {
		#
		# Since we opened the file with create flag
		# delete it if nothing was written to it.
		#
		my $size = (stat($fh))[7];
		my $fileName = $self->{_fileName};
		if ($size <= 0) {
			unlink($fileName);
		} else {
			chmod(0666, $fileName);
		}
		close($fh);
	}

	$self->{_fileHandle} = undef;
}

=pod

=head1 PUBLIC INSTANCE METHODS

=item * writeHeader()

Commit the database information in memory to disk.

=cut

sub writeHeader
{
	my $self = shift();

	# check and die on header errors to prevent further corrupting a potentially corrupted cdb
	my @errors = $self->checkHeader();
	die "Unable to write header for ", $self->fileName(), " because ", join(', ', @errors), "." if (@errors);

	my $fh = $self->_openDB();
	my $header = $self->{_header};
	my $name = $self->{_fileName};

	$header = $self->_assignPrivateHeaderFields(1);

	my @record = map { $header->{$_} } @headerFields;

	my $record = pack($headerTemplate, @record);

	sysseek($fh, 0, 0) || die "could not seek to write header, $!\n";
	syswrite($fh, $record, $headerLength) or do {
		 warn "could not write header on [$name]: $!\n";
	};

	# now reaped by DESTROY
	#$self->_closeDB();
}

=pod

=item * readHeader()

Read database header from disk and load it up into memory.
Return a hash that contains this information.

=cut
sub readHeader
{
	my $self = shift();

	#
	# if the header has already been read from backing store
	# do not read again
	#
	my $header = $self->{_header};
	return ($header) if ($header->{_synced});

	$header->{_synced} = 1; # Set synced here for new cdb as this will return on sysread below

	my $fh = $self->_openDB();
	my $record;

	sysseek($fh, 0, 0) || die "could not seek to read header, $!\n";
	sysread($fh, $record, $headerLength) || return $header;

	my @fields = unpack($headerTemplate, $record);

	my %savedHeader;
	for (my $i = 0; $i < @headerFields; $i++) {
		$savedHeader{$headerFields[$i]} = $fields[$i];
		$savedHeader{$headerFields[$i]} =~ s/\000//g;

		# XXX - this is not correct for string types like description
		# to fix those, need to know the type of each headerfield.
		if (!defined $savedHeader{$headerFields[$i]}) {
			$savedHeader{$headerFields[$i]} = 0;
		}

		$savedHeader{_synced} = 1;
	}

	#
	# overwrite the read in header with the new one if it was
	# specified.
	#
	for my $key (@publicHeaderFields) {
		if (defined($header->{$key})) {
			if ($key eq "maxRecords") {
				if ($header->{$key} != $savedHeader{$key}) {
					$savedHeader{$key} = $header->{$key};
					$savedHeader{'_maxRecordsChanged'} = 1;
				} 
			} else {
				$savedHeader{$key} = $header->{$key};
			}
		}
	}

	$self->_setHeader(\%savedHeader);

	# now reaped by DESTROY
	#$self->_closeDB();

	return ($self->{_header});
}

=pod

=item * printHeader([filehandle])

Print database header.  Filehandle is optional.  Use like $cdb->printHeader(*STDERR)

=cut
sub printHeader
{
	my $self = shift();
	my $fh = shift() || *STDOUT;

	$self->readHeader();
	my $header = $self->{_header};

	for (my $i = 0; $i < @headerFields; $i++) {

		if (!defined $header->{$headerFields[$i]}) {
			$header->{$headerFields[$i]} = '';
		}

		syswrite($fh, "$headerFields[$i] = $header->{$headerFields[$i]}\n");
	}

}

=pod

=item * checkHeader()

Checks and returns an array of errors in the header

=cut
sub checkHeader {
	my $self = shift; 
	my @errors;

	$self->readHeader();
	my $header = $self->{_header};
	my @requiredHeaders = qw(name maxRecords _numRecords _startRecord);
	my @missingHeaders;

	foreach my $field (@requiredHeaders) {
		push(@missingHeaders, $field) unless (defined($header->{$field}));
	}
	push(@errors, "Missing required headers: " . join(', ', @missingHeaders)) if (@missingHeaders);
	
	push(@errors, "_startRecord ($header->{_startRecord}) exceeds maxRecords ($header->{maxRecords})") if ($header->{_startRecord} > $header->{maxRecords});
	push(@errors, "maxRecords ($header->{maxRecords}) exceeds $MAXRECORDS") if ($header->{maxRecords} > $MAXRECORDS);

	return @errors;
}

=pod

=item * name()

Return pretty name of the database.

=cut
sub name
{
	my $self = shift();
	my $notPretty = shift;
	my $name;
	
	$self->readHeader();
	my $header = $self->{_header};
	$name = $header->{name};

	if (!$notPretty && $self->description() && ($self->description() !~ m/^Circular DB.*entries/) ) {
		$name .= $self->description();
	}
	
	return $name;
}

=pod

=item * fileName()

Return fully qualifed filename of the database.

=cut
sub fileName
{
	my $self = shift();

	return ($self->{_fileName});
}

=pod

=item * units()

Units of the quantity stored in the database.

=cut

sub units
{
	my $self = shift();

	$self->readHeader();
	my $header = $self->{_header};

	my $class = ref($self);
	my $units = $header->{units} || $class->defaultDataUnits();

	return ($units);
}

sub setUnits
{
	my $self = shift();
	my $units = shift;

	$self->readHeader();

	my $header = $self->{_header};

	$header->{units} = $units;
	return ($header->{units});
}

=pod

=item * dataType()

Data type the quantity stored in the database. (counter, integer, gauge, event)
Integer is a synomyn for counter useful when using SNMP.

=cut
sub dataType
{
	my $self = shift();

	$self->readHeader();
	my $header = $self->{_header};

	my $class = ref($self);
	my $type = $header->{type} || $class->defaultDataType();

	return ($type);
}

=pod

=item * description()

Description of the database.

=cut


sub description
{
	my $self = shift();

	$self->readHeader();
	my $header = $self->{_header};
	

	my $description = $header->{description};

	# If it's not the default Description field, it contains a snmp information
	if ( ($description) && ($description !~ m/^Circular DB.*entries/) ) {
		# We just want one space at the beginning of the string
		$description =~ s/^\s*/ /;
	}
	
	return $description;
}

sub setDescription
{
	my $self = shift();
	my $description = shift;

	$self->readHeader();

	my $header = $self->{_header};


	$header->{description} = $description;
	return ($header->{description});
}

=pod

=item * maxRecords()

Maximum number of records this cdb holds

=cut


sub maxRecords
{
	my $self = shift();

	$self->readHeader();
	my $header = $self->{_header};

	return $header->{maxRecords};
}
=pod

=item * longerName()

This returns the product name and the name as a string.

=cut
sub longerName
{
	my $self = shift();
	
	my $name = $self->name();
	
	#Total Number of Sessions
	
	my $prefix = $self->fileName();
	
	#/var/mon/cdb/s4/total_number_of_sessions.cdb
	
	#Alcatel Total number of sessions
	#/var/mon/cdb/aes/alcatel/total_number_of_sessions.cdb
	
	#remote /var/mon/cdb
	my $dir = ariba::monitor::misc::circularDBDir() . '/';
	$prefix =~ s|$dir||;
	
	#remove the final /...
	$prefix =~ s|/[^/]+$||;
	
	# should return aes or s4
	
	my $longerName = $prefix . " - ". $name;

	
	if ($self->description() && ($self->description() !~ m/^Circular DB.*entries/) ) {
		$longerName .= $self->description();
	}
	
	return $longerName;
}





=item * numRecords()

Number of samples that are currently in the database.

=cut
sub numRecords
{
	my $self = shift();

	$self->readHeader();
	my $header = $self->{_header};
	return ($header->{_numRecords});
}

=pod

=item * lastUpdated()

Time of the last update to the database, In number of seconds since epoch.

=cut
sub lastUpdated
{
	my $self = shift();

	$self->readHeader();
	my $header = $self->{_header};
	return ($header->{_lastUpdated});
}

=pod

=item * writeRecords(@records)

Bulk write samples to the database. The records array is a two dimenensional
array, like:

records[recnum][0] = time1;
records[recnum][1] = value1;

records[recnum+1][0] = time2;
records[recnum+1][1] = value2;

XXXX NOTE:  writeRecords should return the number of records written, like updateRecords
does.  On 2005-09-02 Dan & Jarek wanted to fix this, but were worried about code
that depended on the current bogus return value.  It needs more research.

=cut
sub writeRecords
{
	my $self = shift();
	my @records = @_;

	#
	# read old header if it exists.
	# write a header out, since the db may not have existed.
	#
	$self->readHeader();
	my $header = $self->{_header};

	# Reset and read in records to re-sequence the data
	if ($header->{_maxRecordsChanged}) {
		unshift(@records, $self->readRecords());

		# Needs to delete for shrinking, otherwise an extra record is stored
		$self->_closeDB();
		unlink($self->fileName());

		# Reset stats
		$header->{_numRecords}  = 0;
		$header->{_startRecord} = 0;
		delete $header->{_maxRecordsChanged};
	}

	$self->writeHeader();

	my $fh = $self->_openDB();

	#
	# records are 2 dimensional arrays,
	# with each column 0 as time, and column 1 as value
	#
	my $numRecords = @records;
	my $name = $self->{_fileName};

	for (my $i = 0; $i < @records; $i++) {
		my ($time, $value);

		$time = $records[$i][0];
		$value = $records[$i][1] if (defined($records[$i][1]));

		next unless ($time);

		#
		# protect against storing any arbitrary stuff in cdb, allow
		# storing only doubles as values in the cdb
		#
		if (defined($value) && $value !~ m|^[\d\.]+$|) {
			$value = undef;
		}

		my $record;
		if (defined($time) && defined($value)) {
			$record = pack($recordTemplate, $time, $value);
		} else {
			$record = pack($recordTemplate, $time, $MINDOUBLE);
		}



		my $offset;
		if ($header->{_numRecords} >= $header->{maxRecords}) {
			$offset = $headerLength + 
				$header->{_startRecord} * $header->{_recordLength};
			$header->{_startRecord}++;
			$header->{_startRecord} %= $header->{maxRecords};
		} else {
			$offset = $headerLength + 
				$header->{_numRecords} * $header->{_recordLength};
			$header->{_numRecords}++;
		}

		my $pos = sysseek($fh, $offset, 0) or do {
			die "could not seek to write record [$name]: $!\n";
		};

		#print "start $i record = $header->{_startRecord}, pos = $pos\n";

		syswrite($fh, $record, $header->{_recordLength}) or do {
			die "could not write record [$name]: $!\n";
		};
	}
	$self->writeHeader();

	# now reaped by DESTROY
	#$self->_closeDB();
}

=pod

=item * writeRecord(time, value)

Write a single sample to the database.    Use
writeRecords() instead of calling this repeatedly.

=cut
sub writeRecord
{
	my $self = shift();
	my $time = shift() || time();
	my $value = shift();

	my @records;

	$records[0][0] = $time;
	$records[0][1] = $value;

	$self->writeRecords(@records);
}

=pod

=item * updateRecords(@records)

Bulk update samples in the database. The records array is a two dimenensional
array, like:

records[recnum][0] = time1;
records[recnum][1] = value1;

records[recnum+1][0] = time2;
records[recnum+1][1] = value2;

=cut
sub updateRecords
{
	my $self = shift();
	my @records = @_;

	# check and die on header errors to prevent further corrupting a potentially corrupted cdb
	my @errors = $self->checkHeader();
	die "Unable to update records for ", $self->fileName(), " because ", join(', ', @errors), "." if (@errors);

	my $header = $self->readHeader();
	my $numRecs = $header->{_numRecords};

	my $fh = $self->_openDB();
	my $offset = -$header->{_recordLength};

	my $numUpdated = 0;

	for (my $i = 0; $i < @records; $i++) {
		my ($time, $value);

		$time = $records[$i][0];
		$value = $records[$i][1] if (defined($records[$i][1]));

		my $lrec = $self->_logicalRecordForTime($time);
		$lrec-- if ($lrec >= 1);

		my $rtime = $self->_timeFromLogicalRecord($lrec);
		while ($rtime < $time && $lrec < $numRecs-1) {
			$lrec++;
			$rtime = $self->_timeFromLogicalRecord($lrec);
		}

		while ($time == $rtime && $lrec < $numRecs) {
			my $record;
			if (defined($time) && defined($value)) {
				$record = pack($recordTemplate, $time, $value);
			} else {
				$record = pack($recordTemplate, $time, $MINDOUBLE);
			}
			my $pos = sysseek($fh, $offset, 1) || 
			    die "could not seek to write record, $!\n";

			syswrite($fh, $record, $header->{_recordLength}) || 
			    die "could not write record, $!\n";


			$numUpdated++;
			$lrec++;

			# need the 'unless' clause because _timeFromLogicalRecord will die
			# if the logical record is out of bounds
			$rtime = $self->_timeFromLogicalRecord($lrec) unless ($lrec == $numRecs);
		}
	}

	# now reaped by DESTROY
	#$self->_closeDB();

	return $numUpdated;
}

=pod

=item * updateRecord(time, value)

Update a single record in the database. This is to fix any bad values
that might have crept into the db.  Use updateRecords() instead
of calling this repeatedly.

=cut
sub updateRecord
{
	my $self = shift();
	my $time = shift() || time();
	my $value = shift();

	my @records;

	$records[0][0] = $time;
	$records[0][1] = $value;

	return($self->updateRecords(@records));
}

=pod

=item * discardRecordsInTimeRange(time1, time2)

Discard records in a specified time range by marking the sample values
for those records as undef.

=cut
sub discardRecordsInTimeRange
{
	my $self = shift();
	my $time1 = shift();
	my $time2 = shift();

	my $header = $self->readHeader();
	my $numRecs = $header->{_numRecords};

	my $fh = $self->_openDB();
	my $offset = -$header->{_recordLength};

	my $numUpdated = 0;

	my $lrec = $self->_logicalRecordForTime($time1);
	$lrec-- if ($lrec >= 1);

	for (my $i = $lrec; $i < $numRecs; $i++) {
		my $rtime = $self->_timeFromLogicalRecord($i);

		if ($rtime >= $time1 && $rtime <= $time2) {
			my $record;
			$record = pack($recordTemplate, $rtime, $MINDOUBLE);

			my $pos = sysseek($fh, $offset, 1) || 
				die "could not seek to write record, $!\n";

			syswrite($fh, $record, $header->{_recordLength}) || 
				die "could not write record, $!\n";

			$numUpdated++;
		}
	}

	# now reaped by DESTROY
	#$self->_closeDB();

	return $numUpdated;
}


=pod

=item * readRecords(startTime, endTime, numRecsRequested, arrayRef)

Return an array of records. The array returned is of format:

records[0][0] = time0
records[0][1] = value0

records[1][0] = time1
records[1][1] = value1

If none of the arguments are provided, this returns everything in the
database. A range of sample can be specified by using one or more of the
arguments.

startTime - start time of the samples of interest (beginning by default)

endTime   - end time of the samples of interest (last sample by default)

recs  - number of samples of interest;

	    +value 'n' means last n samples in the range

	    -value 'n' means first n samples in the range

=cut
sub readRecords
{
	my $self = shift();
	my $start = shift();
	my $end = shift();
	my $numRequested = shift();
	my $arrayRef = shift();

	if (defined($start) && defined($end) && $end < $start) {
		die "end $end has to be >= start $start in time interval requested\n";
	}

	my $header = $self->readHeader();
	if (!$header) {
		die "nothing to read in ", $self->fileName(), "\n";
	}

	my $numRecs = $header->{_numRecords};
	my $startRec = $header->{_startRecord};

	my @records = ();
	unless (defined($arrayRef)) {
		$arrayRef = \@records;
	}

	# bail out if there are no records
	if ($numRecs <= 0) {

		unless (defined($arrayRef)) {
			return @$arrayRef;
		} else {
			return @records;
		}
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

	my $fh = $self->_openDB();

	my $firstRequestedLogicalRec;
	if ($numRequested && $numRequested < 0 && !$start) {
		#
		# if reading only few records from the end, just set -ve offset
		# to seek to 
		#
		$firstRequestedLogicalRec = $numRequested;
	} else {
		#
		# compute which record to start reading from the beginning,
		# based on start time specified.
		#
		$firstRequestedLogicalRec = $self->_logicalRecordForTime($start);
	}

	#
	# if end is not defined, read all the records or only read
	# uptil the specified record.
	#
	my $lastRequestedLogicalRec;

	if (!$end) {
		$lastRequestedLogicalRec = $numRecs-1;
	} else {
		$lastRequestedLogicalRec = $self->_logicalRecordForTime($end);

		# this can return something > $end, check for that
		if ($self->_timeFromLogicalRecord($lastRequestedLogicalRec) > $end) {
			$lastRequestedLogicalRec--;
		}
	}

	# 
	# If end and start times were given, it is possible that the time span
	# described occurs entirely before or after the timespan described by the
	# cdb contents.  In such a case the first and last logical records
	# calculated above will not be correct, and right thing to do is return no
	# values.
	#
	my $requestedRecordsAreValid = 1;

	if ($end && $start) {
		my $lastRequestedTime = $self->_timeFromLogicalRecord($lastRequestedLogicalRec);
		my $firstRequestedTime = $self->_timeFromLogicalRecord($firstRequestedLogicalRec);

		if ( ($lastRequestedTime < $start && $firstRequestedTime < $start ) || 
			 ($lastRequestedTime > $end   && $firstRequestedTime > $end   ) ) {
			$requestedRecordsAreValid = 0;
		}
	}

	if ($numRecs && $requestedRecordsAreValid) {
		my $lastRequestedPhysicalRec = ($lastRequestedLogicalRec + 
							$startRec) % $numRecs;

		my ($seekLogicalRec, $seekPhysicalRec) =
				$self->_seekToLogicalRecordForReading($firstRequestedLogicalRec);

		my $record;
		my ($bytesToRead, $bytesRead);


		if ($lastRequestedPhysicalRec >= $seekPhysicalRec) {
			$bytesToRead = $recordLength * ($lastRequestedPhysicalRec - 
							$seekPhysicalRec + 1);
			$bytesRead = sysread($fh, $record, $bytesToRead);
		} else {
			my ($record1, $record2);
			$bytesToRead = $recordLength * ($numRecs - $seekPhysicalRec + 1);
			$bytesRead = sysread($fh, $record1, $bytesToRead);

			sysseek($fh, $headerLength, 0);

			$bytesToRead = $recordLength * ($lastRequestedPhysicalRec - 0 + 1);
			$bytesRead += sysread($fh, $record2, $bytesToRead);

			$record = $record1 . $record2;
		}

		my $numStored = 0;
		for (my $bytesUnpacked = 0; 
				$bytesUnpacked < $bytesRead; 
				$bytesUnpacked += $recordLength) {

			push(@{$arrayRef->[$numStored++]}, 
				unpack($recordTemplate, 
					substr($record, $bytesUnpacked, $recordLength)));

		}

		#
		# only return num of records requested
		#
		if ($numRequested && @$arrayRef >= abs($numRequested)) {
			if ($numRequested > 0 ) {
				@$arrayRef = @$arrayRef[0..$numRequested-1];
			} else {
				@$arrayRef = @$arrayRef[$numRequested..-1];
			}
		}
	}

	# now reaped by DESTROY
	#$self->_closeDB();

	unless (defined($arrayRef)) {
		return @$arrayRef;
	} else {
		return @records;
	}
}

sub _computeScaleFactorAndNumRecords
{
	my $self = shift();
	my $numRecords = shift();

	my $header = $self->readHeader();

	if ($header->{type} && $header->{type} eq "counter") {
		if ($numRecords) {
			if ($numRecords > 0) {
				$numRecords++;
			} else {
				$numRecords--;
			}
		}
	}

	my $factor = 0;
	my $units  = $header->{units};

	my $multiplier = 1;
	my $time = 0;

	if ($units) {

		if ($units =~ m|per\s*(\d+)(\D+)|) {

			$multiplier = $1;
			$time = $2;

		} elsif ($units =~ m|per\s*(\w+)|) {

			$time = $1;
		}

		if ($time eq "min") {
			$factor = 60;
		} elsif ($time eq "hour") {
			$factor = 60 * 60;
		} elsif ($time eq "sec") {
			$factor = 1;
		} elsif ($time eq "day") {
			$factor = 60 * 60 * 24;
		} elsif ($time eq "week") {
			$factor = 60 * 60 * 24 * 7;
		} elsif ($time eq "month") {
			$factor = 60 * 60 * 24 * 30;
		} elsif ($time eq "quarter") {
			$factor = 60 * 60 * 24 * 90;
		} elsif ($time eq "year") {
			$factor = 60 * 60 * 24 * 365;
		} 

		$factor *= $multiplier if $factor;
	}

	return ($factor, $numRecords);
}

=pod

=item * validateContents([filehandle])

Validate contents of the circular db. This routine will do
some data integrity checks and report errors in the database.
Output defaults to STDERR.  Use like $cdb->validateContents(*STDOUT).

=cut
sub validateContents
{
	my $self = shift();
	my $fh = shift() || *STDERR;

	my %allDates;
	my @samplesWithUndefValues;
	my @duplicateDates;
	my @counterWraps;
	my @badDates;

	my @records;
	$self->readRecords(undef, undef, undef, \@records);

	my $header = $self->readHeader();

	my $n = @records;

	my ($date, $value, $prevDate, $prevValue);
	$prevValue = -1;
	$prevDate = -1;
	for (my $i = 0; $i < $n; $i++) {
		$date = $records[$i][0];
		$value = $records[$i][1];

		$value = undef if ($value == $MINDOUBLE);

		unless(defined($allDates{$date})) {
			$allDates{$date} = 1;
		} else {
			push(@duplicateDates, $date);
		}

		unless(defined($value) && $value) {
			push(@samplesWithUndefValues, $date);
		}

		if ($header->{type} eq "counter" && $value < $prevValue) {
			push(@counterWraps, $date);
		}

		if ($date < $prevDate) {
			push(@badDates, $date);
		}

		$prevDate = $date;
		$prevValue = $value;
	}

	my $ret = 0;
	$self->printHeader($fh);

	if (@badDates) {
		syswrite($fh, "ERROR: DB has ".scalar(@badDates)." record(s) with out of order date entries\n");

		for $date (@badDates) {
			syswrite($fh, "  $date\n");
		}
		$ret++;
	} else {
		syswrite($fh, "There are no out of order date entries in this DB\n");
	}
	if (@duplicateDates) {
		syswrite($fh, "Warn: DB has ".scalar(@duplicateDates)." record(s) with same date entries\n");

		for $date (@duplicateDates) {
			syswrite($fh, "  $date\n");
		}
		$ret++;
	} else {
		syswrite($fh, "There are no duplicate date entries in this DB\n");
	}

	if (@samplesWithUndefValues) {
		syswrite($fh, "Warn: DB has ".scalar(@samplesWithUndefValues)." record(s) with undef values as samples\n");

		for $date (@samplesWithUndefValues) {
			syswrite($fh, "  $date\n");
		}
		$ret++;
	} else {
		syswrite($fh, "There are no undef sample values in this DB\n");
	}

	if (@counterWraps) {
		syswrite($fh, "info: DB has ".scalar(@counterWraps)." record(s) with counter wraps\n");

		for $date (@counterWraps) {
			syswrite($fh, "  $date\n");
		}
		$ret++;
	} elsif ($header->{type} eq "counter") {
		syswrite($fh, "There are no counter wraps in this DB\n");
	}

	return ($ret);
}

=pod

=item * aggregateUsingFunctionForRecords(function, recs)

Aggregate a specified number of records using a consolidation function.
The current set of functions supported are:

'average', 'max', 'min' and 'sum'

The aggregation function will always compute 'rate' information for 
'counter' type of quantity.

=cut
sub aggregateUsingFunctionForRecords
{
	my $self = shift();
	my $function = shift();
	my $numRecords = shift();
	my $start = shift();
	my $end = shift();

	my $factor = 0;

	($factor, $numRecords) = $self->_computeScaleFactorAndNumRecords($numRecords);

	my $counterType = defined $self->dataType() && $self->dataType() eq "counter" ? 1 : 0;

	my @records;
	$self->readRecords($start, $end, $numRecords, \@records);

	my $sum = 0;
	my $totalTime;
	my $max;
	my $min;
	my @values = ();

	my ($prevDate, $prevValue, $newValue);
	my ($timeDelta, $valDelta);
	my $numValues = 0;

	if($function eq "lastChanged") {
		return undef unless(scalar(@records) > 1);
		my $currentValue = $records[scalar(@records)-1][1];
		for(my $i = scalar(@records)-2; $i>=0; $i--) {
			my $date = $records[$i][0];
			my $value = $records[$i][1];
			if(defined($value) && $value ne $currentValue) {
				my $mins = int((time() - $date)/ 60);
				return($mins);
			}
		}

		#
		# all the same, return the first timestamp in the list
		#
		my $mins = int((time() - $records[0][0])/ 60);
		return($mins);
	}

	for (my $i = 0; $i < @records; $i++) {
		my $date = $records[$i][0];
		my $value = $records[$i][1];

		next if (!$date || $date < 0);

		$value = undef if ($value == $MINDOUBLE);

		if ($counterType) {

			$newValue = $value;
			$value = undef;

			if (defined($prevValue) && defined($newValue)) {
				$valDelta = $newValue - $prevValue;
				if ($valDelta >= 0) {
					$value = $valDelta;
				}
			}

			$sum += $value if defined($value);
			$prevValue = $newValue;
		}

		if ($factor) {
			unless ($prevDate) {
				$prevDate = $date;
				next;
			}

			$timeDelta = $date - $prevDate;
			if ($timeDelta > 0 && defined($value)) {
				$value = $factor * ($value/$timeDelta);
				$totalTime += $timeDelta;
			}

			$prevDate = $date;
		}

		next unless(defined($value));

		$numValues++;

		unless(defined($max)) {
			$max = $value;
		}

		unless(defined($min)) {
			$min = $value;
		}

		$sum += $value unless $counterType;
		$max = $value > $max ? $value : $max;
		$min = $value < $min ? $value : $min;

		push (@values, $value);
	}

	my $return;

	if ($function eq "median") {
		@values = sort { $a <=> $b } @values;
		my $midpoint = $numValues/2;
		my $median = $values[$midpoint];
		if ($numValues % 2) {
			$median = ($median + $values[($midpoint+1)])/2;
		}
		return $median;
	} elsif ($function eq "average") {
		if ($counterType) {
			$return = ($sum/$totalTime) if ($totalTime && defined($sum));
		} else {
			$return = ($sum/$numValues) if ($numValues && defined($sum));
		}
	} elsif ($function eq "percentChange") {
		if($values[0] == 0) {
			$return = 0;
		} else {
			$return = ($values[$#values] - $values[0]) / $values[0] * 100;
		}
	} elsif ($function eq "change") {
		if($values[0] == 0) {
			$return = 0;
		} else {
			$return = ($values[$#values] - $values[0]);
		}
	} elsif ($function eq "sum") {
		$return = $sum;
	} elsif ($function eq "max") {
		$return = $max;
	} elsif ($function eq "min") {
		$return = $min;
	} else {
		die "aggregateValueUsingFunctionForRecords() $function not supported\n";
	}

	return $return;
}

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

sub _debugDate
{
	my $date = shift;
	return POSIX::strftime("%d %H", localtime($date));
}

sub _convertValuesBetweenSparcAndX86 {
	my $class = shift;
	my $value = shift;

	if (defined($value)) {
		my @bytes = unpack("C*", pack("d", $value) );
		$value = unpack("d", pack("C*", reverse(@bytes)));
	}

	return $value;
}

sub _convertCDBValuesBetweenSparcAndX86 {
	my $self = shift;
	my $recordsRef = shift;

	my $class = ref($self);

	for ( my $i = 0; $i < @$recordsRef; $i++) {
		$recordsRef->[$i][1] = $class->_convertValuesBetweenSparcAndX86($recordsRef->[$i][1]);
	}
}

=pod
=item * convertCDBFromSparcToX86 ()

converts a CDB -- header and all records from sparc to 64 bit x86 format.
Since the data is binary, this conversion is required. We also need to
update the byte order thats recorded in the header, to indicate that the
conversion is complete.

=cut

sub convertCDBFromSparcToX86 {
	my $self = shift;

	$self->readHeader();
	my $header = $self->{_header};
	my @records;
	my $converted = 0;

	if ($header->{'_byteOrder'} != $myByteOrder) {

		$self->readRecords(undef, undef, undef, \@records);
		$self->_closeDB();

		my $filename = $self->fileName();
		unlink($filename);

		$header->{'_version'} = $circularDBVersion;
		$header->{'_recordLength'} = $recordLength;

		$header->{'_byteOrder'} = $myByteOrder;
		$header->{_numRecords}  = 0;
		$header->{_startRecord} = 0;

		$self->writeHeader();

		$self->_convertCDBValuesBetweenSparcAndX86(\@records);
		$self->writeRecords(@records);

		$converted = 1;
	}

	$self->_closeDB();

	return $converted;
}

=pod

=item * printRecords(start, end, recs, fh, dateformat, cookedForGraphing)

Prints the records in the db. All arguments are optional.
start, end and recs have same meaning as readRecords() method.

fh - specifies the file handle to print records to (STDOUT by default)

dateformat - is the 'gnuplot' style date to use for printing.

if cookedForGraphing is true then we compute 'rate' information for
'counter' type of quantity, and do summarization for 'event' type.

=cut
sub printRecords
{
	my $self = shift();
	my $start = shift();
	my $end = shift();
	my $numRequested = shift();
	my $fh = shift() || *STDOUT;
	my $dateFormat = shift();
	my $cookedForGraphing = shift();
	my $adjustTz = shift();

	my $convert = defined($dateFormat);
	my ($date, $value);

	my $factor = 0;
	my $tzadj  = 0;

	if ($cookedForGraphing) {
		($factor, $numRequested) = $self->_computeScaleFactorAndNumRecords($numRequested);

		$adjustTz = 1;
	}

	if ($adjustTz) {
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

	# for speed
	my $counterType = ($self->dataType() eq "counter");
	my $gaugeType = ($self->dataType() eq "gauge");
	my $eventType = ($self->dataType() eq "event");

	my ($prevDate, $prevValue, $newValue);
	my ($timeDelta, $valDelta);

	# this for event type graphs, we summarize
	# the count number of entries in the db per some time unit,
	# ignoring the value of the records
	my $sum = 0;
	my $boundaryDate = $n && ($records[0][0] + $factor);

	for (my $i = 0; $i < $n; $i++) {
		$date = $records[$i][0];
		$value = $records[$i][1];

		next if (!$date || $date < 0);

		$value = undef if ($value == $MINDOUBLE);

		#
		# if counter type data, compute rate.
		#
		# account for undef in the db.
		# account for samples that got recorded twice.
		# account for counter wraps
		#
		if ($cookedForGraphing) {

			if ($eventType) {

				if ($date < $records[0][0]) {
					next;
				} elsif ($date < $boundaryDate) {
					$sum += $value;

					# if we have reached end
					# of data without hitting the
					# boundary, go ahead use it
					if ($i + 1 == $n) {
						$value = $sum;
					} else {
						next;
					}
				} else {

					while ($date >= $boundaryDate) {
						_printRecord($fh, $boundaryDate - $factor, $sum, $dateFormat, $tzadj);
						$boundaryDate += $factor;
						$sum = 0;
					}

					$sum = $value;
					next;
				}

			} else {

				if ($counterType) {

					$newValue = $value;
					$value = undef;

					if (defined($prevValue) && defined($newValue)) {

						$valDelta = $newValue - $prevValue;

						if ($valDelta >= 0) {
							$value = $valDelta;
						}
					}

					$prevValue = $newValue;
				}

				if ($factor) {
					unless ($prevDate) {
						$prevDate = $date;
						next;
					}

					$timeDelta = $date - $prevDate;

					if ($timeDelta > 0 && defined($value)) {
						$value = $factor * ($value/$timeDelta);
					}

					$prevDate = $date;
				}
			}
		}

		_printRecord($fh, $date, $value, $dateFormat, $tzadj);
	}

	if ($eventType && $cookedForGraphing) {

		while ($n && $records[-1][0] >= $boundaryDate) {
			_printRecord($fh, $boundaryDate - $factor, $sum, $dateFormat, $tzadj);
			$boundaryDate += $factor;
			$sum = 0;
		}
	}
	
	return ($n && ($records[0][0]-$tzadj), $n && ($records[-1][0]-$tzadj));
}

=pod

=item * print([filehandle])

Print the contents of whole database.
Defaults to STDOUT.  Use like $cdb->print(*STDERR)

=cut
sub print
{
	my $self = shift();
	my $fh = shift() || *STDOUT;

	my $dateFormat = '%Y-%m-%d %H:%M:%S';

	syswrite($fh, "============== Header ================\n");
	$self->readHeader();
	$self->printHeader($fh);
	syswrite($fh, "============== Records ================\n");
	$self->printRecords(undef, undef, undef, $fh, $dateFormat);
	syswrite($fh, "============== End ================\n");
	syswrite($fh, "============== Cooked Records ================\n");
	$self->printRecords(undef, undef, undef, $fh, $dateFormat, 1);
	syswrite($fh, "============== End ================\n");
}

#
# This is embedded test code
#

sub main
{
	my $cdb = ariba::monitor::CircularDB->new("test/foo", "foo", 7, "counter");

	my @records;

	for ( my $i = 0; $i < 12; $i++) {
		$records[$i][0] = $i;
		$records[$i][1] = $i;
	}

	$cdb->writeRecords(@records);

	$cdb->print();

	$cdb->printRecords(9, 18, -3); print "-" x 30, "\n";
	$cdb->printRecords(undef, undef, 2); print "-" x 30, "\n";
	$cdb->printRecords(undef, undef, -4); print "-" x 30, "\n";

	$cdb->updateRecord(7, 14);
	$cdb->print();

	#my @cdbs = ariba::monitor::CircularDB->listDBs();
	#print "Found following circular dbs in the storage area:\n";
	#for my $c (@cdbs) {
	#	print $c->name(), "\n";
	#	print $c->description(), "\n";
	#}
}

#main();

1;

__END__

=pod

=back

=head1 AUTHOR

Manish Dubey <mdubey@ariba.com>

=head1 SEE ALSO

ariba::monitor::CircularDBGraph for graphing one or more circular dbs,
ariba::monitor::AggregateCDB for summing multiple CDBs together for graphing.

=cut

