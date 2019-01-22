#!/usr/local/bin/perl

package ariba::Ops::MCL::DAAction;

use strict;
use LWP::UserAgent;

use base qw(ariba::Ops::MCL::BaseAction);
use ariba::Ops::MCL::BasicCommand;

my $logger = ariba::Ops::Logger->logger();

sub objectLoadMap {
	my $class = shift;

	my $map = $class->SUPER::objectLoadMap();

	$map->{'commands'} = '@ariba::Ops::MCL::BasicCommand';

	return($map);
}

sub arguments {
    my $self = shift;

    return $self->postData();
}

sub validAccessorMethods {
    my $class = shift;

    my $ref = $class->SUPER::validAccessorMethods();
    $ref->{'postData'} = 1;

    return($ref);
}

sub parse {
	my $self = shift;
	my $mcl = shift;
	my $step = shift;
	my $args = shift;
	my $stream = shift;

	my @empty;
	my $command;
	my $commandCount = 0;
	$self->setCommands(@empty);
    $self->setPostData($args);

	while(my $line = shift(@$stream)) {
		chomp($line);
		last if($line =~ /^\s*\}\s*$/);

		$line = $mcl->expandVariables($line);
		if($line =~ /\n/) {
			my @rest;
			( $line, @rest ) = split(/\n/, $line);
			unshift(@$stream, @rest);
		}

		next if($line =~ /^\s*$/);
		next if($line =~ /^\s*\#/);

		if($line =~ /^\s*([\$%])\s+(.*)$/) {
			my $type = $1;
			my $cmd = $2;
			$command = ariba::Ops::MCL::BasicCommand->newFromParser(
				$self->mcl(),
				$self->step(),
				$self->actionNumber(),
				$commandCount,
				$cmd
			);
            $command->setCommandPrefix($type);
			if($type eq '$') {
				$command->setType('get');
			} elsif($type eq '%') {
				$command->setType('post');
				$command->setPostString($args);
			}
			$self->appendToCommands($command);
			$commandCount++;
			$command->setErrorStrings(@empty);
			$command->setSuccessStrings(@empty);
			$command->setSuccessIfStrings(@empty);
		} elsif($command) {
			if(!$self->parseStatusStrings($command, $line)) {
				my $stepname = $step->name();
				die("Unrecognized syntax in Step $stepname DAAction: $line");
			}
		} else {
			my $stepname = $step->name();
			die("Unrecognized syntax in Step $stepname DAAction: $line");
		}
	}
}

sub execute {
	my $self = shift;
 
	my $ua = LWP::UserAgent->new();
	$ua->agent("JMCL ");

	foreach my $cmd ($self->commands()) {
		my @output;

		$cmd->setStatus("");

		my $url = $cmd->commandLine();

		my $res;
		if($cmd->type() eq 'post') {

			## TO-DO need to be able to support different content types
			my $args = $cmd->postString();
			my $req = HTTP::Request->new(POST => "$url");
			$req->content_type('application/x-www-form-urlencoded');
			$req->content($args);

			$res = $ua->request($req);

		} else {
			$res = $ua->get($url);
		}

        $logger->info("Status code: " . $res->status_line);
        my $ret = $res->is_success;
		@output = $res->decoded_content if $res->is_success;

        # log the output
        foreach my $line (@output) {
            chomp $line;
            $line =~ s/\r//;
            $logger->info("$line");
        }

		my $outputString = join("\n", @output);
		$cmd->setOutput($outputString);

        return(0) unless($self->checkCommandOutputForStatus($cmd, $ret, \@output));
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
		last if($cmd->status() eq 'Failed');
	}
	$self->setOutput($actionOut);
}


1;
