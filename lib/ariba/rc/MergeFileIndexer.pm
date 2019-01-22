package ariba::rc::MergeFileIndexer;

#
# MergeFileIndexer.pm
#
use Data::Dumper;

my $ARIBA_INSTALL_ROOT = $ENV{'ARIBA_INSTALL_ROOT'};
my $INSTALL_DIR = $ARIBA_INSTALL_ROOT;
my $INSTALL_INTERNAL_DIR = $INSTALL_DIR . "/internal";
my $INSTALL_CLASSES_DIR = $INSTALL_DIR . "/classes";
my $INSTALL_INTERNAL_CLASSES_DIR = $INSTALL_INTERNAL_DIR . "/classes";

# A given component may require a list of files to be build-time filemerged.
# This routine consults the filemerge-{forward,reverse} index files to determine and return
# the set of components that have at least one common file to merge with.
#
# In the incremental build system, we need to perform rebuilds for the delta set of components 
# known to have changed.
# In the case where the component change relates to an install.csv change, it is important to merge
# with the files declared in this latest install.csv (not a previous stale copy that might exsit from 
# a previous build).
# The incremental build needs to effectively clean out the prior build's files to be filemereg and 
# restore them and merge in the proper sequence. This file contains various subroutines to aide in 
# acquiring the list of components that have overlapping filemerge requirements with a given component 
# so that cleanup and fresh filemerging can happen in the incremental build system.

# Return a reference to a list of component names that have intersecting sets of files to filemerge as the passed n component
#
# Input 1: $component the name of a component
# Returns: reference to a list of other components that have intersecting list of files to merge 
#          against or undef if no info is available (comp unknown)

#
# Constructor
# Input 1: string path to index file that contains files to merge vs Ariba component name mapping
#
sub new {
    my $class = shift;
    my $indexfile = shift;

    my $self = {};
    bless ($self, $class);

    $self->{'indexfile'} = $indexfile;
    return $self;
}

# Find the set of components that have overlapping filemerge entries in install.csv
# Input 1: $component name of component to consider 
# Returns: reference to list of component names
sub getComponentsToMergeWith {
    my ($self, $component) = @_;

    my $forwardMapRef = $self->_getDirectionedMap("forward");

    my $reverseMapRef = $self->_getDirectionedMap("reverse");

    my $filesetref = $reverseMapRef->{$component};
    if (! defined $filesetref) {
        return undef;
    }

    my %overlapcomps = ();
    for my $f (keys %$filesetref) {
        my $compssetref = $forwardMapRef->{$f};
        for my $c (keys %$compssetref) {
            next if ($c eq $component);
            $overlapcomps{$c} = $c;
        }
    }
    my @overlaplist = keys %overlapcomps;
    return \@overlaplist;
}

# Input 1: reference to a list of component names to query about list of components the are to be merged
# Returns: reference to a list of component names to merge
sub getComponentsToMergeWithBatch {
    my ($self, $componentsListRef) = @_;

    my %set = ();

    my @list = @$componentsListRef;
    for my $c (@list) {
        my $listRef = $self->getComponentsToMergeWith($c);
        for my $c2 (@$listRef) {
            $set{$c2} = $c2;
        }
    }
    @list = keys %set;
    return \@list;
}

# Input 1: component name to query about list of files the are to be merged
# Returns: reference to a list of files to merge
sub getFilesToMergeWith {
    my ($self, $component) = @_;

    my $reverseMapRef = $self->_getDirectionedMap("reverse");
    my $setref = $reverseMapRef->{$component};
    my @files = keys %$setref;
    return \@files;
}

# Input 1: reference to a list of component names to query about list of files the are to be merged
# Returns: reference to a list of files to merge
sub getFilesToMergeWithBatch {
    my ($self, $componentsListRef) = @_;

    my @ret = ();

    my @list = @$componentsListRef;
    for my $c (@list) {
        my $listRef = $self->getFilesToMergeWith($c);
        push (@ret, @listRef);
    }
    return \@ret;
}

# Return 1 if the directory contains Ariba component source to consider for install.csv,Build.mk, etc; 0 otherise
sub containsComponentSource {
    my ($dir) = @_;

    return 0 if ($dir =~ m/^\./);
    return 0 if ($dir eq "3rdParty");
    return 0 if ($dir eq "build");
    return 0 if ($dir eq "install");
    return 0 if ($dir eq "sandbox");
    return 0 if ($dir eq "services");
    return 0 if ($dir eq "shared");
    return 0 if ($dir eq "release");
    return 0 if ($dir eq "tools");

    # other filtering may be need to be added
    return 1;
}

# Input 1: $reference to list of CompMeta for components to search under for install.csv files 
# Input 2: non-zero scalar means to search only the root directory
sub genIndexFileFromSearch {
    my ($self, $compMetaListRef, $rootOnly) = @_;

    for my $cm (@$compMetaListRef) {
        next if ($cm->isDeleted());
        my $srcPath = $cm->getSrcPath();
        if (!defined $srcPath) {
            die "MergeFileIndexer: ERROR : The List of CompMeta does not include the srcPath for component \"" . $cm->getName . "\"\n";
        }
        $self->genIndexFileFromSearchByDir($srcPath, $rootOnly);
    }
}

# Recursively scan a search directory for component install.csv 
# files and create a file index that maps file-to-merge against components that have that file
#
# Input 1: $dir directory to search under for install.csv files 
#          (ones with a makefile with COMPONENT_NAME definition)
# Input 2: non-zero scalar means to search only the root directory
sub genIndexFileFromSearchByDir {
    my ($self, $dir, $rootOnly) = @_;

    my $component;
    my $foundcsv;
    my $foundmakefile;
    my @dirs = ();

    opendir(DIR, $dir) || die("Cannot open directory \"$dir\"\n"); 
    for my $f (readdir(DIR)) {
        next if (! containsComponentSource($f));

        if ($f =~ m/install.csv$/) {
            $foundcsv = "$dir/$f";
        }
        elsif ($f =~ m/Makefile$/) {
            $foundmakefile = "$dir/$f";
            $component = $self->_getComponentNameFromMakefile($foundmakefile);
            next if (! defined $component);
        }

        my $candidatedir = "$dir/$f";
        if (-d $candidatedir) {
            push (@dirs, $candidatedir);
        }
    }

    if (defined $foundcsv && defined $foundmakefile && defined $component) {
        # An install.csv that lives in a component with a Makefile declaring COMPONENT_NAME is
        # a candidate to have the install.csv parsed and indexed.
        $self->updateIndexFile($foundcsv, $component);
    }
    elsif ($#dirs >= 0) {
        unless ($rootOnly) {
            for my $d (@dirs) {
                # Keep drilling through the directory tree looking for install.csv candidates
                $self->genIndexFileFromSearchByDir($d, $rootOnly);
            }
        }
    }
    closedir(DIR);
}

# Input 1: $installcsv path to install.csv to read/parse and update the index from
# Input 2: $component name of component that owns the install.csv
sub updateIndexFile {
    my ($self, $installcsv, $component) = @_;

    if (! -f $self->{'indexfile'}) {
        my $ret = system("touch " . $self->{'indexfile'});
        if ($ret != 0) {
            die ("The filemerge index file \"" . $self->{'indexfile'} . "\" does not exist and it cannot be created\n");
        }
    }

#    print "Found candidate install.csv for \"$component\" at $installcsv\n";
    my $filesToMergeRef = $self->_getFilesToMergeFromInstallCSV($installcsv);

    if (defined $filesToMergeRef) {
        my $newfile = $self->{'indexfile'} . "-new";

        open(INPUTFILE, "<" . $self->{'indexfile'});
        open(OUTPUTFILE, ">$newfile");

        while(<INPUTFILE>) {
            my($line) = $_;
            chomp($line);
            my @tokens = split(' ', $line);
            my $f = $tokens[0];
            my $c = $tokens[1];
            next if ($c eq $component); # remove the old filemerge info as the latest info will be added in as a replacement 
            print OUTPUTFILE "$f $c\n";
        }
        close (INPUTFILE);

        # Now add the latest filemerge data for the component
        for my $f (@$filesToMergeRef) {
            print OUTPUTFILE "$f $component\n";
        }
        close (OUTPUTFILE);

        my $cmd = "sort -k 1 $newfile > " . $self->{'indexfile'};
        my $ret = system($cmd);
        if ($ret != 0) {
            die ("The sorting operation \"$cmd\" failed\n");
        }

        $cmd = "rm -f $newfile";
        $ret = system($cmd);
        if ($ret != 0) {
            die ("The removal operation \"$cmd\" failed\n");
        }

        $self->_prettyPrintIndexFile();
#        $self->_genForwardIndexFile();
#        $self->_genReverseIndexFile();
    }
}

#
# Discover the worst case component that has the largest set of 
# components to merge against (filemerge network)
#
# Returns a reference to a hash with three entries:
#   1. key 'size' value is scalar size (1 based) of list of other comps to merge against
#   2. key 'component' value is scalar name of the component with the largest filemerge network
#   3. key 'listref' value is reference to a list of other component names in the filemerge network
sub getWorstCaseComponentsToMergeWith {
    my ($self) = @_;

    my $worstCaseSize = 0;
    my $worstCaseComp;
    my $worstCaseListRef;

    my $reverseMapRef = $self->_getDirectionedMap("reverse");

    my @comps = keys %$reverseMapRef;
    for my $c (@comps) {
        my $listRef = $self->getComponentsToMergeWith($c);
        my @list = @$listRef;
        my $size = $#list + 1;
        if ($worstCaseSize < $size) {
            $worstCaseSize = $size;
            $worstCaseComp = $c;
            $worstCaseListRef = $listRef;
        }
    }

    my %ret = ();
    $ret{'size'} = $worstCaseSize;
    $ret{'component'} = $worstCaseComp;
    $ret{'listref'} = $worstCaseListRef;
    return \%ret;
}

############## Private internal implementaion below #############

# Input 1: $installcsv path to install.csv to parse
# Return reference to list of files to merge
sub _getFilesToMergeFromInstallCSV {
    my ($self, $installcsv) = @_;

    my %uniqueset = ();

    if (!defined $installcsv) {
        print "MergeFileIndexer: WARNING: The installcsv path is undefined\n";
        return undef;
    }
    if (! -e $installcsv) {
        #print "MergeFileIndexer: WARNING: The installcsv $installcsv path does not exist\n";
        return undef;
    }
    open(INPUTFILE, "<$installcsv");
    while(<INPUTFILE>) {
        my($line) = $_;
        chomp($line);
        if ($line =~ m/MergeFileToFile/) {
            my @tokens = split(',', $line);
            my $srcfiletomerge = $tokens[5];
            my $targetfiletomerge = $tokens[6];
            if (defined $targetfiletomerge && $targetfiletomerge ne "") {
                $uniqueset{$targetfiletomerge} = $targetfiletomerge;
            }
            else {
                $uniqueset{$srcfiletomerge} = $srcfiletomerge;
            }
            push (@files, $filetomerge);
        }
    }
    close (INPUTFILE);

    my @files = keys %uniqueset;
    if ($#files >= 0) {
        return \@files;
    }
    return undef;
}

sub _getComponentNameFromMakefile {
    my ($self, $makefile) = @_;

    open(MAKEFILE, "<$makefile");

    while(<MAKEFILE>) {
        my($line) = $_;
        chomp($line);
        if ($line =~ m/COMPONENT_NAME/) {
            # Example:
            # COMPONENT_NAME := ariba.sourcing.util
            my @tokens = split(':=', $line);
            my $component = $tokens[1];
            return _trim($component);
        }
    }
    close (INPUTFILE);
    return undef;
}

sub _trim($) {
    my $string = shift;
    $string =~ s/^\s+//;
    $string =~ s/\s+$//;
    return $string;
}

sub _prettyPrintIndexFile {
    my ($self) = @_;

    my $newfile = $self->{'indexfile'} . "-new";

    open(INPUTFILE, "<" . $self->{'indexfile'});
    open(OUTPUTFILE, ">$newfile");

    my $previousEntry;
    while(<INPUTFILE>) {
        my($line) = $_;

        chomp($line);
        $line = _trim($line);

        if ($line eq "") {
            $previousEntry = "";
            next;
        }

        my @tokens = split(' ', $line);
        my $f = $tokens[0];
        my $c = $tokens[1];

# original:

# a/b/c foo
# x/y/z bar
# x/y/z cat
# l/m/n zoo

# becomes:

# a/b/c foo
# 
# x/y/z bar
# x/y/z cat
#
# l/m/n zoo

        if (defined $previousEntry) {
            if ($f ne $previousEntry) {
                print OUTPUTFILE "\n";
            }
        }
        $previousEntry = $f;
        print OUTPUTFILE "$f $c\n";
    }
    close (INPUTFILE);
    close (OUTPUTFILE);

    my $cmd = "mv $newfile " . $self->{'indexfile'};
    my $ret = system($cmd);
    if ($ret != 0) {
        die ("The rename operation \"$cmd\" after pretty printing failed\n");
    }
}

# Create a file named $self->{'indexfile'} . "-reverse"
# that has first column == component name
# and the second column a comma separated list of file names to merge
sub _genReverseIndexFile {
    my ($self) = @_;

    $self->_genDirectionedIndexFile("reverse");
}

# Create a file named $self->{'indexfile'} . "-forward"
# that has first column == file name to merge
# and the second column is a comma separated list of components that need the file merged
sub _genForwardIndexFile {
    my ($self) = @_;

    $self->_genDirectionedIndexFile("forward");
}

# Input 1: direction specifier to load. Must be either "reverse" or "forward"
# Returns: reference to a hash where in the forward case, the key is a file name and the value is a ref of set of component names
# Returns: reference to a hash where in the reverse case, the key is a component name and the value is a ref of set of file names
sub _getDirectionedMap {
    my ($self, $direction) = @_;

    my %map = (); # file name to ref to list of component names

    my $previousEntry;

    if (!defined $self->{'indexfile'}) {
        print "MergeFileIndexer: WARNING: The indexfile is not defined\n";
        return \%map;
    }
    if (! -e $self->{'indexfile'}) {
        # We encounter this case in the IncrBuildMgrTest because some tests are not performing a full incremental build which creates the index file
        # TODO: Fix the IncrBuildMgrTest
        #print "MergeFileIndexer: WARNING: The indexfile $self->{'indexfile'} does not exist\n";
        return \%map;
    }

    open(INPUTFILE, "<" . $self->{'indexfile'});

    while(<INPUTFILE>) {
        my($line) = $_;

        chomp($line);
        $line = _trim($line);

        if ($line eq "") {
            $previousEntry = "";
            next;
        }

        my @tokens = split(' ', $line);
        my $f = $tokens[0];
        my $c = $tokens[1];

        my $key;
        my $value;
        if ($direction eq "forward") {
            $key = $f;
            $value = $c;
        }
        elsif ($direction eq "reverse") {
            $key = $c;
            $value = $f;
        }

        my $setref = $map{$key};
        if (!defined $setref) {
            my %set = ();
            $setref = \%set;
            $map{$key} = $setref;
        }

        $setref->{$value} = $value;
    }
    close (INPUTFILE);
    return \%map;
}

# Input 1: $direction eq "forward" or "reverse" to generate
# the $self->{'indexfile'} . "-$direction" file.
# A forward index maps file to command separated list of component names
# A reverse index maps component name to separated list of file names
sub _genDirectionedIndexFile {
    my ($self, $direction) = @_;

    my $mapref = $self->_getDirectionedMap($direction);
    my %map = %$mapref;

    my $newfile = $self->{'indexfile'} . "-$direction";

    open(OUTPUTFILE, ">$newfile");

    for my $key (keys %map) {
        my $setRef = $map{$key};
        my $str = "";
        for my $v (keys %$setRef) {
            if ($str eq "") {
                $str = "$key $str" . "$v";
            }
            else {
                $str = $str . ",$v";
            }
        }
        print OUTPUTFILE "$str\n\n";
    }
    close (OUTPUTFILE);
}

1;
