# $Id: //ariba/services/tools/lib/perl/ariba/rc/Globals.pm#183 $
#
# A module that defines global variables for use by all products
#
########## Please update //ariba/services/config/globals/services.json when updating service configs ###################
########## Please update //ariba/services/config/globals/products.json when updating product configs ###################
########## Both of these json files get installed via CFEngine push under /usr/local/ariba/globals
#
package ariba::rc::Globals;
use File::Basename;
use ariba::rc::ServicesCfg;
use ariba::rc::ProductsCfg;
use strict;

#
# Global path variables that govern the structure of build/deploy wod
#
use constant RCUSER => "rc";
use constant USERPREFIX => "svc";
use constant HOMEPREFIX => "/home";
use constant COPYSRC => "copysrc";
use constant SRCDIRROOT => HOMEPREFIX . "/" . RCUSER . "/src";
use constant OBJDIRROOT => HOMEPREFIX . "/" . RCUSER . "/objs";

use constant SOURCES => "sources"; # DEAD?
use constant BUILDS => "builds";
use constant DEPLOYMENTS => "deployments";

use constant PERSONALSERVICEPREFIX => "personal_";

use constant PASSWORDDIR => "/usr/local/ariba/etc/passwords";


# If this file is present in the root dir of an archive build it means it
# is either in progress or did not finish cleanly
use constant INPROGRESSMARKER => ".in-progress";
use constant BROKENARCHIVEMARKER => ".broken-archive";

use constant ARCHIVEBUILDFINISHTIME => ".finish-time";

our $GLOBALDIR = "/usr/local/ariba/globals";

#
# NT needs drive specification for paths
#
my ($localDrive, $cifsDrive, $platform);

my $servicescfg; # Use accessor sub and not this field directly
my $productscfg; # Use accessor sub and not this field directly
my $servicescfgfile;
my $productscfgfile;

# Input 1: Inject a string representing a fully qualified path to a config file as the backing store for ServicesCfg
# If this is unset or never called, then the ServicesCfg will apply a hueristic to locate the config file
sub setServicesCfgFile {
    $servicescfgfile = shift;
    $servicescfg = undef; # Reset
}

sub getServicesCfgFile {
    return $servicescfgfile;
}

sub getServicesCfg {
    unless ($servicescfg) {
        $servicescfg = ariba::rc::ServicesCfg->new($servicescfgfile);
    }
    return $servicescfg;
}

# Input 1: Inject a string representing a fully qualified path to a config file as the backing store for ProductsCfg
# If this is unset or never called, then the ProductsCfg will apply a hueristic to locate the config file
sub setProductsCfgFile {
    $productscfgfile = shift;
    $productscfg = undef; # Reset
}

sub getProductsCfgFile {
    return $productscfgfile;
}

sub getProductsCfg {
    unless ($productscfg) {
        $productscfg = ariba::rc::ProductsCfg->new($productscfgfile);
    }
    return $productscfg;
}

sub servicesForDatacenter {
    my $datacenter = shift;

    my $sc = getServicesCfg();
    return $sc->servicesForDatacenter($datacenter);
}

# This expects a list of many datacenters.  It calls servicesForDatacenter() to process each single datacenter, so
# just call it directly if you have only one to process.
sub allServicesForDatacenters {
  my @dataCenters = @_;
  my @services;
  foreach my $dc (@dataCenters) {
    push @services, servicesForDatacenter ($dc);
  }
  return @services;
}

#
# on NT the directory that we checkout to is mounted as H:
# the directory we push out to is C:
#
if ($^O =~ /win32/i) {
    $localDrive = "C:";
    $cifsDrive = "Y:";
    $platform = "nt";
} else {
    $localDrive = "";
    $cifsDrive = "";
    $platform = "unix";
}

sub personalServiceType { return $ENV{'ARIBA_SERVICE_TYPE'}; }

sub setPersonalServiceType {
    my $type = shift;
    $ENV{'ARIBA_SERVICE_TYPE'} = $type if $type;
}

sub isPersonalService {
     my $service = shift;

     return 0 if ( !$service );

     my $prefix = personalServicePrefix();

     return ( $service =~ /^$prefix/ );
}

sub personalServicePrefix {
     return PERSONALSERVICEPREFIX;
}

sub allServices
{
    my $sc = getServicesCfg();
    return $sc->allServices();
}

sub isServiceValid
{
    my $service = shift;
    my $sc      = getServicesCfg();
    return $sc->isServiceValid($service);
}

sub allDatacenters
{
    my $sc = getServicesCfg();
    return $sc->allDatacenters();
}

sub devlabServices {
    my $sc = getServicesCfg();
    return sort($sc->devlabServices());
}

sub allProducts
{
    return ( allSharedServiceProducts(), allASPProducts() );
}

sub fancyNameForProductName
{
    my $product = shift;

    my $pc = getProductsCfg();
    return $pc->fancyNameForProduct($product);
}

sub allUsers
{
    my @services = @_;

    unless (@services) {
        @services = allServices();
    }

    my %allUsersHash;

    for my $product (allProducts()) {
        for my $service (@services) {
            my $deploymentUser = deploymentUser($product, $service);
            my $copyUser = copyUser($product, $service);

            $allUsersHash{$deploymentUser} = 1;
            $allUsersHash{$copyUser} = 1;
        }
    }

    return (sort(keys(%allUsersHash)));
}

sub allASPProducts 
{
    return aspProducts();
}

#
# Old prods use different user accounts for each product, while new products
# share a single account, just moving products between these arrays, should
# allow migration of products from using different accounts to shared
# account.
#

sub oldSharedServiceProducts {
    my $pc = getProductsCfg();
    return $pc->oldSharedServiceProducts();
}

sub newSharedServiceProducts {
    my $pc = getProductsCfg();
    return $pc->newSharedServiceProducts();
}

# these are SharedService products (one per service)
sub migrateProducts {
    my $pc = getProductsCfg();
    return $pc->migrateProducts();
}

# these are ASP products (many per service, need customer name)
sub aspProducts {
    my $pc = getProductsCfg();
    return $pc->aspProducts();
}

sub allSharedServiceProducts 
{
    my @prods;

    push(@prods, oldSharedServiceProducts());
    push(@prods, newSharedServiceProducts());
    return @prods;
}

sub sharedServiceSourcingProducts { 
    my $pc = getProductsCfg();
    return $pc->sharedServiceSourcingProducts();
}

sub sharedServiceBuyerProducts { 
    my $pc = getProductsCfg();
    return $pc->sharedServiceBuyerProducts();
}

sub sharedServicePlatformProducts { 
    my $pc = getProductsCfg();
    return $pc->sharedServicePlatformProducts();
}

sub networkProducts { 
    my $pc = getProductsCfg();
    return $pc->networkProducts();
}

sub rollingUpgradePreferredProducts { 
    my $pc = getProductsCfg();
    return $pc->rollingUpgradePreferredProducts();
}

sub rollingUpgradableProducts { 
    my $pc = getProductsCfg();
    return $pc->rollingUpgradableProducts();
}

sub fastDeploymentPreferredProducts { 
    my $pc = getProductsCfg();
    return $pc->fastDeploymentPreferredProducts();
}

sub hadoopProducts { 
    my $pc = getProductsCfg();
    return $pc->hadoopProducts();
}

sub archesProducts { 
    my $pc = getProductsCfg();
    return $pc->archesProducts();
}

sub activeActiveProducts { 
    my $pc = getProductsCfg();
    return $pc->activeActiveProducts();
}

sub webServerProducts { 
    my $pc = getProductsCfg();
    return $pc->webServerProducts();
}

sub isASPProduct {
    my $productName = shift;

    return ( grep($_ eq $productName, aspProducts()) );
}

sub isSharedServiceProduct {
    my $productName = shift;

    return ! isASPProduct($productName);
}

sub isActiveActiveProduct { 
    my $product = shift; 

    return grep { $product eq $_ } activeActiveProducts();  
}

# Confirm this is used post push on service hosts only
# The dev build and deploy env may not have a single "root"
# Return filesystem path like:
# robot with ARIBA_ARCHIVEDEPLOYMENT_AS_INSTALL: 
#     /home/$ARIBA_ARCHIVE_USER_<PRODUCT>/archive/deployments
#     /home/$ARIBA_ARCHIVEDDEPLOYMENTS_USER_<PRODUCT>/archive/deployments
#     /home/rc/archive/deployments
# "NEW" products: /home/svc/<service>/<product>
# ASP products: /home/svc/<product><service>/<customer>
# other: /home/<product><service>/
sub rootDir
{
    my ($product, $service, $customer) = @_;

    if ( isPersonalService($service) && $ENV{'ARIBA_ARCHIVEDEPLOYMENT_AS_INSTALL'}) {
        my $dir = archiveDeployments($product, $service, $customer);
        return $dir;

    } elsif ( $product eq 'stratus' ) {
        # for now, this has to be installed alongside 'mon', as both
        # will run parallely until further notice. So this must be installed
        # under mon<service> user, in subdir
        return "$localDrive" . HOMEPREFIX . "/mon${service}/$product";

    } elsif (grep(/^$product$/, newSharedServiceProducts())) {
        return "$localDrive" . HOMEPREFIX . "/". USERPREFIX . "$service/$product";

    } elsif ($service =~ /^qa|dev|load$/ and grep(/^$product$/, migrateProducts())) {
        return "$localDrive" . HOMEPREFIX . "/". USERPREFIX . "$service/$product";

    } elsif (grep(/^$product$/, aspProducts())) {
        my $dir = "$localDrive" . HOMEPREFIX . "/" . "$product$service";
        $dir .= "/$customer" if $customer;
        return $dir;
    } else {
        return "$localDrive" . HOMEPREFIX . "/". "$product$service";
    }
}

# Returns a filesystem path to /home/rc/src/<product>_<branch>
# This appears to be fallback case for locating src as a result of a build.
# Fortunately, the ARIBA_SOURCE_ROOT is considered as an override, which
# allows us to locate src in directories not under /home
sub srcDir
{
    my ($product, $branch) = @_;

    return "$cifsDrive" . SRCDIRROOT . "/${product}_${branch}";
}

# Returns a filesystem path to /home/rc/objs/<product>_<branch>
# This appears to be fallback case for locating objs as a result of a build.
# Fortunately, the ARIBA_BUILD_ROOT is considered as an override, which
# allows us to locate src in directories not under /home
sub objDir
{
    my ($product, $branch) = @_;

    return "$cifsDrive" . OBJDIRROOT . "/${product}_${branch}";
}

sub stemAndBuildNumberFromBuildName 
{
    my $buildName = shift;

    my $pos = rindex($buildName, "-");
    my $stem = substr($buildName, 0, $pos);
    my $number = substr($buildName, $pos + 1);

    return ($stem, $number);
}

sub buildNamesFromAspDeploymentBuildName { 
    my $aspDeploymentBuildName = shift; 
    my $customerBuildName; 
    my $baseBuildName; 

    if ($aspDeploymentBuildName =~ /^([\w\-]+-\d+)(\w+\d+)$/) { 
        $customerBuildName = $1; 
        $baseBuildName = $2; 
    } 
    
    return ($customerBuildName, $baseBuildName); 
} 

sub versionNumberFromBranchName
{
    my ($branch) = shift;

    #
    # Handle branch specification of type :
    # //ariba -> ariba
    # //ariba/.../build/<version>/<product> -> version
    # //ariba/.../<version> -> version
    # eg
    # //ariba/network/release/AN/4.5 -> 4.5
    # //ariba/network/branch/AN/hummingbird -> hummingbird
    # //ariba/sandbox/build/cs.eagle/s4 -> cs.eagle
    # //ariba/buyer/build/jupiter -> jupiter
    #
    my $version = File::Basename::basename($branch);

    my $version2 = File::Basename::basename(File::Basename::dirname(File::Basename::dirname($branch)));
    if ($version2 =~ /^build$/i) {
        # if this is of the form //ariba/sandbox/build/foo/product, foo is the version
        $version = File::Basename::basename(File::Basename::dirname($branch));
    }

    return $version;
}

sub aspDeploymentBuildName {
    my ($baseBuildName, $customerBuildName) = @_;

    $baseBuildName =~ s/-//g;
    return( $customerBuildName . $baseBuildName );
}

sub aspCustomerModsRootForProduct
{
    my ($product, $customer) = @_;

    my $root = "//ariba/services/$product/customers/$customer";

    return $root;
}

sub getLogicalNameForBranch
{
    my ($branch) = @_;

    my $name = versionNumberFromBranchName($branch);
    $name = "main" if isMainline($name);
    return $name;
}

sub getBuildInfoFileLocation 
{
    my ($archive) = @_;
    
    my $buildInfoFile = "$archive/image/ariba/resource/en_US/strings/BuildInfo.csv";
    unless (-f $buildInfoFile) {
        $buildInfoFile = "$archive/base/ariba/resource/en_US/strings/BuildInfo.csv";
    }

    return $buildInfoFile;
}

sub isMainline
{
    my ($version) = @_;

    return $version eq "ariba" || $version eq "main";
}

sub currentLink
{
    my ($product, $branch) = @_;

    my $current = "current";
    my $version = versionNumberFromBranchName($branch);

    if (!isMainline($version)) {
    $current .= "-$version";
    }

    return $current;
}

sub rcBuildClient
{
    my ($product, $branch, $hostname) = @_;

    my $clientName = "Release_" . uc($product);
    my $version = versionNumberFromBranchName($branch);

    if (!isMainline($version)) {
        $clientName .= "_$version";
    }
    
    if ($branch =~ /sandbox/) {
        $clientName .= "_sb";
    }
    
    my $useh = $ENV{'ARIBA_USEHOST_IN_BUILDSERVER_P4CLIENT'};
    if ($useh && $useh eq "true") {
        my $host = `hostname -s`;
        chomp ($host);
        $clientName .= "_$host";
    }

    my $ctx = $ENV{'ARIBA_BUILDSERVER_P4CLIENT_CONTEXT'};
    if ($ctx) {
        $clientName .= "_$ctx";
    }

    $clientName .= "_" . uc($platform);

    return $clientName;
}

sub archiveBuildFinishTime {
    my $product = shift;
    my $buildname = shift;

    my $stamp = archiveBuilds($product) . '/' .
        $buildname . '/' .  archiveBuildFinishTimeStamp();

    unless (-f $stamp ) {
        return;
    }

    open(STAMP, $stamp) || do {
        print "'$stamp' does not exist: $!";
        return;
    };
    my $time = <STAMP>;
    close(STAMP);

    chomp($time);

    return $time;
}

# This is a fallback resource that can be overridden
# Return filesystem path like:
# /home/$ARIBA_ARCHIVE_USER_<PRODUCT>/archive
# /home/<forcedUser>/archive
# /home/rc/archive
sub _archiveRoot {
    my $product = shift;
    my $forcedUser = shift;

    my $envOverride = 'ARIBA_ARCHIVE_USER_' . uc($product);

    my $user = $ENV{$envOverride} || $forcedUser || RCUSER;

    return  HOMEPREFIX . "/" . $user . "/archive";
}

# Return filesystem path like:
# see archiveDeployments
# see copySrcDir
sub deploymentsRepository
{
    my ($product, $service, $customer) = @_;

    my $dir =  archiveDeployments($product, $service, $customer);

    if (! -d $dir) {
        $dir = copySrcDir($product,$service,$customer);
    }
    return $dir;
}

#
# deprecated: use deploymentsRepository
#
sub buildRepository
{
    my ($product, $service, $customer) = @_;

    return deploymentsRepository($product, $service, $customer);
}

# Return filesystem path like:
# $ARIBALOCAL__ARCHIVEDEPLOYMENTS_LOCATION/<service>/<product>/<customer>
# $ARIBA_ARCHIVEDEPLOYMENTS_LOCATION/<service>/<product>/<customer>
# /home/$ARIBA_ARCHIVE_USER_<PRODUCT>/archive/deployments/<service>/<product>/<customer>
# /home/$ARIBA_ARCHIVEDDEPLOYMENTS_USER_<PRODUCT>/archive/deployments/<service>/<product>/<customer>
# /home/rc/archive/deployments/<service>/<product>/<customer>
# Input: pubonly optional param that when non-zero means to not consider any local archive area (just the public area)
sub archiveDeployments
{
    my ($product, $service, $customer, $pubonly) = @_;

    my $dir;

    unless( $pubonly ) {
        my $trylocal = $ENV{'LOCAL_ARCHIVE'};
        if ($trylocal && $trylocal eq "true") {
            $dir = $ENV{'ARIBA_LOCAL_ARCHIVEDEPLOYMENTS_LOCATION'};
            if ($dir) {
                print "DEBUG:  overriding local archiveDeployments location for $product to be $dir\n";
            }
        }
    }

    if (! defined $dir) {
        $dir = $ENV{ 'ARIBA_ARCHIVEDEPLOYMENTS_LOCATION_' . uc( $product ) };
        if ($dir) {
            print "DEBUG:  overriding archiveDeployments location for $product to be $dir\n";
        }
        else {
            my $envOverrideUser = $ENV{'ARIBA_ARCHIVEDEPLOYMENTS_USER_' . uc($product)};

            if ( $envOverrideUser ) {
                $dir = _archiveRoot($product, $envOverrideUser) . "/" . DEPLOYMENTS;
            } else {
                $dir =  "$cifsDrive" . _archiveRoot($product) . "/". DEPLOYMENTS;
            }
        }
    }

    $dir .= "/$service" if $service;
    $dir .= "/$product" if $product;

    $dir .= "/$customer" if $customer;

    return $dir;
}

sub setArchiveBuildOverrideForProductName {
    my $product = shift;
    my $path = shift;

    $ENV{'ARIBA_ARCHIVEBUILDS_LOCATION_' . uc($product)} = $path;
}

# Return filesystem path like:
# $ARIBA_ARCHIVEBUILDS_LOCATION_<PRODUCT>
sub archiveBuildOverrideForProduct
{
    my ($product) = @_;

    return $ENV{'ARIBA_ARCHIVEBUILDS_LOCATION_' . uc($product)};
}

# Return filesystem path like:
# $ARIBA_LOCAL_ARCHIVEBUILDS_LOCATION
# $ARIBA_ARCHIVEBUILDS_LOCATION_<PRODUCT>
# /home/$ARIBA_ARCHIVE_USER_<PRODUCT>/archive/builds/<product>
# /home/$ARIBA_ARCHIVE_USER_<PRODUCT>/archive/builds/<product>/customers/<customer>
# /home/rc/archive/builds/<product>
#
sub archiveBuilds
{
    my ($product) = @_;
    my $dir;

    my $trylocal = $ENV{'LOCAL_ARCHIVE'};
    if ($trylocal && $trylocal eq "true") {
        $dir = $ENV{'ARIBA_LOCAL_ARCHIVEBUILDS_LOCATION'};
        if ($dir) {
            print "DEBUG:  overriding local archiveBuilds location for $product to be $dir\n";
            return $dir;
        }
    }

    my $envOverride = archiveBuildOverrideForProduct($product);

    if ( $envOverride ) {
        $dir = $envOverride;
        print "DEBUG:  overriding archiveBuilds loc for $product to be $dir\n";
    }
    else {
        $dir = "$cifsDrive" . _archiveRoot($product) . "/". BUILDS;

        if($product =~ /([A-Za-z0-9]+)_(.*)/) {
            # an underscore in product indicates an ASP product_customer
            $product = "$1/customers/$2";
        }

        $dir .= "/$product" if $product;
    }

    return $dir;
}

# Appears to be DEAD (archive-build used to call it, but no longer)
# Note there is no /home/rc/archive/sources
# Return a filesystem path like:
# /home/$ARIBA_ARCHIVE_USER_<PRODUCT>/archive/sources/<product>
# /home/<forcedUser>/archive/sources/<product>
# /home/rc/archive/sources/<product>
sub archiveSources
{
    my ($product) = @_;

    my $dir =  "$cifsDrive" . _archiveRoot($product) . "/". SOURCES;

    $dir .= "/$product" if $product;

    return $dir;
}

sub passwordFile
{
    my ($service) = @_;

    if ( $ENV{'ARIBA_OVERRIDE_PASSWORDDIR'} ) {
        return  $ENV{'ARIBA_OVERRIDE_PASSWORDDIR'} . "/$service";

    } else {
        return PASSWORDDIR . "/$service";
    }
}

sub deploymentUser
{
    my ($product, $service) = @_;

    if ( isPersonalService($service) ) {
        return $ENV{'USER'};
    } elsif (grep(/^$product$/, newSharedServiceProducts())) {
        return USERPREFIX . "$service";
    } elsif ($service =~ /^qa|dev|load$/ and grep(/^$product$/, migrateProducts())) {
        return USERPREFIX . "$service";
    } elsif ( $product eq 'stratus') {
        return "mon${service}";
    } else {
        return "$product$service";
    }
}

sub copyUser
{
    my ($product, $service) = @_;

    return RCUSER;
}

#
# Return a filesystem path like "/home/rc/copysrc/<product><service><customer>"
# Notice that there are no file separator characters between <product> and <service> and <customer>
# Notice that there are no files or directories under /home/rc/copysrc so:
#  a) this method never gets called
#  b) this area is only populated on copyhost (non dev) machine
#
sub copySrcDir
{
    my ($product, $service, $customer) = @_;

    my $copySrcDir = "$localDrive" . HOMEPREFIX . "/" . RCUSER . "/" . COPYSRC . "/";

    $copySrcDir .= "$product" if $product;
    $copySrcDir .= "$service" if $service;

    $copySrcDir .= "/$customer" if $customer;

    return $copySrcDir;
}

sub servicesWithNonSharedFileSystem
{
    my $sc = getServicesCfg();
    return $sc->servicesWithNonSharedFileSystem();
}

sub serviceUsesSharedFileSystem
{
    my ($service) = @_;

    my $sc = getServicesCfg();
    return $sc->serviceUsesSharedFileSystem($service);
}

sub inProgressMarker {
    return INPROGRESSMARKER;
}

sub archiveBuildFinishTimeStamp {
    return ARCHIVEBUILDFINISHTIME;
}

sub brokenArchiveMarker {
    return BROKENARCHIVEMARKER;
}

my @qualRoles = ('testserver', 'seleniumrc');
sub qualRoles {
    return @qualRoles;
}

#
#sub main
#{
#    my $product = "dt-platform";
#    my $service = "dev";
#    my $branch = "//ariba/platform/deliveries/dt/2.0";
#    my $ver = "2.0";
#
#    print "user list: ", join(", ", allUsers(@ARGV)), "\n";
#    print "root dir is : ", rootDir($product, $service), "\n";
#    print "build client is : ", rcBuildClient($product, $ver), "\n";
#    print "build src dir is : ", srcDir($product, $ver), "\n";
#    print "build obj dir is : ", objDir($product, $ver), "\n";
#    print "archive-build dir is : ", archiveBuilds($product), "\n";
#    print "archive-deployment dir is : ", archiveDeployments($product, $service), "\n";
#   print "copysrc command is : scp blah ", copyUser($product, $service), "\@host:", copySrcDir($product, $service), "\n";
#   print "current link = ", currentLink($product, $branch), "\n";
#   print "rc client = ", rcBuildClient($product, $branch), "\n";
#}
#
#main();
#

1;
