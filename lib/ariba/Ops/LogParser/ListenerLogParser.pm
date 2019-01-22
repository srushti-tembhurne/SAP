package ariba::Ops::LogParser::ListenerLogParser;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/LogParser/ListenerLogParser.pm#2 $
# A class to parse listener logs for connection information.

use strict; 
use ariba::Ops::LogParser::BaseParser; 
use ariba::util::OraInfo;

use Date::Parse;

use base qw(ariba::Ops::LogParser::BaseParser);

sub instanceName {
	my $class = shift; 

	return 'listener-log';
}

sub logFile {
	my $class = shift; 

	return ariba::util::OraInfo::sidToOracleHome() . '/network/log/listener.log';
}

sub validAccessorMethods {
	my $class = shift;

	my $methodsRef = $class->SUPER::validAccessorMethods();

	$methodsRef->{'connectionAttemptsForSidMapRef'} = undef;
	$methodsRef->{'connectionAttemptsPerSecondForSidMapRef'} = undef;
	
	return $methodsRef;
}

sub objectLoadMap {
	my $class = shift; 

	my $typeMapRef = $class->SUPER::objectLoadMap(); 

	$typeMapRef->{'connectionAttemptsForSidMapRef'} = 'SCALAR';
	$typeMapRef->{'connectionAttemptsPerSecondForSidMapRef'} = 'SCALAR';

	return $typeMapRef;
}

sub reset {
	my $self = shift; 

	$self->SUPER::reset();

	$self->setFilePosition(0);
	$self->setConnectionAttemptsForSidMapRef({});
	$self->setConnectionAttemptsPerSecondForSidMapRef({});
}


sub connectionAttemptsForSid {
	my $self = shift;
	my $sid = shift;

	my $mapRef = $self->connectionAttemptsForSidMapRef();

	return $mapRef->{$sid} || 0;	
}

sub highestConnectionAttemptsForSid {
	my $self = shift;
	my $sid = shift;

	my $mapRef = $self->connectionAttemptsPerSecondForSidMapRef();
	my $highestConnectionAttempts = 0;

	if ($mapRef->{$sid}) {
		foreach my $timeStamp (keys(%{ $mapRef->{$sid} })) {
			if ($mapRef->{$sid}->{$timeStamp} > $highestConnectionAttempts) {
				$highestConnectionAttempts = $mapRef->{$sid}->{$timeStamp};
			}
		}
	}

	return $highestConnectionAttempts;
}

sub scanPeriod {
	my $class = shift; 

	return 5 * 60 + 5; # 5 mins interval + 5 seconds margin
}

sub parseLine {
	my $self = shift;
	my $line = shift;
	my $startTime = shift; 

	my $connMapRef = $self->connectionAttemptsForSidMapRef();
	my $connPerSecMapRef = $self->connectionAttemptsPerSecondForSidMapRef();

	# 22-SEP-2010 13:40:34 * (CONNECT_DATA=(SID=S4MIG02)(CID=(PROGRAM=)(HOST=__jdbc__)(USER=svcmig2))) * (ADDRESS=(PROTOCOL=tcp)(HOST=10.10.13.228)(PORT=37322)) * establish * S4MIG02 * 0
	print "Parsing line: $line\n" if ($self->debug() && $self->debug() >= 2);
	if ($line =~ /(\d+-\w+-\d+\s+\d+:\d+:\d+) .+ \(CONNECT_DATA=\(SID=(\w+)\)/) {
		my $time = str2time($1);
		my $sid = uc($2);
		
		print "\tTime: $time\tSid: $sid\n" if ($self->debug() && $self->debug() >= 2);
		if ($time && $time > ($startTime - $self->scanPeriod())) {
			$connMapRef->{$sid}++;
			$connPerSecMapRef->{$sid} = {} unless ($connPerSecMapRef->{$sid});
			$connPerSecMapRef->{$sid}->{$time}++;
		}
	}
}

1;
