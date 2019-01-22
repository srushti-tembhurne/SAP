#
# $Id: //ariba/services/tools/lib/perl/ariba/Ops/ControlDeploymentHelper.pm#27 $
#
# A helper class to manage commands launched by control-deployment. This
# will also manage the logs and display to stdout.
#
#

package ariba::Ops::ControlDeploymentHelper;

use strict;
use POSIX;
use ariba::Ops::SharedMemoryChild;
use ariba::rc::Utils;
use ariba::Ops::NetworkUtils;
use ariba::Ops::DeploymentHelper;
use File::Path;
use base qw(ariba::Ops::PersistantObject);

my $maxParallelProcesses = 10;
my $curParallelProcesses = 0;
my $instanceCount = 0;
my $exitStatus = 0;
my $quiet = 0;
my $logging = 1;

# For load balancing logic
my %processesPerHosts = ();  
my %leastFavoriteHosts = ();  # skip over these if at all possible
my $loadBalancingEnabled = 0;
my $_logRoot = "$ENV{'HOME'}/logs";

#
# Class methods:
#
sub setQuiet {
	my $class = shift;
	my $q = shift;

	$quiet = $q;
}

sub quiet {
	return($quiet);
}

sub setLogging {
	my $class = shift;
	my $q = shift;

	$logging = $q;
}

sub logging {
	return($logging);
}

sub newUsingProductAndCustomer {
	my $class = shift;
	my $productName = shift;
	my $customer = shift;

	my $instanceName = $productName;
	$instanceName .= "-$customer" if ($customer);
	$instanceName .= "-" . $instanceCount++;

	my $self = $class->SUPER::new($instanceName);

	$self->setLogRoot($_logRoot);
	$self->setProductName($productName);
	$self->setCustomer($customer);

	return $self;
}

sub newUsingProductServiceAndCustomer {
	my $class = shift;
	my $product = shift;
	my $service = shift;
	my $customer = shift;

	my $self = $class->newUsingProductAndCustomer($product, $customer);

	$self->setService($service) if ($service);

	return $self;
}

sub validAccessorMethods {
        my $class = shift;

	my $methodsRef = $class->SUPER::validAccessorMethods();

        $methodsRef->{'productName'} = undef;
        $methodsRef->{'customer'}    = undef;
        $methodsRef->{'service'}    = undef;

        $methodsRef->{'logDir'}     = undef;
        $methodsRef->{'logRoot'}     = undef;
        $methodsRef->{'logFilePath'} = undef;
        $methodsRef->{'numErrors'}   = undef;

        $methodsRef->{'action'}      = undef;
        $methodsRef->{'user'}        = undef;
        $methodsRef->{'host'}        = undef;
        $methodsRef->{'logName'}     = undef;
		$methodsRef->{'output'}      = undef;
        $methodsRef->{'description'} = undef;
        $methodsRef->{'commands'}    = undef;

        $methodsRef->{'testing'}     = undef;
        $methodsRef->{'timeStarted'} = undef;

        $methodsRef->{'exitStatus'} = undef;

        $methodsRef->{'skipOnSshFailure'} = undef;

        return $methodsRef;
}

sub dir {
	my $class = shift;
	return undef;
}

sub setMaxParallelProcesses {
	my $class = shift;
	$maxParallelProcesses = shift;

	return ($maxParallelProcesses);
}

sub maxParallelProcesses {
	my $class = shift;

	return ($maxParallelProcesses);
}

sub setLoadBalancingEnabled {
	$loadBalancingEnabled = 1;
}

sub setLeastFavoriteHosts {
	my $self = shift;

	%leastFavoriteHosts = map { $_ => 1 } @_;
}

sub setAvailableHosts (@) {
	my $program = shift;
	my @availableHosts = @_;
	for my $host (@availableHosts) {
		$processesPerHosts{$host} = 0;
	}
}

sub incrementProcessesPerHosts {
	my $program = shift;
	my $host = shift;
	my $currentProcessCountOnHost = $processesPerHosts{$host};
	$processesPerHosts{$host} = $currentProcessCountOnHost + 1;
}

sub decrementProcessesPerHosts {
	my $program = shift;
	my $host = shift;
	my $currentProcessCountOnHost = $processesPerHosts{$host};
	$processesPerHosts{$host} = $currentProcessCountOnHost - 1;
}

sub getLeastLoadedHost {
	my $leastLoadedHost = undef;
	my $minimumProcessCount = -1;
	my @availableHosts = keys(%processesPerHosts);

	if (keys %leastFavoriteHosts) {

		# push least favorite hosts to the back of the array; this
		# will cause them to be picked last, or never if not needed
		@availableHosts = sort { 
			if ( $leastFavoriteHosts{$a} ) { 
				1;
			} elsif ( $leastFavoriteHosts{$b} ) {
				-1;
			} else {
				0;
			}
		} @availableHosts;

	}

	for my $host (@availableHosts) {
	    my $currentProcessCountOnHost = $processesPerHosts{$host};
	    if ($minimumProcessCount == -1) {
	    	$leastLoadedHost = $host;
	    	$minimumProcessCount = $currentProcessCountOnHost;
	    }
	    else {
	    	if ($currentProcessCountOnHost < $minimumProcessCount) {
	    		$leastLoadedHost = $host;
	    		$minimumProcessCount = $currentProcessCountOnHost;
	    	}
	    }
	}
	return $leastLoadedHost;
}

sub incrementParallelProcessCount {
	my $class = shift;
	my $count = shift || 1;

	$curParallelProcesses += $count;

	return ($curParallelProcesses);
}

sub decrementParallelProcessCount {
	my $class = shift;
	my $count = shift || 1;

	$curParallelProcesses -= $count;

	return ($curParallelProcesses);
}

sub curParallelProcesses {
	my $class = shift;

	return ($curParallelProcesses);
}

sub logDirForProductServiceCustomerActionAndTime {
	my $class = shift;
	my $productName = shift;
	my $service = shift;
	my $customer = shift;
	my $action = shift;
	my $time = shift;

	# logs are kept like so:
	# In directory: # $LOG_ROOT/$product/$date--$product-[$service-$customer-]$action/
	#  $date is of the form 20050915-124543 (YYYYMMDD-hhmmss)
	#
	my $logIdent = $productName;

	$logIdent .= "-$service" if ($service);
	if ($customer) {
		$logIdent .= "-$customer";
	}

	my $DATE_FORMAT = "%Y%m%d-%H%M%S";
	my $formattedStartDate = POSIX::strftime($DATE_FORMAT, localtime($time));

	my $logSubDir = "$productName/$formattedStartDate-$logIdent-$action";
	my $logDir = "$_logRoot/$logSubDir";

	return $logDir;
}

# had a typo in method name (migration tool now also uses it), slowly
# deprecate it.
sub displayLogFilesNamesAnnotedWithErrors {
	my $class = shift;
	return $class->displayLogFilesNamesAnnotatedWithErrors(@_);
}

#FIXME remove this when control-deployment-new is merged back into
#control-deployment
sub displayLogFilesNamesAnnotatedWithErrors {
	my $class = shift;

	return $class->logFileNamesAnnotatedWithErrors();
}

sub logFileNamesAnnotatedWithErrors {
	my $class = shift;
	my $outputArrayRef = shift;

	my $totalErrors = 0;

	my $hostname = ariba::Ops::NetworkUtils::hostname();
	$hostname =~ s|\.ariba\.com||;

	#
	# For each helper that was launched, display a summary
	# of logfiles created (mark the ones that have errors)
	# 
	for my $object ($class->_listObjectsInCache()) {
		my $logFile = $hostname . ": " . $object->logFilePath();
		my $numErrors = $object->numErrors();
		my $name = $object->productName();
		my $cust = $object->customer();
		my $service = $object->service();

		my $ident = $name;
		$ident .= "-$cust" if ($cust);

		if ($numErrors) {
			if ($outputArrayRef) {
				push @$outputArrayRef, " ** $ident: $logFile **";
			} else {
				print " ** $ident: $logFile **\n" unless $class->quiet();
			}
			$totalErrors += $numErrors;
		} else {
			if ($outputArrayRef) {
				push @$outputArrayRef, "    $ident: $logFile";
			} else {
				print "    $ident: $logFile\n" unless $class->quiet();
			}
		}
	}

	return($totalErrors);
}

sub waitForBackgroundCommands {
	my $class = shift;
	my $num = shift;
	my $finished = 0;

	while (1) {

		#
		# Any more childern lest to reap?
		#
		last if ($class->curParallelProcesses() <= 0);

		my @kids = ariba::Ops::SharedMemoryChild->waitForChildren(1);
		last unless (@kids);


		#
		# one child just finished
		# process its output and exit status
		#
		my $kid = $kids[0];

		unless( defined( $kid )) {
			print "ERROR: kid is undefined in reap in ariba::Ops::ControlDeploymentHelper::waitForBackgroundCommands()\n";
			next;
		}

		#
		# Pull out the helper instance handle from PO cache using
		# the instance name that was set as the tag.
		#
		my $instanceName = $kid->tag();
		my $object = $class->new($instanceName);

		#
		# fetch all the attributes
		#
		my $productName = $object->productName();
		my $service = $object->service();
		my $customer = $object->customer();
		my $action = $object->action();
		my $user = $object->user();
		my $host = $object->host();
		my $logName = $object->logName();
		my $description = $object->description();
		my $cmd = $object->commands();

		$finished++;
		$class->decrementParallelProcessCount();
	    if ($loadBalancingEnabled) {		
		    $class->decrementProcessesPerHosts($host);
	    }
		my @output = $kid->returnValue();
		my $exitValueOfKid = $kid->exitValue(); 

		$object->setExitStatus($exitValueOfKid);

		$exitStatus = $exitValueOfKid || $exitStatus;

		my $foundError = 0;

		#
		# screen scrape the output for common errors
		#
		for ( my $x=0; $x < scalar(@output); $x++ ) {
			if ( $output[$x] =~ /(
				Permission\ denied|
				No\ such\ file\ or\ directory|
				\bfailed\b|
				\berror(s?)\b|
				\bdie\b|
				not\ found|
				File\ exists|
				line\ \d+$|
				Incorrect\ Master\ Password|
				Undefined\ subroutine|
				incorrect\ password|
				Command\ not\ found|
				This\ incident\ will\ be\ reported|
				could\ not\ be\ started|
				Address\ already\ in\ use
			)/ix ){
				if ( $x < $#output # there is a next line
					&& $output[$x] =~ /Fatal server error:/i
					&& $output[$x+1] =~ /Server is already active for display/i
				) {
					# This message comes from xvfb when another
					# instance is started on the same display
					# It's ok to ignore as in every case xvfb has
					# already been started;
					# see TMID 74955
					next;
				}

				if ( $output[$x] =~ /(
					Failed\ to\ connect\ to\ t3|
					0\ elements\ failed|
					failed\ to\ shutdown\ successfully|
					The\ APR\ based\ Apache\ Tomcat\ Native\ library\ which\ allows\ optimal\ performance\ in\ production\ environments\ was\ not\ found|
					hadoop\.security\.logger=ERROR
				)/ix ) {
					#
					# acceptable warning spew from aes deployment,
					# when adminserver launches and configures
					# sourcing
					#
				} else {
					$foundError++;
					$output[$x] = "ERR" . $output[$x];
				}
			}
		}

		#
		# Log file management
		#
		#   one log file for each logName, of the form 
		#   $date--$logName.log
		#  
		#  $date is of the form 20050915-124543 (YYYYMMDD-hhmmss)
		#
		my $logDir = $object->logDir();
		mkpath($logDir) if($class->logging());

		my $productAndCustomer = $productName;
		$productAndCustomer .= "($customer)"  if ($customer);

		my $DATE_FORMAT = "%Y%m%d-%H%M%S";
		my $formattedDate = POSIX::strftime($DATE_FORMAT, localtime);
		my $logFileName = "${formattedDate}--${logName}.log";
		my $logPath = "$logDir/$logFileName";

		$object->setLogFilePath($logPath);

		#
		# write output of the cmd to logfile. Highlight any errors
		# in the log and also display error lines to stdout
		#
		my @savedOutput;
		if($class->logging()) {
			open(LOG, ">$logPath") || print "Unable to open $logPath, $!\n";
		}

		if($class->logging()) {
			print LOG '-' x 72, "\n";
			printf LOG "  begin: %15s %25s  [%s]\n", $productAndCustomer, $host, $description;
		}
		push(@savedOutput,"  begin: %15s %25s  [%s]\n" . $productAndCustomer . $host . $description);

		my $numErrors = $object->numErrors() || 0;
		$numErrors++ if ($exitValueOfKid);

		if ($exitValueOfKid != 0 || $foundError) {
			print "\t! ERROR ($host): $foundError error(s) exit status = $exitValueOfKid\n" unless $class->quiet();
			print LOG "\t! ERROR ($host): $foundError error(s) exit status = $exitValueOfKid\n" if $class->logging();
			push(@savedOutput, "\t! ERROR ($host): $foundError error(s) exit status = $exitValueOfKid\n");

			#
			# print output to a logfile. Also print the error
			# line to stdout
			#
			for my $line (@output) {
				my $errorLine = 0;
				if ( $line =~ s/^ERR/ERR>\t! / ) {
					$errorLine = 1;
				} else {
					$line =~ s/^/\t! /;
				}

				print $line,"\n" if ($errorLine && !$class->quiet());

				print LOG $line,"\n" if($class->logging());
				push(@savedOutput, "$line\n");
			}
		} else {
			print LOG "\t  ", join("\n\t  ", @output), "\n" if($class->logging());
			push(@savedOutput,"\t  " . join("\n\t  ", @output) . "\n");
		}

		$object->setNumErrors($numErrors+$foundError);

		printf LOG "    end: %15s %25s  [%s]\n", $productAndCustomer, $host, $description if($class->logging());
		push(@savedOutput,"    end: %15s %25s  [%s]\n" . $productAndCustomer . $host . $description);
		print LOG '-' x 72, "\n" if($class->logging());
		close(LOG);

		$DATE_FORMAT = "%H:%M:%S";
		$formattedDate = POSIX::strftime($DATE_FORMAT, localtime);

		printf "    end [%8s]: %15s %25s  [%s]\n", $formattedDate, $productAndCustomer, $host, $description unless $class->quiet();

		$object->setOutput(@savedOutput);

		last if ($num && $finished >= $num);
	}

	return($exitStatus);
}

#
# Instance methods:
#
sub logDir {
	my $self = shift;

	my $productName = $self->productName();
	my $customer = $self->customer();
	my $service = $self->service();
	my $action = $self->action();
	my $startTime = $self->timeStarted();

	my $class = ref($self);

	return($class->logDirForProductServiceCustomerActionAndTime($productName, $service, $customer, $action, $startTime));
}

sub launchCommandsInBackgroundWithHostLoadbalancing {
	my $self = shift;
	my $optionsHashRef = shift;

	$self->_launchCommandsInBackgroundAux ( $optionsHashRef );
}

sub launchCommandsInBackground {
	my $self = shift;

    return $self->_launchCommandsInBackgroundAux ({
		action       => shift,
		user         => shift,
		host         => shift,
		logName      => shift,
		password     => shift,
		master       => shift,
		description  => shift,
		commandArray => [@_],
	});
}

sub _launchCommandsInBackgroundAux {
	my $self = shift;
	my $optionsHashRef = shift;

	my $action = $optionsHashRef->{'action'};
	my $user =   $optionsHashRef->{'user'};
	my $host =   $optionsHashRef->{'host'};
	my $logName = $optionsHashRef->{'logName'};
	my $password = $optionsHashRef->{'password'};
	my $master = $optionsHashRef->{'master'};
	my $description = $optionsHashRef->{'description'};
	my @commands = @{$optionsHashRef->{'commandArray'}};

	my $class = ref($self);
	if ($loadBalancingEnabled) {
	    $host = getLeastLoadedHost();

		# since we're picking the host, let the logname reflect that
		unless ($logName) {
			$logName = $host;
		}

		# for now, only HOST token is recognized
		if ($optionsHashRef->{'replaceTokensInCommand'}) {
			map { s/\*HOST\*/$host/g } @commands;
		}
	}
	my $commandString = join("; ", @commands);

	#
	# save away all the input, some of it is needed later
	#
	$self->setAction($action);
	$self->setUser($user);
	$self->setHost($host);
	$self->setLogName($logName);
	$self->setDescription($description);
	$self->setCommands($commandString);

	my $productName = $self->productName();
	my $customer = $self->customer();
	my $testing = $self->testing();

	my $DATE_FORMAT = "%H:%M:%S";
	my $formattedDate = POSIX::strftime($DATE_FORMAT, localtime);

	#
	# sub that should be launched in the child process
	#
	my $coderef = sub {
		my @output;
		$main::quiet = 1;

		my $productAndCustomer = $productName;
		$productAndCustomer .= "($customer)"  if ($customer);

		printf "  begin [%8s]: %15s %25s  [%s]\n", $formattedDate, $productAndCustomer, $host, $description unless $class->quiet();

		my $exitValue = 0;

		for my $cmd (@commands) {

			my $ssh = ariba::Ops::DeploymentHelper::sshWhenNeeded($user, $host, $self->service());

			if ($host) {

				if ($ssh) {
					$cmd = "$ssh '$cmd'";
				}
				else {
					print "$user $host SSH NOT NEEDED!\n";
				}
			}

			my @cmdOutput;

			push(@output, "$cmd");
			push(@output, " started at: ". scalar(localtime(time)));
			my $ret = 1;

			unless ($testing) {
				if ($ssh) {
					close(STDIN);
					close(STDOUT);
					close(STDERR);

					open(STDOUT, '/dev/null');
					open(STDERR, '/dev/null');

					# this returns 1 for success and 0 for failure
					$ret = executeRemoteCommand(
							$cmd,
							$password,
							0,
							$master,
							undef,
							\@cmdOutput
							) 
				} else {
					my $useLocalExpectCover = ariba::rc::Globals::isPersonalService($self->service());
					my $exitStatus;
					$ret = executeLocalCommand($cmd, 0, \@cmdOutput, $master, $useLocalExpectCover, \$exitStatus);

					# $ret is just an indication of success/failure
					# and not the true exit status; $? will be
					# checked in the run() method of
					# ariba::Ops::SharedMemoryChild.
					$? = $exitStatus * 256;
				}
			}


			# exit values are 0 for success and non-zero for failure
			$exitValue = !$ret || $exitValue;

			if ($exitValue) { # this is actually an error condition

				# if there was a problem returned, make sure $? is set correctly
				# ariba::Ops::SharedMemoryChild::waitForChildren will
				# check $?, and if ssh itself fails due to connection
				# error then $? can still remain at 0.
				# Retain $? if it is already set as it is the exit code from expect

				$? = $exitValue * 256 unless ($?);
			}

			push(@output, @cmdOutput);
			push(@output, "finished at: ". scalar(localtime(time)));

			if ($ssh && $self->skipOnSshFailure() && scalar(@commands) > 1 && 
				join("\n", @cmdOutput) =~ /^ERROR .*ariba::rc::Utils::sshCover/) {
				push(@output, "Skipping remaining commands (if any) because of the above ssh error");
				last;
			}
		}

		$main::quiet = 0;
		return (@output);
	};

	#
	# create and launch the child process, store the output in shared mem
	#
	my $size = 3 * 1024 * 1024; #allow up to 3MB of output
	my $child = ariba::Ops::SharedMemoryChild->new($coderef, $size);
	$child->setTag($self->instance());
	$child->run();

	$class->incrementParallelProcessCount();
	if ($loadBalancingEnabled) {	
        $class->incrementProcessesPerHosts($host);
	}
	#
	# If we reached the limit of number of maximum process allowed, wait
	# for one to finish, before allowing the next one to be launched
	#
	if ($class->curParallelProcesses() >= $class->maxParallelProcesses()) {
		$class->waitForBackgroundCommands(1);
	}
}

1;
