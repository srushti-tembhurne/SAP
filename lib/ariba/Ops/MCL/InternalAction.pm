#!/usr/local/bin/perl

package ariba::Ops::MCL::InternalAction;

use strict;
no strict 'refs';
use File::Basename;

use base qw(ariba::Ops::MCL::BaseAction);
use ariba::Ops::MCL::BasicCommand;
use ariba::Ops::Logger;

my %validCommands = (
	'sort' => 1,
	'add' => 1,
	'replace' => 1,
	'head' => 1,
	'tail' => 1,
	'grep' => 1
);

my $logger = ariba::Ops::Logger->logger();

sub validAccessorMethods {
	my $class = shift;

	my $ref = $class->SUPER::validAccessorMethods();
	my @accessors = qw( variable );

    foreach my $accessor (@accessors) {
		$ref->{$accessor} = 1;
	}

	return($ref);
}

sub arguments {
	my $self = shift;
	return($self->variable());
}
 
sub execute {
	my $self = shift;
	my $ret;
	my $mcl = ariba::Ops::MCL->currentMclObject();
	my @data;

	if($self->variable() =~ /Output\(([^\)]+)\)/) {
		my $stepName = $1;
		my $step = $mcl->stepForName($1);
		unless($step) {
			$logger->error("ERROR: Step $stepName does not exist.");
			$self->setOutput("ERROR: Step $stepName does not exist.");
			return(0);
		}
		@data = split("\n", $step->output());
	} else {
		my $v = $mcl->variableForName($self->variable());
	
		unless($v) {
			$logger->error("ERROR: Variable " . $self->variable() . " does not exist.\n");
			$self->setOutput("ERROR: Variable " . $self->variable() . " does not exist.\n(If you think you did set the variable correctly with a Store directive,\ncheck your dependencies)");
			return(0);
		}

		(@data) = split("\n", $v->value);
	}

	foreach my $cmd ($self->commands()) {
		my $func = $cmd->commandLine();
		$logger->info("Processing $func() on " . $self->variable());
		@data = &$func ($cmd->args(), @data);
		$logger->info("Done.");
	}

	my $str = join("\n", @data);
	$logger->info("setting output to:\n$str");
	$self->setOutput( $str );
	return(1);
}

sub objectLoadMap {
	my $class = shift;

	my $map = $class->SUPER::objectLoadMap();

	$map->{'commands'} = '@ariba::Ops::MCL::BasicCommand';

	return($map);
}


sub grep {
	my $arg = shift;
	my (@data) = (@_);

	@data = grep { $_ =~ /$arg/ } @data;
	return(@data);
}

sub head {
	my $arg = shift;
	my (@data) = (@_);

	@data = splice(@data, 0, $arg);
	return(@data);
}

sub tail {
	my $arg = shift;
	my (@data) = (@_);

	$arg *= -1;

	@data = splice(@data, $arg);
	return(@data);
}

sub add {
	my $arg = shift;
	my (@data) = (@_);
	my @ret;

	$logger->info("In add()\n");

	#
	# this should usually be one element...
	#
	foreach my $line (@data) {
		$line += $arg;
		push(@ret, $line);
	}

	return(@ret);
}

sub replace {
	my $arg = shift;
	my (@data) = (@_);
	my (@ret);

	my ($replace, $with) = split(/\s+/, $arg);
	$with = "" if($with eq "undef");

	foreach my $line (@data) {
		if($with =~ /^\$\d+$/) {
			if($line =~ m/$replace/) {
				my $realWith = eval "$with";
				$line =~ s/$replace/$realWith/;
			}
		} else {
			$line =~ s/$replace/$with/g;
		}
		push(@ret, $line);
	}

	return(@ret);
}
	
sub sort {
	my $arg = shift;
	my (@data) = (@_);
	if($arg && $arg eq 'numerical') {
		@data = sort { $a <=> $b } (@data);
	} elsif($arg && $arg eq 'reverse-numerical') {
		@data = sort { $b <=> $a } (@data);
	} elsif($arg && $arg eq 'reverse') {
		@data = sort { $b cmp $a } (@data);
	} else {
		@data = sort { $a cmp $b } (@data);
	}

	return(@data);
}

sub parse {
	my $self = shift;
	my $mcl = shift;
	my $step = shift;
	my $args = shift;
	my $stream = shift;
	my $commandCount = 0;
	my @empty;

	my $var;
	if($args && $args !~ /^\s*$/) {
		$args =~ s/^\s+//;
		$args =~ s/\s+$//;
		$var = $args;
	}
	$self->setVariable($var);

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

		if($line =~ /^\s*(\w+)\s+(.*)\s*$/) {
			my $cmd = $1;
			my $cArgs = $2;
			if($validCommands{$cmd}) {
				$command = ariba::Ops::MCL::BasicCommand->newFromParser(
					$self->mcl(),
					$self->step(),
					$self->actionNumber(),
					$commandCount,
					$cmd
				);
			} else {
				my $stepname = $step->name();
				die("Illegal function call '$cmd' in Step $stepname InternalAction: $line");
				
			}
			$command->setArgs($cArgs);
			$self->appendToCommands($command);
			$commandCount++;
		} else {
			my $stepname = $step->name();
			die("Unrecognized syntax in Step $stepname InternalAction: $line");
		}
	}
}

1;
