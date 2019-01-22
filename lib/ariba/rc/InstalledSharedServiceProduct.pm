package ariba::rc::InstalledSharedServiceProduct;
use ariba::rc::SharedServiceProduct;
use ariba::rc::InstalledProduct;
use ariba::rc::Utils;
use strict;

use vars qw(@ISA);
@ISA  = qw(ariba::rc::InstalledProduct ariba::rc::SharedServiceProduct);

my %installedSharedServiceProducts;
my $debug = 0;

sub new
{
	my $class = shift;
	my $prodname = shift;
	my $service = shift;
	my $buildname = shift;

	my $productFromCache = $class->_checkForProductInCache(\%installedSharedServiceProducts, $prodname, $service, $buildname);

	return $productFromCache if($productFromCache);

	my $self = ariba::rc::Product->new($prodname, $service, $buildname);

	bless($self, $class);

	$self->setProductName($prodname);
	$self->setServiceName($service);

	if ( !$prodname && !$service ) {
		$self->setBuildName($buildname);
	}

	$self->_init();

	# these duplicate calls below are REQUIRED
	# in some cases.  Be VERY CAREFUL.

	$self->setBuildName($buildname);
	$self->setInstallDir();

	if (defined ($prodname)) {
		my $cacheKey = $class->_cacheKey($prodname, $service, $buildname);
		$installedSharedServiceProducts{$cacheKey} = $self;
	}
	return $self;
}

sub isInstalled
{
	my $class = shift;

	my $product = shift;
	my $service = shift;
	my $buildname = shift;

	my $dir = ariba::rc::Globals::rootDir($product,$service);

	$dir .= "/$buildname" if (defined($buildname));

	return ( -d "$dir/config/" && -f "$dir/config/BuildName" );
}

sub installedProductsList
{
        my $class = shift;

	return $class->__productsList(@_);
}

sub _productRootDir
{
	my $self = shift;

	my ($service,$prodname,$buildname,$installDir);

	$service = $self->service();
	$prodname = $self->name();
	$buildname = $self->buildName();

	if (defined $service) {
		$installDir = ariba::rc::Globals::rootDir($prodname,$service);
	}
	if (defined $buildname && $buildname ne "Unknown-Build") {
		$installDir .= "/$buildname";
	}
	return $installDir;
}

return 1;

__END__

