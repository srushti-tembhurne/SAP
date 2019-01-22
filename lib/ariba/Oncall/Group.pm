package ariba::Oncall::Group;

# $Id: //ariba/services/monitor/lib/ariba/Oncall/Group.pm#3 $

use strict;
use ariba::Ops::Constants;
use base qw(ariba::Ops::PersistantObject);
use ariba::Oncall::Person;

sub dir {
        my $class = shift;

        return ariba::Ops::Constants->opsGroupsDir();
}

sub peopleInGroup {
	my $self   = shift;

	my @people = ();

	for my $person (ariba::Oncall::Person->listObjects()) {

		next unless $person->group();
		next unless $person->group()->instance() eq $self->instance();

		push @people, $person;
	}

	return @people;
}

sub peopleNotInGroup {
	my $self   = shift;

	my @people = ();

	for my $person ( ariba::Oncall::Person->listObjects() ) {

		next if ( $person->group() &&
			$person->group()->instance() eq $self->instance() );

		push ( @people, $person );
	}

	return @people;
}

sub save {
        return undef;
}

sub remove {
        return undef;
}

1;
