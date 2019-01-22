#!/usr/local/bin/perl -w
package ariba::monitor::ProductionChange;

use strict;
use ariba::monitor::Change;

use base qw(ariba::monitor::Change); 

sub dir {
	my $class = shift;

	return '/fs/monprod/production-changes';
}

return 1;
