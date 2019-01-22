#!/usr/local/bin/perl -w
package ariba::monitor::ProductionChangeMonitor;
#
# Checks and records production changes 
# $Id: //ariba/services/monitor/lib/ariba/monitor/ProductionChangeMonitor.pm#4 $
#

use ariba::monitor::ProductionChange;
use ariba::Ops::PersistantObject;
use ariba::rc::InstalledProduct;

use base qw(ariba::Ops::PersistantObject); 

sub new {
	my $class = shift;
	
	my $self = $class->SUPER::new('.monitor'); # Single instance.

	return $self;
}

sub dir {
	my $class = shift; 

	return ariba::monitor::ProductionChange->dir();
}

sub checkCFEngineChanges {
	my $self = shift; 
	my $numChanges = 0;

	my $lastPushTime = $self->lastCFEnginePushTime() || 0;
	my $maxTimePushed = $lastPushTime;

	my @changes = CFEngineChange->listObjectsRecursively(); 
	foreach my $change (@changes) {
		if ($change->timePushed() && $change->timePushed() > $lastPushTime) {
			$self->addCFEngineChange($change);
			$maxTimePushed = $change->timePushed() if ($change->timePushed() > $maxTimePushed);
			$numChanges++;
		}
	}

	if ($maxTimePushed > $lastPushTime) {
		$self->setLastCFEnginePushTime($maxTimePushed); 
		$self->save();
	}

	return $numChanges;
}

sub checkProductChanges {
	my $self = shift;
	my $numChanges = 0;

	my $me = ariba::rc::InstalledProduct->new();
	my @products = ariba::rc::InstalledProduct->installedProductsList($me->service());

	foreach my $product (@products) {
		my $type = $product->name();
		my $subType = $product->customer();
		my $buildName = $product->releaseName() . " (" . $product->buildName() . ")"; 
		my $change = ariba::monitor::ProductionChange->lastChangeForType($type, $subType); 
		my $lastBuildName = $change && $change->newValue();
		if (!$lastBuildName || $lastBuildName ne $buildName) {
			my $change = ariba::monitor::ProductionChange->newWithHash(
				time	=> $product->deployedOn(1),
				type	=> $type,
				subType => $subType,
				oldValue	=> $lastBuildName,
				newValue	=> $buildName,
			);
			$change->save();
			$numChanges++;
		}
	}

	return $numChanges;
}

sub addCFEngineChange {
	my $class = shift; 
	my $change = shift; 

	if ($change && $change->timePushed() && $change->type() && $change->label()) {
		my $prodChange = ariba::monitor::ProductionChange->newWithHash(
			time => $change->timePushed(),
			type => 'cfengine', 
			subType => $change->type(),
			newValue => $change->label());
		$prodChange->save();
	}
}

# XXX: Rich, remove the class below and replace references to it with your class.
package CFEngineChange; 

use ariba::Ops::PersistantObject;
use base qw(ariba::Ops::PersistantObject);

sub dir {
	$class = shift;

	return "/tmp/cfengine-change-test";
}


return 1;
