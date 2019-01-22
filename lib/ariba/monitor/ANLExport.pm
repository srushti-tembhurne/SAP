# $Id: //ariba/services/monitor/lib/ariba/monitor/ANLExport.pm#2 $

# Class to encapsulate the concept of an Analysis export file
#
package ariba::monitor::ANLExport;

use strict;
use ariba::Ops::PersistantObject;
use File::stat;
use base qw(ariba::Ops::PersistantObject);

my $EXPORTFILEEXTENSION    = ".exp";
my $EXPORTLOGEXTENSION = ".log";
my $IMPORTLOGEXTENSION = "-import.log";

### overriden PersistantObject methods
sub validAccessorMethods {
	my $class = shift;

	my $methodsRef = $class->SUPER::validAccessorMethods();
	$methodsRef->{'version'} 				= undef;
	$methodsRef->{'dataloadCompleteTime'} 	= undef;
	$methodsRef->{'presentationLoadOrder'} 	= undef;
	$methodsRef->{'exportStatusString'} 	= undef;
	$methodsRef->{'importStatusString'} 	= undef;
	$methodsRef->{'baseDir'} 				= undef;
	$methodsRef->{'hashKey'}				= undef;
	$methodsRef->{'debug'}					= undef;
	$methodsRef->{'zipError'}				= undef;

	return $methodsRef;
}

sub dir() {
	return undef;
}

sub save() {
	return undef;
}

sub recursiveSave() {
	return undef;
}

### end PersistantObject overrides

# given a dataload completion time, version, and basedir, return a
# ariba::monitor::ANLExport object.
#
sub newFromTimestamp {
	my $class = shift;
	my ($time, $version, $baseDir) = @_;

	my $self = $class->SUPER::new($time . $version);
	$self->setVersion($version);
	$self->setDataloadCompleteTime($time);
	$self->setHashKey($time);
	$self->setBaseDir($baseDir);
	return $self;
}

# given a filename, version, and basedir, return a ariba::monitor::ANLExport
# object.
#
sub newFromFile {
	my $class = shift;
	my ($file, $version, $baseDir) = @_;

	my $dataLoadTimestamp = $file;
	$dataLoadTimestamp =~ s/$EXPORTFILEEXTENSION(\.gz)?$//;

	my $self = $class->newFromTimestamp($dataLoadTimestamp, $version, $baseDir);

	return $self;
}

# returns the unix time of when this export completed
sub exportCompleteTime {
	my $self = shift;

	my $cannonicalExportFileName = $self->cannonicalExportLogFileName();

	my $fstat = stat($cannonicalExportFileName);

	return $fstat->mtime();
}

# returns the unix time of when this export was pushed to presentation
sub importCompleteTime {
	my $self = shift;

	my $cannonicalImportLogFileName = $self->cannonicalImportLogFileName();

	my $fstat = stat($cannonicalImportLogFileName);

	return $fstat->mtime();
}

# returns a string representing the end status of this export, or
# undef if this export has never been done.
sub exportStatusString {
	my $self = shift;

	my ($status, $id) = $self->_readExportLog();
	return $status;
}

# returns a string representing the end status of the push of this export to
# presentation, or undef if there has never been a push attempted.
sub importStatusString {
	my $self = shift;

	my $status = $self->_readImportLog();
	return $status;
}

# returns a string composed of the full path and name of the actual export
# file on disk.  If a true value is passed in as an argument, returns a
# verbose selection of information on this export.
sub toString {
	my $self = shift;
	my $full = shift;

	my $exportString = $self->existingCannonicalExportFileName() || $self->cannonicalExportFileName();
	if ($full) {
		my $status = $self->exportStatusString();
		$exportString = 
			"\texport file               -> ".$exportString.
			"\n\tversion of -T instance    -> ".$self->version().
			"\n\tdata load completed       -> ".ariba::Ops::DateTime::prettyTime($self->dataloadCompleteTime()/1000).
			"\n\texport completed          -> ".ariba::Ops::DateTime::prettyTime($self->exportCompleteTime()).
			"\n\texport status             -> ". ( defined($status) ? $status : "<none>" ).
			"\n\tpushed to presentation on -> ";
		if ($self->importStatusString()) {
			$exportString .= ariba::Ops::DateTime::prettyTime($self->importCompleteTime()).
			"\n\tpush status               -> ".$self->importStatusString();
		} else {
			$exportString .= "<never done>";
		}
	}
	
	return $exportString;

}

# returns the nextBaseId obtained when this export finished, or undef if it
# has never been done.
sub nextBaseId {
	my $self = shift;

	my ($status, $id) = $self->_readExportLog();
	return $id;
}

# saves the given nextBaseId to the export log file.  Returns true on success,
# false on failure (if export has not been done or there is a problem opening
# the export log).
sub saveNextBaseId {
	my $self 		= shift;
	my $nextBaseId 	= shift;

	return 0 if !$self->exportStatusString();

	my $exportLogFile = $self->cannonicalExportLogFileName();

	open(LOGFILE, $exportLogFile) || return;
	my @logLines = <LOGFILE>;
	close(LOGFILE);

	chomp($logLines[-1]);
	$logLines[-1] .= "#nextBaseId=".$nextBaseId."\n";

	open(LOGFILE, ">$exportLogFile") || return;
	print LOGFILE @logLines;
	close(LOGFILE);

	return 1;
}

# returns the full (cannonical) path to the actual export file on disk.  This
# is contrasted with cannonicalExportFileName(), which only generates the
# filename that this export would be saved under.
#
sub existingCannonicalExportFileName {
	my $self = shift;

	my $file = $self->cannonicalExportFileName();

	return $file if -f $file;

	$file .= ".gz";
	return $file if -f $file;

	return undef;
}

sub exportExists {
	my $self = shift;

	my $realPath = $self->existingCannonicalExportFileName();
	return defined($realPath);
}

sub zip {
	my $self = shift;

	my $filename = $self->cannonicalExportFileName();
	return $self->_processZipUnzipAction("zip", $filename);
}

sub unzip {
	my $self = shift;

	my $filename = $self->existingCannonicalExportFileName();
	return $self->_processZipUnzipAction("unzip", $filename);
}

sub _processZipUnzipAction {
	my $self = shift;
	my $action = shift || 'zip';
	my $filename = shift;


	unless (-f $filename) {
		$self->setZipError("Zip Error: $filename does not exist or is not a regular file");
		return 0;
	}

	if ($action ne 'zip' && $action ne 'unzip') {
		$self->setZipError("Zip Error: uknown action $action" );
		return 0;
	}

	my $zipBinary = "/usr/local/bin/gzip";
	if (!-x $zipBinary) {
		$zipBinary = "/usr/bin/gzip";
	}
	my @zipArgs = ();

	if ($action eq "zip") {
		return 1 if ($filename =~ /\.gz$/); # zipped file exists already
		push @zipArgs, "-6";
	} else { # action eq "uzip"
		return 1 if ($filename !~ /\.gz$/); # already unzipped
		push @zipArgs, "-d";
	}
	push @zipArgs, "-f";

	if ($self->debug()) {
		print "$0: ",$action,"ing $filename...";
	}

	if (CORE::system($zipBinary, @zipArgs, $filename)) {
		$self->setZipError("Zip Error: failed to ",$action," $filename: $!");
		return 0;
	}

	if ($self->debug()) {
		print "Done.\n";
	}

	return 1;
}

# compares the passed-in export object to this export object.  Returns true if
# both are the same class and dataload, false otherwise.
sub equals {
	my $self = shift;
	my $otherExport = shift;

	my $same = (ref($otherExport)) && (ref($otherExport) eq __PACKAGE__) && $otherExport->hashKey() eq $self->hashKey();

	return $same;
}

# removes the export file and its corresponding log files from disk.
sub purge {
	my $self = shift;

	my @filesToDelete = 
		($self->existingCannonicalExportFileName(),
		 $self->cannonicalExportLogFileName(),
		 $self->cannonicalImportLogFileName(),
		 );

	for my $file (@filesToDelete) {
		if (defined($file) && -f $file) {
			print "$0: Deleting $file" if $self->debug();
			unlink($file) || return 0;
		}
	}

	return 1;
}

sub exportFileName {
	my $self = shift;

	return $self->dataloadCompleteTime() . $EXPORTFILEEXTENSION;
}

sub exportLogFileName {
	my $self = shift;

	return $self->dataloadCompleteTime() . $EXPORTLOGEXTENSION;
}

sub importLogFileName {
	my $self = shift;

	return $self->dataloadCompleteTime() . $IMPORTLOGEXTENSION;
}

sub fullPath {
	my $self = shift;

	return $self->baseDir() . "/" . $self->version();
}

sub cannonicalExportFileName {
	my $self = shift;

	return $self->fullPath() . "/" . $self->exportFileName();
}

sub cannonicalExportLogFileName {
	my $self = shift;

	return $self->fullPath() . "/" . $self->exportLogFileName();
}

sub cannonicalImportLogFileName {
	my $self = shift;

	return $self->fullPath() . "/" . $self->importLogFileName();
}

# Reads the export log corresponding to this export, returns the export status
# and nextBaseId, or undef if no log file exists or cannot be opened.
#
sub _readExportLog {
	my $self = shift;

	my $logFileName = $self->cannonicalExportLogFileName();

	return undef unless -f $logFileName;

	open(LOGFILE, $logFileName) || return undef;

	my $line;
	while(<LOGFILE>) {
		$line = $_;
	}
	close(LOGFILE);

	return undef unless defined($line);

	chomp $line;
	$line =~ m/^(.+?)(?:#nextBaseId=(.+))?$/;
	my ($exportStatusString, $nextBaseId) = ($1, $2);

	return ($exportStatusString, $nextBaseId);
}

# Reads the data push log corresponding to this data push, returns the data
# push status and nextBaseId, or undef if no log file exists or cannot be
# opened.
#
sub _readImportLog {
	my $self = shift;

	my $importLogFileName = $self->cannonicalImportLogFileName();

	return undef unless (-f $importLogFileName); # if the file doesn't exist, import has never been done.

	open(IMPORTLOG, "<", $importLogFileName)  || die ("Failed to open import log $importLogFileName:$!");
	my $line;
	while(<IMPORTLOG>) {
		$line = $_;
	}
	close(IMPORTLOG);

	return undef unless defined($line);

	chomp $line;
	return $line;
}

##### public class methods #######

# tests if the passed-in filename is an export file
sub isExportFile {
	my $class = shift;
	my $file  = shift;

	return $file =~ m/$EXPORTFILEEXTENSION(\.gz)?$/;
}

1;
