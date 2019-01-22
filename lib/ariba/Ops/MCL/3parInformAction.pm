#!/usr/local/bin/perl

package ariba::Ops::MCL::3parInformAction;

use strict;
use File::Basename;

use base qw(ariba::Ops::MCL::NetworkDeviceAction);

my $logger = ariba::Ops::Logger->logger();

sub execute {
	my $self = shift;
	my $mcl = ariba::Ops::MCL->currentMclObject();
	my $ret;

	my $host = $self->host();
	my $machine = ariba::Ops::Machine->new($host);
	my $nm = ariba::Ops::NetworkDeviceManager->newFromMachine($machine);
	$nm->setDebug(0); # in case calling code set this different, we DO NOT WANT

	$self->createFakePrompt($nm);

	foreach my $command ($self->commands()) {
		$command->setStatus("");
		my $cmd = $command->commandLine();

		if($cmd =~ /^\s*sleep\s+(\d+)\s*$/) {
			my $sleepTime = $1;
			sleep($sleepTime);
			$command->setStatus('Successful');
			$logger->info("Slept $sleepTime");
			$command->setOutput("Slept $sleepTime");
			next;
		}

		$logger->info("Running $cmd on device.");
		my @output = $nm->sendCommandUsingInform($cmd, 600);

		if($nm->error()) {
			my $outputStr = join("\n", "ERROR: " . $nm->error(), @output);
			$command->setOutput($outputStr);
			$command->setStatus('Failed');
			$self->setActionOutput();
			return(0);
		}

		foreach my $line (@output) {
			chomp($line);
			$logger->info($line);
		}

		my $outputString = join("\n", @output);
		$command->setOutput($outputString);

		unless($command->errorStrings() || $command->successStrings()) {
			foreach my $line (@output) {
				if($line =~ /error/i) {
					$logger->error("ERROR: Found error string 'error' in output!");
					my $out = $command->output();
					$out .= "\nERROR: Found error string 'error' in output!\n";
					$command->setStatus('Failed');
					$command->setOutput($out);
					$self->setActionOutput();
					return(0);
				}
			}
		}

		if($command->errorStrings()) {
			foreach my $err ($command->errorStrings()) {
				foreach my $line (@output) {
					if($line =~ /$err/) {
						$logger->error("ERROR: Found error string '$err' in output!");
						my $out = $command->output();
						$out .= "\nERROR: Found error string '$err' in output!\n";
						$command->setStatus('Failed');
						$command->setOutput($out);
						$self->setActionOutput();
						return(0);
					}
				}
			}
		}

		if($command->successStrings()) {
			foreach my $string ($command->successStrings()) {
				$ret = 0;
				foreach my $line(@output) {
					$ret = 1 if($line =~ /$string/);
				}
				unless($ret) {
					$logger->error("ERROR: Did not find success string '$string' in output!");
					my $out = $command->output();
					$out .= "\nERROR: Did not find success string '$string' in output!\n";
					$command->setOutput($out);
					$command->setStatus('Failed');
					$self->setActionOutput();
					return(0);
				}
			}
		}
	}
	$self->setActionOutput();
	$nm->disconnect();

	return(1);
}

sub createFakePrompt {
	my $self = shift;
	my $nm = shift;

	my $p = sprintf("%s\@%s cli % ", $nm->loginName(), $nm->hostname());

	$self->setFakePrompt($p);
}

1;
