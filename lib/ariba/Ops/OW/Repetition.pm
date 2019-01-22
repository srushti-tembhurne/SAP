#
# A base class to help render arbitrary object as a web component
#

package ariba::Ops::OW::Repetition;
use strict;

use ariba::Ops::OW::Component;

use vars qw(@ISA);
@ISA = qw(ariba::Ops::OW::Component);

sub displayToString {
	my $self = shift;

	my $class = ref($self);

	# render all my subComponents
	
	my $replace;
	my @list = $self->list();

	my $string = "";
	for my $item ( @list) {
		my $replace;
		$self->setCurrentItem($item);

		# get all sub components

		# for each component, for each attr
	
		# eval tokens using $item

		for my $component ( $self->components() ) {
			$component->evalAttributes($item);
		}


		# render my sub components
		my $subComponentString = $self->SUPER::displayToString(1);

		my @discard = $class->evalTokensInLine($subComponentString, \$replace, $item);
		$string .= $replace;
	}

	return $string;
}

1;
