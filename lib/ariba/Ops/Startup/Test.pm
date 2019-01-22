package ariba::Ops::Startup::Test;

use ariba::Ops::Startup::Monitoring;

use strict;

sub setupOpstools {
	my $me = shift;
	my $masterPassword = shift;

	ariba::Ops::Startup::Monitoring::initializeCipherStoreWithConditions($me, {'user'=> 0}, $me);

}

sub runUnitTests 
{
	my ($me, $masterPassword) = @_;

	#
	# unit tests on startup go here -- each should be a called function,
	# and should print some kind of ERROR message if it fails (which will
	# cause control-deployment to spit an error out.)
	#
	sampleTest();

	discoverTestModules($me, $masterPassword);
}

sub discoverTestModules {
	my $me = shift;
	my $masterPassword = shift;

	my $INSTALLDIR = $me->installDir();
	my $testModDir = "$INSTALLDIR/lib/perl/ariba/UnitTests";

	opendir(D, $testModDir) || return;
	while (my $f = readdir(D)) {
		next unless ($f =~ s/\.pm$//);
		my $class = "ariba::UnitTests::$f";
		require "$testModDir/$f.pm";
		$class->runTests($me, $masterPassword);
	}
}

sub sampleTest {
	if( -e "/tmp/opstools-test-breaks" ) {
		print "Error: Unit test [sampleTest()] failed.\n";
		return;
	}
	print "[sampleTest()] : ok\n";
}

1;

__END__
