# $Id: //ariba/services/tools/lib/perl/ariba/Ops/LogParser/MySQLAlertLogParser.pm#1 $
package ariba::Ops::LogParser::MySQLAlertLogParser;

use strict;

use Date::Calc;

use ariba::monitor::MySQLUtil;

my $debug = 0;

# List of keywords to make the error line to be ignored.
my @ignoreRegExList = (
					 '\[Note\]',
					 '\[Warning\] Statement may not be safe to log in statement format\.' # TMID:75498
);

# List of keywords to make the error line to be considered as warning
my @warningRegExList = (
					 '\[Warning\]'
);

# List of keywords to make the error line to be considered as error
my @errorRegExList = (
					 '\[ERROR\]',
					  'crash'
);

sub new {
	my $class       = shift;

	my $productName = shift;
	my $hostName    = shift;
	my $port        = shift;
	my $type        = shift;

	my $self = {};

	bless ($self, $class);

	$self->setProductName($productName);
	$self->setHostName($hostName);
	$self->setPort($port);
	$self->setType($type);

	$self->setCurrentTime(time());

	$self->reset();

	return($self);
}

sub newFromDBConnection {
	my $class = shift;
	my $dbc = shift;
	my $realHost = shift;

	return $class->new(
					   $dbc->product()->name(), 
					   $realHost,
					   $dbc->port(), 
					   $dbc->type()
					   );
}

sub reset {
	my $self = shift;

	$self->{errors} = [];
	$self->{warnings} = [];
}

sub errors {
	my $self = shift;
	my $errorsRef = $self->{errors};
	return $errorsRef;
}

sub warnings {
	my $self = shift;
	my $warningsRef = $self->{warnings};
	return $warningsRef;
}

sub productName {
	my $self = shift;
	return $self->{productName};
}

sub setProductName {
	my $self = shift;
	my $value = shift;
	$self->{productName} = $value;
}

sub hostName {
	my $self = shift;
	return $self->{hostName};
}

sub setHostName {
	my $self = shift;
	my $value = shift;
	$self->{hostName} = $value;
}

sub port {
	my $self = shift;
	return $self->{port};
}

sub setPort {
	my $self = shift;
	my $value = shift;
	$self->{port} = $value;
}

sub type {
	my $self = shift;
	return $self->{type};
}

sub setType {
	my $self = shift;
	my $value = shift;
	$self->{type} = $value;
}

sub currentTime {
	my $self = shift;
	return $self->{currentTime};
}

sub setCurrentTime {
	my $self = shift;
	my $value = shift;
	$self->{currenTime} = $value;
}

#
# parseFile analyzes the default or specified error log and populate two arrays:
#   - errors
#   - warnings
#   
sub parseFile {
	my $self = shift;

	my $utcStartTime = shift; # in seconds in UTC
	my $utcEndTime = shift;   # in seconds in UTC

	my $hostName = $self->hostName();
	my $port = $self->port();
	my $type = $self->type();
	my $productName = $self->productName();

	my $displayErrors = 0;
	my $logEntryTime;

	my $errors = $self->errors();
	my $warnings = $self->warnings();

	my $alertLogFileName = ariba::monitor::MySQLUtil->alertLogFilePathForPort($port); 

	unless (-r $alertLogFileName) {
		push(@$errors, "Alert log file [$alertLogFileName] cannot be read.");
		return;
	}

    my $logDataRef =
	  ariba::monitor::MySQLUtil->alertLogSubsetByTimeRange(
														   $alertLogFileName,
                                                           $utcStartTime,
														   $utcEndTime);

	for my $lineHashRef ( @$logDataRef ) {
		$self -> _parseLine($lineHashRef); # each line is a hashtable reference
	}

	if ($debug) {
		print '*' x 25, "errors", '*' x 25, "\n\t";
		print join("\n\t", @$errors), "\n";

		print '*' x 25, "warnings", '*' x 25, "\n\t";
		print join("\n\t", @$warnings), "\n";
	}

	return 1;
}

sub _parseLine {
	my $self = shift;
	my $lineHashRef = shift;

	my $errors = $self->errors();
	my $warnings = $self->warnings();

	print("\nContent of line : " . $lineHashRef -> {message} . "\n") if $debug;

	# List of errors to ignore
	print("Checking lines to ignore\n") if $debug;

	foreach my $keyword ( @ignoreRegExList )  {
		if ( $lineHashRef->{message} =~ m/$keyword/i ) {

			print("Matched ignore regex. keyword: $keyword\n") if $debug;
			print("Line : " . $lineHashRef->{message} . "\n") if $debug;

			return 1;
		}
	}

	# List of warnings

	# print("Checking for a warning\n") if $debug;
	foreach my $keyword ( @warningRegExList ) {
		if ($lineHashRef->{message} =~ /$keyword/i ) {
			my $line = "";

			if( $lineHashRef->{timestamp} ) {
				$line = $self->formatLine( $lineHashRef, 1); # 1 to show timestamp
			} else { # if we do not have the timestamp
				# Keeping this branch in case we want to show the end of the timerange in the future
				$line = $self->formatLine( $lineHashRef, 0); # 0 to not to show timestamp
			}

			push(@$warnings, $line);
			return 1;
		}
	}

	#
	# If you decide to implement a logic to defer some of the errors, 
	# implement here before returning errors.
	# 

	# List of errors
	# print("Checking for an error\n") if $debug;
	foreach my $keyword ( @errorRegExList ) {
		if ($lineHashRef->{message} =~ /$keyword/i ) {
			my $line = "";

			if( $lineHashRef->{timestamp}) {
				$line = $self->formatLine( $lineHashRef, 1); # 1 to show timestamp
			} else { # if we do not have the timestamp
				# Keeping this branch in case we want to show the end of the timerange in the future
				$line = $self->formatLine( $lineHashRef, 0); # 0 to not to show timestamp
			}

			print("pushing $line\n") if $debug;

			push(@$errors, $line);
			return 1;
		}
	}
}

sub formatLine {
	my $self = shift;
	my $lineHashRef = shift;
	my $showTimestamp = shift;

	my $line = "[" . 
		$self->productName() . 
		":" . 
		$self->hostName() . 
		":" . 
		$self->port() .  
		"]";

	if ( $showTimestamp ) {
		$line .= ariba::monitor::MySQLUtil->alertLogUTCToLocalTime($lineHashRef->{timestamp}) . 
			" ";
	}

	$line .= $lineHashRef->{message};

	return($line);
}

1;

__END__
