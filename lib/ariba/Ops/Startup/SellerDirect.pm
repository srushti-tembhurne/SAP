package ariba::Ops::Startup::SellerDirect;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/SellerDirect.pm#1

use strict;

use ariba::Ops::Startup::Common;
use ariba::Ops::NetworkUtils;

my $envSetup = 0;
my $installDir;     # make this a hash element of the class when we change this to OO design.

sub printError {
    my $errorCode = shift;
    my $name = shift;
    my $errorString = shift;
    my $refreshBundleDA = shift;

    print "failed\n";
    print "WARN: could not notify $name about the new publish bundle.  This is non-blocking.\n";
    print "You need to manually tell $name to load the bundle.  See https://wiki.ariba.com:8443/pages/viewpage.action?pageId=20480175\n";
    print "$errorCode,  String: $errorString\n";
}

sub refreshBundle {
	print "> SellerDirect.pm refreshBundle() \n";
    #
    # Call Direct action via arches front door
    # Print message if refreshBundle was successful or not
    #
    my $service = shift;
    return unless (ariba::rc::InstalledProduct->isInstalled('arches', $service));
    my $arches = ariba::rc::InstalledProduct->new('arches', $service);
    my $url = $arches->default('VendedUrls.FrontDoorTopLevel');
    my $refreshBundleDA = $url . "/Arches/api/refreshBundle/ariba.sellerdirect";

    my $refreshBundleUrl = ariba::Ops::Url->new($refreshBundleDA);
    $refreshBundleUrl->setTimeout(60);
    $refreshBundleUrl->setUseOutOfBandErrors(1);
    my $xml = $refreshBundleUrl->request();

    print "\n";
    print "Informing " . $arches->name() . " about the publish bundle refresh: ";

    my $errorString = $refreshBundleUrl->error();
	print "\n";
	if ($errorString ne '') {
		print "Error String - >$errorString< \n";
	}
	
	my ($value ) = $xml =~ m|<response>(.*)</response>|;
	if ($value eq "OK") {
		print "Bundle was refreshed for product " . $arches->name() . "\n";
	} else {
		print "Success string 'OK' not found in xml:\n--- Start XML ---\n$xml\n---- End XML ----\n";
		print "refreshBundleUrl - $refreshBundleUrl \n";
		print "You may need to manually refresh the bundle via $refreshBundleDA\n";
	}
	
    print "\n";
    return 1;
}

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

    my $cluster   = $me->currentCluster();
    my @instances = $me->appInstancesOnHostLaunchedByRoleInClusterMatchingFilter(ariba::Ops::NetworkUtils::hostname(), $role, $cluster, $apps);

    setRuntimeEnv($me);

    my @launchedInstances;
    for my $instance (@instances) {
        my $appName = $instance->appName();

		my $masterPassword = ariba::rc::Passwords::lookup("master");
        my $krArgs = composeKrArguments($me, $instance, $masterPassword);
        my $jvmArgs = composeJvmArguments($me, $instance);
	    my $progToLaunch = " $ENV{'JAVA_HOME'}/bin/java $jvmArgs";
        my $com = "$main::INSTALLDIR/bin/keepRunning $krArgs -kp $progToLaunch";
		
		my @responses;
        push(@responses, $masterPassword);
        push(@responses, ariba::rc::Passwords::lookup('md5salt'));
		
        if ($main::debug) { 
		    print  "\n-------------------------- ";
        	print "Will run: $com\n"; 
        } else {
            local $ENV{'JAVA_HOME'} = $me->javaHome($instance->appName());
            local $ENV{'UOPTS'} = $jvmArgs if ($jvmArgs);
            ariba::Ops::Startup::Common::runKeepRunningCommand($com, @responses);
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

    if (!(ariba::Ops::ServiceController::isProductionServicesOnly($service))) {
            $krArgs .= " -kc 2";
    }
	
	if ($masterPassword) {
		$krArgs .= " -km -";
	}

    return ($krArgs);
}

sub composeJvmArguments {
    my($me, $instance) = @_;

    my $exe_path = installDir($me);
    my $jre = $instance->jre();
    my $prettyName = $instance->instanceName();
    my $instanceCommunity = $instance->community();

    # hard coded for P.table which returns an array.  (DD.xml would return a scalar)
    my @jvmArgsArray = $me->default('System.Base.ToolsDefault.JavaVMArguments');

    # for Sprinboot, strip out the 'CompileCommand; args
    @jvmArgsArray = grep(!/CompileCommand/, @jvmArgsArray);

    my $jvmArgs = join( " ", @jvmArgsArray );
    $jvmArgs = ariba::Ops::Startup::Common::expandJvmArguments($me, $prettyName, $jvmArgs, $instanceCommunity);

    $jvmArgs .= getMemory( $me, $instance );
    $jvmArgs .= getPorts( $instance );
	$jvmArgs .= " -DreadMasterPassword=true";
    $jvmArgs .= " -DnodeName=$prettyName" if $prettyName;
    $jvmArgs .= " -Dinstall.root=$exe_path";
    $jvmArgs .= " -jar $exe_path/wars/SellerDirect.war";

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

