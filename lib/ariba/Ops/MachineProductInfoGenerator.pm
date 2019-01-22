package ariba::Ops::MachineProductInfoGenerator; 

use strict; 

use ariba::Ops::Constants; 
use ariba::Ops::PersistantObject;
use ariba::Ops::MachineProductInfo;
use ariba::rc::InstalledProduct;
use ariba::rc::ArchivedProduct;

use dmail::LockLib;
use File::Path;
use File::Basename;

use base qw(ariba::Ops::PersistantObject); 

sub newForService {
	my $class = shift; 
	my $service = shift; 
	my $installed = shift;

	$installed = 1 unless (defined($installed));

	my $instanceName = $class->generateInstanceName($service, $installed);
	my $self = $class->SUPER::new($instanceName); 
	bless($self, $class);

	$self->setService($service);
	$self->setInstalled($installed);
	$self->setDebug(0);
	$self->setStaleAgeInSeconds(86400); # Always default back to 1 day.

	return $self; 
} 

sub generateInstanceName {
	my $class = shift; 
	my $service = shift; 
	my $installed = shift;

	return ($installed ? "installed" : "archived") . "-$service"; 
}

sub objectLoadMap { 
	my $class = shift; 

	my $mapRef = $class->SUPER::objectLoadMap(); 
	
	$mapRef->{'lastGeneratedOn'} = 'SCALAR'; 
	$mapRef->{'service'} = 'SCALAR';
	$mapRef->{'installed'} = 'SCALAR';

	return $mapRef;
} 

sub dir { 
	my $class = shift; 

	return ariba::Ops::Constants::machineProductInfoDir() . "Generator";
} 

sub _saveStateToFile { 
	my $self = shift; 
	my $recursive = shift; 

	my $prevUmask = umask(002); 
	$self->SUPER::_saveStateToFile($recursive); 
	umask($prevUmask); 
} 

sub lock {
	my $self = shift;
	my $lockTries = 1; # Don't block - just use older data when generating.

	my $lockFile = $self->_backingStore();
	my $lockDir = dirname($lockFile);

	dmail::LockLib::forceQuiet();
	return 1 if (dmail::LockLib::haslock($lockFile));

	unless (-d $lockDir) { 
		my $prevUmask = umask(002);
		mkpath($lockDir);
		umask($prevUmask);
	}

	return(dmail::LockLib::requestlock($lockFile, $lockTries));
}

sub unlock {
	my $self = shift;

	my $lockFile = $self->_backingStore();
	my $r = 1;

	if ( dmail::LockLib::haslock($lockFile) ) {
		$r = dmail::LockLib::releaselock($lockFile);
	}

	return $r;
}


sub generate {
	my $self = shift; 

	return unless ($self->lock()); # Don't block - just use older data when generating.
	
	my %hosts = ();
	my %productHash = ();
	my @productNames = ariba::rc::Product::allProductNames();
	my $service = $self->service();
	my @products = $self->installed() ? 
		ariba::rc::InstalledProduct->installedProductsList($service) :
		ariba::rc::ArchivedProduct->archivedProductsList($service);

	print "Generating MachineProductInfo for " . ($self->installed() ? "installed" : "archived") . " $service service products\n" if ($self->debug());

	# Generate products and roles list
	for my $product (@products) {
		my $productName = $product->name();
		my $name = $productName . ($product->customer() ? "/" . $product->customer() : "");
		my @hosts = $product->allHosts();

		for my $host (@hosts) {
			$productHash{$host}{$productName} = 1;
			$hosts{$host} = [] unless (ref($hosts{$host}));
			my $rolesRef = $hosts{$host};

			for my $cluster ($product->allClusters()) {
				my @roles = $product->rolesForHostInCluster($host, $cluster);
				next unless(@roles);

				my $roles = join("|", @roles);
				push(@$rolesRef, "$name/$service/$cluster($roles)");
			}
		}
	}

	# Store the lists
	# XXX Should not delete all existing records prior to save so that saved records will always 
	# be available to be read without doing read blocking / returning empty data. If a machine is 
	# used, it will be updated, otherwise its data will probably never be used for pages.
	for my $host (keys(%productHash)) {
		my @productsList = sort(keys(%{$productHash{$host}})); 
		my $rolesRef = $hosts{$host};
		@$rolesRef = sort(@$rolesRef);

		my $mpi = ariba::Ops::MachineProductInfo->newWithDetails($service, $host, $self->installed(), $rolesRef, \@productsList);	
		$mpi->setLastUpdatedOn(time()); 
		$mpi->save();
	}

	$self->setLastGeneratedOn(time()); 
	$self->setNumOfMpiRecordsGenerated(scalar(keys(%productHash)));
	$self->save();
	$self->unlock();

	return $self->numOfMpiRecordsGenerated();
}

sub regenerateIfStale { 
	my $self = shift; 

	$self->generate() if (!$self->lastGeneratedOn() ||
		$self->lastGeneratedOn() + $self->staleAgeInSeconds() <= time()); 

	return $self->numOfMpiRecordsGenerated();
}


1; 
