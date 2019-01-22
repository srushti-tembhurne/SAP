#!/usr/local/bin/perl

package ariba::Ops::MCL::HbaseAction;

use strict;
use File::Basename;

use base qw(ariba::Ops::MCL::ShellAction);
use ariba::Ops::MCL::BasicCommand;
use ariba::Ops::NetworkUtils;
use ariba::Ops::Utils;
use ariba::Ops::Logger;
use ariba::rc::Utils;

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
	# Write all hbase shell commands to a file to be executed via hbase shell
	#
	my $hbaseFile = "/tmp/hbasecommands.txt";

	my $actionCommand;
	my $firstCommand;
	open(FILE, ">$hbaseFile");

	foreach my $cmd ($self->commands()) {
		$firstCommand = $cmd unless($firstCommand);
		my $hbaseCmd = $cmd->commandLine();
		print FILE "$hbaseCmd\n";

		# Since all commands will be executed in a single script, actionNumber and 
		# commandNumber will remain the same for all cmds
		unless (defined($actionCommand)) {
			$actionCommand = "0:0";
			#$actionCommand = $cmd->actionNumber() . ":" . $cmd->commandNumber();
		}
	}
	print FILE "exit";
	close(FILE);

	if (-e $hbaseFile) {
		my $runCmd = "hbase shell $hbaseFile";
		my @output;

		$self->setStatus("");
		my $prompt = $self->fakePrompt();
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
		$self->setOutput($outputString);

		return(0) unless($self->checkCommandOutputForStatus($firstCommand, $ret, \@output));
	}
	$self->setActionOutput();

	return(1);
}

1;
