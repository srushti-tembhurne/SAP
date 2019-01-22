package ariba::rc::Utils;
#
# $Id: //ariba/services/tools/lib/perl/ariba/rc/Utils.pm#131 $
#

use strict;
use vars qw(@ISA @EXPORT);
use Exporter;
use File::Basename;
use File::Path;
use FileHandle;
use Text::ParseWords;
use Time::HiRes;
use ariba::rc::Passwords;
use ariba::util::PerlRuntime;
use ariba::Ops::PropertyList;

my $cp;
my $rm;
my $ln;
my $mv;
my $mkdir;
my $chmod;
my $chown;

my $rsync;
my $ssh;
my $scp;
my $tar;
my $gzip;
my $sudo;
my $sh;

my $gnuPlot;
my $diff;
my $nice;

my $arp;
my $ping;

my $alreadyRefreshedSudo = 0;

@ISA = qw(Exporter);
@EXPORT = qw(
    r executeLocalCommand executeRemoteCommand unixSlashes dosSlashes onNT flush
    getServiceName getProductName getReleaseName getCustomerName getPrettyCustomerName
    getBuildName getBranchName getClusterName
    hostHasSoftware transferFromSrcToDest checkSource removePath 
    cpCmd rmCmd lnCmd mvCmd mkdirCmd chmodCmd chownCmd
    rsyncCmd sshCmd scpCmd tarCmd gzipCmd sudoCmd shCmd
    gnuPlotCmd diffCmd nicePrefix arpCmd pingCmd
    sharedLibEnvName
    mkdirRecursively rmdirRecursively
    );

{
    if (onNT()) {
        $ENV{'USER'} = $ENV{'USERNAME'} || $ENV{'USER'} || '';
        my $mksRoot = $ENV{'ROOTDIR'};
        $cp = "$mksRoot/mksnt/cp";
        $rm = "$mksRoot/mksnt/rm";
        $ln = "$mksRoot/mksnt/ln";
        $mv = "$mksRoot/mksnt/mv";
        $mkdir = "$mksRoot/mksnt/mkdir";
        $chmod = "$mksRoot/mksnt/chmod";
        $chown = "$mksRoot/mksnt/chown";

        $rsync = "rsync";
        $ssh   = "rsh";
        $scp   = "rcp";
        $tar   = "$mksRoot/mksnt/tar";
        $gzip  = "gzip";

        $arp   = "arp";
        $ping  = "ping";

        $sudo  = "";
        $sh    = 'sh';
    } else {
        unless ( $ENV{'USER'} ) {
            $ENV{'USER'}  = $ENV{'LOGNAME'} if ( defined( $ENV{'LOGNAME'} ) );
        }
        $cp = "/bin/cp";
        $rm = "/bin/rm";
        $ln = "/bin/ln";
        $mv = "/bin/mv";
        $mkdir  = "/bin/mkdir";
        $chmod  = "/bin/chmod";
        $sudo   = (-x "/usr/bin/sudo") ? "/usr/bin/sudo" : "/usr/local/bin/sudo";
        $sh   = "/usr/local/bin/tcsh";
        $chown  = (-x "/usr/local/bin/chown") ?  "/usr/local/bin/chown" : "/bin/chown";

        # in /usr/local/bin on sun, /usr/bin on linux
        $rsync = "rsync"; 
        $ssh   = -x '/usr/local/bin/ssh' ? '/usr/local/bin/ssh' : '/usr/bin/ssh';
        $gnuPlot   = -x '/usr/local/bin/gnuplot' ? '/usr/local/bin/gnuplot' : '/usr/bin/gnuplot';
        $diff      = -x '/usr/local/bin/diff' ? '/usr/local/bin/diff' : '/usr/bin/diff';
        $nice  = "nice";
        $scp   = "scp";
        $tar   = "tar";
        $gzip  = "gzip";

        $arp = -x '/sbin/arp' ? '/sbin/arp' : '/usr/sbin/arp';
        $ping = -x '/bin/ping' ? '/bin/ping' : '/usr/sbin/ping';

        require "ariba/rc/expect-covers.pl";
    }
}

my $testing = 0;
my $debug = 0;
my $trash = 0;

sub rmCmd
{
    return $rm;
}

sub cpCmd
{
    return $cp;
}

sub mvCmd
{
    return $mv;
}

sub lnCmd
{
    return $ln;
}

sub mkdirCmd
{
    return $mkdir;
}

sub chmodCmd
{
    return $chmod;
}

sub chownCmd
{
    return $chown;
}

sub tarCmd
{
    return $tar;
}

sub gzipCmd
{
    return $gzip;
}

sub rsyncCmd
{
    return $rsync;
}

sub sshCmd
{
    return $ssh;
}

sub scpCmd
{
    return $scp;
}

sub sudoCmd
{
    return $sudo;
}

sub shCmd
{
    return $sh;
}

sub gnuPlotCmd
{
    return $gnuPlot;
}

sub diffCmd
{
    return $diff;
}

sub nicePrefix {
    my $niceness = shift;

    my $prefix = "-";
    $prefix = "+" if ($ENV{'SHELL'} =~ /csh$/);

    return "$nice " . $prefix . $niceness;
}

sub arpCmd
{
    return $arp;
}

sub pingCmd
{
    return $ping;
}

sub r 
{
    my ($command,$grabOutput) = @_;
    
    $command = "sh -c '$command'" if (onNT());
    print "Running '$command'\n" if $debug;
    return if ($testing);

    if ($grabOutput) {
            chomp(my $out = `$command`);
            return $out;
    }


    system($command);

    # return 0 on success and exit_value of process otherwise.
    return $? >> 8;
}

sub unixSlashes 
{
    my $path  = shift;
    $path =~ s#\\#/#og if (defined $path and $path !~ /^\s*$/);
    return $path;
}
    
sub dosSlashes 
{
    my ($path,$quotedForUnix) = @_;
    return unless defined $path and $path !~ /^\s*$/;

    # under some shells we end up with //, fix
    # be careful not to hose UNC paths
    $path =~ s#.{2,}//#/#og;

    if ($quotedForUnix) {
        $path =~ s#/#\\\\#og;
    } else {
        $path =~ s#/#\\#og;
    }
    
    return $path;
}

sub onNT 
{
    $^O =~ /mswin32/i ? 1 : 0;
}


sub mkdirRecursively
{
    my $dir = shift;

    # mkpath dies on error, we just need to return error to the
    # caller and let the caller decide what to do.
    eval { File::Path::mkpath($dir) };
    if ($@) {
        return 0;
    }

    return 1;

}
sub rmdirRecursively
{
    my $dir = shift;

    # rmtree dies on error, we just need to return error to the
    # caller and let the caller decide what to do.
    eval { File::Path::rmtree($dir) };
    if ($@) {
        return 0;
    }

    return 1;
}

sub _getName 
{
#XXX todo.  Put all _getNames in a single file, and cache based on configDir

    my $configDir = shift;
    my $type = shift;
    my $useLine = shift || 0;

    unless (defined($configDir)) {
        warn "Error: \$configDir is undefined!\n";
        ariba::util::PerlRuntime::dumpStack();
        return "Unknown-$type";
    }

    my $file = "$configDir/${type}Name";

    open(F, $file) or do {
        # respect quiet settings to allow scripts to mute
        # expected debug output
        unless( defined($main::quiet) && $main::quiet ){
            warn "Error: [$file] can't be read: $!\n";
            ariba::util::PerlRuntime::dumpStack();
        }
        return "Unknown-$type";
    };

    my @lines = <F>;
    close(F);

    # get the requested line or the first line if there arent
    # enough lines in the file
    my $name = $lines[$useLine] || $lines[0];

    chomp($name);
    $name =~ s/\r$//o;
    return $name;
}

sub getServiceName 
{
    _getName(shift,'Service');
}

sub getProductName 
{
    _getName(shift,'Product');
}

sub getReleaseName 
{
    _getName(shift,'Release');
}

sub getBuildName 
{
    _getName(shift,'Build');
}

sub getBranchName
{
    _getName(shift,'Branch');
}

sub getClusterName
{
    _getName(shift,'Cluster');
}

sub getCustomerName 
{
    _getName(shift,'Customer');
}

sub getPrettyCustomerName 
{
    _getName(shift,'Customer', 1);
}

sub hostHasSoftware 
{
    my ($host,$user,$software) = @_;

    if (onNT()) {
        return 0;
    }

    my $command = qq!$ssh -n $host -l $user "/usr/bin/test -r "$software""!;
    my $password = ariba::rc::Passwords::lookup($user);

    return (!sshCover($command, $password));
}

sub executeLocalCommand 
{
    my ($cmd, $bg, $output, $master, $useLocalExpectCover, $exitStatusRef, $password) = @_;
    my ($pid, $ret);

    if($testing) {
        print "testing: $cmd\n";
        return 1;
    }

    if (onNT()) {
        $ret = r($cmd, 0);
        return ($ret == 0);
    }

    if (defined($bg) && $bg) {
        unless ($pid=fork) {
            $ret = r($cmd, 0); #child
            exit (!$ret);
        } else {
            $ret = $pid; #parent
        }
    } else {
        if ($useLocalExpectCover) {
            $ret = localCover($cmd, $master, $output, undef, $password, $useLocalExpectCover);
        } else {
            $ret = r($cmd, 0);
        }
        if ($exitStatusRef) {
            $$exitStatusRef = $ret;
        }

        $ret = !$ret;
    }

    print "$ret: $cmd\n" unless $main::quiet;

    return $ret; #return 1 for sucess, 0 for failure
}

sub batchLocalCommands {

    my @job = @_;

    
    while (my $command = shift @job) {
        my $comment = shift @job;

        print $comment , "\n";
        my $ret = executeLocalCommand($command);

        print "Command : ", $ret, "\n" if ($ret && $debug);
    }

}


sub executeRemoteCommand 
{
    my ($cmd, $password, $bg, @args) = @_;

    my ($pid, $ret);

    if($testing) {
        print "testing: $cmd (password: $password)\n";
        return 1;
    }

    if (onNT()) {
        $ret = r($cmd, @args);
        return ($ret == 0);
    }

    if (defined($bg) && $bg) {
        unless ($pid=fork) {
            $ret = _timeSSHCover($cmd, $password, @args); #child
            exit (!$ret);
        } else {
            $ret = $pid; #parent
        }
    } else {
        $ret = _timeSSHCover($cmd, $password, @args);
        $ret = !$ret;
    }

    return $ret; #return 1 for sucess, 0 for failure
}

sub _timeSSHCover {
    my $startTime = time();

    my $cmd = $_[0];
    my $ret = sshCover(@_);

    my $duration = time() - $startTime; 
    print "$$ returned $ret ($duration secs): $cmd\n" unless $main::quiet;

    return $ret;
}

# Run a list of commands remotely
sub batchRemoteCommands {

    my $host = shift;
    my $user = shift;
    my $password = shift;

    my @job = @_;


    
    while (my $command = shift @job) {
        my $comment = shift @job;

        my @cmdOutput;
        my $sshCommand = "ssh $user\@$host '$command'";


        print $comment , "\n";
        my $ret = executeRemoteCommand(
                    $sshCommand,
                    $password,
                    0,
                    undef,
                    undef,
                    \@cmdOutput,
                );

        my $cmdOutput = join ("\n", @cmdOutput);
        print "SSH : ", $cmdOutput, "\n" if ($debug  && $cmdOutput =~ m/\S/ );
        print "\n";
    }

}



sub checkSource 
{
    my ($dst,$duser,$dstroot,$dstdir) = @_;

    my $testPath = $dstroot;
    $testPath .= "/$dstdir" if ($dstdir);

    # check if source exists
    if (defined $dst and $dst !~ /^\s*$/) {

        unless (hostHasSoftware($dst,$duser,$testPath)) {
            print "Error: Path $duser\@$dst:$testPath does not exist\n";
            return 0;
        }

    } else {

        unless (-e $testPath) {
            print "Error: Path $testPath does not exist\n";
            return 0;
        }
    }

    return 1;
}

sub transferFromSrcToDest 
{
    my($src,$suser,$srcroot,$srcdir,
        $dst,$duser,$dstroot,$dstdir,
        $compress,$bg,$incremental,
        $password,$retOutputRef,$hardLinkSrc,$useDelete)=@_;

    # check if source exists
    my $checkSrcRoot = $srcroot;
    my $checkSrcDir = $srcdir;
    if (!defined($srcdir) || $srcdir eq "*") {
        $checkSrcRoot = dirname($srcroot);
        $checkSrcDir = basename($srcroot);
    }
    my $ret = checkSource($src,$suser,$checkSrcRoot,$checkSrcDir) ? 1 : 0;

    unless ($ret) {
        if (defined $dst) {
            print "\ttransfer to $dst\@$duser:" unless $main::quiet;
        }

        print "$dstroot/$dstdir skipped\n" unless $main::quiet;
        return $ret;
    }

    return transferFromSrcToDestNoCheck($src,$suser,$srcroot,$srcdir,
                        $dst,$duser,$dstroot,$dstdir,
                        $compress,$bg,$incremental,$password,
                        $retOutputRef,$hardLinkSrc,
                        undef,undef,undef,undef,$useDelete);
}

sub copyFiles
{
    my ($srcroot,$srcdir,$dstroot,$dstdir,$checkDest, $nohardlinks) = @_;

    #
    # call lower level routine to do the copy. since this routine
    # can be called to copy from multiple src dir into single dest
    # dir (like from archive-build and make-deployment), perform
    # the copy in incremental mode.
    #
    my $ret = transferFromSrcToDestNoCheck(
        undef, undef,
        $srcroot,$srcdir,
        undef, undef,
        $dstroot,$dstdir,
        0, 0,
        1, undef,
        undef, undef,
        undef, undef,
        undef, $nohardlinks);

    unless ( $ret and $checkDest ) {
        return $ret; 
    } else {
        return compareSrcAndDestFileList($srcroot, $srcdir, $dstroot, $dstdir);
    }
}

sub copyDirsWithCP
{
        my ($srcdir,$dstdir) = @_;
        print "Srcdir is $srcdir \n";
        my $cmd = "cp -R $srcdir $dstdir";
        
        my $ret = r($cmd, 0);
        return ($ret == 0);
}

sub copyFilesWithDelete
{
    my ($srcroot,$srcdir,$dstroot,$dstdir,$checkDest) = @_;

    #
    # call lower level copy routine with out incremental mode to make
    # sure the src and dst are exactly the same.
    #
    my $ret = transferFromSrcToDestNoCheck(undef, undef,
                    $srcroot,$srcdir,
                    undef, undef,
                    $dstroot,$dstdir,
                    0, 0, 0, 
                    undef,undef,undef,undef, 1);

    unless ( $ret and $checkDest ) {
        return $ret; 
    } else {
        return compareSrcAndDestFileList($srcroot, $srcdir, $dstroot, $dstdir);
    }
}
    
sub copyFilesWithCompression
{
        my ($srcroot,$srcdir,$dstroot,$dstdir,$checkDest) = @_;

        #
        # call lower level routine to do the copy. since this routine
        # can be called to copy from multiple src dir into
        # single dest (like from archive-build and
        # make-deployment), perform the copy in incremental mode.
        # This sub allows for compression and checksum                                       

        my $ret = transferFromSrcToDestNoCheck(undef, undef,
                                        $srcroot,$srcdir,
                                        undef, undef,
                                        $dstroot,$dstdir,
                                        1, 0, 1,undef,undef,undef,1);

    unless ( $ret and $checkDest ) {
        return $ret; 
    } else {
        return compareSrcAndDestFileList($srcroot, $srcdir, $dstroot, $dstdir);
    }
}

sub compareSrcAndDestFileList {
    my ($srcroot, $srcdir, $dstroot, $dstdir) = @_;

    my $src = "$srcroot/";
    my $dst = "$dstroot";

    if ($srcdir) {
        $src .= "$srcdir";
    }
    if ($dstdir) {
        $dst .= "/$dstdir";
    }

    my $srcFileList = productRootFileList("$src");
    my $dstFileList = productRootFileList("$dst");

    if (scalar(@$srcFileList) <= 1) {
        print "Source build '$src' has no data";
        return 0;
    }
    my @unMatchedFiles;
    if (scalar(@$srcFileList) > scalar(@$dstFileList)) {
        for my $srcFile (@$srcFileList) {
            $srcFile = quotemeta($srcFile);
            push(@unMatchedFiles, $srcFile) unless grep(/^$srcFile$/, @$dstFileList);
        }
        print "The following files exist in the source root '$src' but not in the destination root '$dst':\n\t",
            join("\n\t", @unMatchedFiles), "\n"; 
        return 0;
    }
    if (scalar(@$srcFileList) < scalar(@$dstFileList)) {
        for my $dstFile (@$dstFileList) {
            $dstFile = quotemeta($dstFile);
            push(@unMatchedFiles, $dstFile) unless grep(/^$dstFile$/, @$srcFileList);
        }
        print "The following files exist in the destination root '$dst' but not in the source root '$src':\n\t",
            join("\n\t", @unMatchedFiles), "\n"; 
        return 0;
    }

    return 1;
}

sub productRootFileList { 
    my $dir = shift;
    my $list = shift;;
    my $rootDir = shift;

    unless ($list) {
        $rootDir = $dir;
        @$list = ();
    }

    my $dirHandle;

    opendir($dirHandle, $dir) || return undef;
    my @dirEntries = readdir($dirHandle);
    closedir $dirHandle;

    for my $entry (@dirEntries) {
        next if $entry =~ /^[\.]{1,2}$/;
        my $fileFullPath = $dir . "/" . $entry;
        if ( -d $fileFullPath ) {
            $list = productRootFileList($fileFullPath, $list, $rootDir)
        } else {
            next if $entry eq ariba::rc::Globals::inProgressMarker();
            next if $entry eq ariba::rc::Globals::brokenArchiveMarker();
            my $dir = quotemeta($rootDir);
            my ($fileRelativePath) = $fileFullPath =~ /^$dir\/(.*)/;
            push(@$list, $fileRelativePath);
        }
    }

    return $list;
}

#
# Kind of equivalent to Properties.load(InputStream) in Java
# Returns a hashtable reference.
#
sub hashFromFile
{
   my($propertyFile, $separator, $commentMarker) = @_;
   my %propertyHash;
   
   my $fh = new FileHandle $propertyFile;
   return hashFromFileHandle($fh,$separator,$commentMarker);
} 

sub hashFromFileHandle
{
   my($fh, $separator, $commentMarker) = @_;
   my %propertyHash;
   $separator ||= "=";  
   $commentMarker ||= "#";
  
   return undef unless $fh;
   while (my $line = $fh->getline()) {
       $line =~ s/${commentMarker}.*//o;
       $line =~ s/^\s+//;
       $line =~ s/\s+$//;
       next unless $line =~ s/$separator/ /o;
       my ($key, $value, $junk) = Text::ParseWords::parse_line('\s+', 0, $line);
       next if !defined($value) || $junk;
       $propertyHash{$key} = $value;
   }
   return \%propertyHash;
}

sub transferFromSrcToDestNoCheck
{
    my(
        $src, $suser,
        $srcroot, $srcdir,
        $dst, $duser,
        $dstroot, $dstdir,
        $compress, $bg,
        $incremental, $password,
        $retOutputRef, $hardLinkSrc,
        $checksum, $excludeProgressMarker,
        $filesFrom, $nohardlinks, $useDelete)=@_;
    my $ret = 0;

    #print "Copying from $src:$srcroot/$srcdir to $dst:$dstroot/$dstdir\n";

    if ($debug) {
        print "srchost = $src\n" if ($src);
        print "srcuser = $suser\n" if ($suser);
        print "srcroot = $srcroot\n" if ($srcroot);
        print "srcdir = $srcdir\n" if ($srcdir);
        print "dsthost = $dst\n" if ($dst);
        print "dstuser = $duser\n" if ($duser);
        print "dstroot = $dstroot\n" if ($dstroot);
        print "dstdir = $dstdir\n" if ($dstdir);
        print "nohardlinks = $nohardlinks\n" if ($nohardlinks);
    }
    my $rsync = rsyncCmd();
    my $rsyncFlags = "-e " . sshCmd() . " --archive -O"; # the -O flag is used to not try setting timestamp on NFS directory
    $rsyncFlags .= " --delete" if $useDelete;
    unless ($nohardlinks) {
        $rsyncFlags .= " --hard-links";
    }

    #
    # for NT
    #
    my $rsh = sshCmd();
    my $rcp = scpCmd() . " -r";
    my $cp = cpCmd() . " -pr";

    $bg = 0 if (onNT()); 
    #
    # Set flags to allow for compressed and incremental pushes
    #
    if (defined($compress) && $compress) {
        $rsyncFlags .= " --compress";
    } 

    if (defined($checksum) && $checksum) {
        $rsyncFlags .= " --checksum";
    }
    
    #
    # incremental flag allows copying files from multiple source
    # dirs into a single dest dir. If this flag is not set, make
    # sure we remove files that are not on the source side, and
    # make sure that both source and dir are in sync
    #
    if (!defined($incremental) || !$incremental) {
        $rsyncFlags .= " --delete --delete-during";
    }

    if (defined($excludeProgressMarker) && $excludeProgressMarker) {
        $rsyncFlags .= " --exclude /" . ariba::rc::Globals::inProgressMarker();
        $rsyncFlags .= " --exclude /" . ariba::rc::Globals::brokenArchiveMarker();
    }

    my $additionalFlags = $ENV{'ARIBA_RSYNC_FLAGS'};
    $rsyncFlags .= " $additionalFlags" if ($additionalFlags);

    if (defined $dstdir && $dstdir ne $srcdir) {
        #
        # Copy the content of directory. 
        # TODO: can lead to 3 problems:
        # - if '*' expands to something huge, we may run out of
        #   commandline length.
        # - if srcdir happens to be a file, srcdir/* will not work
        # - if not doing an incremental copy over, we may have cruft
        #   files in destination directory from previous copies.
        #
        # Take this shortcut to avoid something like:
        # "ssh rm -fr dstdir; tar cf - srcdir | (cd dstroot; tar xf -);
        #                                      rm -fr srcdir"
        #
        #
        $srcroot = "$srcroot/$srcdir" if ($srcdir);
        $srcdir = undef;
        $dstroot = "$dstroot/$dstdir";
        $dstdir = undef;
    } else {
        if ($srcdir) {
            my $srcDirHead = dirname($srcdir);
            if ($srcDirHead ne ".") {
                $dstdir = "$srcDirHead/";
            }
        }
    }

    my $finalSrc = "$srcroot/";
    my $finalDst = "$dstroot";
    my $linkDest = $hardLinkSrc;

    if ($srcdir) {
        $finalSrc .= "$srcdir";
    }

    if ($dstdir) {
        $finalDst .= "/$dstdir";
        $linkDest .= "/$dstdir" if ($linkDest);
    }

    if (defined($hardLinkSrc) && $hardLinkSrc) {
        $rsyncFlags .= " --checksum --link-dest=$linkDest";
    }

    $rsyncFlags .= " --files-from $filesFrom" if ($filesFrom);

    my ($localHost, $localUser);
    my ($from, $ntfrom, $to, $ntto, $ntPreCommand, $ntCopyCommand);

    if (onNT()) {
        $localHost = $ENV{'COMPUTERNAME'};
    } else {
        $localHost=`uname -n`;
        chop $localHost;
    }
    $localHost =~ s,([^\.]*)\..*,$1,;
    $localUser = $ENV{'USER'};

    if (defined $src && defined $dst) {
        my $host;

        $src =~ m|([^\.]*)|;
        $host = $1;
        if ($host eq $localHost && $suser eq $localUser) {
            $src = undef;
        } 

        $dst =~ m|([^\.]*)|;
        $host = $1;
        if ($host eq $localHost && $duser eq $localUser) {
            $dst = undef;
        }

        if (defined($src) && defined($dst)) {
        die "ERROR: remote to remote copy not supported\n",
            "  from: $suser\@$host:$finalSrc\n",
            "  to: $duser\@$host:$finalDst\n";
        }

    } 

    #
    # Either source, or destination, or both are local
    #
    $ntCopyCommand = $cp;
    if (defined ($src)) {
        $from = "$suser\@$src:$finalSrc";
        $ntfrom = "$src.$suser:$finalSrc";
        $ntCopyCommand = $rcp;

        $src =~ m|([^\.]*)|;
        $finalSrc = "$suser\@$1:$finalSrc";

        $password = ariba::rc::Passwords::lookup($suser) unless defined $password;
    } else {
        $from = $finalSrc;
        $ntfrom = $finalSrc;

        $finalSrc = "$localUser\@$localHost:$finalSrc";
    }

    if (defined ($dst)) {
        $to = "$duser\@$dst:$finalDst";
        $ntto = "$dst.$duser:$finalDst";
        $ntPreCommand = "$rsh $dst -l $duser " . mkdirCmd() . " -p $finalDst";
        $ntCopyCommand = $rcp;

        $dst =~ m|([^\.]*)|;
        $finalDst = "$duser\@$1:$finalDst";

        $password = ariba::rc::Passwords::lookup($duser) unless defined $password;
    } else {
        $to = $finalDst;
        $ntto = $finalDst;
        $ntPreCommand = mkdirCmd() . " -p $finalDst";

        $finalDst = "$localUser\@$localHost:$finalDst";
    }

    my $command;

    $command="$rsync $rsyncFlags $from $to";

    if ($finalSrc ne $finalDst) {
        if (onNT()) {
            $ret = r($ntPreCommand) == 0 &&
            r("$ntCopyCommand $from $to") == 0;
        } else {
            if( ! defined($src) && ! defined($dst) ) {
                $ret = executeLocalCommand($command, $bg);
            } else {
                $ret = executeRemoteCommand($command, $password, $bg, undef, undef, $retOutputRef);
            }
        }
    } else {
        print "Loopback push to $finalSrc skipped.\n" unless $main::quiet;
        $ret = 1; #already transferred.
    }

    return $ret;
}

sub removePath 
{
    my($dst,$duser,$dstroot,$dstdir,$bg)=@_;
    my $command;
    # check if destination exists, if it does not exist, it is a no op.
    if (!checkSource($dst,$duser,$dstroot,$dstdir)) {
        return 1;
    }

    my $password = "";
    my $ret;
    if (defined $dst) {
        $command = qq!$ssh $dst -l $duser "cd $dstroot; $chmod -R 755 $dstdir; $rm -rf $dstdir"!;
        $password = ariba::rc::Passwords::lookup($duser);
        $ret = executeRemoteCommand($command, $password, $bg);
    } else {
        $command = qq!cd $dstroot; $chmod -R 755 $dstdir; $rm -rf $dstdir!;
        $ret = executeLocalCommand($command, $bg);
    }

    return $ret;
}

sub flush 
{
    local *FD = shift;

    my $oldfd = select(FD);
    my $oldstate = $|;
    $| = 1;
    print '';
    $| = $oldstate;
    select($oldfd);
}

sub unbuffer
{
    local *FD = shift;

    my $oldfd = select(FD);
    $| = 1;
    select($oldfd);
}

sub connectStringForSidOnHost 
{
    my ($sid, $host) = @_;

    return $sid unless($host);

    my $string = "(description=(address=(host=$host)".
                    "(protocol=tcp)(port=1521))(connect_data=".
                    "(sid=$sid)))";
    return ($string);
}

sub refreshSudoPrompt
{
    my $user = shift();

    my $pass = ariba::rc::Passwords::lookup($user);

    refreshSudoPromptWithPassword($user, $pass);
}

sub refreshSudoPromptWithPassword
{
    my $user = shift();
    my $pass = shift();
    my $quiet = shift();

    ## I'm going to comment this out, can't think of a reason we should limit this to once but I'll leave it here
    ## for historical reasons
    #return if ($alreadyRefreshedSudo++) || onNT();

    my $sudo = sudoCmd();

    #this can cause race condition when refreshSudoPromptWithPassword()
    #is invoked concurrently. One process may think that it has
    #refreshed the prompt and can do sudo operations, only to have
    #another process come along and expire the sudo access
    #r("$sudo -k");

    my $redirect = "";
    if ($quiet) {
        $redirect = ">/dev/null 2>&1";
    }

    open(SUDO, "| $sudo -v -S -p \"Enter %u's Password:\"$redirect");
    print SUDO "$pass\n";
    close(SUDO);
}

sub sharedLibEnvName
{
    my $os = shift;

    $os = $^O if !defined($os);

    if ( ($os eq 'hpux') || ($os eq 'hp-ux') ) {
        return 'SHLIB_PATH';
    } else {
        return 'LD_LIBRARY_PATH';
    }
}

sub setBuildEnvironment
{
    my ($quiet) = @_;

    #
    # set ORACLE_HOME based on the version of ORACLE client libraries
    # declared by the product.
    #
    my $oraRoot = -d "/usr/local/oracle" ? "/usr/local/oracle" : "/opt/oracle";
    if (defined($ENV{'ARIBA_ORA_VERSION'})) {
    my $oraVerRoot = $oraRoot . "." . $ENV{'ARIBA_ORA_VERSION'};
    if (-d $oraVerRoot) {
        $oraRoot = $oraVerRoot;
    }
    }

    if (ariba::rc::Utils::onNT()) {
    #
    # Set root location of various tools. As these could be in nonstandard
    # location on NT.
    #
    my %toolsLocations = (
        'MSSQL70ROOT'   => ['C:/mssql7',   'D:/mssql7'],
        'WINRUNNERROOT' => ['C:/WinRunner','D:/WinRunner'],
        'ORACLE_HOME'   => ['C:/orant',    'D:/orant',
                'C:/ora816',   'D:/ora816'],
        'JDK118ROOT'    => ['C:/jdk1.1.8',     'D:/jdk1.1.8',
                'C:/jdk1.1.8-sun', 'D:/jdk1.1.8-sun',
                'C:/jdk-sun-1.1.8','D:/jdk-sun-1.1.8'],
        'JDK122ROOT'    => ['C:/jdk1.2.2',     'D:/jdk1.2.2',
                'C:/jdk1.2.2-sun', 'D:/jdk1.2.2-sun',
                'C:/jdk-sun-1.2.2','D:/jdk-sun-1.2.2'],
        'JDK131ROOT'    => ['C:/jdk1.3.1',     'D:/jdk1.3.1', 
                    'C:/jdk1.3',       'D:/jdk1.3', 
                    'C:/jdk1.3.1-sun', 'D:/jdk1.3.1-sun',
                    'C:/jdk-sun-1.3.1','D:/jdk-sun-1.3.1'],
        'IBMJAVA13ROOT' => ['C:/ibmjava13',    'D:/ibmjava13', 
                    'C:/jdk1.3.0-ibm', 'D:/jdk1.3.0-ibm',
                    'C:/jdk-ibm-1.3.0','D:/jdk-ibm-1.3.0'],
        'MSSDK31ROOT'   => ['C:/SDK-Java.31',  'D:/SDK-Java.31'],
        'VCAFE40ROOT'   => [
                'C:/VisualCafe4',   'D:/VisualCafe4',
                'C:/VisualCafe40', 'D:/VisualCafe40',
                            'C:/VisualCafe',   'D:/VisualCafe',
                   ],
        'NEXT_ROOT'     => [
                'C:/Apple.5.1', 'C:/Apple5.1',
                'D:/Apple.5.1', 'D:/Apple5.1',
                'C:/Apple', 'D:/Apple',
                   ],
        );

    for my $root (keys(%toolsLocations)) {
        my $possibleLocations = $toolsLocations{$root};
        for my $loc (@$possibleLocations) {
        if (-d $loc) {
            print "Warning: Overriding $root = $ENV{$root} with $loc\n"
                        if ($ENV{$root} && !$quiet);
            $ENV{$root} = $loc;
            last;
        }
        }
        if (!$ENV{$root}) {
        print "Warning: could not locate $root in: ".
              join(", ", @$possibleLocations) . "\n";
        }
    }
    $oraRoot = $ENV{'ORACLE_HOME'};
    } else {
    $ENV{'ORACLE_HOME'} = $oraRoot;

    #
    # Use WO only if product declares it, also used the specified
    # version of WO
    #
    $ENV{'NEXT_ROOT'} = "/tmp";
    if (defined $ENV{'ARIBA_WO_VERSION'}) {
        $ENV{'NEXT_ROOT'} = "/opt/Apple";
        if ( $ENV{'ARIBA_WO_VERSION'} != 4.0 ) {
        $ENV{'NEXT_ROOT'} .= ".$ENV{'ARIBA_WO_VERSION'}";
        }
    }
    }

    #
    # Set temporary dir, used by apple tools.
    #
    if (defined($ENV{'TEMP'})) {
    $ENV{"TEMP"} =~ s,/,\\,g;
    $ENV{"TMPDIR"} = $ENV{"TEMP"};
    $ENV{"TMPDIR"} =~ s,\\,/,g;
    } else {
    $ENV{'TMPDIR'}="/tmp";
    }

    #
    # set PATH
    #
    # These areas need to be in path, for build to work
    #
    my ($pathSep, @platformPaths);

    if (ariba::rc::Utils::onNT()) {
    @platformPaths = ( "C:/Perl/bin",
               "D:/Perl/bin",
               "$ENV{'ROOTDIR'}/mksnt",
               "$ENV{'SystemRoot'}/System32",
               "C:/Program Files/Perforce",
               "C:/Perforce",
               "D:/Program Files/Perforce",
               "D:/Perforce",
             );
    $pathSep = ";";
    } else {
    @platformPaths = ( "/usr/local/bin",
               "/bin",
               "/usr/bin",
               "/usr/ucb",
               "/usr/ccs/bin",
               "/usr/sbin",
               "/usr/local/sbin",
              );
    $pathSep = ":";
    }
    my @pathComponents = ( "." );

    if ($^O ne 'linux' && 
        (! defined $ENV{'ARIBA_NETWORK_TOOLS_ROOT'} ||
        ! -e "$ENV{'ARIBA_NETWORK_TOOLS_ROOT'}/bin/mp2"))
    {
        push @pathComponents, ("$ENV{'NEXT_ROOT'}/Developer/Executables",
                               "$ENV{'NEXT_ROOT'}/Library/Executables",
                               );
    }

    push @pathComponents, (@platformPaths,
               "$ENV{'ARIBA_TOOLS_ROOT'}/bin",
               "$ENV{'ARIBA_SHARED_ROOT'}/bin",
               "$ENV{'ORACLE_HOME'}/bin",
            );
    push(@pathComponents, "$ENV{'ARIBA_NETWORK_TOOLS_ROOT'}/bin")
        if $ENV{'ARIBA_NETWORK_TOOLS_ROOT'};

    $ENV{'PATH'}="";
    for my $pathComponent (@pathComponents) {
    if (-d $pathComponent) {
        $pathComponent =~ s|/|\\|go if (ariba::rc::Utils::onNT());
        $ENV{'PATH'} .= "$pathComponent$pathSep";
    }
    }

    #
    # PHP home is needed to be in the path for community product (drupal based)
    # We do it here separately as the PHP Home might dir might not exist at the time of setting the
    # build environment (in the case of community product php is built as part of the product build)
    #
    if ($ENV{'PHP_HOME'}) {
        my $PHPPath = "$ENV{'PHP_HOME'}/bin";
        $PHPPath =~ s|/|\\|go if (ariba::rc::Utils::onNT());
        $ENV{'PATH'} .= "$PHPPath$pathSep";
    }


    chop($ENV{'PATH'});


    #
    # Following frameworks need to be in LD_LIBRARY_PATH for build
    # to work (because of other code depending on it, during build
    # time)
    #
    if (!ariba::rc::Utils::onNT()) {
    my @ld_library = ( 
           "Library/Executables",
           "Library/Frameworks/Foundation.framework",
               );
    $ENV{'LD_LIBRARY_PATH'} = "";
    for my $ld (@ld_library) {
        if (-e "$ENV{'NEXT_ROOT'}/$ld") {
        $ENV{'LD_LIBRARY_PATH'} .= "$ENV{'NEXT_ROOT'}/$ld$pathSep";
        }
    }
    $ENV{'LD_LIBRARY_PATH'} .= "$ENV{'ORACLE_HOME'}/lib";
    $ENV{'LD_LIBRARY_PATH'} .= "$pathSep/usr/local/lib";
    } 

    $ENV{'ARIBA_CONFIG_ROOT'} = "$ENV{ARIBA_SERVICE_ROOT}/service/config" 
                    unless(defined $ENV{ARIBA_CONFIG_ROOT});
    $ENV{"BUILDNAME_FILE"} = "$ENV{ARIBA_CONFIG_ROOT}/BuildName";
}

sub nextBuildNameForCustomer {
    my $prodname = shift();
    my $customer = shift();

    my $p4Dir = ariba::rc::Globals::aspCustomerModsRootForProduct($prodname, $customer);

    my $cmd = "/usr/local/bin/p4 print -q $p4Dir/config/BuildName";

    my $buildName = `$cmd`;
    chop($buildName);

    my ($build, $num) = ariba::rc::Globals::stemAndBuildNumberFromBuildName($buildName);
    my $nextBuildName = "$build-" . ++$num;

    return $nextBuildName;
}

sub getCustomerNameFromP4 {
    my ($customer, $prodname) = (@_);

    open(F, "/usr/local/bin/p4 files //ariba/services/$prodname/customers/$customer/config/CustomerName |");

    my $line = <F>;
    close(F);

    unless($line) {
        return("");
    }

    if($line =~ m|customers/([^/]+)/config|) {
        return($1);
    }

    return(""); # should never happen, but let's be careful
}

sub redirect_to_log {
    my ($logdir, $logbase, $quiet) = (@_);

    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)
                    = localtime(time);

    $year += 1900;
    $mon++;
    $mon = "0". $mon if ($mon < 10);
    $mday = "0". $mday if ($mday < 10);
    $hour = "0". $hour if ($hour < 10);
    $min = "0". $min if ($min < 10);
    $sec = "0". $sec if ($sec < 10);

    require IO::Tee;

    my $logfile = "$logdir/${logbase}$year$mon$mday-$hour$min$sec" ;

    mkpath($logdir) unless (-d $logdir);

    print "$logbase: Logging output to $logfile\n";


    my @fileHandles = ( new IO::File(">$logfile") );

    push (@fileHandles, \*STDOUT) unless ($quiet);

    return new IO::Tee(@fileHandles);
}

sub getTimingInfoLogFile {
    my ($product, $service, $buildname) = @_;

    return $ENV{'TIMINGLOGFILE'} if $ENV{'TIMINGLOGFILE'};
    return undef unless defined($product) and defined($service) and defined($buildname);
    return $ENV{'HOME'} . "/logs/$product/timing-$service-$buildname";
}

sub writeTimingInfo {
    my ($timelog, $action, $type, $starttime) = @_;

    return unless defined( $timelog );

    my $dirname = dirname( $timelog );
    mkdirRecursively( $dirname ) unless ( -d $dirname );

    my $timefh;
    unless( open( $timefh, ">>", $timelog ) ) {
        print "Unable to open $timelog: $!\n";
        return;
    }

    print $timefh ariba::Ops::DateTime::prettyTime(time());
    print $timefh " $type $action";
    if(defined($starttime)) {
        print $timefh " (", ariba::Ops::DateTime::scaleTime(time() - $starttime), ")";
    }
    print $timefh "\n";

    close($timefh);
}

#-------------------------------------------------------------
# Method to mark build as stable
# $value=1 is to mark as stable and 0 is to unmark
# return undef if successful else returns the error message

sub setBuildStability {
    my ($product, $branch, $buildName, $value) = @_;
    
    my $archive = ariba::rc::Globals::archiveBuilds($product);
    my $cachePath = "$archive/stable.txt";
    my $rhStable = loadStable($cachePath);

    my ($stem, $build) = lc($buildName) =~ /(.*)-(\d+.*)/;
    my $message = "";
    if ($value) {
        if ($rhStable->{$stem}{$build}) {
            $message = "$buildName was already marked stable - nothing done";
       
        } else {
            $rhStable->{$stem}{$build} = 1;
        }
    }
    else {
        if (! delete $rhStable->{$stem}{$build}) {
            $message = "$buildName is not currently marked stable - nothing done";
        }
    }
    
    if (!$message) {
        if (!saveStable($cachePath, $rhStable)) {
            $message = "update FAILED ($!) - please report this to Dept_Release!";
        }
        elsif (!setStableLink($archive, $branch, $buildName, keys %{$rhStable->{$stem}})) {
            $message = "symlink FAILED ($!) - please report this to Dept_Release!";
        }
        elsif(!setBuildAttribute($archive, $branch, $buildName, "stable", $rhStable->{$stem}{$build})) {
            $message = "creating stable build attribute in config folder FAILED ($!) -- please report this to Dept_Release !";
        }
        else {
        return undef;
        }
     }
     return $message;

}

sub loadStable {
    my ($path) = @_;
    my %stable;
    
    if (open(STABLE, $path)) {
        foreach my $line (<STABLE>) {
            my ($stem, @builds) = split(' ', $line);
            
            foreach my $build (@builds) {
                $stable{$stem}{$build} = 1;
            }
        }
        close(STABLE);
    }
    return \%stable;
}

sub saveStable {
    my ($path, $rhStable) = @_;
    open(STABLE, "> $path") || return 0;

    foreach my $stem (sort keys %$rhStable) {
        my @builds = sort { $a <=> $b } keys %{$rhStable->{$stem}};
        
        if (@builds > 0) {
            print STABLE $stem;
            print STABLE " $_" foreach @builds;
            print STABLE "\n";
        }
    }
    return close(STABLE);
}


sub setBuildLock {
    my ($product, $branch, $buildName, $value) = @_;
    
    my $archive = ariba::rc::Globals::archiveBuilds($product);
    my $cachePath = "$archive/purgeLock.txt";
    my $rhLock = loadLockedComponents($cachePath);

    my ($stem, $build) = lc($buildName) =~ /(.*)-(\d+.*)/;
    my $message = "";
    if ($value) {
        if ($rhLock->{$stem}{$build}) {
            $message = "$buildName is now Locked";
       
        } else {
            $rhLock->{$stem}{$build} = 1;
        }
    }
    else {
        if (! delete $rhLock->{$stem}{$build}) {
            $message = "$buildName is now Unlocked";
        }
    }
    
    if (!$message) {
        if (!saveLocked($cachePath, $rhLock)) {
            $message = "Lock FAILED ($!) - please report this to Dept_Release!";
        }
       
        else {
        return undef;
        }
     }
     return $message;

}

sub loadLockedComponents {
    my ($path) = @_;
    my %locked;
    
    if (open(LOCK, $path)) {
        foreach my $line (<LOCK>) {
            my ($stem, @builds) = split(' ', $line);
            
            foreach my $build (@builds) {
                $locked{$stem}{$build} = 1;
            }
        }
        close(LOCK);
    }
    return \%locked;
}

sub saveLocked{
    my ($path, $rhLocked) = @_;
    open(LOCK, "> $path") || return 0;

    foreach my $stem (sort keys %$rhLocked) {
        my @builds = sort { $a <=> $b } keys %{$rhLocked->{$stem}};
        
        if (@builds > 0) {
            print LOCK $stem;
            print LOCK " $_" foreach @builds;
            print LOCK "\n";
        }
    }
    return close(LOCK);
}

sub setAsGolden {
    my ($product, $branch, $buildName, $value) = @_;
    
    my $archive = ariba::rc::Globals::archiveBuilds($product);
    my $cachePath = "$archive/setgolden.txt";
    my $rhGolden = loadGolden($cachePath);

    my ($stem, $build) = lc($buildName) =~ /(.*)-(\d+.*)/;
    my $message = "";
    if ($value) {
        if ($rhGolden->{$stem}{$build}) {
            $message = "$buildName was set as golden - nothing done";
       
        } else {
            $rhGolden->{$stem}{$build} = 1;
        }
    }
    else {
        if (! delete $rhGolden->{$stem}{$build}) {
            $message = "$buildName is not currently set as golden - nothing done";
        }
    }
    
    if (!$message) {
        if (!saveGolden($cachePath, $rhGolden)) {
            $message = "Set as golden FAILED ($!) - please report this to Dept_Release!";
        }
       
        else {
        return undef;
        }
     }
     return $message;

}

sub loadGolden {
    my ($path) = @_;
    my %golden;
    
    if (open(GOLDEN, $path)) {
        foreach my $line (<GOLDEN>) {
            my ($stem, @builds) = split(' ', $line);
            
            foreach my $build (@builds) {
                $golden{$stem}{$build} = 1;
            }
        }
        close(GOLDEN);
    }
    return \%golden;
}

sub saveGolden{
    my ($path, $rhGolden) = @_;
    open(GOLDEN, "> $path") || return 0;

    foreach my $stem (sort keys %$rhGolden) {
        my @builds = sort { $a <=> $b } keys %{$rhGolden->{$stem}};
        
        if (@builds > 0) {
            print GOLDEN $stem;
            print GOLDEN " $_" foreach @builds;
            print GOLDEN "\n";
        }
    }
    return close(GOLDEN);
}


sub setStableLink {
    my ($archive, $branch, $build, @builds) = @_;

    # This is to untaint the value of $branch
    $branch = $1 if $branch =~ m{(.*)};

    my $suffix = ariba::rc::Globals::getLogicalNameForBranch($branch);
    my $target = "$archive/stable-$suffix";
    unlink($target);
    if (@builds) {
        #my ($latest) = sort { $b <=> $a } @builds;
        my ($stem) = $build =~ /^(.*)-\d+.*/;

        # Find out the latest stable build done from this branch
        # which has this stem
        my @suitableBuilds;
        foreach my $buildNum (@builds)
        {
            my $buildName = "$stem-$buildNum";
            my $configDir = "$archive/$buildName/config";
            my $branchName = getBranchName($configDir);
            push (@suitableBuilds, $buildNum) if ( lc($branchName) eq lc($branch) );
        }
        
        my ($latest) = sort { $b <=> $a } @suitableBuilds;
        my $source = "$archive/$stem-$latest";
        symlink($source, $target) || return 0;
    }
    return 1;
}

# This creates a attribute file for deployments.
# In future if we want to extend this for other attributes like
# blessed-for-prod, we need to remove unlink and just delete attribute from file.
sub setBuildAttribute {
    my ($archive, $branch, $build, $attr, $stable) = @_;
    my $file = "$archive/$build/config/buildattributes.txt";
    
    if($stable) {
        open(FH, "> $file") || return 0;
        FH->print("$attr \n");
        close(FH);
    }else{
        unlink($file);
    }
    return 1;
}

# Generate unique filename when removing a directory
sub getTrashDir {
    my ($dir) = @_;
    ++$trash;
    return join ".", "_trash", $dir, Time::HiRes::time(), $trash, $$;
}

#
# pretty-print product name to hide deprecated names
#
my %REWRITE = ( 'asm' => 's4', 'buyer' => 'ssp' );

sub rewrite_productname {
    my ($productname) = @_;

    foreach my $key (keys %REWRITE) {
        my $val = $REWRITE{$key};
        $productname =~ s/$key/$val/gm;
    }

    return $productname;
}

#
# generic harness to retry a subroutine n times
#
# given:
# - number of retries to attempt
# - problem in the form of a regexp that appears in $@
# - reference to a subroutine
#
# then:
# attempt to call the subroutine n times checking
# for the named problem. give up when we have 
# reached the maximum # of retries or if an unexpected
# error occurs.
#
# example:
# my $ok = ariba::rc::Utils::retry (10, "resource unavailable", sub { whatever });
#
sub retry {
    my ($retries, $problem, $func) = @_;
    attempt: {
        my $result;

        # return true if successful
        return 1 if eval { $result = $func->(); 1 };

        # failed: something bad happened other than what we expected
        return 0 unless $@ =~ /$problem/;

        # stop trying
        last attempt if $retries < 1;

        # sleep for 0.1 seconds, and then try again.
        Time::HiRes::sleep (0.1);
        $retries--;
        redo attempt;
    }
    return 0;
}

sub sharedTempDir {
    my $configDir = shift;
    my $sharedTempDir;
    if (-r "$configDir/Parameters.table") {
        my $params = ariba::Ops::PropertyList->newFromFile("$configDir/Parameters.table");
        $sharedTempDir = $params->valueForKeyPath("System.Base.SharedTempDirectory");
    }
    return $sharedTempDir;
}

sub allowCQConfig {
    my $productName = shift;
    my $serviceName = shift;

    ### Allow using CQ specific config if following is true:
    ### - Should never be true for Production.
    ### - Currently, true only for devlab/opslab/personal_robot.
    ### - True only for buyer/s4 products.
    ### Whether CQ specific config exists will be determined
    ### by caller of this function.
    my @devlabServices = ariba::rc::Globals::servicesForDatacenter('devlab');
    my @opslabServices = ariba::rc::Globals::servicesForDatacenter('opslab');
    if (($productName eq "buyer" || $productName eq "s4") &&
        ((grep /^$serviceName$/, @devlabServices) ||
        (grep /^$serviceName$/, @opslabServices) ||
        (ariba::rc::Globals::isPersonalService($serviceName))) ) {
        return 1;
    }
    return 0;
}

# Translate the supplied opsconfiglabel references to default or current to a P4 revspec
# Input 2: buildname - name of build
# Return undef on error
# Return the same value as the supplied opsConfigLabel when not equal to current or default
sub translateOpsConfigLabel {
    my $opsConfigLabel = shift;
    my $buildname = shift;

    if ($opsConfigLabel) {
        if ($opsConfigLabel eq "default") {
            # translate to a Perforce date time revspec at the time of the archive build
            my $cmd = "p4 labels -e $buildname -t";
            my $out = qx "$cmd";
            my $ret = $?;
            my $ret2 = $ret >> 8;
            if ($ret2) {
                print "ERROR: The opsconfiglabel default cannot be resolved: The timestamp relating the the Perforce label $buildname is not found\n";
                return undef;
            }
            # Result is like:
            # Label SSPR3-239 2013/02/15 00:14:03 'Created by rc: Release build on 2013/02/15. '
            my @out2 = split(' ', $out);
            my $datetok = $out2[2];
            my $timetok = $out2[3];

            $opsConfigLabel = $datetok . ":" . $timetok;

            print "Translated the opsconfiglabel from current to $opsConfigLabel\n";
        }
        elsif ($opsConfigLabel eq "current") {
            # translate to a Perforce date time revspec at the current time (format is yyyy/mm/dd:hh:mm:ss)
            $opsConfigLabel = POSIX::strftime("%Y/%m/%d:%H:%M:%S", localtime);
            print "Translated the opsconfiglabel from current to $opsConfigLabel\n";
        }
        return $opsConfigLabel;
    }
    return undef;
}

# The build config contains a BranchName file.
# The value in this file is a p4 depot path.
# There are no real conventions for the values defined in that file.
# This routine does the best it can to come up
# with an identifier sans "/" separator characters
# so the id (branch part) can be used to identify the branch.
#
# The branch part is extracted like from the first matching pattern:
# .../build/<branchpart>/...
# .../branch/.../<branchpart>
# .../ond/<product>/<branchpart>
# .../release/<product>/<branchpart>/...
# Otherwise undef is returned (no branch)
sub formatBranchPart {
    my ($branchPath) = @_;

    chomp $branchPath;

    if ($branchPath =~ /\/build\//) {
        # Could be Like "//ariba/ond/buyer/build/rel"
        # or "//ariba/sandbox/build/rmauri_nc/buyer"

        my @toks = split(/\/build\//, $branchPath);
        my $branchPart = $toks[-1]; # Like "rel" or "rmauri_nc/buyer"

        @toks = split(/\//, $branchPart);
        $branchPart = $toks[0]; # Like "rel" or "rmauri_nc"
        return $branchPart;
    }
    if ($branchPath =~ /\/branch\//) {
        # Could be Like "//ariba/services/webserver/branch/mws/rel"
        my @toks = split(/\/branch\//, $branchPath);
        my $branchPart = $toks[-1]; # Like "mws/rel"
        @toks = split(/\//, $branchPart);
        $branchPart = $toks[-1]; # Like "rel"
        return $branchPart;
    }
    if ($branchPath =~ /\/ond\//) {
        # Could be Like "//ariba/ond/AN/rel" or "//ariba/ond/spotbuy/rel"
        my @toks = split(/\/ond\//, $branchPath);
        my $branchPart = $toks[-1]; # Like "AN/rel"
        @toks = split(/\//, $branchPart);
        $branchPart = $toks[-1]; # Like "rel"
        return $branchPart;
    }
    if ($branchPath =~ /\/release\//) {
        # Could be Like //ariba/community/release/0.1Rel/main or //ariba/services/release/logi/1.0 or //ariba/cxml/release/CXML/1.2.28
        my @toks = split(/\/release\//, $branchPath);
        my $branchPart = $toks[-1]; # Like "CXML/1.2.28"
        @toks = split(/\//, $branchPart);
        $branchPart = $toks[-1]; # Like "1.2.28"
        return $branchPart;
    }
    return undef;
}

# Handy utility to use for testing
sub stacktrace {
    my $i = 1;
    print STDERR "Stack Trace:\n";
    while ( (my @call_details = (caller($i++))) ){
        print STDERR $call_details[1].":".$call_details[2]." in function ".$call_details[3]."\n";
    }
}

# Read a line from stdin.  If a blank <return> is enterned return the optional default.
sub promptWithDefault {
    my $prompt     = shift;
    my $default    = shift;
    my $skipPrompt = shift;

    if ($skipPrompt) {
        return $default;
    }

    my $ans;
    print "$prompt";

    if ($default) {
        print " [$default]";
    }

    print ": ";

    chop( $ans = <STDIN> );

    $ans = $default unless ($ans);

    return ($ans);
}

1;
