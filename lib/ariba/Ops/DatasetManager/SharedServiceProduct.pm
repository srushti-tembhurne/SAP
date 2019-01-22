package ariba::Ops::DatasetManager::SharedServiceProduct;

use base qw(ariba::rc::InstalledSharedServiceProduct);

sub new {
	my $class = shift;
	my $ds = shift;

	my $product = $ds->productName();
	my $service = $ds->serviceName();
	my $build =   $ds->buildName();

	my $productFromCache = $class->_checkForProductInCache(\%installedSharedServiceProducts, $prodname, $service, $buildname);

	return $productFromCache if($productFromCache);

	my $obj = {};
	bless($obj, $class);

	$obj->setDataset($ds);
	$obj->setConfigDir($obj->_productRootDir . "/config");
	$obj->setProductName($product);
	$obj->setServiceName($service);
	$obj->setBuildName($buildname);

	$obj->_init();

	$obj->setInstallDir();

	if (defined ($prodname)) {
		my $cacheKey = $class->_cacheKey($prodname, $service, $buildname);
		$installedSharedServiceProducts{$cacheKey} = $obj;
	}

	return($obj);
}

sub _productRootDir {
	my $self = shift;
	my $ds = $self->dataset();

	return($ds->archiveProductDir());
}

sub setDataset {
	my $self = shift;
	my $ds = shift;

	$self->{dataset} = $ds;
}

sub dataset {
	my $self = shift;

	return($self->{dataset});
}

1;
