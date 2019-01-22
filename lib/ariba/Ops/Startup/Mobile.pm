package ariba::Ops::Startup::Mobile;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/Mobile.pm#1

use strict;

use Data::Dumper;
use File::Path;
use File::Basename;
use ariba::Ops::Startup::Common;
use ariba::Ops::ServiceController;
use ariba::rc::Utils;
use ariba::rc::Passwords;

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
    $ENV{'TEMP'} = '/tmp';

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

sub printTopology {
    my($me) = @_;
    my @allInstances = $me->appInstancesInCluster($me->currentCluster());
    # print Dumper(@allInstances);

    my $f = "$main::INSTALLDIR/topology.txt";
    open(my $file, '>', $f) or die "Could not open file $f at $!";
    print $file "[\n";
    foreach (@allInstances) {
        my $instance = $_;

        my $app = $instance->appName;
        my $name = $instance->instanceName;
        my $host = $instance->host;
        my $iid = $instance->instanceId;
        my $port = $instance->port;
        my $http = $instance->httpPort;
        my $jmx = $instance->jmxPort;
        my $debug = $instance->debugPort;
        my $peer = $instance->zkpeerPort;
        my $leader = $instance->zkleaderPort;

        print $file "['$app', '$name', '$host', $iid, $port, $http, $jmx, $debug, $peer, $leader],\n";
    }

    print $file "]";
    close $file;

    return $f;
}

sub launch {
    my($me, $apps, $role, $community) = @_;

    my $cluster   = $me->currentCluster();
    my $topologyDir = printTopology($me);

    my @instances = $me->appInstancesOnHostLaunchedByRoleInClusterMatchingFilter(ariba::Ops::NetworkUtils::hostname(), $role, $cluster, $apps);
    #print Dumper(@instances);

    my @launchedInstances;

    for my $instance (@instances) {

        my $instanceName = $instance->instanceName();
        my $instanceCommunity = $instance->community();

        if ($instanceCommunity && $community && $instanceCommunity != $community) {
            next;
        }

        my $krArgs = composeKrArguments($me, $instance);

        $role =~ s/mobile-//;
        my $startup = "$main::INSTALLDIR/$role/bin/start.sh $topologyDir $instanceName";
        my $cmdLine = `$startup`;
        chomp($cmdLine);
        print "start: $startup cmdLine: $cmdLine\n";
        my $fullCmd;
        if ($role eq "nginx") {
            $fullCmd = "$cmdLine";
        } else {
            $fullCmd = "$main::INSTALLDIR/bin/keepRunning $krArgs -km - -kp $cmdLine";
        }

        my $masterPassword = ariba::rc::Passwords::lookup("master");
        my @responses;
        push(@responses, $masterPassword);
        ariba::Ops::Startup::Common::launchCommandFeedResponses($fullCmd, @responses);
    }

    return @launchedInstances;
}

sub composeKrArguments {
    my($me, $instance) = @_;

    my $rotateInterval = 24 * 60 * 60; # 1 day

    my $instanceName = $instance->instance();
    my $service  = $me->service();

    my $krArgs = join(" ",
            "-d",
            "-kn $instanceName",
            "-ko",
            "-ks $rotateInterval",
            "-ke $ENV{'NOTIFY'}",
            "-kk",
            );

    if ($service ne 'prod') {
        $krArgs .= " -kc 10";
    }

    #my $serverRoles = $instance->serverRoles();
    #my $progArgs = 'start';

    #my $jvmArgs = ariba::Ops::Startup::Common::composeJvmArguments($me, $instance);

    return $krArgs; #($progArgs, $krArgs, $jvmArgs);
}

1;
__END__