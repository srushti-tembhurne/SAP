package ariba::rc::InstalledProduct;
use ariba::rc::Utils;
use ariba::rc::Globals;
use ariba::rc::Product;
use ariba::rc::InstalledASPProduct;
use ariba::rc::InstalledSharedServiceProduct;
use ariba::util::PerlRuntime;
use strict;

my %installedProducts;
my $debug = 0;

=pod

=head1 NAME

ariba::rc::InstalledProduct - manage an installed products

=head1 SYNOPSIS

    use ariba::rc::InstalledProduct;

    #
    # Load myself, just figure out what product i am based on where 
    # this script is running from
    #
    my $me = ariba::rc::InstalledProduct->new();

    my $buildname = $me->buildName();
    my $service = $me->service();
    my $name = $me->name();

    #
    # Load product "an" for the same service
    #
    my $anProd = ariba::rc::InstalledProduct->new("an", $service);

    #
    # Get a value out of "an" DD.xml
    #
    my $anFrontDoor = $anProd->default('wocgiadaptorurl');


    # Do i run wofapps?
    if ($me->servesRole($hostname, "wofapps")) {
        # Get all the other machines that play this role
        my @hosts = $me->hostsForRole("wofapps");
        print "Hosts that play role wofapps: ", join(",", @hosts). "\n";
    }

    # Get all the hosts that play a part in "an" service
    my @allHosts = $anProd->allHosts();


=head1 DESCRIPTION

    InstalledProduct is a logical subclass of Product. It inherently knows where
    to find each product, and can load them up, from inside any other
    product.

=head1 Additional API routines

Installed Product provides additional information like :

=over 4

=cut

sub new
{
    my $class = shift;
    my $prodname = shift;
    my $service = shift;
    my $buildname = shift;
    my $customer = shift;

    my $realSelf;
    my $tempProductName;

        unless ( $prodname ) {
                my $configDir = ariba::rc::Product->_computeDeployRootFromNothing() . "/" .
                                            ariba::rc::Product->_configSubDirectory();
                $tempProductName = getProductName($configDir);
        } else {
        $tempProductName = $prodname;
    }

        if ( ariba::rc::Globals::isASPProduct($tempProductName) ) {
                $realSelf = ariba::rc::InstalledASPProduct->new($prodname, $service, $buildname, $customer);

        } else {
                $realSelf = ariba::rc::InstalledSharedServiceProduct->new($prodname, $service, $buildname);
        }

    return $realSelf;
}

=pod

=item * installedProductsList()

a list of all products installed on the localhost

=cut
sub installedProductsList
{
    my $class = shift;
    my $service = shift;
    my $product = shift;
    my $customer = shift;

    unless ( $service ) {
        my $configDir = ariba::rc::Product->_computeDeployRootFromNothing() . "/" .
            ariba::rc::Product->_configSubDirectory();
        $service = getServiceName($configDir);
    }

    my @products;

    unless (defined($customer)) {
        push(@products, ariba::rc::InstalledSharedServiceProduct->installedProductsList($service, $product));
    }

    push(@products, ariba::rc::InstalledASPProduct->installedProductsList($service, $product, $customer));

    return (@products);
}

=pod

=item * installedProductsListInCluster( clusterName )

a list of all products installed on the localhost in the specified cluster

=cut
sub installedProductsListInCluster
{
    my $class = shift;
    my $service = shift;
    my $product = shift;
    my $customer = shift;
    my $cluster = shift;

    my @products = $class->installedProductsList($service, $product, $customer); 
    my @productsInCluster = grep { $_->currentCluster() eq $cluster } @products;

    return @productsInCluster;
}

sub isInstalled {
    my $class = shift;
    my @args = @_;

    return ariba::rc::InstalledSharedServiceProduct->isInstalled(@args) || 
        ariba::rc::InstalledASPProduct->isInstalled(@args);
}

sub exists {
        my $class = shift;
    my @args = @_;

        return $class->isInstalled(@args);
}

=pod

=item * deployedOn()

when was the product installed. Returns times in secs since epoch.

=cut
sub deployedOn
{
    my $self = shift;
    my $considerPatched = shift;

    my $dir = $self->configDir();
    my $deployedTime = ((lstat($dir))[9]);
    if ($considerPatched) {
        my $patchedTime = ((stat($dir))[9]);
        $deployedTime = $patchedTime if ($patchedTime && $patchedTime > $deployedTime);
    }

    return $deployedTime;
}

sub setInstallDir
{
    my $self = shift;
    $self->{installDir} = $self->_productRootDir();
}

sub setBuildName
{
    my $self = shift;
    my $buildname = shift;

    $self->__setBuildNamePassedInOrFromDisk($buildname);
}

sub setProductName
{
    my $self = shift;
    my $prodname = shift;

    $self->__setProductNamePassedInOrFromDisk($prodname);
}

sub setServiceName
{
    my $self = shift;
    my $service = shift;

    $self->__setServiceNamePassedInOrFromDisk($service);
}

return 1;

__END__

=pod

=head1 AUTHOR

Manish Dubey <mdubey@ariba.com>

=head1 SEE ALSO

ariba::rc::Product 

ariba::rc::ArchivedProduct

ariba::rc::PersonalProduct

=cut
