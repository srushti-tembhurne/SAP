#
# A base class to help render arbitrary object as a web component
#

package ariba::Ops::OW::ParallelRepetition;
use strict;

use ariba::Ops::OW::Repetition;

use vars qw(@ISA);
@ISA = qw(ariba::Ops::OW::Component);

sub displayToString {
	my $self = shift;

	my $class = ref($self);


	my $listAttribute = "list0";

	my @arrayOfListRefs;

	while ( 1 ) {
		my @list = $self->attribute($listAttribute);
		push(@arrayOfListRefs, \@list);

		last unless $self->hasAttribute($listAttribute);

		if ($listAttribute eq "list9") {
			$listAttribute = "list10";
		} else {
			$listAttribute++;
		}
	}
	
	my $string = "";
	my @totalItems;
	my $maxItems = 0;

	for ( my $j = 0; $j < @arrayOfListRefs; $j++ ) {
		$totalItems[$j] = scalar(@{$arrayOfListRefs[$j]});
		if ($totalItems[$j] > $maxItems) {
			$maxItems = $totalItems[$j];
		}
	}

	for ( my $i = 0; $i < $maxItems; $i++ ) {

		my @currentItems;
		for ( my $j = 0; $j < @arrayOfListRefs; $j++ ) {

			my $index = $i; #top align parallel arrays with unequal num items

			$index = $totalItems[$j] - $maxItems + $i; # bottom align parallel arrays with unequal num items

			if ($index < 0 || $index >= $totalItems[$j]) {
				push(@currentItems, 0);
			} else {
				push(@currentItems, $arrayOfListRefs[$j][$index]);
			}
		}

		my $replace;
		# render all my subComponents
		my $subComponentString = $self->SUPER::displayToString(1);

		my @discard = $class->evalTokensInLine($subComponentString, \$replace, @currentItems);
		$string .= $replace;
	}

	return $string;
}

1;
