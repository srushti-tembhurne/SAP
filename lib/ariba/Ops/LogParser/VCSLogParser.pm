# $Id: //ariba/services/tools/lib/perl/ariba/Ops/LogParser/VCSLogParser.pm#2 $
package ariba::Ops::LogParser::VCSLogParser;

use strict;
use base qw(ariba::Ops::LogParser::BaseParser);

sub instanceName {
	my $class = shift;
	return "vcs";
}

## Instance methods
sub logFile {
	my $self = shift;
	return "/var/VRTSvcs/log/engine_A.log";
}

## VCS prints command output out to the log file with boundries defining the
## the start and end.  We don't want to process the command output.
sub ingoreBoundries {
	my $self = shift;

	$self->setBoundryStart("+--------------------------------------------------------------------+");
	$self->setBoundryEnd("\+====================================================================+");

	return 1;
}

sub parseLine {
	my $self = shift;
	my $line = shift;
	my $time = shift;

	# Example : 2007/09/14 11:57:00 VCS INFO V-16-1-10304 Resource Mount_anlab_ora05data01 (Owner: unknown, Group: ANLAB) is offline on duck (First probe)
	my ($eventDate, $eventTime, $VCS, $level, $msgId, $msg) = split (/ /, $line, 6);

	return if (!$VCS || $VCS ne "VCS" || !$eventDate || !$eventTime);

	my $eventDateTime = "$eventDate $eventTime";
	my $uTimeOfEvent = $self->dateToUTC($eventDateTime);

	# Only process event that happens less than $SCANPERIOD ago
	return if ( $time - $self->scanPeriod() > $uTimeOfEvent );

	if ($msg =~ /MultiNICA:mnic:monitor:Switching/ || $level eq 'WARNING') {
		$msg = "$eventDateTime WARNING $msg";
		if ($self->warnings()) {
			$self->appendToAttribute('warnings', $msg);
		} else {
			$self->setWarnings($msg);
		}
			
	}

	if ($level eq 'ERROR') {
		$msg = "$eventDateTime ERROR $msg";
		if ($self->errors()) {
			$self->appendToAttribute('errors', $msg);
		} else {
			$self->setErrors($msg);
		}
	}

	return 1;
}

1;
