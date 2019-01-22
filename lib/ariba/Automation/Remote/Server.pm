package ariba::Automation::Remote::Server;

use strict;
use warnings;

use CGI;
use File::Basename;

use ariba::Automation::Constants;
use ariba::Automation::GlobalState;
use ariba::Automation::Remote::Utils;
use ariba::Automation::Remote::Robot;

use ariba::rc::Utils;

use dmail::LockLib;

sub new {
	my $class = shift;
	
	my $self = {};
	bless($self, $class);

	return $self;
}

sub process {
	my $self = shift;
	my $cgi = shift;

	my $action = $cgi->param(cgiAction());

	# for backward compatibility, assume missing action is an update
	unless ($action) {
		#$self->showError($cgi, "Missing action");
		$action = cgiActionUpdate();
	}

	if ($action eq cgiActionShow()) {
		$self->processShow($cgi);
	} elsif ($action eq cgiActionGetvar()) {
		$self->processGetVar($cgi);
	} elsif ($action eq cgiTimingReports()) {
		$self->processTimingReport($cgi);
	} elsif ($action eq cgiActionUpdate()) {
		$self->processUpdate($cgi);
	} else {
		$self->showError($cgi, "Unrecognized action: $action");
	}
}

sub showError {
	my $self = shift;
	my $cgi = shift;
	my $msg = shift;

	my %headerHash = (
			-type          => "text/html",
			-status        => "500",
			-Pragma        => "no-cache",
			-Cache_control => "no-cache",
			);

	print $cgi->header(%headerHash);
	print "<html>\n";
	print "Error: " . $msg . "\n" if $msg;
	print "</html>\n";

}

sub processGetVar {
	my $self = shift;
	my $cgi = shift;

	my $robotName = $cgi->param(cgiRobotName());

	unless ($robotName) {
		$self->showError($cgi, "missing parameter" .cgiRobotName());
		return;
	}


	my $robot = ariba::Automation::Remote::Robot->newFromNameNoInit($robotName);
	my @vars = $cgi->param(cgiVar());

	my %headerHash = (
			-type          => "text/html",
			-status        => "200",
			-Pragma        => "no-cache",
			-Cache_control => "no-cache",
			);

	print $cgi->header(%headerHash);

	for my $v (@vars) {
	
		if ($v eq "lastGoodChange")
		{
			print $robot->lastGoodChange() . "\n" if ($robot->lastGoodChange());
			next;
		}
	
		print $robot->attribute($v) . "\n";
	}

}

sub processShow {
	my $self  = shift;
	my $cgi = shift;

	my $robotName = $cgi->param(cgiRobotName());

	my $robot = ariba::Automation::Remote::Robot->newFromNameNoInit($robotName);

	my $state = $robot->state() || "[unknown]";
	my $status = $robot->status();
	my $lastAction = $robot->lastAction();

	my %headerHash = (
			-type          => "text/html",
			-status        => "200",
			-Pragma        => "no-cache",
			-Cache_control => "no-cache",
			);

	print $cgi->header(%headerHash);
	print "<html>\n";

	print "Robot: " . $robot->name(). "\n";
	print "Status: $status\n";
	print "Failed action: " . $robot->errorAction() . "\n" if ($robot->errorAction());
	print "Status Change: " . ariba::Ops::DateTime::prettyTime($robot->statusChangeTime()) . "\n";
	print "LastAction: " . ($lastAction ? $lastAction->instance() . " (".ref($lastAction).")" : "[none]") . "\n";
	print "State: $state\n";

	my $pid = $robot->pid();
	my $logFile = $robot->logFile();
	print "Pid: $pid\n" if $pid;
	print "Logfile: " . join("/", ariba::Automation::Constants::logDirectory(), $robot->logDir(), $logFile) . "\n" if $logFile;

	print "</html>\n";
}

sub processUpdate {
	my $self = shift;
	my $cgi = shift;

	my $error = "";
	my $robotName = $cgi->param(cgiRobotName());

	my $globalState;
	my $globalString = $cgi->param(cgiGlobalState());
	if ($globalString) {
		($globalState) = ariba::Automation::GlobalState->createObjectsFromString($globalString);
		$globalState->recursiveSave();
	}

	my $configString = $cgi->param(cgiRobotConfig());
	if ($configString) {
		my $configFile = ariba::Automation::Remote::Robot->configFileForRobotName($robotName);
		ariba::rc::Utils::mkdirRecursively(dirname($configFile));

		if (open(CONFIG, ">$configFile")) {
			print CONFIG $configString;
			close(CONFIG);
		} else {
			$error .= "can't create $configFile: $!\n";
		}
	}
    
    # optional step: write a status page if provided by client
    # TODO: if one robot builds multiple products, should we write multiple status files?
    my $robotStatus = $cgi->param(cgiRobotStatus());
    my $robotProduct = $cgi->param(cgiRobotProduct());
    ($robotProduct) = $robotProduct =~ m#^([-A-Z0-9_]+)$#i; # taint checking of product name
    if ($robotStatus && $robotProduct) {
        my $statusDir = "/home/rc/robots/applinks/$robotName";
        ariba::rc::Utils::mkdirRecursively ($statusDir);
        my $statusFile = join "/", $statusDir, $robotProduct . ".html";
        if (open(STATUS, ">$statusFile")) {
          print STATUS $robotStatus;
          close (STATUS);
        } else {
          $error .= "can't create $statusFile: $!\n";
        }
    }

	# optional step: update robot status log
	if (! $error && $globalState) {
		$self->updateStateChangeLog ($cgi, $globalState, $robotName);
	}
    
	my $status = 200;
	$status = 500 if $error;

	my %headerHash = (
			-type          => "text/html",
			-status        => "$status",
			-Pragma        => "no-cache",
			-Cache_control => "no-cache",
			);

	print $cgi->header(%headerHash);
	print "<html>\n";
	print "rootdir: ". ariba::Automation::Constants->baseRootDirectory(). "\n";
	print "dir: " . $globalState->dir()."\n" if $globalState;
	#print join("\n", map( { "$_ => ".$ENV{$_} } keys %ENV) ), "\n";
	print "got: $robotName<br>\n";
	print "got: $globalString<br>\n" if $globalString;
	print "error: $error<br>\n";
	print "</html>\n";
	print "\n";
}

sub updateStateChangeLog {
	my ($self, $cgi, $globalState, $robotName) = @_;

    my $debug = 0;

	# bail unless robot is reporting BQ state: we don't want
	# to log the state for each update, just at the last 
	# action. 
	my $lastActionName = $globalState->lastActionName() || "";
	print STDERR "updateStateChangeLog: lastActionName=$lastActionName\n" if $debug;
	return unless $lastActionName eq "wait-for-target-BQ";

	# bail if build was stopped
	my $buildResult = $globalState->buildResult() || "";
	print STDERR "updateStateChangeLog: buildResult=$buildResult\n" if $debug;
	return if $buildResult eq "stopped";

	# bail if forceFailure flag in effect
	my $forceFailure = $globalState->forceFailure() || "";
	print STDERR "updateStateChangeLog: forceFailure=$forceFailure\n" if $debug;
	return if $forceFailure eq "1";

	my $status = $globalState->status() || "";
	print STDERR "updateStateChangeLog: status=$status\n" if $debug;
	return unless $status;

	# display error action if available and build failed
	my $errorAction = $globalState->errorAction() || "";
	print STDERR "updateStateChangeLog: errorAction=$errorAction\n" if $debug;
	if ($status ne "FAILURE") {
		$errorAction = "";
	}

	# example logfile filename: /home/rc/status-logs/robot57.log
	my $logname = $robotName . ".log";
	my $logfile = join "/", 
		ariba::Automation::Constants->statusChangeLogDirectory(),
		$logname;

	# logfile named for robot
	my $lock = "/tmp/robot-status-change-log-" . $robotName;
	print STDERR "updateStateChangeLog: logfile=$logfile lock=$lock\n" if $debug;

	# lockfile protects logfile append from race conditions
	if (! dmail::LockLib::requestlock ($lock, 2)) {
		# fail silently if we can't get lock
		print STDERR "updateStateChangeLog: FATAL, Can't get lock\n" if $debug;
		return; 
	}

	my $fail = 0;

	if (open FILE, ">>$logfile")
		{
		my $now = time();
		print FILE "$now $robotName $status $errorAction\n";
		if (! close FILE)
			{
			$fail = 1;
			}
		}
	else
		{
		$fail = 1;
		}

	dmail::LockLib::releaselock($lock);
	print STDERR "updateStateChangeLog: " . ($fail ? "FAIL writing to $logfile, $!" : "OK") . "\n" if $debug;
}

sub processTimingReport {
	my $self = shift;
	my $cgi = shift;

  my $reportsDir = "/home/rc/robotswww/reports";

  print $cgi->header ((-type => 'text/plain', -status => 200));

  my $file = $cgi->param('upload');
  my ($robotName) = $cgi->param('robotName') =~ m#^([-A-Z0-9]+)$#i;
  $robotName = $robotName || "";

  print "File: " . length ($file) . " bytes\n" .
    "robotName: $robotName\n";

  return unless $robotName;
  
  my ($bytesread, $buffer);
  my $reportsFile = join "/", $reportsDir, $robotName . ".png"; 
  print "reportsFile: $reportsFile\n";

  if (open (OUTFILE,">$reportsFile")) {
      binmode (OUTFILE);
      while ($bytesread=read($file,$buffer,1024)) {
        print OUTFILE $buffer;
        }
      close OUTFILE;
      print "ok\n";
  }
}

1;
