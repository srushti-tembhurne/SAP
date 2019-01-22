package ariba::rc::AppInstanceManager;

# $Id: //ariba/services/tools/lib/perl/ariba/rc/AppInstanceManager.pm#88 $

use strict;

use ariba::rc::AbstractAppInstance;
use ariba::rc::JavaAppInstance;
use ariba::rc::TomcatAppInstance;
use ariba::rc::WebLogicAppInstance;
use ariba::rc::WOFAppInstance;
use ariba::rc::OpenOfficeAppInstance;
use ariba::rc::SeleniumAppInstance;
use ariba::rc::PHPAppInstance;
use ariba::rc::PerlAppInstance;
use ariba::rc::SpringbootAppInstance;
use ariba::rc::OpenCpuAppInstance;
use ariba::rc::RedisAppInstance;
use ariba::rc::HadoopAppInstance;
use ariba::rc::Utils;
use ariba::rc::AUCSolrAppInstance;
use ariba::rc::AUCCommunityAppInstance;
use ariba::Ops::Machine;
use ariba::Ops::NetworkUtils;
use Time::HiRes qw( gettimeofday tv_interval );
use POSIX qw( clock );


my %appInstanceManagersCache = ();
my $DEBUG = 0;

my $v5HeapDefault = 'Xmx64M';
my $maxPermSizeDefault = 64; # MB
my $mb            = 1048576;
my $gb            = 1073741824;
my $jvmMemOverhead = 70 * $mb;

my $bucketHash;

=pod

=head1 NAME

ariba::rc::AppInstanceManager

=head1 VERSION

$Id: //ariba/services/tools/lib/perl/ariba/rc/AppInstanceManager.pm#88 $

=head1 SYNOPSIS

AppInstanceManager is used by Product.pm. Do not hook into this class directly.

    use ariba::rc::AppInstanceManager;

    my $apm = ariba::rc::AppInstanceManager->newWithProduct($product);
    my $instancesRef = $apm->appInstances();

    for my $app (@$instancesRef) {
    print "appName: [" . $app->appName() . "]\n";
    }

=head1 DESCRIPTION

This class encapsulates the concept of Application Instance objects,
as derived from a product's appflags.cfg and appcounts.cfg files.

AppInstance objects should be created through the Product API.

=head1 PUBLIC CLASS METHODS

=over 8

=item * $class->newWithProduct($product)

Allocate an AppInstanceManager for use later.

=cut

sub newWithProduct {
    my $class = shift;
    my $product = shift;

    my $productName  = $product->name();
    my $serviceName  = $product->service();
    my $customer     = $product->customer() || 'default';
    my $buildName       = $product->buildName() || "";
    #
    # Cache it for this product
    #
    my $cacheKey = "$productName$serviceName$customer$buildName";
    my $cached = $appInstanceManagersCache{$cacheKey};

    return $cached if $cached;

    my $self = {
        'product' => $product,
        'appInstances' => undef,
        'communities' => undef,
    };

    bless($self, $class);

    $appInstanceManagersCache{$cacheKey} = $self;

    return $self;
}

=pod

=back

=head1 PUBLIC OBJECT METHODS

=over 8

=cut

sub product {
    my $self = shift;

    return $self->{'product'};
}

sub communityNames {
    my $self = shift;
    my @names = ();

    # Initialize the app info, in case it hasn't already been done
    my @apps = $self->appInstances();

    my $communitiesInProduct = $self->{'communities'};

    if ($communitiesInProduct) {
        @names = keys(%$communitiesInProduct);
    }

    return @names;
}

=item * $self->isLayout(version)

Return true if layout is >= version

If the layout version in the config is "true", treat it as version 1

=cut

sub isLayout {
    my $self = shift;
    my $version = shift;

    my $layoutVersion = $self->product()->default('Ops.UseNewInstanceLayoutAlgorithm') || "";

    if($layoutVersion eq "true") {
        return $version <= 1;
    }

    if($layoutVersion =~ m/^v(\d+)$/) {
        return $version <= $1;
    }

    return 0;
}

sub numCommunities {
    my $self = shift;

    return (scalar($self->communityNames()));
}


=item * $self->appInstances()

Return all AppInstance objects for the received product in the current cluster.

=cut

sub appInstances {
    my $self = shift; 

    return $self->appInstancesInCluster($self->product()->currentCluster());
} 


=item * $self->appInstancesInCluster( clusterName )

Return all AppInstance objects for the received product in the specified cluster.

=cut

sub appInstancesInCluster {
    my $self = shift;
    my $cluster = shift;

    return [] unless ( $cluster );

    return $self->{"appInstancesIn$cluster"} if ( $self->{"appInstancesIn$cluster"} );

    undef($bucketHash);

    my $product      = $self->product();
    my $productName  = $product->name();
    my $serviceName  = $product->service();
    my $configDir    = $product->configDir();
    my $buildName    = $product->buildName();
    my $rolesManager = $product->rolesManager();
    my $customer     = $product->customer() || 'default';

    my ($appFlags,$appCounts,$totalAppCounts,$appsToHosts,$communitiesInProduct);

    unless (defined $rolesManager) {
        warn "rolesManager is not defined! cannot continue.";
        return undef;
    }

    my @apps = ();

    my @emptyList = ();
    my %emptyMap =  ();

    $self->{"appInstancesIn$cluster"} = [ @emptyList ];

    my @portNames;

    # Old-style config
    if (-r "$configDir/apps.cfg") {

        $appFlags = $self->_loadAppsCfg($configDir,$product);

        $appCounts = $self->_loadAppsCfgCounts(
            $appFlags,$rolesManager,$cluster
        );

        $appsToHosts = $self->_distributeLoad(
            $appCounts,$appFlags,$product,$rolesManager,$cluster
        );

        @apps = $self->_mergeAndCreateInstancesOld(
            $appCounts,$appFlags,$appsToHosts,$rolesManager,
            $product,$cluster
        );

    # New-style config
    } elsif (-r "$configDir/appflags.cfg") {

        ($appCounts, $totalAppCounts, $communitiesInProduct) = $self->_loadAppCounts($productName, $buildName,$configDir,$serviceName, $cluster);

        $self->{'communities'} = $communitiesInProduct;

        $appFlags = $self->_loadAppFlags(
            $configDir,$product,$totalAppCounts
        );

        $appsToHosts    = $self->_distributeAppsUsingRoles(
            $appCounts,$appFlags,$product,$rolesManager,$cluster
        );

        @apps = $self->_mergeAndCreateInstances(
            $appCounts,$appFlags,$appsToHosts,$rolesManager,
            $product,$cluster,$customer
        );

    } else {
        warn "No valid config files exist!" if $DEBUG;
        return $self->{"appInstancesIn$cluster"};
    }

    if ($self->instancesHavePortNumberClash(@apps)) {
        return $self->{"appInstancesIn$cluster"};
    }

    $self->{"appInstancesIn$cluster"} = [ @apps ];

    return $self->{"appInstancesIn$cluster"};
}

=pod

=item * $self->instancesHavePortNumberClash($basePortNamesRef, @instances)

Return the number of instances in the received array which have port conflicts.

=cut

sub instancesHavePortNumberClash {
    my $self = shift;
    my @instances = @_;

    my @portNames;

    my %ports = ();
    my $clashes = 0;

    for my $instance (@instances) {
        my $host = $instance->host();
        my $name = $instance->instanceName();

        my @instancePorts = ();
        my %portToPortName;

        my @portNames = grep { $_ =~ m/Port$/i } $instance->attributes();

        for my $portName ( @portNames ) {
            my $p = $instance->attribute($portName);

            if ( $p ) {
                push(@instancePorts, $p);
                $portToPortName{$p} = $portName;
            }

        }

        for my $p ( @instancePorts) {
            if ( $ports{$host}{$p} ) {
                warn "****** Error: $name has $portToPortName{$p} ($p) port number clash with $ports{$host}{$p}\n";
                $clashes++;
            } else {
                $ports{$host}{$p} = $name;
            }
        }
    }

    return $clashes;
}

=pod

=back

=head1 PRIVATE OBJECT METHODS

=over 8

=item $self->_distributeLoad($appCounts,$appFlags,$product,$rolesManager,$cluster)

=cut

sub _distributeLoad {
    my ($self,$appCounts,$appFlags,$product,$rolesManager,$cluster) = @_;

    my %appToCount = ();

    for my $appName ( sort(keys(%$appCounts)) ) {

        my $communityCount = $appCounts->{$appName};
        my $role  = $appFlags->{$appName}->{'launchedBy'};
        my @hosts = $rolesManager->hostsForRoleInCluster($role, $cluster);

        for my $communityName (sort keys %$communityCount) {

            for my $host (sort(@hosts)) {
                $appToCount{$appName}->{$communityName}->{$host} = $communityCount->{$communityName};
            }
        }
    }

    return \%appToCount;
}

sub _calculateLoadFactorForHosts {
    my $self = shift;
    my $product = shift;
    my $hint = shift;
    my $hosts = shift;
    my $realForVirtualHost = shift;

    my %factorForHost = ();

    my $baseMem  = 1024;
    my $baseCpuSpeed = 200;

    for my $host ( @$hosts ) {
        next if defined $factorForHost{$host};

        my $machine = $self->_loadAndValidateMachineDB($product, $realForVirtualHost || $host);
        next unless ( $machine );

        my $memorySize = $machine->memorySize();
        my $cpuCount   = $machine->cpuCount();
        my $cpuSpeed   = $machine->cpuSpeed();
        my $factor     = 1;

        if ($hint =~ /mem/i) {
            $factor = _myround($memorySize/$baseMem);
        } elsif ($hint =~ /cpu/i) {
            $factor = _myround($cpuCount * ($cpuSpeed/$baseCpuSpeed));
        }
        $factorForHost{$host} =  $factor;
    }

    return \%factorForHost
}

=pod

=item * $self->_distributeAppsUsingRoles($appCounts,$appFlags,$product,$rolesManager,$cluster);

=cut

sub _distributeAppsUsingRoles {
    my $self = shift;
    my $appCounts = shift;
    my $appFlags = shift;
    my $product = shift;
    my $rolesManager = shift;
    my $cluster = shift;

    my $serviceName = $product->service();
    my $instancesOfAppOnEachMachine = {};
    my $numOfAppsOnMachine      = {};
    my $memConsumedOnMachine  = {};

    my $allowUnevenLayout = $product->default('Ops.allowUnevenInstanceLayoutAndRedundancy') &&
        $product->default('Ops.allowUnevenInstanceLayoutAndRedundancy') eq 'true';

    # intialize each machine as not running any apps at all
    for my $host ($rolesManager->hostsInCluster($cluster), $rolesManager->virtualHostsInCluster($cluster)) {
        $numOfAppsOnMachine->{$host} = 0;
        $memConsumedOnMachine->{$host} = 0;
    }

    for my $appName ( sort(keys(%$appCounts)) ) {

        my $communityCount = $appCounts->{$appName};
        my $hint = $appFlags->{$appName}->{'loadDistHint'} || '';
        my $role = $appFlags->{$appName}->{'launchedBy'};

        print "\nLoad balance hint for $appName = $hint\n" if $DEBUG > 1;

        my @hosts = ();
        my $factorForHost;

        if (defined $role) {
            @hosts = sort($rolesManager->hostsForRoleInCluster($role, $cluster));
            my $realForVirtualHost;
            if (my @virtualHosts = sort($rolesManager->virtualHostsForRoleInCluster($role, $cluster))) {
                $realForVirtualHost = shift @hosts;     # Simply use first host's mdb
                @hosts = (shift @virtualHosts);             # There is always just 1 virtual host per role
            }
            $factorForHost = $self->_calculateLoadFactorForHosts($product, $hint, \@hosts, $realForVirtualHost);
        }

        for my $communityName ( sort(keys(%$communityCount)) ) {

            my $count = $appCounts->{$appName}->{$communityName};
            my $maxHeap = $self->_maxHeapForApp($product,$appName);

            if ($DEBUG > 1) {
                print "---------------------------------------------------\n";
                print "App = $appName, Community = $communityName, ";
                print "role = $role, count = $count, heap = $maxHeap\n";
            }

            if ($count > 0 && @hosts == 0) {
                warn "Error: no host found to run $appName\n"; 
                next;
            }

            for my $host (@hosts) {
                $instancesOfAppOnEachMachine->{$appName}->{$communityName}->{$host} = 0;
                print "  $host\n" if $DEBUG > 1;
            }

            #skipping chcek for robots (personal service) 
            if (($serviceName && (!ariba::rc::Globals::isPersonalService($serviceName))) &&  
                $appName eq 'CatSearch' && ($count % 2  != 0) && 
                $self->isLayout(4)) {
                    warn "Error: Node count for CatSearch node must be even, but it is $count instead.\n"; 
                    next;
            }
      
            # assign hosts to run each instance
            while ($count > 0) {

                # get an ordered list of hosts to distribute load evenly.
                my @orderedHosts = $self->_orderHosts($product, $factorForHost, $numOfAppsOnMachine, $instancesOfAppOnEachMachine->{$appName}->{$communityName}, $memConsumedOnMachine, $allowUnevenLayout, @hosts);
                unless(@orderedHosts) {
                    print "ERROR: no more hosts left to allocate $count AppInstances\n";
                    last;
                }

                # Make exception for CatSearch as it should always be evenly balanced
                @orderedHosts = ($orderedHosts[0]) if ($allowUnevenLayout && $appName ne 'CatSearch');  

                my $loadMultiplier = 1;
                $loadMultiplier = 2 if ($appName eq 'CatSearch' && $self->isLayout(4) && ($serviceName && (!ariba::rc::Globals::isPersonalService($serviceName))));

                for my $host (@orderedHosts) {

                    $instancesOfAppOnEachMachine->{$appName}->{$communityName}->{$host} += $loadMultiplier;
                    $numOfAppsOnMachine->{$host} += $loadMultiplier;
                    $memConsumedOnMachine->{$host} += ($maxHeap * $loadMultiplier) || 0;

                    $count -= $loadMultiplier;
                    last if $count <= 0;
                }
            }

        }
    }

    # print the current load on each server for debugging
    if ($DEBUG) {
        my %hostsHash = ();

        for my $host (keys %$numOfAppsOnMachine) {
            my $count = $numOfAppsOnMachine->{$host} || next;
            $hostsHash{$host} = $count;
        }

        for my $host (sort { $hostsHash{$a} <=> $hostsHash{$b} } keys %hostsHash) {
            print "$host $hostsHash{$host}\n";
        }
    }

    return $instancesOfAppOnEachMachine;
}

my %_hostsToMachineDBCache;

sub _loadAndValidateMachineDB {
    my $self = shift;
    my $product = shift;
    my $host = shift;

    my $name = $product->name();
    my $customer = "";
    my $productIdentifier = $name;
    if ($product->isASPProduct()) {
        $customer = $product->customer();
        $productIdentifier = "$name(customer: $customer)";
    }

    if (exists($_hostsToMachineDBCache{"$host-$productIdentifier"})) {
        return $_hostsToMachineDBCache{"$host-$productIdentifier"};
    }

    my $errMsg;
    my $machine;

    # try to resolve the hostname to make sure its valid
    my $ip = ariba::Ops::NetworkUtils::hostToAddr($host);

    # failed resolution returns the hostname as ip address
    if ($ip eq $host) {
        #
        # retry DNS if we get a failure.  This was done to fix another
        # DNS problem (TMID:77993), and so I'll try the same thing for
        # TMID:82800
        #
        $ip = ariba::Ops::NetworkUtils::hostToAddr($host);
        if($ip eq $host) {
            $errMsg = "cannot resolve $host to it ip address";
        }
    }   

    unless ($errMsg) {
        $machine = ariba::Ops::Machine->new($host);
        $errMsg = "failed to load machinedb record" unless($machine);
    }

    #
    # a valid machinedb entry must have atleast 5 entries
    #
    if (!$errMsg && scalar($machine->attributes()) < 5) {
        $errMsg = "bad machinedb record. It has less than 5 attributes";
    }

    #
    # Make sure it has entries we will use
    #
    unless ($errMsg) {
        my $memorySize = $machine->memorySize();
        my $cpuCount   = $machine->cpuCount();
        my $cpuSpeed   = $machine->cpuSpeed();
        if (!$memorySize || !$cpuCount || !$cpuSpeed) {
            $errMsg = "machinedb missing memorySize:$memorySize:, cpuCount:$cpuCount:, cpuSpeed:$cpuSpeed";
        }
    }

    # tell user what's wrong
    if ($errMsg) {
        print "ERROR: Bad host [$host] in configs for $productIdentifier: $errMsg\n";
        $machine = undef;
    } 

    $_hostsToMachineDBCache{"$host-$productIdentifier"} = $machine;
    return $_hostsToMachineDBCache{"$host-$productIdentifier"};
}


=pod

=item * $self->_orderHosts($product,$hint,$numOfAppsOnMachine,@hosts)

=cut

sub _orderHosts {
    my $self = shift;
    my $product = shift;
    my $factorForHost = shift;
    my $numOfAppsOnMachine = shift;
    my $numOfSameAppsInCommunityOnMachine = shift;
    my $memConsumedOnMachine = shift;
    my $allowUnevenLayout = shift;
    my @hosts = @_;

    my @orderedHostList = ();
    my %loadOnHost = ();

    my %hostCapacity = ();

    for my $host (@hosts) {

        push(@orderedHostList, $host) if $self->isLayout(1);

        my $factor = $factorForHost->{$host};

        # 
        # the +2 skews the sort of the hosts, favoring hosts with larger
        # factors (memory or cpu size) by moving them to the front of the
        # list.  The value was empirically determined to be the best
        # adjustment in terms of using all available resources on hosts.
        #
        # Increasing this factor past 2 causes the larger hosts to become
        # overloaded before fully utilizing the smaller hosts, and less than
        # 2 causes the smaller hosts to become overloaded before fully
        # utilizing the larger ones.  "Fully utilize" in this sense means
        # that the ratio of app instances to host resources remains very close
        # for hosts with varying amounts of resources.
        #
        $loadOnHost{$host} = ($numOfAppsOnMachine->{$host} + 2)/$factor;

        # save aside the fact that this host can handle more load
        #
        # normalize the number of apps a machine is running
        if ($factor > 1) {
            $hostCapacity{$host} = $factor;
        }
    }

    unless ($self->isLayout(1)) {
        @orderedHostList = keys %loadOnHost;
    }

    if ($self->isLayout(2)) {
        @orderedHostList = sort { 
            my $redundancyLoadA = $numOfSameAppsInCommunityOnMachine->{$a} ? 1 : 0; 
            my $redundancyLoadB = $numOfSameAppsInCommunityOnMachine->{$b} ? 1 : 0;
            $allowUnevenLayout && ($redundancyLoadA <=> $redundancyLoadB) ||
            ($loadOnHost{$a} <=> $loadOnHost{$b})
        } @orderedHostList;
    } else {
        @orderedHostList = sort { $memConsumedOnMachine->{$a} <=> $memConsumedOnMachine->{$b} } @orderedHostList;
    }

    unless ($self->isLayout(2)) {
        # For machines that can handle more load, add them to the list more than once
        while (keys(%hostCapacity)) {
            for my $host (@orderedHostList) {
                if ($hostCapacity{$host} && $hostCapacity{$host} > 1) {
                    push(@orderedHostList, $host);
                    $hostCapacity{$host}--;
                } else {
                    delete $hostCapacity{$host};
                }
            }
        }
    }

    #print "returning list as : ", join(", ", map { "$_(" . $loadOnHost{$_}.")" } @orderedHostList), "\n";
    return (@orderedHostList);
}


=pod

=item * $self->_loadAppsCfgCounts($appFlags,$rolesManager,$cluster)

=cut

sub _loadAppsCfgCounts {
    my $self = shift;
    my $appFlags = shift;
    my $rolesManager = shift;
    my $cluster = shift;

    my $appCounts = {};

    # build a appCounts hash for the old config type
    while(my ($appName, $values) = each %$appFlags) {

        my @hosts = $rolesManager->hostsForRoleInCluster($appFlags->{$appName}->{'launchedBy'}, $cluster);

        $appCounts->{$appName}->{'default'} = $appFlags->{$appName}->{'instances'};
    }

    return $appCounts;
}


=pod

=item * $self->_loadAppCounts($productName, $buildName,$configDir,$serviceName,$cluster)

=cut

sub _loadAppCounts {
    my $self = shift;
    my $productName = shift;
    my $buildName = shift;
    my $configDir = shift;
    my $serviceName = shift;
    my $cluster = shift;

    my %communitiesInProduct;

    my $configFile = "$configDir/appcounts.cfg";
    if ( $cluster ) {
        my $clusterCfgFile = "$configFile.$cluster";
        $configFile = $clusterCfgFile if ( -f $clusterCfgFile );
    }

    ### If CQ config is allowed, check for existence of same. The
    ### config is created during CQ run and cleaned up once the run 
    ### is complete. If for some reason, it isn't, it will cause 
    ### problems during BQ/LQ. Cluster stop will cleanup shared temp 
    ### so this is unlikely, also build name is used to reduce the 
    ### likelyhood.
    if (ariba::rc::Utils::allowCQConfig($productName, $serviceName)) {
            my $sharedTempDir = ariba::rc::Utils::sharedTempDir($configDir);
            if (defined $sharedTempDir) {
                print "Checking for existence of CQ topology in $buildName" . 
                      "_cqtopology in directory $sharedTempDir \n" if $DEBUG;
                my $cqConfigFile = "$sharedTempDir/$buildName" . "_cqtopology/appcounts.cfg";
                if (-r $cqConfigFile) {
                    print "Using CQ app counts : $cqConfigFile \n" if $DEBUG;
                    $configFile = $cqConfigFile;
                }
            }
    }

    return 0 unless -r $configFile;

    print "reading configFile: [$configFile]\n" if $DEBUG;

    my %appCounts = ();

    # input separator
    local $/ = 'Community ';

    open (CONF, $configFile) or do {
        warn "Error: Could not open [$configFile]: $!";
        return undef;
    };

    while(<CONF>) {
        chomp;
        next if /^\s*$/ or /^#/;

        my ($communityName,$appsCountString) = (/^(\S+)\s+\{(.+?)\}/gs);

        unless ($communityName eq 'default') {
            $communitiesInProduct{$communityName} = $communityName;
        }

        my %count = ();
        
        for my $line (split /\n/, $appsCountString) {

            next if $line =~ /^#/;

            if ($line =~ /(\S+),\s*(\d+)/) {
                $count{$1} = $2;
            }
        }

        if ($DEBUG) {
            print "communityName: [$communityName]\n";
        }

        while (my ($appName,$count) = each %count) {
            $appCounts{$appName}->{$communityName} = $count;
        }
    }
    close(CONF);

    my %totalAppCounts;
    for my $appName (keys(%appCounts)) {
        my $count = 0;
        for my $communityName(keys(%{$appCounts{$appName}})) {
            $count += $appCounts{$appName}->{$communityName};
        }
        $totalAppCounts{$appName}->{'instances'} = $count;
    }

    return (\%appCounts, \%totalAppCounts, \%communitiesInProduct);
}


=pod

=item * $self->_loadAppFlags($configDir,$product,$totalAppCounts)

=cut

sub _loadAppFlags {
    my $self = shift;
    my $configDir = shift;
    my $product = shift;
    my $totalAppCounts = shift;

    return $self->_loadTemplateCfg("$configDir/appflags.cfg", $product, $totalAppCounts);
}

=pod

=item * $self->_loadAppsCfg($configDir,$product)

=cut

sub _loadAppsCfg {
    my $self = shift;
    my $configDir = shift;
    my $product = shift;

    return $self->_loadTemplateCfg("$configDir/apps.cfg", $product);
}

=pod

=item * $self->_maxHeapForApp($product,$appName)

=cut

sub _maxHeapForApp {
    my $self = shift;
    my $product = shift;
    my $appName = shift;

    my $maxHeap;

    #
    # This is platform style product, heap size is defined once globally
    #
    if (defined $product->tomcatVersion()) {
        if ($maxHeap = $product->default("System.Base.ToolsDefault.JavaMemoryMax")) {
            if ($maxHeap =~ /(\d+)M/i) {
                $maxHeap = $1;
            } else {
                ($maxHeap) = ($v5HeapDefault =~ /Xmx(\d+)M/i);
            }

            $maxHeap *= $mb;
            $maxHeap += $jvmMemOverhead;
        }
    }

    #
    # AES
    #
    #XXX this should differentiate between sourcing and admin
    if ($product->name() eq "aes" && $appName =~ /Sourcing/i) {
        $maxHeap = $product->default("jvmparams.heapsize.max");
        $maxHeap *= $mb;
        $maxHeap += $jvmMemOverhead;
    }

    #
    # Perl App
    #
    # XXX - this is an educated guess -- these should be small
    #
    if( $appName =~ /OpsToolsTest/ ) {
        $maxHeap = 50 * $mb;
    }

    #
    # OpenOffice
    #
    # XXX - this is an educated guess for now -- we need to check how this
    # goes in qa/load
    #
    if( $appName =~ /OpenOffice/ ) {
        $maxHeap = 250 * $mb;
    }

    if ( $appName =~ /Selenium/i) {
        # 200 mb for selenium java proc + 20 mb for XVFB
        $maxHeap = 225 * $mb;
    }
    
    if ( $appName =~ /PhpCgi/i) {
        $maxHeap = 250 * $mb;
    }

    if ( $appName =~ /AUCSolr/ ){
        $maxHeap = $product->default("System.Base.ToolsDefault.JavaMemoryMax");
    }
    if ( $appName =~ /AUCCommunity/i ) {
        #This override is required to avoid warnings emitted below if this is undeclared
        #AUCCommunity is a PHP app so does not require maxHeap setting
        $maxHeap = 1;
    }
    #
    # This is WOF app, heap size is defined in DD.xml and can be
    # overriden for each app
    #
    if (defined $product->woVersion()) {

        if ($product->default("\l$appName.jvmargs")) {

            $maxHeap = $product->default("\l$appName.jvmargs");

        } elsif ($product->default("\l$appName.jvmargsappend")) {

            $maxHeap = $product->default("\l$appName.jvmargsappend");

        } else {
            $maxHeap = $v5HeapDefault;
        }

        if ($maxHeap =~ /Xmx(\d+)M/i) {
            $maxHeap = $1;
        } else {
            ($maxHeap) = ($v5HeapDefault =~ /Xmx(\d+)M/i);
        }

        $maxHeap *= $mb;
        $maxHeap += $jvmMemOverhead;
    }

    unless ($maxHeap) {
        $maxHeap = $product->default("JVM.$appName.MaxHeapSizeInMB") || $product->default("JVM.MaxHeapSizeInMB");
        $maxHeap *= $mb if ($maxHeap);
    }

    if ($product->default("Ops.JVM.$appName.MaxHeapSize") || $product->default("Ops.JVM.MaxHeapSize")) {
        $maxHeap = $product->default("Ops.JVM.$appName.MaxHeapSize") || $product->default("Ops.JVM.MaxHeapSize");
        $maxHeap *= $mb if ($maxHeap && ($maxHeap =~ s/M$//io || $maxHeap =~ /\d$/o));
        $maxHeap *= $gb if ($maxHeap && $maxHeap =~ s/G$//io);
    }

    return $maxHeap;
}


=pod

=item * $self->_maxPermForApp($product,$appName)

=cut

sub _maxPermForApp {
    my $self = shift;
    my $product = shift;
    my $appName = shift;

    my $jvmArgs;
    my $isJavaApp = 0;

    # Platform
    if (defined $product->tomcatVersion()) {
        my @jvmArgs = $product->default("System.Base.ToolsDefault.JavaVMArguments");
        if ( my @jvmArgs ) {
            $jvmArgs = join(' ', @jvmArgs);
            $isJavaApp = 1;
        }
    }

    # AES
    if ( $appName =~ /Sourcing/i ) {
        $jvmArgs = $product->default("jvmparams.heapsize.addtl-mem-args");
        $isJavaApp = 1;
    }

    # WOF (AN)
    if (defined $product->woVersion()) {
        if ($product->default("\l$appName.jvmargs")) {
            $jvmArgs = $product->default("\l$appName.jvmargs");
        } elsif ($product->default("\l$appName.jvmargsappend")) {
            $jvmArgs = $product->default("\l$appName.jvmargsappend");
        }
        $isJavaApp = 1;
    }

    ## Solr for AUC/Community
    if ( $appName =~ /AUCSolr/ ){
        $jvmArgs = $product->default("System.Base.ToolsDefault.JavaVMArguments");
        $isJavaApp = 1;
    }

    if ( $appName =~ /AUCCommunity/i ) {
        $jvmArgs = "";
        $isJavaApp = 0;
    }

    # Other Apps
    if( $appName =~ /(?:OpenOffice|Selenium)/i ) {
        $isJavaApp = 1;
    }

    return 0 unless ($isJavaApp);

    my $maxPerm = $maxPermSizeDefault;
    $maxPerm = $1 if ($jvmArgs && $jvmArgs =~ /[MaxPermSize|MaxMetaspaceSize]=(\d+)M/i);
    $maxPerm *= $mb;

    return $maxPerm;
}


=pod

=item * $self->_maxOverheadForApp($product,$appName)

=cut

sub _maxOverheadForApp {
    my $self = shift;
    my $product = shift;
    my $appName = shift;

    my $isJavaApp = 0;
    my $defaultOverhead = 70;  # Use this unless set in overheadMap below
    my %overheadMap = (
        s4      => { default => 170, TaskCXML => 240, Admin => 10, GlobalTask => 90 },
        buyer   => { default => 80, TaskCXML => 130, Admin => 10, GlobalTask => 10 },
        an      => { 
            default => 70,  # AN mostly don't seem to have much overhead
            Address => 200,
            ANCXMLDispatcher => 100,
            PropogationProcessor => 100,
            Discovery => 100,
            DiscoveryAdmin => 80,
            Supplier => 100,
            ANCXMLOutDispatcher => 80,
            Admin => 90,
            ANTaskDispatcher => 90, 
            Forex => 230,
            }, 
        logi        => { HbaseRegion => 1024 },
        hadoop      => { HbaseRegion => 1024 },
        hadoopdr    => { HbaseRegion => 1024 },
        community   => { AUCSolrIndexer => 1024, AUCSolrSearch => 1024 },
        );
    
    if ($overheadMap{$product->name()} || 
        defined $product->tomcatVersion() ||                        # Platform
        defined $product->woVersion() ||                            # WOF (AN)
        $appName =~ /(?:Sourcing|OpenOffice|Selenium|AUCSolr)/i) {  # Others
        $isJavaApp = 1;
    }
    
    my $maxOverhead = ($overheadMap{$product->name()} && 
        ($overheadMap{$product->name()}{$appName} || 
        $overheadMap{$product->name()}{'default'}) ) || $defaultOverhead;
    my $overhead = 0; 

    # jvmMemOverhead is added in _maxHeapForApp. When not added,
    # then the below formula can be adjusted.
    $overhead = ($maxOverhead * $mb) - $jvmMemOverhead if ($isJavaApp);

    return $overhead;
}

=pod

=item * $self->_loadTemplateCfg($configFile,$product,$totalAppCounts)

this loads both the old apps.cfg and the new appflags.cfg file, and passes
back a $flags hash ref.

=cut

sub _loadTemplateCfg {
    my $self = shift;
    my $configFile = shift;
    my $product = shift;
    my $totalAppCounts = shift;


    #
    # This sub parses the appflags.cfg file and creates a data struture
    # describing the app *classes*.   It doesn't deal with any instance
    # data yet.
    #

    my ($apps, @keys, %ports, @portNames) = ({}, (), (), ());

    print "reading configFile: [$configFile]\n" if $DEBUG;

    return 0 if !defined($configFile) || !-r $configFile;

    my $appType = undef;
    
    open (CFG, $configFile) or do { 
        warn "Error: Could not open [$configFile]: $!";
        return undef;
    };

    while(<CFG>) {

        chomp;
        s/\r//;

        if (/^\s*#\s*BEGIN\s*(\w*)/) {
            $appType = lc($1);
            next;

        } elsif (/^\s*#\s*END\s*(\w*)/) {
            if (lc($1) ne $appType) {
                warn "Syntax error, END before BEGIN of $1, $_";
                return undef;
            }
            $appType = undef;
            @portNames = ();
            next;

        } elsif (/^\s*#\s*TEMPLATE\s*:\s*(.*)/) {
            @keys = map { lcfirst($_) } split(/\s*,\s*/, $1);
            next;
        }

        next if /^\s*#/ || /^\s*$/;

        next unless defined $appType;

        #
        if (my ($name,$port) = (/^(base\S+)\s*=\s*(\d+)/i)) {
            $ports{lc $name} = $port;
            push(@portNames, lc($name));
            next;
        }

        # Save away the details of this app
        my @vals     = split(/\s*,\s*/);
        my $appName  = $vals[0];

        # create the apps hash
        for (my $i = 0; $i <= $#vals; $i++) {

            # Hack for RecvTO, etc in appflags.cfg
            $keys[$i] =~ s/TO$/To/;
            
            $vals[$i] =~ s/^\s+|\s+$//g;
            $apps->{$appName}->{$keys[$i]} = $vals[$i];
        }

        #
        $apps->{$appName}->{'appType'} = $appType;
        $apps->{$appType}->{'portNames'} = [ @portNames ];
    
        if (! $apps->{$appName}->{'instances'} ) {
            if ($totalAppCounts && $totalAppCounts->{$appName}) {
                $apps->{$appName}->{'instances'} = $totalAppCounts->{$appName}->{'instances'};
            } else {
                $apps->{$appName}->{'instances'} = 0;
            }
        }

        # figure out the max memory usage for the instance
        if (! $apps->{$appName}->{'maxInstanceMemory'}) {
            $apps->{$appName}->{'maxInstanceMemory'} = $self->_maxHeapForApp($product,$appName) + $self->_maxPermForApp($product,$appName) + $self->_maxOverheadForApp($product,$appName);
        }

        # Figure out some standard ports that all apps need
        # based on the base port porvided earlier
        for my $basePortName (@portNames) {
            $apps->{$appName}->{$basePortName} = $ports{$basePortName};
        }
        # this is a hack
        $apps->{$appName}->{'baseinstanceid'} = $ports{'baseport'};

        if ($DEBUG) {
            print "app = $appName, role = $apps->{$appName}->{'launchedBy'},";
        
            for my $basePortName (@portNames) {  
                print " $basePortName = $ports{$basePortName}";
            }
            print "\n";
        }

        # make space for $appName (class) to use, based on the number of instances
        # so that the next $appName's instances will start their ports after all of
        # the previous app's instances.

        if(!$self->isLayout(5)) {
            for my $basePortName ( @portNames ) {
                #XXXX THIS IS A BIG FAT HACK
                #XXXX This should be fixed one of two ways
                #XXXX 1. Redesign this code so the *AppInstance.pm classes
                #XXXX are given these params and they return a set of instances
                #XXXX 2. Sourcing 4.x should expose a way to set the "other" port
                #XXXX in addition to the main port 
                #XXXX There's a third way that was discussed and rejected:
                #XXXX allow the config file to declare a port incr per port type.
                #XXXX That's data that should be hidden in the *AppInstance classes
                #XXXX not forced into the config

                if ( $appType =~ /weblogic/i && $appName =~ /admin/i ) {
                    $ports{$basePortName}    += ( $apps->{$appName}->{'instances'} * 2 );
                } else {
                    $ports{$basePortName}    += $apps->{$appName}->{'instances'};
                }
            }
        }
    }

    close(CFG);

    return $apps;
}

=pod

=item * $self->_mergeAndCreateInstances($appCounts,$appFlags,$appsToHosts,$rolesManager,$product,$cluster,$customer);

Does the dirty work of mapping appflags and appcounts to objects.

=cut

sub _mergeAndCreateInstances {
    my $self = shift;
    my $appCounts = shift;
    my $appFlags = shift;
    my $appsToHosts = shift;
    my $rolesManager = shift;
    my $product = shift;
    my $cluster = shift;
    my $customer = shift;

    my @apps = ();
    my $productName = $product->name();
    my $serviceName = $product->service();

    my @appNames = keys %$appCounts;
    @appNames = sort @appNames if ($self->isLayout(4));
    my $id = $appFlags->{$appNames[0]}->{'baseinstanceid'};
    foreach my $appName (@appNames) {

        my $communityCount = $appCounts->{$appName};
        my $appType = $appFlags->{$appName}->{'appType'};
        $id = $appFlags->{$appName}->{'baseport'} if(!$self->isLayout(5));

        my $temp = 0;
        for my $community (sort keys %$communityCount) {
            my $totalCount = $communityCount->{$community};
            my $startBucket = $temp % 2;
            my $idForCommunity = 1;

            my @hosts = keys %{$appsToHosts->{$appName}->{$community}};
            @hosts = sort @hosts if ($self->isLayout(4));
            foreach my $host (@hosts) {

                my $instanceCount = $appsToHosts->{$appName}->{$community}->{$host};

                $self->_commonMergeAndCreate(
                    $productName, $appName, $appType, $appFlags, $instanceCount,
                    \$id, $host, $product, $cluster, $community, $customer, \@apps, $totalCount, \$idForCommunity, $startBucket
                );
            }
            $temp++;
        }
    }

    # DO NOT CHANGE the order of @apps as it needs to be in $id order to be better load balanced
    # when ariba::Ops::Startup::Apache::writeModJKConfigFile() creates the modjk worker properties.
    # $id order means sequential HTTP requests hits different host. If sorted, in host IP's last 
    # octet (host order), many sequential requests would hit the same host.
    # OK to sort once better sorting algorithm is used in writeModJKConfigFile(). 
    # TMID:99124

    return @apps;
}

#
# this call gets lazy loaded when code asks for $instance->recycleGroup().
#
# It does NOT affect the basic app to host allocation.  Instead it looks
# at the bucket allocation, and swaps like appinstances from bucket 1 and 0,
# for instance swapping UI-19410145@app270 (bucket 1) for UI-24310144@app293
# (bucket 0) such that UI-19410145@app270 ends up in bucket 0, and
# UI-24310144@app293 ends up in bucket 1.
#
# This is done such that at the end:
#
# * apps are still balanced across recycleGroups because we always trade 1-to-1
# * apps are still host balanced, because we don't change that
# * hosts are better, if not perfectly balanced by recycleGroup.
#
sub allocateV3Buckets {
    my $self = shift;
    my $cluster = shift;
    my $product = $self->product();

    unless($ENV{'USE_V3_LAYOUT'} || $self->isLayout(3)) {
        return;
    }

    if($self->isLayout(5)) {
        return;
    }

    my ($ltop, $lbot);
    my $start = [ gettimeofday() ];
    my $totalCPUStart = clock();
    my $swaps = 0;
    my $fullLook = 0;
    my $considered = 0;
    my $totalConsidered = 0;
    my $lastTotalDiffPrime;
    my $sameTotalDiff=0;
    my ($lastA, $lastB);
    my $ref = $self->appInstancesInCluster($cluster);
    my @apps = (sort { $a->orderId() <=> $b->orderId() } @{$ref});
    print "Balancing ", scalar(@apps), " nodes " if($main::debug);
    my $maxSwaps = int(scalar(@apps)/4);
    $maxSwaps = 25 if($maxSwaps < 25);
    my $hosts;
    my @hostList;
    my @appTypes;
    my %appTypesHash;

    #
    # build an initial hash that has:
    #
    # * total nodes on host
    # * nodes by bucket on host
    # * an array of app instances for the host, hashed by appName:community
    # * arrays of app instances for the host, hashed by appName:community, and
    #   current bucket
    #
    foreach my $ai (@apps) {
        next if ($ai->appName eq 'CatSearch' && $self->isLayout(4));

        $hosts->{$ai->host()}->{'total'}++;
        $hosts->{$ai->host()}->{$ai->recycleGroup()}++;
        my $type = $ai->appName() . ":" . ($ai->community() || '');
        $appTypesHash{$type} = 1;
        push(@{$hosts->{$ai->host()}->{'apps'}->{$type}->{'all'}}, $ai);
        push(@{$hosts->{$ai->host()}->{'apps'}->{$type}->{$ai->recycleGroup()}}, $ai);
    }

    #
    # we build a @hostList array here -- we can't rely on the return order
    # for keys, and building this here saves a lot of sort calls.
    #
    # same for @appTypes
    #
    @hostList = sort(keys(%$hosts));
    @appTypes = sort(keys(%appTypesHash));

    print "across ", scalar(@hostList), " hosts.\n"
        if($main::debug);

    foreach my $h (@hostList) {
        #
        # this is either 0 (even number of nodes on host) or 1/total
        # for odd number of nodes.  It is used to detect cases where
        # you are swapping 2/3 and 3/2 for 3/2 and 2/3.
        #
        $hosts->{$h}->{'deviation'} = 
            ($hosts->{$h}->{'total'} % 2) / $hosts->{$h}->{'total'};

        #
        # these are bounds for unbalance.  It ends up being .5 +/- 1/total.
        # so for a host with 10 nodes, you get .4 for floor, and .6 for ceil,
        # which puts only .5 (5 and 5) between them, and thus "balanced".
        #
        # the interesting case, with 5 nodes, you get .3 and .7 -- which
        # puts both .4 (2 and 3) and .6 (3 and 2) as greater than floor
        # and less than ceil, so that both are considered balanced.
        #
        $hosts->{$h}->{'floor'} =
            (($hosts->{$h}->{'total'}/2)-1)/$hosts->{$h}->{'total'};
        $hosts->{$h}->{'ceil'} =
            (($hosts->{$h}->{'total'}/2)+1)/$hosts->{$h}->{'total'};
        my $ratio = ($hosts->{$h}->{0} || 0) / $hosts->{$h}->{'total'};

        #
        # special case -- if a host has 1 app instance, treat it as .5
        #
        $ratio = .5 if($hosts->{$h}->{'total'} == 1);

        $hosts->{$h}->{'ratio'} = $ratio;
    }

    my $maxDiffPrime = 0;
    my $totalDiffPrime = 0;
    my $swapStart = [ gettimeofday() ];
    my $cpuStart = clock();
    while(1) {
        my @low;
        my @high;
        $maxDiffPrime = 0;
        $totalDiffPrime = 0;
        my $maxSide;

        #
        # for each host, we calculated the ratio.  .5 is balanced.
        # less than .5 is bucket 1 heavy.  More than .5 is bucket 0 heavy.
        #
        # prime refers to the primary preference, which is to swap nodes off
        # the most overbalanced machine.  The secondary preference is to make
        # a swap with the widest difference between ratios.  maxDiffPrime and
        # totalDiffPrime are used to determine end cases, as the changes in
        # them reflect how much progress is still being made.
        #
        # more specifically:
        #   maxDiffPrime is the maximum f(host) = abs(ratio(host) - .5)
        #   totalDiffPrime is the sum of f(host) = abs(ratio(host) - .5) for
        #               all hosts.
        #
        # we also build an array, @low, which are hosts that are
        # bucket 1 heavy (low ratio), and arrays @high, which are arrays of
        # nodes on hosts that are bucket 0 heavy (high ratio).
        #
        # normally we only consider hosts outside of the floor/ceil
        # bounds, but when we don't find a swap, we open up to
        # using .5 as a pivot point instead of floor/ceil.
        #
        foreach my $h (@hostList) {
            my $ratio = $hosts->{$h}->{'ratio'};

            if($ratio <= $hosts->{$h}->{'floor'}) {
                push(@low, $h);
            } elsif($fullLook && $ratio <= .5) {
                push(@low, $h);
            }

            if($ratio >= $hosts->{$h}->{'ceil'}) {
                push(@high, $h);
            } elsif($fullLook && $ratio >= .5) {
                push(@high, $h);
            }

            my $prime;
            my $side;
            if($ratio > .5) {
                $prime = $ratio - .5;
                $side = "high";
            } else {
                $side = "low";
                $prime = .5 - $ratio;
            }
            if($prime > $maxDiffPrime) {
                $maxDiffPrime = $prime;
                $maxSide = $side;
            }
            $totalDiffPrime += $prime;
        }

        $totalDiffPrime = int($totalDiffPrime * 1000)/1000;

        #
        # totalDiffPrime is effectively a sum of how far off of perfect .5
        # balance the hosts are.  If we go 6 swaps in a row without this
        # changing, we stop as we're not making progress.
        #
        if(defined($lastTotalDiffPrime) && $totalDiffPrime == $lastTotalDiffPrime) {
            #
            # don't increment on a fullLook, since we didn't actually change
            # anything last iteration.
            #
            $sameTotalDiff++ unless($fullLook);
        } else {
            $sameTotalDiff = 0;
        }
        if($sameTotalDiff > 6) {
            print "not helping, ending.\n" if($main::debug);
            last;
        }
        $lastTotalDiffPrime = $totalDiffPrime;

        #
        # if no high ratio hosts and no low ratio hosts are found, we're done.
        # when we hit this exit case, we're happy.  The rest of them are cases
        # where we settle for good enough.
        #
        unless(scalar(@low) || scalar(@high)) {
            print "no high or low hosts found.\n" if($main::debug);
            last;
        }

        #
        # we try to only swap when we're way overloaded, but if one
        # host is way overloaded, we can swap with any host that is
        # leaning the other way.  This can happen in a case where
        #
        # A=0/5, B=3/2, C=3/2, D=3/2
        #
        # the above case, B, C, and D are "balanced", so we'd have no @high,
        # but we would have A in @low.
        #
        unless(scalar(@low)) {
            foreach my $h (@hostList) {
                if($hosts->{$h}->{'ratio'} <= .5) {
                    push(@low, $h);
                }
            }
        }
        unless(scalar(@high)) {
            foreach my $h (@hostList) {
                if($hosts->{$h}->{'ratio'} >= .5) {
                    push(@high, $h);
                }
            }
        }

        my ($sa, $sb);
        my $diffPrime = 0;
        my $diffSecond = 0;

        #
        # we loop the low(*) ratio hosts, and for each instance in bucket 1,
        # we check like apps on hosts in @high.  We are looking to swap a
        # node off the most overbalanced host first (diffPrime).  In cases
        # of multiple swaps that would achive the prime consideration, the
        # difference in host ratio is the secondary preference (diffSecond).
        # An exception, we never want to choose a node we chose last time, as
        # that can create an infinite loop.
        #
        # we also look at hosts in ratio order, and exit loops when we find
        # a match (which often saves a lot of comparisons that are much less
        # likely to generate a better match than we already have)
        #
        # (*) actually, we sometimes do this in reverse, if the most unbalanced
        # host is of the "high" variety.  We do this to try and find good swap
        # choices quickly.
        #
        @high = sort { $hosts->{$b}->{'ratio'} <=> $hosts->{$a}->{'ratio'} } @high;
        @low = sort { $hosts->{$a}->{'ratio'} <=> $hosts->{$b}->{'ratio'} } @low;


        if($maxSide eq "low") {
            #
            # this average is to cut down on choice considerations -- we'll only
            # look at the above average high hosts in the inner loop, unless we
            # are full looking
            #
            my $avgHigh = 0;
            if(scalar(@high)) {
                foreach my $h (@high) { $avgHigh += $hosts->{$h}->{'ratio'}; }
                $avgHigh = int($avgHigh/scalar(@high));
            }

            foreach my $lowHost (@low) {
                my $comp = .5 - $hosts->{$lowHost}->{'ratio'};
                foreach my $highHost (@high) {
                    last unless
                        ($fullLook || $hosts->{$highHost}->{'ratio'} > $avgHigh);
                    my $newPrime = $hosts->{$highHost}->{'ratio'} - .5;
                    last if($comp < $diffPrime && $newPrime < $diffPrime);
                    $newPrime = $comp if($comp > $newPrime);
                    my $newSecond = $hosts->{$highHost}->{'ratio'} -
                        $hosts->{$lowHost}->{'ratio'};
                    next unless($newPrime > $diffPrime ||
                        ($newPrime == $diffPrime && $newSecond > $diffSecond));
                    foreach my $type (@appTypes) {
                        foreach my $ai (@{$hosts->{$lowHost}->{'apps'}->{$type}->{1}}) {
                            $considered++;
                            foreach my $bi (@{$hosts->{$highHost}->{'apps'}->{$type}->{0}}) {
                                $considered++;
    
                                if(
                                    ((!$lastA || $lastA->instanceId() != $bi->instanceId()) &&
                                    (!$lastB || $lastB->instanceId() ne $ai->instanceId()))
                                ) {
                                    $sa = $ai; $sb = $bi;
                                    $diffPrime = $newPrime;
                                    $diffSecond = $newSecond;
                                }
                            }
                        }
                    }
                    last if($sa && $sb && !$sameTotalDiff);
                }
                last if($sa && $sb && !$sameTotalDiff);
            }
        } else {
            #
            # this is the same code as above, except we do high hosts in the
            # outer loops instead of low hosts, since our best swap candidate
            # is a "high" host.
            #
            my $avgLow = 0;
            if(scalar(@low)) {
                foreach my $h (@low) { $avgLow += $hosts->{$h}->{'ratio'}; }
                $avgLow = int($avgLow/scalar(@low));
            }

            foreach my $highHost (@high) {
                my $comp = $hosts->{$highHost}->{'ratio'} - .5;
                foreach my $lowHost (@low) {
                    last unless
                        ($fullLook || $hosts->{$lowHost}->{'ratio'} > $avgLow);
                    my $newPrime = .5 - $hosts->{$lowHost}->{'ratio'};
                    last if($comp < $diffPrime && $newPrime < $diffPrime);
                    $newPrime = $comp if($comp > $newPrime);
                    my $newSecond = $hosts->{$highHost}->{'ratio'} -
                        $hosts->{$lowHost}->{'ratio'};
                    next unless($newPrime > $diffPrime ||
                        ($newPrime == $diffPrime && $newSecond > $diffSecond));
                    foreach my $type (@appTypes) {
                        foreach my $bi (@{$hosts->{$highHost}->{'apps'}->{$type}->{0}}) {
                            $considered++;
                            foreach my $ai (@{$hosts->{$lowHost}->{'apps'}->{$type}->{1}}) {
                                $considered++;
    
                                if(
                                    ((!$lastA || $lastA->instanceId() != $bi->instanceId()) &&
                                    (!$lastB || $lastB->instanceId() ne $ai->instanceId()))
                                ) {
                                    $sa = $ai; $sb = $bi;
                                    $diffPrime = $newPrime;
                                    $diffSecond = $newSecond;
                                }
                            }
                        }
                    }
                    last if($sa && $sb && !$sameTotalDiff);
                }
                last if($sa && $sb && !$sameTotalDiff);
            }
        }

        #
        # if we don't find anything, we set fullLook, and expand our search in
        # the next pass.  The case where this helps is described above.
        #
        # if we already are doing an expanded search, and don't find a swap,
        # then we stop... it means we painted ourselves into a corner, where
        # it's not worth churning to get out of it.  Luckily this doesn't
        # happen often.  The corner case would be a where one host has
        # instances A and B, both in bucket 1, while all other A or B instances
        # are on hosts that lean towards bucket 1.
        #
        unless($sa && $sb) {
            if($fullLook) {
                print "no node found to swap\n" if($main::debug);
                last;
            }
            $fullLook=1;
            next;
        }

        #
        # this catches the end case where the nodes are odd in count on hosts,
        # and the only availible swaps are a 3/2 for a 2/3 (which doesn't
        # change anything).  We'd otherwise catch 2/3 and 3/2, with the
        # sameTotalDiff logic, but we wouldn't catch 3/2 and 3/4 without
        # this code.
        #
        my $thresh;
        $thresh = $hosts->{$sa->host()}->{'deviation'};
        $thresh = $hosts->{$sb->host()}->{'deviation'} if($thresh > $hosts->{$sb->host()}->{'deviation'});

        if($maxDiffPrime <= $thresh) {
            print "end, not enough delta\n" if($main::debug);
            last;
        }

        my $swapElapsed = tv_interval( $swapStart );
        $swapElapsed = int($swapElapsed*1000)/1000;
        $swapStart = [ gettimeofday() ];
        my $clock = clock();
        my $cpuElapsed = $clock - $cpuStart;
        $cpuStart = $clock;
        $cpuElapsed = $cpuElapsed/1000000;

        if($main::debug && $cpuElapsed > 0.1) {
            print ">> ";
        }

        print "$maxSide:swap ", $sa->instanceName(), " and ", $sb->instanceName(), " MaxLoad=", int(1000*(.5+$maxDiffPrime))/10, "%  TDP=$totalDiffPrime($fullLook:$sameTotalDiff) ($swapElapsed secs($cpuElapsed CPU)) (considered=$considered)\n"
            if($main::debug);

        #
        # we're going to swap, so clear fullLook
        #
        $fullLook=0;
        $totalConsidered += $considered;
        $considered=0;

        #
        # $sa is known to be in bucket 1 by selection logic, and $sb likewise
        # is known to be in bucket 0.  We set the opposite here, and then we
        # update %$hosts ratios with the new bucket 0 and bucket 1 allocation.
        #
        # Additionally, we rebuild the bucket 0 and bucket 1 arrays for these
        # hosts.
        #
        $sa->setRecycleGroup(0);
        $sb->setRecycleGroup(1);
        $hosts->{$sa->host()}->{0}++; $hosts->{$sa->host()}->{1}--;
        $hosts->{$sb->host()}->{1}++; $hosts->{$sb->host()}->{0}--;
        $hosts->{$sa->host()}->{'ratio'} = 
                $hosts->{$sa->host()}->{0} / $hosts->{$sa->host()}->{'total'}
                    unless($hosts->{$sa->host()}->{'total'} == 1);
        $hosts->{$sb->host()}->{'ratio'} = 
                $hosts->{$sb->host()}->{0} / $hosts->{$sb->host()}->{'total'}
                    unless($hosts->{$sb->host()}->{'total'} == 1);

        my $type = $sa->appName() . ":" . ($sa->community() || '');
        @{$hosts->{$sa->host()}->{'apps'}->{$type}->{0}} = ();
        @{$hosts->{$sa->host()}->{'apps'}->{$type}->{1}} = ();
        @{$hosts->{$sb->host()}->{'apps'}->{$type}->{0}} = ();
        @{$hosts->{$sb->host()}->{'apps'}->{$type}->{1}} = ();
        foreach my $ai (@{$hosts->{$sa->host()}->{'apps'}->{$type}->{'all'}}) {
            push(@{$hosts->{$sa->host()}->{'apps'}->{$type}->{$ai->recycleGroup()}}, $ai);
        }
        foreach my $ai (@{$hosts->{$sb->host()}->{'apps'}->{$type}->{'all'}}) {
            push(@{$hosts->{$sb->host()}->{'apps'}->{$type}->{$ai->recycleGroup()}}, $ai);
        }

        #
        # save this for preventing looping on the same node(s)
        #
        $lastA = $sa;
        $lastB = $sb;
        $swaps++;
        if($swaps >= $maxSwaps) {
            #
            # this prevents endless churn.  Luckily this rarely happens,
            # and then only in a case where the base input is heavily
            # skewed.  Now that we do a better first pass allocation, this
            # just doesn't happen.
            #
            print "ending after too many swaps\n" if($main::debug);
            last;
        }

        #
        # rotating this array helps the algorithm avoid getting stuck
        # in ruts where the same nodes are at the top of the list in
        # terms of tie breaking.  If diffPrime and diffSecond are the
        # same for two different pairs of nodes, the first pair found
        # is selected, but the order is based on this array, so this
        # just shakes the bag a little.
        #
        # ditto for the order we consider appTypes in.
        #
        my $h = shift(@hostList);
        push(@hostList, $h);
        my $t = shift(@appTypes);
        push(@appTypes, $t);
    }

    print "Final: MaxLoad=", int(1000*(.5+$maxDiffPrime))/10, "%  TDP=$totalDiffPrime\n" if($main::debug);

    my $elapsed = tv_interval( $start );
    my $totalCPUUsed = clock() - $totalCPUStart;
    $totalCPUUsed/=1000000;
    if($swaps) {
        $totalConsidered = int(($totalConsidered * 1000)/$swaps) / 1000;
        print "Completed $swaps swaps in $elapsed seconds using $totalCPUUsed seconds of CPU time (avg nodes looked at: $totalConsidered)\n" if($main::debug);
    }
}

###############################################################################
#This method is used to generate logicalNames of the form C1_UI1 , C1_UI2 etc.,
#This is part of dynamic capacity feature
##############################################################################
sub generateLogicalNames 
{
    my $self = shift;
    my $cluster = shift;
    my $refAppInstances = $self->appInstancesInCluster($cluster);
    my @appList = (sort { $a->orderId() <=> $b->orderId() } @{$refAppInstances});
 
    my %l2pMap = (      
       'MapB0' => undef, 
       'MapB1' => undef, 
    );
    $l2pMap{'MapB0'} =  { } ;
    $l2pMap{'MapB1'} =  { } ;
    
    for my $appInstance (@appList)
    {        
       my $alias         = $appInstance->alias();
       my $currentBucket = $appInstance->recycleGroup();
    
       #String like 'C1_' is appended with a String like 'UI' to get a string like 'C1_UI' here
       #Note that ending sequence number is not yet present
       my $community = $appInstance->community();    
       $community=0 unless defined $community;
       my $communityPrefix = "C$community"."_" . $alias; 
    
       #Map name to be used is dynamically generated. Bucket0 sequences are stored in 
       #map: l2pMapForB0 and bucket1 sequences are stored in map: l2pMapForB1 
       my $mapName = "MapB$currentBucket";
    
       #Bucket0 is initialized with -1 and Bucket1 is initialized with 0,  this will ensure odd numbered nodes 
       #are in bucket0 and even numbered nodes are in bucket1. We need to ensure the pool of values in bucket0 
       #and bucket1 are discrete to avoid duplicate names when we merge bucket0 of one topology with bucket1 of 
       #another topology
       if(!defined($l2pMap{$mapName}{ $communityPrefix }))
       {       
           my $initValue = ($currentBucket == 0 ) ? -1 : 0;
           $l2pMap{$mapName}{ $communityPrefix } = $initValue ;        
       }

       #Running sequence number for each bucket is generated here
       $l2pMap{ $mapName }{ $communityPrefix } += 2 ;

       #Complete logical name like C1_UI1 is formed here
       my $logicalName =  $communityPrefix . $l2pMap{ $mapName }{ $communityPrefix } ;
             
       #Set this after logical name is calculated
       $appInstance->setLogicalName($logicalName); 
    } 
}


=pod

=item * $self->_mergeAndCreateInstancesOld($appCounts,$appFlags,$appsToHosts,$rolesManager,$product,$cluster);

Performs the same function as _mergeAndCreateInstances(), but operates using the legacy apps.cfg config file.

=cut

sub _mergeAndCreateInstancesOld {
    my $self = shift;
    my $appCounts = shift;
    my $appFlags = shift;
    my $appsToHosts = shift;
    my $rolesManager = shift;
    my $product = shift;
    my $cluster = shift;

    my @apps = ();
    my $productName = $product->name();

    # All old style configs have no customer.
    my $customer;

    while(my ($appName, $communityCount) = each %$appCounts) {

        my $id;
        my $appType = $appFlags->{$appName}->{'appType'};
        
        for my $community (sort keys %$communityCount) {

            while(my ($host,$instanceCount) = each %{$appsToHosts->{$appName}->{$community}}) {

                $id = $appFlags->{$appName}->{'baseport'};

                $self->_commonMergeAndCreate(
                    $productName, $appName, $appType, $appFlags, $instanceCount,
                    \$id, $host, $product, $cluster, $community, $customer, \@apps
                );
            }
        }
    }

    return @apps;
}

sub _commonMergeAndCreate {
    my $self          = shift;
    my $productName   = shift;
    my $appName       = shift;
    my $appType       = shift;
    my $appFlags      = shift;
    my $instanceCount = shift;
    my $id            = shift;
    my $host          = shift;
    my $product       = shift;
    my $cluster       = shift;
    my $community     = shift;
    my $customer      = shift;
    my $apps          = shift;
    my $totalCount    = shift;
    my $idForCommunity    = shift;
    my $bucketStart = shift || 0;
    my $serviceName   = $product->service();

    my @portNames = @{$appFlags->{$appType}->{'portNames'}};

    my $shortHost = $host;
    $shortHost =~ s/\.ariba\.com//ig;
    my $instanceHost = $shortHost;
    $instanceHost =~ s/\.//g;

    my $applicationContext;

    for my $count (1..$instanceCount) {

        my ($appInstance, $class);

        # Create an appropriate object for each type.
        if ($appType =~ /WebLogic/i) {

            $class = 'ariba::rc::WebLogicAppInstance';

        } elsif ($appType =~ /Tomcat/i) {

            $class = 'ariba::rc::TomcatAppInstance';
            #
            # XXXX For tomcat appinstance pre-jupiter we write
            # instancename to Parameters.table, which does not
            # allow a '.' in the name. Once we stop updating
            # Parameters.table this should be removed
            #
            $shortHost =~ s/(\w*)\..*/$1/ig;
            $applicationContext = $product->default('Tomcat.ApplicationContext');

        } elsif ($appType =~ /Java/i || $appType =~ /Servers/i) {

            $class = 'ariba::rc::JavaAppInstance';

        } elsif ($appType =~ /OpenOffice/i) {

            $class = 'ariba::rc::OpenOfficeAppInstance';

        } elsif ($appType =~ /PhpCgi/i) {

            $class = 'ariba::rc::PHPAppInstance';

        } elsif ($appType =~ /Perl/i) {

            $class = 'ariba::rc::PerlAppInstance';

        } elsif ($appType =~ /Springboot/i) {

            $class = 'ariba::rc::SpringbootAppInstance';
            $applicationContext = $product->default('Tomcat.ApplicationContext');

        } elsif ($appType =~ /Redis/i) {

            $class = 'ariba::rc::RedisAppInstance';

        } elsif ($appType =~ /OpenCpu/i) {

            $class = 'ariba::rc::OpenCpuAppInstance';

        } elsif ($appType =~ /Selenium/i) {

            $class = 'ariba::rc::SeleniumAppInstance';

        } elsif ($appType =~ /Hadoop|Logi/i) {

            $class = 'ariba::rc::HadoopAppInstance';

        } elsif ($appType =~ /AUCSolr/i) {

            $class = 'ariba::rc::AUCSolrAppInstance';

        } elsif ($appType =~ /AUCCommunity/i) {
            $class = 'ariba::rc::AUCCommunityAppInstance';

        } else {

            $class = 'ariba::rc::WOFAppInstance';

        }

        # Divide zookeeper nodes into 3 buckets
        my $bucketCount;
        if($appName =~ m/zookeeper/i) {
            $bucketCount = 3;
        } else {
            $bucketCount = 2;
        }
        my $slot = 0;
        if($self->isLayout(5)) {
            # start at something between 1 and $bucketCount
            $slot = (($$idForCommunity - 1 + $bucketStart) % $bucketCount) + 1;
            # Look at slot names for already allocated nodes to find lowest unused slot
            # on host
            my @slotsOnHost = map { $_->instanceName() =~ m/^Node(\d+)-$instanceHost/ } @$apps;
            while(grep { $_ == $slot } @slotsOnHost) {
                $slot += $bucketCount;
            }
        }

        # make sure portnumbers are incremented respective to base port.
        my $offset = $$id - $appFlags->{$appName}->{'baseport'};

        # compute the instanceId
        my $lastOctet      = 0; 
        my $lastTwoOctets  = 0;
        my @ipAddresses    = (gethostbyname($host))[4] || (gethostbyname($host))[4]; # TMID: 77993 

        if (scalar @ipAddresses > 0 && defined $ipAddresses[0]) {
            my @octets = unpack('C4', $ipAddresses[0]);
            $lastOctet = $octets[3];
            $lastOctet = "DNSReverseLookupFailed" unless $lastOctet;
            $lastTwoOctets = $octets[2] * 256 + $octets[3];
        } else {
            $lastOctet++;
        }

        my $alias = $appFlags->{$appName}->{'alias'};
        my($instanceId, $instanceName, $workerName, $instance, $logicalName);
        if($self->isLayout(5)) {
            $instanceName = "Node$slot-$instanceHost";
            $instanceId = sprintf("1%05d%03d", $lastTwoOctets, $slot);
            $instance = $product->buildName() . "-$instanceName";
            $workerName = "Node$slot$instanceHost";
            if($class eq "ariba::rc::WOFAppInstance" || $class eq "ariba::rc::SpringbootAppInstance") {
                 $logicalName = "C" . ($community eq 'default'? 0 :($community eq 'Buyer' ? "b" : ($community eq 'Supplier' ? 's' : $community))) . "_$alias$$idForCommunity"."_$instanceId";
            } else {
                 $logicalName = "C" . ($community eq 'default' ? 0 : $community) . "_$alias$$idForCommunity";
            }
        } else {
            $instanceId = $lastOctet.$$id;
            $instanceName = "$alias-$instanceId\@$shortHost";
            $instance = $instanceName;
            $workerName = "$alias$instanceId";
        }

        # Create the object here - with the
        # appropriate instance name.
        #XXXX this should be newWithDetails()
        $appInstance = $class->new($instance);
        $appInstance->setInstanceName($instanceName);
        $appInstance->setAppName($appName);
        $appInstance->setProductName($productName);
        $appInstance->setCluster($cluster);
        $appInstance->setInstanceId($instanceId);
        $appInstance->setHost($host);
        $appInstance->setApplicationContext($applicationContext);
        $appInstance->setWorkerName($workerName);
        $appInstance->setServiceName($serviceName);
        $appInstance->setManager($self);
        $appInstance->setOrderId($$id);
        $appInstance->setCommunityId($$idForCommunity);
        $appInstance->setLogicalName($logicalName);

        if ( $productName =~ /spotbuy/i ){
            $appInstance->setMonitorUrl( '/Spotbuy/service/webresources/monitor/stats' );
        }

        # copy the app flags data to the instance.  Some of this is junk.

        while(my ($key,$val) = each %{$appFlags->{$appName}}) {
            $appInstance->setAttribute($key, $val);
        }


        my $v5BasePort = $appInstance->attribute("baseinstanceid");
        $v5BasePort += 20 * ($slot - 1);
        my $counter = 0;
        for my $basePortName ( @portNames ) {

            my $portName = $basePortName;
            $portName =~ s/^base//;
            $portName =~ s/(\w+)port$/$1Port/;

            my $basePort = $appInstance->attribute($basePortName);
            if ( $basePort ) {
                my($useThisPort, $modBase);
                if($self->isLayout(5)) {
                    if($portName =~ m/community/ or $portName =~ m/cluster/) {
                        $useThisPort = $basePort + $offset;
                        $modBase = $$id;
                    } else {
                        $useThisPort = $v5BasePort + $counter++;
                        $modBase = $$id;
                    }
                } else {
                    $useThisPort = $basePort + $offset;
                    $modBase = $useThisPort;
                }
                if ($appInstance->attribute($portName)) {
                    $useThisPort = $appInstance->attribute($portName);
                } else {
                    $appInstance->setAttribute($portName, $useThisPort);
                }
                $appInstance->deleteAttribute($basePortName);

                #
                # We need to divide the whole system into
                # two recycle groups for rolling
                # upgrade/restart
                #
                # Assign a recycle group to each appinstance
                # based on its port number. This gurantees that
                # each group has half the apps for each
                # community.
                #
                if ($portName =~ /^port$/i) {
                    my $mod = 0;
                    #
                    # our code for allocating instances has a strong tendancy
                    # to allocate instances in repeating host sequences.  Left
                    # unchecked, hosts tend to be all in bucket 0 or in bucket
                    # 1 as this code assigns A=0,B=1,C=0,D=1 over an over for
                    # the same hosts.  We use this entropy to our advantage
                    # here, by assuming that if A is 0 heavy, then B and D are
                    # 1 heavy, and C is also 0 heavy, and pick a first bucket
                    # based on the current A balance.  With s4 and buyer
                    # configs, this changes bucket allocations that leave hosts
                    # on average 85/15 skewed towards bucket 0 or bucket 1, to
                    # initial allocations that are closer to 55/45.  The better
                    # starting allocation makes the V3 swapping code work a lot
                    # less to balance the allocation.
                    #
                    # However, for personal services, where you can have just
                    # a single node of a given type, we want to not do this
                    # because our apps rely on there being a node in bucket 0
                    # sometimes.
                    #
                    if($totalCount && $totalCount > 1 && 
                      ($self->isLayout(3) || $ENV{'USE_V3_LAYOUT'})) {
                        my $type = "$productName:$serviceName:$customer:" .
                            $product->buildName() .  ":" .
                            $appInstance->appName() . ":$community";
                        my $hostkey = "$productName:$serviceName:$customer:" . 
                            $product->buildName() .
                            ":" . $appInstance->host();
                        $mod = $bucketHash->{$type};
                        unless($mod) {
                            #
                            # first app of this type, see if we start even
                            # or odd
                            #
                            my $b0 = $bucketHash->{$hostkey}->{0} || 0;
                            my $b1 = $bucketHash->{$hostkey}->{1} || 0;

                            if($b1 > $b0) {
                                $mod = ($modBase % 2) ? 1 : 2;
                            } elsif($b0 > $b1) {
                                $mod = ($modBase % 2) ? 2 : 1;
                            } else {
                                $mod = ($b1 % 2) + 1;
                            }
                            $bucketHash->{$type} = $mod;
                        }
                        $bucketHash->{$hostkey}->{($modBase+$mod) % 2}++;
                    }
                    if($self->isLayout(5)) {
                        my $bucket = ($slot - 1) % $bucketCount;
                        $appInstance->setRecycleGroup($bucket);
                    } elsif ($appName eq 'CatSearch' && $self->isLayout(4)) {
                        my $appkey = "$productName:$serviceName:$customer:" . 
                            $product->buildName() .
                            ":" . $appInstance->appName();
                        $bucketHash->{$appkey}++;
                        my $bucket = ((($bucketHash->{$appkey}-1) % 4) < 2) ? 0 : 1;
                        $appInstance->setRecycleGroup($bucket);
                    } else { 
                        $appInstance->setRecycleGroup(($modBase+$mod) % $bucketCount);
                    }
                }
            }
        }

        # Original AppInstance behavior was to return undef for
        # community if community is 'default'. Preserve that behavior.
        # To be maximally backwards compatible make sure there's no community attribute.

        if ( $community eq 'default' ) {
            $appInstance->deleteAttribute("community");
        } else {
            $appInstance->setCommunity($community);
        }

        if ($customer) {
            $appInstance->setCustomer($customer);
        }

        if (!$appInstance->exeName() or $appInstance->exeName() eq 'same') {
            $appInstance->setExeName( $appInstance->alias() );
        }
        
        # onto the stack
        push @{$apps}, $appInstance;

        $$id++;
        $$idForCommunity++;
    }
}

# Private functions:
sub _myround {
    my $float = shift;

    return $float unless ($float);

    if (($float/10) >= 0.7) {
        return int($float) + 1;
    } else {
        return int($float);
    }
}

=pod

=back

=head1 AUTHORS

Dan Sully <dsully@ariba.com>, Manish Dubey <mdubey@ariba.com>,
Alex Sandbak <asandbak@ariba.com>

=head1 SEE ALSO

ariba::rc::Product, ariba::rc::AbstractAppInstance,
ariba::rc::WebLogicAppInstance, ariba::rc::WOFAppInstance,
ariba::rc::TomcatAppInstance

=cut

1;
