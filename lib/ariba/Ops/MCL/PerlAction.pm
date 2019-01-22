#!/usr/local/bin/perl

package ariba::Ops::MCL::PerlAction;

use strict;
use File::Basename;

use base qw(ariba::Ops::MCL::BaseAction);
use ariba::Ops::MCL::BasicCommand;
use ariba::rc::Utils;
use ariba::Ops::Logger;

my $logger = ariba::Ops::Logger->logger();
my $helpersLoaded = 0;

sub objectLoadMap {
	my $class = shift;

	my $map = $class->SUPER::objectLoadMap();

	$map->{'commands'} = '@ariba::Ops::MCL::BasicCommand';

	return($map);
}

sub execute {
	my $self = shift;
	my $mcl = ariba::Ops::MCL->currentMclObject();

	foreach my $command ($self->commands()) {
		$command->setStatus("");
		my $cmd = $command->commandLine();
		$cmd = "ariba::Ops::MCL::Helpers::$cmd";
		my $retVal = eval "$cmd";

		if($@) {
			$logger->error("$cmd produced perl exception.");
			$logger->error("$@");
			$command->setOutput("$cmd produced perl exception.\n\n$@.\n");
			$self->setActionOutput();
			return(0);
		}

		if($retVal) {
			if($retVal !~ /^\d+$/) {
				$command->setOutput($retVal);
				if($retVal =~ /WAIT/i) {
					$logger->info($retVal);
					$self->setActionOutput();
					return(-1);
				}
				if($retVal =~ /ERROR/i) {
					$logger->error($retVal);
					$self->setActionOutput();
					return(0);
				}
			} else {
				$command->setOutput("$cmd completed successfully");
			}
			$logger->info($command->output());
		} else {
			$command->setOutput("$cmd failed\n$!");
			$logger->error("$cmd failed\n$!");
			$self->setActionOutput();
			return(0);
		}
	}

	$self->setActionOutput();
		
	return(1);
}

sub loadPerlHelpers {
	my $dir;

	foreach my $d (@INC) {
		if ( -e "$d/ariba/Ops/MCL/Step.pm" ) {
			$dir = $d;
			last;
		}
	}

	opendir(D, "$dir/ariba/Ops/MCL/Helpers");
	while(my $f = readdir(D)) {
		next unless($f =~ s/\.pm$//);
		my $package = "ariba::Ops::MCL::Helpers::$f";
		eval "use $package";
		if($@) {
			$logger->error("Failed to load $package.");
			die($@);
		}
	}
	closedir(D);
}

sub commandPrefix {
	return "";
}

sub parse {
	my $self = shift;
	my $mcl = shift;
	my $step = shift;
	my $args = shift;
	my $stream = shift;
	my $commandCount = 0;
	my @empty;

	unless($helpersLoaded) {
		ref($self)->loadPerlHelpers();
		$helpersLoaded = 1;
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

		if($line =~ /^\s*(.*)$/) {
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
		} else {
			# this really can't happen, but let's put the structure here
			my $stepname = $step->name();
			die("Unrecognized syntax in Step $stepname PerlAction: $line");
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
