#
#
# A module that provides abstraction on top of rc products. Provides API to 
# get information about the product such as :
# name, servicetype, installdir, buildname, releasename etc.
#
# perldoc ariba::rc::Product.pm
#
#
# $Id: //ariba/services/tools/lib/perl/ariba/rc/SharedServiceProduct.pm#8 $
#
#
package ariba::rc::SharedServiceProduct;

use ariba::rc::Product;
use ariba::rc::Globals;

use vars qw(@ISA);
@ISA  = qw(ariba::rc::Product);

my $debug = 0;

sub new
{
        my $class = shift;
        my $prodname = shift;
        my $service = shift;
        my $buildname = shift;

        my $productRootDir;

        my $self = {};

        bless($self,$class);

        $self->setProductName($prodname);
        $self->setServiceName($service);
        $self->setBuildName($buildname);

		print "Creating $class, $prodname, $service, $productRootDir\n" if $debug;


        return $self;
}

sub allProductNames {
	my $class = shift;

	return ariba::rc::Globals::allSharedServiceProducts();
}

sub __productsList
{
        my $class = shift;
        my $service = shift;
	my $product = shift;

        my @products;
	my @allProducts;

	if ( $product ) {
		return () unless ariba::rc::Globals::isSharedServiceProduct($product);
		@allProducts = ( $product );
	} else {
        	@allProducts = $class->allProductNames();
	}

        for my $p (@allProducts) {
                if ($class->exists($p,$service,undef)) {
                        my $prod = $class->new($p, $service, undef);
                        push(@products, $prod);
                }
        }

        return @products;
}

sub _init {
	my $self = shift;
	my $opsConfigLabel = shift;
    my $cluster = shift;

	$self->SUPER::_init( $opsConfigLabel, $cluster );

	# nothing shared service product specific here yet.
}

1;
