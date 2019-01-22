#
# $Id: //ariba/services/tools/lib/perl/ariba/Ops/AQLClient.pm#6 $

package ariba::Ops::AQLClient;


use strict;
use ariba::Ops::Utils;
use ariba::Ops::DBConnection;
use ariba::rc::Utils;
use File::Path;
use POSIX qw(strftime);
use URI::Escape;


require "geturl";


my $DEFAULT_TIMEOUT = 3600; # 1 hour for aql-metrics' ACPOrderAmount.aql

sub new {
	my $class = shift;

	my $self = {};

	bless($self, $class);

	$self->setColsep();

	return $self;	
}

sub newFromAQLConnection {
	my $class = shift;
	my $aqlConnection = shift;

	my $self = {};

	bless($self, $class);

	$self->{'aqlConnection'} = $aqlConnection;

	$self->setColsep();

	return $self;	
}

sub colsep {
	my $self = shift;

	return $self->{'colsep'};
}

sub setColsep {
	my $self = shift;
	my $colsep = shift ;

	return $self->{'colsep'} = $colsep || "\t";
}



sub DESTROY {
	my $self = shift;
	$self->disconnect();
}

sub debug {
	my $self = shift;
	return $self->{'debug'} || 0;
}

sub setDebug {
	my $self = shift;
	$self->{'debug'} = shift;
}

sub error {
	my $self = shift;
	return $self->{'error'};
}

sub setError {
	my $self = shift;
	$self->{'error'} = shift;
}

sub connect {
	my $self = shift;
	my $timeout = shift || $DEFAULT_TIMEOUT;

	return 1;
}

sub disconnect {
	my $self = shift;

}

sub executeAQLWithTimeout {
	my $self = shift;
	my $aql = shift;
	my $timeout = shift || $DEFAULT_TIMEOUT;
	my $resultsRef = shift;

	my $start = time();
	my $coderef;

	if ( ref($resultsRef) eq "ARRAY" ) {
		$coderef = sub { @$resultsRef = $self->executeAQL($aql); };
	} else {
		$coderef = sub { $$resultsRef = $self->executeAQL($aql); };
	}

	if(! ariba::Ops::Utils::runWithForcedTimeout($timeout,$coderef) ) {
		my $end = time();
		my $duration = "start=" . strftime("%H:%M:%S", localtime($start)) .
				" end=" . strftime("%H:%M:%S", localtime($end));
		
		my $errorString = $self->timedOutErrorString() . " [$aql] $duration";
		$self->setError($errorString);
		if ( ref($resultsRef) eq "ARRAY" ) {
			@$resultsRef = ($errorString);
		} else {
			$$resultsRef = $errorString;
		}
		return 0;
	}
	return 1;
}

sub timedOutErrorString {
	my $class = shift;

	return "timed out running AQL";
}

sub executeAQL {
	my $self = shift;
	my $aql = shift;

	my @results = ();

	my $aqlConnection = $self->{'aqlConnection'};

	unless ($aqlConnection) {
		my $errorString = "AQLConnection not defined";
		$self->setError($errorString);
		return ref($self) . "->executeAQL() : error for AQL : ". $errorString;
	}

	my $timeout = $DEFAULT_TIMEOUT;
	my @errors;


	# Default escape pattern is :  "^A-Za-z0-9\-_.!~*'()"
	# But ( and ) need to be escaped
	my $escapePattern = "^A-Za-z0-9\-_.!~*'";

	my $url = $aqlConnection->directActionUrl(); 

	my @aqlQuery = ("query=" .  uri_escape($aql, $escapePattern)  . "&" .
						 "separator=" .  uri_escape($self->colsep(), $escapePattern)
						);

	if ($self->debug()) {
		print "AQL url is : [$url]\n";
	}
	
	my @geturlArgs = ("-e","-q", "-timeout",$timeout,"-results",\@results, "-errors", \@errors, 
							"-followRedirects", "-contenttype", 'application/x-www-form-urlencoded', "-postmemory", \@aqlQuery);

	eval 'main::geturl(@geturlArgs, $url);';

	$self->setError(undef);			

	if (@errors) {
		$self->setError(join("\n", @errors));			
	}

	if ($self->debug()) {
		print "AQL result is : [@results]\n";
	}

	my $joinedResults = join('', @results);

	
	$self->setError("Service temporary unavailable") if ($joinedResults =~ m/temporarily unavailable/i);			

	if (wantarray) {
		return @results;
	} else {
		return $joinedResults;
	}
}

1;
