# $Id: Conf.pm,v 1.1 1999/12/07 04:58:08 dsully Exp dsully $

package ariba::WebStats::Analog;

use strict;

sub new {
	my $proto = shift;
	return bless my $self = {}, (ref $proto || $proto);
}

sub run {

}

1;

__END__
