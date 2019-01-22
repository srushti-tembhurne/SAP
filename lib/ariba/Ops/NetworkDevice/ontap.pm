package ariba::Ops::NetworkDevice::ontap;

use strict;
use base qw(ariba::Ops::NetworkDevice::BaseDevice);

sub loginName {
	my $self = shift;
       
	return 'root';
}

sub commandPrompt {
    my $self = shift;

    return 'nfs.*>';
}

1;

__END__
