#
# $Id: //ariba/services/tools/lib/perl/ariba/rc/RolesManager.pm#19 $
#
package ariba::rc::RolesManager;
#
# This package manages roles.cfg and provides API to get to information
# in that file.
#
#
# api:
#  hostsForRoleInCluster
#  rolesForHostInCluster
#  rolesInCluster
#  hostsInCluster
#  isARoleInCluster
#
#  rolesForVirtualHostInCluster
#  virtualHostsForRoleInCluster
#  realOrVirtualHostsForRoleInCluster
#
#  virtualHostsForRealHostInCluster
#  realHostsForVirtualHostInCluster
#
#  hosts
#  virtualHosts
#  clusters
#  roles
#  isARole
#
#  addNewHostWithSameRolesAs
#  save
#
#  hostServesRoleInCluster
#
#  clustersForHost
#  clustersForRole
#
#  dirsToCopyFromForRole
#  dirsProvidedByForRole
#  pathsToCopyToForRole
#  usersToCopyToForRole
#
#
#

use strict;
use File::Basename;
use File::Path;

use ariba::rc::Globals;
use ariba::rc::Utils;
use ariba::Ops::PersistantObject;

use vars qw(@ISA);

@ISA = qw(ariba::Ops::PersistantObject);

my $defaultDomain = "ariba.com";

my @validClusters = ("primary", "secondary", "standby", "disaster", "backup");

=pod

=head1 NAME

ariba::rc::RolesManager - manage roles.cfg in a given config directory

=head1 SYNOPSIS

	use ariba::rc::RolesManager;

	#
	# Load roles information in config dir /foo/bar
	# for product an, service dev, build cuz-20
	#
	my $rolesMgr = ariba::rc::RolesManager->new("/foo/bar", "an", "dev", "cuz-20");

	#
	# All hosts that are part of this service
	#
	my @hosts = $rolesMgr->hosts();

	#
	# all roles played by $host in cluster $cluster
	#

	my @roles = $rolesMgr->rolesForHostInCluster($host, $cluster);



=head1 DESCRIPTION

RolesManager provides an API for all roles related information for a
product. This information includes things like:

=over 4

=item * which machines is this product running on

=item * hostnames for any role in a given cluster (required by the product)

=item * roles for a any host in a given cluster

=item * what directories to push to which host for this product

=back

=head1 API

A complete list of all API routines is :

=over 4

=item * new() OR new(configdir, productName, service, buildname)

Create a new manager object (or fetch a previously created object out of the
cache).   This method is deprecated, use newWithProduct() instead.

=item * newWithProduct($product)

Create a new manager using an ariba::rc::Product.

=cut

# class methods
sub objectLoadMap 
{
	my $class = shift;
	my %map = (
		'hosts', '@SCALAR',
		'roles', '@SCALAR',
		'clusters', '@SCALAR',
		'virtualHosts', '@SCALAR',
	);
	return \%map;
}

sub dir 
{
	my $class = shift;

	# don't have a backing store
	return undef;
}

=pod

=item * defaultCluster()

This is a class method that returns the value of default cluster, if 
nothing has been specified.

call it like: 

my $cluster = ariba::rc::RolesManager->defaultCluster();

=cut

sub defaultCluster 
{
	my $class = shift;

	return $validClusters[0];
}

=pod

=item * validClusters()

Class method which returns a list of valid cluster names.

=cut

sub validClusters {
	my $class = shift;

	return @validClusters;
}

sub new
{
	my ($class, $configDir, $productName, $serviceName, $buildName, $customer) = @_;

	# Do not use this method
	#XXX All calls to buildname, configdir, should go via ProductAPI

	my $instance = $configDir;

	my $self = $class->SUPER::new($instance);
	bless($self, $class);

	if ($productName && $configDir) {

		my $rolesFile = "$configDir/roles.cfg";

		### If CQ config is allowed, check for existence of same. The
		### config is created during CQ run and cleaned up once the run
		### is complete. If for some reason, it isn't, it will cause
		### problems during BQ/LQ. Cluster stop will cleanup shared temp
		### so this is unlikely, also build name is used to reduce the
		### likelyhood.
		if (ariba::rc::Utils::allowCQConfig($productName, $serviceName)) {
			my $sharedTempDir = ariba::rc::Utils::sharedTempDir($configDir);
			if (defined $sharedTempDir) {
				my $cqRolesFile = "$sharedTempDir/$buildName" . "_cqtopology/roles.cfg";
				if (-r $cqRolesFile) {
					$rolesFile = $cqRolesFile;
				}
			}
		}

		if (! -f $rolesFile) {
			$rolesFile = "$configDir/$productName-roles.cfg";
		}

		my $rolesToDirsFile = "$configDir/roles2dirs.cfg";

		$self->setConfigDir($configDir);
		$self->setProductName($productName);
		$self->setServiceName($serviceName);
		$self->setBuildName($buildName);
		$self->setCustomer($customer);

		$self->setRolesFile($rolesFile);
		$self->setRolesToDirsFile($rolesToDirsFile);

		$self->_readAndInitializeRoles();

		if ( defined($serviceName) && defined($buildName) ) {
			$self->_readAndInitializeCopyDetails();
		}
	}

	return $self;
}

sub newWithProduct
{
	my $class   = shift;
	my $product = shift;

	my $self = $class->new(
		$product->configDir(), 
		$product->name(),
		$product->service(),
		$product->buildName(),
		$product->customer()
	);

	$self->setProduct($product);

	return $self;
}

=pod

=item * save(file)

saves the information to a a file specified in some cannonical format.

=cut
sub save
{
	my $self = shift;
	my $file = shift;

	my $dir = dirname($file);

	unless (-d $dir) {
		mkpath($dir) or warn "Can't create dir: [$dir]: $!";
	}

	my $date = localtime(time());

	open(FH, "> $file") or do {
		warn "Error: Can't write to [$file]: $!";
		return 0;
	};

	print FH "#\n";
	print FH "# This file was created automatically by $0\n";
	print FH "# on $date\n";
	print FH "#\n";

	for my $cluster ($self->clusters()) {
		print FH "\n#\n";
		print FH "cluster = $cluster\n";
		print FH "#\n\n";
		for my $role ($self->rolesInCluster($cluster)) {
			print FH "$role\t";
			my $i = 0;
			my $prefix = " ";

			#
			# write out the virtual hosts first
			#
			for my $virtualHost ($self->virtualHostsForRoleInCluster($role, $cluster))
			{
				print FH " $virtualHost { ", join(" ",
						$self->realHostsForVirtualHostInCluster($virtualHost, 
						$cluster)), " }\n\t\t";
			}

			for my $host ($self->hostsForRoleInCluster($role, $cluster)) {
				#
				# write this real host out only if it was not previously
				# written out as part of virtual host line
				#
				if ($self->virtualHostsForRealHostInCluster($host, $cluster)) {
					next;
				}

				print FH "$prefix$host";
				$i++;
				unless ($i % 2) {
					$prefix = "\n\t\t";
				} else {
					$prefix = " ";
				}
			}
			print FH "\n\n";
		}
	}
	close(FH);
}

sub _getUniqueItemsToAppend
{
	my $class = shift;
	my $oldArrayRef = shift;
	my $newArrayRef = shift;

	my @appendArray = ();

	for my $newValue (@$newArrayRef) {
		my $found = 0;
		for my $oldValue (@$oldArrayRef) {
			if ($oldValue eq $newValue) {
				$found = 1;
				last;
			}
		}
		push(@appendArray, $newValue) unless($found);
	}

	return @appendArray;
}

sub _readAndInitializeRoles
{
	my $self = shift;

	my $rolesFile = $self->rolesFile();

	open(FH, $rolesFile) or do {
		warn "Error: Can't read [$rolesFile]: $!";
		return undef;
	};

	my $class   = ref($self);
	my $domain  = $defaultDomain;
	my $cluster = ariba::rc::RolesManager->defaultCluster();

	my $clusterHostsRoles;
	my $clusterRolesHosts;
	my $clusterVirtualHostsRoles;
	my $clusterRolesVirtualHosts;

	my $realHostToVirtualHost;
	my $realHostToRolesVirtualHost;
	my $virtualHostToRealHost;

	my (@hosts, @virtualHosts, @clusters, @roles);
	my $rolesFromPath;
	my $rolesToPath;
	my $prevRole;
	my $preDeclaredCluster;

	my $preline;

	while( my $line = $preline || <FH> ) {

		$preline = undef;

		next if ($line =~ /^\s*#/o || $line =~ /^\s*;/o);

		chomp($line);

		$line =~ s/\cM$//o;
		$line =~ s/\s*$//o;

		next if $line =~ /^\s*$/;

		# parse domain line:
		# domain = .snv.ariba.com
		# clean it up to allow '.snv.ariba.com' or 'snv.ariba.com'
		if ($line =~ /\s*domain\s*=\s*(.*)\s*/o) {
			$domain = $1;
			$domain =~ s|^\.||;
			next;
		}

		# parse cluster line:
		# cluster = primary
		if ($line =~ /\s*cluster\s*=\s*(.*)\s*/o) {
			$preDeclaredCluster = $1;
			next;
		}

		# allow continuation of hosts specification for a role on to next
		# line, if the line begins with whitespace (role), 
		# it's a continuation line
		my $lineNum = $.;
		while ($preline = <FH>) {
			if ($preline !~ /^\s+\w+/) {
				last;
			}

			chomp($preline);
			$line = "$line $preline";
			$lineNum = $.;
		}

		# tidy up the line
		$line =~ s/\cM$//go;
		$line =~ s/\s*$//go;
		$line =~ s/\s+/ /go;

		next if $line =~ /^\s*$/;

		# each line of format:
		#
		# role host1 host2 fqhn [cluster]
		# OR
		# role host1 virtualHost {host2 host3} host4
		#
		# Validate the virtual host specification syntax
		#
		my $syntaxCheck = $line;
		$syntaxCheck =~ s|^\w+\s*||;
		while ( $syntaxCheck =~ m|{|o || $syntaxCheck =~ m|}|o ) {
			my $match = '[\w\.\-]+\s*{\s*[\w\.\-]+[^}]+}';

			if ( $syntaxCheck !~ m#$match# ) {
				die "ERROR: Syntax error at $rolesFile:$lineNum virtual host line should be of form virtual { real1 real2 }\n";
			}

			$syntaxCheck =~ s|$match||;
		}

		# check to see if the cluster is defined as the last element
		# on the line, if so pull it out
		if ($line =~ s/(primary|secondary|standby|disaster|backup)$//) {
			$cluster = $1;
		} else {
			$cluster = $preDeclaredCluster ||
				ariba::rc::RolesManager->defaultCluster();
		}

		# pull out virual host that is specified in a format like:
		my $virtualHost;
		while ( $line =~ s/([\w\.\-]+)\s*{([^}]+)}/$2/o ) {
			$virtualHost = $1;
			my $realHosts = $2;

			unless ($virtualHost =~ m|\.|o) {
					$virtualHost .= ".$domain";
			}
			for my $realHost (split(/\s+/, $realHosts)) {
				next if ($realHost =~ /^\s*$/);
				unless ($realHost =~ m|\.|o) {
					$realHost .= ".$domain";
				}
				$realHostToVirtualHost->{$cluster}->{$realHost}->{$virtualHost} = 1;
				push(@{$virtualHostToRealHost->{$cluster}->{$virtualHost}},$realHost);
			}
		}

		# here we start the parsing of role <host1> <host2> format
		my @fields = split(/\s+/, $line);
		my $role   = shift(@fields);

		for my $host (@fields) {
			# roles.cfg may have tokens that haven't been expanded
			# this is a work-around for a bootstrap problem that 
			# blows up the code
			next if $host =~ /^\*/;

			# we can also get bogus expansions from other products
			# make sure our returned hosts are real
			# skipping "hosts" like 
			# Unknown-an-dev-hostsForRole('reporting-database')
			next if $host =~ /^Unknown-\w+/;

			unless ($host =~ m|\.|o) {
				$host .= ".$domain";
			}

			push @hosts, $class->_getUniqueItemsToAppend(\@hosts, [$host]);

			push @roles, $class->_getUniqueItemsToAppend(\@roles, [$role]);

			push @clusters, $class->_getUniqueItemsToAppend(\@clusters, [$cluster]);

			$clusterHostsRoles->{$cluster}->{$host}->{$role} = 1;
			$clusterRolesHosts->{$cluster}->{$role}->{$host} = 1;

			# tuck away virtual hosts
			if ($virtualHost) {

				push @virtualHosts, $class->_getUniqueItemsToAppend(\@virtualHosts, [$virtualHost]);

				$clusterVirtualHostsRoles->{$cluster}->{$virtualHost}->{$role} = 1;
				$clusterRolesVirtualHosts->{$cluster}->{$role}->{$virtualHost} = 1;

				$realHostToRolesVirtualHost->{$cluster}->{$host}->{$role}->{$virtualHost} = 1;
			}
		}
	}
	close(FH);

	$self->setClusterRolesHosts($clusterRolesHosts);
	$self->setClusterHostsRoles($clusterHostsRoles);

	$self->setClusterRolesVirtualHosts($clusterRolesVirtualHosts);
	$self->setClusterVirtualHostsRoles($clusterVirtualHostsRoles);

	$self->setRealHostToVirtualHost($realHostToVirtualHost);
	$self->setRealHostToRolesVirtualHost($realHostToRolesVirtualHost);
	$self->setVirtualHostToRealHost($virtualHostToRealHost);

	$self->setHosts(@hosts);
	$self->setVirtualHosts(@virtualHosts);
	$self->setRoles(@roles);
	$self->setClusters(@clusters);
}

sub _addCopyDetailsForRole
{
	my $self = shift;

	my($role, $providedBy, $toUser, $toPath, $dir) = @_;

	my $copyDetails = $self->copyDetails();

	# src details
	push(@{$copyDetails->{$role}->{'providedBy'}}, $providedBy);
	push(@{$copyDetails->{$role}->{'fromDirs'}}, $dir);

	# dest details
	push(@{$copyDetails->{$role}->{'toUsers'}}, $toUser);
	push(@{$copyDetails->{$role}->{'toPaths'}}, $toPath);

	$self->setCopyDetails($copyDetails);
}

sub _readAndInitializeCopyDetails
{
	my $self = shift;

	my $rolesToDirsFile = $self->rolesToDirsFile();

	return undef unless ( -e $rolesToDirsFile );

	open(FH, $rolesToDirsFile);

	while(<FH>) {
		chomp;
		s/\cM$//o;
		next if (/^\s*$/o || /^\s*#/o) ;

		my ($role,$dirs) = split(/\s+/, $_, 2);

		my $toUser = ariba::rc::Globals::deploymentUser($self->productName(), 
								$self->serviceName());
		my $toPath = ariba::rc::Globals::rootDir($self->productName(), 
							 $self->serviceName(), 
							 $self->customer()) . 
							 "/" . $self->buildName();
		for my $dir (split(/\s+/,$dirs)) {
			#
			# For files provided by customers, default/sample files
			# are distributed by default.
			#
			# personalities are provided by customers. List one or more 
			# default/sample personality that can pushed as part of the build.
			#
			# role   cust-config:DirName:default1;default2...
			# ex.
			#
			# personalities (name of the role)
			# cust-config (a flag that indicates that some content of this
			#			  role is controlled by customer, not p4)
			# p (maps to <buildname>/../p, so that data in this directory is
			#	not blown away with each build push.)
			# ANDefault (a default personality from p4 that is part of build
			#			and ends up as <buildname>/ANDefault)
			#
			# will be stated as:
			# personalities cust-config:p:ANDefault;Ariba
			#
			
			if ($dir =~ /^cust-config:(.*)/) {
				$dir = $1;
				my ($toDir, $defaultDirs) = split(/:/,$dir);
				my $dest = dirname($toPath) . "/$toDir";

				if (!defined ($defaultDirs)) {
					$self->_addCopyDetailsForRole($role, "customer", $toUser, $dest, "none");
					next;
				}

				for my $defaultDir (split(';',$defaultDirs)) {
					my $src = $defaultDir;
					$self->_addCopyDetailsForRole($role, "customer", $toUser, $dest, $src);
				}

			} else {
				$self->_addCopyDetailsForRole($role, "build", $toUser, $toPath, $dir);
			}
		}
	}
	close(FH);
}

=pod

=item * hostServesRoleInCluster(host, role, cluster)

returns true if the host plays any role at all in the specified cluster

=cut
sub hostServesRoleInCluster
{
	my $self = shift;
	my $host = shift;
	my $role = shift;
	my $cluster = shift;

	unless ($self->configDir() and defined($cluster)) {
		return 0;
	}

	my $clusterRolesHosts = $self->clusterRolesHosts();

	if ( defined($clusterRolesHosts->{$cluster}) &&
		 defined($clusterRolesHosts->{$cluster}->{$role}) &&
		 defined($clusterRolesHosts->{$cluster}->{$role}->{$host}) ) {
		 return 1;
	}

	return 0;
}

=pod

=item * addNewHostWithSameRolesAs(newhost, oldhost)

Adds new host as a host performing same roles as the old host
In order to make this change persistant, 'save' method should be called.

=cut
sub addNewHostWithSameRolesAs
{
	my $self = shift;
	my $newHost = shift;
	my $oldHost = shift;

	unless ($self->configDir()) {
		return 0;
	}

	my $clusterHostsRoles = $self->clusterHostsRoles();
	my $clusterRolesHosts = $self->clusterRolesHosts();

	my $realHostToVirtualHost = $self->realHostToVirtualHost();
	my $virtualHostToRealHost = $self->virtualHostToRealHost();

	my $added = 0;

	for my $cluster (keys (%$clusterHostsRoles) ) {
		for my $role ( keys (%{$clusterHostsRoles->{$cluster}->{$oldHost}}) ) {
			$added++;
			$clusterHostsRoles->{$cluster}->{$newHost}->{$role} = 1;
			$clusterRolesHosts->{$cluster}->{$role}->{$newHost} = 1;
		}

		if ( defined($realHostToVirtualHost->{$cluster}) &&
		     defined($realHostToVirtualHost->{$cluster}->{$oldHost}) ) {
			for my $virtualHost ( keys (%{$realHostToVirtualHost->{$cluster}->{$oldHost}}) ) {
				$realHostToVirtualHost->{$cluster}->{$newHost}->{$virtualHost} = 1;
				push(@{$virtualHostToRealHost->{$cluster}->{$virtualHost}}, $newHost);
			}
		}
	}

	return $added;
}

=pod

=item * removeHostFromRoles(host)

Removes host performing roles in all clusters
In order to make this change persistant, 'save' method should be called.

=cut
sub removeHostFromRoles
{
	my $self = shift;
	my $host = shift;

	unless ($self->configDir()) {
		return 0;
	}

	my $clusterHostsRoles = $self->clusterHostsRoles();
	my $clusterRolesHosts = $self->clusterRolesHosts();

	my $realHostToVirtualHost = $self->realHostToVirtualHost();
	my $virtualHostToRealHost = $self->virtualHostToRealHost();

	my $removed = 0;

	for my $cluster (keys (%$clusterHostsRoles) ) {

		for my $role ( keys (%{$clusterHostsRoles->{$cluster}->{$host}}) ) {

			$removed++;
			delete $clusterHostsRoles->{$cluster}->{$host}->{$role};
			delete $clusterRolesHosts->{$cluster}->{$role}->{$host};
		}

		if ( defined($realHostToVirtualHost->{$cluster}) &&
		     defined($realHostToVirtualHost->{$cluster}->{$host}) ) {

			for my $virtualHost ( keys (%{$realHostToVirtualHost->{$cluster}->{$host}}) ) {

				delete $realHostToVirtualHost->{$cluster}->{$host}->{$virtualHost};

				# Grep out the old host
				@{$virtualHostToRealHost->{$cluster}->{$virtualHost}} =
					grep { ! /$host/ } @{$virtualHostToRealHost->{$cluster}->{$virtualHost}};
			}
		}
	}

	return $removed;
}

=pod

=item * hostsForRoleInCluster(role, cluster)

a list hosts playing specified role in a given cluster.

=cut
sub hostsForRoleInCluster
{
	my $self = shift;
	my $role = shift;
	my $cluster = shift;

	my @hosts;

	unless ($self->configDir()) {
		return @hosts;
	}

	my $clusterRolesHosts = $self->clusterRolesHosts();

	if ( defined($clusterRolesHosts->{$cluster}) &&
		 defined($clusterRolesHosts->{$cluster}->{$role}) ) {
		push(@hosts, keys(%{$clusterRolesHosts->{$cluster}->{$role}}) );
	}

	return @hosts;
}

=pod

=item * virtualHostsForRoleInCluster(role, cluster)

a list hosts playing specified role in a given cluster.

=cut
sub virtualHostsForRoleInCluster
{
	my $self = shift;
	my $role = shift;
	my $cluster = shift;

	my @hosts;

	unless ($self->configDir()) {
		return @hosts;
	}

	my $clusterRolesVirtualHosts = $self->clusterRolesVirtualHosts();

	if ( defined($clusterRolesVirtualHosts->{$cluster}) &&
		 defined($clusterRolesVirtualHosts->{$cluster}->{$role}) ) {
		push(@hosts, keys(%{$clusterRolesVirtualHosts->{$cluster}->{$role}}) );
	}

	return @hosts;
}

=pod

=item * realOrVirtualHostsForRoleInCluster(role, cluster)

a list real or virtual hosts playing specified role in a given cluster.

=cut
sub realOrVirtualHostsForRoleInCluster
{
	my $self = shift;
	my $role = shift;
	my $cluster = shift;

	my @hosts = $self->virtualHostsForRoleInCluster($role, $cluster);

	unless(@hosts) {
		@hosts = $self->hostsForRoleInCluster($role, $cluster);
	}

	return @hosts;
}

=pod

=item * hostsInCluster(cluster)

list of all hosts in the spcified cluster

=cut
sub hostsInCluster
{
	my $self = shift;
	my $cluster = shift;

	my @hosts;

	unless ($self->configDir()) {
		return @hosts;
	}

	my $clusterHostsRoles = $self->clusterHostsRoles();

	if ( defined($clusterHostsRoles->{$cluster}) ) {
		push( @hosts, keys(%{$clusterHostsRoles->{$cluster}}) );
	}

	return @hosts;
}

=pod

=item * virtualHostsInCluster(cluster)

list of all hosts in the spcified cluster

=cut
sub virtualHostsInCluster
{
	my $self = shift;
	my $cluster = shift;

	my @hosts;

	unless ($self->configDir()) {
		return @hosts;
	}

	my $clusterVirtualHostsRoles = $self->clusterVirtualHostsRoles();

	if ( defined($clusterVirtualHostsRoles->{$cluster}) ) {
		push( @hosts, keys(%{$clusterVirtualHostsRoles->{$cluster}}) );
	}

	return @hosts;
}

=pod

=item * clustersForHost(host)

a list of all clusters a host belongs to.

=cut
sub clustersForHost
{
	my $self = shift;
	my $host = shift;

	my @clusters;

	unless ($self->configDir()) {
		return @clusters;
	}

	my $clusterHostsRoles = $self->clusterHostsRoles();

	for my $cluster (keys(%{$clusterHostsRoles})) {
		if ( defined($clusterHostsRoles->{$cluster}->{$host}) ) {
			push(@clusters, $cluster);
		}
	}

	return @clusters;
}

=pod

=item * clustersForVirtualHost(host)

a list of all clusters a host belongs to.

=cut
sub clustersForVirtualHost
{
	my $self = shift;
	my $host = shift;

	my @clusters;

	unless ($self->configDir()) {
		return @clusters;
	}

	my $clusterVirtualHostsRoles = $self->clusterVirtualHostsRoles();

	for my $cluster (keys(%{$clusterVirtualHostsRoles})) {
		if ( defined($clusterVirtualHostsRoles->{$cluster}->{$host}) ) {
			push(@clusters, $cluster);
		}
	}

	 return @clusters;
}

=pod

=item * rolesForHostInCluster(host, cluster)

a list of roles played by a real or a virtual host in a given cluster.

=cut
sub rolesForHostInCluster
{
	my $self = shift;
	my $host = shift;
	my $cluster = shift;

	my @roles;

	unless ($self->configDir()) {
		return @roles;
	}


	my $clusterHostsRoles = $self->clusterHostsRoles();

	if ( defined($clusterHostsRoles->{$cluster}) &&
		 defined($clusterHostsRoles->{$cluster}->{$host}) ) {
		push(@roles, keys(%{$clusterHostsRoles->{$cluster}->{$host}}) );
	} else {
		push(@roles, $self->rolesForVirtualHostInCluster($host, $cluster));
	}

	return @roles;
}

=pod

=item * rolesForVirtualHostInCluster(host, cluster)

a list of roles played by a virtual host in a given cluster.

=cut
sub rolesForVirtualHostInCluster
{
	my $self = shift;
	my $host = shift;
	my $cluster = shift;

	my @roles;

	unless ($self->configDir()) {
		return @roles;
	}


	my $clusterVirtualHostsRoles = $self->clusterVirtualHostsRoles();

	if ( defined($clusterVirtualHostsRoles->{$cluster}) &&
		 defined($clusterVirtualHostsRoles->{$cluster}->{$host}) ) {
		push(@roles, keys(%{$clusterVirtualHostsRoles->{$cluster}->{$host}}) );
	 }

	 return @roles;
}

=pod

=item * rolesInCluster(cluster)

a list of all roles in cluster

=cut
sub rolesInCluster
{
	my $self = shift;
	my $cluster = shift;

	my @roles;

	unless ($self->configDir()) {
		return @roles;
	}

	my $clusterRolesHosts = $self->clusterRolesHosts();

	if ( defined($clusterRolesHosts->{$cluster}) ) {
		push( @roles, keys(%{$clusterRolesHosts->{$cluster}}) );
	}

	return @roles;
}

=pod

=item * isARoleIn(string)

a given string a real role

=cut
sub isARole
{
	my $self = shift;
	my $role = shift;

	return($self->isARoleInCluster($role));
}

=pod

=item * isARoleInCluster(string, cluster)

a given string a real role

=cut
sub isARoleInCluster
{
	my $self = shift;
	my $role = shift;
	my $specifiedCluster = shift;

	my $ret = 0;

	unless ($self->configDir()) {
		return $ret;
	}

	my $clusterRolesHosts = $self->clusterRolesHosts();

	#
	# if cluster is not specified, work with all clusters
	#
	my @clusters = ($specifiedCluster) || $self->clusters();

	for my $cluster (@clusters) {
		if ( defined($clusterRolesHosts->{$cluster}) &&
		     defined($clusterRolesHosts->{$cluster}->{$role}) ) {
			$ret = 1;
			last;
		}
	}

	return $ret;
}

=pod

=item * clustersForRole(role)

a list of all clusters that have the given role defined for them

=cut
sub clustersForRole
{
	my $self = shift;
	my $role = shift;

	my @clusters;

	unless ($self->configDir()) {
		return @clusters;
	}

	my $clusterRolesHosts = $self->clusterRolesHosts();

	for my $cluster (keys(%{$clusterRolesHosts})) {
		if ( defined($clusterRolesHosts->{$cluster}->{$role}) ) {
			push(@clusters, $cluster);
		 }
	}

	return @clusters;
}

=pod

=item * virtualHostsForRealHostInCluster(host, cluster[, role])

a list of virtualHosts that correspond to the real hostname. 
role is optional and is used to uniquely identify the correct virtual host for a role 
if a real host is mapped to multiple virtual hosts.

=cut
sub virtualHostsForRealHostInCluster
{
	my $self = shift;
	my $host = shift;
	my $cluster = shift;
	my $role = shift;

	my @hosts;

	unless ($self->configDir()) {
		return @hosts;
	}

	if ($role) { 
		my $realHostToRolesVirtualHost = $self->realHostToRolesVirtualHost();

		if ( defined($realHostToRolesVirtualHost->{$cluster}) &&
			 defined($realHostToRolesVirtualHost->{$cluster}->{$host}) &&
			 defined($realHostToRolesVirtualHost->{$cluster}->{$host}->{$role}) ) {
			push(@hosts, keys(%{$realHostToRolesVirtualHost->{$cluster}->{$host}->{$role}}) );
		}

		return @hosts;
	}

	my $realHostToVirtualHost = $self->realHostToVirtualHost();

	if ( defined($realHostToVirtualHost->{$cluster}) &&
	     defined($realHostToVirtualHost->{$cluster}->{$host}) ) {
		push(@hosts, keys(%{$realHostToVirtualHost->{$cluster}->{$host}}) );
	}

	return @hosts;
}

=pod

=item * realHostsForVirtualHostInCluster(host, cluster)

a list of realhosts that define a virtual host

=cut
sub realHostsForVirtualHostInCluster
{
	my $self = shift;
	my $host = shift;
	my $cluster = shift;

	my @hosts;

	unless ($self->configDir()) {
		return @hosts;
	}

	my $virtualHostToRealHost = $self->virtualHostToRealHost();

	if ( defined($virtualHostToRealHost->{$cluster}) &&
	     defined($virtualHostToRealHost->{$cluster}->{$host}) ) {
		push(@hosts, @{$virtualHostToRealHost->{$cluster}->{$host}} );
	}

	# PFS-14014: dedup!
	my @unique_hosts = ();
	my %host_seen;
	foreach my $host ( @hosts ) {
		next if ( exists $host_seen{$host} );

		$host_seen{$host} = 1;
		push(@unique_hosts, $host);
	}

	return @unique_hosts;
}

=pod

=item * dirsToCopyFromForRole(role)

source directories to be copied for a given role

=cut
sub dirsToCopyFromForRole
{
	my $self = shift;
	my $role = shift;

	my @copyFrom;

	unless ($self->configDir()) {
		return @copyFrom;
	}

	my $copyDetails = $self->copyDetails();

	if ( defined($copyDetails->{$role}) &&
	     defined($copyDetails->{$role}->{'fromDirs'}) ) {
		push(@copyFrom, @{$copyDetails->{$role}->{'fromDirs'}});
	}

	return @copyFrom;
}

=pod

=item * dirsProvidedByForRole(role)

nature of contents in the source directory (customer|build)

=cut
sub dirsProvidedByForRole
{
	my $self = shift;
	my $role = shift;

	my @providedBy;

	unless ($self->configDir()) {
		return @providedBy;
	}

	my $copyDetails = $self->copyDetails();

	if ( defined($copyDetails->{$role}) &&
	     defined($copyDetails->{$role}->{'providedBy'}) ) {
		push(@providedBy, @{$copyDetails->{$role}->{'providedBy'}});
	}

	return @providedBy;
}

=pod

=item * pathsToCopyToForRole(role)

final destination for the directories to be transferred to

=cut
sub pathsToCopyToForRole
{
	my $self = shift;
	my $role = shift;

	my @copyTo;

	unless ($self->configDir()) {
		return @copyTo;
	}

	my $copyDetails = $self->copyDetails();

	if ( defined($copyDetails->{$role}) &&
	     defined($copyDetails->{$role}->{'toPaths'}) ) {
		push(@copyTo, @{$copyDetails->{$role}->{'toPaths'}});
	}

	return @copyTo;
}

=pod

=item * usersToCopyToForRole(role)

user to copy the directory over as.

=cut
sub usersToCopyToForRole
{
	my $self = shift;
	my $role = shift;

	my @usersTo;

	unless ($self->configDir()) {
		return @usersTo;
	}

	my $copyDetails = $self->copyDetails();

	if ( defined($copyDetails->{$role}) &&
	     defined($copyDetails->{$role}->{'toUsers'}) ) {
		push(@usersTo, @{$copyDetails->{$role}->{'toUsers'}});
	}

	return @usersTo;
}

sub DESTROY {
        my $self = shift;

        $self->setProduct(undef);
}

sub main
{
	#my $rm = ariba::rc::RolesManager->new(
	#	'/home/rc/archive/builds/an/Ween-66/config/dev',
	#	'an',
	#	'dev',
	#	'Ween-66'
	#);

	my $product = ariba::rc::InstalledProduct->new('an', 'dev');
	my $rm      = ariba::rc::RolesManager->newWithProduct($product);

	my $cluster = $ARGV[0] || ariba::rc::RolesManager->defaultCluster();

	my @vhs = $rm->virtualHostsInCluster($cluster);
	print "virtual hosts in cluster = ", join(", ", @vhs), "\n";
	print "=================================\n";

	for my $vh (@vhs) {
		my @hs = $rm->realHostsForVirtualHostInCluster($vh, $cluster);

		for my $h (@hs) {
			print "real host for $vh = $h\n";
			print "virual host for $h = ", join(", ", $rm->virtualHostsForRealHostInCluster($h, $cluster)), "\n";
		}

		print "--------------------------------\n\n";

		my @roles = $rm->rolesForVirtualHostInCluster($vh,$cluster);

		for my $role (@roles) {
			print "roles for $vh = ", join(", ", @roles), "\n";

			my @rvhs = $rm->virtualHostsForRoleInCluster($role, $cluster);

			print "virtual hosts that play $role = ", join(", ", @rvhs), "\n";
			print "real hosts that play $role = ", join(", ", $rm->hostsForRoleInCluster($role, $cluster)), "\n";
		}

		print "=================================\n\n";
	}

	print "\n";

	for my $role ($rm->roles()) {

		print "$role on $cluster cluster is played by:\n";

		for my $host ($rm->hostsForRoleInCluster($role, $cluster)) {
			print "  $host\n";
		}

		my @dirsFrom   = $rm->dirsToCopyFromForRole($role);
		my @providedBy = $rm->dirsProvidedByForRole($role);
		my @toPaths    = $rm->pathsToCopyToForRole($role);
		my @toUsers    = $rm->usersToCopyToForRole($role);
		my @toHosts    = $rm->hostsForRoleInCluster($role, $cluster);

		if ($#dirsFrom != $#toPaths) {
			die "ERROR: src != dest\n";
		}

		for (my $i = 0; $i < scalar(@dirsFrom); $i++) {
			print "  copy $dirsFrom[$i] ($providedBy[$i]) to\n";
			for my $host (@toHosts) {
				print "	$toUsers[$i]\@$host:$toPaths[$i]\n";
			}
		}

		print "\n";
	}

	$rm->addNewHostWithSameRolesAs("foo.ariba.com", "andb1.snv.ariba.com");
	$rm->save("/tmp/roles.cfg");

#	for my $host ($rm->hosts()) {
#		print "$host on $cluster cluster plays:\n";
#		for my $role ($rm->rolesForHostInCluster($host, $cluster)) {
#			print "  $role\n";
#		}
#	}

}

# main();

1;

__END__

=pod

=head1 AUTHOR

Manish Dubey <mdubey@ariba.com>

=head1 SEE ALSO

	ariba::rc::Product

=cut
