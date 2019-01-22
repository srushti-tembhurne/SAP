# $Id: //ariba/services/tools/lib/perl/ariba/Ops/LogParser/LogiFlumeLogParser.pm#1 $
package ariba::Ops::LogParser::LogiFlumeLogParser;

use strict;
use base qw(ariba::Ops::LogParser::BaseParser);

sub instanceName {
	my $class = shift;
	return "LogiFlume";
}

## Instance methods
sub logFile {
	my $self = shift;
    my $file = shift;

    $self->{'logFile'} = $file if $file;

    return $self->{'logFile'} if $self->{'logFile'};

    die "Log file has to be set\n";
}

sub scanPeriod {
    my $self = shift;
    my $period = shift;

    $self->{'scanPeriod'} = $period if $period;

    return $self->{'scanPeriod'} if $self->{'scanPeriod'};

    return $self->SUPER::scanPeriod;
}

sub parseLine {
	my $self = shift;
	my $line = shift;
	my $time = shift;

    #2016-02-03 15:56:11,758 [TailThread-93] INFO text.Cursor: tail /home/svcdev/s4/logs/perf-C0_GlobalTask4.csv : file might have been rotated! (size: old = 67265340, new = 143931607, channel = 143931607)(modifed: old = 1454487250000, new = 1454543660000)

	my ($date, $process, $msg) = $line =~ /^(\d+-\d+-\d+\s+\d+:\d+:\d+),\d+\s+\[(.*?)\]\s+(.*)\s*$/;
	return unless ($msg);

	my $uTimeOfEvent = $self->dateToUTC($date);

	# Only process event that happens less than $SCANPERIOD ago
    return if ( $time - $self->scanPeriod() > $uTimeOfEvent );

	$msg = "$date $msg";

    my $attrs = "infos";
    $attrs = "warnings" if ( $msg =~ /WARN/ );
    $attrs = "errors" if ( $msg =~ /ERROR/ );

    $attrs ne "errors" && return 1; # interested in errors only now
    if ( $self->$attrs ) {
        $self->appendToAttribute($attrs, $msg);
    }
    else {
        $self->setAttribute($attrs, $msg);
    }

	return 1;

}

1;
