package ariba::Ops::Startup::Common;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/Common.pm#142 $
# Common functions for startup.

use strict;

# Standard base or CPAN modules:
use FindBin;
use File::Basename;
use File::Path;
use File::Slurp;
use Expect;
use POSIX qw(setsid);

use Carp;

use dmail::LockLib;

# Ariba specific modules:
use ariba::rc::Utils;
use ariba::rc::Globals;
use ariba::rc::Passwords;
use ariba::Ops::Constants;
use ariba::Ops::ProcessTable;
use ariba::Ops::Utils;
use ariba::Ops::NetworkUtils;
use ariba::Ops::Machine;
use ariba::Ops::ServiceController;
use ariba::Ops::DatacenterController;

my $mkdir = ariba::rc::Utils::mkdirCmd();
my $chown = ariba::rc::Utils::chownCmd();
my $chmod = ariba::rc::Utils::chmodCmd();
my $rm = ariba::rc::Utils::rmCmd();

my $taggedLogs = 0;
my $archivedLogs = 0;
my $myUid; # global so it can stay cached

sub realOrFakeSudoCmd {
    my $SUDO = ariba::rc::Globals::isPersonalService($ENV{'ARIBA_SERVICE'}) ? '' : ariba::rc::Utils::sudoCmd();
    return $SUDO;
}

sub startShell
{
    print "You now have a shell ($ENV{'SHELL'}) with right env",
        " for launching a webobjects/weblogic app. Refer to an\n",
        "existing keepRunning log to get the proper",
        " command line args to the app.\n";

    exec($ENV{'SHELL'});
}

sub createDbLinkToMonitoring
{
    my ($product,$linkName) = @_;

    my $mon = ariba::rc::InstalledProduct->new("mon", $product->service());

    my $to = ariba::Ops::DBConnection->connectionsForProductOfDBType(
        $mon, ariba::Ops::DBConnection->typeMain()
    );

    for my $type (ariba::Ops::DBConnection->typeMain(), ariba::Ops::DBConnection->typeReporting()) {

        my $from = ariba::Ops::DBConnection->connectionsForProductOfDBType($product, $type);

        if ($from && $from->sid() && $from->sid() ne 'dummy') {
            ariba::Ops::Startup::DB::createLinkFromTo($linkName,$from,$to);
        }
    }
}

# Create a ".forward" file, to pass incoming mail to filter code.
sub createDotForward 
{
    my $product = shift;

    my $productName = $product->name();
    my $currentBinDir = ariba::rc::Globals::rootDir($productName, $product->service());
    my $currentConfigDir = ariba::rc::Globals::rootDir($productName, $product->service());
    my $forward    = "$ENV{HOME}/.forward" ;

    if ($productName && $productName eq 's4') {
        $forward .= "+$productName" if $productName;
    }

    print "Creating file $forward\n";
    open(FW, "> $forward") || die "Error: Could not create file $forward, $!\n";

    if ($productName && $productName eq 's4') {
        my $logdir = "$ENV{HOME}/$productName/logs";
        mkdirRecursively($logdir) unless -d $logdir;
        print FW "\"| $currentBinDir/bin/mailcode/mail-filter -f $currentConfigDir/config/$productName.filter -logdir $logdir\"\n";
    } elsif ($productName && $productName eq 's2') {
        my $logdir = "$ENV{HOME}/logs";
        mkdirRecursively($logdir) unless -d $logdir;
        print FW "\"| $currentBinDir/bin/mailcode/mail-filter -f $currentConfigDir/.$productName-filter -logdir $logdir\"\n";
    } else {
        print FW "\"| $ENV{HOME}/bin/mailcode/mail-filter\"\n";
    }
    close(FW);
    chmod(0600, $forward) or die "Error: Can't change permissions on file $forward : $!\n";
}

# Setup symbolic links to standard filters & mh_profile stuff
sub createSymLinksForBounceProcessor 
{
    my $productName = shift;

    # bounce processor is special and needs symlinks links in $HOME
    # not under the product dir (svcdev/an for ex.) in consolidated
    # accounts.
    my $dest = $ENV{'HOME'};

    #
    # mailcode can be in one of the following two locations (AN vs
    # buyer)
    #
    my @possibleMailcodeDirs = (
            "$main::INSTALLDIR/bounce-processor/bin/mailcode",
            "$main::INSTALLDIR/3rdParty/bounce-processor/bin/mailcode",
            "$main::INSTALLDIR/base/3rdParty/bounce-processor/bin/mailcode",
            );
    for my $mailcodeDir (@possibleMailcodeDirs) {
        if (-d $mailcodeDir) {

            my $destDir = "$main::INSTALLDIR/bin";
            my $mailcodeDest = "$destDir/mailcode";
            my $oldMode = (stat($destDir))[2];
            chmod(0755, $destDir);

            unlink $mailcodeDest if (-e $mailcodeDest);
            unless (symlink($mailcodeDir, $mailcodeDest)) {
                die __PACKAGE__."::createSymLinksForBounceProcessor: can't create symlink $mailcodeDest to $mailcodeDir: $!";
            }

            chmod($oldMode, $destDir);
            last;
        }
    }

    #
    # create other symlinks needed for mail-filter to work
    #
    #FIXME 
    #   "config/buyer.filter"                 => ".filter",
    # should get changed to
    #   "config/buyer.filter"                 => ".buyer-filter",
    # once we have the new mail filter mechanism in place for buyer
    my %files = (
        "bounce-processor/fax/an-.filter"     => ".filter",
        "config/buyer.filter"                 => ".filter",
        "config/s4.filter"                 => ".s4-filter",
        "config/s2.filter"                 => ".s2-filter",
        "bounce-processor/fax/an-.mh_profile" => ".mh_profile",
        "bounce-processor/fax"                => "fax",
        "bounce-processor/email-processor"    => "email-processor",
        "bounce-processor/setuid"             => "setuid",
        "bin"                             => "bin",
    );

    #FIXME remove after buyer is using .forward+buyer
    # HOA-162513: only create bin symlink if it's buyer
    delete($files{"bin"}) if $productName ne "buyer";

    #HOA-75142 - Adding collabmail-processor for AN bounce processor in devlab

    my $host = ariba::Ops::NetworkUtils::hostname();
    my $currentMachine = ariba::Ops::Machine->new($host);
    my $datacenter = $currentMachine->datacenter();

    if (lc($productName) eq 'an') {  
       $files{'bounce-processor/collabmail-processor'} = 'collabmail-processor';
    }

    for my $srcFile (keys(%files)) {
        my $destFile = $files{$srcFile};
        my $srcPath = "$main::INSTALLDIR/$srcFile";

        if (-e $srcPath) {
            rmtree("$dest/$destFile");
            symlink($srcPath, "$dest/$destFile");
        }
    }
}

sub fixArchiveLogDirPermissions {
    my $base = ariba::Ops::Constants->archiveLogBaseDir();
    my $service = shift;
    my $product = shift;
    my $customer = shift;

    my $SUDO = realOrFakeSudoCmd();

    my @files;

    push(@files, "$base/$service/$product") if ( -e "$base/$service/$product" );
    push(@files, "$base/$service") if ( -e "$base/$service" );
    push(@files, "$base") if ( -e "$base" );

    if (scalar(@files)){

        my $tgtFiles = join(' ', @files);

        my $cmd = "$SUDO chmod -f 1777 $tgtFiles";
        my $user = $ENV{'USER'} || $ENV{'LOGNAME'};
        my $password = ariba::rc::Passwords::lookup($user);
        my @output;
        unless ( ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1, undef, $password) ) {
            print "Running $cmd failed:\n", join("\t\n", @output), "\n";
            return 0;
        }

    }

    return 1;
}

# monitoring and webserver products run a compiled apache component from within the product's build
# This apache component must match the OS on which it's being run.  All apache/OS versions are deployed
# with each product.  Detect the OS on the install host and set a soft link to point to the correct
# apache package.
sub createApacheSymLinks {
    my $self = shift;

    # hard coding sucks.  I did some google searching to find a different way of determining the OS
    # but couldn't find anything better.
    my $osInfo = read_file( '/etc/redhat-release' );
    (my $osVersion) = ( $osInfo =~ /release\s+(\d+)\.\d+/ );

    my $installDir = $self->installDir();
 
    my @dirs = ( "$installDir/bin/linux", "$installDir/lib/linux", "$installDir/lib/modules/linux" );

    foreach my $dir (@dirs) {
        my $actualName = "${dir}$osVersion"; 
        unless ( -d $actualName ) {
            die "I think the OS version is $osVersion and thus I need $actualName.  This dir does not exist.\n";
        }

        ariba::Ops::Startup::Common::makeSymlink( $actualName, $dir );
    }
}

sub archiveKeepRunningLogs 
{
    my $service = shift;
    my $prodname = shift;
    my $customer = shift;
    my $specificAppsRef = shift;

    return if ($archivedLogs || $taggedLogs);

    $archivedLogs = 1;

    my $archiveLogdir = ariba::Ops::Constants::archiveLogDir(
        $service, $prodname, $customer
    );
    fixArchiveLogDirPermissions($service, $prodname, $customer);
    unless ( -d $archiveLogdir ) {
        mkdirRecursively($archiveLogdir);
    }
    fixArchiveLogDirPermissions($service, $prodname, $customer);

    my $keepRunningLogsDir = "$ENV{'LOGSDIR'}";

    return unless (-d $keepRunningLogsDir);

    
    my $symLinkArchived = $keepRunningLogsDir . '/archivedLogs';
    ariba::Ops::Utils::updateSymlink($archiveLogdir, $symLinkArchived);
    
    #
    # find all the files that need to be archived
    #
    my @filesToArchive;
    if ($specificAppsRef && @$specificAppsRef) {
        for my $specificApp (@$specificAppsRef) {
            push(@filesToArchive, "keepRunning-$specificApp*");
        }
    } else {
        push(@filesToArchive, "keepRunning*");
    }

    for my $fileToArchive (@filesToArchive) {
        my $cmd = "$main::INSTALLDIR/bin/clean-old-files-from-dir -d -1 -z -a $archiveLogdir \'$keepRunningLogsDir/$fileToArchive\.\\d+\' \'$keepRunningLogsDir/${fileToArchive}DEAD\' \'$keepRunningLogsDir/${fileToArchive}EXIT\'";

        print "Archiving old keepRunning logs...\n";
        print "$cmd\n";
        r("$cmd");
    }
}

sub setupKeeprunningLogDirs {
    my $service = shift;
    my $prodname = shift;
    my $customer = shift;
    my $keepRunningLogsDir = "$ENV{'LOGSDIR'}";

    return if ($taggedLogs);
    return unless (-d $keepRunningLogsDir);

    $taggedLogs = 1;

    # Create archive log dir
    my $archiveLogdir = ariba::Ops::Constants::archiveLogDir($service, $prodname, $customer);
    fixArchiveLogDirPermissions($service, $prodname, $customer);
    unless ( -d $archiveLogdir ) {
        mkdirRecursively($archiveLogdir);
        fixArchiveLogDirPermissions($service, $prodname, $customer);
    }

    # Symlink to archive log dir in kr log dir.
    my $symLinkArchived = $keepRunningLogsDir . '/archivedLogs';
    ariba::Ops::Utils::updateSymlink($archiveLogdir, $symLinkArchived);
}

sub removeJunkFromTempDir 
{
    my $temp    = tmpdir();

    # Safety net if $TEMP is not set
    return unless defined $temp;

    r("$main::INSTALLDIR/bin/clean-old-files-from-dir $temp/ariba");
}

sub daemonControl
{
    my $start    = shift;
    my $prog     = shift;
    my $pid_file = shift;
    my $password = shift || 0;

    if ($start) {
        if ($password) {
            my $md5salt = ariba::rc::Passwords::lookup("md5salt");
            open (CMD,"| $ENV{'ARIBA_DEPLOY_ROOT'}/$prog -readMasterPassword") || die $!;
            select(CMD);
            $| = 1;
            print CMD "$password\n";
            print CMD "$md5salt\n";
            close CMD;
        } else {
            r("$ENV{'ARIBA_DEPLOY_ROOT'}/$prog");
        }

    } elsif ( -f $pid_file ) {
        open(PID, $pid_file) || warn "Can't open $pid_file: $!\n";
        my $pid = <PID>;
        close(PID);

        kill 9, $pid;
    }
}

sub loadInstalledProducts
{
    my $service = shift;
    return ariba::rc::InstalledProduct->installedProductsList($service);
}

sub loadInstalledSharedServiceProducts
{
    my $service = shift;
    return ariba::rc::InstalledSharedServiceProduct->installedProductsList($service);
}

sub loadInstalledASPProducts
{
    my $service = shift;
    return ariba::rc::InstalledASPProduct->installedProductsList($service);
}

sub setupEnvironment
{
    my($ldLibrary, $pathComponents, $classesRoots, $excludeList) = @_;
    my($sep);

    print '-' x 72, "\n" unless $main::quiet;
    my @paths;
    for my $pathComponent (@$pathComponents) {
        if (-d "$pathComponent") {
            push(@paths, $pathComponent);
        }
    }

    $sep = ':';
    $ENV{'TMPDIR'}="/tmp";
    push(@paths, qw(/bin /usr/bin /usr/ucb /usr/local/bin /usr/sbin /usr/local/sbin));

    my $path = join($sep, @paths);

    $ENV{'PATH'} = $path;

    # 
    #  set JDKROOT from JAVA_HOME, this is for any sub-programs
    #  apps may spawn that are not run through our startup code;
    #  The gnu and runjava utilities will choose some default jdk
    #  unless JDKROOT is set
    $ENV{'JDKROOT'} = $ENV{'JAVA_HOME'} if $ENV{'JAVA_HOME'};

    my $envName = sharedLibEnvName();

    $ENV{$envName} = join($sep, @$ldLibrary);

    unless ($main::quiet) {
        print "PATH=",$ENV{'PATH'},"\n";
        print "$envName=",$ENV{$envName},"\n";
        print "JAVA_HOME=",$ENV{'JAVA_HOME'},"\n";
        print "JDKROOT=",$ENV{'JDKROOT'},"\n";
    }


    ## These files contain specific classpaths that need to be processed
    my ( $classpathFile, $platformClasspathFile );

    if ( $ENV{'INSTR_MODE'} )
    {
        $classpathFile         = "$main::INSTALLDIR/instr_classes/classpath.txt";
        $platformClasspathFile = "$main::INSTALLDIR/instr_classes/classpath-platform.txt";
    } else {
        $classpathFile         = "$main::INSTALLDIR/classes/classpath.txt";
        $platformClasspathFile = "$main::INSTALLDIR/classes/classpath-platform.txt";
    }

    my @fullzips = ();

    if ( -e "$platformClasspathFile" ){
        @fullzips = cleanClasspath( \@fullzips,
                                     $classpathFile,
                                     $platformClasspathFile,
                                     $classesRoots
                                 );
    } else {
        $ENV{'CLASSPATH'}  = join($sep, @$classesRoots);
        $ENV{'CLASSPATH'} .= "$sep$ENV{'CLASSPATH'}$sep";

        for my $classesRoot (@$classesRoots) {

            opendir(DIR,$classesRoot) || next;
            my @zips = grep(/(zip)|(jar)$/o, readdir(DIR));
            close(DIR);

            # HACK! TODO: need xerces.jar before parser.jar in
            # classpath
            # HACK#2!!  Switched back, need jaxp-1.1.jar before
            # xmlparserv2.jar, and xerces.jar is gone now.
            #for my $zip (reverse(@zips)){
            for my $zip (@zips) {
                if (defined($excludeList)) {

                    if (!exists $excludeList->{$zip}) {
                        push(@fullzips,"$classesRoot/$zip");
                    }
                    else {
                            print "Excluding $zip from classpath\n" unless $main::quiet;
                    }

                } else {
                    push(@fullzips,"$classesRoot/$zip");
                }
            }
        }
    }

    $ENV{'CLASSPATH'} .= join($sep, @fullzips);

    unless ($main::quiet) {
        print "CLASSPATH=",$ENV{'CLASSPATH'},"\n";
        print "TEMP=",$ENV{'TEMP'},"\n";
        print '-' x 72, "\n";;
    }
}

##
## Function: cleanClasspath: TMID: 131264.  Classpaths need to be sorted so platform specific classes
##   get loaded before app specific classes which get loaded before "other" classes (other
##   being things not in the platform/app specific lists but still need to be added.
##
## Arguments: Array of paths,
##            classpath.txt filename,
##            classpath-platform.txt filename
##
## Returns: Array of paths, cleaned and ordered correctly
##
sub cleanClasspath{
    my $classArray     = shift;
    my $classpathFile  = shift;
    my $platformCPFile = shift;
    my $classesRoots   = shift;

    my @classpathFileContents;
    if ( -e $classpathFile ){
        open my $IN, '<', $classpathFile or croak "Could not open '$classpathFile' for read: $!\n";
        @classpathFileContents = <$IN>; ## Slurp contents
        close $classpathFile;
        chomp @classpathFileContents;
    } else {
        ## I want to print a warning that we didn't find the file but it
        ## causes c-d to think it's an error
#        print "'$classpathFile' not found, skipping ...\n";
    }

    open my $IN, '<', $platformCPFile or croak "Could not open '$platformCPFile' for read: $!\n";
    my @platformCPFileContents = <$IN>; ## Slurp contents
    close $platformCPFile;
    chomp @platformCPFileContents;

    ## Process @classArray:
    my %pathForFile;
    my @cpOut;
    my %seen;

    PATH:
    foreach my $path ( @{ $classArray } ){
        chomp $path;
        my @line = split( /\//, $path );
        next PATH unless $line[ -1 ] =~ m/(?:jar|zip)$/;
        $pathForFile{ $line[ -1 ] } = $path;
    }

    ## Process @platformCPFileContents first
    ## processArr returns nothing, all changes made are by side-effect
    if ( -e $platformCPFile ){
        processArr( \@platformCPFileContents, \@cpOut, \%seen, \%pathForFile );
    }

    ## Next process @classpathFileContents
    if ( -e $classpathFile ){
        processArr( \@classpathFileContents, \@cpOut, \%seen, \%pathForFile );
    }

    ## Note: This chunk of code is copied from setupEnvironment() and mildly
    ## tweaked to filter out things already added to the CLASSPATH.  If the
    ## code I swiped this from changes, you'll need to change this as well.
    ##
    for my $classesRoot (@$classesRoots) {

        opendir(DIR,$classesRoot) || next;
        my @zips = grep(/(zip)|(jar)$/o, readdir(DIR));
        close(DIR);

        for my $zip (sort @zips) {
            #print "PROCESSING: $zip\n";

            if ( $seen{ $zip } ){ ## We've seen this file
                #print "ignoring: '$zip'\n";
            } else {
                push(@cpOut,"$classesRoot/$zip");
                #print "adding  : '$zip'\n"
            }
        }
    }
    ## End copied code

    return @cpOut;
}

##
## Function: processArr: TMID: 131264.  Helper for cleanClasspath()
##
## Note: This function relies entirely on side-effect
##
## Arguments: Ref to array of classpath
##            Ref to output array
##            Ref to "seen" hash
##            Ref to hash of file->path (created by cleanClasspath()
##
## Returns: Nothing, all changes are side-effects
##
sub processArr{
    my $arr         = shift;
    my $arrOut      = shift;
    my $seen        = shift;
    my $pathForFile = shift;

    LINE:
    foreach my $line ( @{ $arr } ){
        chomp $line;
        if ( $line =~ m/^#/ || $line =~ m/^\s*$/ ){
            next LINE;
        }
        my @tmp = split /\//, $line;
        my $fname = $tmp[ -1 ]; ## last element

        if ( $seen->{ $fname } ){
            next LINE;
        }

        $seen->{ $fname } = 1;

        ## Need to prepend $main::INSTALLDIR to these ...
        push @{ $arrOut }, "$main::INSTALLDIR/$line";
        if ( exists $pathForFile->{ $fname } && defined $pathForFile->{ $fname } ){
            delete $pathForFile->{ $fname };
        }
    }
}

sub runKeepRunningCommand
{
    my ($cmd, $masterPassword, $woVersion) = @_;

    my $pid;
    my @responses;

    my $launchCmd = $cmd;

    if (defined($masterPassword)) {
        push(@responses, $masterPassword);
        push(@responses, ariba::rc::Passwords::lookup('md5salt'));

        #
        # WO < 5.0 could take -readMasterPassword as command line
        # arg, but for pure java apps it needs to be passed in
        # using system property (-D)
        #
        my $additionalArg = '-readMasterPassword YES';
        if ($woVersion && $woVersion >= 5.0) {
            $additionalArg = '-DreadMasterPassword=YES';
        }

        # Do not set -readMasterPassword for personal_services
        $additionalArg = '' if (ariba::rc::Globals::isPersonalService($ENV{'ARIBA_SERVICE'}));

        $launchCmd = "$cmd -km - $additionalArg";
    }

    launchCommandFeedResponses($launchCmd, @responses);
}

sub launchCommandFeedResponses {
    
    my $cmd = shift;
    my @responses = @_;

    print "Running $cmd\n" unless $main::quiet;
    return if ($main::testing);

    #
    # if we need to feed something to the command we are launching
    # fork a process and have the child process feed in the
    # reponses to the launched command (over stdin).
    #
    # we also dissociate the child from the terminal to prevent the
    # launched command from dumping all over the terminal and that
    # actually causes problems with ssh
    #
    unless (my $pid=fork) { # child
        open STDIN, '/dev/null';
        open STDOUT, '>/dev/null';
        setsid();
        open STDERR, '>&STDOUT';
        open(CMD, "| $cmd") || die "ERROR: failed to launch [$cmd], $!";

        select(CMD);
        $| = 1;

        #
        # feed the command everything we need to feed it on
        # stdin.
        #
        for my $response (@responses) {
            print CMD "$response\n";
        }

        #close(CMD); # don't do this, this will cause this process
                     # to hang until child has finished, which is
                     # never in our case.
        exit(0);
    }
}

sub runCommandAndFeedMasterPassword {
    my $command = shift;
    my $masterPassword = shift;

    if ($main::testing) {
        print "$command\n";
        return 1;
    }

    open(CMD, "| $command") || do {
            print "ERROR: failed to launch [$command], $!\n";
            return 0;
    };
    print CMD "$masterPassword\n";
    close(CMD) || do {
        $! ? print "ERROR: [$command] failed, $!\n" :
             print "ERROR: [$command] exited with status [$?]\n";
        return 0;
    };

    return 1;
}

sub symlinkAdditionalLogDir 
{
    my $additionalLogDir = shift;
    my $linkName = shift;
    my $service = shift;
    my $product = shift;
    my $customer = shift;
    my $archiveDir = ariba::Ops::Constants::archiveLogDir(
        $service, $product, $customer
    );

    return if $main::testing;

    $linkName = $archiveDir . "/" . $linkName;

    # update the symlink as neccesary...
    ariba::Ops::Utils::updateSymlink($additionalLogDir, $linkName);
}

sub tmpdir 
{
    $ENV{'TEMP'} = $ENV{'TEMP'} || "/tmp";

    return $ENV{'TEMP'};
}

sub makeSharedFileSystemDir
{
    my $dir = shift;

    if ( defined $dir && $dir !~ /NOT_SUPPORTED/ && ! -d $dir) {
        mkdirRecursively($dir);
    }
}

sub prepareHeapDumpDir
{
    my $me = shift;

    my $dumpRoot = $me->default('Ops.HeapDumpRoot');
    if (defined($dumpRoot)) {
        unless (-d $dumpRoot) {
            mkpath($dumpRoot, 0, 0770);
            # mkpath applies umask?
            chmod(0770,$dumpRoot);
        }
        my $dumpDir = $me->default('Ops.HeapDumpDir');
        if ($dumpDir) { 
            $dumpDir = $dumpRoot . "/" . $dumpDir; 
        unless (-d $dumpDir) {
            mkpath($dumpDir, 0, 0770);
            chmod(0770,$dumpDir);
        }
    }
}
}

sub expandJvmArguments
{
    my $me = shift;
    my $instanceName = shift;
    my $jvmArgs = shift;
    my $community = shift || 0;

    # expand some run-time tokens

    $jvmArgs =~ s/\@INSTANCENAME\@/$instanceName/g;
    $jvmArgs =~ s/\@COMMUNITY\@/C_$community/g;

    # The unique ID for a heap dump file used to be the startup time stamp of the 
    # KR perl process.  This has been replaced with the JAVAPID of the java VM.
    # This substitution takes place in keepRunning.  The next two lines can be
    # deleted once it is confirmed that UNIXTIME is no longer used anywhere.
    my $ct = time();
    $jvmArgs =~ s/\@UNIXTIME\@/$ct/g;

    if (my $hdroot = $me->default('Ops.HeapDumpRoot')) {
        my $hddir = $me->default('Ops.HeapDumpDir');
        if ( $hddir ) {
            $hdroot = $hdroot . "/" . $hddir;
        }
        $jvmArgs =~ s/\@HEAPDUMPROOT\@/$hdroot/g;
    }

    return $jvmArgs;
}

=item * expandRuntimeVars( $inputText, $runtimeVars )
Expands runtime variables in a text string based on a user provided list of runtime variables. 
Runtime variable is a text string tagged with @ signs, ex. @HADOOP-NAME@

Arguments: 
    $inputText      Text string to perform the value substituion on. Runtime vars should be tagged
                    as @RUNTIME-VARIABLE-KEY@
    $runtimeVars    Hash ref where the key is the search value and the value is the replacement value.
                    The search value should not have the @ signs.

Returns:            Copy of $inputText with the runtime variables replaced with $runtimeVars

=cut

sub expandRuntimeVars {
    my $inputText = shift; 
    my $runtimeVars = shift; 

    return $inputText unless (defined($inputText) && ref($runtimeVars) eq 'HASH');

    map { $inputText =~ s/\@$_\@/$runtimeVars->{$_}/g } keys %$runtimeVars;

    return $inputText;
}

# Run the passed-in startup hook. Don't check if the passed-in product plays
# the hook role, only check if the hook exists.
#
sub runNamedStartupHookNoCheck
{
    my ($me, $hook, $action) = @_;

    my $hookdir = "$main::INSTALLDIR/startup-hooks";
    my $hookfile = $hook;
    $hookfile = 'springboot' if ($hook =~ /^springboot-/);

    return unless -d $hookdir;
    return unless -f "$hookdir/$hookfile";

    my $prod = $me->name();
    my $service = $me->service();
    my $cluster = $me->currentCluster();
    my $customer = $me->customer() || '';

    print "Running $action on hook $hook\n" unless $main::quiet;
    r("$hookdir/$hookfile $prod $service $cluster $action \"$customer\" $hook");
}

# Run the hook if this host plays the role
# for the passed-in product.
sub runStartupHook {
    my ($me, $hook, $action) = @_;

    # The following block checks to make sure that if the hook is a real
    # role then the current host plays that role 
    #
    # Sometimes we have hooks that do not correspond to a real
    # role name (ex. anl-aes-integrated). For this just call
    # runStartupHookNoCheck()

    my $hostname = ariba::Ops::NetworkUtils::hostname();
    if ($me->servesRoleInCluster($hostname, $hook, $me->currentCluster()) ) {
        runNamedStartupHookNoCheck($me, $hook, $action);
    }
}

# Run all the hooks for the role(s) this host is playing
# for the passed-in product.
sub runStartupHooks {
    my ($me, $rolesLaunched, $action) = @_;

    for my $hook (keys %{$rolesLaunched}) {
        runStartupHook($me, $hook, $action);
    }
}

sub setAsInstalled 
{
    my($buildname) = shift;

    my %Files = (
        "docroot"        => "docroot",
        "config"         => "config",
        "lib"            => "lib",
        "bin"            => "bin",
        "base"           => "base",
        "testautomation" => "testautomation",
        "phing"          => "phing",
    );

    #
    # during rolling restart, protect against multiple race condition
    # among startup scripts
    #
    my $symlinkLockFile = $ENV{HOME}."/setasinstalled-$buildname";
    dmail::LockLib::forceQuiet();
    if (dmail::LockLib::requestlock($symlinkLockFile, 1,ariba::Ops::NetworkUtils::hostname())) {
        print "Info: setAsInstalled obtained lock $symlinkLockFile for symlink creation\n";
        createSymLinks($buildname, \%Files);
        dmail::LockLib::releaselock($symlinkLockFile);
    } else {
        print "Info: setAsInstalled skipping symlink creation, another startup has done this\n";
    }
    dmail::LockLib::removeQuiet();
}

sub createSymLinks 
{
    my($buildname, $files, $reverse) = @_;
    my($prodRoot) = dirname($main::INSTALLDIR);

    foreach my $dest (keys(%{$files})) {

        # change the order of from and to if reverse is defined
        # needed for things when a directory inside buildname is
        # a symlink to something outside the buildname tree
        # (eg. personalties
        my ($src, $destdir);

        if (defined $reverse && $reverse) {
            $src = "$prodRoot/$files->{$dest}";
            $dest =  "$main::INSTALLDIR/$dest";
        } else {
            $src =  "$main::INSTALLDIR/$files->{$dest}";
            $dest = "$prodRoot/$dest" ;
        }

        makeSymlink($src, $dest);
    }
}

sub makeSymlink {
    my $src = shift;
    my $dest = shift;

    # Make sure that the directory this goes into exists
    unless (-e $src) {
        print "Warning: symlink $src -> $dest skipped, src doesn't exist\n";
        return;
    }

    #
    # Check to make sure that a link pointing to right
    # location does not already exist
    #
    if (-l $dest) {
        my $pointsTo = readlink($dest);
        if ($pointsTo eq $src) {
            print "Info: $dest already points to $src. symlink creation skipped\n";
            return;
        }
    }

    #
    # prepare to create the symlink
    #
    my $destdir = dirname($dest);
    mkdirRecursively([$destdir]) unless -d $destdir;
    unlink ($dest) || rmtree($dest);

    print "Creating $dest -> $src\n" unless ($main::quiet);
    unless (symlink($src, $dest)) {
        #
        # Make sure no one else created this symlink
        # in parallel.
        #
        my $failureMsg = $!;
        unless (-e $dest) {
            die "Error: Could not create symlink to $src, $failureMsg\n";
        }
    }
}

sub createVersionedDocrootSymlinks
{
    my $prodRoot = dirname($main::INSTALLDIR);
    my %versions;
    my %spVersions;

    opendir(DIR, "$prodRoot") || die "Could not open $prodRoot, $!\n";
    my @dirs = grep(!/^\./, readdir(DIR));
    closedir(DIR);

    for my $subdir (sort @dirs) {
        next if (-l "$prodRoot/$subdir");
        next unless -d ("$prodRoot/$subdir/docroot" );

        my $buildInfoFile = "$prodRoot/$subdir/docroot/ariba/resource/en_US/strings/BuildInfo.csv";
        next unless -f $buildInfoFile;

        my $buildInfoVals = ariba::rc::Utils::hashFromFile($buildInfoFile, ",", "#");

        my $versionNumber = $buildInfoVals->{"build"};

        $versions{$versionNumber} = $subdir;
        my $spVersion = int($versionNumber / 100);
        if(!defined($spVersions{$spVersion}) or $spVersions{$spVersion} < $versionNumber) {
            $spVersions{$spVersion} = $versionNumber;
        }
    }

    my $destDir = "$main::INSTALLDIR/docroot";
    my $oldMode = (stat($destDir))[2];
    unless(chmod(0755, $destDir)) {
        print "Failed to chmod 0755 $destDir: $!\n";
        return;
    }
    foreach my $version (keys %versions) {
        my $src = "$prodRoot/" . $versions{$version} . "/docroot";
        my $dest = "$destDir/$version";

        makeSymlink($src, $dest);
    }

    foreach my $version (keys %spVersions) {
        my $src = "$prodRoot/" . $versions{$spVersions{$version}} . "/docroot";
        my $dest = "$destDir/$version";

        makeSymlink($src, $dest);
    }
    unless(chmod($oldMode, $destDir)) {
        print "Failed to chmod " . oct($oldMode) . " $destDir: $!\n";
    }
}

#
# This function is here instead of ariba::Ops::Startup::Monitoring.pm to make
# sure the non-monitoring products are protected from depending on
# monitoring-only libraries that ariba::Ops::Start::Monitoring.pm uses
#

sub createMonitoringArchiveDirFromService
{
    my $service = shift;

    my $monDir = ariba::Ops::Constants->monitorDir();
    my $user = $ENV{'USER'} || $ENV{'LOGNAME'};

    # If the passwords have been initialized from the master password use it,
    # otherwise try the cipher.  startup calls this function before passwords
    # are initialized but iostat-data doesn't have the master password to initialize
    my $password;
    
    if($user ne 'root') {
        if ( ariba::rc::Passwords::initialized() ) {
            $password = ariba::rc::Passwords::lookup($user);
        } else {
            my $cipherStore = ariba::rc::CipherStore->new($service);
            $password = $cipherStore->valueForName($user);
        }

        unless ($password) {
            Carp::carp "ERROR: Can't get password for '$user'";
            return 0;
        }
    }

    # mondir is someplace everyone can write to if we are a personal
    # service, but not if a real service;   this was done inside of Constants

    my $SUDO = realOrFakeSudoCmd();
    if($user eq 'root') {
        $SUDO = "";
    } else {
        $SUDO .= " ";
    }

    # create only if needed.
    unless (-d $monDir) {
        my $cmd = "${SUDO}$mkdir -p $monDir";
        my @output;
        unless ( ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1, undef, $password) ) {
            print "Running $cmd failed:\n", join("\t\n", @output), "\n";
            return 0;
        }
    }

    #
    # remove any dangling symlinks... dangling symlinks cause chown errors
    # below.
    #
    opendir(D, $monDir);
    while(my $file = readdir(D)) {
        next if($file =~ /^\.+$/);
        $file = "$monDir/$file";
        if( -l $file ) {
            my $linkto = readlink($file);
            unless($linkto =~ m|^/|) {
                $linkto = "$monDir/$linkto";
            }
            unless( -e $linkto ) {
                my $cmd = "${SUDO}$rm $file";
                my @output;
                unless ( ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1, undef, $password) ) {
                    print "Running $cmd failed:\n", join("\t\n", @output), "\n";
                    return 0;
                }
            }
        }   
    }
    closedir(D);

    my $cmd;
    if ($user =~ /^mon/) {
        # needed if more than one service share the db server that we
        # run monitoring program on

        my $uid = (stat $monDir)[4];
        my $owner = (getpwuid $uid)[0];
        #chown call hangs intermittently if called repetitively
        #So run chown only if $monDir is not already owned by $user
        #HOA-95954
        $cmd = "${SUDO}$chown -R $user:ariba $monDir" if ($owner ne $user);
    } else {
        $cmd = "${SUDO}$chmod -R 777 $monDir";
    }

    if ($cmd) {
    	my @output;
    	unless ( ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1, undef, $password) ) {
        	print "Running $cmd failed:\n", join("\t\n", @output), "\n";
        	return 0;
    	}
    }

    return 1;

}

sub launchLogfileWatcher
{
    my $me = shift();

    if (ariba::Ops::ServiceController::checkFunctionForService($me->service(), 'launchlog')) {
        my $SUDO = realOrFakeSudoCmd();
        my $com = "${SUDO} $main::INSTALLDIR/bin/common/logfile-watcher";
        launchCommandFeedResponses($com);
    }
}

sub launchCopyFromSharedFs
{
    my $me = shift();
    my $masterPassword = shift();
    my $shortHost = shift();
    my @args = @_;
    my ($krargs, $com);

    my $name = $me->name();
    return 0 unless ($name eq "mon" || $name eq "an");

    my $rotateLogInterval = 12 * 60 * 60 ; # rotate logs every 12 hours
    $krargs = "-ke $ENV{'NOTIFY'}";

    # HACK: send pages only to dang and manishd for this.
    if (ariba::Ops::ServiceController::isProductionServicesOnly($me->service())) {
        #$krargs .= " -kg 6502247647\@mobile.att.net,6508887572\@mobile.att.net";
    } else {
        $krargs .= " -kg $ENV{'NOTIFYPAGERS'}";
    }

    $krargs .= " -ks $rotateLogInterval";

    if (!(ariba::Ops::ServiceController::isProductionServicesOnly($me->service()))) {
        $krargs .= " -kc 2";
    }

    my $distSharedFs = "$main::INSTALLDIR/bin/copy-from-shared-fs $name -debug " .
                       join(" ", @args);
    $com = "$main::INSTALLDIR/bin/keepRunning -d -kp $distSharedFs $krargs -kn copy-from-shared-fs\@$shortHost";
    ariba::Ops::Startup::Common::runKeepRunningCommand($com, $masterPassword);
}

sub launchCopyToSharedFs
{
    my($me, $masterPassword, $shortHost)=@_;
    my ($krargs, $com);

    my $name = $me->name();
    return 0 unless ($name eq "mon");

    my $rotateLogInterval = 12 * 60 * 60 ; # rotate logs every 12 hours
    $krargs = "-ke $ENV{'NOTIFY'}";
    $krargs .= " -kg $ENV{'NOTIFYPAGERS'}";
    $krargs .= " -ks $rotateLogInterval";

    if (!(ariba::Ops::ServiceController::isProductionServicesOnly($me->service()))) {
        $krargs .= " -kc 2";
    }

    my $syncToSharedFs = "$main::INSTALLDIR/bin/copy-to-shared-fs $name -debug";
    $com = "$main::INSTALLDIR/bin/keepRunning -d -kp $syncToSharedFs $krargs -kn copy-to-shared-fs\@$shortHost";
    ariba::Ops::Startup::Common::runKeepRunningCommand($com, $masterPassword);
}

sub webLogicSortRoles
{
    # make sure we launch sourcingadmin before market
    return -1 if $::a eq "sourcingadmin" && $::b eq "market";
    return  1 if $::b eq "sourcingadmin" && $::a eq "market";

    # make sure we launch sourcingadmin before presentation
    return -1 if $::a eq "sourcingadmin" && $::b eq "presentation";
    return  1 if $::b eq "sourcingadmin" && $::a eq "presentation";

    # make sure we launch sourcingadmin before sourcing
    return -1 if $::a eq "sourcingadmin" && $::b eq "sourcing";
    return  1 if $::b eq "sourcingadmin" && $::a eq "sourcing";

    return ($::a cmp $::b);
}

=pod

=list * sortRolesBasedOnOrder( $roleA, $roleB, $orderHash )

Returns the sort value (-1, 0, 1) for the two roles based on the 
order hash provided. The order hash has the following format: 

my $orderHash = {
    roleA => 1, 
    roleB => 2, 
    roleC => 3,
};

=cut

sub sortRolesBasedOnOrder
{
    my $roleA = shift;
    my $roleB = shift;
    my $order = shift;
        
    return 1 if !exists($order->{$roleA}) && exists($order->{$roleB});
    return -1 if exists($order->{$roleA}) && !exists($order->{$roleB});
    return $order->{$roleA} <=> $order->{$roleB} if (exists($order->{$roleA}) && exists($order->{$roleB}));
    return ($roleA cmp $roleB);
}

sub logsDirForProduct {
    my $product = shift;

    my $service = $product->service();
    my $prodname = $product->name();
    my $customer = $product->customer();

    my $logsDir = ariba::Ops::Startup::Common::tmpdir() . "/$service/$prodname";
    $logsDir .= "/$customer" if ($customer);

    return $logsDir;
}
#
# This sub is used only to set things up. It should not:
#
# - create anything (like log directories etc.)
# - launch anything (like xvfb, log-viewer etc.)
# - modify anything (except ClusterName, if requested)
# - delete anything (like krlogs, tomcat config files etc.)
#
# as it is used from both startup and stopsvc and other scripts
# 
sub initializeProductAndBasicEnvironment {

    my $hostname = shift;
    my $clusterName = shift;
    my $checkForRootUser = shift;
    my $verifyPciPassword = shift;

    #
    # based on where the script was invoked from, find out which product
    # we are trying to operate on
    #
    my $scriptDir =  dirname($FindBin::Bin);
    $scriptDir =~ s#\\#/#og;
    $scriptDir =~ s#/$##og;

    $ENV{'PERL5LIB'} ||= '';
    $ENV{'PERL5LIB'} = join(':', ("$scriptDir/lib/perl","$scriptDir/lib","$ENV{'PERL5LIB'}"));

    # be friendly.
    umask 022;

    # our Rlimit code only works on Solaris
    if ( $^O eq "solaris" ) {
        #
        # bump up # of fd's to maximum allowable.
        #
        eval "use ariba::util::Rlimit"; die "Eval Error: $@\n" if ($@);
        my ($rcur, $rmax) = ariba::util::Rlimit::getrlimit("descriptors");
        ariba::util::Rlimit::setrlimit("descriptors", $rmax, $rmax);
    }

    my $me = ariba::rc::InstalledProduct->new();

    my $service  = $me->service();
    my $prodname = $me->name();
    my $customer = $me->customer();

    # make sure we run as the user we should.
    my $deploymentUser = $me->deploymentUser();
    my $effectiveUser  = getpwuid($>);

    # check if we are running as the right user
    if ( ( ! $checkForRootUser ) && ( $deploymentUser ne $effectiveUser ) ) {
        print "ERROR: startup should be run as [$deploymentUser], not [$effectiveUser].\n";
        return undef;
    }
    if ( $checkForRootUser && ( $effectiveUser ne 'root' && $deploymentUser ne $effectiveUser ) ){
        print "ERROR: startup should be run as [$deploymentUser] or [root], not [$effectiveUser].\n";
        return undef;
    }

    # Load in configuration of the product about to be deployed
    unless ($me->deploymentDefaults() || $me->parametersTable()) {
        print "ERROR: Could not find defaults for $prodname or an for service $service\n";
        return undef;
    }

    # make sure we can load all the dependent modules for this product
    if ($prodname eq "mon") {
        eval "use ariba::Ops::Startup::Monitoring";

        if ($@ =~ /Can\'t/) {
            print "ERROR: Can't load ariba::Ops::Startup::Monitoring: $@\n";
            return undef;
        }
    }

    # find out which cluster we are operating on
    $clusterName = $me->currentCluster() unless $clusterName;
    unless ($me->recordClusterName($clusterName)) {
        print "ERROR: could not record clustername $clusterName, $!\n";
        return undef;
    }

    # Load in the roles of this host
    my @roles = $me->rolesForHostInCluster($hostname, $clusterName);
    if ($#roles < 0) {
        print "ERROR: Could not find $hostname in roles.cfg\n";
        return undef;
    }

    # This should happen upfront before any call to the 'default' or
    # 'defaults' method. Both those methods try to use master password
    # to decrypt cipherblocktext in DD.xml
    ariba::rc::Passwords::initialize($service);
    if ( $verifyPciPassword && $me && $me->default( 'Ops.UsesPciPassword' ) eq 'true' ) {
        my $pci = ariba::rc::Passwords::lookup( 'pci' );
        die "ERROR: Concatenated <master>split<pci> password required.  Could not determine the PCI password from the password entered.\n" unless $pci;
    }

    my $installDir = $me->installDir();
    $ENV{'ARIBA_TOOLS_ROOT'} = $installDir;
    $ENV{'ARIBA_SERVICE_ROOT'} = $installDir;
    $ENV{'ARIBA_DEPLOY_ROOT'} = $installDir;
    $ENV{'ARIBA_CONFIG_ROOT'} = $me->configDir();
    $ENV{'BUILDNAME'} = $me->buildName();
    $ENV{'ARIBA_SERVICE'} = $me->service();
    $ENV{'NEXT_ROOT'} = $me->nextRoot();
    $ENV{'ORACLE_HOME'} = $me->oracleHome();

    $ENV{'LOGSDIR'} = ariba::Ops::Startup::Common::logsDirForProduct($me);

    $ENV{'NOTIFY'}       = $me->default('notify')       || $me->default('notify.email') || '';
    $ENV{'NOTIFYPAGERS'} = $me->default('notifypagers') || $me->default('notify.pagers') || '';
    $ENV{'SMTPSERVER'}   = $me->default('smtpserver')   || '';
    $ENV{'APPENDSTRING'} = $me->default('appendstring') || '';

    unless( -d $ENV{'LOGSDIR'} ) {

        #
        # fix permissions on the fly
        #
        my $SUDO = realOrFakeSudoCmd();
        my $backdir = $ENV{'LOGSDIR'};
        while($backdir =~ s|/[^/]+$|| && $backdir =~ m|[^/]/|) {
            next unless -d $backdir;
            my $cmd = "$SUDO chmod -f 1777 $backdir";
            my $password = ariba::rc::Passwords::lookup($deploymentUser);

            my @output;
            unless ( ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1, undef, $password) ) {
                print "Running $cmd failed:\n", join("\t\n", @output), "\n";
                return;
            }
        }

        unless (ariba::rc::Utils::mkdirRecursively($ENV{'LOGSDIR'})) {
            print "ERROR: Could not create $ENV{'LOGSDIR'}\n";
            return undef;
        }

        #
        # change permission on /tmp/$SERVICE to drwxrwxrwxt like /tmp is
        #
        chmod(01777, dirname($ENV{'LOGSDIR'})) if( -e dirname($ENV{'LOGSDIR'}));
    }

    ariba::Ops::Startup::Common::tmpdir();

    # This is required for Crontab.pm to do its work
    ariba::rc::Utils::refreshSudoPrompt($deploymentUser) unless ariba::rc::Globals::isPersonalService($me->service());

    return $me;
}

sub startVirtualFrameBufferServer {
    my $display = shift || ':1.0';
    my $krInstanceName = shift;

    return(ariba::Ops::Startup::Common::controlVirtualFrameBufferServer($display, "start", $krInstanceName));

}

sub stopVirtualFrameBufferServer {
    my $display = shift || ':1.0';
    my $krInstanceName = shift;

    return(ariba::Ops::Startup::Common::controlVirtualFrameBufferServer($display, "stop", $krInstanceName));

}

sub controlVirtualFrameBufferServer {
    my $display = shift;
    my $action = shift;
    my $krInstanceName = shift;

    $ENV{'DISPLAY'} = $display;

    my ($cmd, $cmdargs, $displayRes) = ariba::Ops::Utils::checkForXvfbPath ($display);

    # The above method returns undef'd values in the list if it can not figure out info based on the OS and OS version.
    # If this happens, this method cannot continue either, and should return undef or zero as well.
    return 0 unless $cmd;

    my $xvfbLockFile = "/var/tmp/xvfb-start-lock-$display";
    $xvfbLockFile =~ s/:/_/g;

    #
    # If Xvfb is already running kill it if the request is to stop,
    # dont start it if the request is to start.
    #
    my $processTable = ariba::Ops::ProcessTable->new();
    my $checkCommand = "$cmd $display";

    if ($action eq "stop") {

        if ($krInstanceName) {
            my ($krPids, $xvfbPids, $files) = kRpidsAndFilesForAppNames($krInstanceName);
            killPids($krPids, $xvfbPids, "9");
            map { unlink($_) } @$files;
        }

        $processTable->killProcessesWithName($checkCommand);
        for (1..10) {
            $processTable->refresh();
            last unless ($processTable->processWithNameExists($checkCommand));
            sleep(1);
        }
        $processTable->refresh();
        if ($processTable->processWithNameExists($checkCommand)) {
            print "Warning: Couldn't stop $cmd for display $display\n";
        }
    } elsif ($action eq "start") {

        #
        # serialize the check for xvfb to avoid race condition during
        # rolling restart
        #
        # only one process needs to do start xvfb so it's ok for 
        # subsequent startup runs to fail this lock check and
        # continue without error
        #

        if (dmail::LockLib::requestlock($xvfbLockFile)) {
            unless($processTable->processWithNameExists($checkCommand)) {

                my $displayLock = "/tmp/.X${display}-lock";
                if (-e $displayLock) {
                    print "Warning: '$displayLock' exists but '$checkCommand' not found in the process table.  Removing.\n";
                    unlink $displayLock;
                }

                if ($krInstanceName) {
                    my $rotateInterval = 24 * 60 * 60; # 1 day
                    ariba::Ops::Startup::Common::launchCommandFeedResponses("$main::INSTALLDIR/bin/keepRunning -w -kp $cmd $cmdargs $displayRes -ks $rotateInterval -ki -kn $krInstanceName -ke $ENV{'NOTIFY'}");
                } else {
                    ariba::Ops::Startup::Common::launchCommandFeedResponses("$cmd $cmdargs $displayRes");
                }

                # sometimes when starting multiple nodes on the same
                # host (even in serial) we see xvfb 'Server Error'
                # messages in the logs about server already being
                # started.
                #
                # Try to avoid this by giving the server some time to
                # show up in the process list.
                #
                for (1..10) {
                    $processTable->refresh();
                    last if ($processTable->processWithNameExists($checkCommand));
                    sleep(1);
                }

                $processTable->refresh();
                unless ($processTable->processWithNameExists($checkCommand)) {
                    print "Warning: Couldn't not find $checkCommand for display $display in process table\n";
                }
            }

            dmail::LockLib::releaselock($xvfbLockFile);
        }
    }

    return 1;
}

sub javaHomeForProduct {
    my $me = shift;

    my $javaHome = $me->javaHome();

    #
    # stop if we cannot find java installation to use
    #
    unless ($javaHome) {
        print "ERROR: Could not find Java, check to make sure you have JavaVersion.cfg for this product\n";
        exit(1);
    }

    unless (-d $javaHome ) {
        print "ERROR: Could not find requested java installation [$javaHome]\n";
        exit(1);
    }

    return $javaHome;
}

sub waitForAppInstancesToInitialize {
    my $appInstancesRef = shift;
    my $timeout         = shift || 5*60; # 5 mins
    my $tries           = shift || 10;
    my $reportProgress   = shift;
    my $quiet = shift;

    my $sleepTime = $timeout/$tries; # we will try upto $tries times.

    #
    # cache the status of appInstances, so we dont recheck the ones
    # that are already up.
    #
    my %isAppInstanceUp;
    my $allAppInstancesAreUp;

    # create a new array to not modify pass-in array ref, as caller
    # may not expect instances to be missing
    my @appInstances = grep { $_->canCheckIsUp() } @$appInstancesRef;

    #
    # try upto 10 times to see if the app has come up. Bail out as
    # soon as it is up
    #
    for (my $i = 0; $i < $tries; $i++) {
        for my $appInstance (@appInstances) {
            my $instanceName = $appInstance->instanceName();

            if ( $appInstance->checkIsUp() ) {
                print "$instanceName is up\n" if $reportProgress;
                $isAppInstanceUp{$instanceName} = 1;
            }
        }

        #
        # Check if each of the requested app is up
        #
        $allAppInstancesAreUp = 1;
        for my $appInstance (@appInstances) {
            my $instanceName = $appInstance->instanceName();

            unless ($isAppInstanceUp{$instanceName}) {
                $allAppInstancesAreUp = 0;
                print "$instanceName is NOT up after ", $i + 1, " tries\n" if $reportProgress;
                last;
            }
        }

        #
        # unless all of the appinstances are up, we need to check again
        #
        if ($allAppInstancesAreUp) {
            last;
        } else {
            sleep($sleepTime);
        }
    }

    unless($allAppInstancesAreUp) {
        print "Warning: one or more instance(s) aren't fully up after $timeout secs timeout. Continuing...\n" unless $quiet;
    }

    return $allAppInstancesAreUp;
}

sub _dirForLoadRedisFiles {
    my $me = shift;
    my $sharedTempDir = $me->default('System.Logging.ArchiveDirectoryName');
    my $dirForLoadRedis = "$sharedTempDir/ops.loadmeta"; #change this in dd.cfg . new param for loadredis.for now use same dir

    return $dirForLoadRedis;
}
sub loadredisLock {
    my $me = shift;

    my $dirForLoadRedis = _dirForLoadRedisFiles($me);
    my $buildName = $me->buildName();
    my $releaseName = $me->releaseName();
    my $lockFile = "$dirForLoadRedis/loadredis-$buildName-$releaseName";

    return $lockFile;
}

sub loadredisSuccessMarker {
    my $me = shift;

    my $dirForLoadRedis = _dirForLoadRedisFiles($me);
    my $buildName = $me->buildName();
    my $releaseName = $me->releaseName();
    my $successMarkerFile = "$dirForLoadRedis/loadredis-$buildName-$releaseName.success";

    return $successMarkerFile;
}

sub loadredisFailureMarker {
    my $me = shift;

    my $dirForLoadRedis = _dirForLoadRedisFiles($me);
    my $buildName = $me->buildName();
    my $releaseName = $me->releaseName();
    my $failureMarkerFile = "$dirForLoadRedis/loadredis-$buildName-$releaseName.failure";

    return $failureMarkerFile;
}

sub _dirForLoadMetaFiles {
    my $me = shift;
    my $sharedTempDir = $me->default('System.Logging.ArchiveDirectoryName');
    my $dirForLoadMeta = "$sharedTempDir/ops.loadmeta";

    return $dirForLoadMeta;
}
sub loadmetaLock {
    my $me = shift;

    my $dirForLoadMeta = _dirForLoadMetaFiles($me);
    my $buildName = $me->buildName();
    my $releaseName = $me->releaseName();
    my $lockFile = "$dirForLoadMeta/loadmeta-$buildName-$releaseName";

    return $lockFile;
}

sub loadmetaSuccessMarker {
    my $me = shift;

    my $dirForLoadMeta = _dirForLoadMetaFiles($me);
    my $buildName = $me->buildName();
    my $releaseName = $me->releaseName();
    my $successMarkerFile = "$dirForLoadMeta/loadmeta-$buildName-$releaseName.success";

    return $successMarkerFile;
}

sub loadmetaFailureMarker {
    my $me = shift;

    my $dirForLoadMeta = _dirForLoadMetaFiles($me);
    my $buildName = $me->buildName();
    my $releaseName = $me->releaseName();
    my $failureMarkerFile = "$dirForLoadMeta/loadmeta-$buildName-$releaseName.failure";

    return $failureMarkerFile;
}

sub kRpidsAndFilesForAppNames {
    my @stopApps = @_;

    my $tmpDir    = $ENV{'LOGSDIR'};

    # grab only the PID files that keepRunning has written out.
    opendir(TMP, $tmpDir) || warn "instance-watcher could not open dir [$tmpDir]: $!";
    my @filelist = grep { /keepRunning.+?\.pid/ } readdir(TMP);
    closedir(TMP);

    my @krPids;
    my @appPids;
    my @unlinkFiles;

    for my $appName (@stopApps) {

        for my $file (@filelist) {

            next unless $file =~ /\b$appName\b/;

            open(KRPID, "$tmpDir/$file") or warn "Can't open [$tmpDir/$file]: $!";
            chomp(my $krPid  = <KRPID>);
            chomp(my $appPid = <KRPID>);
            close(KRPID);

            push(@unlinkFiles, "$tmpDir/$file");

            print "Killing process from $file $krPid, $appPid\n";

            push(@krPids, $krPid);
            push(@appPids, $appPid);

        }
    }

    return(\@krPids, \@appPids, \@unlinkFiles);

}

sub sigUSR2 {

    my $sigusr2;
    if ($^O =~ /linux/i) {
        $sigusr2 = 12;
    } elsif ($^O =~ /solaris/i) {
        $sigusr2 = 17;
    }

    return $sigusr2;
}

sub pidToProcessMap {
    my $ref = shift;
    my (@pids) = (@_);

    my $processTable = ariba::Ops::ProcessTable->new();
    $processTable->refresh();

    foreach my $pid (@pids) {
        my $data = $processTable->dataForProcessID($pid);
        my $cmd = $data->{'cmnd'};
        #
        # I'd like to use ppid, but processTable doesn't reliably return it
        # correctly.
        #
        # $$ref{$pid} = $data->{'ppid'} . ":$cmd";
        $$ref{$pid} = $cmd;
    }
}

sub checkProcess {
    my $pid = shift;
    my $map = shift;
    my $check = {};

    #
    # assume we match in this case, since we don't have a map entry
    # this ensures backwards compatibility if any other code calls
    # killPids
    #
    return(1) unless($map->{$pid});

    pidToProcessMap($check, $pid);

    if($check->{$pid} && $check->{$pid} eq $map->{$pid}) {
        return(1);
    }

    print "INFO: $pid does not match original process : ", $check->{$pid}, " does not match ", $map->{$pid}, "\n";
    return(0);
}

sub killPids {
    my $krPidsArrayRef = shift;
    my $appPidsArrayRef = shift;
    my $useSignals = shift;
    my $waitTime = shift;
    my $debug = shift;
    my $pidMap = shift;

    unless($pidMap) {
        $pidMap = {};
        pidToProcessMap($pidMap, @{$krPidsArrayRef}, @{$appPidsArrayRef});
    }

    #
    # Try to send SIGTERM to apps first before sending SIGKILL, to give
    # it a chance to exit cleanly
    #
    my @killSignals = (15, 9);

    if ($useSignals) {
        @killSignals = split(/:/, $useSignals);
    }

    my $killed;
    my $sendSignal;

    for my $signal (@killSignals) {
        my %killedPids;
        $killed = 0;

        if ($signal eq "USR2") {
            $signal = ariba::Ops::Startup::Common::sigUSR2();
        }

        # Kill keeprunning before the actual process
        for my $pid (@$krPidsArrayRef) {
            next unless($pid);
            #
            # we sometimes have the same pid in the list twice -- don't
            # send it a "soft" signal twice, which can cause the app to die
            # "hard" if it has not yet reset the signal handler
            #
            next if($killedPids{$pid});

            #making generic across all products as per HOA-149084.Do a graceful shutdown with Signal 15
            #If that does not helps,kill with signal 9
            $sendSignal = $signal;


            # check to make sure that the process is still running
            if (kill(0, $pid) && checkProcess($pid, $pidMap)) {
                print "killing [$pid] ($sendSignal)\n";
                kill ($sendSignal, $pid) unless ($debug);
                $killedPids{$pid} = 1;
                $killed++;
            }
        }

        for my $pid (@$appPidsArrayRef) {
            next unless($pid);
            #
            # we sometimes have the same pid in the list twice -- don't
            # send it a "soft" signal twice, which can cause the app to die
            # "hard" if it has not yet reset the signal handler
            #
            next if($killedPids{$pid});

            $sendSignal = $signal;
            # check to make sure that the process is still running
            if (kill(0, $pid) && checkProcess($pid, $pidMap)) {
                print "killing [$pid] ($sendSignal)\n";
                kill ($sendSignal, $pid) unless($debug);
                $killedPids{$pid} = 1;
                $killed++;
            }
        }

        #
        # sleep 20 secs to give all the processes a chance to exit
        # cleanly in case we sent it a SIGTERM
        #
        if ($killed) {
            my $sleepInterval = 20;
            print "Sent signal [$signal] to all apps\n";

            # if we are going to send another signal, wait for
            # some time before sending it.
            if (@killSignals > 1) {
                if ($signal == ariba::Ops::Startup::Common::sigUSR2() || 
                    ($waitTime && $signal == 15)) {

                    # wait for 16 mins after SIGUSR2
                    # this is to account for some overhead in the app's 
                    # shutdown process
                    my $waitTimeInMinutes = $waitTime || 16;
                    my $secondsToWait = $waitTimeInMinutes * 60;

                    $sleepInterval = 10; # 10 seconds
                    my $numLoops = $secondsToWait / $sleepInterval;

                    for ( my $i = 1; $i <= $numLoops ; $i++) {
                        sleep($sleepInterval);
                        my $allGone = 1;
                        print "Waited for ", $i*$sleepInterval, " secs check again...\n";
                        for my $pid (@$appPidsArrayRef) {
                            if (kill(0, $pid) && checkProcess($pid, $pidMap)) {
                                $allGone = 0;
                                last;
                            }
                        }
                        #
                        # If all processes have
                        # exited, we dont need to wait
                        # the entire 15 mins. Break
                        # out of the loop now.
                        #
                        if ($allGone) {
                            last;
                        }
                    }
                } elsif ($signal == 15) {
                    #wait for 20 secs after SIGTERM
                    print "Waiting up to $sleepInterval secs graceful exit...\n";
                    for (my $i = 1; $i <= $sleepInterval; $i++) {
                        sleep(1);
                        my $allKilled = 1;
                        for my $pid (keys %killedPids) {
                            if (kill(0, $pid)) {
                                $allKilled = 0;
                                last;
                            }
                        }
                        if ($allKilled) {
                            print "All processes exited after $i sec(s)\n";
                            last;
                        }
                    }
                } elsif ($signal == 9) {
                    print "$killed processe(s) did not exit gracefully, force killed.\n";
                }
            }
        }
    }
}

sub killProcesses {
    my $community = shift;
    my @processes = @_;
	$myUid = (getpwnam($ENV{'USER'}))[2] unless(defined($myUid));

    my $cmd;
    my $pidfield = 1;
    my $pname    = 8;
    my $usernamefield = 0;

    if ($^O eq "linux") {
        $cmd = "/bin/ps auxww";
        $pname = 10;

    } elsif ($^O eq "solaris") {
        $cmd = "/usr/ucb/ps -auxww";

    } else {
        $cmd = "/bin/ps -elf";
        $usernamefield = 2;
        $pidfield = 3;
    }

    my @krPids;
    my @appPids;
    my @unlinkFiles;

    my %seenProcess;

    for my $process (@processes) {

        #
        # if the incoming array has duplicate entry, dont do
        # more work
        #
        next if ($seenProcess{$process});
        $seenProcess{$process} = 1;

        open(PROC, "$cmd |") || die "ERROR: $cmd failed, $!\n";
        while(my $line =<PROC>) {
            chomp($line);
            $line =~ s/^\s*//;
            my @info = split(/\s+/, $line);
            my $pid  = $info[$pidfield];
            my $name = "";

            for (my $i = $pname; $i <= $#info; $i++) {
                $name .= " " . $info[$i];
            }

			#
            # make sure we are killing apps owned by this user
			#
			# we have to check UID and name since usernames longer than 8
			# characters show up by UID in ps listings
			#
            next if ($name =~ /$0/);
			next if($info[$usernamefield] ne $ENV{'USER'} &&
						$info[$usernamefield] ne $myUid);

            # kill keep running only for this buildname (in shared accout this is important)
            next if (($process =~ /^keepRunn/ || $name =~ /keepRunning/) && $name !~ /$ENV{BUILDNAME}/);

            if ($name =~ /$process/i) {

                if ($pid == $$) { 
                    print "skipping $pid $name\n";
                    next;
                }

                # if stopping a particular community, try to look for
                # community string as a command line argument.
                next if $community && $name !~ /Community[=\s]$community\b/i;

                print "Killing process $process, $name, $pid\n";
                if ($name =~ /keepRunn/i) {
                    push(@krPids, $pid);
                } else {
                    push(@appPids, $pid);
                }

            }
        }
        close(PROC);
    }

    return(\@krPids, \@appPids, \@unlinkFiles);
}


=pod

=list * composeJvmArguments( product, instance )

Returns the jvm args for the specified product and app instance in non-array context. 
In array context, returns the Max Heap Size (numeric in MB) separately as the 2nd element in an 
array with the other jvm args as the 1st element. 

'instance' can be a app instance or the name of the app.

=cut

sub composeJvmArguments {
    my($me, $instance) = @_;

    my @jvmArgs; 
    my $appName = ref($instance) && $instance->appName() || $instance;

    # Max Heap Size
    my $maxHeapSize = $me->default("Ops.JVM.$appName.MaxHeapSize") || 
        $me->default('Ops.JVM.MaxHeapSize') || 
        $me->default("JVM.$appName.MaxHeapSizeInMB") || 
        $me->default('JVM.MaxHeapSizeInMB');

    if ($maxHeapSize) {
        if (wantarray()) {
            $maxHeapSize =~ s/M$//io; 
            $maxHeapSize *= 1024 if ($maxHeapSize =~ s/G$//io);
        } else {
            $maxHeapSize .= 'M' if ($maxHeapSize =~ /\d$/);
            push(@jvmArgs, '-Xmx' . $maxHeapSize);
            undef($maxHeapSize);
        }
    }

    # Start Heap Size
    my $startHeapSize = $me->default("Ops.JVM.$appName.StartHeapSize") || 
        $me->default('Ops.JVM.StartHeapSize') || 
        $me->default("JVM.$appName.StartHeapSizeInMB") || 
        $me->default('JVM.StartHeapSizeInMB');
    $startHeapSize .= 'M' if ($startHeapSize && $startHeapSize =~ /\d$/);
    push(@jvmArgs, '-Xms' . $startHeapSize) if ($startHeapSize);

    # Start Stack Size
    my $stackSize = $me->default("Ops.JVM.$appName.StackSize") || 
        $me->default('Ops.JVM.StackSize') || 
        $me->default("JVM.$appName.StackSizeInMB") || 
        $me->default('JVM.StackSizeInMB');
    $stackSize .= 'M' if ($stackSize && $stackSize =~ /\d$/);
    push(@jvmArgs, '-Xss' . $stackSize) if ($stackSize);

    # Arguments
    my $jvmArgs = $me->default("Ops.JVM.$appName.Arguments") || 
        $me->default("Ops.JVM.Arguments") || 
        $me->default("JVM.$appName.Arguments") || 
        $me->default("JVM.Arguments"); 
    my $jvmArgsAppend = $me->default("Ops.JVM.$appName.ArgumentsAppend") || 
        $me->default("JVM.$appName.ArgumentsAppend");

    map {
        my $args = $_;
        if ($args) {
            if (ref($args) eq 'ARRAY') {
                push(@jvmArgs, @$args) if (@$args);
            } else {
                push(@jvmArgs, $args);
            }
        }
    } ($jvmArgs, $jvmArgsAppend);

    # JVM Args
    $jvmArgs = join(' ', @jvmArgs);
    $jvmArgs = "-server $jvmArgs" unless ($jvmArgs =~ /-(?:server|client)/o);

    if (wantarray()) {
        return ($jvmArgs, $maxHeapSize);
    } else {
        return $jvmArgs;
    }
}


#
# Constants
#

sub EXIT_CODE_OK { return 0; }
sub EXIT_CODE_ERROR { return 1; }
sub EXIT_CODE_ABORT { return 2; }
sub EXIT_CODE_TIMEOUT { return 3; }
   
1;

__END__
