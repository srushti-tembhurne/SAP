package ariba::Ops::Startup::OSGI;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/OSGI.pm#17 $

use strict;

use File::Path;
use File::Basename;
use ariba::Ops::Startup::Common;
use ariba::Ops::ServiceController;
use ariba::rc::Utils;
use ariba::rc::Globals;

my $envSetup = 0;

# Only do this once.
chomp(my $arch = lc(`uname -s`));
chomp(my $kernelName = `uname -s`);

sub setRuntimeEnv {
    my $me = shift;
    my $force = shift;

    return if $envSetup && !$force;

    my $tomcatHome = $me->tomcatHome();
    $ENV{'JAVA_HOME'} = ariba::Ops::Startup::Common::javaHomeForProduct($me);

    my @ldLibrary = (
        "$main::INSTALLDIR/lib/$kernelName",
        "$main::INSTALLDIR/internal/lib/$kernelName",
        );
       
    my @pathComponents = (
        "$ENV{'JAVA_HOME'}/bin",
        "$ENV{'ORACLE_HOME'}/bin",
        "$main::INSTALLDIR/bin",
        "$main::INSTALLDIR/internal/bin",
        );

    # maybe open $installDir/base/classes/classpath.txt and
    # add them to the class path.   For now hope
    # that installdir/base/classes will do

    my @classes = (
        "$main::INSTALLDIR/lib",
    );

    ariba::Ops::Startup::Common::setupEnvironment(\@ldLibrary, \@pathComponents, \@classes);

    chdir("$main::INSTALLDIR") || die "ERROR: could not chdir to $main::INSTALLDIR, $!\n";

    $envSetup++;
}

sub _launch {
    my $me = shift;
    my $webInfSubDir = shift;
    my $apps = shift;
    my $role = shift;
    my $community = shift;
    my $updateConfigFile = shift;
    my $masterPassword = shift;
    my $appArgs = shift || "";
    my $additionalAppParamsHashRef = shift;

    ariba::Ops::Startup::OSGI::setupOSGIForAppInstances($me, $role, $apps, $webInfSubDir);

    ariba::Ops::Startup::Common::prepareHeapDumpDir($me);

    return ariba::Ops::Startup::OSGI::launchAppsForRole($me, $apps, $appArgs, $role, $community, $updateConfigFile, $masterPassword, $additionalAppParamsHashRef);

}

sub launch {
    my $me = shift;
    my $webInfSubDir = shift;
    my $apps = shift;
    my $role = shift;
    my $community = shift;
    my $masterPassword = shift;
    my $appArgs = shift || "";
    my $additionalAppParamsHashRef = shift;

    return ariba::Ops::Startup::OSGI::_launch($me, $webInfSubDir, $apps, $role, $community, 0, $masterPassword, $appArgs, $additionalAppParamsHashRef);

}

sub setupOSGIForAppInstances {
    my $me = shift;
    my $role = shift;
    my $apps = shift;
    my $webInfSubDir = shift;

    my $installDir = $me->installDir();
    my $productName = $me->name();
    my $configDir = $me->configDir();
    my $applicationContext = $me->default('Tomcat.ApplicationContext');
    my $cluster   = $me->currentCluster();

    my @appInstances = $me->appInstancesOnHostLaunchedByRoleInClusterMatchingFilter(ariba::Ops::NetworkUtils::hostname(),$role,$cluster,$apps);

    my $baseRoot = $me->default('Tomcat.Base');

    for my $appInstance (@appInstances) {
        my $name = $appInstance->instance();
        my $tomcatBaseDir = "$baseRoot/$name";

        my $logs = "$tomcatBaseDir/logs";
        my $tmp = "$tomcatBaseDir/temp";
        my $work = "$tomcatBaseDir/work";
        my $conf = "$tomcatBaseDir/conf";
        my $lib = "$tomcatBaseDir/lib";
        my $repository = "$tomcatBaseDir/repository";
        my $configDir = "$tomcatBaseDir/config";

        #
        # Create sparse tree that will correspond to TOMCAT_BASE
        #
        rmdirRecursively($tomcatBaseDir);
        for my $dir ($logs, $tmp, $work, $conf ) {
            unless (-d $dir) {
                #FIXME
                # this makes $tomcatBaseDir and down owned by current
                # service user; need to fix permissions to allow
                # other service users to create their own
                # $tomcatBaseDir
                mkpath($dir) || die "ERROR: failed to create $dir: $!";
            }
        }

        #
        # create symlinks to lib, repository, and config
        #
        my $src = "$main::INSTALLDIR/lib";
        my $dest = $lib;
        unless (symlink($src, $dest)) {
            #
            # Make sure no one else created this symlink
            # in parallel.
            #
            my $failureMsg = $!;
            unless (-e $dest) {
                print "Error: Could not create symlink $dest to $src, $failureMsg\n";
            }
        }

        $src = "$main::INSTALLDIR/repository";
        $dest = $repository;
        unless (symlink($src, $dest)) {
            #
            # Make sure no one else created this symlink
            # in parallel.
            #
            my $failureMsg = $!;
            unless (-e $dest) {
                print "Error: Could not create symlink $dest to $src, $failureMsg\n";
            }
        }

        $src = "$main::INSTALLDIR/config";
        $dest = $configDir;
        unless (symlink($src, $dest)) {
            #
            # Make sure no one else created this symlink
            # in parallel.
            #
            my $failureMsg = $!;
            unless (-e $dest) {
                print "Error: Could not create symlink $dest to $src, $failureMsg\n";
            }
        }
                 
        $appInstance->setTomcatBase($tomcatBaseDir);
        $appInstance->setApplicationContext($applicationContext);

        #
        # create tomcat server configuration file
        #
        my $templateServerXml = "$configDir/tomcat-server.xml";
        my $generatedServerXml = "$conf/tomcat-server.xml";

        generateServerConfigurationFileForAppInstance($me, $appInstance,
                $templateServerXml, $generatedServerXml);
        #
        # Cheat, set some useful attributes on appInstance
        #
        $appInstance->setServerConfigurationFile($generatedServerXml);
        
        $templateServerXml = "$configDir/serviceability.xml";
        $generatedServerXml = "$conf/serviceability.xml";

        generateServerConfigurationFileForAppInstance($me, $appInstance,
                $templateServerXml, $generatedServerXml);
    }

    return @appInstances;
}

sub generateServerConfigurationFileForAppInstance {
    my $me = shift;
    my $appInstance = shift;
    my $templateConfig = shift;
    my $generatedConfig = shift;

    #
    # read in template config. populate the tokens and write it
    # back out
    #

    open(TMPL, $templateConfig) || die "Error: could not read template tomcat config file, $templateConfig, $!\n";
    sysread(TMPL, my $confString, -s TMPL);
    $confString =~ s/\r//g;
    close(TMPL);

    my $config;

    #
    # Initialize set of tokens that we might replace
    #
    $config->{HOST} = $appInstance->host();
    $config->{PORT} = $appInstance->port();
    $config->{HTTPPORT} = $appInstance->httpPort();
    $config->{SHUTDOWNPORT} = $appInstance->shutdownPort();
    $config->{WORKERNAME} = $appInstance->workerName();
    $config->{APPLICATIONCONTEXT} = $appInstance->applicationContext();

    #
    # Should the HttpOnly flag be set on session cookies to prevent
    # client side script from accessing the session ID?
    #
    $config->{USEHTTPONLYCOOKIES} = $me->default('Ops.Servercfg.UseHttpOnlySessionCookies');

    for my $from (sort (keys(%$config))) {

        my $to = $config->{$from};

        # Token can be an empty string.
        next unless defined $to;

        $to =~ s/^\s*//g;
        $to =~ s/\s*$//g;
# We will support both * and @ for these tokens for now, but @ is the new standard
        $confString =~ s/\*$from\*/$to/g;
        $confString =~ s/\@$from\@/$to/g;
    }

    chmod (0644, $generatedConfig);
    open(CONF, "> $generatedConfig") || die "Could not write config file $generatedConfig, $!\n";
    print CONF $confString;
    close(CONF);

    return $confString;
}

#
# For code based on platform version < jupiter that
# did not support passing P.t values via command line,
# call this routine with updateConfigFile == 1
#
sub launchAppsForRole {
    my($me, $apps, $appArgs, $role, $community, $updateConfigFile, $masterPassword, $additionalAppParamsHashRef) = @_;

    my $cluster   = $me->currentCluster();
    my $rotateInterval = 24 * 60 * 60; # 1 day
    my $delayInSec = 5;

    my @instances = $me->appInstancesOnHostLaunchedByRoleInClusterMatchingFilter(ariba::Ops::NetworkUtils::hostname(),$role,$cluster,$apps);

    my @launchedInstances;
    for my $instance (@instances) {

        my $instanceName = $instance->instance();

        my $instanceCommunity = $instance->community();

        if ($instanceCommunity && $community && $instanceCommunity != $community) {
            next;
        }
        
        push (@launchedInstances, $instance) ;

        my ($progArgs, $krArgs, $jvmArgs, $osgiArgs, $parametersRef) = composeLaunchArguments($me, $instance, $masterPassword, $additionalAppParamsHashRef);

        my $tomcatConfigFile = $instance->serverConfigurationFile();
        my %parameters  = %$parametersRef;

        #
        # All node specific properties are under:
        #
        # System.Nodes.Node<#>.Host
        # System.Nodes.Node<#>.Port
        # System.Nodes.Node<#>.InterNodePort
        # System.Nodes.Node<#>.ClassName
        # System.Nodes.Node<#>.ApplicatonServer
        #
        # When specified on command line in conjunction with
        # -nodename <Nodeid> these change to:
        #
        # System.Node.Host
        # System.Node.Port
        #
        # and so on...
        #

        #
        # Form ariba app related command line options
        #
        my $allArgs = "";

        for my $arg (keys(%parameters)) {
            $allArgs .= " -D$arg=$parameters{$arg}";
        }

        my $progToLaunch = join(" ",
                $me->javaHome($instance->appName()) . "/bin/java",
                $jvmArgs,
                $allArgs,
                "-DAriba.CommandLineArgs=\\\"$progArgs $appArgs\\\"",
                "org.eclipse.virgo.osgi.launcher.Launcher",
                "-config $main::INSTALLDIR/lib/org.eclipse.virgo.kernel.launch.properties",
                $osgiArgs,
                );

        my $prodname = $me->name();
        if ( grep {"$prodname" eq $_} ariba::rc::Globals::archesProducts() ) {

            # in the arches case, we want to remove the repository caches 
            # (usr.index and ext.index) that are under the work directory 
            # before any retry done by keepRunning.  As a result, instead
            # of directly passing in progToLaunch, we pass in a wrapper
            # script that does the removal as well as startup.  

            my $installDir = $me->installDir();
            my $baseRoot = $me->default('Tomcat.Base');
            my $tomcatBaseDir = "$baseRoot/$instanceName";
            my $workDir = "$tomcatBaseDir/work";
            $progToLaunch = "$main::INSTALLDIR/bin/startarches.sh $workDir $progToLaunch";
        }

        my $com = "$main::INSTALLDIR/bin/keepRunning $krArgs -kp $progToLaunch";
        if (defined($masterPassword)) {
            ariba::Ops::Startup::Common::launchCommandFeedResponses($com, $masterPassword, "");
        } else {
            ariba::Ops::Startup::Common::runKeepRunningCommand($com);
        }
        sleep($delayInSec);
    }

    return @launchedInstances;
}

sub composeLaunchArguments {
    my($me, $instance, $masterPassword, $additionalAppParamsHashRef) = @_;

    my $launched  = 0;
    my $cluster   = $me->currentCluster();
    my $rotateInterval = 24 * 60 * 60; # 1 day

    my $instanceName = $instance->instanceName();
       my $nodeName;
       if ($me->isLayout(5)) {
               $nodeName = $instance->logicalName();
       }
       else {
           $nodeName = $instance->workerName();
       }

    my $service  = $me->service();

    #
    # Community related stuff
    #
    my $instanceCommunity = $instance->community();
    my $numCommunities = $me->numCommunities();
    my @appInstances = $me->appInstances();
    my $totalAppInstances = scalar(@appInstances);
    my $numInstancesInCommunity = 0;
    if ($numCommunities) {
        #
        # instanceCommunity can be undef, make it be 0 so
        # we dont get perl warns in compare below
        #
        my $matchComm = $instanceCommunity || 0;
        for my $inst (@appInstances) {
            my $comm = $inst->community() || 0;
            if ($comm == $matchComm) {
                $numInstancesInCommunity++;
            }
        }
    }

    my %parameters  = ();
    if (defined $additionalAppParamsHashRef) {
        %parameters = %$additionalAppParamsHashRef;
    }

    #
    # All node specific properties are under:
    #
    # System.Nodes.Node<#>.Host
    # System.Nodes.Node<#>.Port
    # System.Nodes.Node<#>.InterNodePort
    # System.Nodes.Node<#>.ClassName
    # System.Nodes.Node<#>.ApplicatonServer
    #
    # When specified on command line in conjunction with
    # -nodename <Nodeid> these change to:
    #
    # System.Node.Host
    # System.Node.Port
    #
    # and so on...
    #
    $parameters{"System.Nodes.$nodeName.ClassName"} = "ariba.base.server.Node";
    $parameters{"Ariba.Nodename"} = $nodeName;

    if (defined $instance->rpcPort()) {
        $parameters{"System.Nodes.$nodeName.Port"} = $instance->rpcPort();
    } 

    if (defined $instance->httpPort()) {
        $parameters{"System.Nodes.$nodeName.HttpPort"} = $instance->httpPort();
    }

    if (defined $instance->internodePort()) {
        $parameters{"System.Nodes.$nodeName.InterNodePort"} = $instance->internodePort();
    } 
    if (defined $instance->host()) {
        $parameters{"System.Nodes.$nodeName.Host"} = $instance->host();
    } 
    if (defined $instance->jmxPort()) {
        $parameters{"com.sun.management.jmxremote.port"} = $instance->jmxPort();
    }
    $parameters{"com.sun.management.jmxremote.authenticate"} = "true";
    $parameters{"com.sun.management.jmxremote.login.config"} = "dm-kernel";
    $parameters{"com.sun.management.jmxremote.access.file"} = "$main::INSTALLDIR/config/org.eclipse.virgo.kernel.jmxremote.access.properties";
    $parameters{"com.sun.management.jmxremote.ssl"} = "true";
    $parameters{"com.sun.management.jmxremote.ssl.need.client.auth"} = "false";
    $parameters{"java.security.auth.login.config"} = "$main::INSTALLDIR/config/org.eclipse.virgo.kernel.authentication.config";
    $parameters{"org.eclipse.virgo.kernel.authentication.file"} = "$main::INSTALLDIR/config/org.eclipse.virgo.kernel.users.properties";
    if (defined $instance->serverRoles()) {
        my $roleString = $instance->serverRoles();
        $roleString =~ s/\|/,/g;

        $parameters{"System.Nodes.$nodeName.ServerRole"} = "\'\($roleString\)\'";
        unless ($numCommunities) {
            my @similarInstances = $me->appInstancesWithNameInCluster($instance->appName(), $cluster);
            my $numNodes = scalar(@similarInstances);
            $parameters{"System.RealmAffinity.ExpectedNumberOfNodes"} = $numNodes;
        }
    } 
    #
    #
    # If the instance belongs to a community, we need to specify
    # community id and the multicast ip group that it should be part of
    #
    if ($numCommunities) {
        $parameters{'.Ariba.NumCommunities'} = $numCommunities;

        if (defined $instanceCommunity) {
            $parameters{'.Ariba.CommunityID'} = $instanceCommunity;
        }  else {
            $parameters{'.Ariba.CommunityID'} = 0;
        }
    }

    createTopologyFile($me, $instance, \%parameters);

    my $tomcatBase = $instance->tomcatBase();
    my $tomcatHome = $me->tomcatHome();

    my $prettyName = $instanceName;
    $prettyName .= "--" . $instance->logicalName() if $instance->logicalName();


    # kr options
    my $krArgs = join(" ",
            "-d",
            "-kn $prettyName",
            "-ko",
            "-ks $rotateInterval",
            "-ke $ENV{'NOTIFY'}",
            "-kk",
            "-kf",
            );

    if (!(ariba::Ops::ServiceController::isProductionServicesOnly($service))) {
        $krArgs .= " -kc 2";
    }

    if ( grep  { $me->name() eq $_ } (ariba::rc::Globals::sharedServiceSourcingProducts(), ariba::rc::Globals::sharedServiceBuyerProducts(), ariba::rc::Globals::archesProducts(), "s2", "sdb", "help") ) {
        $krArgs .= " -kb";
    }

    #
    # Form ariba app related command line options
    #
    my $progArgs = "";

    if ($masterPassword) {
        $progArgs .= " -readMasterPassword";
        $krArgs .= " -km -";
    }

    $parameters{"org.eclipse.virgo.kernel.home"} = $tomcatBase;
    #
    # Form the command to launch VM
    #
    my $appName = $instance->appName();
    my $startHeapSize = $me->default("Ops.JVM.$appName.StartHeapSize") || 
        $me->default('Ops.JVM.StartHeapSize') ||
        $me->default('JVM.StartHeapSizeInMB');
    my $maxHeapSize = $me->default("Ops.JVM.$appName.MaxHeapSize") ||
        $me->default('Ops.JVM.MaxHeapSize') ||
        $me->default('JVM.MaxHeapSizeInMB');
    my $stackSize = $me->default("Ops.JVM.$appName.StackSize") || 
        $me->default('Ops.JVM.StackSize')  ||
        $me->default('JVM.StackSizeInMB');
    
    $startHeapSize .= 'M' if ($startHeapSize =~ /\d$/o);    
    $maxHeapSize .= 'M' if ($maxHeapSize =~ /\d$/o);    
    $stackSize .= 'M' if ($stackSize =~ /\d$/o);    

    my $startSize = $startHeapSize;
    $startSize =~ s/m$//i;
    $startSize *= 1024 if ($startSize =~ s/g$//i);

    my $newSize;
    if ($startSize >= 512) {
        $newSize = "384M";
    } else {
        $newSize = $startSize/2 . "M";
    }

    #
    # Debug param for JVM for remote debugging
    #
    my $debugPort = $ENV{'ARIBA_JVM_DEBUG_PORT'} || "";

    #
    # Allow for just an offset to be specified in case there
    # are multiple instances on the same machine. Offset is
    # applied to the port (derived from BasePort in appflags).
    # So for ex:
    #
    # setenv ARIBA_JVM_DEBUG_PORT_OFFSET 500
    #
    # will add 500 to port for each instance
    #
    my $debugPortOffset = $ENV{'ARIBA_JVM_DEBUG_PORT_OFFSET'};
    if ($debugPortOffset) {
        $debugPort = $instance->port() + $debugPortOffset;
    }

    my $debugOpts = "-Xdebug -Xnoagent -Xrunjdwp:transport=dt_socket,server=y,suspend=n,address=$debugPort";
    my $jvmDebugOpts = "";

    if ($debugPort && !(ariba::Ops::ServiceController::isProductionServicesOnly($service))) {
        $jvmDebugOpts = $debugOpts;
    }

    my $additionalSpecifiedVmArgs = $me->default('Ops.JVM.Arguments') || $me->default('JVM.VMArguments');
    my $additionalVmArgs = "";

    #
    # additional jvm args specified in P.table come back as an array,
    # but if specified in DD.xml (help product) come back as a string.
    # handle both cases.
    #
    if ($additionalSpecifiedVmArgs) {
        if (ref($additionalSpecifiedVmArgs) eq "ARRAY") {
            if (@$additionalSpecifiedVmArgs) {
                $additionalVmArgs = join(" ", @$additionalSpecifiedVmArgs);
            }
        } else {
            $additionalVmArgs = $additionalSpecifiedVmArgs;
        }
    }
    
    unless ($additionalVmArgs) {
        $additionalVmArgs = join(" ",
                    "-XX:MaxPermSize=128M",
                    "-XX:NewSize=$newSize",
                    "-XX:MaxNewSize=$newSize",
                    "-XX:SurvivorRatio=1",
                    );
    }

    #
    # if one of this signal is set to USR2, then we need to tell vm
    # to use a different Signal for its internal use.
    #
    # TMID: 23858
    #
    my $graceFulSig = $me->default('System.Shutdown.Signals.GracefulShutdown');
    my $forceSig = $me->default('System.Shutdown.Signals.ForcefulShutdown');

    my $useAltSignal = 0;
    my @shutdownSignals = ();

    for my $signal ($graceFulSig, $forceSig) {
        if ($signal) {
            my @sigArray;

            #
            # DD.xml does not have a good way to represent arrays; expect
            # a comma-delimited string in that case

            if (ref($signal) ){  # P.table case
                @sigArray = @$signal;

            } else {  # DD.xml case
                @sigArray = split(/,/, $signal);
            }

            push(@shutdownSignals, @sigArray);
        }
    }

    for my $sig (@shutdownSignals) {
        if ($sig eq "USR2") {
            $useAltSignal = 1;
            last;
        }
    }

    if ($useAltSignal) {
        if ($arch eq "sunos") {
            $additionalVmArgs .= " -XX:+UseAltSigs";
        } elsif ($arch eq "linux") {
            $ENV{'_JAVA_SR_SIGNUM'} = 50;
        }
    }

    my $aribaSecurityProperties = $me->default("Ops.AribaSecurityProperties");
    if ($aribaSecurityProperties) {
        $additionalVmArgs .= " -Djava.security.properties=file:${aribaSecurityProperties}";
    }

    my ($tomcatEndorsed, $installRootEndorsed, $endorsedDirs);
    $tomcatEndorsed = "$tomcatHome/common/endorsed";
    if ($me->isASPProduct()) {
        $installRootEndorsed = "$main::INSTALLDIR/base/classes/endorsed";
    } else {
        $installRootEndorsed = "$main::INSTALLDIR/classes/endorsed";
    }
    $endorsedDirs = "$installRootEndorsed:$tomcatEndorsed";    

    my $osgiArgs = join(" ", 
        "-Forg.eclipse.virgo.kernel.home=$tomcatBase",
        "-Forg.eclipse.virgo.kernel.config=$main::INSTALLDIR/config",
        "-Fosgi.configuration.area=$tomcatBase/work/osgi/configuration",
        "-Fosgi.java.profile=file:$main::INSTALLDIR/lib/java6-server.profile",
        "-Forg.eclipse.virgo.medic.log.config.path=$tomcatBase/conf/serviceability.xml",
        "-Forg.eclipse.gemini.web.tomcat.config.path=$tomcatBase/conf/tomcat-server.xml");
    
    my $jvmArgs = join(" ",
        "-server",
        "-Xms$startHeapSize",
        "-Xmx$maxHeapSize",
        "-Xss$stackSize",
        ariba::Ops::Startup::Common::expandJvmArguments($me,$prettyName, $additionalVmArgs),
        $jvmDebugOpts,
        "-Duser.home=$tomcatBase",
        "-Djava.util.prefs.userRoot=$tomcatBase",
        "-Djava.util.prefs.systemRoot=$tomcatBase",
    );

    return ($progArgs, $krArgs, $jvmArgs, $osgiArgs, \%parameters);
}

sub createTopologyFile {
    my ($me, $instance, $parameters) = @_;

    my $topologyFile = $instance->tomcatBase() . "/Topology.xml";

    $parameters->{'Ariba.Topology'} = $topologyFile;

    open(F, "> $topologyFile") || die "Could not create topology file: $!";

    print F "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n";
    print F "<topology>\n";

    my @instances = $me->appInstancesInCluster($me->currentCluster());

    my @instanceNames = ();
    my %instances = ();
    for my $instance (@instances) {
        if(defined($instance->serverRoles())) {

                my $instanceName;
                if($me->isLayout(5)) {
                $instanceName = $instance->logicalName();
                } else {
                $instanceName = $instance->workerName();
                }
                $instances{$instanceName} = $instance;
                push @instanceNames, $instanceName;
	

        }
    }
    @instanceNames = sort(@instanceNames);

    my $instanceNum = 0;
    foreach my $instanceName (@instanceNames) {
        my $instance = $instances{$instanceName};

        print F "    <node id=\"$instanceNum\" name=\"$instanceName\"";
        print F ' host="' . $instance->host() . '"';
        print F ' port="' . $instance->httpPort() . '"';
        print F ' jmxPort="' . $instance->jmxPort() . '"';
        my $roles = $instance->serverRoles();
        $roles =~ s/\|/\,/g;
        print F ' qmPort="' . $instance->queuemgrPort() . '"' if $roles =~ m/queuemanager/i;
        print F " roles=\"$roles\"";
        print F ' recycleGroup="' . $instance->recycleGroup() . '"';
        print F " />\n";
        $instanceNum++;
    }

    print F "</topology>\n";
    close(F);
}

1;

__END__
