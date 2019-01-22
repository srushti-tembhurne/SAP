# $Id: //ariba/services/tools/lib/perl/ariba/Ops/LogParser/BaseParser.pm#2 $
package ariba::Ops::LogParser::BaseParser;

use strict;
use base qw(ariba::Ops::PersistantObject);

use ariba::Ops::PersistantObject;
use ariba::Ops::DateTime;

# Abstract methods
sub instanceName {
	my $class = shift;

	# Ex. sendmail, vcs, listener-log
	die __PACKAGE__ . " must implement abstract method instanceName()";	
}

sub parseLine {
	my $self = shift;
	my $line = shift;
	my $startTime = shift;

	die __PACKAGE__ . " must implement abstract method parseLine()";	
}

## Class methods
sub new {
	my $class = shift;

	my $instanceName = $class->instanceName();
	return unless $instanceName;
	my $self = $class->SUPER::new($instanceName);

	$self->reset();

	return $self;
}

sub validAccessorMethods {
	my $class = shift;

	my $methodsRef = $class->SUPER::validAccessorMethods();

	$methodsRef->{'infos'}        = undef;
	$methodsRef->{'warnings'}     = undef;
	$methodsRef->{'errors'}       = undef;
	$methodsRef->{'logFile'}      = undef;
	$methodsRef->{'scanPeriod'}   = undef;
	$methodsRef->{'debug'}        = undef;
	$methodsRef->{'runError'}     = undef;
	$methodsRef->{'boundryStart'} = undef;
	$methodsRef->{'boundryEnd'}   = undef;
	$methodsRef->{'filePosition'} = undef;

	return $methodsRef;
}

sub objectLoadMap {
	my $class = shift;

	my $mapRef = $class->SUPER::objectLoadMap(); 
	
	$mapRef->{'infos'}				= '@SCALAR';
	$mapRef->{'warnings'}			= '@SCALAR';
	$mapRef->{'errors'}				= '@SCALAR';
	$mapRef->{'logFile'}			= 'SCALAR';
	$mapRef->{'scanPeriod'}			= 'SCALAR';
	$mapRef->{'debug'}				= 'SCALAR';
	$mapRef->{'runError'}			= 'SCALAR';
	$mapRef->{'boundryStart'}		= 'SCALAR';
	$mapRef->{'boundryEnd'}			= 'SCALAR';
	$mapRef->{'filePosition'}		= 'SCALAR';

	return $mapRef;
}

# This at least works for syslog and vcs log time formats
sub dateToUTC {
	my $class = shift;
	my $dateString = shift;	

	return ariba::Ops::DateTime::syslogToTimestamp($dateString);
}

# No backing store
sub dir {
	return undef;
}

## Instance methods
sub reset {
	my $self = shift; 

	$self->setInfos(); 
	$self->setWarnings();
	$self->setErrors();
	$self->setRunError();
	$self->setFilePosition();
}

sub scanPeriod {
	my $self = shift;
	return 2 * 60 * 60; # 2 hours
}

sub ingoreBoundries {
	my $self = shift;

	return 0;
}

sub parseLog {
	my $self = shift;

	my $logFile = $self->logFile();
	unless (-f $logFile) {
		$self->setRunError("$logFile not found");
		return;
	}

	open(LOG, $logFile) || return undef;
	print "Parsing $logFile\n" if $self->debug();

	my $lineCount = 0;
	my $time = time();
	my $ignoreLine = 0;
	my ($boundryStart, $boundryEnd);

	if ($self->ingoreBoundries()) {
		$boundryStart = $self->boundryStart();
		$boundryEnd = $self->boundryEnd();
	}

	if (defined $self->filePosition()) {
		my $fileSize = -s $logFile;
		if ($self->filePosition() <= $fileSize) {
			seek(LOG, $self->filePosition(), 0);
			print 'Seeked to position ', $self->filePosition(), "\n" if ($self->debug());
		}
	}

	while (my $line = <LOG>) {

		next if ($line =~ m/^\s*#/);
		next if ($line =~ m/^\s*$/);

		chomp $line;

		$ignoreLine = 1 if $boundryStart && $line eq $boundryStart;

		if ($ignoreLine && $line eq $self->boundryEnd()) {
				$ignoreLine = 0; 
				next;
		}

		next if $ignoreLine;

		$self->parseLine($line, $time);

		++$lineCount;

		if ($self->debug()) {
			print "Doing line $lineCount\r" if ($lineCount % 100 == 0);
		}
	}

	if (defined $self->filePosition()) {
		my $position = tell(LOG);
		$self->setFilePosition($position) if ($position >= 0);
	}

	if ($self->debug()) {
		print "parsed $lineCount lines\n";
	}

	close(LOG);
}

sub infoCount {
	my $self = shift;

	my @infos = $self->infos();
	return scalar(grep(defined($_), @infos));
}

sub warningCount {
	my $self = shift;

	my @warnings = $self->warnings();
	return scalar(grep(defined($_), @warnings));
}

sub errorCount {
	my $self = shift;

	my @errors = $self->errors();
	return scalar(grep(defined($_), @errors));
}

sub allResults {
	my $self = shift;

	my @results = ();
	push(@results, $self->errors()) if $self->errors();
	push(@results, $self->warnings()) if $self->warnings();
	push(@results, $self->infos()) if $self->infos();

	if (scalar @results) {
		return join("\n", @results);
	} else {
		return;
	}
}

1;



























