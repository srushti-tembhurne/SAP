package ariba::rc::PersonalProduct;
use ariba::rc::Product;
use ariba::rc::Utils;
use strict;
use vars qw(@ISA);
@ISA  = qw(ariba::rc::Product);

my %personalProducts;
my $debug = 0;

sub new
{
	my $class = shift;
	my $prodname = shift;

	if(defined($prodname) && defined($personalProducts{$prodname})){
		return $personalProducts{$prodname};
	}
	
	my $self = $class->SUPER::new($prodname, $ENV{'USER'}, "Developer-Build");
	bless($self, $class);

	if (defined ($prodname)) {
		$personalProducts{$prodname} = $self;
	}
	return $self;
}

sub personalProductsList 
{
	my $class = shift;
	my $service = shift;

	my ($product, @allProducts, @products);
	@allProducts = $class->SUPER::allProductNames();

	for $product (@allProducts) {
		if ($class->isBuilt($product,$service)) {
			my $prod = $class->new($product, $service);
			push(@products, $prod);
		}
	}

	return @products;
}

sub servesRole
{
	my ($self, $host, $role) = @_;

	if ($role eq "wofapps") {
		return 1;
	} else {
		return 0;
	}
}

sub rolesForHost
{
	my ($self, $role) = @_;

	return (("wofapps"));

}

sub _productRootDir
{
	my $self = shift;

	my ($service,$prodname, $installDir);

	return $self->{productRootDir} if (defined $self->{productRootDir});

	if (!defined ($ENV{'ARIBA_BUILD_ROOT'})) {
	    die "\$ARIBA_BUILD_ROOT must be set, to deploy a personal build\n";
	}

	$installDir = $ENV{'ARIBA_BUILD_ROOT'};
	return $installDir;
}

sub _init
{
	my $self = shift;

	my $productRootDir = $self->_productRootDir();
	my $prodname = $self->name();
	
	$self->{installDir} = $productRootDir;
	#my $configDir = "$productRootDir/" . _configSubDirectory();

	if (!defined ($ENV{'ARIBA_CONFIG_ROOT'})) {
	    die "\$ARIBA_CONFIG_ROOT must be set, to deploy a personal build\n";
	}
	my $configDir = $ENV{'ARIBA_CONFIG_ROOT'};

	$self->{configDir} = ariba::rc::Product::_stat("$configDir");
	$self->{definitionFile} = undef;
	$self->{metatopology} = undef;
        $self->{deploymentDefaults} = ariba::rc::Product::_stat("$configDir/DeploymentDefaults.xml");
	$self->{woAppsConfig} = ariba::rc::Product::_stat("$configDir/WoApps.cfg");
	$self->{docRoot} = undef;
	$self->{cgiBin} = undef;
	$self->{releaseName} = getReleaseName($self->{configDir});

}

sub _buildName
{
	my $self = shift;
	$self->{buildName} = "Developer-Build";
}

return 1;
