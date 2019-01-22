package ariba::Ops::DatasetManager::Product;

use base qw(ariba::rc::InstalledProduct);

use ariba::Ops::Constants;
use ariba::Ops::DatasetManager;
use ariba::Ops::DatasetManager::SharedServiceProduct;

sub new {
	my $class = shift;
	my $ds = shift;
	my $specifiedService = shift;

	if(!ref($ds) && $ds && $ds =~ /\d+$/) {
		$ds = ariba::Ops::DatasetManager->new($ds);
	}

	return(undef) unless(ref($ds));

	my $product = $ds->productName();
	my $service = $ds->serviceName();
	$specifiedService = $service unless($specifiedService);
	my $build =   $ds->buildName();

	my $root = $ds->archiveProductDir();

	if( -d $root && -d "$root/config" ) {
		return(ariba::Ops::DatasetManager::SharedServiceProduct->new($ds));
	} else {
		if(ariba::rc::InstalledProduct->isInstalled($product, $specifiedService, $build)) {
			return($class->SUPER::new($product, $specifiedService, $build));
		} else {
			return(undef);
		}
	}
}

1;
