#!/usr/local/bin/perl

package ariba::Ops::MCL::OracleScriptAction;

use strict;

#
# this is based of OracleAction, to inherit most of the work.
#
# executeLocal() is overridden to run the SQL as a script
#
use base qw(ariba::Ops::MCL::OracleAction);

my $logger = ariba::Ops::Logger->logger();

sub sqlScriptDir {
	my $self = shift;
	my $mcl = ariba::Ops::MCL->currentMclObject();

	my $dir = $mcl->dir() . "/" . $mcl->instance() . "/sql";
	return($dir);
}

sub createSqlDir {
	my $self = shift;
	my $dir = $self->sqlScriptDir();
	ariba::rc::Utils::mkdirRecursively($dir);
}

sub sqlFile {
	my $self = shift;
	my $step = $self->step();
	my $actionNumber = $self->actionNumber();
	my $dir = $self->sqlScriptDir();

	my $file = "$dir/script-$step.$actionNumber.sql";

	return($file);
}

sub executeLocal {
	my $self = shift;
	my $mcl = ariba::Ops::MCL->currentMclObject();
	my $blurPasswords;
	my %blurValues;
	my $firstCommand;

	my $sid = $self->sid();
	my $host = $self->host();
	my $schema = $self->schema();
	my $schemaPassword = $self->password();

	if($schema && !$schemaPassword) {
		$schemaPassword = $self->getSchemaPassword();
	}

	if($schema) {
		$self->setFakePrompt("$schema\@$sid $host SQL>");
	} else {
		$self->setFakePrompt("$sid\@$host SQL>");
	}

	my $serviceManager = ariba::Ops::OracleServiceManager->new($sid);

	#
	# write the script to disk
	#
	my $timeout = undef;
	my @errorStrings = ();
	my @successStrings = ();
	my @successIfStrings = ();
	my $perlCheck;

	$self->createSqlDir();
	my $sqlFile = $self->sqlFile();
	my $SQL;
	open($SQL, "> $sqlFile");

	print $SQL "set sqlprompt '> ';\n";
	print $SQL "WHENEVER SQLERROR exit sql.sqlcode;\n\n";
	print $SQL "SET ECHO ON;\n";

	foreach my $cmd ($self->commands()) {
		$firstCommand = $cmd unless($firstCommand);
		my $runCmd = $cmd->commandLine();

		my $regex = $self->passwordRegex();
		while($runCmd =~ /$regex/) {
			my $type = $1;
			my $pass = $self->getPassword($type);
			$runCmd =~ s/$regex/$pass/;
			next unless($pass); # don't "blur" an empty string
			$blurPasswords = 1;
			$blurValues{$pass} = $type;
		}
		$timeout = $cmd->timeout() if($cmd->timeout());
		push(@errorStrings, $cmd->errorStrings());
		push(@successStrings, $cmd->successStrings());
		push(@successIfStrings, $cmd->successIfStrings());
		$perlCheck = $cmd->perlCheck();

		print $SQL "$runCmd\n";
	}

	return(1) unless($firstCommand);

	print $SQL "select 'SQL>' from dual;\n";
	close($SQL);

	my @output;

	$self->setStatus("");

	my $runCmd = "\@ $sqlFile ;";

	my $prompt = $self->fakePrompt();
	my $actionCommand = "0:0";
	$logger->info("$actionCommand $prompt $runCmd");


	$serviceManager->setUseLogger(1);

	my $ret = $serviceManager->_runSqlFromServiceManager(
		$runCmd,
		undef,
		\@output,
		$schema,
		$schemaPassword,
		$timeout,
	);

	my $systemPassword;
	my $sysPassword;

	#
	# last line is expect prompt management, so we ignore it
	#
	pop(@output);

	#
	# log the output
	#
	foreach my $line (@output) {
		chomp $line;
		$line =~ s/\r//;
		if($blurPasswords) {
			my $count = 0;
			foreach my $k (sort { length($b) <=> length($a) } (keys %blurValues)) {
				my $blur = "[password for ::USER::$count::]";
				$count++;
				$line =~ s/$k/$blur/gi;
				#
				# this is a dumb edge case, but if you do this:
				#
				# select 'PASSWORD:s4/S3LIVEDW028' from V$DATABASE;
				#
				# then oracle will use a truncated by 1 password as the
				# column header.  So we'll catch that too.
				#
				my $substr = substr($k, 0, length($k)-1);
				$line =~ s/$substr/$blur/gi;
			}
			$count = 0;
			foreach my $k (sort { length($b) <=> length($a) } (keys %blurValues)) {
				my $user = lc($blurValues{$k});
				$line =~ s/::USER::$count::/$user/g;
			}
		}
		$logger->info("$line");
	}

	my $outputString = join("\n", @output);

	$self->setOutput($outputString);

	unless(scalar(@errorStrings) || scalar(@successStrings)) {
		@errorStrings = ( '(error|ORA-\d+|SP2-\d+)' );
	}

	return( $self->checkCommandOutputForStatus( $firstCommand, 1, \@output, \@errorStrings, \@successStrings, \@successIfStrings, $perlCheck, 'OracleScript' ) );

}

1;
