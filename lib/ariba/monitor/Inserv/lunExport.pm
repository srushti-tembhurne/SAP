# $Id: //ariba/services/monitor/lib/ariba/monitor/Inserv/lunExport.pm#2 $
package ariba::monitor::Inserv::lunExport;

############################################################################
############################################################################
############################################################################
############################################################################
############################################################################
############################################################################
############################################################################
#
# NetworkDeviceManager.pm and the related sub libraries are being moved
# to //ariba/services/tools/lib/perl/ariba/Ops/...
#
# If you need to make changes to this file, make them there, and change your
# calling code to use ariba::Ops::NetworkDeviceManager instead.
#
############################################################################
############################################################################
############################################################################
############################################################################
############################################################################
############################################################################
############################################################################

use base qw(ariba::Ops::PersistantObject);
use strict;

my $BACKING_STORE = undef;

sub dir {
	my $class = shift;

	return $BACKING_STORE;
}

sub setDir {
	my $class = shift;
	my $dir = shift;

	$BACKING_STORE = $dir;
}

sub objectLoadMap {
	my $class = shift;

	my %map = (
			'ports', '@SCALAR',
		  );

	return \%map;
}

sub validAccessorMethods {
        my $class = shift;

	my $methodsRef = $class->SUPER::validAccessorMethods();

        $methodsRef->{'ports'} = 'undef';
        $methodsRef->{'lun'} = undef;
}

1;
