#
#
# A module that provides abstraction on top of rc products. Provides API to 
# get information about the product such as :
# name, servicetype, installdir, buildname, releasename etc.
#
# perldoc ariba::rc::Product.pm
#
#
# $Id: //ariba/services/tools/lib/perl/ariba/rc/Product.pm#121 $
#
#
package ariba::rc::Product;

use FindBin;
use File::Basename;

use ariba::rc::AppInstanceManager;
use ariba::rc::Globals;
use ariba::rc::RolesManager;
use ariba::rc::Utils;
use ariba::Ops::NetworkUtils;
use ariba::Ops::PropertyList;
use ariba::Ops::Machine;
use ariba::util::XMLWrapper;
use XML::Simple;

# this is part the class cluster magic
use ariba::rc::SharedServiceProduct;
use ariba::rc::ASPProduct;

my $debug = 0;

=pod

=head1 NAME

ariba::rc::Product - manage Ariba products

=head1 DESCRIPTION

Product is the base class of the Product API,  allowing you to get all the
meta/config information about any Ariba Commerce Network Service product. 

Do not use the Product class directly.  Use ArchivedProduct or InstalledProduct.

There are several routines that fault in the config information, as you
 request them, and can give you information such as :

=over 4

=item * which machines is this product running on

=item * hostnames and domain names for any role (required by the product)

=item * a particular entry in the product's DD.xml

=item * servicename/buildname/releasename/productname etc.

=item * names/port# of wofapps vended through webserver

=item * locations of docroot/cgi-bin/DD.xml etc.

=back

A complete list of all API routines is :

=head1 CLASS METHODS

=over 4

=item * appInstancesMatchingFilter(appInstancesRef, filterArrayRef )

Returns a filtered list of apps based on the provided apps list and the filter criteria

The filtering is done by matching on either the full app instance name or the instance's workerName.
If the filter has a digit, then it is assumed to be single instance, and therefore performs an exact match.
Otherwise, the filter is matched as a regex pattern.

=cut

sub appInstancesMatchingFilter {
    my $class = shift;
    my $appsRef = shift; 
    my $filterArrayRef = shift;

    my @instances = @$appsRef;

    # If not filtering the apps, return them all
    if (!defined($filterArrayRef) || scalar(@$filterArrayRef) <= 0) {
        return @instances;
    }

    my @filteredInstances;

    for my $instance (@instances) {
        my $instanceName = $instance->instanceName();
        my $workerName = $instance->workerName() || "undef";

        for my $filter (@$filterArrayRef) {
            my $singleInstance = my $pattern = undef;

            if (defined($filter) && $filter =~ /\d+/){
                $singleInstance = $filter;
            } else {
                $pattern = $filter;
            }

            if ( defined $singleInstance ){
                if ($instanceName eq $singleInstance ||
                    $workerName eq $singleInstance) {
                    push(@filteredInstances, $instance);
                    last;
                }
                
            }
            if ( defined $pattern ){
                if ($instanceName =~ /$pattern/ ||
                    $workerName =~ /$pattern/) {
                    push(@filteredInstances, $instance);
                    last;
                }
            }
        }
    }

    return @filteredInstances;
}

=item * allProductNames()

returns a list of supported products.

=cut

sub allProductNames
{
    my $class = shift;

    my @aspProducts = ariba::rc::ASPProduct->allProductNames();
    my @ssProducts = ariba::rc::SharedServiceProduct->allProductNames();

    return (@ssProducts, @aspProducts);
}

=item * new() OR new(name, service, buildname)

Create a new product object (or fetch a previously created object out of the
cache). 

=cut
sub new 
{
    my $class = shift;
    my $prodname = shift;
    my $service = shift;
    my $buildname = shift;
    my $customer = shift;
    my $opsConfigLabel = shift;

    my $realSelf;

    unless ( $prodname ) {
        my $configDir = $class->_computeDeployRootFromNothing() . "/" .
                                            $class->_configSubDirectory();
        $prodname = getProductName($configDir);
    }

    print "In creating $class new() for $prodname, $service\n" if ($debug);

    if ( ariba::rc::Globals::isASPProduct($prodname) ) {
        $realSelf = ariba::rc::ASPProduct->new($prodname, $service, $buildname, $customer);

    } else {
        $realSelf = ariba::rc::SharedServiceProduct->new($prodname, $service, $buildname);
    }

    $realSelf->{_createdAt} = time();
    $realSelf->{opsConfigLabel} = $opsConfigLabel;
    return $realSelf;
}

sub _cacheKey
{
    my $class = shift;
    my $prodname = shift;
    my $service = shift;
    my $buildname = shift;
    my $customer = shift;

    my $cacheKey = $prodname;
    $cacheKey .= $service if ( defined($service) );
    $cacheKey .= $buildname if ( defined($buildname) );
    $cacheKey .= $customer if ( defined($customer) );

    return $cacheKey;
}

sub _checkForProductInCache 
{
    my $class = shift;
    my $cache = shift;
    my $prodname = shift;
    my $service = shift;
    my $buildname = shift;
    my $customer = shift;

    my $cacheKey = $class->_cacheKey($prodname, $service, $buildname, $customer);

    if(defined($prodname) && defined($cache->{$cacheKey})){
        my $product =  $cache->{$cacheKey};
        my $realConfigDir = $product->installDir() . "/" .
                    $class->_configSubDirectory();
        my $configDir = $product->configDir();
        my $configDirModTime = (lstat($configDir))[9];
        my $realConfigDirModTime = (stat($realConfigDir))[9];
        my $productLoadedAt = $product->{_createdAt};

        if ($productLoadedAt >= $configDirModTime &&
            $productLoadedAt >= $realConfigDirModTime) {
            return $product;
        } else {
            $cache->{$cacheKey} = undef;
            return undef;
        }
    }
    return undef;
}

sub setNotFaultedIn 
{
    my $self = shift;

    $self->{_defaultsFaultedIn} = 0;
    $self->{_rolesFaultedIn}    = 0;
}

sub _faultInDefaults {
    my $self = shift;

    return $self if ($self->{_defaultsFaultedIn} && $self->{_defaultsFaultedIn} == 1);
    $self->{_defaultsFaultedIn} = 1;

    $self->_loadProductDefaults();

    return $self;
}

sub _faultInRoles {
    my $self = shift;

    return $self if ($self->{_rolesFaultedIn} && $self->{_rolesFaultedIn} == 1);
    $self->{_rolesFaultedIn} = 1;

    $self->_loadProductRoles();

    return $self;
}

sub deploymentUser 
{
    my $self = shift;

        return ariba::rc::Globals::deploymentUser($self->name(), $self->service());
}

sub _computeDeployRootFromNothing {
    my $self = shift;

    my $dir = $FindBin::RealBin;

    while ( $dir ne "/" ) {
        my $configDir = "$dir/" . $self->_configSubDirectory();
        my $productNameFile = "$configDir/ProductName";
        my $serviceNameFile = "$configDir/ServiceName";

        if (-d $configDir && -f $productNameFile && -f $serviceNameFile) {
            return $dir;
        }

        $dir = dirname($dir);
    }

    return undef;
}

sub setBuildName
{
    my $self = shift;
    my $buildname = shift;
    
    $self->{buildName} = $buildname;
}

sub setProductName
{
    my $self = shift;
    my $prodname = shift;
    
    $self->{prodname} = $prodname;
}

sub setServiceName
{
    my $self = shift;
    my $service = shift;
    
    $self->{service} = $service;
}

sub returnEncryptedValues {
    my $self = shift;
	return(1) if($self->{'returnEncryptedValues'});
}

sub setReturnEncryptedValues {
	my $self = shift;
	my $value = shift;
	$self->{'returnEncryptedValues'} = $value;
}

# yes, the ASP sickness has reached all the way to here
# this is to allow programs that loop over any type of product
# to call customer() without having to protect with isASPProduct()
sub customer
{
    my $self = shift;
    return undef;
}

sub prettyCustomerName
{
    my $self = shift;
    return undef;
}

sub _configSubDirectory
{
    return "config";
}

sub _init
{
    my $self = shift;
    my $opsConfigLabel = shift;
    my $cluster = shift;

    $cluster = 'primary' unless $cluster;
    my $productRootDir = $self->_productRootDir($opsConfigLabel);

    $self->{installDir} = $productRootDir;
    my $configDir = "$productRootDir/" . $self->_configSubDirectory();

    if ( $debug ) {
        my $class = ref($self);
        my @isa = @{$class::ISA};
        print "did call _productRootDir().  Class of self == $class isa($class) == ",join(",",@isa)," configdir=$configDir productRootDir=$productRootDir\n";
    }

    $self->{configDir} = $self->_stat("$configDir");
    $self->_setupConfigFiles( $cluster );
}

sub _setupConfigFiles {
    my $self = shift;
    my $cluster = shift;

    my $productRootDir =  $self->{installDir};
    my $configDir = $self->{configDir};
    my $prodname = $self->name();

    $self->{configDir} = $self->_stat("$configDir");
    $self->{definitionFile} = $self->_stat("$configDir/$prodname-definition.cfg");
    $self->{woAppsConfig} = $self->_stat("$configDir/WoApps.cfg");
    $self->{appsConfig} = $self->_stat("$configDir/apps.cfg");
    $self->{appInfo} = $self->_stat("$configDir/asmshared/AppInfo.xml");
    $self->{docRoot} = $self->_stat("$productRootDir/docroot");
    $self->{cgiBin} = $self->_stat("$productRootDir/docroot/cgi-bin");
    $self->_setupPtableDDxml( $configDir, $cluster );

    #
    # releasename has slightly different behavior based on if it
    # passed undef or if it passed a directory that does not
    # exist
    #

    ### Grab releasename, if defined in dd.xml
    $self->{releaseName} = ( -e "$self->{configDir}/ReleaseName" ) ? getReleaseName($self->{configDir}) : $self->default("MetaData.ReleaseName");


    if ($self->{releaseName} ) {
        my $majorRelease = $self->{releaseName};
        $majorRelease =~ s|(\d+(\.\d+)?).*|$1|;
        $self->{majorReleaseName} = $majorRelease;
    }

    ### Grab BranchName, if defined in dd.xml
    $self->{branchName} = ( -e "$self->{configDir}/BranchName" ) ? getBranchName($self->{configDir}) : $self->default("MetaData.BranchName");

    $self->{clusterNameFile} = "$configDir/ClusterName";

    $self->setNotFaultedIn();
}

# In the old world we had this
#        $self->{deploymentDefaults} = $self->_stat("$configDir/DeploymentDefaults.xml");
#        $self->{parametersTable} = $self->_stat("$configDir/Parameters.table");
#
# It's possible for DeploymentDefaults.xml to be hard coded with primary cluster specific info.  This
# makes it incompatible to run in the secondary cluster in the event of a dr fail over.
# For seamless dr-failover compatibility DeploymentDefaults.xml file no longer exist.
# Instead it's been replaced by DeploymentDefaults.xml.primary and DeploymentDefaults.xml.secondary
#
# When startup is called on an app host a soft link is set to one of these two files based on the cluster
# we're running in.  However, when control-deployment is run it's reading the configs directly from 
# the archived deployment in /home/rc/copysrc.  There are no soft links here so we need to determine which
# of the .primary or .secondary files should be used.
#
sub _setupPtableDDxml {
    my $self = shift;
    my $configDir = shift;
    my $cluster = shift;

    my %configs = (
        deploymentDefaults => "$configDir/DeploymentDefaults.xml",
        parametersTable => "$configDir/Parameters.table",
    );

    foreach my $key ( keys %configs ) {
        $self->{ $key } = undef;

        # Perhaps the root P.table or DD.xml file exists.  If so use that and we're done.
        if ( $self->{ $key } = $self->_stat( $configs{ $key } )) {
            next;
        }

        # OK, that didn't work, but we have a defined cluster.  Look for the associated.
        # .primary or .secondary file based on $cluster.
        $self->{ $key } = $self->_stat( $configs{ $key } . ".$cluster" );
    }
}            

sub _stat
{
    my $self = shift;
    my $path = shift;

    if ( -e $path ) {
        return $path;
    } else {
        return undef;
    }
}

sub _computeRoleDetailsForWofApps
{
    my $self = shift;

    my $roleDetails = \%{$self->{'role_details'}} ;

    my $rolesManager = $self->rolesManager();

    for my $cluster ($rolesManager->clusters()) {
        for my $role ($rolesManager->rolesInCluster($cluster)) {
        for my $host ($rolesManager->hostsForRoleInCluster($role,$cluster)) {
            $roleDetails->{$role}{$host} = $cluster;
        }
        }
    }
}

sub reloadParametersTable
{
    my $self = shift;
    $self->_loadParametersTable();
}

sub _setEncryptedParametersDecrypted
{
    my $self = shift;
    my $value = shift;

    $self->{'_encryptedParametersDecrypted'} = $value;
}

sub _encryptedParametersDecrypted
{
    my $self = shift;

    return $self->{'_encryptedParametersDecrypted'};
}

sub _loadParametersTable
{
    my $self = shift;
    my $tableFile = $self->parametersTable();

    if (!defined $tableFile || !-f $tableFile) {
        return 0;
    }

    $self->{'parameters'} = ariba::Ops::PropertyList->newFromFile($tableFile);
    my $encryptedParametersKey = "System.Base.SecureParameters";
    my $encryptedParametersRef = $self->{'parameters'}->valueForKeyPath($encryptedParametersKey);

    for my $encryptedParameter (@$encryptedParametersRef) {
        #$self->{encryptedParameters}
        $self->{pbeEncryptedParameters}->{$encryptedParameter} = $encryptedParameter;
    }

    $self->_setEncryptedParametersDecrypted(0);

    return 1;
}

sub reloadDeploymentDefaults
{
    my $self = shift;
    $self->_loadDeploymentDefaults();
}

sub _setEncryptedDefaultsDecrypted
{
    my $self = shift;
    my $value = shift;

    $self->{'_encryptedDefaultsDecrypted'} = $value;
}

sub _encryptedDefaultsDecrypted
{
    my $self = shift;

    return $self->{'_encryptedDefaultsDecrypted'};
}

sub _loadDeploymentDefaults
{
    my $self = shift;
    my $xmlFile = $self->deploymentDefaults();
    my $defaultsRef = \%{$self->{'defaults'}};
    my $defaultsRefPreserveCase = \%{$self->{'defaultsPreserveCase'}};

    if (!defined $xmlFile || !-f $xmlFile) {
        return 0;
    }

    ariba::util::XMLWrapper::parse($xmlFile, $defaultsRefPreserveCase);
    #
    # store the information in case insensitive assoc array as
    # well (backward compatibility)
    #
    for my $key (keys(%$defaultsRefPreserveCase)) {

        $defaultsRef->{lc $key} = $defaultsRefPreserveCase->{$key};

        # quick lookup of our cipher keys
        my $encKey = $key;
        if ($key =~ s/cipherblocktext//i) {
            $self->{'encryptedDefaults'}->{$key} = $encKey;
            $self->{'encryptedDefaults'}->{lc $key} = $encKey;
        }

        if ($key =~ s/[_]*pbeencrypted[_]*//i) {
            $self->{'pbeEncryptedDefaults'}->{$key} = $encKey;
            $self->{'pbeEncryptedDefaults'}->{lc $key} = $encKey;
        }
    }

    $self->_setEncryptedDefaultsDecrypted(0);

    return 1;
}

sub _loadApps
{
    my $self = shift;

    my $apm = ariba::rc::AppInstanceManager->newWithProduct($self);

    $self->{'appInstanceManager'} = $apm;
}

sub _loadRolesManager
{
    my $self = shift;
    my $rolesManager = ariba::rc::RolesManager->newWithProduct($self);

    $self->{'rolesManager'} = $rolesManager;
}

sub _loadProductDefaults
{
    my $self = shift;
    unless ($self->_loadDeploymentDefaults()) {
        $self->_loadParametersTable();
    }
}

sub _loadProductRoles
{
    my $self = shift;
    $self->_loadRolesManager();
    $self->_computeRoleDetailsForWofApps();
}

sub isASPProduct 
{
    my $self = shift;

    return ariba::rc::Globals::isASPProduct($self->name());
}

sub isSharedServiceProduct 
{
    my $self = shift;

    return ariba::rc::Globals::isSharedServiceProduct($self->name());
}

=pod

=head1 INSTANCE METHODS

=item * name()

Name of the product.

=cut
sub name 
{
        my $self = shift;
        return $self->{prodname};
}

=pod

=item * service()

Service name of this product instance.

=cut
sub service 
{
        my $self = shift;
        return $self->{service};
}

=pod

=item * buildName()

Get the product's buildname.

=cut
sub buildName
{
    my $self = shift;
        return $self->{buildName};
}

=pod

=item * branchName()

Get the perforce branch name from which the product was built.

=cut
sub branchName
{
    my $self = shift;
        return $self->{branchName};
}

=pod

=item * releaseName()

Name of the release of this product.

=cut
sub releaseName
{
    my $self = shift;
        return $self->{releaseName};
}

=pod

=item * majorReleaseName()

Name of the release of this product.

=cut
sub majorReleaseName
{
    my $self = shift;
        return $self->{majorReleaseName};
}

=pod

=item * installDir()

Where is the product installed.

=cut
sub installDir
{
    my $self = shift;
        return $self->{installDir};
}

=pod

=item * configDir()

Get the location of config directory.

=cut
sub configDir
{
    my $self = shift;
        return $self->{configDir};
}

=pod

=item * setConfigDir(dir)

Set the location of config directory.

=cut
sub setConfigDir
{
    my $self = shift;
    my $dir = shift;

        $self->{configDir} = $dir;
}

=pod

=item * docRoot()

Location of docroot of this product, if it has one.

=cut
sub docRoot
{
    my $self = shift;
        return $self->{docRoot};
}

=pod

=item * cgiBin()

Get the location of cgi-bin directory, if there is one. 

=cut
sub cgiBin
{
    my $self = shift;
        return $self->{cgiBin};
}

=pod

=item * clusterNameFile()

Get the location of file that contains the cluster name

=cut
sub clusterNameFile
{
    my $self = shift;
        return $self->{clusterNameFile};
}

=pod

=item * definitionFile()

Get the build/archive definition file name/location for this product.

=cut
sub definitionFile
{
    my $self = shift;
        return $self->{definitionFile};
}

=pod

=item * setAppInstanceManager()

Set the loaded product's AppInstanceManager - useful for testing & debugging.

=cut
sub setAppInstanceManager
{
    my $self = shift;
    my $apm = shift;

    $self->{'appInstanceManager'} = $apm;
}

=pod

=item * appInstanceManager()

Handle to appInstanceManager that can answer various appInstance related
questions, like how many instances of a certain app should run on a given
host etc.

=cut
sub appInstanceManager
{
    my $self = shift;

    unless (defined $self->{'appInstanceManager'}) {
        $self->_loadApps();
    }

    return $self->{'appInstanceManager'};
}


=pod

=item * setRolesManager()

Set the loaded product's rolesManager - useful for testing & debugging.

=cut
sub setRolesManager
{
    my $self = shift;
    my $rolesManager = shift;

    $self->{'rolesManager'} = $rolesManager;
}

=pod

=item * rolesManager()

Handle to roles Manager that can answer various roles related questions,
like does a host serve a certain role

=cut
sub rolesManager
{
    my $self = shift;

    $self->_faultInRoles();
    return $self->{'rolesManager'};
}

=pod

=item * deploymentDefaults()

Get the name/location of DD.xml

=cut
sub deploymentDefaults
{
    my $self = shift;
    return $self->{deploymentDefaults};
}

=pod

=item * parametersTable()

Get the name/location of Parameters.table file

=cut
sub parametersTable
{
    my $self = shift;
    return $self->{parametersTable};
}

=pod

=item * appInfo()

Get the name/location of the AppInfo.xml file

=cut

sub appInfo {
    my $self = shift;
    return $self->{appInfo};
}

=pod

=item * parameters()

Get Parameters.table plist object handle

=cut
sub parameters
{
    my $self = shift;
    return $self->{parameters};
}

sub _tokenizedFiles
{
    my $self = shift;

    my $dir = $self->configDir();
    my $root = $self->installDir();

    my @defaultTokenizedFile = $self->deploymentDefaults();
    my @files;

    my $tokenizedFiles = "$dir/replace-tokens.cfg";

    return @defaultTokenizedFile unless (-f $tokenizedFiles);

    open(FL, $tokenizedFiles) || return @defaultTokenizedFile;
    while(<FL>) {
        s/^\s*//go;
        s/#.*//go;
        s/\s*$//go;
        next if ($_ eq "");

        my ($src, $dest) = split(/\s+/, $_);

        $dest = "$root/$dest";

        push(@files, $dest);
    }
    close(FL);

    return @files;
}

sub _unresolvedTokensFlag
{
    my $self = shift;

    return $self->{'hasUnresolvedTokens'};
}

sub _unresolvedTokensList
{
    my $self = shift;

    return $self->{'allUnresolvedTokens'};
}

sub _parseTokenizedFiles
{
    my $self = shift;

    $self->{'hasUnresolvedTokens'} = 0;

    for my $file ($self->_tokenizedFiles()) {

        next unless (-f $file);

        my $reportFile = basename($file);

        open(FL, $file) || next;
        while(<FL>) {
        while (s/(Unknown-[\w\-().\"]*)//o) {
            push(@{$self->{'allUnresolvedTokens'}}, "$reportFile: $1");
            $self->{'hasUnresolvedTokens'} = 1;
        }
        }
        close(FL);
    }

    return;
}

=pod

=item * hasUnresolvedTokens(report)

does the config for the given product have any un resolved tokens? 

=cut

sub hasUnresolvedTokens
{
    my $self = shift;

    my $unresolvedTokens = $self->_unresolvedTokensFlag();

    unless (defined($unresolvedTokens)) {
        $self->_parseTokenizedFiles();
    }

    return($self->_unresolvedTokensFlag());
}

=pod

=item * allUnresolvedTokens()

report all the unresolved tokens in config files.

=cut

sub allUnresolvedTokens
{
    my $self = shift;

    my $unresolvedTokens = $self->_unresolvedTokensList();

    unless (defined($unresolvedTokens)) {
        $self->_parseTokenizedFiles();
    }

    return($self->_unresolvedTokensList());
}

=pod

=item * servesRoleInCluster(host, role, cluster)

Does the given host, play the given role?

=cut
sub servesRoleInCluster
{
    my $self = shift;
    my $host = shift;
    my $role = shift;
    my $cluster = shift;

    my $rolesManager = $self->rolesManager();
    $cluster = $self->clusterForHost($host) unless($cluster);

    return ($rolesManager->hostServesRoleInCluster($host, $role, $cluster));
}

=pod

=item * rolesForHostInCluster(host, cluster)

List of all roles played by this host.

=cut
sub rolesForHostInCluster
{
    my $self = shift;
    my $host = shift;
    my $cluster = shift;

    my $rolesManager = $self->rolesManager();
    $cluster = $self->clusterForHost($host) unless($cluster);

    return ($rolesManager->rolesForHostInCluster($host, $cluster));
}

=pod

=item * singleRoleForHostInCluster(host, cluster, offset)

A role played by this host.

=cut
sub singleRoleForHostInCluster
{
    my $self = shift;
    my $role = shift;
    my $cluster = shift;
    my $offset = shift;

    unless ($offset) {
        $offset = 0;
    }

    my @roles = $self->rolesForHostInCluster($role, $cluster);

    my $singleRole;
    if (@roles && $offset < @roles) {
        $singleRole = $roles[$offset];
    }

    return $singleRole;
}

=pod

=item * hostsForRoleInCluster(role, cluster)

List of all the hosts that play a particular role.

=cut
sub hostsForRoleInCluster
{
    my $self = shift;
    my $role = shift;
    my $cluster = shift;

    my $rolesManager = $self->rolesManager();
    $cluster = $self->currentCluster() unless($cluster);

    return ($rolesManager->hostsForRoleInCluster($role, $cluster));
}

=pod

=item * hostsForRolePrefixInCluster(role, cluster)

List of all the hosts that match a role prefix

=cut
sub hostsForRolePrefixInCluster
{
    my $self = shift;
    my $rolePrefix = shift;
    my $cluster = shift;

    my $rolesManager = $self->rolesManager();
    $cluster = $self->currentCluster() unless($cluster);

    return unless $rolePrefix;

    my @roles = grep { m/^$rolePrefix/ } $self->allRoles();

    my @hosts;
    my %seenHosts;

    for my $role (@roles) {
        for my $host ( $rolesManager->hostsForRoleInCluster($role, $cluster) ) {
            unless ($seenHosts{$host}) {
                push(@hosts, $host);
                $seenHosts{$host} = 1;
            }
        }
    }

    return @hosts;
}

=pod

=item * singleHostForRoleInCluster(role, cluster, offset)

Return one host that plays a role in a cluster.

=cut
sub singleHostForRoleInCluster
{
    my $self = shift;
    my $role = shift;
    my $cluster = shift;
    my $offset = shift;

    unless ($offset) {
        $offset = 0;
    }

    my @hosts = $self->hostsForRoleInCluster($role, $cluster);

    my $singleHost;
    if (@hosts && $offset < @hosts) {
        $singleHost = $hosts[$offset];
    }

    return $singleHost;
}

=pod

=item * virtualHostsForRoleInCluster(role, cluster)

List of virtual hosts that play a particular role, returns list of
real hosts if there are no virtual hosts for the specified role.

=cut
sub virtualHostsForRoleInCluster
{
    my $self = shift;
    my $role = shift;
    my $cluster = shift;

    my $rolesManager = $self->rolesManager();
    $cluster = $self->currentCluster() unless($cluster);

    return ($rolesManager->realOrVirtualHostsForRoleInCluster($role, $cluster));
}

=pod

=item * virtualHostForRoleInCluster(role, cluster)

virtual host that play a particular role, returns list of
real hosts if there are no virtual hosts for the specified role.

=cut
sub virtualHostForRoleInCluster
{
    my $self = shift;
    my $role = shift;
    my $cluster = shift;

    my @vhosts = $self->virtualHostsForRoleInCluster($role, $cluster);

    if (@vhosts) {
        return $vhosts[0];
    } else {
        return undef;
    }
}

=pod

=item * hostsForVirtualHostInCluster(virtualHost, cluster)

List of hosts that make up a virtual host in a given cluster.

=cut
sub hostsForVirtualHostInCluster
{
    my $self = shift;
    my $virtualHost = shift;
    my $cluster = shift;

    my $rolesManager = $self->rolesManager();
    $cluster = $self->currentCluster() unless($cluster);

    return ($rolesManager->realHostsForVirtualHostInCluster($virtualHost, $cluster));
}

=pod

=item * virtualHostForHostInCluster(host, cluster[, role])

one of the virtual hosts that are defined for a given host in the cluster.
role is optional and is used to uniquely identify the correct virtual host for a role 
if a real host is mapped to multiple virtual hosts.

=cut
sub virtualHostForHostInCluster
{
    my $self = shift;
    my $host = shift;
    my $cluster = shift;
    my $role = shift;

    my @vhosts = $self->virtualHostsForHostInCluster($host, $cluster, $role);

    if (@vhosts) {
        return $vhosts[0];
    } else {
        return undef;
    }
}
=pod

=item * virtualHostsForHostInCluster(host, cluster[, role])

List of virtual hosts that are defined for a given host in the cluster.
role is optional and is used to uniquely identify the correct virtual host for a role 
if a real host is mapped to multiple virtual hosts.

=cut
sub virtualHostsForHostInCluster
{
    my $self = shift;
    my $host = shift;
    my $cluster = shift;
    my $role = shift;

    my $rolesManager = $self->rolesManager();
    $cluster = $self->currentCluster() unless($cluster);

    return ($rolesManager->virtualHostsForRealHostInCluster($host, $cluster, $role));
}

=pod

=item * activeHostForVirtualHostInCluster (virtualHost, cluster)

Active host for the virtual host in the cluster based on the MAC address

=cut
sub activeHostForVirtualHostInCluster {
    my $product = shift;
    my $virtualHost = shift;
    my $cluster = shift;

    #XXXX FIX THIS!!!!!  Some callers call this with args in wrong order!!
    if ( ref($virtualHost) ) {
        my $temp = $virtualHost;
        $virtualHost = $product;
        $product = $temp;
    }

    unless ($virtualHost) {
        return undef;
    }

    my @hosts = $product->hostsForVirtualHostInCluster($virtualHost, $cluster);
    push(@hosts, $virtualHost) unless (@hosts);

    return ($product->activeHostForVirtualHostUsingMacAddress($virtualHost, @hosts));
}

=pod

=item * activeHostForVirtualHostUsingMacAddress(virtualHost, hosts)

Active host for the virtual host based on the provided list of hosts and their MAC addresses

=cut
sub activeHostForVirtualHostUsingMacAddress {
    my $product = shift;
    my $virtualHost = shift;
    my @hosts = @_;

    return undef unless($virtualHost);
    return undef unless(@hosts);

    # $virtualMac comes back normalized
    my $virtualMac = ariba::Ops::NetworkUtils::macAddressForHost($virtualHost);

    if (!defined($virtualMac)) {
        # try once more
        $virtualMac = ariba::Ops::NetworkUtils::macAddressForHost($virtualHost) || return undef;
    }

    #
    # loop over all hosts and see which machines mac matches
    # the mac of virtual host
    #
    for my $host (@hosts) {
        #
        # sometimes host passed in is same as virtual host and it
        # may not have a machine db record. Check for it before
        # trying to allocate machine db entry.
        #
        if ($host eq $virtualHost) {
            return $host;
        }

        #
        # look through all mac addrss fields in machine db to check which one matches.
        # Normalize $realMac pulled from the machinedb record as  
        # $virtualMac has been normalized in the macAddressForHost call above.
        #
        my $machine = ariba::Ops::Machine->new($host);
        for my $macAttribute ('macAddr', 'macAddrSecondary', 'macAddrTernary', 'macAddrQuadrary' ) {
            my $realMac = $machine->attribute($macAttribute);
            $realMac = ariba::Ops::NetworkUtils::formatMacAddress( $realMac );
            if (defined $realMac && $virtualMac eq $realMac) {
                return $host;
            }
        }
    }

    return undef;
}


=pod

=item * allRoles()

Get a list of all roles that are played by someone for this product.

=cut
sub allRoles
{
    my $self = shift;

    my $rolesManager = $self->rolesManager();

    return ($rolesManager->roles());
}

=pod

=item * rolesMatchingFilter()

Returns list of all roles that  has 'filter' matching in role-name for this product.
For eg. webserver input will match roles matching webserver

=cut
sub rolesMatchingFilter
{
    my ( $self, $filter )  = @_;

    return () unless ( $filter);
    
    my @all_roles = $self->allRoles();

    return () unless ( scalar(@all_roles) );

    my @ws_roles = grep { $_ =~ /$filter$/i } @all_roles;

    ( wantarray() ) ? return (@ws_roles) : return (\@ws_roles);
}
  
=pod

=item * allRolesInCluster()

Get a list of all roles that are played by someone for this product in the
given cluster

=cut
sub allRolesInCluster
{
    my $self = shift;
    my $cluster = shift;

    my $rolesManager = $self->rolesManager();

    return ($rolesManager->rolesInCluster($cluster));
}

=pod

=item * isARole()

Given a string, find out if it is a real role for this product.

=cut

sub isARole
{
    my $self = shift;
    my $role = shift;

    return $self->rolesManager()->isARole($role);
}

=pod

=item * isARoleInCluster()

Given a string, find out if it is a real role for this product in this
cluster.

=cut

sub isARoleInCluster
{
    my $self = shift;
    my $role = shift;
    my $cluster = shift;

    return $self->rolesManager->isARoleInCluster($role, $cluster);
}

=pod

=item * allHosts()

Get a list of all real hosts that play any role for this product.

=cut
sub allHosts
{
    my $self = shift;

    return $self->rolesManager()->hosts();
}

=pod

=item * allVirtualHosts()

Get a list of all virtual hosts that play any role for this product.

=cut
sub allVirtualHosts
{
    my $self = shift;

    return $self->rolesManager()->virtualHosts();
}

=pod

=item * allHostsInCluster()

Get a list of all real hosts that play any role for this product in 
the given cluster

=cut
sub allHostsInCluster
{
    my $self = shift;
    my $cluster = shift;

    return $self->rolesManager()->hostsInCluster($cluster);
}

=pod

=item * allVirtualHostsInCluster()

Get a list of all virtual hosts that play any role for this product in 
the given cluster

=cut
sub allVirtualHostsInCluster
{
    my $self = shift;
    my $cluster = shift;

    return $self->rolesManager()->virtualHostsInCluster($cluster);
}

=pod
=item * hasSecondaryCluster()
Returns true if product is set up with secondary cluster
=cut

sub hasSecondaryCluster {
    my $self = shift;

    return 1 if (grep /^secondary$/, $self->allClusters());
    return 0;
}

=pod

=item * allClusters()

Get a list of all clusters that are used by this product

=cut
sub allClusters
{
    my $self = shift;

    return $self->rolesManager()->clusters();
}

=pod

=item * currentCluster()

Get the current cluster for this product based on how it was launched.

=cut

sub currentCluster {
    my $self = shift;

    my $cluster = $self->{'cluster'};
    return ($cluster) if ($cluster);

    $cluster = ( -e "$self->{configDir}/ClusterName" ) ? getClusterName($self->configDir()) : $self->default("MetaData.ClusterName");

    if ($cluster =~ /^Unknown/) {
        $cluster = undef;
    }

    unless (defined($cluster)) {
        $cluster = $self->clusterForHost(ariba::Ops::NetworkUtils::hostname());
    }

    $self->{'cluster'} = $cluster;

    return $cluster;
}

=pod

=item * otherCluster()

Get the other cluster for this product based on the current cluster

=cut

sub otherCluster {
    my $self = shift;

    my @otherClusters = grep { $_ ne $self->currentCluster() } $self->allClusters();
    my $otherCluster = shift(@otherClusters); # Common use is there is only one other cluster

    return $otherCluster;
}

=pod

=item * clusterForHost()

Get the current cluster for this product for a given host. If there is
ambiguity in the cluster determination, this will return undef.

=cut
sub clusterForHost
{
    my $self = shift;
    my $host = shift;

    my $rolesManager = $self->rolesManager();

    my $cluster;
    my @clusters = $rolesManager->clustersForHost($host);

    # if we can unabgiuously determine hosts cluster, lock that in
    if (@clusters == 1) {
        $cluster = $clusters[0];
    } elsif (@clusters > 1) {
        die "ERROR ariba::rc::Product: could not determine cluster for " .
            "$host unmabigiously\n";
    }

    return $cluster;
}

=pod

=item * clusterForVirtualHost()

Get the current cluster for this product for a given host. If there is
ambiguity in the cluster determination, this will return undef.

=cut
sub clusterForVirtualHost
{
    my $self = shift;
    my $host = shift;

    my $rolesManager = $self->rolesManager();

    my $cluster;
    my @clusters = $rolesManager->clustersForVirtualHost($host);

    # if we can unabgiuously determine hosts cluster, lock that in
    if (@clusters == 1) {
        $cluster = $clusters[0];
    } elsif (@clusters > 1) {
        die "ERROR ariba::rc::Product: could not determine cluster for " .
            "$host unmabigiously\n";
    }

    return $cluster;
}

=pod

=item * recordClusterName(clusterName)

Assign a cluster to the current host. Every call to currentCluster after
this will return this assigned cluster name.

=cut

sub recordClusterName
{
    my $self = shift;
    my $clusterName = shift;

    my $clusterNameFile = $self->clusterNameFile();
    my $configDir = $self->configDir();

    # make config dir writable
    my $oldMode = (stat($configDir))[2];
    chmod(0755, $configDir);

    open(FL, "> $clusterNameFile") || return 0;
    print FL "$clusterName\n";
    close(FL);

    # restore old mode of config dir
    chmod($oldMode, $configDir);

    $self->setClusterName($clusterName);

    return 1;
}

=pod

=item * setClusterName(clusterName)

Assign a cluster to the current host. Only for the in memory instance.
=cut

sub setClusterName
{
    my $self = shift;
    my $clusterName = shift;

    $self->{'cluster'} = $clusterName;

    return 1;
}

=pod

=item * clearClusterName()

clear a previously recorded cluster name for the current host

=cut
sub clearClusterName 
{
    my $self = shift;

    my $clusterNameFile = $self->clusterNameFile();

    unlink($clusterNameFile) || return 0;

    $self->{'cluster'} = undef;

    return 1;
}

=pod

=item * hasBeenInstalled()

Uses a check against the cluster file to determine if a product build has been
installed yet or not.

=cut
sub hasBeenInstalled {
    my $self = shift;

    my $clusterNameFile = $self->clusterNameFile();

    if( -e $clusterNameFile ) {
        return(1);
    }

    return(0);
}

sub _decryptEncryptedParameters
{
    my $self = shift;
	my $returnEncrypted = $self->returnEncryptedValues();

    return if ($self->_encryptedParametersDecrypted());

    my $name = $self->name();
    my $service = $self->service();

    my $storeNamePrefix;

    if ( $self->customer() ) {
        $storeNamePrefix = "$name/$service/" . $self->customer() . ":";
    } else {
        $storeNamePrefix = "$name/$service:";
    }

    my $cipherStore;
    my $parameters = $self->{'parameters'};
    while (my ($key,$encKey) = (each(%{$self->{'encryptedParameters'}}),
                   each(%{$self->{'pbeEncryptedParameters'}})) ) {

        my $newKey    = $key;
        my $newValue;
        $newValue = $parameters->valueForKeyPath($encKey) if($returnEncrypted);
        my $storeName = $storeNamePrefix . $newKey;

        #
        # If password lib has been initialized, decrypt cipherblock
        # using master password. Also put the clear text value
        # in CipherStore for later use.
        #
        # If password lib is not initialized, try to get clear text
        # value from CipherStore, which might have been previosly
        # stored.
        #
        if (ariba::rc::Passwords::initialized() && ariba::rc::Passwords::service() eq $self->service()) {
            $newValue = ariba::rc::Passwords::decryptBruteForce($parameters->valueForKeyPath($encKey));
        }

		#
		# do not use the cipher store if the calling script sets
		# returnEncrypted, since the calling code will be expecting
		# values that are still encrypted.
		#
		elsif( !$returnEncrypted ) {

            unless($cipherStore) {
            eval "use ariba::rc::CipherStore"; 
            die "Eval Error: $@\n" if ($@);
            $cipherStore = ariba::rc::CipherStore->new($self->service());
            }

            my $valFromCipherStore = $cipherStore->valueForName($storeName);
			$newValue = $valFromCipherStore if($valFromCipherStore);
        }
        $parameters->setValueForKeyPath($newKey, $newValue);
    }
    $self->_setEncryptedParametersDecrypted(1);
}

sub _decryptEncryptedDefaults
{
    my $self = shift;
	my $returnEncrypted = $self->returnEncryptedValues();

    my $defaultsRef = \%{$self->{'defaults'}};
    my $defaultsRefPreserveCase = \%{$self->{'defaultsPreserveCase'}};

    return if ($self->_encryptedDefaultsDecrypted());


    my $name = $self->name();
    my $service = $self->service();

    my $storeNamePrefix;

    if ( $self->customer() ) {
        $storeNamePrefix = "$name/$service/" . $self->customer() . ":";
    } else {
        $storeNamePrefix = "$name/$service:";
    }

    my $cipherStore;
    while (my ($key,$encKey) = (each(%{$self->{'encryptedDefaults'}}),
                               each(%{$self->{'pbeEncryptedDefaults'}})) ) {

        my $newKey    = $key;
		my $newValue;
        $newValue = $defaultsRefPreserveCase->{$encKey} if($returnEncrypted);
        my $lcNewKey  = lc($newKey);

        my $storeName = $storeNamePrefix . $newKey;

        #
        # If password lib has been initialized, decrypt cipherblock
        # using master password. Also put the clear text value
        # in CipherStore for later use.
        #
        # If password lib is not initialized, try to get clear text
        # value from CipherStore, which might have been previosly
        # stored.
        #
        if (ariba::rc::Passwords::initialized() && ariba::rc::Passwords::service() eq $self->service()) {
            $newValue = ariba::rc::Passwords::decryptBruteForce( $defaultsRefPreserveCase->{$encKey} );
        }

		#
		# do not use the cipher store if the calling script sets
		# returnEncrypted, since the calling code will be expecting
		# values that are still encrypted.
		#
		elsif( !$returnEncrypted ) {
            unless($cipherStore) {
            eval "use ariba::rc::CipherStore"; 
            die "Eval Error: $@\n" if ($@);
            $cipherStore = ariba::rc::CipherStore->new($self->service());
            }

            my $valFromCipherStore = $cipherStore->valueForName($storeName);
			$newValue = $valFromCipherStore if($valFromCipherStore);
        }
        $defaultsRef->{$lcNewKey} = $newValue;
        $defaultsRefPreserveCase->{$newKey} = $newValue;
    }
    $self->_setEncryptedDefaultsDecrypted(1);
}

=pod

=item * defaults()

Get the whole DD.xml as an associative array.

=cut
sub defaults
{
    my $self = shift;

    $self->_faultInDefaults();
    if (defined($self->deploymentDefaults())) {
        $self->_decryptEncryptedDefaults();

        print "Defaults in product is ", join("\n",
            keys(%{$self->{'defaultsPreserveCase'}})), "\n" if ($debug);
        return (%{$self->{'defaultsPreserveCase'}});
    } elsif (defined($self->parametersTable())) {
        $self->_decryptEncryptedParameters();

        my %keyValues;
        for my $key ($self->{'parameters'}->listKeys()) {
            $keyValues{$key} = $self->{'parameters'}->valueForKeyPath($key);
        }
        return (%keyValues);
    }
}
=pod

=item * encryptedDefaultKeys()

Return an associative array of things that are encrypted in DD.xml or
P.table.

  Key in this associative array is the DD.xml element that will return
  the encrypted value.

  Value in this associative array is the DD.xml element that will return
  the clear text value

  For P.table case Key and Value are always identical.
=cut

sub encryptedDefaultKeys
{
    my $self = shift;
    my %encryptedKeys;

    $self->_faultInDefaults();
    if (defined($self->deploymentDefaults())) {
        while (my ($key,$encKey) = (each(%{$self->{'encryptedDefaults'}}),
                       each(%{$self->{'pbeEncryptedDefaults'}})) ) {
            $encryptedKeys{$encKey} = $key;
        }
    } elsif (defined($self->parametersTable())) {

        while (my ($key,$encKey) = (each(%{$self->{'encryptedParameters'}}),
                       each(%{$self->{'pbeEncryptedParameters'}})) ) {
            $encryptedKeys{$encKey} = $key;
        }
    }

    return %encryptedKeys;
}

=pod

=item * default('name')

Get a particular setting out of DD.xml.

=cut
sub default
{
    my $self = shift;
    my $key = shift;  # This is required and should be checked that it has a value.
    my $value;

    $self->_faultInDefaults();


    if (defined($self->deploymentDefaults())) {
        $key = lc($key);

        # only if requested an encrypted key
        if (defined($self->{'encryptedDefaults'}->{$key}) ||
            defined($self->{'pbeEncryptedDefaults'}->{$key}))  {
            $self->_decryptEncryptedDefaults();
        }

        $value = $self->{'defaults'}->{$key};
    } elsif (defined($self->parametersTable())) {
        if (defined($self->{'encryptedParameters'}->{$key}) ||
            defined($self->{'pbeEncryptedParameters'}->{$key}))  {
            $self->_decryptEncryptedParameters();
        }
        $value = $self->{'parameters'}->valueForKeyPath($key);
    }
    # We do nothing if neither the above matches.  This would basically be the same as a
    # simple 'return' with no args, except the following would try to return something based
    # on $value, which would not be defined in this case.  So verify there's a value to return.

    if (wantarray && ref($value) && (ref($value) eq 'ARRAY')) {
        return @{$value};
    } else {
        return ($value);
    }
}

=pod

=item * defaultKeysForPrefix('prefix')

Given a key prefix get all the keys in DD.xml that match the prefix.

=cut
sub defaultKeysForPrefix
{
    my $self = shift;
    my $prefix = shift;
    my $lowercaseIt;

    $self->_faultInDefaults();

    my $defaults = $self->{'defaultsPreserveCase'};
    my $parameters = $self->{'parameters'};
    my @keys;

    #
    # change 301261 specifically lowercased the matches, not sure
    # why, but maintain backward compatibility
    #
    if (defined($self->deploymentDefaults())) {
        @keys = keys(%$defaults);
        $lowercaseIt = 1;
    } elsif (defined($self->parametersTable())) {
        @keys = $parameters->listKeys();
        $lowercaseIt = 0;
    }

    my %matchedKeys;
    for my $key (@keys) {
        if ($key =~ m|^($prefix[^\.]*)\.|i) {
            my $match = $1;
            if ($lowercaseIt) {
                $match = lc($match);
            }
            $matchedKeys{$match} = $key;
        }
    }

    return (keys(%matchedKeys));
}

=pod

=item * distToUsers(role)

Which user will receive the distribution on the destination host.

=cut
sub distToUsers
{
    my $self = shift;
    my $role = shift;

    return $self->rolesManager()->usersToCopyToForRole($role);
}

=pod

=item * distToPaths(role)

Where should the distribution end up on the destination host.

=cut
sub distToPaths
{
    my $self = shift;
    my $role = shift;

    $self->rolesManager()->pathsToCopyToForRole($role);
}

=pod

=item * distFromDirs(role)

Get the list of directories that need to be distributed for a particular
build of this product.

=cut
sub distFromDirs
{
    my $self = shift;
    my $role = shift;

    $self->rolesManager()->dirsToCopyFromForRole($role);
}

=pod

=item * distProvidedBy(role)

Who provided the contents of distribution. Could be one of "customer" or
"build".

=cut
sub distProvidedBy
{
    my $self = shift;
    my $role = shift;

    $self->rolesManager()->dirsProvidedByForRole($role);
}

=pod

=item * xmlStringForNode('node')

Extract a subset of xml tree from DD.xml. Provide the parent node that needs
to be extracted, and it will return xml string for that node recursively.

=cut
sub xmlStringForNode
{
    my $self = shift;
    my $pattern = shift;

    $self->_faultInDefaults();

    return(ariba::util::XMLWrapper::createXMLString(
                    $self->{'defaultsPreserveCase'},
                    $pattern));
}

=item * xmlStringForNodeWithEmptyDefault('node')

Does xmlStringForNode('node') but returns empty string if undefined instead of undef.

=cut
sub xmlStringForNodeWithEmptyDefault
{
    my $self = shift;
    my $pattern = shift;

    return $self->xmlStringForNode($pattern) || "";
}

=pod

=item * woAppsConfig() appsConfig() woVersion()
instances() instancesInCluster()
instancesOnHostInCluster(host, cluster)
instancesOnHostLaunchedByRoleInCluster(host, role, cluster)
instancesVisibleViaRoleInCluster(role) 

Provide information on WO appname, number of instances, their port#, if they
are visible via front door or back door etc.

=cut

sub woAppsConfig
{
    my $self = shift;
        return $self->{woAppsConfig};
}

sub appsConfig
{
    my $self = shift;
        return $self->{appsConfig};
}

sub appNamesWithRecordDowntimeStatus
{
    my $self = shift;

    unless (%{$self->{'recordappnames'}}) {
        $self->_loadAppNamesWithRecordDowntimeStatus();
    }

    return (keys %{$self->{'recordappnames'}});
}

sub _loadAppNamesWithRecordDowntimeStatus
{
    my $self = shift;

    my %uniqueAppnamesHash = ();

    foreach my $instance ($self->appInstances()) {

        if (defined $instance->recordStatus() and $instance->recordStatus() eq "yes") {
            $uniqueAppnamesHash{$instance->appName()}++;
        }
    }

    $self->{'recordappnames'} = \%uniqueAppnamesHash;
}

sub _checkIfPropertyIsTrue {
    my $self = shift;
    my $property = shift;

    $self->_faultInDefaults();

    if ($self->default($property) && 
        ($self->default($property) eq "true" ||
         $self->default($property) eq "1")) {
        return 1;
    } else {
        return 0;
    }
}

sub isTrue {
    my $self = shift;
    my $property = shift;

    return $self->_checkIfPropertyIsTrue($property);
}

sub appInstances {
    my $self = shift;

    return $self->appInstancesInCluster($self->currentCluster());
}

sub woaInstances {
    my $self = shift;

    if (-t STDOUT) {
        warn "using deprecated method woaInstances() - use instances() instead.\n";
    }

    return $self->appInstances();
}

sub isLayout {
    my $self = shift;
    my $version = shift;

    return $self->appInstanceManager()->isLayout($version);
}

sub appInstancesInCluster {
    my ($self,$cluster) = @_;

    return @{ $self->appInstanceManager()->appInstancesInCluster($cluster) };
}

sub appInstancesVisibleViaRoleInCluster {
    my ($self,$role,$cluster) = @_;

    my @instances = ();

    $cluster = $self->currentCluster() unless($cluster);

    return @instances unless($cluster);

    for my $instance ($self->appInstancesInCluster($cluster)) {

        my $visibleVia = $instance->visibleVia() || next;

        if ( $role eq $visibleVia ) {
            push(@instances, $instance);
        }
    }

    return @instances;
}

sub appInstancesLaunchedByRoleInCluster {
    my ($self,$role,$cluster) = @_;

    my @instances = ();

    $cluster = $self->currentCluster() unless($cluster);

    return @instances unless($cluster);

    for my $instance ($self->appInstancesInCluster($cluster)) {

        my $launchedBy = $instance->launchedBy() || next;

        if ($role eq $launchedBy) {
            push(@instances, $instance);
        }
    }

    return @instances;
}

sub appInstancesLaunchedByRoleInClusterMatchingFilter {
    my ($self,$role,$cluster,$filterArrayRef) = @_;

    my @instances = $self->appInstancesLaunchedByRoleInCluster($role, $cluster); 
    return $self->appInstancesMatchingFilter(\@instances, $filterArrayRef);
}

sub appInstancesWithNameInCluster {
    my ($self,$name,$cluster) = @_;

    my @instances = ();

    $cluster = $self->currentCluster() unless($cluster);

    return @instances unless($cluster);

    for my $instance ($self->appInstancesInCluster($cluster)) {

        my $appName = $instance->appName() || next;

        if ($appName eq $name) {
            push(@instances, $instance);
        }
    }

    return @instances;
}

sub appInstancesInCommunity
{
    my ($self,$community) = @_;

    my @instances = ();

    for my $instance ($self->appInstances()) {

        my $appInstanceCommunity = $instance->community();

        if ( (!defined($community) || !$community ||
              $community eq 'default') &&
             !defined($appInstanceCommunity) ) {
            push(@instances, $instance);
            next;
        }

        if ( $community && $appInstanceCommunity &&
             $appInstanceCommunity eq $community ) {
            push(@instances, $instance);
            next;
        }
    }

    return @instances;
}

sub appInstancesOnHostInCluster
{
    my ($self,$host,$cluster) = @_;

    my @instances = ();

    $cluster = $self->clusterForHost($host) unless($cluster);

    return @instances unless($cluster);

    for my $instance ($self->appInstancesInCluster($cluster)) {

        my $onHost    = $instance->host();

        if ($host eq $onHost) {
            push(@instances, $instance);
        }
    }

    return @instances;
}

sub appInstancesOnHostLaunchedByRoleInCluster
{
    my ($self,$host,$role,$cluster) = @_;

    my @instances = ();

    $cluster = $self->clusterForHost($host) unless($cluster);

    return @instances unless($cluster);

    my $virtualHost = $self->virtualHostForHostInCluster($host, $cluster, $role);
    if ($virtualHost) {
        my $activeHost = $self->activeHostForVirtualHostInCluster($virtualHost, $cluster); 
        undef($virtualHost) unless ($activeHost eq $host);
    }

    for my $instance ($self->appInstancesInCluster($cluster)) {

        my $onHost    = $instance->host();
        my $onRole    = $instance->launchedBy();

        if (($host eq $onHost || $virtualHost && $virtualHost eq $onHost) && 
            $role eq $onRole) {
            push(@instances, $instance);
        }
    }

    return @instances;
}

sub appInstancesOnHostLaunchedByRoleInClusterMatchingFilter {
    my ($self,$host,$role,$cluster,$filterArrayRef) = @_;

    my @instances = $self->appInstancesOnHostLaunchedByRoleInCluster($host,$role,$cluster);

    return $self->appInstancesMatchingFilter(\@instances, $filterArrayRef);

}

=pod

=item * numCommunities()

Number of communites that the AppInstances are configured for.

=cut

sub numCommunities {
    my $self = shift;

    my $apm = $self->appInstanceManager();

    return $apm->numCommunities();
}

sub woVersion
{
    my $self = shift;
    my $woVersionFile = $self->configDir() . "/WoVersion.cfg";
    my $appleVer;

    if ( -f $woVersionFile ) {
        open(FL, "$woVersionFile") || return $appleVer;
        $appleVer = <FL>;
        close(FL);

        chomp($appleVer);
        $appleVer =~ s/\cM+//;
    }

    return $appleVer;
}

=pod

=item * nextRoot()

If the product uses WebObjects, the location of Apple directory it was built
with.

=cut
sub nextRoot
{
    my $self = shift;

    if (onNT()) {
        return $ENV{'NEXT_ROOT'};
    }

    my $appleRoot = "/opt/Apple";
    my $appleVer = $self->woVersion();
    if ( defined ($appleVer) ) {
        $appleRoot = "$appleRoot" . "." . "$appleVer";
    }

    return $appleRoot;
}

sub oraVersion
{
    my $self = shift;
    my $oraVersionFile = $self->configDir() . "/OraVersion.cfg";
    my $oraVer = "8.0.5";

    if ( -f $oraVersionFile ) {
        open(FL, "$oraVersionFile") || return $oraVer;
        $oraVer = <FL>;
        close(FL);

        chomp($oraVer);
        $oraVer =~ s/\cM+//;
    }

    return $oraVer;
}

=pod

=item * oracleHome()

If the product uses Oracle client libraries, the location of ORACLE directory 
it was built with.

=cut
sub oracleHome
{
    my $self = shift;
    my $oracleRoot;

    if (onNT()) {
        $oracleRoot = -d "d:/orant" ? "d:/orant" : "c:/orant";
    } else {
        $oracleRoot = -d "/usr/local/oracle" ? 
                "/usr/local/oracle" : "/opt/oracle";
    }

    my $oraVer = $self->oraVersion();
    if ( defined ($oraVer) ) {
        my $oracleVerRoot = "$oracleRoot" . "." . "$oraVer";
        if ( -d $oracleVerRoot) {
        $oracleRoot = $oracleVerRoot;
        }
    }

    return $oracleRoot;
}

=pod

=item * isActiveActive()

Returns true if this product instance is an active/active product.

=cut
sub isActiveActive {
    my $self = shift;

    return ariba::rc::Globals::isActiveActiveProduct($self->name());
}

sub jdbcVersion
{
    my $self = shift;
    my $jdbcVersionFile = $self->configDir() . "/JDBCVersion.cfg";
    my $jdbcVer;

    if ( -f $jdbcVersionFile ) {
        open(FL, "$jdbcVersionFile") || return $jdbcVer;
        $jdbcVer = <FL>;
        close(FL);

        chomp($jdbcVer);
        $jdbcVer =~ s/\cM+//;
    }

    return $jdbcVer;
}

sub qualStatusFile {
    my $self = shift;
    return $self->configDir() . "/QualStatus";
}

sub setQualStatus {
    my $self = shift;
    my $status = shift;

    my $statusFile = $self->qualStatusFile();
    my $statusDir = dirname($statusFile);

    # make config dir writable
    my $oldMode = (stat($statusDir))[2];
    chmod(0755, $statusDir);

    my $tmpFile = "$statusFile$$";
    open(FL, ">$tmpFile") or die "Can't open qual status temp file $tmpFile: $!";
    chomp($status);
    print FL "$status\n" or die "Couldn't write qual status: $!";
    close(FL) or die "Couldn't close qual status temp file: $!";

    rename($tmpFile, $statusFile) or die "Couldn't rename $tmpFile to $statusFile: $!";

    # restore old mode of config dir
    chmod($oldMode, $statusDir);

    return 1;
}

sub qualStatus {
    my $self = shift;
    my $qualStatus;

    my $qualStatusFile = $self->qualStatusFile();

    if ( -f $qualStatusFile ) {
        open(FL, "$qualStatusFile") || return $qualStatus;
        $qualStatus = <FL>;
        close(FL);

        chomp($qualStatus);
        $qualStatus =~ s/\cM+//;
    }

    return $qualStatus;
}

sub javaVersion
{
    my $self = shift;
    my $javaVersionFile = $self->configDir() . "/JavaVersion.cfg";
    my $javaVer;

    if ( -f $javaVersionFile ) {
        open(FL, "$javaVersionFile") || return $javaVer;
        $javaVer = <FL>;
        close(FL);

        chomp($javaVer);
        $javaVer =~ s/\cM+//;
    }

    return $javaVer;
}

sub javaHome
{
    my $self = shift;
    my $appName = shift; 

    my $javaRoot = undef;

    my $javaVer = $self->javaVersion();

    if ( defined ($javaVer) ) {
        my $javaVerRoot = "/usr/j2sdk$javaVer";
        $javaRoot = $javaVerRoot;
    }

    my $altJdkRoot = $ENV{'JDKROOT'};
    if (defined($altJdkRoot) && $altJdkRoot) {
        $javaRoot = $altJdkRoot;
    }

    # JDKROOT is set always in Common.pm:setEnvironment and overrides.
    # Can't move/unset JDKROOT override since some unknown place might be using it.
    # So this needs to be down here to have the highest precedency. 
    $javaVer = $appName && $self->default("Ops.JVM.$appName.Version") || $self->default('Ops.JVM.Version');
    $javaRoot = "/usr/j2sdk$javaVer" if ($javaVer);

    return $javaRoot;
}

sub tomcatVersion
{
    my $self = shift;
    my $tomcatVersionFile = $self->configDir() . "/TomcatVersion.cfg";
    my $tomcatVer;

    if ( -f $tomcatVersionFile ) {
        open(FL, "$tomcatVersionFile") || return $tomcatVer;
        $tomcatVer = <FL>;
        close(FL);

        chomp($tomcatVer);
        $tomcatVer =~ s/\cM+//;
    }

    return $tomcatVer;
}

sub tomcatHome
{
    my $self = shift;
    my $tomcatRoot = "/opt/tomcat";

    my $tomcatVer = $self->tomcatVersion();

    if ( defined ($tomcatVer) ) {
        my $tomcatVerRoot = "/opt/tomcat.$tomcatVer";

        if ( -d $tomcatVerRoot) {
            $tomcatRoot = $tomcatVerRoot;
        }
    }

    return $tomcatRoot;
}

sub cxmlVersion
{
    my $self = shift;

    my $cxmlVersionFile = $self->configDir() . "/CxmlVersion.cfg";
    my $cxmlVer;

    if ( -f $cxmlVersionFile ) {
        open(FL, "$cxmlVersionFile") || return $cxmlVer;
        $cxmlVer = <FL>;
        close(FL);

        chomp($cxmlVer);
        $cxmlVer =~ s/\cM+//;
    }

    return $cxmlVer;
}

sub runtime_instrumentation_config
{
    my $self = shift;

    ### Get the instrumented config of the product
    my $instrumented_config = undef;
    if ( $self->parametersTable() )
    {
        $instrumented_config = $self->default("System.Admin.CodeCoverage.RuntimeInstrumentationConfigFile");
    } elsif (  $self->deploymentDefaults() )
    {
        $instrumented_config = $self->default("RuntimeInstrumentationConfig");
    }

    ### Return if the config file not found or not able to read
    ( -e $instrumented_config && -f _ && -r _ ) ? return $instrumented_config : return undef;
}

sub runtime_instrumented_instances
{
    my $self = shift;

    ### Get instrumentation config file of the product
    my $instrumented_config = $self->runtime_instrumentation_config();
    return undef unless ( $instrumented_config );

    my %instrumented_instances = ();
    my $csv = Text::CSV->new( {sep_char => ','} );
    open(my $instr_fh, '<', $instrumented_config);
    while (my $line = <$instr_fh>)
    {
        chomp $line;
        if ($csv->parse($line))
        {
            my @fields = $csv->fields();
            $instrumented_instances{$fields[0]} = 1 if ( $fields[0] );
        }
    }
    close($instr_fh);

    return (\%instrumented_instances);
}

### Returns 1 (true), 0 (false)
sub is_instance_instrumented
{
    my ($self, $instance_name) = @_;

    my $runtime_instrumented_instances = $self->runtime_instrumented_instances();
    return 0 unless ( $runtime_instrumented_instances );

    defined ( $runtime_instrumented_instances->{$instance_name} ) ?  return 1 : return 0;
}

sub __setProductNamePassedInOrFromDisk
{
    my $self = shift;
    my $prodname = shift;

    if (defined $prodname && $prodname ne "Unknown-Product") {
        $self->{prodname} = $prodname;
    } else {
        my $configDir= $self->_computeDeployRootFromNothing() . "/" .
                        $self->_configSubDirectory();
        $self->{prodname} = getProductName($configDir);
    }
}

sub __setServiceNamePassedInOrFromDisk
{
    my $self = shift;
    my $service = shift;

    if (defined $service && $service ne "Unknown-Service") {
        $self->{service} = $service;
    } else {
        my $configDir= $self->_computeDeployRootFromNothing() . "/" .
                        $self->_configSubDirectory();
        $self->{service} = getServiceName($configDir) || $self->default("MetaData.ServiceName");
    }
}

sub __setBuildNamePassedInOrFromDisk
{
    my $self = shift;
    my $buildname = shift;
    
    if (defined $buildname && $buildname ne "Unknown-Build") {
        print "$self->just read buildname from passed in = $buildname\n" if $debug;
        $self->{buildName} = $buildname;
    } elsif ( $self->{configDir} ) {
        print "$self->just read buildname from disk via self->configDir==",$self->{configDir},"\n" if $debug;
        $self->{buildName} = getBuildName($self->{configDir});
    } else {

        my $configDir= $self->_computeDeployRootFromNothing() . "/" .
                        $self->_configSubDirectory();
        $self->{buildName} = getBuildName($configDir);
        print "$self->JUST READ BUILDNAME FROM DISK from $configDir set to ",$self->{buildName},"\n" if $debug;
    }
}

return 1;


__END__

=pod

=head1 AUTHOR

Manish Dubey <mdubey@ariba.com>
Dan Sully <dsully@ariba.com>

=head1 SEE ALSO

    ariba::rc::InstalledProduct 

    ariba::rc::ArchivedProduct

    ariba::rc::PersonalProduct

=cut
