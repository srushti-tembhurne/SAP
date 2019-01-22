#
# A base class to help render arbitrary object as a web component
#

package ariba::Ops::OW::Foo;
use strict;

use ariba::Ops::OW::Component;

use vars qw(@ISA);
@ISA = qw(ariba::Ops::OW::Component);


sub template {
	my $self = shift;

	my @f = (
'<OWRepetition list=*'. $self->class() . '->listObjects()* id=top> ',
'	*$currentItem->instance()*',
"\n",
'        <OWRepetition list=*sort($currentItem->attributes())* >',
'                *$currentItem* *ariba::Ops::OW::Repetition->new("top")->currentItem()->attribute($currentItem)*',
"\n",
'        </OWRepetition>',
"\n",
'</OWRepetition>',
	);

	return \@f;
}


1;
