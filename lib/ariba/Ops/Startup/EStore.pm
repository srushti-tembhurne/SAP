package ariba::Ops::Startup::EStore;

use strict;

use File::Basename;
use File::Path;

use ariba::Ops::Startup::Common;
use ariba::rc::Utils;


sub genericFilesystemSetup
{
	my $me = shift;

	ariba::Ops::Startup::Common::makeSharedFileSystemDir($me->default('perf.reportdir')); 
	ariba::Ops::Startup::Common::makeSharedFileSystemDir($me->default('reportdir'));

	ariba::Ops::Startup::Common::createMonitoringArchiveDirFromService($me->service());

}

# Setup symbolic links to personalities
sub createSymLinksForPersonalities
{
	my $buildname = shift;
	my $prodRoot  = dirname($main::INSTALLDIR);

	my $persRoot = "docroot";
	if (-d "$main::INSTALLDIR/personalities") {
		# This should be the default after AN48
		$persRoot = "personalities";
	}

	#
	# Populate the p directory with default brands
	#
	my %defaultBrands = (
		"p/Ariba"	   => "$persRoot/Ariba",
		"p/ANDefault"	=> "$persRoot/ANDefault",
		"p/Amex"	=> "$persRoot/Amex",
		"p/Amex-T"	=> "$persRoot/Amex-T",
		"p/EAriba"	=> "$persRoot/EAriba",		
		"p/EAriba-T"	=> "$persRoot/EAriba-T"		
	);

	ariba::Ops::Startup::Common::createSymLinks($buildname, \%defaultBrands, 0);

	#
	# Make sure docroot can access brands stored in the personality
	# directory
	#
	my @personalityDirs = qw(p Personalities);

	for my $personalityDir (@personalityDirs) {
		next unless -d "$prodRoot/$personalityDir";
		my %Files = (
			"WebObjects/$personalityDir"	=> "$personalityDir",
			"docroot/$personalityDir"	=> "$personalityDir",
		);

		ariba::Ops::Startup::Common::createSymLinks($buildname, \%Files, 1);
	}

}


sub createSymLinksForAdminserver
{
	my $me = shift;
	my $prodRoot = dirname($main::INSTALLDIR);
	my $src  = $me->default('reportdir') . '/output';
	my $dest = $me->docRoot() . '/reports';

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

	unlink ($dest);
	unless (symlink($src, $dest)) {
		#
		# Make sure no one else created this symlink
		# in parallel.
		#
		my $failureMsg = $!;
		unless (-e $dest) {
			print "Error: Could not create symlink $dest to $src, $failureMsg\n";
		}
	}
}


1;

__END__
