package ariba::rc::JavaPkgToCompsIndexer;

#
# JavaPkgToCompsIndexer
#
# This index is used by the IncrBuildMgr metadata validation system.
# This index associates the Java packages published by an Ariba component.
#
# The index is named pkgtocomps.txt and is located in a directory controlled by the caller
# Each line in the file looks like "package.name aribacompname"
# There may be multiple lines with the same package name - we call these "ambiguous".
#
# Not thread safe - the old pkgtocomps.txt will be replaced by a new copy
# There is no provision at this time for two processes performing an update on this file simultaneously.
#
# Usage:
# my $resultHashRef = ariba::rc::javaPkgToCompsIndexer->new("path to pkgtocomps.txt file", $compMetaReference)
# my %resultHash = %$resultHashRef;
# my $returnCode = $resultHash('returnCode');
# if ($returnCode == 0) {
#     my $addedPackagesRef = $resultHash{'add'};
#     my $deletedPackagesRef = $resultHash{'delete'};
# }
use strict;
no warnings 'recursion';
use Data::Dumper;
use ariba::rc::CompMeta;

my $ARIBA_SHARED_ROOT = $ENV{'ARIBA_SHARED_ROOT'};
my $ARIBA_SOURCE_ROOT = $ENV{'ARIBA_SOURCE_ROOT'};
my $ARIBA_INSTALL_ROOT = $ENV{'ARIBA_INSTALL_ROOT'};
my $JAVA_HOME = $ENV{'JAVA_HOME'};

my $javaPackagePattern = '^\s*package\s+([A-Za-z0-9._-]*)';

#
# Constructor
#
# Input 1: $compMeta reference to a CompMeta that describes the contribution to update the index with
# Input 2: $indexFilePath path to the directory containing the pkgtocomps.txt file
sub new {
    my $class = shift;
    my $compMeta = shift;
    my $indexFilePath = shift;
    my $self = {};
    bless ($self, $class);

    if (defined $indexFilePath) {
        $self->{'indexFilePath'} = $indexFilePath;
    }

    if (defined $compMeta) {
        $self->{'compMeta'} = $compMeta;
    }

    return $self;
}

# Input 1: $flag 0 to disable debug printing; 1 to enable it
sub setDebug {
    my ($self, $flag) = @_;

    $self->{'debug'} = $flag;
}

# Create the pkgtocomps.txt index so that the packages published by all components
# under the source path declared in the CompMeta.
# It is intended that this be run rarely like at times of performing full RC builds
# The IncrBuildMgr uses the updateIndex API to update the index quickly
#
# Input 1: reference to list of CompMeta
# Input 2: name of directory that will be updated to contain pkgtocomps.txt
# Returns: 0 if success; other values == failure
sub createIndexForProductUniverse {
    my ($compMetaListRef, $indexFileDir) = @_;

    if (! -d $indexFileDir) {
        my $cmd = "mkdir $indexFileDir";
        my $ret = system($cmd);
        if ($ret != 0) {
            die "JavaPkgToCompsIndexer: ERROR : The Java package to comp index directory could not be created. The command was \"$cmd\"\n";
        }
    }

    my $indexFilePath = "$indexFileDir/pkgtocomps.txt";
    if (-e $indexFilePath) {
        my $cmd = "rm -f $indexFilePath";
        my $ret = system($cmd);
        if ($ret != 0) {
            die "JavaPkgToCompsIndexer: ERROR : Could not delete the old Java package To comp index file. The command was \"$cmd\"\n";
        }
    }
    my $cmd = "touch $indexFilePath";
    my $ret = system($cmd);
    if ($ret != 0) {
        die "JavaPkgToCompsIndexer: ERROR : The Java package to comp index file could not be touched. The command was \"$cmd\"\n";
    }

    my %map = ();
    my $us = scalar @$compMetaListRef;
    print "\nJavaPkgToCompsIndexer: Begin Generating full Java package to Ariba comp index for $us components in the universe.\n";
    for my $cm (@$compMetaListRef) {
        my $srcPath = $cm->getSrcPath();
        if (!defined $srcPath) {
            die "JavaPkgToCompsIndexer: ERROR : The List of CompMeta does not include the srcPath for component \"" . $cm->getName . "\"\n";
        }
        print ".";
        unless ($cm->isMarkedAsHubDoNotIndex()) {
            my %packages = ();
            _updatePackageListForComponent($cm, $srcPath, \%packages, 0);
            my $cn = $cm->getName();
            $map{$cn} = \%packages;
        }
    }

    # Now generate the file in one batch pass
    my $inf = "$indexFileDir/pkgtocomps.txt";
    open(OUTPUTFILE, ">$inf");
    for my $cn (keys %map) {
        my $pkgsetref = $map{$cn};
        for my $pkg (keys %$pkgsetref) {
            my $line = "$pkg $cn\n";
            print OUTPUTFILE $line;
        }
    }
    close(OUTPUTFILE);

    print "\nJavaPkgToCompsIndexer: Done Generating full Java package to Ariba comp index\n";
}

# Find the set of package names for a component and update $packagesSetRef
#
# Input 1: reference to a CompMeta
# Input 2: directory to search under for Java packages for the component described by the CompMeta
# Input 3: reference to a set (hash key==value) of package names
# Input 4: Scalar if true we've sen a Project.mk already so don't consider subdirs that also have Project.mk (AN hierarchical filter)
sub _updatePackageListForComponent {
    my ($compMetaRef, $dir, $packagesSetRef, $foundProjectMK) = @_;

    my $foundSubProjectMK = 0;

    if ($foundProjectMK) {
        opendir(DIR, $dir) || die("Cannot open directory \"$dir\"\n");
        for my $f (readdir(DIR)) {
            if ($f =~ m/Project.mk/) {
                $foundSubProjectMK = 1;
                last;
            }
        }
        closedir(DIR);
    }

    my @dirs = ();
    my $foundPkgInThisDir = 0;

    opendir(DIR, $dir) || die("Cannot open directory \"$dir\"\n");
    for my $f (readdir(DIR)) {
        next if ($f =~ m/^\./);

        my $fullpath = "$dir/$f";

        if (-d $fullpath) {
            if (! $foundSubProjectMK) {
                # Any subdirectories must be searched so long as they are not under a secondary project
                push (@dirs, $fullpath);
            }
#            else {
#                print "\nJavaPkgToCompsIndexer: INFO: Skipping secondary project subdirectory $fullpath\n";
#            }
        }
        elsif ($f =~ m/Project.mk/) {
            $foundProjectMK = 1;
        }
        elsif ((! $foundPkgInThisDir) && (! $foundSubProjectMK) && ($f =~ m/.java$/)) {
            # We found a java file for the first time in this directory.
            #
            # There are cases like in AN where there are nested projects in a hierarchical directory structure
            # like Util\ contining a subdirectory core\. These contain Project.mk that define project names
            # 'Util' and 'CoreUtil' respectively.
            #
            # When we are building up Java package to component mapping information, we have to be mindful
            # that when associating packages for components like 'Util' that sub components like 'CoreUtil'
            # do not get included else we will end up with incorrect 'Ambiguous package mappings'
            #
            # In this implmentation, if we find a Project.mk for the second and subsequent times,
            # then we will not associate the Java package for those secondary components.
            open(INPUTFILE, "<" . $fullpath);
            while(<INPUTFILE>) {
                my($line) = $_;
                chomp($line);

                if ($line =~ /$javaPackagePattern/) {
                    my @rhslist = ($line =~ /$javaPackagePattern/);
                    $packagesSetRef->{$rhslist[0]} = $rhslist[0];
                    # We don't have to look in this directory anymore as all the .java are in the same package
                    $foundPkgInThisDir = 1;
                    last;
                }
            }
            close(INPUTFILE);
        }
    }

    if ($#dirs >= 0) {
        for my $d (@dirs) {
            # Keep searching the component's directory tree looking for .java files
            _updatePackageListForComponent($compMetaRef, $d, $packagesSetRef, $foundProjectMK);
        }
    }
    closedir(DIR);
}

# Update the pkgtocomps.txt index so that the packages published by the component we are
# considering will be reflected in the index.
#
# Input 1: reference to a set of package names associated with the CompMeta described by this instance.
# If not defined, the package set will be determed by introspecting via DependencyEmitter -internal
#
# Return reference to a hash with entries:
#   key 1: 'add'    value 1: reference to a list of Java package names that were added
#   key 2: 'delete' value 2: reference to a list of Java package names that were deleted
#   key 3: 'returnCode' value == 0 is success; otherwise it's a failure where add/delete may be undef
sub updateIndex {
    my ($self, $setref) = @_;

    my $cn = $self->{'compMeta'}->getName();

    my %resultHash = ();

    my $inf = "$self->{'indexFilePath'}/pkgtocomps.txt";

    unless (-e $inf) {
        $resultHash{'returnCode'} = 1;
        return \%resultHash;
    }

    if (! defined $setref) {
        $setref = $self->_getSetOfPackagesFromDependencyEmitter();
    }

    if (! defined $setref) {
        print "JavaPkgToCompsIndexer: WARNING : There are no Java packages for component $cn\n";
        my %set = ();
        $setref = \%set;
    }

    my @addList = ();
    $resultHash{'add'} = \@addList;

    my @deleteList = ();
    $resultHash{'delete'} = \@deleteList;

    my $outf = "$inf-new";

    open(INPUTFILE, "<$inf");
    open(OUTPUTFILE, ">$outf");

    # First we filter out all the "package to component" lines relating to the component
    while(<INPUTFILE>) {
        my($line) = $_;
        chomp($line);
        if (! ($line =~ m/ $cn$/)) {
            print OUTPUTFILE "$line\n";
        }
        else {
            my @tokens = split(' ', $line);
            my $pkg = $tokens[0];

            my $val = $setref->{$pkg};
            if (! defined $val) {
                # The package was removed ; capture that fact for reporting purposes
                push (@deleteList, $pkg);
            }
            else {
                # the package was not removed or added (unchanged)
                # We remove it from the set now so as to be able to compute what the additions were.
                # Entries that remain in the %set are new additions
                delete $setref->{$pkg};
            }
        }
    }

    # next we add the new associations for the component
    my $updateStr = "";
    foreach my $p (keys %{$setref}) {
        $updateStr = $updateStr . "$p $cn\n";
    }
    print OUTPUTFILE $updateStr;
    close(INPUTFILE);
    close(OUTPUTFILE);

    my $success = rename($outf, $inf);
    if ($success) {
        $resultHash{'returnCode'} = 0;
    }
    else {
        $resultHash{'returnCode'} = 1;
    }

    push (@addList, (keys %{$setref}));

    return \%resultHash;
}

# Return a reference to a set (hash with k=v) that contains the package names published by the component
sub _getSetOfPackagesFromDependencyEmitter {
    my ($self) = @_;

    if (!defined $ARIBA_SHARED_ROOT) {
        die("The ARIBA_SHARED_ROOT environmnent varibale must be defined in the environment");
    }

    my $artifactPathsListRef = $self->{'compMeta'}->getPublishedArtifactPaths();
    my $cn = $self->{'compMeta'}->getName();
    my @artifactPathsList = @$artifactPathsListRef;

    my %retSet = ();

    foreach my $ap (@artifactPathsList) {
        if (! -e $ap) {
            print "JavaPkgToCompsIndexer: WARNING : Could not acquire list of Java packages for component  \"$cn\" because the artifact \"$ap\" does not exist.\n";
            next;
        }

        my $command = "$JAVA_HOME/bin/java -classpath $ARIBA_SHARED_ROOT/java/jars/validatorAndBinChecker.jar:$ARIBA_INSTALL_ROOT/classes/bcel.jar ariba.build.tool.DependencyEmitter $ap internal";

        if (defined $self->{'indexFilePath'}) {
            $command .= " $self->{'indexFilePath'}";
        }
        else {
            $command .= " /tmp";
        }

        my @stdout = qx "$command";
        my $retCode = $? ;

        if ($retCode > 0) {
            # perldoc -f system (must >> 8 to get actual value)
            $retCode = $retCode >> 8;
            die("JavaPkgToCompsIndexer: ERROR : Failure from command \"$command\" return code: $retCode\n");
        }

        if ($self->{'debug'}) {
            print "JavaPkgToCompsIndexer: Successfully ran command: \"$command\" output: \"@stdout\" return code: $retCode\n";
        }

        foreach my $line (@stdout){
            chomp($line);
            if ($line =~ /DependencyEmitter: ERROR/) {
                # Should not get here as the exit code handler above should've returned
                return \%retSet;
            }
            next if ($line =~ /DependencyEmitter: DEBUG/);
            next if ($line =~ /^#/);

            if ($line =~ /\,/) {
                my @retList = split(',', $line);
                for my $pkg (@retList) {
                    $retSet{$pkg} = $pkg;
                }
            }
            elsif ($line ne "") {
                $retSet{$line} = $line;
            }
        }
    }
    return \%retSet;
}

1;
