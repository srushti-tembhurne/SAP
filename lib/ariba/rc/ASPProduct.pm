
#
# A module that provides abstraction on top of rc products. Provides API to 
# get information about the product such as :
# name, servicetype, installdir, buildname, releasename etc.
#
# perldoc ariba::rc::Product.pm
#
#
# $Id: //ariba/services/tools/lib/perl/ariba/rc/ASPProduct.pm#16 $
#
#
package ariba::rc::ASPProduct;

use ariba::rc::Product;
use ariba::rc::Globals;
use ariba::rc::Utils;

use vars qw(@ISA);
@ISA  = qw(ariba::rc::Product);

my $debug = 0;

sub new
{
        my $class = shift;
        my $prodname = shift;
        my $service = shift;
        my $buildname = shift;
        my $customer = shift;

        my $productRootDir;

        my $self = {};

        bless($self,$class);

        $self->setProductName($prodname);
        $self->setServiceName($service);
        $self->setCustomer($customer);
        $self->setBuildName($buildname);

        print "Creating $class, $prodname, $service, $customer, $productRootDir\n" if ($debug);

        return $self;
}

sub allProductNames {
        my $class = shift;

        return ariba::rc::Globals::allASPProducts();
}

sub __productsList
{
	my $class = shift;
	my $service = shift;
	my $product = shift;
	my $customer = shift;

	my @products;
	my @allProducts;

	if ( $product ) {
		return () unless ariba::rc::Globals::isASPProduct($product);
		@allProducts = ( $product );
	} else {
		@allProducts = $class->allProductNames();
	}

	my $config = $class->_configSubDirectory();

	for my $p (@allProducts) {
		if ( $customer ) {
			if ($class->exists($p,$service,undef,$customer)) {
				my $prod = $class->new($p, $service,undef,$customer);
				push(@products, $prod);
			}
			next; # p (product)
		} 

		# this is really else clause

		my $rootDir = $class->rootDir($p, $service);

		my $ret = opendir(ROOTDIR, $rootDir);
		# We used to check for the existence of $rootdir, but our automount
		# setup prevents that check from working properly, so we check the
		# error before spewing a warning.
		if(!$ret) {
			warn "can't open $rootDir, $!" unless $! =~ m/No such file/;
			next;
		}
		#my @customers = grep(-d "$rootDir/$_/$config/", readdir(ROOTDIR));
		my @files = grep($_ !~ /^\.\.?/, readdir(ROOTDIR));
		close(ROOTDIR);

		for my $cust ( @files ) {
			if ($class->exists($p,$service,undef,$cust)) {
				my $prod = $class->new($p, $service,undef,$cust);
				push(@products, $prod);
			}
		}
	}

	return @products;
}


sub setCustomer
{
	my $self = shift;
	my $customer = shift;
	
	# in the case where we computer our customer name from buildName
	# don't overwrite customer name in later calls
	#

	$self->{customer} = $customer if $customer;
}

sub customer
{
	my $self = shift;
	return $self->{customer};
}

sub prettyCustomerName
{
	my $self = shift;
	return $self->{prettyCustomerName};
}

sub __setCustomerPassedInOrFromDisk
{
	my $self = shift;
	my $customer = shift;

	if (defined $customer && $customer ne "Unknown-Customer") {
                print "$self->just set customer passed in = $customer\n" if $debug;
		$self->{customer} = $customer;
        } elsif ( $self->{configDir} ) {
                print "$self->just read customer from disk via self->configDir==",$self->{configDir} ,"\n" if $debug;
		$self->{customer} = getCustomerName($self->{configDir});
	}  else {
		my $configDir= $self->_computeDeployRootFromNothing() . "/" .
								$self->_configSubDirectory();
		$self->{customer} = getCustomerName($configDir);
                print "$self->JUST READ CUSTOMERAME FROM DISK from $configDir set to ",$self->{customer},"\n" if $debug;
	}
}

sub _init {
	my $self = shift;

	$self->SUPER::_init();

	my $productRootDir = $self->_productRootDir();
	my $baseDir = "base";

	$self->{baseInstallDir} = $self->_stat("$productRootDir/$baseDir");

	$self->{baseDocRoot} = $self->_stat("$productRootDir/$baseDir/docroot");
	my $baseConfig = "$productRootDir/$baseDir/config";

	$self->{baseConfig} = $self->_stat("$productRootDir/$baseDir/config");

	$self->{prettyCustomerName} = getPrettyCustomerName($self->{configDir});

	#
	# If Parameters.table could not be found in its usual location
	# (toplevel config), try the one in base/config dir.
	#
	unless ($self->{parametersTable}) {
		$self->{parametersTable} = $self->_stat("$baseConfig/Parameters.table");
	}
	unless ($self->{appInfo}) {
		$self->{appInfo} = $self->_stat("$baseConfig/asmshared/AppInfo.xml");
	}
}

sub baseInstallDir {
	my $self = shift;

	return $self->{baseInstallDir};
}

sub baseDocRoot {
	my $self = shift;

	return $self->{baseDocRoot};
}

sub baseReleaseName {
	my $self = shift;

	unless ( $self->{baseReleaseName} ) {
		$self->{baseReleaseName} = getReleaseName($self->{baseConfig});
	}	

	return $self->{baseReleaseName};
}

sub baseMajorReleaseName {
	my $self = shift;

	unless ( $self->{baseMajorReleaseName} ) {
		my $releaseName = $self->baseReleaseName();

		$releaseName =~ s|(\d+(\.\d+)?).*|$1|;
		$self->{baseMajorReleaseName} = $releaseName;
	}	
	return $self->{baseMajorReleaseName};
}

sub baseBuildName {
	my $self = shift;

	unless ( $self->{baseBuildName} ) {
		$self->{baseBuildName} = getBuildName($self->{baseConfig});
	}	

	return $self->{baseBuildName};
}

sub isCustomerSuiteDeployed {
	my $self = shift;

	return scalar($self->otherCustomerSuiteMembersList()) ? 1 : 0;
}

sub isInstanceSuiteDeployed {
	my $self = shift;

	return scalar($self->otherInstanceSuiteMembersList()) ? 1 : 0;
}

sub _suiteMembers {
	my $self = shift;
	my $includeSelf = shift;
	my $suiteListKey = shift;

	my $class = ref($self);

	my $service = $self->service();
	my $customer = $self->customer();

	# get a string listing products this one is integrated with,
	# e.g. "acm,anl,aes"
	my $suiteDeployedList = $self->default($suiteListKey);

	return 0 unless (defined($suiteDeployedList));

	my @suiteMembers = ();
	
	# split deployed list into individual products
	for my $suiteMember (split(",", $suiteDeployedList)) {
		# remove any beginning or trailing whitespace
		$suiteMember =~ s/^\s+//;
		$suiteMember =~ s/\s+$//;

		# don't include undef, which can happen because
		# we get a list like:
		#<InstanceSuiteDeployedList>aes,,anl</InstanceSuiteDeployedList>

		# ignore undefined (empty) products
		next if ( ! defined ($suiteMember) || $suiteMember eq "");

		# don't include self if it's not requested
		next if (!$includeSelf && $suiteMember eq $self->name());

		push(@suiteMembers, $suiteMember);
	}

	return (@suiteMembers);
}

=pod

=item * suiteMembersList()

Gives a list of product names that are instance suite deployed for this customer

=cut
sub instanceSuiteMembersList {
	my $self = shift;
	my $includeSelf = shift;

	$includeSelf = 1 unless defined($includeSelf);

	return ($self->_suiteMembers($includeSelf, 'Ops.InstanceSuiteDeployedList'));
}

=pod

=item * suiteMembersList()

Gives a list of product names that are customer suite deployed for this customer

=cut
sub customerSuiteMembersList {
	my $self = shift;
	my $includeSelf = shift;

	$includeSelf = 1 unless defined($includeSelf);

	return ($self->_suiteMembers($includeSelf, 'Ops.CustomerSuiteDeployedList'));
}

=pod

=item * otherInstanceSuiteMembersList()

Gives a list of other product names that are instance suite deployed with this one.

=cut
sub otherInstanceSuiteMembersList {
	my $self = shift;

	return ($self->instanceSuiteMembersList(0));
}

=pod

=item * otherCustomerSuiteMembersList()

Gives a list of other product names that are customer suite deployed with this one.

=cut
sub otherCustomerSuiteMembersList {
	my $self = shift;

	return ($self->customerSuiteMembersList(0));
}

1;
