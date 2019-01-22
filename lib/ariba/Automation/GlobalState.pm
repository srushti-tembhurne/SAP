package ariba::Automation::GlobalState;

use ariba::Automation::State;
use base qw(ariba::Automation::State);
use ariba::Automation::Constants;

sub newFromName {
	my $class = shift;
	my $name = shift;

	#
	# singleton
	#
	my $self = $class->SUPER::new("$name.GlobalState");

	return $self;
}

sub objectLoadMap {
	my $class = shift;

	my $mapRef = $class->SUPER::objectLoadMap();

	$mapRef->{'lastGoodChangeList'} = '@SCALAR';
	$mapRef->{'lastGoodChangeTimeList'} = '@SCALAR';
	$mapRef->{'latestQualIds'} = '@SCALAR';
	$mapRef->{'buildInfo'} = '@SCALAR';
	$mapRef->{'configOrigin'} = '@SCALAR';
	$mapRef->{'notifications'} = '@SCALAR';

	return $mapRef;
}


1;
