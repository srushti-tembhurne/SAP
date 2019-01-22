package ariba::monitor::VendorOutageList;

# $Id: //ariba/services/monitor/lib/ariba/monitor/VendorOutageList.pm#1 $

use strict;
use ariba::monitor::OutageSchedule;

# This is the list of outages that each vendor can have. Source of truth.
my %vendorList = (

	'inovis'  => [ 'sat 20:00-23:59', 'sun 00:00-01:00' ],

	'xpedite' => [ 'sat 19:00-23:59', 'sun 00:00-01:00' ],
);

sub outageForVendor {
	my $class  = shift;
	my $vendor = shift;

	return ariba::monitor::OutageSchedule->new( @{$vendorList{$vendor}} );
}

1;
