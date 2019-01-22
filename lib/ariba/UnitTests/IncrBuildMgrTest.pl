use strict;
use lib '.';
use lib '../..';
use ariba::UnitTests::IncrBuildMgrTest;
use Getopt::Long;

sub usage {
    print "Usage: perl IncrBuildMgrTest.pl [-printdebug] [-extendedUniverseSize <number>] [-tests <comma separated test numbers>] [-firstTest <number>] [-lastTest <number>]\n";
    print "For example: perl IncrBuildMgrTest.pl -e 100 -f 1 -l 5 -t 8,10,12\" will run tests 1,2,3,4,5,8,10,12 over the extended universe of 100 components\n";
}

sub main
{
    my $printdebug;
    my $extendedUniverseSize;
    my $tests;
    my $firstTest;
    my $lastTest;
    my $help;

    my $result = GetOptions ("printdebug" => \$printdebug, 
        "extendedUniverseSize=i" => \$extendedUniverseSize,
        "tests=s" => \$tests,
        "firstTest=i" => \$firstTest,
        "lastTest=i" => \$lastTest,
        "help" => \$help);

    if (defined $help) {
        usage();
    }
    else {
        my @testarray;
        if (defined $firstTest && defined $lastTest) {
            @testarray = ($firstTest .. $lastTest);
        }
        if (defined $tests) {
            if (@testarray) {
                my @a = split(",", $tests);
                push (@testarray, @a);
            }
            else {
                @testarray = split(",", $tests);
            }
        }

        if (@testarray) {
            ariba::UnitTests::IncrBuildMgrTest->runTests("IncrBuildMgrTest", undef, $printdebug, $extendedUniverseSize, \@testarray);
        }
        else {
            ariba::UnitTests::IncrBuildMgrTest->runTests("IncrBuildMgrTest", undef, $printdebug, $extendedUniverseSize, undef);
        }
    }
}

main();
