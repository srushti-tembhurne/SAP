#!/usr/local/bin/perl

use strict;
use FindBin;
use lib "$FindBin::Bin/../lib/perl";
use TestUtils;

my $single_test = shift;

my $t = TestUtils->new();

if (defined $single_test)
{
	#run a single test
	$t->run_test_from_json({test_conf => '/home/montest/FOVEA/test/conf/tests.json', single_test => $single_test});
}
else
{
	#run all tests
	$t->run_test_from_json({test_conf => '/home/montest/FOVEA/test/conf/tests.json'});
}
