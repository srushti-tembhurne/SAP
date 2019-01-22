package ariba::Ops::VendorContract;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/VendorContract.pm#5 $


use strict;
use ariba::Ops::Constants;
use ariba::Ops::PersistantObject;
use base qw(ariba::Ops::PersistantObject);
use DateTime;


sub dir {
	my $class = shift;
	return ariba::Ops::Constants->vendorContractDir();
}

sub listAttributes {
	my $class = shift;

	return qw(
		vendor product lastRenewal nextRenewal contract
		currentPO notes costper cost lastContact 
	);
}

sub daysTillContractRenewal {
	my $self = shift;

	unless ($self->nextRenewal() && $self->nextRenewal() =~ m|\d+/\d+/\d+|) {
		return 0;
	}

	my ($month,$day,$year) = split(/\//, $self->nextRenewal());

	my $nextRenewal = DateTime->new(
		month => $month,
		day   => $day,
		year  => $year,
	);

	my $today = DateTime->today();
	my $delta = $nextRenewal - $today;

	return ($delta->delta_days() + ($delta->delta_months * 30));
}

1;

__END__
