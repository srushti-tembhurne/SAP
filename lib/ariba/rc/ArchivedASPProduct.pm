package ariba::rc::ArchivedASPProduct;
use ariba::rc::ASPProduct;
use ariba::rc::ArchivedProduct;
use ariba::rc::Utils;
use ariba::rc::Globals;
use strict;

use vars qw(@ISA);
@ISA  = qw(ariba::rc::ArchivedProduct ariba::rc::ASPProduct);

my %archivedASPProducts;
my $debug = 0;

sub new
{
	my $class = shift;
	my $prodname = shift;
	my $service = shift;
	my $buildname = shift;
	my $customer = shift;

	my $productFromCache = $class->_checkForProductInCache(\%archivedASPProducts, $prodname, $service, $buildname, $customer);

	return $productFromCache if($productFromCache);
	
	print "Creating $class, $prodname, $service\n" if $debug;
	my $self = ariba::rc::Product->new($prodname, $service, $buildname);
	print "   After Creating $class, $prodname, $service, ", $self->installDir(),"\n" if $debug;

	bless($self, $class);

	if ( $buildname && !$customer ) {
		# figure out customer name from buildName
		# assumes some knowledge about builds names we shouldn't have
		$customer = (ariba::rc::Globals::stemAndBuildNumberFromBuildName($buildname))[0];
	}

	$self->setProductName($prodname);
	$self->setServiceName($service);
	$self->setCustomer($customer);

	$self->_init();

	$self->setBuildName($buildname);

	if (defined ($prodname)) {
		my $cacheKey = $class->_cacheKey($prodname, $service, $buildname, $customer);
		$archivedASPProducts{$cacheKey} = $self;
	}
	return $self;
}

sub isArchived
{
	my $class = shift;
	my $product = shift;
	my $service = shift;
	my $build = shift;
	my $customer = shift;

	if ( $build && !$customer ) {
		# figure out customer name from buildName
		# assumes some knowledge about builds names we shouldn't have
		$customer = (ariba::rc::Globals::stemAndBuildNumberFromBuildName($build))[0];
	}

	my $dir = ariba::rc::Globals::buildRepository($product, $service, $customer);

	$build = $build || $class->_getLatestArchivedInfo($dir);

	$dir .= "/$build" if (defined ($build));

	return ( -d "$dir/config/" && -f "$dir/config/BuildName" );
}

sub archivedProductsList
{
        my $class = shift;

	return $class->__productsList(@_);
}

sub rootDir
{
	my $class = shift;
	my $prodname = shift;
	my $service = shift;
	my $customer = shift;

	my $rootDir = ariba::rc::Globals::buildRepository($prodname, $service, $customer);

	return $rootDir;
}

sub _productRootDir
{
	my $self = shift;

	my ($service, $prodname, $customer, $buildname, $installDir);

	return $self->{productRootDir} if (defined $self->{productRootDir});

	$service = $self->service();
	$prodname = $self->name();
	$buildname = $self->buildName();
	$customer = $self->customer();

	if (defined $service) {
	    $installDir = ariba::rc::Globals::buildRepository($prodname, $service, $customer);
	} 

	if (!defined $buildname || $buildname eq "Unknown-Build") {
	    $buildname = $self->_getLatestArchivedInfo($installDir);
	}

	if (defined $buildname) {
	    $installDir .= "/$buildname";
	}

	return $installDir;
}

sub setCustomer
{
        my $self = shift;
        my $customer = shift;

        $self->__setCustomerPassedInOrFromDisk($customer);
}

return 1;

__END__

