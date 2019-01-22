package ariba::Ops::Startup::Enode;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/Enode.pm#1
# MODIFIED FOR HANASIM
use strict;

use File::Path;
use File::Basename;
use ariba::Ops::Startup::Common;
use ariba::Ops::ServiceController;
use ariba::rc::Utils;
use ariba::Ops::Utils;

my $envSetup = 0;

# Only do this once.
#chomp(my $arch = lc(`uname -s`));
#chomp(my $kernelName = `uname -s`);

sub setRuntimeEnv {
    my $me = shift;

    return if $envSetup;

    my $installDir = $me->installDir();

    $main::INSTALLDIR = $installDir;    # ariba::Ops::Startup::Common->setupEnvironment started to use this.

    $ENV{'JAVA_HOME'} = ariba::Ops::Startup::Common::javaHomeForProduct($me);
    $ENV{'FLUME_HOME'} = "$installDir/flume";
    $ENV{'SIM_CONF'} = "$installDir/config";
    $ENV{'ZOOKEEPER_HOME'} = "$installDir/zookeeper";
    $ENV{'FLUME_CONF_DIR'} = $ENV{'FLUME_HOME'}."/conf";
    $ENV{'TEMP'} = '/tmp';
    $ENV{'JAVA_LIB'} = 'org.apache.flume.node.Application';

    my @ldLibrary = (
        );

    my @pathComponents = (
        "$ENV{'FLUME_HOME'}/bin",
        "$ENV{'JAVA_HOME'}/bin",
        "$installDir/bin",
        );

    my @classes = (
        "$ENV{'FLUME_HOME'}",
        "$ENV{'FLUME_CONF_DIR'}",
        "$ENV{'FLUME_HOME'}/lib",
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

    return launchAppsForRole($me, $apps, $role, $community, $masterPassword);
}

sub launchAppsForRole {
    my($me, $apps, $role, $community, $masterPassword) = @_;

    my $cluster   = $me->currentCluster();

    my @responses;
    if (defined($masterPassword)) {
        push(@responses, $masterPassword);
        push(@responses, ariba::rc::Passwords::lookup('md5salt'));
    }

    my @instances = $me->appInstancesOnHostLaunchedByRoleInClusterMatchingFilter(
        ariba::Ops::NetworkUtils::hostname(), $role, $cluster, $apps);

    my @launchedInstances;
    my $ntolaunch = 0;;
    for my $instance (@instances) {
    
        my $instanceName = $instance->instance();
        my $instanceCommunity = $instance->community();
        if($instanceName =~ /enode/i){
            $ntolaunch++;
        }
        if($instanceName =~ /lbnode/i){
            #$ntolaunch =  1;
        }

        if ($instanceCommunity && $community && $instanceCommunity != $community) {
            next;
        }
        
        push (@launchedInstances, $instance) ;
        my $basedir = $me->{'defaults'}->{'config.basedir'};
        if($instanceName =~ /lbnode/i){
            $ntolaunch = $me->{'defaults'}->{'config.numdisks'};
        }
        create_dir($instanceName,$basedir, $ntolaunch);
        
        my ($progArgs, $krArgs, $jvmArgs) = composeLaunchArguments($me, $instance, $ntolaunch);
        my $prog = "$ENV{'JAVA_HOME'}/bin/java ". $jvmArgs;
        my $progToLaunch = join(' ',
                        $prog,
                        $progArgs,
                        );

        my $com = "$main::INSTALLDIR/bin/keepRunning $krArgs -kp $progToLaunch -km";
        print  "\n-------------------------- ";
        if ($main::debug) { 
                print "Will run: $com\n"; 
        } else {
                local $ENV{'JAVA_HOME'} = $me->javaHome($instance->appName());
                local $ENV{'UOPTS'} = $jvmArgs if ($jvmArgs);

                    ariba::Ops::Startup::Common::launchCommandFeedResponses($com, @responses);
        }
    }

    return @launchedInstances;
}

sub composeLaunchArguments {
    my($me, $instance, $num) = @_;

    my $rotateInterval = 24 * 60 * 60; # 1 day
    $rotateInterval =  1800, if ($me->name() =~ /hanasim/); #  Rotate file every 30 min

    my $instanceName = $instance->instance();
    #$instanceName =~ s/Enode/Enode$num/i;  
    #$instanceName =~ s/Lbnode/Lbnode$num/i;    
    my $service  = $me->service();

    my $krArgs = join(" ",
            "-d",
            "-kn $instanceName",
            "-ko",
            "-ks $rotateInterval",
            "-ke $ENV{'NOTIFY'}",
            "-kk",
            );

    if (!(ariba::Ops::ServiceController::isProductionServicesOnly($service))) {
        $krArgs .= " -kc 2";
    }
    my $inst = 'enode'.$num;
    $inst = 'lbnode' if($instanceName =~ /lbnode/i);
    my $instconf = $me->{'defaults'}->{'config.flumeconfig'};
    $instconf = $me->{'defaults'}->{'config.lbconfig'} if($instanceName =~ /lbnode/i);
    my $jmxport = $instance->jmxPort();
    my $jlkport = $instance->port();
    my $jmxauth = $me->{'defaults'}->{'jmx.authenticate'};
    my $jmxssl = $me->{'defaults'}->{'jmx.ssl'};
    my $jmxlocal = $me->{'defaults'}->{'jmx.local'};
    
    my $serverRoles = $instance->serverRoles();
    my $progArgs = ' -Dflume.root.logger=WARN,console '.'-javaagent:'.$main::INSTALLDIR.'/classes/jolokia-jvm-1.3.0-agent.jar=port='.$jlkport.',host=0.0.0.0,agentContext=/hsim ';
    #$progArgs .=  '-Dorg.jolokia.agentContext=/hsim -Dcom.sun.management.jmxremote -Dcom.sun.management.jmxremote.port=';
    $progArgs .=  '-Dcom.sun.management.jmxremote -Dcom.sun.management.jmxremote.port=';
    $progArgs .= $jmxport . ' -Dcom.sun.management.jmxremote.authenticate='.$jmxauth . ' -Dcom.sun.management.jmxremote.ssl=';
    $progArgs .= $jmxssl . ' -Dcom.sun.management.jmxremote.local.only='.$jmxlocal;
    $progArgs .= ' -cp '.$ENV{'FLUME_CONF_DIR'}.":$main::INSTALLDIR".'/classes/*'.":$main::INSTALLDIR/lib/*:"."$ENV{'FLUME_HOME'}/lib/*";
    $progArgs .= ' -Dsimulator.config='.$ENV{'SIM_CONF'}. '/'.$me->{'defaults'}->{'config.simconfig'};
    $progArgs .= ' -Djava.library.path= '. $ENV{JAVA_LIB};  
    $progArgs .= ' --conf-file '.$ENV{'SIM_CONF'}. '/'.$instconf. ' -n '.$inst;

    my $jvmArgs = ariba::Ops::Startup::Common::composeJvmArguments($me, $instance);
    $jvmArgs =~ s/\-server//;
    $jvmArgs =~ s/\"//g;
    return ($progArgs, $krArgs, $jvmArgs);
}

sub refreshConfigs {
    print "Refreshing Flume configurations\n";
    system('flume-config -refreshAll');

}


sub createDirs{
        my $me = shift;
        my $rootdir = $me->{'defaults'}->{'config.basedir'};
        $rootdir = $1 if($rootdir =~ /(.*\/)/);
        $rootdir = $1 if($rootdir =~ /(.*\/)/);
        if ($rootdir ) {
                    print "Creating directory: $rootdir\n";
                    r("mkdir -p $rootdir");
                    $rootdir .= 'Simulator';
                    print "Creating directory: $rootdir\n";
                    r("mkdir -p $rootdir");
                    print "Creating directory: $rootdir/reports\n";
                    r("mkdir -p $rootdir/reports");
                    print "Creating directory: $rootdir/zookeeper\n";
                    r("mkdir -p $rootdir/zookeeper");
        }
}


sub create_dir {
    my($instanceName,$basedir, $num) = @_;
    if($instanceName =~ /enode/i){
        $instanceName = 'ENode'.$num
    }
    else{
        $instanceName = 'LBNode';
    }
    $basedir .= $num;
    foreach my $d('data', 'channel'){
        my $dir = "$basedir/$instanceName/$d";
        if ($dir && !(-d $dir)) {
                print "Creating directory: $dir\n";
                r("mkdir -p $dir");
            }
    }
    #create addiotional symlinks to flume and zookeeper
    my @dirs = split /\//, $main::INSTALLDIR;
    #create sym link one level up.
    my $base = join '/', @dirs[0..$#dirs-1];

    ariba::Ops::Utils::updateSymlink($ENV{'FLUME_HOME'}, "$base/flume");
    ariba::Ops::Utils::updateSymlink($ENV{'ZOOKEEPER_HOME'}, "$base/zookeeper");
}


1;

__END__
