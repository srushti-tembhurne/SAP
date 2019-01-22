#!/usr/local/bin/perl

package ariba::Ops::MCL::HadoopAction;

use strict;
use File::Basename;

use base qw(ariba::Ops::MCL::ShellAction);
use ariba::Ops::MCL::BasicCommand;
use ariba::Ops::NetworkUtils;
use ariba::rc::Utils;
use ariba::Ops::Logger;
use ariba::Ops::Startup::Hadoop;
use ariba::Ops::Utils;

my $logger = ariba::Ops::Logger->logger();

sub executeLocal {
	my $self = shift;

	my $uid = $<;
	my $user = (getpwuid($uid))[0];
	my $password = ariba::rc::Passwords::lookup( $user );

	my $serviceOfUser = ariba::Ops::Utils::serviceForUser($user);
	my $master;
	if( $serviceOfUser ) {
		$master = ariba::rc::Passwords::lookup("${serviceOfUser}Master");
	}
	unless($master) {
		$master = ariba::rc::Passwords::lookup( 'master' );
	}

	#
	# Set run time environment vars in order to run hadoop related commands
	#
	my $hadoop = ariba::rc::InstalledProduct->new("hadoop", $serviceOfUser);

	ariba::Ops::Startup::Hadoop::setRuntimeEnv($hadoop);
	$logger->info("Your environment is now setup to run Hadoop cluster commands");

	#
	# non-hbase shell commands
	#
	foreach my $cmd ($self->commands()) {
		my @output;

		$cmd->setStatus("");

		my $runCmd = $cmd->commandLine();

		my $prompt = $self->fakePrompt();
		my $actionCommand = $cmd->actionNumber() . ":" . $cmd->commandNumber();
		$logger->info("$actionCommand $prompt $runCmd");

		my $ret = ariba::rc::Utils::executeLocalCommand(
			"$runCmd 2>&1",
			0,
			\@output,
			$master,
			"Logger",
			undef,
			$password
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

		return(0) unless($self->checkCommandOutputForStatus($cmd, $ret, \@output));

	}

	$self->setActionOutput();

	return(1);
}

1;
