#!/usr/local/bin/perl

package ariba::Ops::MCL::ShellAction;

use strict;
use File::Basename;

use base qw(ariba::Ops::MCL::BaseAction);
use ariba::Ops::MCL::BasicCommand;
use ariba::Ops::NetworkUtils;
use ariba::Ops::Utils;
use ariba::Ops::Logger;
use ariba::rc::Utils;

my $logger = ariba::Ops::Logger->logger();

sub objectLoadMap {
	my $class = shift;

	my $map = $class->SUPER::objectLoadMap();

	$map->{'commands'} = '@ariba::Ops::MCL::BasicCommand';

	return($map);
}

sub logOutputTo {
	my $self = shift;
	my $mcl = ariba::Ops::MCL->currentMclObject();

	my $dir = $mcl->logdir();
	$dir =~ s/\d+$/real-time-output/;
	ariba::rc::Utils::mkdirRecursively($dir);
	my $file = "$dir/" . $self->instance();
	return($file);
}

sub arguments {
	my $self = shift;

	my $user = $self->user();
	my $host = $self->host();

	return("$user\@$host");
}

sub host {
	my $self = shift;

	my $host = $self->attribute('host');
	unless($host =~ /^\d+\.\d+\.\d+\.\d+$/) {
		$host =~ s/(?:\.ariba\.com)+$/.ariba.com/;
	}
	return($host);
}

sub execute {
	my $self = shift;
	my $ret;
	my $mcl = ariba::Ops::MCL->currentMclObject();

	if($self->isRemote()) {
		$ret = $self->executeRemote();
	} else {
		my $user = $self->user();
		my $host = $self->host();

		$logger->info("==== $user\@$host ====");
		$ret = $self->executeLocal();
		my $breakLine = "=" x (length("$user\@$host")+10);
		$logger->info($breakLine);
	}

	return($ret);
}

sub isRemote {
	my $self = shift;

	return(0) if(ariba::Ops::MCL::inDebugMode());

	my $host = ariba::Ops::NetworkUtils::hostname();
	my $uid = $<;
	my $user = (getpwuid($uid))[0];

	if($user eq $self->user() && $host eq $self->host()) {
		return(0);
	} elsif($host eq $self->host()) {
		return(1);
	} else {
		return(2);
	}
}

# This hack pains me so much.
# We just implemented split-mp for Buyer, AN, and Spotbuy which required an update to Passwords.pm to parse <master>split<pci>
# Because we absorb tools code into each product some of our products do not have the new code and thus can not parse split-mp.
# If we pass split-mp into control-deployment for these other products it will try to use the split-mp string as the standard mp 
# and fail.  Thus this ugly if else mess.  Please rip this out once we have vault.  It's an affront and to proper code design.
sub standardOrSplit {
    my $command = shift;
    my $master = shift;

    # if split-mp was not passed in then skip all this math.
    if ( $master =~ /split/ ) {

        # Is the command running control-deployment?
        # Yay, hard coding for one command possibility.
        if ( $command =~ /control-deployment/ ) {         

            # OK, are we running control-deployment for one of the split-mp products?
            # Yay, hard coding for specific products.
            my @needSplitMP = ( " an ", " buyer ", " spotbuy " );
            my $match = 0;
            foreach my $product ( @needSplitMP ) {
                if ( $command =~ /$product/ ) {
                    $match = 1;
                    last;
                }
            }
        
            # If we didn't find a match then we're running control-deployment for a product that does not need split-mp
            # and may not be capable of parsing split-mp.  Truncate to just the standard mp.
            # There is not a shower long enough to clean the stink off this hack.
            unless ( $match ) {
                ($master) = ($master =~ /(^.*)split/);
            }
        }
    }

    return $master;
}

sub executeRemote {
	my $self = shift;
	my @output;

	my $host = $self->host();
	my $user = $self->user();
	my $mclctl = $FindBin::Bin . "/" . basename($0);
	unless( $mclctl =~ /mcl-control/ && -e $mclctl ) {
		$mclctl = "/usr/local/ariba/bin/mcl-control";
	}

	my $password = ariba::rc::Passwords::lookup( $user );
	my $master = ariba::rc::Passwords::lookupMasterPci( undef, 1 );

	#
	# variables are stored locally... and if we have to rsh, then we also need
	# to package off the variables so that the remote end can parse the MCL
	# with the same values.
	#
	# This is kind of an ugly hack, but it is preferable to other ideas I had
	# to solve this problem.
	#
	my $mcl = ariba::Ops::MCL->currentMclObject();

	#
	# we also need the MCL on the remote side
	#
	unless( $mcl->transferMCLFile($host, $user) ) {
		$self->setOutput("ERROR: Failed to copy MCL file to remote host.\n");
		return(0);
	}

    my $service = $mcl->service();
    $service = ariba::Ops::Utils::serviceForUser( $user ) unless ( $service eq 'devlab' );

	my $command = "ssh -o TCPKeepAlive=yes -o ServerAliveInterval=120 -l $user $host $mclctl remoteaction -mcl " . $self->mcl() . " -step " . $self->step() . " -action " . $self->actionNumber() . " -dir /tmp -service $service";

	$logger->info("Run: $command");
	$logger->info("==== $user\@$host ====");

	my $ret = ariba::rc::Utils::executeRemoteCommand(
		$command,
		$password,
		0,
		$master,
		undef,
		\@output
	);

	my @savedOutput;
	my $exitOk = 0;

	foreach my $line (@output) {
		$line =~ s/^\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d\s*//;
		$line =~ s/^\(info\)\s*//;
		$line =~ s/^(\d+:\d+)\s*\+\+\+/+++/;

		next if($line =~ /^\s*$/);
		next if($line =~ /Master Password is good./);
		next if($line =~ m|Reading /tmp/.*variables$|);
		if($line =~ /Execution Finished: Exiting Normally/) {
			$exitOk = 1;
			next;
		}

		$logger->info($line);
		push(@savedOutput, $line);
	}

	my $breakLine = "=" x (length("$user\@$host")+10);
	$logger->info($breakLine);

	my $outputText = join("\n", @savedOutput);

	$self->setOutput($outputText);

	#
	# If we didn't see the remote side exit normally, we did NOT succeed.
	#
	if($ret && !$exitOk) {
		$logger->error("Remote session ended abnormally.");
		$ret = 0;
	}

	return($ret);
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

        my @vals = split( /\@/, $args );
        my ( $user, $service, $host );
        if ( scalar( @vals ) == 2 ) {
            ( $user, $host ) = @vals;
        } 
        elsif ( scalar( @vals ) == 3 ) {
            ( $user, $service, $host ) = @vals;
        } 
        else {
            my $stepname = $self->step();
            die("Illegal user[\@service]\@host specification in Step $stepname.");
        }

		if($user && $host) {
			$host .= ".ariba.com" unless($host =~ /\.ariba\.com$/ || $host eq 'localhost' || $host =~ /^\d+\.\d+\.\d+\.\d+$/);
			$self->setUser($user);
			$self->setHost($host);
			$self->setService($service);
		}
	}

	unless($self->user() && $self->host()) {
		$self->setHost( ariba::Ops::NetworkUtils::hostname() );
		my $uid = $<;
		$self->setUser( (getpwuid($uid))[0] );
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
			} elsif($line =~ /^\s*IgnoreExitCode/) {
				$command->setIgnoreExitCode(1);
			} elsif(! $self->parseStatusStrings($command, $line) ) {
				my $stepname = $step->name();
				die("Unrecognized syntax in Step $stepname ShellAction: $line");
			}
		} else {
			my $stepname = $step->name();
			die("Unrecognized syntax in Step $stepname ShellAction: $line");
		}
	}
}

sub executeLocal {
	my $self = shift;

	my $uid = $<;
	my $user = (getpwuid($uid))[0];
	my $password = ariba::rc::Passwords::lookup( $user );

	my $service = ariba::Ops::Utils::serviceForUser($user);
	my $master;
	if( $service ) {
		$master = ariba::rc::Passwords::lookup("${service}Master");
	}
	unless($master) {
		$master = ariba::rc::Passwords::lookupMasterPci( undef, 1 );
	}

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

		my $prompt = $self->fakePrompt();
		my $actionCommand = $cmd->actionNumber() . ":" . $cmd->commandNumber();
		$logger->info("$actionCommand $prompt $runCmd");

        # Butt ugly hack alert
        $master = standardOrSplit( $runCmd, $master );

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
