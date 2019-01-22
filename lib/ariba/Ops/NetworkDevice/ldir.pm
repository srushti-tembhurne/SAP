package ariba::Ops::NetworkDevice::ldir;

use strict;
use base qw(ariba::Ops::NetworkDevice::pix);

# The Local Director's prompts and commands are the same as the PIX's.

# The config command isn't however.

sub configCommand {
	my $self = shift;

	return 'write term';
}

1;

__END__
