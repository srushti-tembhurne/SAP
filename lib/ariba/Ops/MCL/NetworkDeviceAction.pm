#!/usr/local/bin/perl

package ariba::Ops::MCL::NetworkDeviceAction;

use strict;
use File::Basename;

use base qw(ariba::Ops::MCL::BaseAction);
use ariba::Ops::MCL::BasicCommand;
use ariba::Ops::NetworkUtils;
use ariba::Ops::NetworkDeviceManager;
use ariba::rc::Utils;
use ariba::Ops::Logger;

my $logger = ariba::Ops::Logger->logger();

sub objectLoadMap {
	my $class = shift;

	my $map = $class->SUPER::objectLoadMap();

	$map->{'commands'} = '@ariba::Ops::MCL::BasicCommand';

	return($map);
}

sub shouldUseProxyForNetworkDevice {
	my $self = shift;
	my $nd = shift;

	my $host = ariba::Ops::NetworkUtils::hostname();
	my $m = ariba::Ops::Machine->new($host);

	if($m->datacenter eq 'devlab') {
		if($nd->os() eq 'inserv') {
			return(1);
		}
	}

	return(0);
}
	
sub execute {
	my $self = shift;
	my $mcl = ariba::Ops::MCL->currentMclObject();

	my $host = $self->host();
	my $machine = ariba::Ops::Machine->new($host);
	my $shouldProxy = $self->shouldUseProxyForNetworkDevice($machine);
	my $nm = ariba::Ops::NetworkDeviceManager->newFromMachine($machine, $shouldProxy);
	$nm->setDebug(0); # in case calling code set this different, we DO NOT WANT

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

		if($cmd =~ /^\s*enable$/) {
			my $enablePass = ariba::rc::Passwords::lookup('networkEnable');
			$nm->setEnablePassword($enablePass);
			$nm->connect();
			$nm->enable();
			$command->setStatus('Successful');
			$logger->info("Network Enable Sent.");
			$command->setOutput("Network Enable Sent.");
			next;
		}
		
		$logger->info("Running $cmd on device.");
		my @output = $nm->_sendCommandLocal($cmd,180);
		if($nm->error() && ($nm->error() =~ /TIMEOUT/ || $cmd =~ /^show/)) {
			$logger->warn("Attempting retry after network device timeout.\n");
			$nm->disconnect();
			$nm->connect();
			@output = $nm->_sendCommandLocal($cmd);
		}
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
			#
			# use a default error string
			#
			$command->setErrorStrings( 'error' );
		}

		return(0) unless($self->checkCommandOutputForStatus($command, 1, \@output));
	}
	$self->setFakePrompt($nm->actualCommandPrompt()) if($nm->actualCommandPrompt());
	$self->setActionOutput();
	$nm->disconnect();

	return(1);
}

sub arguments {
	my $self = shift;

	return($self->host());
}

sub parse {
	my $self = shift;
	my $mcl = shift;
	my $step = shift;
	my $args = shift;
	my $stream = shift;
	my $commandCount = 0;
	my @empty;

	if($args && $args !~ /^\s*$/) {
		$args =~ s/^\s+//;
		$args =~ s/\s+$//;
		my $host = $args;
		if($host) {
			$host .= ".ariba.com" unless($host =~ /\.ariba\.com$/ || $host =~ /^\d+\.\d+\.\d+\.\d+$/);
			$self->setHost($host);
		} else {
			my $stepname = $step->name();
			die("NetworkDevice Action requires a host in Step $stepname.");
		}
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
			} elsif(! $self->parseStatusStrings($command, $line) ) {
				my $stepname = $step->name();
				die("Unrecognized syntax in Step $stepname NetworkDeviceAction: $line");
			}
		} else {
			my $stepname = $step->name();
			die("Unrecognized syntax in Step $stepname NetworkDeviceAction: $line");
		}
	}

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
	}
	$self->setOutput($actionOut);
}

1;
