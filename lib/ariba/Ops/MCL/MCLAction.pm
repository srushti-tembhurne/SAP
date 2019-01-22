#!/usr/local/bin/perl

package ariba::Ops::MCL::MCLAction;

use strict;
use File::Basename;

use base qw(ariba::Ops::MCL::BaseAction);
use ariba::Ops::MCL::BasicCommand;
use ariba::Ops::NetworkUtils;
use ariba::rc::Utils;
use ariba::Ops::Logger;

my $logger = ariba::Ops::Logger->logger();

sub newFromParser {
	my $class = shift;
	my $mcl = shift;
	my $step = shift;
	my $number = shift;

	#
	# if not in a screen, this becomes a vanilla ShellAction
	#
	$class = "ariba::Ops::MCL::ShellAction" unless($ENV{'STY'});

	return($class->SUPER::newFromParser($mcl, $step, $number));
}

sub objectLoadMap {
	my $class = shift;

	my $map = $class->SUPER::objectLoadMap();

	$map->{'commands'} = '@ariba::Ops::MCL::BasicCommand';

	return($map);
}

sub parse {
	my $self = shift;
	my $mcl = shift;
	my $step = shift;
	my $args = shift;
	my $stream = shift;
	my $commandCount = 0;
	my @empty;

	#
	# this shouldn't happen, but leaving it here to be paranoid
	#
	unless($ENV{'STY'}) {
		# error for not being in a screen
		die("Not in a screen session for MCLAction");
	}

	my $command;
	$self->setCommands(@empty);

	while(my $line = shift(@$stream)) {
		chomp($line);
		last if($line =~ /^\s*\}\s*$/);

		$line = $mcl->expandVariables($line);
		if($line =~ /\n/) {
			my @rest;
			( $line, @rest ) = split(/\n/, $line);
			unshift(@$stream,@rest);
		}

		next if($line =~ /^\s*$/);
		next if($line =~ /^\s*\#/);

		if($line =~ /^\s*\$\s+(.*)$/) {
			my $cmd = $1;
			if($cmd =~ /[\'\"]/) {
				die("quotes not allowed in MCLAction commands. (this feature may be implemented later).");
			}
			$command = ariba::Ops::MCL::BasicCommand->newFromParser(
				$self->mcl(),
				$self->step(),
				$self->actionNumber(),
				$commandCount,
				$cmd
			);
			$self->appendToCommands($command);
			$commandCount++;
			$command->setErrorStrings(@empty);
			$command->setSuccessStrings(@empty);
			$command->setSuccessIfStrings(@empty);
		} elsif($command) {
			if($line =~ /^\s*\>\s+(.*)$/) {
				my $append = $1;
				my $cmd = $command->commandLine();
				$cmd .= " $append";
				$command->setCommandLine($cmd);
			} elsif($line =~ /^\s*IgnoreExitCode/) {
				$command->setIgnoreExitCode(1);
			} elsif(! $self->parseStatusStrings($command, $line) ) {
				my $stepname = $step->name();
				die("Unrecognized syntax in Step $stepname MCLAction: $line");
			}
		} else {
			my $stepname = $step->name();
			die("Unrecognized syntax in Step $stepname MCLAction: $line");
		}
	}

	my @commands = $self->commands();
	if(scalar(@commands) > 1) {
		die("MCLAction with more than one command is not allowed.");
	}
}

sub execute {
	my $self = shift;

	my $uid = $<;
	my $user = (getpwuid($uid))[0];

	#
	# XXX -- in a perfect world, this would also support multi-service
	# with super-service passwords, but for now MCL actions must run
	# with the same service as the parent -- the child MCL can take the
	# super password and itself be multi-service as a work around.
	#
	my $master = ariba::rc::Passwords::lookupMasterPci( undef, 1 );

	my $fifo = "/tmp/.screen-mcl-fifo." . $$ . '.' . $ENV{'STY'};
	if( system('/usr/bin/mkfifo -m 0000 '. $fifo) ) {
		$logger->error("Failed to created FIFO $fifo");
		return(0);
	}
	unless(chmod(0600, $fifo)) {
		$logger->error("Failed to chmod FIFO $fifo");
		unlink($fifo);
		return(0);
	}

	my $hackFile = "/tmp/.screen-password-info." . $$ . '.' . $ENV{'STY'};
	my $FH;
	open($FH, "> $hackFile");
	print $FH "master: $master\n";
	close($FH);

	#
	# in MOST action types this is a loop, but MCL actions only allow
	# one command, so just pull el numero uno (or cero... whatever)
	#
	my $cmd = ($self->commands())[0];
	my @output;

	$cmd->setStatus("");

	my $runCmd = $cmd->commandLine();

	my $prompt = $self->fakePrompt();
	my $actionCommand = $cmd->actionNumber() . ":" . $cmd->commandNumber();
	$logger->info("$actionCommand $prompt $runCmd");

	#
	# pass PPID as an environment variable so the child can find the
	# fifo and MPW files
	#
	$runCmd = "screen bash -c 'export ARIBA_MCL_PPID=$$ ; $runCmd ; sleep 5'";
	system($runCmd);

	#
	# read the output here ... CAREFUL -- this open HAS to be AFTER the
	# system call above, since open will block until the pipe is opened
	# for write by the above command -- which won't happen unless we
	# spawn the child first.
	#
	# the nice thing about this is that the FIFO will get EOF on read when the
	# process in the other screen (write side) exits, so we can detect
	# the completion of the process this way.
	#
	$logger->info("Opening FIFO: $fifo to read child progress.");
	my $PIPE;
	unless(open($PIPE, $fifo)) {
		$logger->error("Failed to open FIFO $fifo for reading");
		unlink($fifo);
		return(0);
	}

	my $ret = 0;
	while(my $line = <$PIPE>) {
		chomp $line;
		$line =~ s/\r//;

		$ret = 1 if($line =~ /completed\s+successfully\s+in/);
		$logger->info($line);
		push(@output, $line);

		if($line =~ /Child\s+running\s+in\s+WINDOW\s+(\d+)/) {
			my $window = $1;
			$self->sendInfoToUI("In Window $window");
		}

	}
	close($PIPE);
	unlink($fifo);

	my $outputString = join("\n", @output);
	$cmd->setOutput($outputString);

	#
	# In case the child fails at this
	#
	unlink($hackFile);

	unless($ret) {
		$outputString .= "\nERROR: Child MCL is NOT completed successfully.";
		$outputString .= "\nYou should resume and complete it, then mark this step complete";
		$cmd->setOutput($outputString);

		$self->setActionOutput();
		$logger->error("Child MCL is not completed successfully.");
		$logger->info("You should resume and complete it, then mark this step complete");
		return(0);
	}
	return(0) unless($self->checkCommandOutputForStatus($cmd, $ret, \@output));

	$self->setActionOutput();

	return(1);
}

sub setActionOutput {
	my $self = shift;

	my $fakePrompt = $self->fakePrompt();

	my $actionOut = "";
	foreach my $cmd ($self->commands()) {
		$actionOut .= "$fakePrompt " . $cmd->commandLine() . "\n";
		$actionOut .= $cmd->output();
		chomp($actionOut);
		$actionOut .= "\n";
		last if($cmd->status() eq 'Failed');
	}
	$self->setOutput($actionOut);
}

1;
