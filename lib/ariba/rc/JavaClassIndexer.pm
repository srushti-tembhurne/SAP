package ariba::rc::JavaClassIndexer;

use strict;
no warnings 'recursion';
use Data::Dumper;
use ariba::rc::CompMeta;
use File::Copy;
use File::Path;
use lib "$ENV{'ARIBA_SHARED_ROOT'}/bin";
use File::Basename;

my $ARIBA_INSTALL_ROOT = $ENV{'ARIBA_INSTALL_ROOT'};
my $ARIBA_SHARED_ROOT = $ENV{'ARIBA_SHARED_ROOT'};
my $JAVA_HOME = $ENV{'JAVA_HOME'};

my $ROOT_INDEX_DIR = 'rootIndexDir';
my $DEBUG = 'debug';
my $SCINDEX = 'scindex';
my $CLASSINDEX = 'classindex';

sub new {
    my $class = shift;
    my $rootIndexDir = shift;
    my $debug = shift;
    my $self = {};
    bless ($self, $class);

    $self->{$ROOT_INDEX_DIR} = $rootIndexDir;
    $self->{$DEBUG} = $debug;

    $self->_createPerCompIndexDir();
    $self->_createPerSubclassIndexDir();

    return $self;
}

# createAuxClassIndexes
#
sub createAuxClassIndexes {
    my ($self, $prodUniverseRef) = @_;

    $self->_createClassIndex($prodUniverseRef);
    $self->_createSubclassIndex();
}

# doesCompDefineMethod
#
# Given a method on a class that is known to have changed,
# Determine if a component contains a class that is a subclass of the changed class
# that defines a method of the same signature.
#
# This predicate method is important for the incremental build system to be able 
# to identify if the tested component should be rebuilt so as to catch build failures
# that would be caught in a full build. A typical use case is when new method is introduced
# on a class or the method visibility increased while in the presense of a subclass with
# lesser visibility.
#
# In a full-build system, a compile failure would result on the
# component class that did not change (but had the pre-existing method that would reduce
# method visibility.

# Input 1: component name to test
# Input 2: reference to a set of string method signature of the form class:method(type1,type2)
#
# Return 1 if the component defines a method of the same signature (with perhaps different access); 0 otherwise
sub doesCompDefineMethod {
    my ($self, $compName, $methodsigs) = @_;

    my $fn = $self->_getPathToPerCompClassIndexFile($compName);
    if (! -e $fn) {
        return 0;
    }

    open(INPUTFILE, "<" . $fn);

    # Recall that the input lines for the per-component index file looks like:
    #
    # comp.foo.bar ariba.util.core.FileComponentChecksum e ariba.util.core.ComponentChecksum
    # comp.foo.bar ariba.util.core.FileComponentChecksum m private addFileContents(java.io.File,byte[])

    while(<INPUTFILE>) {
        my($line) = $_;
        chomp($line);

        if ($line =~ / m /) {
            my @linea = split(/ /, $line);
            my $compname = $linea[0];
            my $classname = $linea[1];
            # $linea[2] eq "m"
            my $access = $linea[3];
            my $methodsig = $linea[4];

            my @a = keys (%{$methodsigs});
            for my $ms (@a) {
                my @a = split(/:/, $ms);
                my $c = $a[0];
                my $m = $a[1];

                if ($methodsig eq $m) {
                    if ($self->_isaSubclassOf($classname, $c)) {
                        return 1;
                    }
                }
            }
        }
    }
    close(INPUTFILE);
    return 0;
} # doesCompDefineMethod

# _createClassIndex
#
# Create the percompindexes directory of index files that
# contain the classes and methods defined for each component 
#
# Input 1: ref to list of CompMeta in the universe
#
sub _createClassIndex {
    my ($self, $prodUniverseRef) = @_;

    for my $cm (@{$prodUniverseRef}) {
        next if ($cm->isDeleted());
        $self->updateClassIndex($cm);
    }
}

# updateClassIndex
#
# Call this method after every component build to update the per-component classinfo-<compname>.txt index
#
# Ideally, this method only needs to be called when the component was known to have:
# - classes added
# - classes removed
# - methods added
# - methods removed
#
# Input 1: Reference to CompMeta object that was just built and analyzed by BC
sub updateClassIndex {
    my ($self, $compMetaRef) = @_;

    my $deinfo = $self->_getDEAddVisInfo($compMetaRef);

    # Example output of DependencyEmitter in methods mode:
    #
    # ariba.core.util ariba.util.core.Foo e ariba.util.core.ComponentChecksum
    # ariba.core.util ariba.util.core.Foo m public getChecksum()
    # ariba.core.util ariba.util.core.Foo m private addFileContents(java.io.File,byte[])
    #
    # ariba.core.util ariba.util.log.Bar e ariba.util.log.StandardLayout
    # ariba.core.util ariba.util.log.Bar m public getHeader()

    my @linestowrite = ();

    foreach my $outputLine (@{$deinfo}){
        chomp($outputLine);
        if ($outputLine =~ /DependencyEmitter: ERROR/) {
            return;
        }
        next if ($outputLine =~ /DependencyEmitter: DEBUG/);
        next if ($outputLine =~ /^#/);
        next if ($outputLine =~ /^[\w]*$/);

        push (@linestowrite, $outputLine);
    }
    $self->_updateClassIndexAux($compMetaRef->getName(), \@linestowrite);
} # updateClassIndex

sub removeClassIndex {
    my ($self) = @_;

    my $d = $self->_getPathToPerCompClassIndexDir();
    if (-d $d) {
        my $cmd = "rm -f $d/$CLASSINDEX" . "-*";
        my $ret = system($cmd);
        if ($ret != 0) {
            print "JavaClassIndexer: WARNING Could not remove per-component index files. The command was: \"$cmd\".\n";
        }
    }
    else {
        $self->_createPerCompIndexDir();
    }

    $d = $self->_getPathToPerSubclassIndexDir();
    if (-d $d) {
        my $cmd = "rm -f $d/$SCINDEX" . "-*";
        my $ret = system($cmd);
        if ($ret != 0) {
            print "JavaClassIndexer: WARNING Could not remove per-subclass index files. The command was: \"$cmd\".\n";
        }
    }
    else {
        $self->_createPerSubclassIndexDir();
    }
}

# Internal methods below

# Returns String absolute path to directory that will contain the component index files : classindex-<compName>.txt
sub _getPathToPerCompClassIndexDir {
    my ($self) = @_;

    my $fn = $self->{$ROOT_INDEX_DIR} . "/percompindexes";
    return $fn;
}

# Returns String absolute path to directory that will contain the component index files : scindex-<letter>.txt
sub _getPathToPerSubclassIndexDir {
    my ($self) = @_;

    my $fn = $self->{$ROOT_INDEX_DIR} . "/persubclassindexes";
    return $fn;
}

# Input 1: name of component
# Returns String absolute path to per component index : classindex-<compName>.txt
sub _getPathToPerCompClassIndexFile {
    my ($self, $compName) = @_;

    my $d = $self->_getPathToPerCompClassIndexDir();
    my $fn = "$d/$CLASSINDEX-$compName.txt";
    return $fn;
}

# _createSubclassIndex
# Must be called after createClassIndex !
#
# create files under persubclassindex/scindex-<uppercase-starting-letter-of-classnames>.txt
# that contain a mapping of a subclassname to list of superclassnames.
#
sub _createSubclassIndex {
    my ($self) = @_;

    my $dir = $self->_getPathToPerCompClassIndexDir();

    my %classtosuperclasses = (); # key: class name: value ref to list of superclass names

    # First pass: read in all the per component index files extracting the clas to superclass info
    # and load into memory the first order class -> ref to list (superclass)
    #
    # Second pass: resolve the list so it contains the transitive closure of super classes
    #
    # The final pass is to record to a per class index file the class e  superclass1,superclass2
    # where the file contains entries for class names with same starting letter (case insensitve)
    #
    # For example, for the cases where:
    # ariba.foo.A  extends ariba.bar.B
    # ariba.foo.A2 extends ariba.bar.b2
    # ariba.bar.B  extends ariba.car.C
    # ariba.bar.b2 extends Object
    # ariba.car.C  extends Object
    #
    # We would form three index files:
    # superclass-A.txt
    #    ariba.foo.A e ariba.bar.B,ariba.car.C,Object
    #    ariba.foo.A2 e ariba.bar.b2,Object
    #
    # superclass-B.txt
    #    ariba.bar.B e ariba.car.C,Object
    #    ariba.bar.b2 e Object
    #
    # superclass-C.txt
    #    C.car.ariba e Object
    #

    # First pass
    my @files = <$dir/*.txt>;
    for my $fn (@files) {
        open(INPUTFILE, "<" . $fn);

        # Example of classindex-<compname>.txt :
        #
        # comp.foo.bar ariba.util.core.SignalHandler e Object
        # comp.foo.bar ariba.util.core.SignalHandler m protected setFollowSignalChain(boolean)

        while(<INPUTFILE>) {
            my($line) = $_;
            chomp($line);

            if ($line =~ / e /) {
                my @linea = split(/ /, $line);

                # my $comp = $linea[0];
                my $class = $linea[1];
                # my $mode = $linea[2];
                my $superclass = $linea[3];

                my  $ref = $classtosuperclasses{$class};
                if (! defined $ref) {
                    my @superclasses = ();
                    $ref = \@superclasses;
                    $classtosuperclasses{$class} = $ref;
                }
                push (@{$ref}, $superclass);
            }
        }
        close(INPUTFILE);
    }

    # Second pass
    my @classes = keys (%classtosuperclasses);
    for my $c (@classes) {
        my @outputSuperclassesList = ();
        $self->_createTransitiveSuperclassSet(\%classtosuperclasses, $c, \@outputSuperclassesList);
        $classtosuperclasses{$c} = \@outputSuperclassesList;
    }

    # Third pass
    $dir = $self->_getPathToPerSubclassIndexDir();
    @classes = keys (%classtosuperclasses);
    for my $c (@classes) {
        if ($c ne "Object") {
            my $uc = $self->_getStartingLetterFromClassname($c);
            my $fn = "$dir/$SCINDEX-$uc.txt";

            open(OUTPUTFILE, ">>" . $fn);
            my $ref = $classtosuperclasses{$c};
            if (defined $ref) {
                my @a = @{$ref};
                my $str = join(",", @a); 
                print OUTPUTFILE "$c e $str\n";
            }
            close(OUTPUTFILE);
        }
    }
} # _createSubclassIndex

sub _createTransitiveSuperclassSet {
    my ($self, $masterClassToSuperclassesHashRef, $classname, $outputSuperclassesListRef) = @_;

    my $lr = $masterClassToSuperclassesHashRef->{$classname};
    if (defined $lr) {
        # We may have an undefined case when say a class extends a third party class like junit.framework.TestCase
        # in those cases we stop recuring up the superclass chain
        my @a = @{$lr};
        if ($#a >= 0) {
            my $sc = $a[0];
            push (@{$outputSuperclassesListRef}, $sc);
            if ($sc ne "Object") {
                $self->_createTransitiveSuperclassSet($masterClassToSuperclassesHashRef, $sc, $outputSuperclassesListRef);
            }
        }
    }
}

# Input 1: name of component
# Input 2: reference to list of string lines to write (contains comp class superclass and method info)
sub _updateClassIndexAux {
    my ($self, $compName, $linestowriteListRef) = @_;

    my @a = @{$linestowriteListRef};
    if ($#a >= 0) {
        # Don't create empty files...
        my $fn = $self->_getPathToPerCompClassIndexFile($compName);
        if (-e $fn) {
            my $cmd = "rm -f $fn";
            my $ret = system($cmd);
            if ($ret > 0) {
                # perldoc -f system (must >> 8 to get actual value)
                $ret = $ret >> 8;
                print "JavaClassIndexer: WARNING: Could not delete old index file. Command was \"$cmd\"\n";
            }
        }
        open(OUTPUTFILE, ">$fn");
        for my $line (@a) {
            print OUTPUTFILE "$line\n";
        }
        close(OUTPUTFILE);

        if ($self->{$DEBUG}) {
            print "JavaClassIndexer: updated index \"$fn\"\n";
        }
    }
}

#
# _getDEAddVisInfo
#
# Input 1: Reference to CompMeta object that was just built and analyzed by BC
# returns String to be parsed by _updateClassIndex
sub _getDEAddVisInfo {
    my ($self, $compMetaRef) = @_;

    my $artifactPathsRef = $compMetaRef->getPublishedArtifactPaths();

    my @dependencyEmitterCumulativeOutput = (); # Accross all artifacts for this component

    my $compName = $compMetaRef->getName();

    foreach my $ap (@$artifactPathsRef) {
        my $command = "$JAVA_HOME/bin/java -classpath $ARIBA_SHARED_ROOT/java/jars/validatorAndBinChecker.jar:$ARIBA_INSTALL_ROOT/classes/bcel.jar ariba.build.tool.DependencyEmitter $ap methods $self->{$ROOT_INDEX_DIR} $compName";

        if (! -e $ap) {
            print "JavaClassIndexer: WARNING : Unable to index the classes for the component \"$compName\" aritifact \"$ap\" because the artifact does not exist. The command: \"$command\"\n";
            next;
        }

        # running command and storing value in an array
        my @dependencyEmitterOutput = qx "$command";
        my $ret = $? ;

        if ($ret > 0) {
            # perldoc -f system (must >> 8 to get actual value)
            $ret = $ret >> 8;
            die("JavaClassIndexer: ERROR: Failure running command to acquire Java methods for component artifact: \"$command\" output: \"@dependencyEmitterOutput\" return code: $ret\n");
        }

        if ($self->{$DEBUG}) {
            print "JavaClassIndexer: Successfully ran command: \"$command\" output: \"@dependencyEmitterOutput\" return code: $ret\n";
        }

        push (@dependencyEmitterCumulativeOutput, @dependencyEmitterOutput);
    }
    return \@dependencyEmitterCumulativeOutput;
}

sub _createPerCompIndexDir {
    my ($self) = @_;

    my $d = $self->_getPathToPerCompClassIndexDir();
    unless (-d $d) {
        my $cmd = "mkdir -p $d";
        my $ret = system($cmd);
        if ($ret != 0) {
            print "JavaClassIndexer: WARNING Could not create per-component index directory. The command was: \"$cmd\".\n";
        }
    }
}

sub _createPerSubclassIndexDir {
    my ($self) = @_;

    my $d = $self->_getPathToPerSubclassIndexDir();
    unless (-d $d) {
        my $cmd = "mkdir -p $d";
        my $ret = system($cmd);
        if ($ret != 0) {
            print "JavaClassIndexer: WARNING Could not create per-subclass index directory. The command was: \"$cmd\".\n";
        }
    }
}

# Input 1: class name to check if it is a subclass of consideredSuperclass
# Input 2: consideredSuperclass name to check if it is a superclass of class
# Returns 1 if class is a subclass of consideredSuperclass; 0 otherwise
sub _isaSubclassOf {
    my ($self, $class, $consideredSuperclass) = @_;

    my $uc = $self->_getStartingLetterFromClassname($class);
    my $d = $self->_getPathToPerSubclassIndexDir();
    my $fn = "$d/$SCINDEX-$uc.txt";
    if (-e $fn) {
        open(INPUTFILE, "<" . $fn);
        while(<INPUTFILE>) {
            my($line) = $_;
            chomp($line);

            # Example:
            # scindex-A.txt would look like
            #    ariba.foo.A e ariba.bar.B,ariba.car.C,Object
            #    ariba.foo.A2 e ariba.bar.b2,Object
            #    ariba.foo2.a e Object

            if ($line =~ / e /) {
                my @tokens = split(/ /, $line);

                my $c = $tokens[0];
                # tokens[1] = 'e'
                my $sclist = $tokens[2];

                if ($class eq $c) {
                    @tokens = split(/,/, $sclist);
                    for my $t (@tokens) {
                        if ($consideredSuperclass eq $t) {
                            return 1;
                        }
                    }
                }
            }
        }
        close(INPUTFILE);
    }
    else {
        print "JavaClassIndexer: WARNING Could not locate the per-subclass index file \"$fn\".\n";
    }
    return 0;
} # isaSubclassOf

# Given a classname like "ariba.util.core.Foo" or "ariba.foo2"
# Return the class name starting letter "F"
# The returned letter will be uppercase
sub _getStartingLetterFromClassname {
    my ($self, $classname) = @_;

    my @tokens = split(/\./, $classname);
    my $lastIndex = $#tokens;
    my $c = ucfirst $tokens[$lastIndex];
    my $fc = substr($c,0,1);
    return $fc;
}

1;
