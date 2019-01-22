package ariba::Ops::MachineProductInfo; 

use strict; 
use ariba::Ops::Constants; 
use ariba::Ops::PersistantObject; 
use ariba::Ops::MachineProductInfoGenerator;

use base qw(ariba::Ops::PersistantObject); 

my $staleAgeInSeconds = 86400; # 1 day

sub newWithDetails {
	my $class = shift; 
	my $service = shift || return; 
	my $host = shift || return; 
	my $installed = shift; 
	my $rolesRef = shift; 
	my $productsRef = shift; 

	$installed = 1 unless (defined($installed));

	my $instanceName = $class->generateInstanceName($installed, $service, $host); 
	my $self = $class->SUPER::new($instanceName); 
	bless($self, $class); 

	if ($rolesRef || $productsRef) { # New record
		$self->setInstalled($installed); 
		$self->setService($service); 
		$self->setHost($host); 
		$self->setRoles($rolesRef); 
		$self->setProducts($productsRef); 
	} else { # Existing record
		$class->regenerateForServiceIfStale($service, $installed);
	}
	
	return $self; 
} 

sub generateInstanceName { 
	my $class = shift; 
	my $installed = shift; 
	my $service = shift; 
	my $host = shift || return; 

	my $instanceName = ($installed ? "installed" : "archived") . "/$service/$host";

	return $instanceName;
} 

sub objectLoadMap { 
	my $class = shift; 

	my $mapRef = $class->SUPER::objectLoadMap(); 
	
	$mapRef->{'installed'} = 'SCALAR'; 
	$mapRef->{'service'} = 'SCALAR';
	$mapRef->{'host'} = 'SCALAR';
	$mapRef->{'roles'} = '@SCALAR';
	$mapRef->{'products'} = '@SCALAR';

	return $mapRef;
} 

sub dir { 
	my $class = shift; 

	return ariba::Ops::Constants::machineProductInfoDir();
} 

sub _saveStateToFile { 
	my $self = shift; 
	my $recursive = shift; 

	my $prevUmask = umask 002; 
	$self->SUPER::_saveStateToFile($recursive); 
	umask $prevUmask; 
} 

sub listObjects {
	my $class = shift; 

	return $class->listObjectsRecursively();
}

sub setStaleAgeInSeconds { 
	my $class = shift; 
	my $staleAge = shift;

	$staleAgeInSeconds = $staleAge if (defined($staleAge));
}

sub staleAgeInSeconds {
	my $class = shift; 

	return $staleAgeInSeconds;
}

sub regenerateForServiceIfStale {
	my $class = shift; 
	my $service = shift;
	my $installed = shift;

	$installed = 1 unless (defined($installed));

	my $mpiGenerator = ariba::Ops::MachineProductInfoGenerator->newForService($service, $installed);
	$mpiGenerator->setStaleAgeInSeconds($class->staleAgeInSeconds());
	$mpiGenerator->regenerateIfStale();
}

sub mpiForServiceAndHost {
	my $class = shift; 
	my $service = shift; 
	my $host = shift;
	my $installed = shift; 

	$installed = 1 unless (defined($installed));

	return $class->newWithDetails($service, $host, $installed);
}

sub archivedMpiForServiceAndHost {
	my $class = shift; 
	my $service = shift; 
	my $host = shift;

	return $class->mpiForServiceAndHost($service, $host, 0);
}

sub installedMpiForServiceAndHost {
	my $class = shift; 
	my $service = shift; 
	my $host = shift;

	return $class->mpiForServiceAndHost($service, $host, 1);
}

sub mpisForService { 
	my $class = shift; 
	my $service = shift; 
	my $installed = shift; 
	my @mpis;

	$installed = 1 unless (defined($installed));

	if ($service) { 
		my $currentTime = time();
		$class->regenerateForServiceIfStale($service, $installed);

		my $matchPropertiesRef = {
			'service'	=> $service, 
			'installed'	=> $installed,
		};

		my @allMpis = $class->_matchPropertiesInObjects($matchPropertiesRef); 
		@mpis = grep { $_->lastUpdatedOn() + $class->staleAgeInSeconds() > $currentTime } @allMpis;
	}

	return @mpis;
} 

sub archivedMpisForService { 
	my $class = shift; 
	my $service = shift; 
	
	return $class->mpisForService($service, 0); 
} 

sub installedMpisForService { 
	my $class = shift; 
	my $service = shift; 

	return $class->mpisForService($service, 1); 
}

sub topProductRolesForServiceAndHost { 
	my $class = shift; 
	my $service = shift; 
	my $host = shift; 
	my $maxRolesToDisplay = shift || 10;

	my $mpi = $class->installedMpiForServiceAndHost($service, $host); 
	my @roles = $mpi->roles(); 
	my $numOfRoles = scalar(@roles);

	if ($numOfRoles > $maxRolesToDisplay) {
		@roles = splice(@roles, 0, $maxRolesToDisplay); 
		unshift(@roles, "Displaying only $maxRolesToDisplay of $numOfRoles roles");
	} 

	return join("\n", @roles);
}

1; 
