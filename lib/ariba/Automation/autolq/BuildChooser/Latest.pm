package ariba::Automation::autolq::BuildChooser::Latest;

#
# Find the latest stable build for a product/branch
#

use strict;
use warnings;
use vars qw ($AUTOLOAD);
use Carp;
use Data::Dumper;
use Sort::Versions;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../lib/perl";
use lib "$FindBin::Bin/../../bin";
use ariba::rc::Globals;
use ariba::Automation::Utils;
use ariba::Automation::autolq::Builds;
use ariba::Automation::autolq::BuildChooser;
use base ("ariba::Automation::autolq::BuildChooser");

{
	my %STEMS =
	(
		"s410s2" => "voyageurs",
	);

	my %ALIASES =
	(
		"ssp" => "buyer",
	);

    #
    # Constructor
    #
    sub new
    {
        my ($self) = @_;
        print "HERP DERP\n";
        my $class = $self->SUPER::new ();
        return $class;
    }

    #
    # Given product/branch and optional dir, attempt to load the latest
    # stable build via label. Uses static methods from
    # ariba::Automation::autolq::Builds to root through
    # /home/rc/archive/builds.
    #
    sub get_label {
        my ($self, $product, $branch, $dir) = @_;
		my $branchName;

		my $productname = $product;
		if (exists $ALIASES{$product}) {
			$productname = $ALIASES{$product};
		}

		my $link = ariba::rc::Globals::archiveBuilds($productname);

		#
		# e.g. 11s1 from //ariba/asm/build/11s1
		#
		my @branchChunks  = split /\//, $branch;
		if (grep {/sandbox/i} @branchChunks) {
			$branchName = $branchChunks[$#branchChunks - 1];
		} else {
			$branchName = $branchChunks[$#branchChunks];
		}

		$link .= '/' . 'current-' . $branchName;

		my $buildName =  ariba::Automation::Utils::buildNameFromSymlink($link);
		return $buildName if($buildName);
		0;
    }
}

1;
