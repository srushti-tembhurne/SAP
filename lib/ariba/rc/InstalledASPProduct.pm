package ariba::rc::InstalledASPProduct;
use ariba::rc::ASPProduct;
use ariba::rc::InstalledProduct;
use ariba::rc::Utils;
use strict;

use vars qw(@ISA);
@ISA  = qw(ariba::rc::InstalledProduct ariba::rc::ASPProduct);

my %installedASPProducts;
my $debug = 0;

sub new
{
	my $class = shift;
	my $prodname = shift;
	my $service = shift;
	my $buildname = shift;
	my $customer = shift;

	my $productFromCache = $class->_checkForProductInCache(\%installedASPProducts, $prodname, $service, $buildname, $customer);

	return $productFromCache if($productFromCache);
	
	my $self = ariba::rc::Product->new($prodname, $service, $buildname, $customer);

	bless($self, $class);


        $self->setProductName($prodname);
        $self->setServiceName($service);

        if ( !$prodname && !$service ) {
		# could read from disk
                $self->setBuildName($buildname);
		$buildname = $self->buildName();
        }

	if ( $buildname && !$customer ) {
		# figure out customer name from buildName
		# assumes some knowledge about builds names we shouldn't have
		$customer = (ariba::rc::Globals::stemAndBuildNumberFromBuildName($buildname))[0];
	}
	$self->setCustomer($customer);

        $self->_init();

	# these duplicate calls below are REQUIRED
	# in some cases.  Be VERY CAREFUL.

        $self->setBuildName($buildname);
	$self->setInstallDir();

	if (defined ($prodname)) {
		my $cacheKey = $class->_cacheKey($prodname, $service, $buildname, $customer);
		$installedASPProducts{$cacheKey} = $self;
	}
	return $self;
}

sub isInstalled
{
	my $class = shift;

	my $product = shift;
	my $service = shift;
	my $buildname = shift;
	my $customer = shift;

	if ( $buildname && !$customer ) {
		# figure out customer name from buildName
		# assumes some knowledge about builds names we shouldn't have
		$customer = (ariba::rc::Globals::stemAndBuildNumberFromBuildName($buildname))[0];
	}

	my $dir = ariba::rc::Globals::rootDir($product, $service, $customer);

	$dir .= "/$buildname" if (defined($buildname));

	my $config = $class->_configSubDirectory();

	return ( -d "$dir/config/" && -f "$dir/config/BuildName" );
}

sub installedProductsList
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

	my $rootDir = ariba::rc::Globals::rootDir($prodname, $service, $customer);

	return $rootDir;
}

sub _productRootDir
{
	my $self = shift;

	my ($service,$prodname,$buildname,$customer,$installDir);

	$service = $self->service();
	$prodname = $self->name();
	$buildname = $self->buildName();
	$customer = $self->customer();

	if (defined $service) {
		$installDir = ariba::rc::Globals::rootDir($prodname,$service,$customer);
	}
	if (defined $buildname && $buildname ne "Unknown-Build") {
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

sub customerBuildName {
	my $self = shift;

	my $baseBuildName = $self->baseBuildName();
	$baseBuildName =~ s/-//g;
	my $deployment = $self->buildName(); # misnomar I know
	$deployment =~ s/$baseBuildName$//;

	return($deployment);
}

return 1;

__END__

