package ariba::Oncall::OperationsEngineer;

# $Id: //ariba/services/monitor/lib/ariba/Oncall/OperationsEngineer.pm#3 $

use strict;
use vars qw(@ISA);
use ariba::Oncall::Person;
use ariba::Ops::Constants;

@ISA = qw(ariba::Oncall::Person);

sub carriesFloatingPager{
	my $self  = shift;
	my $pager = $self->attribute('pager-email');

	return $pager eq ariba::Ops::Constants->operationsFloatingPagerAddress();
}

1;

__END__
