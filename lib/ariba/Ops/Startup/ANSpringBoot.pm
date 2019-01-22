package ariba::Ops::Startup::ANSpringBoot;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/Enode.pm#1

use strict;

use ariba::Ops::Startup::Common;
use ariba::Ops::NetworkUtils;

my $envSetup = 0;
my $installDir;     # make this a hash element of the class when we change this to OO design.

sub setInstallDir {
    my $me = shift;

    $installDir = $me->installDir;
    return ($installDir);
}

sub installDir {
    
    return ($installDir);
}

sub setRuntimeEnv {
    my $me = shift;

    my $installDir = setInstallDir( $me );

    $ENV{'JAVA_HOME'} = ariba::Ops::Startup::Common::javaHomeForProduct($me);
    $ENV{'TEMP'} = '/tmp';
    $ENV{'JAVA_LIB'} = 'org.apache.flume.node.Application';

    my @ldLibrary = (
        );

    my @pathComponents = (
        "$ENV{'JAVA_HOME'}/bin",
        "$installDir/bin",
        );

    my @classes = (
        );

    ariba::Ops::Startup::Common::setupEnvironment(\@ldLibrary, \@pathComponents, \@classes);

    $envSetup++;
}

sub launch {
    my $me = shift;
    my $apps = shift;
    my $role = shift;
    my $community = shift;
    my $masterPassword = shift;

    my $cluster   = $me->currentCluster();
    my @instances = $me->appInstancesOnHostLaunchedByRoleInClusterMatchingFilter(ariba::Ops::NetworkUtils::hostname(), $role, $cluster, $apps);

    setRuntimeEnv($me);

    my @launchedInstances;
    for my $instance (@instances) {
    
        my $aName = $instance->appName();
        my $sb = $instance->isSpringbootApp();

        next unless $instance->isSpringbootApp();

        my $appName = $instance->appName();
        my $instanceName = $instance->instance();

        my $krArgs = composeKrArguments($me, $instance);
        my $jvmArgs = composeJvmArguments($me, $instance);
        my $progToLaunch = " $ENV{'JAVA_HOME'}/bin/java $jvmArgs";

        my $com = "$main::INSTALLDIR/bin/keepRunning $krArgs -kp $progToLaunch";
        if ($main::debug) { 
            print  "\n-------------------------- ";
            print "Will run: $com\n"; 
        } else {
            local $ENV{'JAVA_HOME'} = $me->javaHome($instance->appName());
            local $ENV{'UOPTS'} = $jvmArgs if ($jvmArgs);
            ariba::Ops::Startup::Common::runKeepRunningCommand($com, $masterPassword);
        }

        push(@launchedInstances, $instance); 
    }

    return @launchedInstances;
}

sub composeKrArguments {
    my($me, $instance) = @_;

    my $rotateInterval = 24 * 60 * 60; # 1 day
    my $instanceName = $instance->instance();
    my $service  = $me->service();
    my $prettyName = $instanceName;
    $prettyName .= "--" . $instance->logicalName() if $instance->logicalName();
    $prettyName .= "--" . $instance->instanceId() if $instance->instanceId();

    my $krArgs = join(" ",
                   "-d",
                   "-kn $prettyName",
                   "-ko",
                   "-ks $rotateInterval",
                   "-ke $ENV{'NOTIFY'}",
                   "-kg $ENV{'NOTIFYPAGERS'}",
                   "-kk",
              );

    if (!(ariba::Ops::ServiceController::isProductionServicesOnly($service))) {
            $krArgs .= " -kc 2";
    }

    return ($krArgs);
}

sub composeJvmArguments {
    my($me, $instance) = @_;

    my $jvmArgs = $me->default('jvmargs');

    #replace the double escape char in AN jvmArgs -Dhttp.nonProxyHosts=*.ariba.com\\|*.quadrem.com with single
    $jvmArgs =~ s/\\\\/\\/g;
    my $app = $instance->appName();
    # set application specific overrides for defaults.
    my $keyName = lc($app);
    # Allow an app to completely override the jvm args
    my $overrideVMArgs = $me->default("$keyName.jvmargs");
    $jvmArgs = $overrideVMArgs if $overrideVMArgs;

    # Allow an app to append to the jvm args
    my $appendVMArgs = $me->default("$keyName.jvmargsappend");

    if ($appendVMArgs) {
        if ($jvmArgs) {
            $jvmArgs .= " $appendVMArgs";
        } else {
            $jvmArgs = $appendVMArgs;
        }
    }
    my $instanceName = $instance->instanceName();
    my $instanceCommunity = $instance->community();

    $jvmArgs = ariba::Ops::Startup::Common::expandJvmArguments($me, $instanceName, $jvmArgs, $instanceCommunity);

    my $sysProps = composeSystemProperties($me, $instance);
    $jvmArgs .= $sysProps;

    my $exe_path = $instance->jarPath();
    my $deployRoot = $ENV{'ARIBA_DEPLOY_ROOT'};
    $jvmArgs .= " -jar $deployRoot/$exe_path";

    return ($jvmArgs);
}

my %queueProducers;

sub lookupQueueProducerHostsAndPorts{
    my($me, $queueProducer) = @_;
    if (!%queueProducers) {
        my $cluster = $me->currentCluster();
        my @instances = $me->appInstancesInCluster($cluster);
        foreach my $instance (@instances) {
            my @appCategories = split(/:/,$instance->appCategories());
            if (grep {$_ eq 'QueueProducer'} @appCategories) {
                $queueProducers{$instance->appName()} .= $instance->host().':'.$instance->queuePort().',';
            }
        }
    }
    my $queueProducerHostsAndPorts = $queueProducers{$queueProducer};
    $queueProducerHostsAndPorts =~ s/(.*),$/$1/g;
    return $queueProducerHostsAndPorts;
}

sub composeSystemProperties {
    my($me, $instance) = @_;

    my $httpPort=$instance->httpPort();
    my $sysProps = " -Dserver.port=$httpPort";
    
    my $ajpPort=$instance->port();
    $sysProps .= " -Dtomcat.ajp.port=$ajpPort";
    
    if (defined $instance->transportPort()) {
    	my $transportPort=$instance->transportPort();
    	$sysProps .= " -DTransportListenerPort=$transportPort";
    }

    my @appCategories = split(/:/,$instance->appCategories());
    if (!grep {$_ eq 'Test'} @appCategories)
    {
        my $jolokiaPort = $instance->jolokiaPort();
        $sysProps .= " -Dmanagement.port=$jolokiaPort" if $jolokiaPort;
    }
    
    my $app=$instance->appName();
    my $queueProducerHostsAndPorts;
    if (grep {$_ eq 'QueueProducer'} @appCategories) {
        my $queuePort = $instance->queuePort();
        my $queueHost = $instance->host();
        $sysProps .= " -Dqueue.hostPort=$queueHost:$queuePort" if $queuePort;

        $queueProducerHostsAndPorts = lookupQueueProducerHostsAndPorts($me, $app);
        $sysProps .= " -Dqueue.servers=$queueProducerHostsAndPorts" if $queueProducerHostsAndPorts;
    }

    for my $queueProducer (@appCategories) {
        next unless $queueProducer =~ m/QueueConsumer$/;
        $queueProducer =~ s/(.*)Consumer$/$1/g;
        $queueProducerHostsAndPorts = lookupQueueProducerHostsAndPorts($me, $queueProducer);
        $sysProps .= " -Dqueue.servers=$queueProducerHostsAndPorts" if $queueProducerHostsAndPorts;
    }

    #jvmRoute of tomcat instance should match the worker name in mod_jk
    #for sticky_session in load balancer
    my $jvmRoute=$instance->workerName();
    $sysProps .= " -DjvmRoute=$jvmRoute";
    $sysProps .= " -DAppName=$app";
    if (defined $instance->alias()) {
        my $alias = $instance->alias();
        $sysProps .= " -DAppNameAlias=$alias";
    }


    my $prodname = $ENV{'ARIBA_PRODUCT'} = uc($me->name());
    $sysProps .= " -DProduct=$prodname";
    my $instanceName=$instance->instanceName();
    $sysProps .= " -DOps.Stopsvc=$instanceName";
    if (defined $instance->attribute('communityClusterEnabled') &&
        $instance->attribute('communityClusterEnabled') eq 'yes') {
        $sysProps .= " -DCommunityClusterEnabled=true";
    }
    
    my $instanceCommunity=$instance->community();
    if (defined $instanceCommunity) {
        $sysProps .= " -DCommunity=$instanceCommunity";
    }
   
    my $instanceId=$instance->instanceId();
    $sysProps .= " -DInstanceID=$instanceId";
    my $aribaSecurityProperties = $me->default("Ops.AribaSecurityProperties");
    if ($aribaSecurityProperties) {
        $sysProps .= " -Djava.security.properties=file:${aribaSecurityProperties}";
    }
    # allow super user access to apps via admin server
    if ($instance->launchedBy() eq "anspringbootadminapps") {
       $sysProps .= " -DSuperUser=yes";
    }


    my $appleRoot = $ENV{'NEXT_ROOT'};
    $sysProps .= " -DreadMasterPassword=YES";
    $sysProps .= " -DWORootDirectory=$appleRoot";

    my $arguments = $instance->arguments();
    if (defined $arguments) {
        $sysProps .= " $arguments";
    }

    return ($sysProps); 
}
1;

__END__

