package ariba::Ops::BusyPageController;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/BusyPageController.pm#2 $

use strict;
use ariba::rc::Globals;
use ariba::rc::Utils;
use ariba::rc::Passwords;
use ariba::rc::InstalledProduct;
use ariba::Ops::ProductAPIExtensions;

use base qw(ariba::Ops::AbstractBusyPage);


# Check if the product needs to make ws 560 error pages modified
sub _checkValidity {
	my $self = shift;

	# Initialized in initialize()
	if ($$self{wsNeedToRestart} || $$self{sswsNeedToRestart}) {
		return 1;
	} else {
		return 0;
	}
}


sub _setState {
	my $self      = shift;
	my $state     = shift;
	my $comment   = shift;
	my $duration  = shift;
	my $beginning = shift;
	my $force     = shift;

	my $product = $$self{product};

	my $currentCluster = $product->currentCluster();
	my @hosts = $product->hostsForRoleInCluster('httpvendor', $currentCluster);

		
	my $commandRoot;
	if ($$self{wsNeedToRestart}) {
		$commandRoot = ariba::rc::Globals::rootDir('ws', $product->service());
	} elsif ($$self{sswsNeedToRestart}) {
		$commandRoot = ariba::rc::Globals::rootDir('ssws', $product->service());
	}
	
	my $command = "$commandRoot/bin/control-error560-pages-on-httpvendor -$state";
	$command .= ' -d' if ($$self{debug});
	$command .= ' -testing' if ($$self{testing});
	$command .= " -product " . $$self{product}->name();
	$command .= " -duration $duration" if defined($duration);
	$command .= " -beginning $beginning" if defined($beginning);
	$command .= " -force " if defined($force);

	foreach my $hostname (@hosts) {
	
		my @command = ($command, $comment);

		ariba::rc::Utils::batchRemoteCommands ($hostname, $$self{user}, $$self{password}, @command);
	}

	$$self{state} = $state;
	return 1;

}


sub newFromProduct {
	my $class = shift;
	my $product = shift || ariba::rc::InstalledProduct->new();

	my @productsToRestart = ariba::Ops::ProductAPIExtensions::productsToRestartAfterDeployment($product);
	my $wsNeedToRestart = 0;
	my $sswsNeedToRestart = 0;
	for my $p (@productsToRestart) {
		if ($p eq 'ws') {
			$wsNeedToRestart = 1;
			last;
		}
		if ($p eq 'ssws') {
			$sswsNeedToRestart = 1;
			last;
		}
	}

	my $self = ();
	if ( ($wsNeedToRestart && ariba::rc::InstalledProduct->isInstalled('ws', $product->service())) ||
		($sswsNeedToRestart && ariba::rc::InstalledProduct->isInstalled('ssws', $product->service())) ) {
		$self = $class->SUPER::new();
	}

	$$self{wsNeedToRestart} = $wsNeedToRestart;
	$$self{sswsNeedToRestart} = $sswsNeedToRestart;
	$$self{product} = $product;
	
	bless($self, $class);


	if ($self->_checkValidity()) {

		ariba::rc::Passwords::initialize($product->service());

		my $user = ariba::rc::Globals::deploymentUser('ws', $product->service());
		my $password = ariba::rc::Passwords::lookup($user);
	
		$$self{user} = $user;
		$$self{password} = $password;
	}

	return $self;
}



sub setUnplanned {
	my $self = shift;
	my $force = shift;

	$force = 0;

	return 0 unless ($self->_checkValidity());

	my $comment = "\nReturn to normal state for the busy pages...\n";
	return $self->_setState($ariba::Ops::AbstractBusyPage::stateUnplanned, $comment, undef, undef, $force);
	
}

sub setRolling {
	my $self = shift;
	my $force = shift;

	return 0 unless ($self->_checkValidity());


	my $comment = "\nSet busy pages to restart state...\n";
	
	return $self->_setState($ariba::Ops::AbstractBusyPage::stateRolling, $comment, undef, undef, $force);

}

sub setPlanned {
	my $self = shift;
	my $duration = shift;
	my $beginning = shift;
	my $force = shift;

	return 0 unless ($self->_checkValidity());

	
	my $comment = "\nSet up temporary busy pages...\n";
	
	return $self->_setState($ariba::Ops::AbstractBusyPage::statePlanned, $comment, $duration, $beginning, $force);
	
}


1;
