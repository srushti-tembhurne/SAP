#!/usr/local/bin/perl

package ariba::Ops::MCL::OracleAction;

use strict;
use File::Basename;
use ariba::Ops::OracleServiceManager;
use ariba::rc::InstalledProduct;
use ariba::rc::Globals;
use ariba::Ops::DBConnection;

#
# this is based of ShellAction, to inherit the local/remote pieces
#
# executeLocal() and parse() are overridden for running stuff through
# OracleServiceManager
#
use base qw(ariba::Ops::MCL::ShellAction);

my $logger = ariba::Ops::Logger->logger();

sub validAccessorMethods {
	my $class = shift;

	my $ref = $class->SUPER::validAccessorMethods();
	my @accessors = qw( sid schema password );

	foreach my $accessor (@accessors) {
		$ref->{$accessor} = 1;
	}

	return($ref);
}

sub passwordRegex {
	my $self = shift;
	return('PASSWORD:([\w\/\@:=\{\}\+]+)');
}

#
# Oracle steps always "run" as mon$service, since that has the cipher store
# for loading OracleServiceManager -- for this the cofigurable bit is SID
# rather than shell user
#
# XXXXX -- MON HAS TO BE UP FOR THIS TO WORK
#
sub user {
	my $self = shift;
	my $mcl = ariba::Ops::MCL->currentMclObject();

	return(undef) unless($mcl); # this can happen on initial load

	my $service = $mcl->service();

	return( ariba::Ops::MCL::userForService($service, "svc") );
}

sub arguments {
	my $self = shift;

	my $schema = $self->schema();
	my $sid = $self->sid();
	my $host = $self->host();
	my $passwd = $self->password();
	if($passwd && $passwd !~ /^password:/i) {
		$passwd = "[password]";
	}
	$schema .= "/$passwd" if($schema && $passwd);

	if($schema) {
		return("$schema\@$sid\@$host");
	} else {
		return("$sid\@$host");
	}
}

sub parseArguments {
	my $self = shift;
	my $args = shift;

	my @vals = split(/\@/, $args);
	my ($sid, $host, $schema);
	if(scalar(@vals) == 2) {
		($sid, $host) = @vals;
	} elsif(scalar(@vals) == 3) {
		($schema, $sid, $host) = @vals;
	} else {
		my $stepname = $self->step();
		die("Illegal [schema\@]sid\@host specification in Step $stepname.");
	}

	if($sid && $host) {
		$host .= ".ariba.com" unless($host =~ /\.ariba\.com$/ || $host eq 'localhost' || $host =~ /^\d+\.\d+\.\d+\.\d+$/);
		$self->setSid($sid);
		$self->setHost($host);
	}
		
	if($schema) {
		my $pass;
		($schema, $pass) = split(/\//, $schema);
		$self->setSchema($schema);
		$self->setPassword($pass);
	}

	unless($self->sid() && $self->host()) {
		my $stepname = $self->step();
		die("OracleAction requires sid and host as argument in Step $stepname.");
	}
}

sub reparseArgs {
	my $self = shift;
	my $vars = shift;
	my $args = shift;

	foreach my $var (keys %$vars) {
		my $val = $$vars{$var};
		$args =~ s/\$\{$var\}/$val/g;
	}

	$self->parseArguments($args);
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
		if($args =~ /\$\{[^\}]+\}/) {
			$self->setUnparsedArgs($args);
		} else {
			$self->parseArguments($args);
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
			}
			elsif($line =~ /^\s*Timeout:\s*(.*)$/) {
				my $val = $1;
				$command->setTimeout($val);
			} elsif(! $self->parseStatusStrings($command, $line) ) {
				my $stepname = $step->name();
				die("Unrecognized syntax in Step $stepname OracleAction: $line");
			}
		} else {
			my $stepname = $step->name();
			die("Unrecognized syntax in Step $stepname OracleAction: $line");
		}
	}
}

sub getSchemaPassword {
	my $self = shift;
	my $schema = $self->schema();
	my $sid = $self->sid();
	my $mcl = ariba::Ops::MCL->currentMclObject();
	my $service = $mcl->productServiceForMCL();
	my @products;

	foreach my $pname (ariba::rc::Globals::allProducts()) {
		if(ariba::rc::InstalledProduct->isInstalled($pname, $service)) {
			push(@products, ariba::rc::InstalledProduct->new($pname, $service));
		}
	}

	map { $_->setReturnEncryptedValues(1) } @products;

	my @dbc = ariba::Ops::DBConnection->connectionsFromProducts(@products);
	my $dc;
	foreach my $c (@dbc) {
		if(lc($c->user()) eq lc($schema) && lc($c->sid()) eq lc($sid)) {
			$dc = $c;
			last;
		}
	}

	return(undef) unless($dc);

	my $password = $dc->password();
	if($mcl->service() ne $service) {
		$password = ariba::rc::Passwords::decryptValueForSubService($password, $service);
	}

	return($password);
}

sub getPassword {
	my $self = shift;
	my $type = shift;
	my $mcl = ariba::Ops::MCL->currentMclObject();
	my $service = $mcl->productServiceForMCL();
	my $ret;

	if($type =~ /^[^:]+:/i) {
		my ($svc, $hash) = split(/:/, $type);
		$ret = ariba::rc::Passwords::decryptValueForSubService($hash, $svc);
		return($ret);
	} elsif($type =~ m|/|) {
		#
		# lookup a schema password
		#
		my ($schema, $product);
		my @i = split(/\//, $type);

		if(scalar(@i) == 2) {
			$product = $i[0];
			$schema = $i[1];
			$service = $mcl->service();
		} elsif (scalar(@i) == 3) {
			$product = $i[0];
			$schema = $i[2];
			$service = $i[1];
		} else {
			return("");
		}

		my $sid;
		( $schema, $sid ) = split(/\@/, $schema);

		my $p = ariba::rc::InstalledProduct->new($product, $service);
		$p->setReturnEncryptedValues(1);
		my @dbcs = ariba::Ops::DBConnection->connectionsFromProducts($p);
		my $dbc;
		@dbcs = grep { uc($_->sid()) eq uc($sid) } @dbcs if($sid);
		( $dbc ) = grep { uc($_->user()) eq uc($schema) } @dbcs;
		$ret = $dbc->password();
	} else {
		#
		# lookup sys or system password
		#
		my $mon = ariba::rc::InstalledProduct->new('mon', $service);
		$mon->setReturnEncryptedValues(1);
		$ret = $mon->default("dbainfo.$type.password");
	}

	if($mcl->service() ne $service) {
		$ret = ariba::rc::Passwords::decryptValueForSubService($ret, $service);
	}

	return($ret);
}

sub executeLocal {
	my $self = shift;
	my $mcl = ariba::Ops::MCL->currentMclObject();
	my $blurPasswords;
	my %blurValues;

	my $sid = $self->sid();
	my $host = $self->host();
	my $schema = $self->schema();
	my $schemaPassword = $self->password();

	if($schemaPassword && $schemaPassword =~ /^password:/) {
		my @vals = split(/:/, $schemaPassword);
		my ($service, $crypt);
		if(scalar(@vals) == 2) {
			$service = $mcl->service();
			$crypt = $vals[1];
		} else {
			$service = $vals[1];
			$crypt = $vals[2];
		}

		$schemaPassword = ariba::rc::Passwords::decryptValueForSubService($crypt, $service);
	}

	if($schema && !$schemaPassword) {
		$schemaPassword = $self->getSchemaPassword();
	}

	if($schema) {
		$self->setFakePrompt("$schema\@$sid $host SQL>");
	} else {
		$self->setFakePrompt("$sid\@$host SQL>");
	}

	my $serviceManager = ariba::Ops::OracleServiceManager->new($sid);

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

		#
		# OracleServiceManager needs semicolons!
		#
		if($runCmd !~ /\s*\;\s*$/) {
			$runCmd .= ";";
		}

		my $prompt = $self->fakePrompt();
		my $actionCommand = $cmd->actionNumber() . ":" . $cmd->commandNumber();
		$logger->info("$actionCommand $prompt $runCmd");

		my $regex = $self->passwordRegex();
		while($runCmd =~ /$regex/) {
			my $type = $1;
			my $pass = $self->getPassword($type);
			$runCmd =~ s/$regex/$pass/;
			next unless($pass); # don't "blur" an empty string
			$blurPasswords = 1;
			$blurValues{$pass} = $type;
		}

		my $timeout = $cmd->timeout();
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
		# log the output
		#
		foreach my $line (@output) {
			chomp $line;
			$line =~ s/\r//;
			if($blurPasswords) {
				# we looked up and substituted in a password, we need to
				# clean the output so we don't log it back
				my $count = 0;
				foreach my $k (sort { length($b) <=> length($a) } (keys %blurValues)) {
					my $blur = "[password for ::USER::$count::]";
					$count++;
					my $regex = quotemeta($k);
					$line =~ s/$regex/$blur/gi;
					#
					# this is a dumb edge case, but if you do this:
					#
					# select 'PASSWORD:s4/S3LIVEDW028' from V$DATABASE;
					#
					# then oracle will use a truncated by 1 password as the
					# column header.  So we'll catch that too.
					#
					my $substr = substr($k, 0, length($k)-1);
					$substr = quotemeta($substr);
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
		$cmd->setOutput($outputString);

		unless(scalar($cmd->errorStrings()) || scalar($cmd->successStrings())) {
			#
			# use this for a default error string
			#
			$cmd->setErrorStrings( '(error|ORA-\d+|SP2-\d+)' );
		}

		return(0) unless($self->checkCommandOutputForStatus($cmd, 1, \@output));
	}

	$self->setActionOutput();

	return(1);
}

1;
