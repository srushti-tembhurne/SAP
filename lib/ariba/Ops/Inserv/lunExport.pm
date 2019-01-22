# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Inserv/lunExport.pm#2 $
package ariba::Ops::Inserv::lunExport;
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
