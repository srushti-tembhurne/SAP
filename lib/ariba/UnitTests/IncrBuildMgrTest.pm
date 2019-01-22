package ariba::UnitTests::IncrBuildMgrTest;

#
# IncrBuildMgrTest
#
# Unit tests for IncrBuildMgr
#
# Environment requirements:
#    Expects ARIBA_SHARED_ROOT to be defined
#
# This test code generates universe of components, builds a baseline image
# and runs incremental build scenarios against various changelists that include
# combinations of compatible and incompatible changes.
#
# The universe looks includes components below:
# with the dependencies shown below:
# A -> B
# E -> B
# B -> C, D, M
# C -> G
# D -> F
# G -> D
# F ->
# M ->
# Mdup ->
#
# H -> I
# I -> J
# J -> K, L, M
# K -> K2
# K2 ->
# L ->

# An optional extended universe generates a chain of components of a configurable depth like this 100 example:
# L -> L1
# L1 -> L2
# ...
# L99 -> L100

use strict;
use Data::Dumper;
use File::Copy;
use Switch;
use ariba::rc::IncrBuildMgr;
use ariba::rc::CompMeta;
use ariba::rc::IncrBuildMgrException;
use ariba::rc::JavaClassIndexer;
use Time::HiRes qw(gettimeofday); 

my %baselineUniverseHash = (); # component name to CompMeta
my $debug = 0;

my $extendedUniverseSize = 0;

my $BASELINE_DIR_NAME = "incrBuildMgrBaseline";
my $PACKAGE_NAME = "incrBuildMgrTest";
my $TEMP_DIR = "/tmp";
my $SHARED_ROOT = $ENV{'ARIBA_SHARED_ROOT'};

# Define a mapping of test ids to test subroutines
#
my %testRoutines = (
    incrBuildMgrTest1  => \&_runTest1,
    incrBuildMgrTest2  => \&_runTest2,
    incrBuildMgrTest3  => \&_runTest3,
    incrBuildMgrTest4  => \&_runTest4,
    incrBuildMgrTest5  => \&_runTest5,
    incrBuildMgrTest6  => \&_runTest6,
    incrBuildMgrTest7  => \&_runTest7,
    incrBuildMgrTest8  => \&_runTest8,
    incrBuildMgrTest9  => \&_runTest9,
    incrBuildMgrTest10 => \&_runTest10,
    incrBuildMgrTest11 => \&_runTest11,
    incrBuildMgrTest12 => \&_runTest12,
    incrBuildMgrTest13 => \&_runTest13,
    incrBuildMgrTest14 => \&_runTest14,
    incrBuildMgrTest15 => \&_runTest15,
    incrBuildMgrTest16 => \&_runTest16,
    incrBuildMgrTest17 => \&_runTest17,
    incrBuildMgrTest18 => \&_runTest18,
    incrBuildMgrTest19 => \&_runTest19,
    incrBuildMgrTest20 => \&_runTest20,
    incrBuildMgrTest21 => \&_runTest21,
    incrBuildMgrTest22 => \&_runTest22,
    incrBuildMgrTest23 => \&_runTest23,
    incrBuildMgrTest24 => \&_runTest24,
    incrBuildMgrTest25 => \&_runTest25,
    incrBuildMgrTest26 => \&_runTest26,
    incrBuildMgrTest27 => \&_runTest27,
    incrBuildMgrTest28 => \&_runTest28,
    incrBuildMgrTest29 => \&_runTest29,
    incrBuildMgrTest30 => \&_runTest30,
    incrBuildMgrTest31 => \&_runTest31,
    incrBuildMgrTest32 => \&_runTest32,
    incrBuildMgrTest33 => \&_runTest33,
    incrBuildMgrTest34 => \&_runTest34,
    incrBuildMgrTest35 => \&_runTest35
);

# Define a mapping of test ids to delta specs
#
# Terminology:
#     A term like "B:c1" means that component B changed using compatible template 1
#     A term like "D:i2" means that component D changed using incompatible template 2
#     A term like "B:c1,D:i2" means that B was changed using compatible template 1 and D was changed using incompatible template 2
#
my %testDeltas = (
    incrBuildMgrTest1  => "B:c1,D:i1",
    incrBuildMgrTest2  => "B:i1,D:c1",
    incrBuildMgrTest3  => "B:c1,D:c1",
    incrBuildMgrTest4  => "B:i1,D:i1",
    incrBuildMgrTest5  => "F:c1",
    incrBuildMgrTest6  => "F:i1",
    incrBuildMgrTest7  => "B:c1,D:i2",
    incrBuildMgrTest8  => "B:c1,D:i3",
    incrBuildMgrTest9  => "L:c1",
    incrBuildMgrTest10 => "L:i1",
    incrBuildMgrTest11 => "L:i4",
    incrBuildMgrTest12 => "L:i5",
    incrBuildMgrTest13 => "L:i6",
    incrBuildMgrTest14 => "L:i7",
    incrBuildMgrTest15 => "L:c2",
    incrBuildMgrTest16 => "C:i8",
    incrBuildMgrTest17 => "C:i9",
    incrBuildMgrTest18 => "B:c1,D:i1",
    incrBuildMgrTest19 => "B:c1",
    incrBuildMgrTest20 => "B:c1",
    incrBuildMgrTest21 => "L:c3",
    incrBuildMgrTest22 => "B:c5",
    incrBuildMgrTest23 => "B:c6",
    incrBuildMgrTest24 => "K2:c4",
    incrBuildMgrTest25 => "K2:c7",
    incrBuildMgrTest26 => "F:c8",
    incrBuildMgrTest27 => "B:c1",
    incrBuildMgrTest28 => "B:c1",
    incrBuildMgrTest29 => "B:i1",
    incrBuildMgrTest30 => "M:i1",
    incrBuildMgrTest31 => "M:i12",
    incrBuildMgrTest32 => "F:v1",
    incrBuildMgrTest33 => "K2:i13",
    incrBuildMgrTest34 => "K2:i14",
    incrBuildMgrTest35 => "L:i15",
);

# Main entry point that will be discovered and run automatically by UnitTest framework
# or driven by IncrBuildMgrTest.pl main program
#
# Input1: $product name of product or test case
# Input2: $masterPassword passed only in regression test cases (not used though)
# Input3: $printdebug if 1 then print debug messages
# Input4: $extendedUniverseSizeArg a number > 0 will generate an extended universe graph of this size
# Input5: $testArrayRef a reference to an array of test numbers
sub runTests {
    my ($class, $product, $masterPassword, $printdebug, $extendedUniverseSizeArg, $testArrayRef) = @_;

    if (! defined $SHARED_ROOT) {
        die "The ARIBA_SHARED_ROOT must be defined in the environment\n";
    }

    $debug = $printdebug;

    if (defined $extendedUniverseSizeArg) {
        $extendedUniverseSize = $extendedUniverseSizeArg;
    }

    _codeGenBaselineUniverse();
    _buildBaselineUniverse();
    _generateBaselinePackageToCompsIndex();

    my @testRoutineKeys = keys %testRoutines;
    my $testRoutineCount = @testRoutineKeys;

    my @range;
    if (defined $testArrayRef) {
        @range = @{$testArrayRef};
    }
    else {
        @range=(1..$testRoutineCount);
    }

    foreach my $testId (@range) {
        my $testRoutineId = "incrBuildMgrTest$testId";
        my $testRoutineRef = $testRoutines{$testRoutineId};
        &{$testRoutineRef}();
    }
}

sub _generateBaselinePackageToCompsIndex {
    print "Generating the baseline component index\n";
    my @productUniverse = values %baselineUniverseHash;
    my $javaClassIndexer = ariba::rc::JavaClassIndexer->new("$TEMP_DIR/$BASELINE_DIR_NAME");
    $javaClassIndexer->createAuxClassIndexes(\@productUniverse);
}

sub _buildBaselineUniverse {
    my $startTime = gettimeofday;
    print "Building the baseline universe of components (brute force full build)\n";

    # Consider leveraging the incrBuild to do this baseline build in the correct order
    # TODO: We have a fullBuild option to IncrBuildMgr so we could use that feature instead of the brute force way below
    my $compName = "F";
    my $ret = _compileAndPackageComp($compName, $BASELINE_DIR_NAME);
    if ($ret ne "SUCCESS") {
        print "ERROR Building the baseline universe for component $compName\n";
    }

    $compName = "D";
    $ret = _compileAndPackageComp($compName, $BASELINE_DIR_NAME);
    if ($ret ne "SUCCESS") {
        print "ERROR Building the baseline universe for component $compName\n";
    }

    $compName = "G";
    $ret = _compileAndPackageComp($compName, $BASELINE_DIR_NAME);
    if ($ret ne "SUCCESS") {
        print "ERROR Building the baseline universe for component $compName\n";
    }

    $compName = "C";
    $ret = _compileAndPackageComp($compName, $BASELINE_DIR_NAME);
    if ($ret ne "SUCCESS") {
        print "ERROR Building the baseline universe for component $compName\n";
    }

    $compName = "M";
    $ret = _compileAndPackageComp($compName, $BASELINE_DIR_NAME);
    if ($ret ne "SUCCESS") {
        print "ERROR Building the baseline universe for component $compName\n";
    }

    $compName = "Mdup";
    $ret = _compileAndPackageComp($compName, $BASELINE_DIR_NAME);
    if ($ret ne "SUCCESS") {
        print "ERROR Building the baseline universe for component $compName\n";
    }

    $compName = "B";
    $ret = _compileAndPackageComp($compName, $BASELINE_DIR_NAME);
    if ($ret ne "SUCCESS") {
        print "ERROR Building the baseline universe for component $compName\n";
    }

    $compName = "A";
    $ret = _compileAndPackageComp($compName, $BASELINE_DIR_NAME);
    if ($ret ne "SUCCESS") {
        print "ERROR Building the baseline universe for component $compName\n";
    }

    $compName = "E";
    $ret = _compileAndPackageComp($compName, $BASELINE_DIR_NAME);
    if ($ret ne "SUCCESS") {
        print "ERROR Building the baseline universe for component $compName\n";
    }

    if ($extendedUniverseSize > 0) {
        print "IncrBuildMgrTest: Building extended baseline universe\n";
    }
    my $index = $extendedUniverseSize;
    while ($index > 0) {
        print ".";
        $compName = "L$index";
        $ret = _compileAndPackageComp($compName, $BASELINE_DIR_NAME);
        if ($ret ne "SUCCESS") {
            print "ERROR Building the baseline universe for component $compName\n";
        }
        $index --;
    }
    if ($extendedUniverseSize > 0) {
        print "\n";
    }

    $compName = "L";
    $ret = _compileAndPackageComp($compName, $BASELINE_DIR_NAME);
    if ($ret ne "SUCCESS") {
        print "ERROR Building the baseline universe for component $compName\n";
    }

    $compName = "K2";
    $ret = _compileAndPackageComp($compName, $BASELINE_DIR_NAME);
    if ($ret ne "SUCCESS") {
        print "ERROR Building the baseline universe for component $compName\n";
    }

    $compName = "K";
    $ret = _compileAndPackageComp($compName, $BASELINE_DIR_NAME);
    if ($ret ne "SUCCESS") {
        print "ERROR Building the baseline universe for component $compName\n";
    }

    $compName = "J";
    $ret = _compileAndPackageComp($compName, $BASELINE_DIR_NAME);
    if ($ret ne "SUCCESS") {
        print "ERROR Building the baseline universe for component $compName\n";
    }

    $compName = "I";
    $ret = _compileAndPackageComp($compName, $BASELINE_DIR_NAME);
    if ($ret ne "SUCCESS") {
        print "ERROR Building the baseline universe for component $compName\n";
    }

    $compName = "H";
    $ret = _compileAndPackageComp($compName, $BASELINE_DIR_NAME);
    if ($ret ne "SUCCESS") {
        print "ERROR Building the baseline universe for component $compName\n";
    }

    my $elapsedTime = gettimeofday-$startTime;
    print "Building the baseline universe of components : elapsed time : $elapsedTime secs\n\n";
}

#
# Generate baseline universe of components A...L
#
# Side-effect is to update %baselineUniverseHash and @baselineUniverse and create the baseline dirs and files:
#
# Dirs:  $TEMP_DIR/<BASELINE_DIR_NAME>/<compName>/{src,classes,jars}
# Files: $TEMP_DIR/<BASELINE_DIR_NAME>/<compName>/src/ariba/<PACKAGE_NAME>/<compName>.java-{baseline,c{1},i{1,2,3,4}}
#
sub _codeGenBaselineUniverse {

    if ($extendedUniverseSize > 0) {
        print "Generating the extended baseline universe of components {A...L$extendedUniverseSize}\n";
    }
    else {
        print "Generating the baseline universe of components {A...M}\n";
    }

    my $cmd = "rm -rf $TEMP_DIR/incrBuildMgr*"; # Start clean each time
    system($cmd);

    my $compName = "A";
    my @depends = ("B");
    my $compMeta = _codeGenComp($BASELINE_DIR_NAME, $compName, \@depends, 1, undef, undef);
    $baselineUniverseHash{$compName} = $compMeta;

    $compName = "B";
    @depends = ("C", "D", "M");
    my $dependsFinalUsage = "M";
    $compMeta = _codeGenComp($BASELINE_DIR_NAME, $compName, \@depends, undef, undef, $dependsFinalUsage);
    $baselineUniverseHash{$compName} = $compMeta;

    $compName = "C";
    @depends = ("G");
    my $snippet = "    private int reducedmethodtest(int i) { return i; }\n";
    $compMeta = _codeGenComp($BASELINE_DIR_NAME, $compName, \@depends, undef, undef, undef, undef, undef, $snippet);
    $baselineUniverseHash{$compName} = $compMeta;

    $compName = "D";
    @depends = ("F");
    $compMeta = _codeGenComp($BASELINE_DIR_NAME, $compName, \@depends, undef, undef, undef);
    $baselineUniverseHash{$compName} = $compMeta;

    $compName = "E";
    @depends = ("B");
    $compMeta = _codeGenComp($BASELINE_DIR_NAME, $compName, \@depends, 1, undef, undef);
    $baselineUniverseHash{$compName} = $compMeta;

    $compName = "F";
    $compMeta = _codeGenComp($BASELINE_DIR_NAME, $compName, undef, undef, undef, undef);
    $baselineUniverseHash{$compName} = $compMeta;

    $compName = "G";
    @depends = ("D");
    $compMeta = _codeGenComp($BASELINE_DIR_NAME, $compName, \@depends, undef, undef, undef);
    $baselineUniverseHash{$compName} = $compMeta;

    $compName = "H";
    @depends = ("I");
    $compMeta = _codeGenComp($BASELINE_DIR_NAME, $compName, \@depends, 1, undef, undef);
    $baselineUniverseHash{$compName} = $compMeta;

    $compName = "I";
    @depends = ("J");
    $compMeta = _codeGenComp($BASELINE_DIR_NAME, $compName, \@depends, undef, undef, undef);
    $baselineUniverseHash{$compName} = $compMeta;

    $compName = "J";
    @depends = ("K", "L", "M");
    $dependsFinalUsage = "M";
    $compMeta = _codeGenComp($BASELINE_DIR_NAME, $compName, \@depends, undef, undef, $dependsFinalUsage);
    $baselineUniverseHash{$compName} = $compMeta;

    $compName = "K";
    @depends = ("K2");
    $compMeta = _codeGenComp($BASELINE_DIR_NAME, $compName, \@depends, undef, undef, undef);
    $baselineUniverseHash{$compName} = $compMeta;

    $compName = "K2";
    $compMeta = _codeGenComp($BASELINE_DIR_NAME, $compName, undef, undef, 1, undef);
    $baselineUniverseHash{$compName} = $compMeta;

    $compName = "L";
    if ($extendedUniverseSize > 0) {
        @depends = ("L1");
        $compMeta = _codeGenComp($BASELINE_DIR_NAME, $compName, \@depends, undef, undef, undef);
    }
    else {
        $compMeta = _codeGenComp($BASELINE_DIR_NAME, $compName, undef, undef, undef, undef);
    }
    $baselineUniverseHash{$compName} = $compMeta;

    my $index = 1;
    while ($index <= $extendedUniverseSize) {
        # Here we generate L<num> that depends on L<num+1>
        # the last leaf L<last> has undef depends
        $compName = "L$index";
        my $nextIndex = $index + 1;
        if ($index < $extendedUniverseSize) {
            my @depends = ("L$nextIndex");
            $compMeta = _codeGenComp($BASELINE_DIR_NAME, $compName, \@depends, undef, undef, undef);
        }
        else {
            $compMeta = _codeGenComp($BASELINE_DIR_NAME, $compName, undef, undef, undef, undef);
        }
        $baselineUniverseHash{$compName} = $compMeta;
        $index ++;
    }

    $compName = "M";
    $compMeta = _codeGenComp($BASELINE_DIR_NAME, $compName, undef, undef, undef, undef, 1);
    $baselineUniverseHash{$compName} = $compMeta;

    $compName = "Mdup";
    $compMeta = _codeGenComp($BASELINE_DIR_NAME, $compName, undef, undef, 1, undef, 1, "M");
    $baselineUniverseHash{$compName} = $compMeta;
}

# Generates the file:
# $pkgdir/<compName>.java-$template
#
# Input1 : $compName is the name of the component to generate
# Input2 : $pkgdir is the path to the Java package directory root to generate the file to
# Input3 : $depends is the reference to an array of dependencies declared by $compName
# Input4 : $template is the name of the template to generate
# Input5 : $root set to 1 to gen as a final class (it's a root in the universe)
# Input6 : $abstract set to 1 to gen as an abstract class (it's a leaf in the universe)
# Input7 : $dependsFinalUsage name of final component to depend on via usage 
# Input8 : $final if set to 1 then treat this component as final
# Input9 : $pkgoverride use this name instead of $compname when generating the package statement (useful for gen ambiguous cases)
# Inpu 10: $addsnippet codesnippet to add
# 
# Template semantics: 
#   baseline= base template (no updates/deletes/additions)
#   c1      = add pub method
#   c2      = add public constructor, field
#   c3      = remove private method, constructor, field
#   c4      = change abstract class to no longer be abstract
#   c5      = change final class to no longer be final
#   c6      = change non public class to be public
#   c7      = change class,field,constructor to be more visible
#   c8      = change public|protected method to now be synchronized
#   c9      = add component
#   c10     = add class
#   i1      = change public|protected method type signature
#   i2      = change public|protected field visibility
#   i3      = remove public|protected field
#   i4      = remove public|protected class interface
#   i5      = change public|protected field to be final
#   i6      = change public|protected field to be static
#   i7      = change public|protected method to be final
#   i8      = change superclass
#   i9      = change class to now be final 
#   i10     = delete component
#   i11     = delete class
#   i12     = change constant (final static) field 
#   i13     = add abstract method to abstract class
#   i14     = add method to interface
#   i15     = removal of public static field is incompatible
#   v1      = change method to be more visible
#
# TBD: Confirm all the checks to incompat public AND protected are implemented
#
sub _codeGenTemplate {
    my ($compName, $pkgdir, $depends, $template, $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet) = @_;

    # The following generates the .java-baseline file for component "A" that depends on a single compopnent B:
    # (It uses inheritance And usage)
    #

    # // This file is generated by IncrBuildMgrTest
    #
    # package ariba.incrBuildMgrTest.A;
    # import ariba.incrBuildMgrTest.B.B;
    # import java.io.Serializable;
    #
    # public class A extends B implements Serializable {
    #     public int field1 = 1;
    #     private int field2 = 2;
    #     protected int field3 = 3;
    #
    #     public A() {
    #     }
    #
    #     private A(String s) {
    #     }
    #
    #     public void a_1() {
    #         B comp = new B();
    #         comp.b_1();
    #     }
    #
    #     protected void a_2() {
    #         B comp = new B();
    #         comp.b_1();
    #     }
    #
    #     private void a_4() {
    #     }
    # }
    #
    # The following generates the .java-baseline file content for component "B" that depends on > 1 components "C", "D"
    # (Dependencies via usage only)
    #
    # // This file is generated by IncrBuildMgrTest
    #
    # package ariba.incrBuildMgrTest.B;
    # import ariba.incrBuildMgrTest.C.C;
    # import ariba.incrBuildMgrTest.D.D;
    # import java.io.Serializable;
    #
    # public class B implements Serializable {
    #     public int field1 = 1;
    #     private int field2 = 2;
    #     protected int field3 = 3;
    #
    #     public B() {
    #     }
    #
    #     private B(String s) {
    #     }
    #
    #     public void b_1() {
    #         C comp1 = new C();
    #         comp.c_1();
    #         D comp2 = new D();
    #         comp.d_1();
    #     }
    #
    #     protected void b_2() {
    #         C comp1 = new C();
    #         comp.c_1();
    #         D comp2 = new D();
    #         comp.d_1();
    #     }
    #
    #     private void b_4() {
    #     }
    # }
    my $maybePublic = "public";
    my $maybeFinalOrAbstract = "";

    my $className = $compName;

    if ($template eq "comaptchange10") {
        # adding a class to the component package
        $className = $compName . "_Addition"
    }

    my $classNameLower = lc($className);

    if (defined $root) {
        # root classes like A,E,H are package final
        $maybeFinalOrAbstract = "final";
        $maybePublic = "";
    }

    if ($template eq "c7") {
        # change root class from package to public
        $maybePublic = "public";
    }

    if (defined $final) {
        $maybeFinalOrAbstract = "final";
    }

    if (defined $abstract) {
        $maybeFinalOrAbstract = "abstract";
    }

    if ($template eq "c6") {
        $maybePublic = "public";
    }

    if ($template eq "c4") {
        $maybeFinalOrAbstract = "";
    }

    my $javasrcfile = "// This file is generated by IncrBuildMgrTest\n\n";

    if (defined $pkgoverride) {
        $javasrcfile = $javasrcfile . "package ariba.$PACKAGE_NAME.$pkgoverride;\n";
    }
    else {
        $javasrcfile = $javasrcfile . "package ariba.$PACKAGE_NAME.$compName;\n";
    }

    $javasrcfile = $javasrcfile . "import java.io.Serializable;\n";
    my $numdepends = 0;
    my $lonedepends = undef;
    if ($depends) {
        my @depends = @$depends;
        foreach my $d (@depends) {
            $numdepends = $numdepends + 1;
            $lonedepends = $d;
            $javasrcfile = $javasrcfile . "import ariba.$PACKAGE_NAME.$d.$d;\n";
        }
    }

    if (defined $dependsFinalUsage) {
        $javasrcfile = $javasrcfile . "import ariba.$PACKAGE_NAME.$dependsFinalUsage.$dependsFinalUsage;\n";
    }

    if ($template eq "i4") {
        if ($numdepends == 1) {
            $javasrcfile = $javasrcfile . "\n$maybePublic $maybeFinalOrAbstract class $className extends $lonedepends { // changing interface is incompatible\n";
        }
        else {
            $javasrcfile = $javasrcfile . "\n$maybePublic $maybeFinalOrAbstract class $className { // changing interface is incompatible\n";
        }
    }
    elsif ($template eq "i8") {
        if ($numdepends == 1) {
            $javasrcfile = $javasrcfile . "\n$maybePublic $maybeFinalOrAbstract class $className implements Serializable { // changing superclass is incompatible\n";
        }
        else {
            $javasrcfile = $javasrcfile . "\n$maybePublic $maybeFinalOrAbstract class $className implements Serializable {\n";
        }
    }
    elsif ($template eq "i9") {
        if ($numdepends == 1) {
            $javasrcfile = $javasrcfile . "\n$maybePublic final class $className extends $lonedepends implements Serializable { // changing class to be final is incompatible\n";
        }
        else {
            $javasrcfile = $javasrcfile . "\n$maybePublic final class $className implements Serializable {\n";
        }
    }
    elsif ($template eq "c5") {
        if ($numdepends == 1) {
            $javasrcfile = $javasrcfile . "\n$maybePublic class $className extends $lonedepends implements Serializable { // no longer final : compatible\n";
        }
        else {
            $javasrcfile = $javasrcfile . "\n$maybePublic class $className implements Serializable {\n";
        }
    }
    else {
        if ($numdepends == 1) {
            $javasrcfile = $javasrcfile . "\n$maybePublic $maybeFinalOrAbstract class $className extends $lonedepends implements Serializable {\n";
        }
        else {
            $javasrcfile = $javasrcfile . "\n$maybePublic $maybeFinalOrAbstract class $className implements Serializable {\n";
        }
    }

    if ($template eq "i2") {
        $javasrcfile = $javasrcfile . "    int field1 = 1; // field reduced visibility change is incompatible\n";
    }
    elsif ($template eq "i3") {
        $javasrcfile = $javasrcfile . "    // public int field1 = 1; // field removal is incompatible\n";
    }
    elsif ($template eq "i5") {
        $javasrcfile = $javasrcfile . "    public final int field1 = 1; // Changes to public/protected fields to make them final is incompatible\n";
    }
    elsif ($template eq "i6") {
        $javasrcfile = $javasrcfile . "    public static int field1 = 1; // Changes to public/protected fields to make them static is incompatible\n";
    }
    else {
        $javasrcfile = $javasrcfile . "    public int field1 = 1;\n";
    }

    if ($template eq "i12") {
        $javasrcfile = $javasrcfile . "    public static final int constant1 = 2; // changes to constants is incompatible \n";
    }
    else {
        $javasrcfile = $javasrcfile . "    public static final int constant1 = 1;\n";
    }

    if ($template eq "c3") {
        $javasrcfile = $javasrcfile . "    //private int field2 = 2; // Removing private field is compatible\n";
    }
    elsif ($template eq "c7") {
        $javasrcfile = $javasrcfile . "    public int field2 = 2; // Field increased visibility is compatible\n";
    }
    else {
        $javasrcfile = $javasrcfile . "    private int field2 = 2;\n";
    }

    if ($template eq "i5") {
        $javasrcfile = $javasrcfile . "    protected final int field3 = 3; // Changes to public/protected fields to make them final is incompatible\n";
    }
    elsif ($template eq "i6") {
        $javasrcfile = $javasrcfile . "    protected static int field3 = 3; // Changes to public/protected fields to make them static is incompatible\n";
    }
    else {
        $javasrcfile = $javasrcfile . "    protected int field3 = 3;\n";
    }

    if ($template eq "i15") {
        $javasrcfile = $javasrcfile . "    // Removal of pub static is incompatible public static int sfield1 = 4;\n";
    }
    else {
        $javasrcfile = $javasrcfile . "    public static int sfield1 = 4;\n";
    }

    if ($template eq "c2") {
        $javasrcfile = $javasrcfile . "    public int field4 = 4; // Addition of a new field is compatible\n";
    }
    $javasrcfile = $javasrcfile . "\n";
    $javasrcfile = $javasrcfile . "    public $className () {\n";
    $javasrcfile = $javasrcfile . "    }\n\n";

    if ($template eq "c3") {
        $javasrcfile = $javasrcfile . "    //private $className (String s) { // Removing private constructor is compatible\n";
        $javasrcfile = $javasrcfile . "    //}\n\n";
    }
    elsif ($template eq "c7") {
        $javasrcfile = $javasrcfile . "    public $className (String s) { // Making constructor more visible is compatible\n";
        $javasrcfile = $javasrcfile . "    }\n\n";
    }
    else {
        $javasrcfile = $javasrcfile . "    private $className (String s) {\n";
        $javasrcfile = $javasrcfile . "    }\n\n";
    }

    if ($template eq "c2") {
        $javasrcfile = $javasrcfile . "    public $className(int i) { // Addition of a new contructor is compatible\n";
        $javasrcfile = $javasrcfile . "    }\n\n";
    }

    if ($template eq "v1") {
        $javasrcfile = $javasrcfile . "    public int reducedmethodtest(int i) { return i; }\n";
        # Classes derived directly or indirectly from the final class that reduce method visibility must be detected and rebuilt (the build will fail)
    }
    elsif (defined $snippet) {
        $javasrcfile = $javasrcfile . $snippet;
    }

    if ($template eq "i13") {
        $javasrcfile = $javasrcfile . "    public abstract int addabstractmethodtest(int i);\n";
    }

    if ($template eq "i1") {
        $javasrcfile = $javasrcfile . "    public void $classNameLower" . "_1(int i) { // Changes to signature is incompatible\n";
    }
    elsif ($template eq "i7") {
        $javasrcfile = $javasrcfile . "    public final void $classNameLower" . "_1() { // Changes to public/protected methods to make them final is incompatible\n";
    }
    elsif ($template eq "c8") {
        $javasrcfile = $javasrcfile . "    public synchronized void $classNameLower" . "_1() { // Changes to make synchronized is compatible\n";
    }
    else {
        $javasrcfile = $javasrcfile . "    public void $classNameLower" . "_1() {\n";
    }

    if (defined $dependsFinalUsage) {
        $javasrcfile = $javasrcfile .  "        $dependsFinalUsage compFU = new $dependsFinalUsage();\n";
        $javasrcfile = $javasrcfile .  "        compFU." . lc($dependsFinalUsage) ."_1();\n";
    }

    if ($numdepends == 1) {
        if ($template ne "i8") {
            # This change removed superclass, which defined the instance method - so we have to remove it to make it build
            my @depends = @$depends;
            my $index = 0;
            foreach my $d (@depends) {
                $index = $index + 1;
                $javasrcfile = $javasrcfile .  "        " . lc($d) ."_1();\n";
            }
        }
    }
    elsif ($numdepends > 1) {
        my @depends = @$depends;
        my $index = 0;
        foreach my $d (@depends) {
            $index = $index + 1;
            $javasrcfile = $javasrcfile .  "        $d comp$index = new $d();\n";
            $javasrcfile = $javasrcfile .  "        comp$index." . lc($d) ."_1();\n";
        }
    }
    $javasrcfile = $javasrcfile . "    }\n\n";

    if ($template eq "i7") {
        $javasrcfile = $javasrcfile . "    protected final void $classNameLower" . "_2() { // Changes to public/protected methods to make them final is incompatible\n";
    }
    elsif ($template eq "c8") {
        $javasrcfile = $javasrcfile . "    protected synchronized void $classNameLower" . "_2() {\n";
    }
    else {
        $javasrcfile = $javasrcfile . "    protected void $classNameLower" . "_2() {\n";
    }
    $javasrcfile = $javasrcfile . "    }\n\n";

    if ($template eq "c1") {
        $javasrcfile = $javasrcfile . "    public void $classNameLower" . "_3() { // Adding methods is compatible\n";
        $javasrcfile = $javasrcfile . "    }\n\n";
    }

    if ($template eq "c3") {
        $javasrcfile = $javasrcfile . "    //private void $classNameLower" . "4() { // Removing private method is compatible\n";
        $javasrcfile = $javasrcfile . "    //}\n";
    }
    else {
        $javasrcfile = $javasrcfile . "    private void $classNameLower" . "_4() {\n";
        $javasrcfile = $javasrcfile . "    }\n";
    }

    $javasrcfile = $javasrcfile . "}";

    my $fileName = "$pkgdir/$className.java";
    if ($template ne "baseline") {
        $fileName = $fileName . "-$template";
    }
    _writeFile($fileName, $javasrcfile);

    _codeGenInterfaceTemplate($compName, $pkgdir, $template);
} # _codeGenTemplate

sub _codeGenInterfaceTemplate {
    my ($compName, $pkgdir, $template) = @_;

    # // This file is generated by IncrBuildMgrTest
    #
    # package ariba.incrBuildMgrTest.N;
    #
    # public interface Ninterface {
    #
    #     public void n_1();
    #     public void n_2();
    # }
    my $classNameLower = lc($compName);

    my $javasrcfile = "// This file is generated by IncrBuildMgrTest\n\n";
    $javasrcfile = $javasrcfile . "package ariba.$PACKAGE_NAME.$compName;\n\n";
    $javasrcfile = $javasrcfile . "public interface $compName" . "interface {\n\n";
    $javasrcfile = $javasrcfile . "    public void $classNameLower" . "_1();\n";
    if ($template eq "i14") {
        $javasrcfile = $javasrcfile . "    public void $classNameLower" . "_2(); // Adding interface methods is incompatible\n";
    }
    $javasrcfile = $javasrcfile . "}";

    my $fileName = "$pkgdir/$compName" . "interface.java";
    if ($template ne "baseline") {
        $fileName = $fileName . "-$template";
    }
    _writeFile($fileName, $javasrcfile);
}

#
# _codeGenComp
#
# Generates the directories:
# $TEMP_DIR/<testName>/<compName>/src/ariba/<PACKAGE_NAME>/<compName>
# $TEMP_DIR/<testName>/<compName>/classes
# $TEMP_DIR/<testName>/<compName>/jars
#
# Generates the files:
# $TEMP_DIR/<testName>/<compName>/src/ariba/<PACKAGE_NAME>/<compName>/<compName>.java-{c{1,2,3,4, etc},i{1,2,3,4 etc.}}
# $TEMP_DIR/<testName>/<compName>/Makefilef (has one line like: COMPONENT_NAME := A)
#
# Input 1: $dirName represents the sub directory under tmp to generate the files
# Input 2: $compName represents the Name of the component (ie "A")
# Input 3: $dependsArraryRef reference to an array of dependent component names (undef if none)
# Input 4: $root set to 1 to treat this component as a root
# Input 5: $abstract set to 1 to treat this component as abstract
# Input 6: $dependsFinalUsage name of final component to depend on via usage 
# Input 7: $final if set to 1 then treat this component as final 
# Input 8: $pkgoverride use this name for the generated package statement (instead of using $compName)
# Input 9: $snippet "java line code snippet to add 
#
# Return: reference to CompMeta for the component
sub _codeGenComp {
    my ($dirName, $compName, $depends, $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet) = @_;

    my $compMeta = ariba::rc::CompMeta->new();
    $compMeta->setName($compName);

    my $testdir = "$TEMP_DIR/$dirName";
    mkdir($testdir);

    my $td = "$testdir/" . $compMeta->getName();
    mkdir($td);

    my $classesdir = "$td/classes";
    mkdir($classesdir);

    my $jarsdir = "$td/jars";
    mkdir($jarsdir);

    my $srcdir = "$td/src";
    mkdir($srcdir);

    my $pkgdir = "$srcdir/ariba";
    mkdir($pkgdir);

    $pkgdir = "$pkgdir/$PACKAGE_NAME";
    mkdir($pkgdir);

    $pkgdir = "$pkgdir/$compName";
    mkdir($pkgdir);

    _codeGenTemplate($compName, $pkgdir, $depends, "baseline", $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet);

    _codeGenTemplate($compName, $pkgdir, $depends, "c1", $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet);
    _codeGenTemplate($compName, $pkgdir, $depends, "c2", $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet);
    _codeGenTemplate($compName, $pkgdir, $depends, "c3", $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet);
    _codeGenTemplate($compName, $pkgdir, $depends, "c4", $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet);
    _codeGenTemplate($compName, $pkgdir, $depends, "c5", $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet);
    _codeGenTemplate($compName, $pkgdir, $depends, "c6", $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet);
    _codeGenTemplate($compName, $pkgdir, $depends, "c7", $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet);
    _codeGenTemplate($compName, $pkgdir, $depends, "c8", $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet);
    _codeGenTemplate($compName, $pkgdir, $depends, "c9", $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet);
    _codeGenTemplate($compName, $pkgdir, $depends, "c10", $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet);

    _codeGenTemplate($compName, $pkgdir, $depends, "i1", $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet);
    _codeGenTemplate($compName, $pkgdir, $depends, "i2", $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet);
    _codeGenTemplate($compName, $pkgdir, $depends, "i3", $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet);
    _codeGenTemplate($compName, $pkgdir, $depends, "i4", $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet);
    _codeGenTemplate($compName, $pkgdir, $depends, "i5", $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet);
    _codeGenTemplate($compName, $pkgdir, $depends, "i6", $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet);
    _codeGenTemplate($compName, $pkgdir, $depends, "i7", $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet);
    _codeGenTemplate($compName, $pkgdir, $depends, "i8", $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet);
    _codeGenTemplate($compName, $pkgdir, $depends, "i9", $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet);
    _codeGenTemplate($compName, $pkgdir, $depends, "i10", $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet);
    _codeGenTemplate($compName, $pkgdir, $depends, "i11", $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet);
    _codeGenTemplate($compName, $pkgdir, $depends, "i12", $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet);
    _codeGenTemplate($compName, $pkgdir, $depends, "i13", $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet);
    _codeGenTemplate($compName, $pkgdir, $depends, "i14", $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet);
    _codeGenTemplate($compName, $pkgdir, $depends, "i15", $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet);

    _codeGenTemplate($compName, $pkgdir, $depends, "v1", $root, $abstract, $dependsFinalUsage, $final, $pkgoverride, $snippet);
    
    my $fileName = "$td/Makefile";
    _writeFile($fileName, "COMPONENT_NAME := $compName\n");

    if ($depends) {
        $compMeta->setDependencyNames($depends);
    }
    my $artifactPath = "$jarsdir/$compName.jar";
    my @artifactPaths = ($artifactPath);
    $compMeta->setPublishedArtifactPaths(\@artifactPaths);
    $compMeta->setSrcPath(($srcdir));
    return $compMeta;
}

# Input: $test the name of the test (scopes the artifact paths)
# Side-effect: Set the ARIBA_SOURCE_ROOT env varibale to point into the test directory
# Returns: reference to a test universe hash (comp name to CompMeta)
sub _loadTestUniverse {
    my ($test) = @_;
    my %testUniverse = %baselineUniverseHash;
    foreach my $compMeta (values %baselineUniverseHash) {
        my $compMetaClone = $compMeta->clone();
        my $baselineArtifactPathsRef = $compMetaClone->getPublishedArtifactPaths();
        my @baselineArtifactPaths = @$baselineArtifactPathsRef;
        my @testArtifactPaths = ();
        foreach my $ap (@baselineArtifactPaths) {
            # convert the occurance of $BASELINE_DIR_NAME to $test so the artifact paths are relative to the test directory
            $ap =~ s/$BASELINE_DIR_NAME/$test/;
            push (@testArtifactPaths, $ap);
        }
        $compMetaClone->setPublishedArtifactPaths(\@testArtifactPaths);
        $testUniverse{$compMetaClone->getName()} = $compMetaClone;
    }

    return \%testUniverse;
}

# Input 1: name of the test
# Input 2: reference to IncrBuildMgr
# Input 3: reference to subroutine to call when incremental build is successful
# Input 4: reference to subroutine to call when component build errors happen
# Input 5: reference to subroutine to call when metadata validation errors happen
#
# return style 1 (when wantResults == 0) reference to a hash of component names to compat flag value (0 compat;1 direct incompat; 2 transitively rebuilt)
# return style 2 (when wantResults != 0) reference to IncrBuildMgrResults
sub _runIncrBuild {
    my ($test, $bm, $successCB, $compBuildErrorCB, $metaValidationErrorCB) = @_;

    my $results;
    eval {
        $results = $bm->incrBuild();
    };
    if ($@) {
        my $is_increx = $@->isa("ariba::rc::IncrBuildMgrException");
        if ($is_increx) {
            my $incrBuildException = $@;
            my $cn = $incrBuildException->getComponentName();
            my $errormsg = $incrBuildException->getErrorMessage();
            if ($incrBuildException->isCompBuildError()) {
                if (defined $compBuildErrorCB) {
                    &{$compBuildErrorCB}($test, $incrBuildException);
                }
            }
            if ($incrBuildException->isMetaValidatorError()) {
                if (defined $metaValidationErrorCB) {
                    &{$metaValidationErrorCB}($test, $incrBuildException);
                }
            }
        }
        else {
            die $@; # rethrow - we don't know what this is
        }
    }
    elsif (defined $successCB) {
        &{$successCB}($test);
    }
    return $results;
}

sub _successIncrBuildCallbackExpectFailure {
    my ($test) = @_;
    print "$test: javac test case ERROR: The expected failure did not occur for the test\n";
}

sub _metaValidationErrorCallbackExpectSuccess {
    my ($test, $incrBuildMgrException) = @_;

    my $cn = $incrBuildMgrException->getComponentName();
    my $errormsg = $incrBuildMgrException->getErrorMessage();
    print "$test: Test case ERROR: The component \"$cn\" is not expected to have a metadata validation error. The error: \"$errormsg\".\n";
}

sub _metaValidationErrorCallbackExpectFailure {
    my ($test, $incrBuildMgrException) = @_;

    my $cn = $incrBuildMgrException->getComponentName();
    my $errormsg = $incrBuildMgrException->getErrorMessage();
    print "$test: SUCCESS: We got the expected metadata validation problem for component \"$cn\": \"$errormsg\"\n";
}

# The delta set is: {B:c1, D:i1}
sub _compBuildErrorCallbackTest1 {
    my ($test, $incrBuildMgrException) = @_;

    my $cn = $incrBuildMgrException->getComponentName();
    if ($cn eq "G" || $cn eq "C" || $cn eq "B" || $cn eq "A" || $cn eq "E") {
        print $test . ": SUCCESS : The expected build failure for component \"$cn\" matches the expectation\n";
    }
    else {
        print "$test: javac test case ERROR: The actual javac compiler result (failure) for component \"$cn\" does not match the expectation (success)\n";
    }
}

sub _compBuildErrorCallbackTest32 {
    my ($test, $incrBuildMgrException) = @_;

    my $cn = $incrBuildMgrException->getComponentName();
    if ($cn eq "C") {
        print $test . ": SUCCESS : The expected build failure for component \"$cn\" matches the expectation\n";
    }
    else {
        print "$test: javac test case ERROR: The actual javac compiler result (failure) for component \"$cn\" does not match the expectation (success)\n";
    }
}

sub _compBuildErrorCallbackTest33 {
    my ($test, $incrBuildMgrException) = @_;

    my $cn = $incrBuildMgrException->getComponentName();
    if ($cn eq "K") {
        print $test . ": SUCCESS : The expected build failure for component \"$cn\" matches the expectation\n";
    }
    else {
        print "$test: javac test case ERROR: The actual javac compiler result (failure) for component \"$cn\" does not match the expectation (success)\n";
    }
}

sub _compBuildErrorCallbackTest2 {
    my ($test, $incrBuildMgrException) = @_;

    my $cn = $incrBuildMgrException->getComponentName();
    if ($cn eq "A" || $cn eq "E") {
        print $test . ": SUCCESS : The expected build failure for component \"$cn\" matches the expectation\n";
    }
    else {
        print "$test: javac test case ERROR: The actual javac compiler result (failure) for component \"$cn\" does not match the expectation (success)\n";
    }
}

sub _compBuildErrorCallbackExpectSuccess {
    my ($test, $incrBuildMgrException) = @_;

    my $cn = $incrBuildMgrException->getComponentName();
    print "$test: javac test case ERROR: The actual javac compiler result (failure) for component \"$cn\" does not match the expectation (success)\n";
}

# The delta set is: {B:i1, D:i1}
sub _compBuildErrorCallbackTest4 {
    my ($test, $incrBuildMgrException) = @_;

    my $cn = $incrBuildMgrException->getComponentName();
    if ($cn eq "G" || $cn eq "C" || $cn eq "B" || $cn eq "A" || $cn eq "E") {
        print $test . ": SUCCESS : The expected build failure for component \"$cn\" matches the expectation\n";
    }
    else {
        print "$test: javac test case ERROR: The actual javac compiler result (failure) for component \"$cn\" does not match the expectation (success)\n";
    }
}

# The delta set is: {F:i1}
sub _compBuildErrorCallbackTest6 {
    my ($test, $incrBuildMgrException) = @_;

    my $cn = $incrBuildMgrException->getComponentName();
    if ($cn eq "D" || $cn eq "G" || $cn eq "C" || $cn eq "B" || $cn eq "A" || $cn eq "E") {
        print $test . ": SUCCESS : The expected build failure for component \"$cn\" matches the expectation\n";
    }
    else {
        print "$test: javac test case ERROR: The actual javac compiler result (failure) for component \"$cn\" does not match the expectation (success)\n";
    }
}

sub _compBuildErrorCallbackTest7_8 {
    my ($test, $incrBuildMgrException) = @_;

    my $cn = $incrBuildMgrException->getComponentName();
    if ($cn eq "G" || $cn eq "C" || $cn eq "B" || $cn eq "A" || $cn eq "E") {
        print $test . ": SUCCESS : The expected build failure for component \"$cn\" matches the expectation\n";
    }
    else {
        print "$test: javac test case ERROR: The actual javac compiler result (failure) for component \"$cn\" does not match the expectation (success)\n";
    }
}

sub _compBuildErrorCallbackTest18 {
    my ($test, $incrBuildMgrException) = @_;

    my $cn = $incrBuildMgrException->getComponentName();
    if ($cn eq "G" || $cn eq "C" || $cn eq "B" || $cn eq "A" || $cn eq "E") {
        print $test . ": SUCCESS : The expected build failure for component \"$cn\" matches the expectation\n";
    }
    else {
        print "$test: javac test case ERROR: The actual javac compiler result (failure) for component \"$cn\" does not match the expectation (success)\n";
    }
}

sub _compBuildErrorCallbackLIncompat {
    my ($test, $incrBuildMgrException) = @_;

    my $cn = $incrBuildMgrException->getComponentName();
    if ($cn eq "J" || $cn eq "I" || $cn eq "H" || $cn eq "M" || $cn eq "B" || $cn eq "A" || $cn eq "E") {
        print $test . ": SUCCESS : The expected build failure for component \"$cn\" matches the expectation\n";
    }
    else {
        print "$test: javac test case ERROR: The actual javac compiler result (failure) for component \"$cn\" does not match the expectation (success)\n";
    }
}

# _runTest1
#
# The delta set is: {B:c1, D:i1} 
# A Negative test case : some comps with dependencies on D will not compile
#
sub _runTest1 {

    my $test = "incrBuildMgrTest1";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing incremental build over change set {$deltaSpec}\n\tA negative test case: some comps with dependencies on D will not compile\n";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setBuildId($test);
    $bm->setDebug($debug);
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setWantResults(1);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest1);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest1);

    my $results = _runIncrBuild($test, $bm, \&_successIncrBuildCallbackExpectFailure, \&_compBuildErrorCallbackTest1, \&_metaValidationErrorCallbackExpectSuccess);

    if (defined $results) {
        print "$test: Test case ERROR: The component is expected to fail during javac compilation\n";
    }

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # runTest1

# _runTest2
#
# The delta set is: {B:i1, D:c1}
# A Negative test case : some comps with dependencies on B will not compile
#
sub _runTest2 {

    my $test = "incrBuildMgrTest2";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing incremental build over change set {$deltaSpec}\n\tA negative test case: some comps with dependencies on B will not compile\n";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest2);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest2);

    my $rebuildHashRef = _runIncrBuild($test, $bm, \&_successIncrBuildCallbackExpectFailure, \&_compBuildErrorCallbackTest2, \&_metaValidationErrorCallbackExpectSuccess);

    if (defined $rebuildHashRef && (keys %{$rebuildHashRef}) > 0) {
        print "$test: Test case ERROR: The component is expected to fail during javac compilation\n";
    }

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest2

# _runTest3
#
# The delta set is: {B:c1, D:c1}
#
sub _runTest3 {

    my $test = "incrBuildMgrTest3";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing incremental build over change set {$deltaSpec}\n";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);
    $bm->setWantResults(1);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest3);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest3);

    my $resultsRef = _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectSuccess);

    _printResults($test, $resultsRef);
    _assertResultsTest3($test, $resultsRef);

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} #_runTest3

# _runTest4
#
# The delta set is: {B:i1, D:i1}
# A Negative test case : some comps with dependencies on B,D will not compile
#
sub _runTest4 {

    my $test = "incrBuildMgrTest4";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing incremental build over change set {$deltaSpec}\n\tA negative test case: some comps with dependencies on B,D will not compile\n";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest4);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest4);

    my $rebuildHashRef = _runIncrBuild($test, $bm, \&_successIncrBuildCallbackExpectFailure, \&_compBuildErrorCallbackTest4, \&_metaValidationErrorCallbackExpectSuccess);

    if (defined $rebuildHashRef && (keys %{$rebuildHashRef}) > 0) {
        print "$test: Test case ERROR: The component is expected to fail during javac compilation\n";
    }

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest4

# _runTest5
#
# The delta set is: {F:c1}
#
sub _runTest5 {

    my $test = "incrBuildMgrTest5";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing incremental build over change set {$deltaSpec}\n";

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest5);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest5);

    my $rebuildHashRef = _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectSuccess);

    _printSortedRebuildList($test, $rebuildHashRef);
    my @rebuildList = keys %{$rebuildHashRef};
    _assertResultsTest5_26($test, \@rebuildList);

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest5

# _runTest6
#
# The delta set is: {F:i1}
# A Negative test case : some comps with dependencies on F will not compile
#
sub _runTest6 {

    my $test = "incrBuildMgrTest6";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing incremental build over change set {$deltaSpec}\n\tA negative test case: some comps with dependencies on F will not compile\n";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest6);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest6);

    my $rebuildHashRef = _runIncrBuild($test, $bm, \&_successIncrBuildCallbackExpectFailure, \&_compBuildErrorCallbackTest6, \&_metaValidationErrorCallbackExpectSuccess);

    if (defined $rebuildHashRef && (keys %{$rebuildHashRef}) > 0) {
        print "$test: Test case ERROR: The component is expected to fail during javac compilation\n";
    }

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest6

# _runTest7
#
# The delta set is: {B:c1, D:i2}
#
sub _runTest7 {

    my $test = "incrBuildMgrTest7";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing incremental build over change set {$deltaSpec}\n";

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest7);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest7);

    my $rebuildHashRef = _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectSuccess);

    _printSortedRebuildList($test, $rebuildHashRef);
    my @rebuildList = keys %{$rebuildHashRef};
    _assertResultsTest7_8($test, \@rebuildList);

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest7

# _runTest8
#
# The delta set is: {B:c1, D:i3}
#
sub _runTest8 {

    my $test = "incrBuildMgrTest8";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing incremental build over change set {$deltaSpec}\n";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest8);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest8);

    my $rebuildHashRef = _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectSuccess);

    _printSortedRebuildList($test, $rebuildHashRef);
    my @rebuildList = keys %{$rebuildHashRef};
    _assertResultsTest7_8($test, \@rebuildList);

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest8

# _runTest9
#
# The delta set is: {L:c1}
#
sub _runTest9 {

    my $test = "incrBuildMgrTest9";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing incremental build over change set {$deltaSpec}\n";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest9);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest9);

    my $rebuildHashRef = _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectSuccess);

    _printSortedRebuildList($test, $rebuildHashRef);
    my @rebuildList = keys %{$rebuildHashRef};
    _assertResultsTest9($test, \@rebuildList);

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest9

# _runTest10
#
# The delta set is: {L:i1}
# A Negative test case : some comps with dependencies on L will not compile
#
sub _runTest10 {

    my $test = "incrBuildMgrTest10";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing incremental build over change set {$deltaSpec}\n\tA negative test case: some comps with dependencies on L will not compile\n";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest10);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest10);

    my $rebuildHashRef = _runIncrBuild($test, $bm, \&_successIncrBuildCallbackExpectFailure, \&_compBuildErrorCallbackLIncompat, \&_metaValidationErrorCallbackExpectSuccess);

    if (defined $rebuildHashRef && (keys %{$rebuildHashRef}) > 0) {
        print "$test: Test case ERROR: The component is expected to fail during javac compilation\n";
    }

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest10

# _runTest11
#
# The delta set is: {L:i4}
#
sub _runTest11 {

    my $test = "incrBuildMgrTest11";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing incremental build over change set {$deltaSpec}\n";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);

#    Example of registering a callback hook to perform test specific binary compat checking
#    $bm->setBinaryCompatibilityChecker(\&_binaryCompatCheckerTest10_11);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest11);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest11);

    my $rebuildHashRef = _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectSuccess);

    _printSortedRebuildList($test, $rebuildHashRef);
    my @rebuildList = keys %{$rebuildHashRef};
    _assertResultsLIncompat($test, \@rebuildList);

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest11

# _runTest35
#
# The delta set is: {L:i15}
#
sub _runTest35 {

    my $test = "incrBuildMgrTest35";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing incremental build over change set {$deltaSpec}\n";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);

#    Example of registering a callback hook to perform test specific binary compat checking
#    $bm->setBinaryCompatibilityChecker(\&_binaryCompatCheckerTest10_11);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest35);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest35);

    my $rebuildHashRef = _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectSuccess);

    _printSortedRebuildList($test, $rebuildHashRef);
    my @rebuildList = keys %{$rebuildHashRef};
    _assertResultsLIncompat($test, \@rebuildList);

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest35

# _runTest12
#
# The delta set is: {L:i5}
#
sub _runTest12 {

    my $test = "incrBuildMgrTest12";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing incremental build over change set {$deltaSpec}\n";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest12);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest12);

    my $rebuildHashRef = _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectSuccess);

    _printSortedRebuildList($test, $rebuildHashRef);
    my @rebuildList = keys %{$rebuildHashRef};
    _assertResultsLIncompat($test, \@rebuildList);

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest12

# _runTest13
#
# The delta set is: {L:i6}
#
sub _runTest13 {

    my $test = "incrBuildMgrTest13";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing incremental build over change set {$deltaSpec}\n";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest13);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest13);

    my $rebuildHashRef = _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectSuccess);

    _printSortedRebuildList($test, $rebuildHashRef);
    my @rebuildList = keys %{$rebuildHashRef};
    _assertResultsLIncompat($test, \@rebuildList);

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest13

# _runTest14
#
# The delta set is: {L:i7}
#
sub _runTest14 {

    my $test = "incrBuildMgrTest14";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing incremental build over change set {$deltaSpec}\n";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest14);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest14);

    my $rebuildHashRef = _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectSuccess);

    _printSortedRebuildList($test, $rebuildHashRef);
    my @rebuildList = keys %{$rebuildHashRef};
    _assertResultsLIncompat($test, \@rebuildList);

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest14

# _runTest15
#
# The delta set is: {L:c2}
#
sub _runTest15 {

    my $test = "incrBuildMgrTest15";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing incremental build over change set {$deltaSpec}\n";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest15);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest15);

    my $rebuildHashRef = _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectSuccess);

    _printSortedRebuildList($test, $rebuildHashRef);
    my @rebuildList = keys %{$rebuildHashRef};
    _assertResultsLCompat($test, \@rebuildList);

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest15

# _runTest16
#
# The delta set is: {C:i8}
#
sub _runTest16 {

    my $test = "incrBuildMgrTest16";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing incremental build over change set {$deltaSpec}\n";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest16);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest16);

    my $rebuildHashRef = _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectSuccess);

    _printSortedRebuildList($test, $rebuildHashRef);
    my @rebuildList = keys %{$rebuildHashRef};
    _assertResultsTest16($test, \@rebuildList);

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest16

# _runTest17
#
# The delta set is: {C:i9}
#
sub _runTest17 {

    my $test = "incrBuildMgrTest17";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing incremental build over change set {$deltaSpec}\n";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest17);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest17);

    my $rebuildHashRef = _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectSuccess);

    _printSortedRebuildList($test, $rebuildHashRef);
    my @rebuildList = keys %{$rebuildHashRef};
    _assertResultsTest17($test, \@rebuildList);

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest17

# _runTest18
#
# The delta set is: {B:c1, D:i1}
# A Negative test case : some comps with dependencies on D will not compile
#
sub _runTest18 {

    my $test = "incrBuildMgrTest18";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing incremental build over change set {$deltaSpec}\n\tA negative test case: some comps with dependencies on D will not compile\n";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest18);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest18);

    my $rebuildHashRef = _runIncrBuild($test, $bm, \&_successIncrBuildCallbackExpectFailure, \&_compBuildErrorCallbackTest18, \&_metaValidationErrorCallbackExpectSuccess);

    if (defined $rebuildHashRef && (keys %{$rebuildHashRef}) > 0) {
        print "$test: Test case ERROR: The component is expected to fail during javac compilation\n";
    }

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest18

# _runTest19
#
# The delta set is: {B:c1} # metadata validation mismatch test (extra ambiguous dependency)
#
sub _runTest19 {

    my $test = "incrBuildMgrTest19";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing incremental build over change set {$deltaSpec}: Metadata validation test for extra ambiguous dependency\n";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    # Special case where we add an ambiguous dependency - revisit the cleanup later
    my @delta = (); # includes all components that were known to change
    my $compMeta = $testUniverseRef->{"B"};
    my $dependencyNamesRef = $compMeta->getDependencyNames();
    my @dependencyNames = @$dependencyNamesRef;
    push (@dependencyNames, "F");
    $compMeta->setDependencyNames(\@dependencyNames);
    push (@delta, $compMeta);

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest19);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest19);

    my $rebuildHashRef = _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectSuccess);

    _printSortedRebuildList($test, $rebuildHashRef);
    my @rebuildList = keys %{$rebuildHashRef};
    _assertResultsTest19($test, \@rebuildList);

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest19

# _runTest20
#
# The delta set is: {B:c1} # Negative test: Metadata validation mismatch (missing dependency)
#
sub _runTest20 {

    my $test = "incrBuildMgrTest20";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing incremental build over change set {$deltaSpec}\n\tA negative test case: metadata validation mismatch (missing dependency with die)\n";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    # Special case where we add an ambiguous dependency - revisit the cleanup later
    my @delta = (); # includes all components that were known to change
    my $compMeta = $testUniverseRef->{"B"};
    my @dependencyNames = ();
    push (@dependencyNames, "C");
    push (@dependencyNames, "F");
    # D is missing; it is masked by the fact that C depends on G which depends on D
    $compMeta->setDependencyNames(\@dependencyNames);
    push (@delta, $compMeta);

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest20);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest20);

    my $rebuildHashRef = _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectFailure);

    if (defined $rebuildHashRef && (keys %{$rebuildHashRef}) > 0) {
        print "$test: Test case ERROR: The component is expected to fail during javac compilation\n";
    }

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest20

# _runTest27
#
# The delta set is: {B:c1} # Negative test: Metadata validation mismatch (missing dependency)
#
sub _runTest27 {

    my $test = "incrBuildMgrTest27";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing incremental build over change set {$deltaSpec}\n\tA negative test case: metadata validation mismatch (missing dependency no die)\n";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    # Special case where we add an ambiguous dependency - revisit the cleanup later
    my @delta = (); # includes all components that were known to change
    my $compMeta = $testUniverseRef->{"B"};
    my @dependencyNames = ();
    push (@dependencyNames, "C");
    push (@dependencyNames, "F");
    # D is missing; it is masked by the fact that C depends on G which depends on D
    $compMeta->setDependencyNames(\@dependencyNames);
    push (@delta, $compMeta);

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();

    $bm->dieOnValidateMetadataMismatches(0); # The IncrBuildMgrResults contains the mismatch data

    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);
    $bm->setWantResults(1);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest27);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest27);

    my $results = _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectFailure);

    my $expectedResults = ariba::rc::IncrBuildMgrResults->new();

    my @missingList = ("D", "Mdup|M");
    $expectedResults->addMissingDependenciesForComp("B", \@missingList);

    $expectedResults->addCompToRebuildSetAsCompatible("B");

    if (! defined $results) {
        print "$test: Test case ERROR: The expected results are not available\n";
    }

    _printResults($test, $results);

    my $identical = $results->compare($expectedResults);

    my $ars = $results->toString();
    my $ers = $expectedResults->toString();

    if ($identical) {
        # So far so good - now check that the toString() vs fromString work as expected
        my $er = ariba::rc::IncrBuildMgrResults->new();
        $er->fromString($ers);
        my $identical2 = $results->compare($er);
        if ($identical2) {
            my $identical3 = $results->compare($ers);
            if ($identical3) {
                print "$test: Test case SUCCESS: The expected results (including all toString/fromString comparisons) match the expectation\n";
            }
            else {
                print "$test: Test case ERROR: The expected results match the expectation but the string form of comaparison failed\n";
            }
        }
        else {
            print "$test: Test case ERROR: The expected results match the expectation, but the toString/fromString comparison failed\n";
        }
    }
    else {
        print "$test: Test case ERROR: The actual results do not match the expectation\n";
        print "\tThe expected results = $ers\n";
        print "\tThe actual results   = $ars\n";
    }

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest27

# _runTest21
#
# The delta set is: {L:c3}
#
sub _runTest21 {

    my $test = "incrBuildMgrTest21";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing incremental build over change set {$deltaSpec}\n";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest21);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest21);

    my $rebuildHashRef = _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectSuccess);

    _printSortedRebuildList($test, $rebuildHashRef);
    my @rebuildList = keys %{$rebuildHashRef};
    _assertResultsTest21($test, \@rebuildList);

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest21

# _runTest22
#
# The delta set is: {B:c5}
#
sub _runTest22 {

    my $test = "incrBuildMgrTest22";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing incremental build over change set {$deltaSpec}\n";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest22);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest22);

    my $rebuildHashRef = _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectSuccess);

    _printSortedRebuildList($test, $rebuildHashRef);
    my @rebuildList = keys %{$rebuildHashRef};
    _assertResultsTest22($test, \@rebuildList);

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest22

# _runTest23
#
# The delta set is: {B:c6}
#
sub _runTest23 {

    my $test = "incrBuildMgrTest23";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing incremental build over change set {$deltaSpec}\n";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest23);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest23);

    my $rebuildHashRef = _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectSuccess);

    _printSortedRebuildList($test, $rebuildHashRef);
    my @rebuildList = keys %{$rebuildHashRef};
    _assertResultsTest23($test, \@rebuildList);

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest23

# _runTest24
#
# The delta set is: {K2:c4}
#
sub _runTest24 {

    my $test = "incrBuildMgrTest24";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing incremental build over change set {$deltaSpec}\n";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest24);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest24);

    my $rebuildHashRef = _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectSuccess);

    _printSortedRebuildList($test, $rebuildHashRef);
    my @rebuildList = keys %{$rebuildHashRef};
    _assertResultsTest24_25($test, \@rebuildList);

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest24

# _runTest25
#
# The delta set is: {K2:c7}
#
sub _runTest25 {

    my $test = "incrBuildMgrTest25";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing incremental build over change set {$deltaSpec}\n";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest25);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest25);

    my $rebuildHashRef = _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectSuccess);

    _printSortedRebuildList($test, $rebuildHashRef);
    my @rebuildList = keys %{$rebuildHashRef};
    _assertResultsTest24_25($test, \@rebuildList);

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest25

# _runTest26
#
# The delta set is: {F:c8}
#
sub _runTest26 {

    my $test = "incrBuildMgrTest26";

    my $deltaSpec = $testDeltas{$test};

    print $test . ": Performing incremental build over change set {$deltaSpec}\n";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();

    $bm->dieOnValidateMetadataMismatches(0); # The IncrBuildMgrResults contains the mismatch data

    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);
    $bm->setWantResults(0);
    $bm->setFullBuild(0);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest26);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest26);

    my $rebuildHashRef = _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectSuccess);

    _printSortedRebuildList($test, $rebuildHashRef);
    my @rebuildList = keys %{$rebuildHashRef};
    _assertResultsTest5_26($test, \@rebuildList);

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest26

# _runTest28
#
sub _runTest28 {
    my $test = "incrBuildMgrTest28";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing full build using incremental build manager\n";

    my $testUniverseRef = _loadTestUniverse($test);

    my $actingAsAbootstrapCompMeta = $testUniverseRef->{"J"};
    $actingAsAbootstrapCompMeta->markAsBootstrap(1);

    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();

    $bm->dieOnValidateMetadataMismatches(0); # The IncrBuildMgrResults contains the mismatch data

    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);
    $bm->setWantResults(1);
    $bm->setFullBuild(1);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest28);

    $bm->init($test, \@testUniverse, undef, "1.0", \&_componentBuildCallbackTest28);

    $bm->loadDelta(\@delta);

    my $results = _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectFailure);

    my $expectedResults = ariba::rc::IncrBuildMgrResults->new();

    for my $c (keys %$testUniverseRef) {
        if ($c eq "H" || $c eq "I" || $c eq "J" || $c eq "K2" || $c eq "K" || $c eq "L" || $c eq "M") {
            $expectedResults->addCompToRebuildSetAsBootstrap($c);
        }
        else {
            $expectedResults->addCompToRebuildSetAsCompatible($c);
        }
    }

    if (! defined $results) {
        print "$test: Test case ERROR: The expected results are not available\n";
    }

    _printResults($test, $results);

    my $identical = $results->compare($expectedResults);

    my $ars = $results->toString();
    my $ers = $expectedResults->toString();

    if ($identical) {
        # So far so good - now check that the toString() vs fromString work as expected
        my $er = ariba::rc::IncrBuildMgrResults->new();
        $er->fromString($ers);
        my $identical2 = $results->compare($er);
        if ($identical2) {
            print "$test: Test case SUCCESS: The actual results (including the toString/fromString comparison) match the expectation\n";
        }
        else {
            print "$test: Test case ERROR: The actual results match the expectation, but the toString/fromString comparison failed\n";
        }
    }
    else {
        print "$test: Test case ERROR: The actual results do not match the expectation\n";
        print "\tThe expected results = $ers\n";
        print "\tThe actual results   = $ars\n";
    }

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";

    # Display the product universe dependency DAG as ascii-art
    print "$test: Dependency diagram below\n";
    $bm->reportDependencyDAG();
    print "$test: Dependency diagram above\n";
}

# _runTest29
#
sub _runTest29 {
    my $test = "incrBuildMgrTest29";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing report rebuild list only for incompatible change to \"B\"\n";

    my $testUniverseRef = _loadTestUniverse($test);
    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    my $bm = ariba::rc::IncrBuildMgr->new();

    $bm->dieOnValidateMetadataMismatches(0); # The IncrBuildMgrResults contains the mismatch data

    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);
    $bm->setWantResults(1);
    $bm->reportRebuildListOnly(1);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest29);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest29);

    my $results = _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectFailure);

    my $expectedResults = ariba::rc::IncrBuildMgrResults->new();

    for my $c (keys %$testUniverseRef) {
        if ($c eq "B") {
            $expectedResults->addCompToRebuildSetAsIncompatible($c);
        }
        else {
            $expectedResults->addCompToRebuildSetAsTransitive($c);
        }
    }

    if (! defined $results) {
        print "$test: Test case ERROR: The expected results are not available\n";
    }

    _printResults($test, $results);

    my $identical = $results->compare($expectedResults);

    if ($identical) {
        # So far so good - now check that the toString() vs fromString work as expected
        my $ers = $expectedResults->toString();
        my $er = ariba::rc::IncrBuildMgrResults->new();
        $er->fromString($ers);
        my $identical2 = $results->compare($er);
        if ($identical2) {
            print "$test: Test case SUCCESS: The expected results (including the toString/fromString comparison) match the expectation\n";
        }
        else {
            print "$test: Test case ERROR: The expected results match the expectation, but the toString/fromString comparison failed\n";
        }
    }
    else {
        print "$test: Test case ERROR: The expected results do not match the expectation\n";
    }

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
}

# _runTest30
#
sub _runTest30 {
    my $test = "incrBuildMgrTest30";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing expected results test for incompat change to \"M\"\n";

    my $testUniverseRef = _loadTestUniverse($test);

    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    # Display the product universe dependency DAG as ascii-art
    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest30);
    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest30);

    my $er = $bm->getExpectedResults(1);
    my $ers = $er->toString();
    print "$test: The \"what if\" expected rebuild list for incompatible change to \"M\": $ers\n";

    my $er2 = ariba::rc::IncrBuildMgrResults->new();
    $er2->addCompToRebuildSetAsIncompatible("M");
    $er2->addCompToRebuildSetAsTransitive("B");
    $er2->addCompToRebuildSetAsTransitive("A");
    $er2->addCompToRebuildSetAsTransitive("E");
    $er2->addCompToRebuildSetAsTransitive("J");
    $er2->addCompToRebuildSetAsTransitive("I");
    $er2->addCompToRebuildSetAsTransitive("H");

    my $er2s = $er2->toString();

    my $identical = $er->compare($er2);
    if ($identical) {
        print "$test: SUCCESS : The results match the expectations\n";
    }
    else {
        print "$test: ERROR : The results disagree with the expected results\n";
        print "$test: The \"what if\" expected results for M:i is \"$ers\"\n";
        print "$test:     The test assertion results for F:i is \"$er2s\"\n";
    }
}

# _runTest31
#
sub _runTest31 {
    my $test = "incrBuildMgrTest31";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": Performing expected results test for incompat change to constant to \"M\"\n";

    my $testUniverseRef = _loadTestUniverse($test);

    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change
    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    # Display the product universe dependency DAG as ascii-art
    my $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest31);
    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest31);

    my $er = $bm->getExpectedResults(1);
    my $ers = $er->toString();
    print "$test: The \"what if\" expected rebuild list for incompatible change to \"M\": $ers\n";

    my $er2 = ariba::rc::IncrBuildMgrResults->new();
    $er2->addCompToRebuildSetAsIncompatible("M");
    $er2->addCompToRebuildSetAsTransitive("B");
    $er2->addCompToRebuildSetAsTransitive("A");
    $er2->addCompToRebuildSetAsTransitive("E");
    $er2->addCompToRebuildSetAsTransitive("J");
    $er2->addCompToRebuildSetAsTransitive("I");
    $er2->addCompToRebuildSetAsTransitive("H");

    my $er2s = $er2->toString();

    my $identical = $er->compare($er2);
    if ($identical) {
        print "$test: SUCCESS : The results match the expectations\n";
    }
    else {
        print "$test: ERROR : The results disagree with the expected results\n";
        print "$test: The \"what if\" expected results for M:i is \"$ers\"\n";
        print "$test:     The test assertion results for F:i is \"$er2s\"\n";
    }
}

# _runTest32
#
# The delta set is: {F:v1}
#
sub _runTest32 {

    my $test = "incrBuildMgrTest32";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": A negative test case: some comps with dependencies on F will not compile\n";

    # First perform a full build in incrementalmode (so indexes are created)
    # TODO: Change the baseline build to perform full builds using IncrBuildMgr

    print $test . ": Performing full build using incremental build manager\n";

    my $testUniverseRef = _loadTestUniverse($test);

    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change

    my $bm = ariba::rc::IncrBuildMgr->new();

    $bm->dieOnValidateMetadataMismatches(0); # The IncrBuildMgrResults contains the mismatch data

    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);
    $bm->setWantResults(1);
    $bm->setFullBuild(1);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest32_fullbuildprep);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest32);

    my $results = _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectSuccess);

    # Now build in pure incremental mode

    print $test . ": Performing incremental build over change set {$deltaSpec}\n";

    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);
    $bm->setWantResults(1);
    $bm->setFullBuild(0);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest32_templatesonly);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest32);

    $results =  _runIncrBuild($test, $bm, \&_successIncrBuildCallbackExpectFailure, \&_compBuildErrorCallbackTest32, \&_metaValidationErrorCallbackExpectSuccess);

    if (defined $results) {
        print "$test: Test case ERROR: A component is expected to fail during javac compilation\n";
    }

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest32

# _runTest33
#
# The delta set is: {K2:i13}
#
sub _runTest33 {

    my $test = "incrBuildMgrTest33";

    my $deltaSpec = $testDeltas{$test};
    print $test . ": A negative test case: some comps with dependencies on K2 will not compile\n";

    # First perform a full build in incrementalmode (so indexes are created)
    # TODO: Change the baseline build to perform full builds using IncrBuildMgr

    print $test . ": Performing full build using incremental build manager\n";

    my $testUniverseRef = _loadTestUniverse($test);

    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change

    my $bm = ariba::rc::IncrBuildMgr->new();

    $bm->dieOnValidateMetadataMismatches(0); # The IncrBuildMgrResults contains the mismatch data

    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);
    $bm->setWantResults(1);
    $bm->setFullBuild(1);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest33_fullbuildprep);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest33);

    my $results = _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectSuccess);

    # Now build in pure incremental mode

    print $test . ": Performing incremental build over change set {$deltaSpec}\n";

    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);
    $bm->setWantResults(1);
    $bm->setFullBuild(0);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest33_templatesonly);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest33);

    $results =  _runIncrBuild($test, $bm, \&_successIncrBuildCallbackExpectFailure, \&_compBuildErrorCallbackTest33, \&_metaValidationErrorCallbackExpectSuccess);

    if (defined $results) {
        print "$test: Test case ERROR: A component is expected to fail during javac compilation\n";
    }

    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest33

# _runTest34
#
# The delta set is: {K2:i14}
#
sub _runTest34 {

    my $test = "incrBuildMgrTest34";

    my $deltaSpec = $testDeltas{$test};

    # First perform a full build in incrementalmode (so indexes are created)
    # TODO: Change the baseline build to perform full builds using IncrBuildMgr

    print $test . ": Performing full build using incremental build manager\n";

    my $testUniverseRef = _loadTestUniverse($test);

    my @testUniverse = (values %$testUniverseRef);

    my @delta = (); # includes all components that were known to change

    my $bm = ariba::rc::IncrBuildMgr->new();

    $bm->dieOnValidateMetadataMismatches(0); # The IncrBuildMgrResults contains the mismatch data

    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);
    $bm->setWantResults(1);
    $bm->setFullBuild(1);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest34_fullbuildprep);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest34);

    my $results = _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectSuccess);

    # Now build in pure incremental mode

    print $test . ": Performing incremental build over change set {$deltaSpec}\n";

    my @comps = _getCompsFromDeltaSpec($deltaSpec);
    for my $c (@comps) {
        my $compMeta = $testUniverseRef->{$c};
        push (@delta, $compMeta);
    }

    my $startTime = gettimeofday;

    $bm = ariba::rc::IncrBuildMgr->new();
    $bm->setIndexDirectory("$TEMP_DIR/$test");
    $bm->setBuildId($test);
    $bm->setDebug($debug);
    $bm->setWantResults(1);
    $bm->setFullBuild(0);

    $bm->setPriorBuildImageInstaller(\&_priorBuildImageInstallerTest34_templatesonly);

    $bm->init($test, \@testUniverse, \@delta, "1.0", \&_componentBuildCallbackTest34);

    $results =  _runIncrBuild($test, $bm, undef, \&_compBuildErrorCallbackExpectSuccess, \&_metaValidationErrorCallbackExpectSuccess);

    my $er2 = ariba::rc::IncrBuildMgrResults->new();
    $er2->addCompToRebuildSetAsIncompatible("K2");
    $er2->addCompToRebuildSetAsTransitive("K");
    $er2->addCompToRebuildSetAsTransitive("J");
    $er2->addCompToRebuildSetAsTransitive("I");
    $er2->addCompToRebuildSetAsTransitive("H");

    my $identical = $results->compare($er2);
    if ($identical) {
        print "$test: SUCCESS : The results match the expectations\n";
    }
    else {
        print "$test: ERROR : The results disagree with the expected results\n";
    }
    my $elapsedTime = gettimeofday-$startTime;
    print $test . ": Elapsed time: $elapsedTime secs\n\n";
} # _runTest34

sub _printResults {
    my ($test, $resultsRef) = @_;
    print "$test : " . $resultsRef->toString() . "\n";
}

# TODO: phase this out in favor of using _printResults (using IncrBuildMgrResults approach)
sub _printSortedRebuildList {
    my ($test, $rebuildHashRef) = @_;

    my @rebuildList = keys %{$rebuildHashRef};

    print $test . ": The rebuild list is: { ";


    my @sortedRebuildList = sort @rebuildList;
    my $count = 0;
    foreach my $component (@sortedRebuildList) {
        $count ++;
        my $compatflag = $rebuildHashRef->{$component};
        # TODO use constants 
        if ($compatflag == 0) {
            print $component . ":c ";
        }
        elsif ($compatflag == 1) {
            print $component . ":i ";
        }
        elsif ($compatflag == 2) {
            print $component . ":t ";
        }
        elsif ($compatflag == 3) {
            print $component . ":ti ";
        }
        elsif ($compatflag == 4) {
            print $component . ":d ";
        }
        elsif ($compatflag == 16) {
            print $component . ":v ";
        }
        else {
            print $component . ":$compatflag "; # should never get here
        }
    }
    print "}\n";
}

# Emulate the binary compatibility checker to always return 1
#
# Input 1: String path to published artifact
# Input 2: String path to backed up published artifact
# return 0 if compatible; 1 otherwise
sub _binaryCompatCheckerTest10_11 {
    my ($artifact, $backupartifact) = @_;
    return 1;
}

sub _priorBuildImageInstallerCommon {
    my ($test, $deltaSpec) = @_;

    # Copy the baseline structure and it's artifacts to the test directory
    my $cmd = "rm -rf $TEMP_DIR/$test";
    system($cmd);

    $cmd = "cp -r $TEMP_DIR/$BASELINE_DIR_NAME $TEMP_DIR/$test";
    if ($debug) {
        print "IncrBuildMgrTest: Installing prior build. cmd = \"$cmd\"\n";
    }
    system($cmd);

    if ($deltaSpec) {
        _prepForComponentBuildFromDelta($test, $deltaSpec);
    }
}

# Input 1: String baseLabel
# This test program uses this hook to make sure the baseline java files
# and artifacts are in place.
sub _priorBuildImageInstallerTest1 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest1";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest2 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest2";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest3 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest3";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest4 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest4";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest5 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest5";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest6 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest6";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest7 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest7";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest8 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest8";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest9 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest9";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest10 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest10";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest11 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest11";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest35 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest35";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest12 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest12";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest13 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest13";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest14 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest14";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest15 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest15";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest16 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest16";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest17 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest17";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest18 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest18";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest19 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest19";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest20 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest20";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest21 {
    my ($baseLabel) = @_;
    _priorBuildImageInstallerCommon("incrBuildMgrTest21");
    my $test = "incrBuildMgrTest21";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest22 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest22";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest23 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest23";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest24 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest24";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest25 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest25";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest26 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest26";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest27 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest27";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest28 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest28";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest29 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest29";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest30 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest30";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest31 {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest31";
    my $delta = $testDeltas{$test};
    _priorBuildImageInstallerCommon($test, $delta);
}

sub _priorBuildImageInstallerTest32_templatesonly {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest32";
    my $deltaSpec = $testDeltas{$test};
    _prepForComponentBuildFromDelta($test, $deltaSpec);
}

sub _priorBuildImageInstallerTest32_fullbuildprep {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest32";
    _priorBuildImageInstallerCommon($test);
}

sub _priorBuildImageInstallerTest33_templatesonly {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest33";
    my $deltaSpec = $testDeltas{$test};
    _prepForComponentBuildFromDelta($test, $deltaSpec);
}

sub _priorBuildImageInstallerTest33_fullbuildprep {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest33";
    _priorBuildImageInstallerCommon($test);
}

sub _priorBuildImageInstallerTest34_templatesonly {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest34";
    my $deltaSpec = $testDeltas{$test};
    _prepForComponentBuildFromDelta($test, $deltaSpec);
}

sub _priorBuildImageInstallerTest34_fullbuildprep {
    my ($baseLabel) = @_;
    my $test = "incrBuildMgrTest34";
    _priorBuildImageInstallerCommon($test);
}

sub _assertResultsLIncompat {
    my ($test, $rebuildListRef) = @_;

    my %expectedSet = ();
    $expectedSet{"L"} = "L";
    $expectedSet{"J"} = "J";
    $expectedSet{"I"} = "I";
    $expectedSet{"H"} = "H";
    my $expectedSetSize = keys %expectedSet;

    my @actualRebuildList = @$rebuildListRef;
    my $actualRebuildListSize = @actualRebuildList;
    my $errormsg = $test . ": ERROR : The actual results disagree with the expected results\n";
    if ($actualRebuildListSize != $expectedSetSize) {
        print $errormsg;
        return;
    }
    foreach my $compName (@actualRebuildList) {
        if (! exists $expectedSet{$compName}) {
            print $errormsg;
            return;
        }
    }
    print $test . ": SUCCESS : The actual results match the expectations\n";
}

sub _assertResultsTest7_8 {
    my ($test, $rebuildListRef) = @_;

    my %expectedSet = ();
    $expectedSet{"A"} = "A";
    $expectedSet{"B"} = "B";
    $expectedSet{"C"} = "C";
    $expectedSet{"D"} = "D";
    $expectedSet{"E"} = "E";
    $expectedSet{"G"} = "G";
    my $expectedSetSize = keys %expectedSet;
    # Component "F" is not expected to be rebuilt because D was the incompat changed artifact 
    # and F does not depend on D

    my @actualRebuildList = @$rebuildListRef;
    my $actualRebuildListSize = @actualRebuildList;
    my $errormsg = $test . ": ERROR : The actual results disagree with the expected results\n";
    if ($actualRebuildListSize != $expectedSetSize) {
        print $errormsg;
        return;
    }
    foreach my $compName (@actualRebuildList) {
        if (! exists $expectedSet{$compName}) {
            print $errormsg;
            return;
        }
    }
    print $test . ": SUCCESS : The actual results match the expectations\n";
}

sub _assertResultsTest3 {
    my ($test, $resultsRef) = @_;

    my $expectedResults = ariba::rc::IncrBuildMgrResults->new();
    $expectedResults->addCompToRebuildSetAsCompatible("B");
    $expectedResults->addCompToRebuildSetAsCompatible("D");

    my $identical = $resultsRef->compare($expectedResults);
    if ($identical) {
        print "$test: SUCCESS : The actual results match the expectations\n";
    }
    else {
        print "$test: ERROR : The actual results disagree with the expected results\n";
    }
}

sub _assertResultsTest5_26 {
    my ($test, $rebuildListRef) = @_;

    my %expectedSet = ();
    $expectedSet{"F"} = "F";
    my $expectedSetSize = keys %expectedSet;
    # Component "F" is expected to be rebuilt only ; even though the universe depends on it
    # the change to F is binary compatible

    my @actualRebuildList = @$rebuildListRef;
    my $actualRebuildListSize = @actualRebuildList;
    my $errormsg = $test . ": ERROR : The actual results disagree with the expected results\n";
    if ($actualRebuildListSize != $expectedSetSize) {
        print $errormsg;
        return;
    }
    foreach my $compName (@actualRebuildList) {
        if (! exists $expectedSet{$compName}) {
            print $errormsg;
            return;
        }
    }
    print $test . ": SUCCESS : The actual results match the expectations\n";
}

sub _assertResultsTest9 {
    my ($test, $rebuildListRef) = @_;

    my %expectedSet = ();
    $expectedSet{"L"} = "L";
    my $expectedSetSize = keys %expectedSet;
    # Component "L" is expected to be rebuilt only ; even though the universe depends on it
    # the change to L is binary compatible

    my @actualRebuildList = @$rebuildListRef;
    my $actualRebuildListSize = @actualRebuildList;
    my $errormsg = $test . ": ERROR : The actual results disagree with the expected results\n";
    if ($actualRebuildListSize != $expectedSetSize) {
        print $errormsg;
        return;
    }
    foreach my $compName (@actualRebuildList) {
        if (! exists $expectedSet{$compName}) {
            print $errormsg;
            return;
        }
    }
    print $test . ": SUCCESS : The actual results match the expectations\n";
}

sub _assertResultsLCompat {
    my ($test, $rebuildListRef) = @_;

    my %expectedSet = ();
    $expectedSet{"L"} = "L";
    my $expectedSetSize = keys %expectedSet;

    my @actualRebuildList = @$rebuildListRef;
    my $actualRebuildListSize = @actualRebuildList;
    my $errormsg = $test . ": ERROR : The actual results disagree with the expected results\n";
    if ($actualRebuildListSize != $expectedSetSize) {
        print $errormsg;
        return;
    }
    foreach my $compName (@actualRebuildList) {
        if (! exists $expectedSet{$compName}) {
            print $errormsg;
            return;
        }
    }
    print $test . ": SUCCESS : The actual results match the expectations\n";
}

sub _assertResultsTest16 {
    my ($test, $rebuildListRef) = @_;

    my %expectedSet = ();
    $expectedSet{"C"} = "C";
    $expectedSet{"B"} = "B";
    $expectedSet{"E"} = "E";
    $expectedSet{"A"} = "A";
    my $expectedSetSize = keys %expectedSet;
    # The delta set is: {C:i8}

    my @actualRebuildList = @$rebuildListRef;
    my $actualRebuildListSize = @actualRebuildList;
    my $errormsg = $test . ": ERROR : The actual results disagree with the expected results\n";
    if ($actualRebuildListSize != $expectedSetSize) {
        print $errormsg;
        return;
    }
    foreach my $compName (@actualRebuildList) {
        if (! exists $expectedSet{$compName}) {
            print $errormsg;
            return;
        }
    }
    print $test . ": SUCCESS : The actual results match the expectations\n";
}

sub _assertResultsTest17 {
    my ($test, $rebuildListRef) = @_;

    my %expectedSet = ();
    $expectedSet{"A"} = "A";
    $expectedSet{"E"} = "E";
    $expectedSet{"B"} = "B";
    $expectedSet{"C"} = "C";
    my $expectedSetSize = keys %expectedSet;

    my @actualRebuildList = @$rebuildListRef;
    my $actualRebuildListSize = @actualRebuildList;
    my $errormsg = $test . ": ERROR : The actual results disagree with the expected results\n";
    if ($actualRebuildListSize != $expectedSetSize) {
        print $errormsg;
        return;
    }
    foreach my $compName (@actualRebuildList) {
        if (! exists $expectedSet{$compName}) {
            print $errormsg;
            return;
        }
    }
    print $test . ": SUCCESS : The actual results match the expectations\n";
}

sub _assertResultsTest19 {
    my ($test, $rebuildListRef) = @_;

    my %expectedSet = ();
    $expectedSet{"B"} = "B";
    my $expectedSetSize = keys %expectedSet;

    my @actualRebuildList = @$rebuildListRef;
    my $actualRebuildListSize = @actualRebuildList;
    my $errormsg = $test . ": ERROR : The actual results disagree with the expected results\n";
    if ($actualRebuildListSize != $expectedSetSize) {
        print $errormsg;
        return;
    }
    foreach my $compName (@actualRebuildList) {
        if (! exists $expectedSet{$compName}) {
            print $errormsg;
            return;
        }
    }
    print $test . ": SUCCESS : The actual results match the expectations\n";
}

sub _assertResultsTest21 {
    my ($test, $rebuildListRef) = @_;

    my %expectedSet = ();
    $expectedSet{"L"} = "L";
    my $expectedSetSize = keys %expectedSet;
    # Component "L" is expected to be rebuilt as L is compatible

    my @actualRebuildList = @$rebuildListRef;
    my $actualRebuildListSize = @actualRebuildList;
    my $errormsg = $test . ": ERROR : The actual results disagree with the expected results\n";
    if ($actualRebuildListSize != $expectedSetSize) {
        print $errormsg;
        return;
    }
    foreach my $compName (@actualRebuildList) {
        if (! exists $expectedSet{$compName}) {
            print $errormsg;
            return;
        }
    }
    print $test . ": SUCCESS : The actual results match the expectations\n";
}

sub _assertResultsTest22 {
    my ($test, $rebuildListRef) = @_;

    my %expectedSet = ();
    $expectedSet{"B"} = "B";
    my $expectedSetSize = keys %expectedSet;

    my @actualRebuildList = @$rebuildListRef;
    my $actualRebuildListSize = @actualRebuildList;
    my $errormsg = $test . ": ERROR : The actual results disagree with the expected results\n";
    if ($actualRebuildListSize != $expectedSetSize) {
        print $errormsg;
        return;
    }
    foreach my $compName (@actualRebuildList) {
        if (! exists $expectedSet{$compName}) {
            print $errormsg;
            return;
        }
    }
    print $test . ": SUCCESS : The actual results match the expectations\n";
}

sub _assertResultsTest23 {
    my ($test, $rebuildListRef) = @_;

    my %expectedSet = ();
    $expectedSet{"B"} = "B";
    my $expectedSetSize = keys %expectedSet;

    my @actualRebuildList = @$rebuildListRef;
    my $actualRebuildListSize = @actualRebuildList;
    my $errormsg = $test . ": ERROR : The actual results disagree with the expected results\n";
    if ($actualRebuildListSize != $expectedSetSize) {
        print $errormsg;
        return;
    }
    foreach my $compName (@actualRebuildList) {
        if (! exists $expectedSet{$compName}) {
            print $errormsg;
            return;
        }
    }
    print $test . ": SUCCESS : The actual results match the expectations\n";
}

sub _assertResultsTest24_25 {
    my ($test, $rebuildListRef) = @_;

    my %expectedSet = ();
    $expectedSet{"K2"} = "K2";
    my $expectedSetSize = keys %expectedSet;

    my @actualRebuildList = @$rebuildListRef;
    my $actualRebuildListSize = @actualRebuildList;
    my $errormsg = $test . ": ERROR : The actual results disagree with the expected results\n";
    if ($actualRebuildListSize != $expectedSetSize) {
        print $errormsg;
        return;
    }
    foreach my $compName (@actualRebuildList) {
        if (! exists $expectedSet{$compName}) {
            print $errormsg;
            return;
        }
    }
    print $test . ": SUCCESS : The actual results match the expectations\n";
}

sub _componentBuildCallbackTest1 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest1";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest2 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest2";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest3 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest3";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest4 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest4";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest5 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest5";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest6 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest6";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest7 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest7";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest8 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest8";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest9 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest9";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest10 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest10";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest11 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest11";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest35 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest35";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest12 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest12";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest13 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest13";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest14 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest14";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest15 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest15";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest16 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest16";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest17 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest17";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest18 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest18";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest19 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest19";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest20 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest20";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest27 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest27";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest21 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest21";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest22 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest22";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest23 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest23";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest24 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest24";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest25 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest25";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest26 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest26";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest28 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest28";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest29 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest29";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest30 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest30";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest31 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest31";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest32 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest32";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest33 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest33";
    return _compileAndPackageComp($compName, $dirName, 1);
}

sub _componentBuildCallbackTest34 {
    my ($compMeta) = @_;
    my $compName = $compMeta->getName();
    my $dirName = "incrBuildMgrTest34";
    return _compileAndPackageComp($compName, $dirName, 1);
}

# Input 1 : $deltaSpec string form of a delta specification like "A:i1,B:c3"
# Returns : list of component names mentioned in the deltaSpec
sub _getCompsFromDeltaSpec {
    my ($deltaSpec) = @_;

    my @comps = ();
    chomp($deltaSpec);
    my @splitArray = split(',', $deltaSpec); 
    foreach my $s (@splitArray) {
        my @splitArray2 = split(':', $s); 
        push (@comps, $splitArray2[0]);
    }
    return @comps;
}

# Input 1 : $test name/directory of test
# Input 2 : $delta string form of a delta specification like "A:i1,B:c3"
#
sub _prepForComponentBuildFromDelta {
    my ($test, $deltaSpec) = @_;

    chomp($deltaSpec);
    my @splitArray = split(',', $deltaSpec); 
    foreach my $s (@splitArray) {
        my @splitArray2 = split(':', $s); 
        _prepForComponentBuild($splitArray2[0], $splitArray2[1], $test);
    }
}

sub _prepForComponentBuild {
    my ($compName, $template, $dirName) = @_;
    # copy the $compName.java-$template to $compName.java
    my $from = "$TEMP_DIR/$dirName/$compName/src/ariba/$PACKAGE_NAME/$compName/$compName.java-$template";
    my $to = "$TEMP_DIR/$dirName/$compName/src/ariba/$PACKAGE_NAME/$compName/$compName.java";
    my $cmd = "cp -f $from $to";
    my $retCode = system($cmd);
    if ($debug) {
        print "IncrBuildMgrTest: Preparing for $compName build. cmd = \"$cmd\" return code = $retCode\n";
    }

    # copy the <$compName>interface>.java-$template to <$compName>interface>.java
    $from = "$TEMP_DIR/$dirName/$compName/src/ariba/$PACKAGE_NAME/$compName/$compName" . "interface.java-$template";
    $to = "$TEMP_DIR/$dirName/$compName/src/ariba/$PACKAGE_NAME/$compName/$compName" . "interface.java";
    $cmd = "cp -f $from $to";
    $retCode = system($cmd);
    if ($debug) {
        print "IncrBuildMgrTest: Preparing for $compName build. cmd = \"$cmd\" return code = $retCode\n";
    }
}

# Input 1: $component to rebuild
# Input 2: $dirName which test (directory) to compile to
# Input 3: $dieOnError 1 to throw an IncrBuildMgrException; 0 to return "ERROR"
# return "SUCCESS" or "ERROR"
sub _compileAndPackageComp {
    my ($component, $dirName, $dieOnError) = @_;

    # setup the baseline java files for this component
    my $rp = "$TEMP_DIR/$dirName";
    my $basepath = "$rp/$component";
    my $srcpath = "$basepath/src/ariba/$PACKAGE_NAME/$component/";
    my $classespath = "$basepath/classes";
    my $jarspath = "$basepath/jars";

    my $classpath = "-classpath $rp/A/classes:$rp/B/classes:$rp/C/classes:$rp/D/classes:/E/classes:$rp/F/classes:$rp/G/classes:$rp/H/classes:$rp/I/classes:$rp/J/classes:$rp/K/classes:$rp/K2/classes:$rp/L/classes:$rp/M/classes:$rp/Mdup/classes";

    my $index = 1;
    while ($index <= $extendedUniverseSize) {
        my $cn = "L$index";
        $classpath = $classpath . ":$rp/$cn/classes";
        $index ++;
    }

    my $unexpectedErrorMsg;

    my $cmd = "rm -rf $classespath/ariba";
    my $rmRetCode = system($cmd);
    if ($rmRetCode != 0) {
        $unexpectedErrorMsg = "IncrBuildMgrTest: rm ERROR for command \"$cmd\": return code = $rmRetCode\n";
        if ($debug) {
            print $unexpectedErrorMsg;
        }
        my $exception = ariba::rc::IncrBuildMgrException->new($component, $rmRetCode, $unexpectedErrorMsg);
        $exception->setUnexpectedError();
        if ($dieOnError) {
            die $exception;
        }
        else {
            return "ERROR";
        }
    }

    # compile the components java source files
#    $cmd = "javac -d $classespath $classpath $srcpath" . "$component.java";
    $cmd = "javac -d $classespath $classpath $srcpath" . "$component.java $srcpath" . "$component" . "interface.java";
    if (! $debug) {
        $cmd = $cmd . " 2> /dev/null";
    }
    else {
        print "Compiling \"$component\" with cmd=\"$cmd\"\n";
    }
    my $javacRetCode = system($cmd);
    if ($javacRetCode != 0) {
        $unexpectedErrorMsg = "IncrBuildMgrTest: javac ERROR for component \"$component\": return code = $javacRetCode\n";
        if ($debug) {
            print "IncrBuildMgrTest: javac cmd = \"$cmd\"\n";
            print $unexpectedErrorMsg;
        }
        if ($dieOnError) {
            my $exception = ariba::rc::IncrBuildMgrException->new($component, $javacRetCode, $unexpectedErrorMsg);
            $exception->setCompBuildError();
            die $exception;
        }
        else {
            return "ERROR";
        }
    }

    # delete the old jar #TODO - deal with multiple artifacts
    $cmd = "rm -f $jarspath/$component.jar";
    $rmRetCode = system($cmd);
    if ($rmRetCode != 0) {
        $unexpectedErrorMsg = "IncrBuildMgrTest: rm ERROR for command \"$cmd\": return code = $rmRetCode\n";
        if ($debug) {
            print $unexpectedErrorMsg;
        }
        if ($dieOnError) {
            my $exception = ariba::rc::IncrBuildMgrException->new($component, $rmRetCode, $unexpectedErrorMsg);
            $exception->setUnexpectedError();
            die $exception;
        }
        else {
            return "ERROR";
        }
    }

    # package up the artifact for this component
    $cmd = "jar cf $jarspath/$component.jar -C $classespath .";
    my $jarRetCode = system($cmd);
    if ($jarRetCode != 0) {
        $unexpectedErrorMsg = "IncrBuildMgrTest: jar command \"$cmd\" ERROR for component \"$component\": return code = $rmRetCode\n";
        if ($debug) {
            print "IncrBuildMgrTest: jar cmd = \"$cmd\"\n";
            print $unexpectedErrorMsg;
        }
        if ($dieOnError) {
            my $exception = ariba::rc::IncrBuildMgrException->new($component, $jarRetCode, $unexpectedErrorMsg);
            $exception->setCompBuildError();
            die $exception;
        }
        else {
            return "ERROR";
        }
    }

    return "SUCCESS";
}

sub _writeFile {
    my ($file, $line) = @_;

    open(FILE, ">$file") || return 0;
    print FILE "$line";
    return close(FILE);
}

1;
