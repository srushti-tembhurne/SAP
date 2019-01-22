package ariba::rc::PublishedArtifactIndexer;

#
# PublishedArtifactIndexer.pm
# Creates an index that maps Ariba component to comma separated list of artifacts it publishes
# It discovers the published artifacts by parsing the Makefile and Build.mk files for the
# product universe (CompMeta list)
#
#
use Data::Dumper;
use ariba::rc::CompMeta;

my $ARIBA_SOURCE_ROOT = $ENV{'ARIBA_SOURCE_ROOT'};
my $ARIBA_INSTALL_ROOT = $ENV{'ARIBA_INSTALL_ROOT'};
my $INSTALL_DIR = $ARIBA_INSTALL_ROOT;
my $INSTALL_INTERNAL_DIR = $INSTALL_DIR . "/internal";
my $INSTALL_ETC_DIR = $INSTALL_INTERNAL_DIR . "/etc";
my $INSTALL_STAGING_DIR = $INSTALL_INTERNAL_DIR . "/staging";
my $INSTALL_CLASSES_DIR = $INSTALL_DIR . "/classes";
my $INSTALL_INTERNAL_CLASSES_DIR = $INSTALL_INTERNAL_DIR . "/classes";
my $INSTALL_ENDORSED_CLASSES_DIR = $INSTALL_DIR . "/classes/endorsed";
my $INSTALL_CLASSES_ENDORSED_DIR = $INSTALL_DIR . "/classes/endorsed";

my $varpattern = '\$\(([\w]*)\)';

# Constructor
# Input 1: string path to index file that contains component name to artifact paths it publishes
#
sub new {
    my $class = shift;
    my $indexfile = shift;

    my $self = {};
    bless ($self, $class);

    $self->{'debug'} = 0;

    $self->{'indexfile'} = $indexfile;
    return $self;
}

# Input 1: 0 to disable debug printing; otherwise enable (default is disabled)
sub setDebug {
   my ($self, $flag) = @_;

   $self->{'debug'} = $flag;
}

# Return 1 if the directory contains Ariba component source to consider for install.csv,Build.mk, etc; 0 otherise
sub containsComponentSource {
    my ($dir) = @_;

    return 0 if ($dir =~ /^\./);
    return 1;
}

# Input 1: Reference to a list of CompMeta to update
# Input 2: pass in a non-zero scalar to have the CompMeta published artifact list appended to.
# Input 3: non zero scalar means to check only the passed in directory (do not recurse into subdirs)
#
# Returns count of number of CompMeta objects that were updated (should be same as passed in list size)
sub updateCompMetaWithPublishedArtifactsViaSearch {
    my ($self, $compMetaListRef, $update, $rootOnly) = @_;

    my %compToArtifacts = ();

    if (! defined $dir) {
        $dir = $ARIBA_SOURCE_ROOT;
    }

    $self->getPublishedArtifactsForUniverse($compMetaListRef, \%compToArtifacts, $rootOnly);

    my $count = 0;
    for my $cm (@$compMetaListRef) {
        my $name = $cm->getName();
        my $artifactListRef = $compToArtifacts{$name};
        if (! defined $artifactListRef) {
            if ($self->{'debug'}) {
                print "PublishedArtifactIndexer: Unable to locate published artifact information for component \"$name\"\n";
            }
        }
        else {
            if ($update) {
                $cm->updatePublishedArtifactPaths($artifactListRef);
            }
            else {
                $cm->setPublishedArtifactPaths($artifactListRef);
            }
            $count ++;
        }
    }
    return $count;
}

# Update CompMeta objects with published artifact information by consulting a previously created index file
# TODO?: The method updateCompMetaWithPublishedArtifactsViaSearch may be fast enough
#
# Input 1: Path to published index file (created from xxx)
# Input 2: Reference to a list of CompMeta to update
# Returns count of number of CompMeta objects that were updated (should be same as passed in list size)
sub updateCompMetaWithPublishedArtifactsViaIndex {
    my ($self, $dir, $compMetaListRef) = @_;

}

# Scan the source directories declared by each CompMeta and update the hash reference parameter
# Input 1: $compMetaListRef reference to CompMeta to search its source path for Build.mk files
# Input 2: reference to an updated hash where key is component name and value is reference to a list of artifact names published by that component
# Input 3: non zero scalar means to check only the passed in directory (do not recurse into subdirs)
sub getPublishedArtifactsForUniverse {
    my ($self, $compMetaListRef, $returnedHash, $rootOnly) = @_;

    for my $cm (@$compMetaListRef) {
        my $srcPath = $cm->getSrcPath();
        if (!defined $srcPath) {
            die "PublishedArtifactIndexer: ERROR : The List of CompMeta does not include the srcPath for component \"" . $cm->getName . "\"\n";
        }
        $self->getPublishedArtifactsForUniverseByDir($srcPath, $returnedHash, $rootOnly);
    }
}

# Scan a directory hierarchy (typically compmeta->getsrcpath) and ultimately update the hash reference parameter
# Input 1: $dir directory to search under for Build.mk files
# Input 2: reference to a hash where key is component name and value is reference to a list of artifact names published by that component
# Input 3: non zero scalar means to check only the passed in directory (do not recurse into subdirs)
sub getPublishedArtifactsForUniverseByDir {
    my ($self, $dir, $returnedHash, $rootOnly) = @_;

    my @dirs = ();
    my $component;
    my $component_makefile;
    my $component_bdf;
    my $foundbuildmk;
    my $foundmakefile;
    my $foundbdf;

    opendir(DIR, $dir) || die("PublishedArtifactIndexer: ERROR : Cannot open directory \"$dir\"\n"); 
    for my $f (readdir(DIR)) {
        next if (! containsComponentSource($f));

        if ($f =~ /Makefile$/) {
            $foundmakefile = "$dir/$f";
            $component_makefile = _getComponentNameFromMakefile($foundmakefile);
            next if (! defined $component_makefile);
        }
        elsif ($f =~ /component.bdf/) {
            $foundbdf = "$dir/$f";
            $component_bdf = _getComponentNameFromBDF($foundbdf);
            next if (! defined $component_bdf);
        }
        elsif ($f =~ /Build.mk$/) {
            $foundbuildmk = "$dir/$f";
        }

        my $candidatedir = "$dir/$f";
        if (-d $candidatedir) {
            push (@dirs, $candidatedir);
        }
    }

    if (defined $component_makefile && defined $component_bdf) {
        if ($component_makefile ne $component_bdf) {
            print "PublishedArtifactIndexer: WARNING The component name in $dir/Makefile ($component_makefile) is different than component.bdf ($component_bdf): Using $component_bdf\n";
        }
        $component = $component_bdf;
    }
    elsif (defined $component_bdf && (! defined ($component_makefile))) {
        print "PublishedArtifactIndexer: WARNING The component name is not defined in $dir/Makefile bit it is in component.bdf ($component_bdf)\n";
        $component = $component_bdf;
    }
    elsif (defined $component_makefile && (! defined ($component_bdf))) {
        print "PublishedArtifactIndexer: WARNING The component name is not defined in $dir/component.bdf bit it is in Makefile ($component_makefile)\n";
        $component = $component_makefile;
    }

    my $buildmkpubs = 0;
    my $makefilepubs = 0;

    # It isn't cool how the Ariba 3rdParty comps declare their published artifacts in Makefile 
    # and Ariba developed comps in Build.mk (with different variables too)

    if (defined $foundmakefile && defined $component) {
        my $artifactListRef = $self->_getPublishedArtifactsForCompFromMakefile($component, $foundmakefile);
        if (defined $artifactListRef && @$artifactListRef >= 0) {
            $makefilepubs = @$artifactListRef + 1;
            my $lr = $returnedHash->{$component};
            if (defined $lr) {
                push (@$lr, @$artifactListRef);
            }
            else {
                $returnedHash->{$component} = $artifactListRef;
            }
        }
    }

    if (defined $foundbuildmk && defined $component) {
        my $artifactListRef = $self->_getPublishedArtifactsForCompFromBuildmk($component, $foundbuildmk);
        if (defined $artifactListRef && @$artifactListRef >= 0) {
            $buildmkpubs = @$artifactListRef + 1;
            my $lr = $returnedHash->{$component};
            if (defined $lr) {
                push (@$lr, @$artifactListRef);
            }
            else {
                $returnedHash->{$component} = $artifactListRef;
            }
        }
    }

    unless ($rootOnly) {
        if ($buildmkpubs == 0 && $makefilepubs == 0 && $#dirs >= 0) {
            for my $d (@dirs) {
                # Keep searching for Build.mk / Makefile
                $self->getPublishedArtifactsForUniverseByDir($d, $returnedHash, $rootOnly);
            }
        }
    }
    closedir(DIR);
}

# Input 1: name of component to look for published artifacts
# Input 2: path to Build.mk to scan for ALL_ZIP_FILES (published artifact info)
# Return: reference to a list of artifact paths (or undef if no published artifacts)
sub _getPublishedArtifactsForCompFromBuildmk {
    my ($self, $component, $buildmkpath) = @_;

    my @artifacts = ();

    open(INPUTFILE, "<" . $buildmkpath);

    my %defs = ();

    # This regex pattern is used to search for Makefile variable references like $(SOME_ZIP_FILE)
    while(<INPUTFILE>) {
        my($line) = $_;

        $line =~ s/[\r\n]//g;
        next if ($line eq '#');
        next if ($line eq '');

        _loadMakefileVariable($line, ':=', \%defs);
        _loadMakefileVariable($line, '=', \%defs);
        _loadMakefileVariable($line, '+=', \%defs);

        # Ex:
        # ASM_VERIFICATION_ZIP_NAME := ariba.asm.verification.zip
        # ASM_VERIFICATION_ZIP_FILE := $(INSTALL_INTERNAL_CLASSES_DIR)/$(ASM_VERIFICATION_ZIP_NAME)
        # ALL_ZIP_FILES += $(ASM_VERIFICATION_ZIP_FILE)

        my $ALL_ZIP_FILES = quotemeta("ALL_ZIP_FILES");
        if ($line =~ /^$ALL_ZIP_FILES/) {
            my $c = $defs{$ALL_ZIP_FILES};
            $c = _expandMakefileVariable($line, $buildmkpath, $c, \%defs);
            push (@artifacts, $c); # save the artifact path in the returned list
        }
    }
    close(INPUTFILE);

    my $numartifacts = $#artifacts + 1;
    print "PublishedArtifactIndexer: Found $numartifacts published artifacts for component \"$component\" from the file \"$buildmkpath\"\n";
    if ($numartifacts <= 0) {
        return undef;
    }
    return \@artifacts;
}

sub _expandMakefileVariable {
    my ($line, $file, $rhs, $defs) = @_;

    if ($rhs =~ /$varpattern/) {
        # Expand each variable reference once per iteration (each step may introduce more variables so continue until no more)
        # $rhs is updated each time
        while (1) {
            last if (!($rhs =~ /$varpattern/));
            my @rhslist = ($rhs =~ /$varpattern/);

            for my $e (@rhslist) {
                my $ev = $defs->{$e};
                if (defined $ev) {
                    # Substitute $(ASM_VERIFICATION_ZIP_FILE) with /home/rmauri/ariba/incbuild/install/internal/classes/ariba.asm.verification.zip
                    $rhs =~ s/\$\($e\)/$ev/g;
                }
                else {
                    die "PublishedArtifactIndexer: ERROR : Broken Build.mk: Cannot resolve the Makefile variable \"$rhs\" on the line \"$line\" in the file \"$file\"\n";
                }
            }
        }
    }
    return $rhs;
}

sub _loadMakefileVariable {
    my ($line, $separator, $defs) = @_;

    my $sep = quotemeta(" $separator ");
    if ($line =~ /$sep/) {
        my @tokens = split("$sep", $line);
        my $k = _trim($tokens[0]); # looks like: COLLABORATION_ZIP_FILE
        my $v = _trim($tokens[1]); # looks like: ariba.collaboration.zip

        if ($v =~ /$varpattern/) {
            # Variable references on the rhs
            # ASM_VERIFICATION_ZIP_FILE := $(INSTALL_INTERNAL_CLASSES_DIR)/$(ASM_VERIFICATION_ZIP_NAME)
            # dig the variable names out of any variable references
            # like INSTALL_INTERNAL_CLASSES_DIR and ASM_VERIFICATION_ZIP_NAME from the rhs
            my @vars = ($v =~ /$varpattern/);
            for my $e (@vars) {
                # The following makefile to env replacements were found empirically.
                if ($e eq "INSTALL_DIR") {
                    $v =~ s/\$\($e\)/$INSTALL_DIR/g;
                }
                elsif ($e eq "INSTALL_INTERNAL_DIR") {
                    $v =~ s/\$\($e\)/$INSTALL_INTERNAL_DIR/g;
                }
                elsif ($e eq "INSTALL_INTERNAL_CLASSES_DIR") {
                    $v =~ s/\$\($e\)/$INSTALL_INTERNAL_CLASSES_DIR/g;
                }
                elsif ($e eq "INSTALL_CLASSES_DIR") {
                    $v =~ s/\$\($e\)/$INSTALL_CLASSES_DIR/g;
                }
                elsif ($e eq "INSTALL_STAGING_DIR") {
                    $v =~ s/\$\($e\)/$INSTALL_STAGING_DIR/g;
                }
                elsif ($e eq "INSTALL_ETC_DIR") {
                    $v =~ s/\$\($e\)/$INSTALL_ETC_DIR/g;
                }
                elsif ($e eq "INSTALL_CLASSES_ENDORSED_DIR") {
                    $v =~ s/\$\($e\)/$INSTALL_CLASSES_ENDORSED_DIR/g;
                }
                else {
                    my $ev = $defs->{$e};
                    if (defined $ev) {
                        $v =~ s/\$\($e\)/$ev/g; # Substitute $(ASM_VERIFICATION_ZIP_NAME) with ariba.asm.verification.zip
                    }
                }
                $defs->{$k} = $v;
            }
        }
        else {
            # No variable references on the rhs
            # ASM_VERIFICATION_ZIP_NAME := ariba.asm.verification.zip
            $defs->{$k} = $v;
        }
    }
}

# Input 1: name of component to look for published artifacts
# Input 2: path to Makefile to scan for published artifact info (mostly 3rdParty comps)
# Return: reference to a list of artifact paths (or undef if no published artifacts)
sub _getPublishedArtifactsForCompFromMakefile {
    my ($self, $component, $mkpath) = @_;

    open(INPUTFILE, "<" . $mkpath);

    my @artifacts = ();
    my %defs = ();

    while(<INPUTFILE>) {
        my($line) = $_;

        $line =~ s/[\r\n]//g;
        next if ($line eq '#');
        next if ($line eq '');

        if ($line =~ /^INSTALL_CLASSES\s+\+\=/) {
            my $sep = quotemeta("+=");
            my @tokens = split($sep, $line);
            my $c = _trim($tokens[1]);
            @tokens = split(/\s+/, $c);
            for $c (@tokens) {
                $c = _expandMakefileVariable($line, $mkpath, $c, \%defs);
                push (@artifacts, "$INSTALL_CLASSES_DIR/$c");
            }
        }
        elsif ($line =~ /^INSTALL_CLASSES\s+\:\=/) {
            my $sep = quotemeta(":=");
            my @tokens = split($sep, $line);
            my $c = _trim($tokens[1]);
            @tokens = split(/\s+/, $c);
            for $c (@tokens) {
                $c = _expandMakefileVariable($line, $mkpath, $c, \%defs);
                push (@artifacts, "$INSTALL_CLASSES_DIR/$c");
            }
        }
        elsif ($line =~ /^INSTALL_INTERNAL_CLASSES\s+\+\=/) {
            my $sep = quotemeta("+=");
            my @tokens = split($sep, $line);
            my $c = _trim($tokens[1]);
            @tokens = split(/\s+/, $c);
            for $c (@tokens) {
                $c = _expandMakefileVariable($line, $mkpath, $c, \%defs);
                push (@artifacts, "$INSTALL_INTERNAL_CLASSES_DIR/$c");
            }
        }
        elsif ($line =~ /^INSTALL_INTERNAL_CLASSES\s+\:\=/) {
            my $sep = quotemeta(":=");
            my @tokens = split($sep, $line);
            my $c = _trim($tokens[1]);
            @tokens = split(/\s+/, $c);
            for $c (@tokens) {
                $c = _expandMakefileVariable($line, $mkpath, $c, \%defs);
                push (@artifacts, "$INSTALL_INTERNAL_CLASSES_DIR/$c");
            }
        }
        elsif ($line =~ /^INSTALLED_ZIPS\s+\+\=/) {
            my $sep = quotemeta("+=");
            my @tokens = split($sep, $line);
            my $c = _trim($tokens[1]);
            @tokens = split(/\s+/, $c);
            for $c (@tokens) {
                $c = _expandMakefileVariable($line, $mkpath, $c, \%defs);
                push (@artifacts, "$INSTALL_DIR/$c");
            }
        }
        elsif ($line =~ /^INSTALLED_ZIPS\s+\:\=/) {
            my $sep = quotemeta(":=");
            my @tokens = split($sep, $line);
            my $c = _trim($tokens[1]);
            @tokens = split(/\s+/, $c);
            for $c (@tokens) {
                $c = _expandMakefileVariable($line, $mkpath, $c, \%defs);
                push (@artifacts, "$INSTALL_DIR/$c");
            }
        }
        elsif ($line =~ /^INSTALL_ENDORSED_CLASSES\s+\+\=/) {
            my $sep = quotemeta("+=");
            my @tokens = split($sep, $line);
            my $c = _trim($tokens[1]);
            @tokens = split(/\s+/, $c);
            for $c (@tokens) {
                $c = _expandMakefileVariable($line, $mkpath, $c, \%defs);
                push (@artifacts, "$INSTALL_ENDORSED_CLASSES_DIR/$c");
            }
        }
        elsif ($line =~ /^INSTALL_ENDORSED_CLASSES\s+\:\=/) {
            my $sep = quotemeta(":=");
            my @tokens = split($sep, $line);
            my $c = _trim($tokens[1]);
            @tokens = split(/\s+/, $c);
            for $c (@tokens) {
                $c = _expandMakefileVariable($line, $mkpath, $c, \%defs);
                push (@artifacts, "$INSTALL_ENDORSED_CLASSES_DIR/$c");
            }
        }
        elsif ($line =~ /^INSTALL_STAGING_CLASSES\s+\+\=/) {
            my $sep = quotemeta("+=");
            my @tokens = split($sep, $line);
            my $c = _trim($tokens[1]);
            @tokens = split(/\s+/, $c);
            for $c (@tokens) {
                $c = _expandMakefileVariable($line, $mkpath, $c, \%defs);
                push (@artifacts, "$INSTALL_STAGING_DIR/$c");
            }
        }
        elsif ($line =~ /^INSTALL_STAGING_CLASSES\s+\:\=/) {
            my $sep = quotemeta(":=");
            my @tokens = split($sep, $line);
            my $c = _trim($tokens[1]);
            @tokens = split(/\s+/, $c);
            for $c (@tokens) {
                $c = _expandMakefileVariable($line, $mkpath, $c, \%defs);
                push (@artifacts, "$INSTALL_STAGING_DIR/$c");
            }
        }
        else {
            _loadMakefileVariable($line, ':=', \%defs);
            _loadMakefileVariable($line, '=', \%defs);
            _loadMakefileVariable($line, '+=', \%defs);
        }
    }
    close(INPUTFILE);

    my $numartifacts = $#artifacts + 1;
    print "PublishedArtifactIndexer: Found $numartifacts published artifacts for component \"$component\" from file \"$mkpath\"\n";
    if ($numartifacts <= 0) {
        return undef;
    }
    return \@artifacts;
}

# Recursively scan a search directory for component Build.mk
# files and create a file index that maps component to list of artificats it publishes
#
# Input 1: $dir directory to search under for Build.mk files 
sub genPublishIndexFileFromSearch {
    my ($self, $dir) = @_;

    my %compToArtifactsHash = ();
    $self->getPublishedArtifactsForUniverseByDir($dir, \%compToArtifactsHash);
    open(OUTPUTFILE, ">" . $self->{'indexfile'});

    for my $c (keys %compToArtifactsHash) {
        my $artifactsListRef = $compToArtifactsHash{$c};
        my $str = "";
        for my $a (@$artifactsListRef) {
            if ($str eq "") {
                $str = "$c $a";
            }
            else {
                $str = $str . ",$a";
            }
        }
        print OUTPUTFILE "$str\n";
    }
    close (OUTPUTFILE);
}

sub _getComponentNameFromMakefile {
    my ($makefile) = @_;

    open(MAKEFILE, "<$makefile");

    while(<MAKEFILE>) {
        my($line) = $_;

        $line =~ s/[\r\n]//g;
        next if ($line eq '#');
        next if ($line eq '');

        if ($line =~ /COMPONENT_NAME/) {
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

sub _getComponentNameFromBDF {
    my ($bdf) = @_;

    my $compname;
    my $state;

    open(BDF, "<$bdf");
    while(<BDF>) {
        my($line) = $_;
        $line =~ s/[\r\n]//g;
        next if ($line eq '#');
        next if ($line eq '');

        if ($line =~ /begin: build-definition-section/) {
            $state = 1;
            next;
        }

        next unless defined $state;
        next unless $state >= 1;

        if ($line =~ /end: build-definition-section/) {
            # Assert we will not get here as we exit the parsing loop as soon as we find the comp name
            last;
        }

        if ($state == 1 && $line =~ /BEGIN TEMPLATE/) {
            $state = 2;
            next;
        }

        if ($state == 2 && $line =~ /END TEMPLATE/) {
            $state = 3;
            next;
        }

        if ($state == 3) {
            # expect p4dir
            next if ($line =~ /^#/);
            $state = 4;
            next;
        }

        if ($state == 4) {
            # expect envvar
            next if ($line =~ /^#/);
            $state = 5;
            next;
        }

        if ($state == 5) {
            # expect modname
            next if ($line =~ /^#/);
            $compname = $line;
            last;
        }
    }
    close (INPUTFILE);
    return $compname;
}

sub _trim($) {
    my $string = shift;
    $string =~ s/^\s+//;
    $string =~ s/\s+$//;
    return $string;
}

1;
