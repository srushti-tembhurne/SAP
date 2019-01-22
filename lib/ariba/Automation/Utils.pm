package ariba::Automation::Utils;

use warnings;
use strict;

use File::Basename;
use File::Path;

use ariba::Ops::Constants;
use ariba::rc::Globals;
use ariba::rc::BuildDef;
use Ariba::P4;

use ariba::Automation::Constants;
use ariba::Automation::Utils::HTML;
use ariba::Automation::Utils::Runtime;
use ariba::Ops::Logger;

#
# Central repository for utility functions shared by various modules
# that don't seem to fit anywhere else
#

my $sleepTimeInMinutes = ariba::Automation::Constants::sleepTimeForNewRCBuildInMinutes();
my $logger = ariba::Ops::Logger->logger();

sub buildRootDir {
	my $class = shift;

	my $user = $ENV{'USER'};

	my $root = ariba::Ops::Constants::robotRootDir() . "/" .
				ariba::rc::Globals::personalServicePrefix() . $user;

	return $root;
}

sub setupLocalBuildEnvForProductAndBranch {
	my $class = shift;
	my $productName = shift;
	my $branchName = shift;

	my $user = $ENV{'USER'};

	my $root = $class->buildRootDir();

	my $archiveBuildRoot = ariba::Ops::Constants::robotRootDir() . "/" .  ariba::rc::Globals::personalServicePrefix() . "$user/archive/builds/$productName";
	ariba::rc::Globals::setArchiveBuildOverrideForProductName($productName, $archiveBuildRoot);

	my $previousClient;

	if ($branchName) {
		my $version = ariba::rc::Globals::versionNumberFromBranchName($branchName);
		my $srcRoot = "$root/src/$version";
		$ENV{'ARIBA_SOURCE_ROOT'} = $srcRoot;
		$ENV{'ARIBA_BUILD_ROOT'}  = "$root/objs/$version";
		$ENV{'ARIBA_LATEST_CHANGE_FILE'} = "$root/$version-LATEST_CHANGE.txt";

		my $p4ClientName = join('_', "robot", $user, $productName, $version);
		my $views = [ "//ariba/..." ];
		my $comment = "robot build of $productName ($version)";
		Ariba::P4::createClient($p4ClientName,$views,$srcRoot,$comment);
		$previousClient = Ariba::P4::switchClient($p4ClientName);
	} else {
		$previousClient = $ENV{'P4CLIENT'};
	}

	return $previousClient;
}

sub teardownLocalBuildEnvForProductAndBranch {
	my $class = shift;
	my $productName = shift;
	my $branch = shift;
	my $previousP4Client = shift;

	delete $ENV{'ARIBA_SOURCE_ROOT'};
	delete $ENV{'ARIBA_BUILD_ROOT'};
	delete $ENV{'ARIBA_LATEST_CHANGE_FILE'};

	ariba::rc::Globals::setArchiveBuildOverrideForProductName($productName, undef);

	if ($previousP4Client) {
		Ariba::P4::switchClient($previousP4Client);
	}
}

sub opsToolsRootDir  {
	my $class = shift;

	return ariba::Ops::Constants->personalServiceGlobalCacheDir() . "/usr/local";
}

sub service {
	my $class = shift;

	return ariba::rc::Globals::personalServicePrefix() . $ENV{'USER'};
}

sub isIdcRobotHost {
	my $hostname = shift;

	if ($hostname =~ /^idc/i) {
		return 1;
	}

	return;
}

sub buildNameFromSymlink {
	my $link = shift;

	my $logger = ariba::Ops::Logger->logger();

	unless ( -l $link ) {
		$logger->info("'$link' does not exist or is not a symlink.  Waiting $sleepTimeInMinutes minutes to check again.");

		sleep $sleepTimeInMinutes * 60;

		unless ( -l $link ) {
			$logger->error("'$link' does not exist after a second check.");
			return;
		}
	}

	my $buildName = basename(readlink($link));

	unless ( $buildName ) {
		$logger->error("Could not get deference archive build synlink to get buildname");
		return;
	}

	return $buildName;
}

# gets changes between 2 revisions given last change number,
# product and branch.
sub getChangesForProduct {
	my ($lastChange, $product, $branch, $additionalPerforcePath) = @_;
    my $configDir = ariba::rc::BuildDef::prodConfigDir($product, $branch);

    my $ctxt = "$configDir/components.txt";
    my @monitor = ($ctxt);

    # Include the build config dir as well
    push (@monitor,$configDir);

    my @changesFullList = getChanges($lastChange, "head", \@monitor,$additionalPerforcePath);

    # Eliminate changes by rc user and changes on certain files
    my @changes = eliminateChanges (@changesFullList);

    my $latestChange = ( sort { $b <=> $a } ( @changes ))[0] ;
    return $latestChange;
}

# gets changes between 2 revisions given last change number,
# product and maven top level pom.  The pom file is read to get the list of
# depot paths to inspect for changes.
sub getChangesForMavenProduct {
    my ($lastChange, $mavenTLP) = @_;
    
    my @monitor = ($mavenTLP);
    
    $logger->info("reading paths from $mavenTLP since $lastChange");
    
    push(@monitor, readModulePathsFromPom($lastChange, "head", $mavenTLP));
    
    my @changesFullList = getChanges($lastChange, "head", \@monitor);
    
    # Eliminate changes by rc user and changes on certain files
    my @changes = eliminateChanges (@changesFullList);
    
    my $latestChange = ( sort { $b <=> $a } ( @changes ))[0] ;
    return $latestChange;

}

# get the changes between 2 revisions
# if the first revision ($fromChange) is not defined, return a list
# containing only 1 element: the last known change
sub getChanges {
    my ($fromChange, $toChange, $monitor, $additionalPerforcePath) = @_;
    if (! defined($toChange) || $toChange eq "head") {
        $toChange="#head";
    }
    if ($fromChange eq $toChange) {
        return ();
    }
    if (@$monitor == 0) {
        return ();
    }
    my @paths = getInterestingPaths($fromChange, $toChange, $monitor);
    if ($additionalPerforcePath && $additionalPerforcePath =~ m|//ariba/|){
       $additionalPerforcePath .= "/...#head";
       push(@paths,$additionalPerforcePath);

    }

    my $flag = ($fromChange == 0 ? "-m 1": "");
    my @listOfChanges = ();

    # we can't call p4 changes on a huge array of paths, we will reach
    # the limit of the command line size
    # instead, we break it up into 20 paths and call p4 changes on these
    # 20 paths and then we reloop
    while (@paths > 0) {
        my @tempArray = ();
        my $cpt = 0;
        while ($cpt < 20 && @paths >0) {
            push(@tempArray, pop(@paths));
            $cpt++;
        }
        my $fullPath = join(" ",@tempArray);
        my $command = "changes $flag $fullPath";
        my %out = Ariba::P4::p4s($command);
        if($out{error}) {
            $logger -> error("Error getting the changes: " .
                     join("",@{$out{error}}));
        }
        if (exists($out{info}) && @{$out{info}} > 0 ) {
            my @changes = @{$out{info}};
            foreach my $change (@changes) {
                chomp($change);
                $change =~ s/^Change\s+(\d+).*/$1/;
                if ($change > $fromChange) {
                    if (!grep($_ == $change, @listOfChanges)) {
                        push (@listOfChanges, $change);
                    }
                }
            }
        }
    }
    if ($fromChange == 0) {
        my $tempLatestChange = ( sort { $b <=> $a } ( @listOfChanges ))[0] ;
        return ($tempLatestChange);
    }
    else {
        return ( sort { $b <=> $a } ( @listOfChanges ));
    }
}



# if given a depotDir (//ariba/b/c), return the depotDir in a array context
# with #head: //ariba/b/c/...#head
# if given a //ariba/.../blabla.txt, going to assume that this file is a
# components.txt (a triplet (compName Label Path)) and will return an array
# containing all the entries from the componentx.txt
# $fromChange is for the perforce query optimization
sub getInterestingPaths ($$$) {
    my ($fromChange, $toChange, $paths) = @_;
    my @interestingPaths = ();
    my $range ;
    if ($fromChange == 0) {
        $range = "#head";
    }
    else {
        $range = "\@$fromChange,$toChange";
    }
    foreach my $path (@$paths) {
        if ($path =~ /.*\.txt$/) {
            push(@interestingPaths, getPathsFromFile($fromChange,$toChange,$path));
            # let's add the file itself so we know when it's updated
            push(@interestingPaths, $path.$range);
        }
        elsif ($path =~ m|//ariba/|) {
            # remove trailing ... if any
            $path =~ s/\.\.\.$//;
            # remove trailing / if any
            $path =~ s/\/$//;
            $path .= "/...$range";
            push(@interestingPaths, $path);
        }
        else {
            $logger->warning("Entry $path ignored: expecting an entry of form ".
                   "//ariba/b/c or //ariba/b/c/components.txt");
        }
    }
    return @interestingPaths;
}

# parse a pom file to get <path> elements containing pom.xml paths
# return an array containsing the paths with the label
sub readModulePathsFromPom {
    my ($fromChange, $toChange, $pom) = @_;
    my @interestingPaths = (); 
    my %output = Ariba::P4::p4s("print -q $pom");
    
    if ($output{error}) {
        print ("Problem getting $pom, ignoring this entry");
        foreach my $line (@{$output{error}}) {
            chomp($line);
            print($line);
        }
        return ();
    }
    
    my $depotPath = "";
    my $range;
    
    
    
    if  ($fromChange == 0) {
        $range = "#head";
    }
    else {
        $range = "\@$fromChange,$toChange";
    }
    
    foreach my $line (@{$output{text}}) {
        if ($line =~ /^\s*$/) {
            next;
        }
        $line = Ariba::Util::stripCommentAndTrim($line);
        
        if ($line =~ /<path>/) {
            $depotPath  = $line;
            $depotPath =~ s/<path>//;
            $depotPath =~ s/<\/path>//;
            
            
            if($depotPath =~ /.pom.xml/) {
                $depotPath =~ s/pom.xml/.../;
                $logger->debug("Adding interesting path $depotPath");
                push(@interestingPaths, $depotPath);
            }
            
        }
    }
  
    return @interestingPaths;

}




# parse a file in the components.txt's style
# return a array containing the paths and the label
sub getPathsFromFile (@) {
    my ($fromChange,$toChange,$path) = @_;
    my @interestingPaths = ();
    my $isSandbox = 0;
    if ($path =~ m|//ariba/sandbox/|) {
        $isSandbox = 1;
    }
    my $range;
    if  ($fromChange == 0) {
        $range = "#head";
    }
    else {
        $range = "\@$fromChange,$toChange";
    }
    my %output = Ariba::P4::p4s("print -q $path");
    if ($output{error}) {
        $logger->warning("Problem getting $path, ignoring this entry");
        foreach my $line (@{$output{error}}) {
            chomp($line);
            $logger->warning($line);
        }
        return ();
    }
    foreach my $line (@{$output{text}}) {
        if ($line =~ /^\s*$/) {
            next;
        }
        $line = Ariba::Util::stripCommentAndTrim($line);
        my ($name, $label, $location) = split(' ', $line, 3);
        next if (! $location);
        if ($location !~ m|^//ariba/| ||
            $location !~ m|/...$|) {
            $logger->warning("$path: Ignoring line $line");
        }
        else {
            if($label eq "latest") {
                $label = "$range";
                push(@interestingPaths, $location.$label);
            }
            else {
                if (!$isSandbox) {
                    $label = "$range";
                    push(@interestingPaths, $location.$label);
                }
                else {
                    # it's at label, so no changes
                    # if the label is updated in a sandbox (rebase), we would catch
                    # that event since we monitor the components.txt as well
                }
            }
        }
    }
    return @interestingPaths;
}

# CGI encoding of strings
sub cgi_encode
  {
  my $str = shift;
  $str =~ s/([^\w ])/sprintf("%%%02x", ord($1))/geo;
  $str =~ s/ /+/go;
  return $str;
  }

# Find out if this a sandbox robot
sub isSandboxRobot
{
	my $robot = shift;

	my $branch = $robot->targetBranchname();

	# If the global var is not defined, try the 'build' action
	if (!$branch)
	{
        	my ($buildAction) = grep { $_->type() eq 'build' } $robot->actionsOrder();
		$branch = $buildAction->branchName();
	}

	if (!$branch)
	{
		print("Unable to fetch the branch name. We can't say if this is a sandbox robot.\n");
		print("Considering this to be a mainline robot.\n");
		return 0;
	}

	return 1 if ($branch =~ /\/sandbox\//i);
	return 0;
}

# Maintain backward compatibility
# TODO: Change calling scripts to point at new module
sub form_select
  {
  return ariba::Automation::Utils::HTML::form_select (@_);
  }

# Maintain backward compatibility
# TODO: Change calling scripts to point at new module
sub parseRuntime
  {
  return ariba::Automation::Utils::Runtime::parseRuntime (@_);
  }

# Maintain backward compatibility
# TODO: Change calling scripts to point at new module
sub elapsedTime
  {
  return ariba::Automation::Utils::Runtime::elapsedTime (@_);
  }

sub eliminateChanges ()
{
  my @changes = @_;
  my @goodChanges;

  my @usersToBeEliminated = ("rc");
  my @filesToBeEliminated = (
		"BuildName",
		"ReleaseName"
			);

   foreach my $change (@changes)
   {
	my $changeInfo = Ariba::P4::getChangelistInfo($change);
        if ( grep (/$$changeInfo{"User"}/i,@usersToBeEliminated) )
	{
		$logger->info ("The change $change is not considered for robot kick-off as it is submitted by the user " . $$changeInfo{"User"});
		next;
	}

	# Look at files that need to be eliminated
	my @files = Ariba::P4::ChangelistFiles($change);
	my $skipThisChange = 1;
	foreach my $filePath (@files)
	{
		my $file = (split (/\//,$filePath))[-1];
		$file =~ /(.*)#/;
		$file = $1;

		if (! (grep(/$file/i,@filesToBeEliminated)) )
		{
			$skipThisChange = 0;
			last;
		}
	}
	if ($skipThisChange)
	{
		$logger->info ("The change $change is not considered for robot build kick-off as it edits build config files only");
		next;
	}

	# If we are here, then this change needs to be considered for build kick-off
	push (@goodChanges, $change);
   }

   return @goodChanges;
}

sub deleteGlobalState {
	my $stateDir = shift;
	my $configDir = shift;
	my $robotName = shift;

	my $deletePath = "$stateDir/$robotName.GlobalState";
	my $configDeletePath = "$configDir/$robotName";

	if (-e $deletePath) {
		unlink ($deletePath) or warn "Could not delete $deletePath \n. $!" ;
	}

	if (-d $configDeletePath) {
		rmtree ($configDeletePath) or warn "Could not delete $configDeletePath \n. $!";
	}

}

1;
