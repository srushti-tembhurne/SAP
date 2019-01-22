#!/usr/local/bin/perl

package ariba::Ops::MCL::WaitAction;

use strict;
use File::Basename;

use base qw(ariba::Ops::MCL::BaseAction);
use ariba::Ops::MCL::BasicCommand;
use ariba::Ops::Logger;

my $logger = ariba::Ops::Logger->logger();

sub objectLoadMap {
	my $class = shift;

	my $map = $class->SUPER::objectLoadMap();

	$map->{'commands'} = '@ariba::Ops::MCL::BasicCommand';

	return($map);
}

sub commandPrefix {
	return "";
}

sub execute {
	my $self = shift;
	my $mcl = ariba::Ops::MCL->currentMclObject();

	foreach my $command ($self->commands()) {
		$command->setOutput($command->commandLine());
	}
	$self->setActionOutput();

	return(-1);
}

sub dryrun {
	my $self = shift;

	#
	# wait actions don't do anything anyway
	#
	return($self->execute());
}

sub parse {
	my $self = shift;
	my $mcl = shift;
	my $step = shift;
	my $args = shift;
	my $stream = shift;
	my $commandCount = 0;
	my @empty;

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
			# this really can't happen, but let's put the infrastructure here
			my $stepname = $step->name();
			die("Unrecognized syntax in Step $stepname WaitAction: $line");
		}
	}

	return(1);
}

sub setActionOutput {
	my $self = shift;

	my $actionOut = "";
	foreach my $cmd ($self->commands()) {
		$actionOut .= $cmd->commandLine() . "\n";
	}
	chomp($actionOut);
	$self->setOutput($actionOut);
}

1;
