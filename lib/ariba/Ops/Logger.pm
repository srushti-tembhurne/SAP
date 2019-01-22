package ariba::Ops::Logger;

#
# Log4perl-like package
# This is intended as a simplification / transitional package 
#

use strict;
use ariba::Ops::PersistantObject;
use ariba::Ops::DateTime;

use base qw(ariba::Ops::PersistantObject);

my $LOG_LEVEL_ERROR = 1;
sub ERROR_LOG_LEVEL { return $LOG_LEVEL_ERROR; }

my $LOG_LEVEL_WARN  = 2;
sub WARN_LOG_LEVEL { return $LOG_LEVEL_WARN; }

my $LOG_LEVEL_INFO  = 3;
sub INFO_LOG_LEVEL { return $LOG_LEVEL_INFO; }

my $LOG_LEVEL_DEBUG = 4;
sub DEBUG_LOG_LEVEL { return $LOG_LEVEL_DEBUG; }

my @levelToString = ();

$levelToString[$LOG_LEVEL_ERROR] = "error";
$levelToString[$LOG_LEVEL_WARN]  = "warning";
$levelToString[$LOG_LEVEL_INFO]  = "info";
$levelToString[$LOG_LEVEL_DEBUG] = "debug";

my $currentClassLogLevel = $LOG_LEVEL_INFO;

#
# returns singleton logger object
#
sub logger {
	my $class = shift;
	my $instance = shift || "";

	my $logger = $class->SUPER::new($class . $instance);

	return $logger;
}

sub logLevel {
	my $class = shift;

	if (ref($class)) {
		my $logLevel = $class->SUPER::logLevel();
		return $logLevel if defined($logLevel);
	}
	return $currentClassLogLevel;
}

sub setLogLevel {
	my $class = shift;
	my $level = shift;

	if ($level < $LOG_LEVEL_ERROR || $level > $LOG_LEVEL_DEBUG) {
		$level = $LOG_LEVEL_DEBUG;
	}
	
	if (ref($class)) {
		$class->SUPER::setLogLevel($level);
	} else {
		$currentClassLogLevel = $level;
	}
}

sub _printMsg {
	my $self = shift;
	my $logLevel = shift;
	my $msg = shift;

	return if ($self->logLevel() < $logLevel);

	unless($self->quiet()) {
		print(ariba::Ops::DateTime::prettyTime(time()) . " (" . $levelToString[$logLevel] . ") " . $msg . "\n");
	}

	if($self->logFile()) {
		my $FH;
		if($self->fh()) {
			$FH = $self->fh();
		} else {
			open($FH, "> " . $self->logFile());
			my $old = select($FH);
			$|=1;
			select($old);
			$self->setFh($FH);
		}

		print $FH ariba::Ops::DateTime::prettyTime(time()) . " (" . $levelToString[$logLevel] . ") " . $msg . "\n";
	}
}

sub info { my $self = shift; return $self->_printMsg($LOG_LEVEL_INFO, @_); }
sub warn { my $self = shift; return $self->_printMsg($LOG_LEVEL_WARN, @_); }
sub error { my $self = shift; return $self->_printMsg($LOG_LEVEL_ERROR, @_); }
sub debug { my $self = shift; return $self->_printMsg($LOG_LEVEL_DEBUG, @_); }

1;
