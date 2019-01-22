package ariba::monitor::FaxInfo;

use strict;
use ariba::Ops::PersistantObject;
use base qw(ariba::Ops::PersistantObject);


sub objectLoadMap {
        my $class = shift;

        my $mapRef = $class->SUPER::objectLoadMap();

        $$mapRef{'faxIDs'} =  '@SCALAR';

        return $mapRef;
}


sub dir {
	my $class = shift;
	return ariba::monitor::misc::faxInfoStorageDir();
}

sub newFromQuery {
	my $class = shift;
	my $query = shift;

	my $self = $class->SUPER::new( $query->service() . $query->productName() . "_community_" . $query->communityId() );
	bless($self, $class);
	return $self;
}

1;
