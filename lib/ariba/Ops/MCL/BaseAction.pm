#!/usr/local/bin/perl

package ariba::Ops::MCL::BaseAction;

use strict;
use base qw(ariba::Ops::PersistantObject);
use ariba::Ops::MCLGen;

sub sendInfoToUI {
	my $self = shift;
	my $info = shift;

	my $mcl = ariba::Ops::MCL->currentMclObject();
	my $dir = $mcl->messagedir();
	my $file = "$dir/message-" . $self->step() . "-" . time();

	my $FH;
	open($FH, "> $file");
	print $FH $self->step() . ":" . "$info\n";
	close($FH);
}

sub isCompleted {
	my $self = shift;
	return 1 if($self->status eq 'Completed');
	return 0;
}

sub commandPrefix {
	return '$';
}

sub definition {
	my $self = shift;

	my $type = ref($self); $type =~ s/Action$//; $type=~s/^ariba::Ops::MCL:://;
	my $args = $self->arguments();
	my @commands;
	foreach my $c ($self->commands()) {
		my $prefix = $c->commandPrefix() or $self->commandPrefix();
		$prefix .= " " if($prefix);
		push(@commands, "$prefix" . $c->commandLine());
		foreach my $e ($c->errorStrings()) {
			push(@commands, "  ErrorString: $e");
		}
		foreach my $e ($c->successStrings()) {
			push(@commands, "  SuccessString: $e");
		}
		foreach my $e ($c->successIfStrings()) {
			push(@commands, "  SuccessIf: $e");
		}
		if($c->perlCheck()) {
			push(@commands, "  PerlCheck: " . $c->perlCheck());
		}

		push(@commands, "  IgnoreExitCode") if($c->ignoreExitCode());
		push(@commands, "  Timeout: " . $c->timeout()) if($c->timeout());
	}
	my $ret = defineAction($type, $args, @commands);

	return($ret);
}

sub validAccessorMethods {
	my $class = shift;

	my $ref = $class->SUPER::validAccessorMethods();
	my @accessors = qw( actionNumber commands fakePrompt host header mcl output status step unparsedArgs user service );

	foreach my $accessor (@accessors) {
		$ref->{$accessor} = 1;
	}

	return($ref);
}

sub reparseArgs {
}

sub arguments {
	return(undef);
}

#
# by default, actions are not remote
#
sub isRemote {
	my $self = shift;
	return 0;
}

sub iterate {
	my $list = shift;
	my $c = shift;

	my @array = split(/\s+/,$list);
	$c = ($c % scalar(@array));

	return($array[$c]);
}

sub duplicate {
	my $self = shift;
	my $src = shift;
	my $vars = shift;
	my $iterateCount = shift;
	my @commands;


	foreach my $attr(qw(host user variable sid schema password)) {
		my $str = $src->attribute($attr);
		next unless($str);
		foreach my $var (keys %$vars) {
			my $val = $$vars{$var};
			$str =~ s/\$\{$var\}/$val/g;
		}
		while($str =~ /Iterate\(\s*([^\)]+)\s*\)/) {
			my $list = $1;
			$list =~ s/^'//;
			$list =~ s/'$//;
			my $repl = iterate($list, $iterateCount);
			$str =~ s/Iterate\(\s*([^\)]+)\s*\)/$repl/;
		}
		$self->setAttribute($attr, $str);
	}

	if($src->unparsedArgs()) {
		my $str = $src->unparsedArgs();
		while($str =~ /Iterate\(\s*([^\)]+)\s*\)/) {
			my $list = $1;
			$list =~ s/^'//;
			$list =~ s/'$//;
			my $repl = iterate($list, $iterateCount);
			$str =~ s/Iterate\(\s*([^\)]+)\s*\)/$repl/;
		}
		$self->reparseArgs($vars, $src->unparsedArgs());
	}

	foreach my $baseCmd ($src->commands()) {
		my $cmd = ref($baseCmd)->newFromParser(
			$baseCmd->mcl(),
			$baseCmd->step(),
			$self->actionNumber(),
			$baseCmd->commandNumber(),
			$baseCmd->commandLine()
		);
		$cmd->duplicate($baseCmd, $vars, $iterateCount);
		push(@commands, $cmd);
	}
	$self->setCommands(@commands);
}

sub setStatus {
	my $self = shift;

	$self->SUPER::setStatus(@_);
	$self->save();
}

sub dir {
    return('/var/mcl');
}

sub _computeBackingStoreForInstanceName {
    my $class = shift;
    my $instance = shift;

    my ($mclname, $stepname, $number) = split(/\-\-/, $instance);
    my $store = "/var/mcl/$mclname/actions/${stepname}-$number";
    return($store);
}

sub newFromParser {
	my $class = shift;
	my $mcl = shift;
	my $step = shift;
	my $number = shift;

	my $instance = $mcl . "--" . $step . "--" . $number;

	my $self = $class->SUPER::new($instance);

	$self->setMcl($mcl);
	$self->setStep($step);
	$self->setActionNumber($number);

	return($self);
}

#
# your subclass should implement this function to parse action specification
#
sub parse {
	my $self = shift;
	my $mcl = shift;
	my $step = shift;
	my $args = shift;
	my (@stream) = (@_);

	while(my $line = shift(@stream)) {
		chomp($line);
		$line = $mcl->expandVariables($line);
		last if($line =~ /^\s*\{\s*$/);
		#
		# subclass should implement parser here
		#

		#
		# You should die if you encounter invalid syntax!!!!
		#
	}

	return(@stream);
}

sub execute {
	my $self = shift;
	return ($self->SUPER::execute());
}

sub dryrun {
	my $self = shift;
	my $out;

	foreach my $command ($self->commands()) {
		$out .= $self->fakePrompt();
		$out .= " ";
		$out .= $command->commandLine();
		$out .= "\nCommand not run in dryrun mode.\n";
	}
	$self->setOutput($out);

	return(1);
}

sub fakePrompt {
	my $self = shift;
	my $prompt;

	$prompt = $self->attribute('fakePrompt');

	unless($prompt) {
		if($self->host() && $self->user()) {
			$prompt = $self->user() . "\@" . $self->host() . " \$";
		}
	}

	unless($prompt) {
		my $type = ref($self);
		$type =~ s/^ariba::Ops::MCL:://;
		$type =~ s/Action$//;
		$prompt = "$type \$";
	}

	$prompt =~ s/\.ariba\.com//; # chop this -- it's clutter
	return("+++ $prompt");
}

sub checkCommandOutputForStatus {
	my $self = shift; # an action object
	my $cmd = shift; # the command
	my $ret = shift; # command return code
	my $output = shift; # reference to the output
	my $errorStrings = shift;
	my $successStrings = shift;
	my $successIfStrings = shift;
	my $perlCheck = shift || $cmd->perlCheck();
	my $runCmd = shift;

	$runCmd = $cmd->commandLine() unless($runCmd);

	my $logger = ariba::Ops::Logger->logger();

	if($perlCheck) {
		my $call = "ariba::Ops::MCL::ErrorCheckers::$perlCheck(\$output);";
		my $ret = eval $call;

		if($@) {
			$logger->error("$perlCheck failed: $@");
			my $out = $cmd->output();
			$out .= "\nERROR: $perlCheck failed: $@\n";
			$cmd->setOutput($out);
			$cmd->setStatus('Failed');
			$self->setActionOutput();
			return(0);
		} else {
			if($ret =~ /ERROR:/) {
				$logger->error("$perlCheck failed: $ret");
				my $out = $cmd->output();
				$out .= "\nERROR: $perlCheck failed: $ret\n";
				$cmd->setOutput($out);
				$cmd->setStatus('Failed');
				$self->setActionOutput();
				return(0);
			}
		}
	}

	#
	# these override all other behavior -- this string indicates success
	# regardless of any other errors
	#
	# example use case:
	#
	# $ mkdir /foo
	# SuccessIf: cannot\screate\sdirectory.*:\sFile\sexists
	#
	# basically if this fails because the directory is already there, then
	# the step succeeds.  (nevermind that you can just use -p to mkdir)
	#
	if($successIfStrings || $cmd->successIfStrings()) {
		my @array;
		if($successIfStrings) {
			@array = @$successIfStrings;
		} else {
			@array = $cmd->successIfStrings();
		}
		foreach my $str (@array) {
			foreach my $line (@$output) {
				if($line =~ /$str/) {
					return(1);
				}
			}
		}
	}

	unless($ret || $cmd->ignoreExitCode()) {
		$logger->error("ERROR: '$runCmd' exited with non-zero exit code.");
		my $out = $cmd->output();
		$out .= "\nERROR: $runCmd exited with non-zero exit code.\n";
		$cmd->setOutput($out);
		$cmd->setStatus('Failed');
		$self->setActionOutput();
		return(0);
	}

	if($errorStrings || $cmd->errorStrings()) {
		my @array;
		if($errorStrings) {
			@array = @$errorStrings;
		} else {
			@array = $cmd->errorStrings();
		}
		foreach my $err (@array) {
			foreach my $line (@$output) {
				if($line =~ /$err/) {
					$logger->error("ERROR: Found error string '$err' in output!");
					my $out = $cmd->output();
					$out .= "\nERROR: Found error string '$err' in output!\n";
					$cmd->setOutput($out);
					$cmd->setStatus('Failed');
					$self->setActionOutput();
					return(0);
				}
			}
		}
	}

	if($successStrings || $cmd->successStrings()) {
		my @array;
		if($successStrings) {
			@array = @$successStrings;
		} else {
			@array = $cmd->successStrings()
		}
		foreach my $string (@array) {
			$ret = 0;
			foreach my $line(@$output) {
				$ret = 1 if($line =~ /$string/);
			}
			unless($ret) {
				$logger->error("ERROR: Did not find success string '$string' in output!");
				my $out = $cmd->output();
				$out .= "\nERROR: Did not find success string '$string' in output!\n";
				$cmd->setOutput($out);
				$cmd->setStatus('Failed');
				$self->setActionOutput();
				return(0);
			}
		}
	}

	#
	# this command checks out
	#
	return(1);
}

sub parseStatusStrings {
	my $self = shift;
	my $command = shift;
	my $line = shift;

	if($line =~ /^\s*ErrorString:\s*(.*)$/) {
		my $val = $1;
		$command->appendToErrorStrings($val);
	} elsif($line =~ /^\s*SuccessString:\s*(.*)$/) {
		my $val = $1;
		$command->appendToSuccessStrings($val);
	} elsif($line =~ /^\s*SuccessIf:\s*(.*)$/) {
		my $val = $1;
		$command->appendToSuccessIfStrings($val);
	} elsif($line =~ /^\s*PerlCheck:\s*(.*)$/) {
		my $val = $1;
		$command->setPerlCheck($val);
	} else {
		return(0);
	}

	return(1);
}

1;
