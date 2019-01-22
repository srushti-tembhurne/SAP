#!/usr/local/bin/perl

package ariba::Ops::MCL::Checks;

use ariba::Ops::Logger;
my $logger = ariba::Ops::Logger->logger();

use ariba::rc::InstalledProduct;
use ariba::Ops::OracleClient;
use ariba::Ops::DBConnection;
use ariba::Ops::DatabasePeers;
use ariba::rc::Globals;

sub isInstalled {
	return(ariba::rc::InstalledProduct->isInstalled(@_));
}

1;
