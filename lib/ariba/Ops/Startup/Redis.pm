package ariba::Ops::Startup::Redis;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/Redis.pm#1

=head1 NAME

ariba::Ops::Startup::Redis - Startup code for Redis.  Redis is the in-memory data structure store
used by suppliermanagement, supplierrisk, and other products.

=head1 DESCRIPTION

See wiki page: https://wiki.ariba.com/display/SUM/SM+-+Redis+Production+Deployment+Protocol

Redis runs instances in pairs in a master/slave format.  The end math tries to split
the pairs such that one is on an even numbered host and the other is on an odd numbered host.
This is to respect the odd/even network switch redundancy.

A basic topology map is created on local disk.  A java script is then run against this file to
generate the config files used to start each Redis instance.  Each final config file is unique.

=head1 Subroutines

=over 4

=cut

use strict;
use File::Path;
use Data::Dumper;

use ariba::Ops::Startup::Common;
use ariba::Ops::NetworkUtils;
use ariba::rc::Utils;

my $installDir;     # make this a hash element of the class when we change this to OO design.
my $configDir;

my @configFiles;
my $redisConfigFile = 'redis.cfg';


=pod

=item * setRuntimeEnv( $productObject )

Set bacic environment structure including product install path, java path, etc

Returns: nothing

=cut

sub setRuntimeEnv {
    my $me = shift;

    $installDir = $me->installDir();
    $configDir = $me->configDir();
    my $service = $me->service();

    # Create the local data dir if this is the first run.  Else the dir will already exist
    my $path = $me->default( 'Ops.Redis.DataDir' );
    unless ( -d $path ) {
        mkpath( $path, 1, 0755 ) || die "Couldn't create $path: $@";
    }

    $ENV{'JAVA_HOME'} = ariba::Ops::Startup::Common::javaHomeForProduct($me);
    $ENV{'TEMP'} = '/tmp';
    $ENV{'JAVA_LIB'} = 'org.apache.flume.node.Application';

    my @ldLibrary = ();

    my @pathComponents = (
        "$ENV{'JAVA_HOME'}/bin",
        "$installDir/bin",
        );

    my @classes = ();

    ariba::Ops::Startup::Common::setupEnvironment(\@ldLibrary, \@pathComponents, \@classes);
}


=pod

=item * makeRedisConfigFile( $productObject, $role )

A basic topology map is created on local disk.  A java script is then run against this file to
generate the config files used to start each Redis instance.  Each final config file is unique.

Returns: nothing.

=cut

sub makeRedisConfigFiles {
    my $me = shift;
    my $role = shift;

    my $cluster   = $me->currentCluster();
    my @instances = $me->appInstancesLaunchedByRoleInCluster($role, $cluster);

    my $instanceCount = 0;
    my $file = "$configDir/$redisConfigFile";
    open( my $fh, '>', $file ) or die "Could not open '$file' for writing $!";
    foreach my $instance (@instances) {
        my $host = $instance->host();
        my $instanceName = $instance->instanceName();
        my $port = $instance->port();

        print $fh "$instanceName,$host,$port\n";
        $instanceCount++;
    }
    close $fh;

    my $redisJar = "$installDir/" . $me->default( 'Ops.Redis.ConfigGenerator' );
    my $cmd = "java -jar $redisJar $configDir $file " . $instanceCount/2;
    ariba::rc::Utils::executeLocalCommand($cmd);
}


=pod

=item * getConfigFile( $host, $port )

Loop over the array of config files.  Find the unique one for the instance by
matching the host and port in the file name.

Returns: scalar - the name of the config file.

=cut

sub getConfigFile {
    my $host = shift;
    my $port = shift;

    # sample file name format
    # app520.lab1.ariba.com_Redis-1377000@app520.lab1_7000_master.conf
    
    # OK, pay attention.  This is way more complex than it needs to be, but it was fun to learn.
    # Compiling regex values is 4x slower than looking for literal string.  
    # The idea is to pre compile as much as possible to save time.
    #
    # The '/o' compiles a value once for the full run of the program.  Thus as this code executes
    # on host $hostRegex is only ever compiled once.  This includes multiple calls to this subroutine.
    # $portRegex will be different for each call to the subroutine, but it will be the same for each 
    # itteration of the loop.  The 'qr' will compile $portRegex one per subroutine call.
    my $hostRegex = qr/^${host}/o;
    my $portRegex = qr/_${port}_/;
    foreach my $file (@configFiles) {
        return $file if ($file =~ /$hostRegex.+$portRegex/);
    }
}
    

=pod

=item * readAllConfigFiles()

After the config files are created (one unique to each Redis instance)
read them into a global array.

Returns: nothing

=cut

sub readAllConfigFiles {

    opendir my $dh, $configDir or die "Could not open '$configDir' for reading: $!\n";
    @configFiles = readdir $dh;

    @configFiles = grep(/(master|slave)\.conf/, @configFiles);
}


=pod

=item * readAllConfigFiles()

This is the entry routine to launch the redis instances.  Here the command line args
are constructed and passed into keepRunning on a per instance basis.

Returns: array - the instances launched.

=cut

sub launch {
    my $me = shift;
    my $apps = shift;
    my $role = shift;

    setRuntimeEnv($me);

    makeRedisConfigFiles( $me, $role );
    readAllConfigFiles();

    my $cluster = $me->currentCluster();
    my $host = ariba::Ops::NetworkUtils::hostname();
    my @instances = $me->appInstancesOnHostLaunchedByRoleInClusterMatchingFilter($host, $role, $cluster, $apps);

    # Create the redis data dir (if required)
    my $dataFilePath = $me->default( 'Ops.Redis.DataDir' );
    mkdirRecursively( $dataFilePath ) unless -d $dataFilePath;

    my @launchedInstances;
    for my $instance (@instances) {

        my $host = $instance->host();
        my $port = $instance->port();
        my $instanceName = $instance->instanceName();
        my $redisArgs = $me->default( 'Ops.Redis.JVMArgs' );

        # get the config file for the instance
        my $configFile = getConfigFile($host, $port);
        unless ($configFile) {
            die "If this happens it means AIM is broke.  Panic!  Can't find config file for $host:$port in $configDir\n"; 
        }
        $configFile = "$configDir/$configFile";

        # This regex extracts either 'master' or 'slave' from the config file name
        (my $masterOrSlave) = ($configFile =~ /(master|slave)/);

        # define the data file for the instance.
        my $dataFile = "${instanceName}_${port}_${masterOrSlave}.rdb";
     
        # Do some regex substitutions on the jvm args
        $redisArgs =~ s/\@REDISPORT\@/$port/;
        $redisArgs =~ s/\@REDISCONFIG\@/$configFile/;
        $redisArgs =~ s/\@REDISDATA\@/$dataFile/;

        # get the args for keeprunning
        my $krArgs = composeKrArguments($me, $instance);

        # the final command to run
        my $launchCommand = $me->default( 'Ops.Redis.LaunchProgram' );
        my $cmd = "$main::INSTALLDIR/bin/keepRunning $krArgs -kp $installDir/$launchCommand $redisArgs";
        
        if ($main::debug) {
            print  "\n-------------------------- ";
            print "Will run: $cmd\n";
        } else {
            ariba::Ops::Startup::Common::runKeepRunningCommand($cmd);
        }

        push(@launchedInstances, $instance);
    }

    return @launchedInstances;
}


=pod

=item * composeKrArguments()

Compile the arguments used by keepRunning.

Returns: scalar - the keepRunning args.

=cut

sub composeKrArguments {
    my($me, $instance) = @_;

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

    return ($krArgs);
}


=pod

=item * stopRedis()

Cleanly shut down a redis instance.

Returns: nothing.

=cut

sub stopRedis {
    my $instancesRef = shift;
    my $me = shift;

    setRuntimeEnv($me);

    # first kill off the keepRuning processes
    # these lines were copied from stopsvc and modified to only kill KR, not the redis instances.
    my @instanceNames;
    my %pidMap;
    for my $instance (@$instancesRef) {
        push ( @instanceNames, $instance->Name );
    }
    my ($krPidsRef, $appPidsRef, $deleteFilesRef) = ariba::Ops::Startup::Common::kRpidsAndFilesForAppNames(@instanceNames);
    ariba::Ops::Startup::Common::pidToProcessMap(\%pidMap, @$krPidsRef);
    ariba::Ops::Startup::Common::killPids($krPidsRef, undef, 1, undef, $main::debug, \%pidMap);

    my $stopProgram = "$installDir/" . $me->default('Ops.Redis.CLIProgram');
    
    # Now that KR is dead we can cleanly shut down the lingering Redis instance.
    for my $instance (@$instancesRef) {
        my $host = $instance->host();
        my $port = $instance->port();

        my $cmd = "$stopProgram -c -h $host -p $port SHUTDOWN";

        r($cmd);
    }
}

;

__END__
