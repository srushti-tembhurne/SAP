# Business Objects module

package ariba::monitor::BusinessObjects;

use strict;
use ariba::monitor::Url;
use ariba::monitor::OutageSchedule;
use ariba::monitor::AppRecycleOutage;
use ariba::monitor::ProductStatus;
use ariba::rc::InstalledProduct;

use HTML::Entities;
use XML::Simple;

our $debug = 0;

my $_monProduct = ariba::rc::InstalledProduct->new ();

sub new
{
    # This will simply be a container for the things that define a Business Object object, for the purposes of monitoring.
    my $boe;
    my $class = shift;

    $boe = _getDefaults ();

    return bless $boe, $class;
}

# Only these two of the original methods are currently useful, the functionality for the rest were removed from the configs
# to match actual 1st requirements.  They are retained for possible future use, after the END marker.  The _getDefaults will
# continue to try and find them, and will return undef for any that don't exist.  This is "harmless" so long as the methods
# are kept inaccessible.
sub getMonProduct
{
    return $_monProduct;
}

sub getURLs
{
    my $self = shift;
    return $self->{urls}; # This returns a ref to an array.
}

sub _getDefaults
{
    my @defaults;
    # Now that we need to monitor the servers directly, and there are more than one each, the 'default' method will return space
    # delimited strings which need to be converted into individual array elements, and this whole thing is then converted to a
    # hash ref on return, ready to be blessed.

    push @defaults, 'urls',      [split /\s+/, $_monProduct->default ('businessobjects.boeappurl')
                                   .' '. $_monProduct->default ('businessobjects.boeweburl')
                                   .' '. $_monProduct->default ('businessobjects.boefrontdoorurl')],
                    'email',     $_monProduct->default ('businessobjects.boeemail');
    return {@defaults};
}

1;

__END__

sub getHost
{
    my $self = shift;
    return $self->{host};
}

sub getPort
{
    my $self = shift;
    return $self->{port};
}

sub getUser
{
    my $self = shift;
    return $self->{username};
}

sub getCipher
{
    my $self = shift;
    return $self->{ciphertext};
}
