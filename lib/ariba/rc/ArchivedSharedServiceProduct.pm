package ariba::rc::ArchivedSharedServiceProduct;
use ariba::rc::SharedServiceProduct;
use ariba::rc::ArchivedProduct;
use ariba::rc::Utils;
use strict;

use vars qw(@ISA);
@ISA  = qw(ariba::rc::ArchivedProduct ariba::rc::SharedServiceProduct);

my %archivedSharedServiceProducts;
my $debug = 0;

sub new
{
	my $class = shift;
	my $prodname = shift;
	my $service = shift;
	my $buildname = shift;
	my $opsConfigLabel = shift;
	my $cluster = shift;

	my $productFromCache = $class->_checkForProductInCache(\%archivedSharedServiceProducts, $prodname, $service, $buildname);

	return $productFromCache if($productFromCache);
	
    print "Creating $class, $prodname, $service\n" if $debug;
	my $self = ariba::rc::Product->new($prodname, $service, $buildname, undef, $opsConfigLabel);
    print "   After Creating $class, $prodname, $service, ", $self->installDir(),"\n" if $debug;

	bless($self, $class);

	$self->setProductName($prodname);
	$self->setServiceName($service);

	$self->_init( $opsConfigLabel, $cluster );
    $self->{opsConfigLabel} = $opsConfigLabel;

	$self->setBuildName($buildname);

	if (defined ($prodname)) {
		my $cacheKey = $class->_cacheKey($prodname, $service, $buildname);
		$archivedSharedServiceProducts{$cacheKey} = $self;
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
	my $opsConfigLabel = shift;

	my $dir = ariba::rc::Globals::buildRepository($product, $service);

	$build = $build || $class->_getLatestArchivedInfo($dir);

    if ($build) {
	    $dir .= "/$build";
        if ($opsConfigLabel) {
	        $dir .= "-$opsConfigLabel";
        }
    }

	return ( -d "$dir/config/" && -f "$dir/config/BuildName" );
}

sub archivedProductsList
{
	my $class = shift;
	my @args = @_;

	return $class->__productsList(@args);
}

sub _productRootDir
{
	my $self = shift;
	my $opsConfigLabel = shift;

	my ($service,$prodname,$buildname,$installDir);

	return $self->{productRootDir} if (defined $self->{productRootDir});

	$service = $self->service();
	$prodname = $self->name();
	$buildname = $self->buildName();

	if (defined $service) {
	    $installDir = ariba::rc::Globals::buildRepository($prodname, $service);
	} 

	if (!defined $buildname || $buildname eq "Unknown-Build") {
	    $buildname = $self->_getLatestArchivedInfo($installDir);
	}

	if (defined $buildname) {
	    $installDir .= "/$buildname";
	}

	if (defined $opsConfigLabel) {
	    $installDir .= "-$opsConfigLabel";
        $self->{opsConfigLabel} = $opsConfigLabel;
	}

	return $installDir;
}

return 1;

__END__
