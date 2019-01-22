#!/usr/local/bin/perl

package ariba::Ops::MCL::ScpShellAction;

use strict;
use File::Basename;
use base qw(ariba::Ops::MCL::ShellAction);

#
# This is a subclass of ShellAction, intended to run scp (which asks for
# a password, and is sort of a remote command, but also sorta like a local
# command)
#

my $logger = ariba::Ops::Logger->logger();

sub executeLocal {
	my $self = shift;

	my $uid = $<;
	my $user = (getpwuid($uid))[0];
	my $password = ariba::rc::Passwords::lookup( $user );

	foreach my $cmd ($self->commands()) {
		my @output;

		$cmd->setStatus("");

		my $runCmd = $cmd->commandLine();

		if($runCmd =~ /^\s*sleep\s+(\d+)\s*$/) {
			my $sleepTime = $1;
			sleep($sleepTime);
			$cmd->setStatus('Successful');
			$logger->info("Slept $sleepTime");
			$cmd->setOutput("Slept $sleepTime");
			next;
		}

		my $prompt = $self->fakePrompt();
		my $actionCommand = $cmd->actionNumber() . ":" . $cmd->commandNumber();
		$logger->info("$actionCommand $prompt $runCmd");

		my $usePassword = $password;
		if($runCmd =~ m/(\w+)\@\w+/) {
			my $targetUser = $1;
			$usePassword = ariba::rc::Passwords::lookup( $targetUser );
		}

		my $ret = ariba::rc::Utils::executeRemoteCommand(
			$runCmd,
			$usePassword,
			0,
			undef,
			undef,
			\@output
		);

		#
		# log the output
		#
		foreach my $line (@output) {
			chomp $line;
			$line =~ s/\r//;
			$logger->info("$line");
		}

		my $outputString = join("\n", @output);
		$cmd->setOutput($outputString);

		unless($ret || $cmd->ignoreExitCode()) {
			$logger->error("ERROR: '$runCmd' exited with non-zero exit code.");
			my $out = $cmd->output();
			$out .= "\nERROR: $runCmd exited with non-zero exit code.\n";
			$cmd->setOutput($out);
			$cmd->setStatus('Failed');
			$self->setActionOutput();
			return(0);
		}

		if($cmd->errorStrings()) {
			foreach my $err ($cmd->errorStrings()) {
				foreach my $line (@output) {
					if($line =~ /$err/) {
						$logger->error("ERROR: Found error string '$err' in output!");
						my $out = $cmd->output();
						$out .= "\nERROR: Found error string '$err' in output!\n";
						$cmd->setOutput($out);
						$cmd->setStatus('Failed');
						$self->setActionOutput();
						return(0);
					}
				}
			}
		}

		if($cmd->successStrings()) {
			foreach my $string ($cmd->successStrings()) {
				$ret = 0;
				foreach my $line(@output) {
					$ret = 1 if($line =~ /$string/);
				}
				unless($ret) {
					$logger->error("ERROR: Did not find success string '$string' in output!");
					my $out = $cmd->output();
					$out .= "\nERROR: Did not find success string '$string' in output!\n";
					$cmd->setOutput($out);
					$cmd->setStatus('Failed');
					$self->setActionOutput();
					return(0);
				}
			}
		}
	}

	$self->setActionOutput();

	return(1);
}

1;
