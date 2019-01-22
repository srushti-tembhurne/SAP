package ariba::Ops::AbstractBusyPage;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/AbstractBusyPage.pm#4 $

use strict;
use ariba::rc::InstalledProduct;

# Constants

our $stateRolling   = 'rolling';
our $statePlanned   = 'planned';
our $stateUnplanned = 'unplanned';


sub new {
	my $class = shift;

	my $self = {};

	bless($self, $class);

	$$self{debug}   = undef;
	$$self{testing} = undef;

	return $self;

}

sub setUnplanned {
	my $self = shift;
	my $force = shift;

	return undef;
}

sub isUnplanned {
	my $self = shift;

	return ($self->guessState() eq $stateUnplanned);
}

sub setRolling {
	my $self = shift;

	return undef;
}

sub isRolling {
	my $self = shift;

	return ($self->guessState() eq $stateRolling);
}

sub setPlanned {
	my $self = shift;

	return undef;
}

sub isPlanned {
	my $self = shift;

	return ($self->guessState() eq $statePlanned);
}

sub setDebug {
	my $self = shift;
	my $debug = shift;

	$$self{debug} = $debug;
}

sub debug {
	my $self = shift;
	
	return $$self{debug};
}

sub setTesting {
	my $self = shift;
	my $testing = shift;

	$$self{testing} = $testing;

}

sub testing {
	my $self = shift;

	return $$self{testing};
}

sub state {
	my $self = shift;

	return $self->guessState();

}

sub guessState {
	my $self = shift;

	return undef;
}

1;
