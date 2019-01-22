package ariba::Ops::Startup::Springboot;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/Enode.pm#1

use strict;

use ariba::Ops::Startup::Common;
use ariba::Ops::NetworkUtils;

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
	
        next unless $instance->isSpringbootApp();

        my $appName = $instance->appName();

        my $krArgs = composeKrArguments($me, $instance, $masterPassword);
        my $jvmArgs = composeJvmArguments($me, $instance, $role, $masterPassword);
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
    my($me, $instance, $masterPassword) = @_;

    my $rotateInterval = 24 * 60 * 60; # 1 day
    my $service  = $me->service();
    my $prettyName = $instance->instanceName();
    $prettyName .= "--" . $instance->logicalName() if $instance->logicalName();

    my $krArgs = join(" ",
                   "-d",
                   "-kn $prettyName",
                   "-ko",
                   "-ks $rotateInterval",
                   "-ke $ENV{'NOTIFY'}",
                   "-kg $ENV{'NOTIFYPAGERS'}",
                   "-kk",
              );

    if ($masterPassword) {
        $krArgs .= " -km -";
    }

    if (!(ariba::Ops::ServiceController::isProductionServicesOnly($service))) {
            $krArgs .= " -kc 2";
    }

    return ($krArgs);
}

sub composeJvmArguments {
    my($me, $instance, $role, $masterPassword) = @_;

    my $exe_path = installDir($me);
    my $jre = $instance->jre();
    my $prettyName = $instance->instanceName();
    my $instanceCommunity = $instance->community() || 'default';
    my $service = $me->service();
    my $ipv4 = $me->default('Ops.PreferIPv4Stack') || '';
    my $hasRedis = $me->default('Ops.Redis.LaunchProgram') || '';
    my $config = $me->deploymentDefaults() || $me->parametersTable();

    # HACK ALERT
    # We have a race condition where the first installation of a product will not have the DD.xml/P.table
    # soft link set.  Thus $config will be foo.primary.  When this is passed on the command line to SR or GB
    # the app breaks.  Strip off the suffix.  I need to explore the core "dual config" code and figure a 
    # cleaner way to handle this.
    $config =~ s/.primary$//;
    $config =~ s/.secondary$//;

    # When read from P.table and array of args is returned.
    # When read from DD.xml a scalar with all args is returned.
    my @jvmArgsArray = ();
    @jvmArgsArray = $me->default('System.Base.ToolsDefault.JavaVMArguments');

    # for Buyer/Sprinboot, strip out the 'CompileCommand; args
    # This has no effect on the args when read from DD.xml
    @jvmArgsArray = grep(!/CompileCommand/, @jvmArgsArray);

    # This is done to flatten the args in to a scalar.
    my $jvmArgs = join( " ", @jvmArgsArray );
    $jvmArgs = ariba::Ops::Startup::Common::expandJvmArguments($me, $prettyName, $jvmArgs, $instanceCommunity);
    $jvmArgs =~ s/\@SPRINGBOOT_ROLE\@/$role/g;

    $jvmArgs .= getMemory( $me, $instance );
    $jvmArgs .= getPorts( $instance );
    $jvmArgs .= " -DnodeName=$prettyName" if $prettyName;
    $jvmArgs .= " -Dinstall.root=$exe_path";
    $jvmArgs .= " -Dspring.profiles.active=$service";
    $jvmArgs .= " -Dspring.config.location=file://$config";
    $jvmArgs .= getRedisInfo( $me ) if $hasRedis;
    $jvmArgs .= " -Djava.net.preferIPv4Stack=$ipv4" if $ipv4;
    $jvmArgs .= " -DcommunityId=$instanceCommunity";
    $jvmArgs .= " -DreadMasterPassword=true" if $masterPassword;
    $jvmArgs .= " -jar $exe_path/$jre";


    return ($jvmArgs);
}

sub getPorts {
    my $instance = shift;

    my $ajpPort = $instance->port();
    my $httpPort = $instance->httpPort();
    my $jolokiaPort = $instance->jolokiaPort();

    my $args;
    $args .= " -Dserver.port=$httpPort" if $httpPort;
    $args .= " -Dtomcat.ajp.port=$ajpPort" if $ajpPort;
    $args .= " -Dmanagement.port=$jolokiaPort" if $jolokiaPort;

    return( $args );
}

sub getRedisInfo {
    my $me = shift;

    my $cluster   = $me->currentCluster();
    my @instances = $me->appInstancesOnHostLaunchedByRoleInClusterMatchingFilter(ariba::Ops::NetworkUtils::hostname(), 'redis', $cluster );    

    # all jvm instances can make their initial connection to any redis host:port.
    # Simply use the first one in the list.
    my $instance = shift( @instances );
    my $host = $instance->host();
    my $port = $instance->port();

    return (" -DredisHost=$host:$port");
}

# The code for this subroutine is pulled from Tomcat.pm.
sub getMemory {
    my $me = shift;
    my $instance = shift;

    my $appName = $instance->appName();
    my $startHeapSize = $me->default("Ops.JVM.$appName.StartHeapSize") ||
        $me->default('Ops.JVM.StartHeapSize') ||
        $me->default('Ops.JVM.StartHeapSizeInMB') ||
        $me->default('System.Base.ToolsDefault.JavaMemoryStart');
    my $maxHeapSize = $me->default("Ops.JVM.$appName.MaxHeapSize") ||
        $me->default('Ops.JVM.MaxHeapSize') ||
        $me->default('Ops.JVM.MaxHeapSizeInMB') ||
        $me->default('System.Base.ToolsDefault.JavaMemoryMax');
    my $stackSize =  $me->default("Ops.JVM.$appName.StackSize") ||
        $me->default('Ops.JVM.StackSize') ||
        $me->default("Ops.JVM.StackSizeInMB") ||
        $me->default('System.Base.ToolsDefault.JavaStackJava');

    $startHeapSize .= 'M' if ($startHeapSize =~ /\d$/o);
    $maxHeapSize .= 'M' if ($maxHeapSize =~ /\d$/o);
    $stackSize .= 'M' if ($stackSize =~ /\d$/o);

    my $args;
    $args .= " -Xms$startHeapSize" if $startHeapSize;
    $args .= " -Xmx$maxHeapSize" if $maxHeapSize;
    $args .= " -Xss$stackSize" if $stackSize;

    return( $args );
}

1;

__END__

