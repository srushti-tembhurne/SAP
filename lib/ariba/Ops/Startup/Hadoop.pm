package ariba::Ops::Startup::Hadoop;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/Hadoop.pm#34 $

use strict;

use File::Path;
use File::Basename;
use ariba::Ops::Startup::Common;
use ariba::Ops::Startup::Veritas;
use ariba::Ops::ServiceController;
use ariba::rc::Utils;
use ariba::rc::Globals;
use ariba::rc::Passwords;

my $SUDO = ariba::rc::Utils::sudoCmd();

# Only do this once.
chomp(my $arch = lc(`uname -s`));
chomp(my $kernelName = `uname -s`);

sub setRuntimeEnv {
    my $me = shift;
    my $role = shift;

    my $installDir = $me->installDir();
    $ENV{'LOGSDIR'} = ariba::Ops::Startup::Common::logsDirForProduct($me) unless ($ENV{'LOGSDIR'});

    #
    # Override the OOTB RootLogger value of INFO
    #
    $ENV{'HADOOP_ROOT_LOGGER'} = $me->default('Ops.RootLogger.$appName') || $me->default('Hadoop.RootLogger');

    $ENV{'JAVA_HOME'} = ariba::Ops::Startup::Common::javaHomeForProduct($me);
    if (defined $role && ($role eq 'hadoop-task' || $role eq 'hadoop-jobtracker' || $role eq 'ha-jobtracker'
        || $role eq 'mapreduce-zkfc')) {
        # if we are dealing with jobtracker or tasktracker, we would
        # need to see if the current deployed hadoop version is release 1
        # or release 2.  If the current deployed hadoop version is release 2,
        # the hadoop home needs to be set to a different directory so
        # that we can use mapreduce version 1.
        if (-e "$installDir/hadoop/bin-mapreduce1") {
            # the current deployed hadoop version is release 2 (cdh 4.4.0)
            $ENV{'HADOOP_HOME'} = "$installDir/hadoop/share/hadoop/mapreduce1";

            # create symlink HADOOP_HOME/conf to etc/hadoop-mapreduce1
            unless (-l "$ENV{'HADOOP_HOME'}/conf") {
                symlink("$installDir/hadoop/etc/hadoop-mapreduce1", "$ENV{'HADOOP_HOME'}/conf"); 
            }

            # create symlink HADOOP_HOME/bin to bin-mapreduce1
            unless (-l "$ENV{'HADOOP_HOME'}/bin") {
                symlink("$installDir/hadoop/bin-mapreduce1", "$ENV{'HADOOP_HOME'}/bin");
            }
        }
        else {
            # the current deployed hadoop version is release 1 (cdh 3)
            $ENV{'HADOOP_HOME'} = "$installDir/hadoop";
        }
    }
    else {
        # we are not dealing with jobtracker or tasktracker
        $ENV{'HADOOP_HOME'} = "$installDir/hadoop"; 

        if (-e "$installDir/hadoop/bin-mapreduce1") {
            # the current deployed hadoop version is release 2 (cdh 4.4.0)
            # create symlink HADOOP_HOME/conf to etc/hadoop
            unless (-l "$ENV{'HADOOP_HOME'}/conf") {
                symlink("$installDir/hadoop/etc/hadoop", "$ENV{'HADOOP_HOME'}/conf");
            }
        }
    }
    
    $ENV{'HBASE_HOME'} = "$installDir/hbase";
    $ENV{'HADOOP_CONF_DIR'} = "$ENV{'HADOOP_HOME'}/conf";
    $ENV{'HBASE_CONF_DIR'} = "$ENV{'HBASE_HOME'}/conf";
    $ENV{'HADOOP_LOG_DIR'} = "$ENV{'LOGSDIR'}";
    $ENV{'HADOOP_PID_DIR'} = $ENV{'LOGSDIR'};

    # Changed to fix problems due to exec hardening of /tmp for PCI audit.  It has been determined that this is for monitoring startup in
    # certain environments, and should not be done outside of said environments.

    # The temp dir is to be created in the home directory of the service user, under hadoop.  If it does not exist, create it.
    # Use the HADOOP_HOME ENV VAR to determine the exact location, for consistency.
    $ENV{'TEMP'} = "$ENV{HADOOP_HOME}/tmp";
    # If the location does not exist, create it.
    unless (-d $ENV{TEMP})
    {
        # It is possible, but not likely, the hadoop part does not exist either, so the -p option is used, just in case.
        system ("mkdir -p $ENV{TEMP}");
    }

    my @ldLibrary = (
        );

    my @pathComponents = (
        "$ENV{'HADOOP_HOME'}/bin",
        "$ENV{'HBASE_HOME'}/bin",
        "$ENV{'JAVA_HOME'}/bin",
        "$installDir/bin",
        );

    my @classes = (
        "$ENV{'HADOOP_HOME'}",
        "$ENV{'HADOOP_HOME'}/conf",
        "$ENV{'HADOOP_HOME'}/lib",
        );

    ariba::Ops::Startup::Common::setupEnvironment(\@ldLibrary, \@pathComponents, \@classes);
}

=item * writeXmlConfFiles( $installedProductInstance, $role )

Generates the core-site.xml, mapred-site.xml, hbase-site.xml, and zoo.cfg
configuration files with the following runtime variables replaced based
on which cluster the product is deployed on: 

    HADOOP-NAMENODE-SERVER      Namenode VIP/Server from roles.cfg
    HADOOP-JOBTRACKER-SERVER    Jobtracker VIP/Server from roles.cfg    
    ZOOKEEPER-QUORUM            List of zookeeper servers/quorum separated
                                by comma.
    ZOOKEEPER-SERVERS-LIST      List of zookeeper servers/quorum and
                                leader ports from roles.cfg/DD.xml
    HA-ZOOKEEPER-QUORUM         List of zookeeper servers and ports separated
                                by comma without space.
    JOURNAL-QUORUM              Journal quorum separated by semi-colon 
                                without space.

The config files are generated once / on first call only if multiple calls to 
this method is performed.

If the source .cfg files are not in the config folder, the destination files
will not be generated.

Arguments: 
    installedProductInstance    Installed hadoop product to generate the 
                                configs for. 

Returns: 
    None
    
    Errors are printed to STDOUT 

=cut

sub writeXmlConfFiles {
    my $me = shift;
    my $role = shift; 
    my $installDir = $me->installDir();
    # Paths should be relative to the $me->installDir()
    # Need to have hdfs-site.xml in hbase/conf for resolving the NameServiceID
    my %confFiles = (
        # Destination File                  Source Template File
        'hbase/conf/hbase-site.xml'      => 'config/hbase-site.cfg',
        'hbase/conf/hdfs-site.xml'       => 'config/hdfs-site.cfg',
        'zookeeper/conf/zoo.cfg'         => 'config/zoo.cfg', 
    );

    if (defined $role && ($role eq 'hadoop-task' || $role eq 'hadoop-jobtracker') || $role eq 'ha-jobtracker') {
        # if we are dealing with jobtracker or tasktracker, we would
        # need to see if the current deployed hadoop version is release 1
        # or release 2.  If the current deployed hadoop version is release 2,
        # the configuration files are in a different place.
        if (-e "$installDir/hadoop/bin-mapreduce1") {
            # the current deployed hadoop version is release 2 (cdh 4.4.0)
            # need to have hdfs-site.xml in mapred conf for resolving the NameServiceID
            $confFiles{'hadoop/etc/hadoop-mapreduce1/core-site.xml'}   = 'config/core-site.cfg';
            $confFiles{'hadoop/etc/hadoop-mapreduce1/mapred-site.xml'} = 'config/mapred-site.cfg';
            $confFiles{'hadoop/etc/hadoop-mapreduce1/hdfs-site.xml'} = 'config/hdfs-site.cfg';
        }
        else {
             # the current deployed hadoop version is release 1 (cdh 3)
            $confFiles{'hadoop/conf/core-site.xml'}   = 'config/core-site.cfg';
            $confFiles{'hadoop/conf/mapred-site.xml'} = 'config/mapred-site.cfg';
            $confFiles{'hadoop/conf/hdfs-site.xml'}   = 'config/hdfs-site.cfg';
        }
    }
    else {
        # we are not dealing with jobtracker or tasktracker
        if (-e "$installDir/hadoop/bin-mapreduce1") {
            $confFiles{'hadoop/etc/hadoop/core-site.xml'}   = 'config/core-site.cfg', 
            $confFiles{'hadoop/etc/hadoop/mapred-site.xml'} = 'config/mapred-site.cfg', 
            $confFiles{'hadoop/etc/hadoop/hdfs-site.xml'}   = 'config/hdfs-site.cfg',
            $confFiles{'hadoop/etc/hadoop/hbase-site.xml'}  = 'config/hbase-site.cfg';
        }
        else {
            $confFiles{'hadoop/conf/core-site.xml'}   = 'config/core-site.cfg', 
            $confFiles{'hadoop/conf/mapred-site.xml'} = 'config/mapred-site.cfg', 
            $confFiles{'hadoop/conf/hdfs-site.xml'}   = 'config/hdfs-site.cfg',
            $confFiles{'hadoop/conf/hbase-site.xml'}  = 'config/hbase-site.cfg';
        }
    }

     my %runtimeVars = (
        'HADOOP-NAMENODE-SERVER'    => $me->virtualHostForRoleInCluster('hadoop-name', $me->currentCluster()), 
        'HADOOP-JOBTRACKER-SERVER'  => $me->virtualHostForRoleInCluster('hadoop-jobtracker', $me->currentCluster()),
        'HA-JOBTRACKER-SERVER'      => $me->virtualHostForRoleInCluster('ha-jobtracker', $me->currentCluster()),
    );

    my $index = 1;
    my @nnServers = $me->hostsForRoleInCluster('hadoop-name', $me->currentCluster());
    foreach my $nnServer (@nnServers) {
        $runtimeVars{"HADOOP-NAMENODE-SERVER$index"} = "$nnServer";
        $index++;
    }

    $index = 1;
    my @hajtServers = $me->hostsForRoleInCluster('ha-jobtracker', $me->currentCluster());
    foreach my $hajtServer (@hajtServers) {
        $runtimeVars{"HA-JOBTRACKER-SERVER$index"} = "$hajtServer";
        $index++;
    }

    # ZooKeeper server list format: server.$uniqueId=$server:$quorumPort:$leaderPort
    # ex: server.11=app256.ariba.com:52010:52020
    #
    # We use the last octet of the machine's ip address as the uniqueId
    # as that is unique enough when zk clusters will be just a few machines.
    # 
    # ZooKeeper quorum list format: $server:$zkPort

    my @zkServers = $me->hostsForRoleInCluster('zookeeper', $me->currentCluster());
    if($role eq 'hsim-zookeeper' || $role eq 'lbnode' || $role eq 'enode' ) {
        @zkServers = $me->hostsForRoleInCluster('hsim-zookeeper', $me->currentCluster());
        $confFiles{'config/simulator.config.xml'}   = 'config/simulator.config.xml';
    }
    my $zkQuorumPort = $me->default('ZooKeeper.QuorumPort'); 
    my $zkLeaderPort = $me->default('ZooKeeper.LeaderPort');
    my $zkPort = $me->default('ZooKeeper.Port');
    my @zkServersList; 
    my @zkQuorumList;

    foreach my $server (@zkServers) {
        my $machine = ariba::Ops::Machine->new($server);
        my $serverId;
        
        if ( $machine->ipAddr() && $machine->ipAddr() =~ /(\d+)$/ ) {
            my $lastOctetOfIp = $1; 
            $serverId = $lastOctetOfIp;
        } else {
            print "Error: $server does not have valid ipAddr set / excluding it from zoo.cfg"; 
            next; 
        }

        push(@zkServersList, "server.$serverId=$server:$zkQuorumPort:$zkLeaderPort");
        push(@zkQuorumList, "$server:$zkPort");
    }

    $runtimeVars{'ZOOKEEPER-QUORUM'} = join(', ', @zkServers);
    $runtimeVars{'ZOOKEEPER-SERVERS-LIST'} = join("\n", @zkServersList);
    $runtimeVars{'HA-ZOOKEEPER-QUORUM'} = join(',', @zkQuorumList);

    my @journalServers = $me->hostsForRoleInCluster('hadoop-journal', $me->currentCluster());
    my $journalPort = $me->default('Hadoop.DFS.Journal.Port');
    my @journalServersList;
    foreach my $journalServer (@journalServers) {
        push(@journalServersList, "$journalServer:$journalPort");
    }
    $runtimeVars{'JOURNAL-QUORUM'} = join(';', @journalServersList);

    while ( my ($destFile, $sourceFile) = each(%confFiles) ) {
        my $sourcePath = $me->installDir() . "/$sourceFile"; 
        my $destPath = $me->installDir() . "/$destFile"; 

        local $@;

        eval {
            # Check for source file
            unless ( -e $sourcePath ) {
                print "Skipping generation of $destPath as $sourcePath does not exist\n"; 
                next;
            }

            # Skip if dest file is newer than source file, which indicates it was already
            # generated by another process.
            if ( -e $destPath && ((-M $destPath) < (-M $sourcePath)) ) {
                print "Skipping generation of $destPath as it is newer than $sourcePath\n"; 
                next;
            }

            # Read from source file
            open(my $sourceFh, "< $sourcePath") || die "Failed to open $sourcePath, $!"; 
            my @contents = <$sourceFh>; 
            close($sourceFh); 
            
            # Check for source content
            scalar(@contents)                   || die "No contents read from $sourcePath";

            # Expand runtime vars in source content
            my $updatedContents = ariba::Ops::Startup::Common::expandRuntimeVars(join('', @contents), \%runtimeVars);

            # Change file to writable
            chmod(0644, $destPath) if (-f $destPath && ! -w $destPath);

            # Write updated content with runtime vars to dest file
            open(my $destFh, "> $destPath")     || die "Failed to open $destPath for writing, $!"; 
            print $destFh $updatedContents      || die "Failed to write to $destPath, $!"; 
            close($destFh)                      || die "Failed to close $destPath, $!";
        }; 

        print "Error: $@. $destPath may not be generated.\n" if ( $@ );
    }

    return 1;
}

sub launch {
    my $me = shift;
    my $apps = shift;
    my $role = shift;
    my $community = shift;

    return launchAppsForRole($me, $apps, $role, $community);
}

sub launchAppsForRole {
    my($me, $apps, $role, $community) = @_;

    my $cluster   = $me->currentCluster();

    my @instances = $me->appInstancesOnHostLaunchedByRoleInClusterMatchingFilter(
        ariba::Ops::NetworkUtils::hostname(), $role, $cluster, $apps);

    # For Veritas enabled nodes, always launch it on each host, and Veritas
    # will start on the first host, and will ignore the start from the second host,
    # unless it doesn't match the app filter.
    if ( ariba::Ops::Startup::Veritas::isVeritasControlEnabledForRole($me, $role) ) { 
        my $alreadyLaunchingNode = grep { $_->launchedBy() eq $role } @instances; 

        unless ( $alreadyLaunchingNode ) {
            my @apps = $me->appInstancesLaunchedByRoleInClusterMatchingFilter($role, $cluster, $apps);
            push(@instances, @apps) if ( @apps );
        }
    }

    my @launchedInstances;
    for my $instance (@instances) {

        my $instanceName = $instance->instance();
        my $instanceCommunity = $instance->community();

        if ($instanceCommunity && $community && $instanceCommunity != $community) {
            next;
        }
        
        push (@launchedInstances, $instance);

        my ($progArgs, $krArgs, $jvmArgs, $maxHeapSize) = composeLaunchArguments($me, $instance);

        if ( ariba::Ops::Startup::Veritas::isVeritasControlEnabledForNode($me, $instance) ) {
            unless ( ariba::Ops::Startup::Veritas::startVeritasControlledNode($me, $instance) ) {
                print "Error: Failed to start " . $instance->instance(), "\n";
            }
        } 
        else {
            my $prog;
            if ($role eq 'hadoop-task' || $role eq 'hadoop-jobtracker' || $role eq 'ha-jobtracker'
            || $role eq 'mapreduce-zkfc') { 
                # $ENV{'HADOOP_HOME'} should have been already set to
                # the right place in setRuntimeEnv
                $prog = "$ENV{'HADOOP_HOME'}/bin/hadoop"
            }
            elsif ($role eq 'hadoop-thrift') {
                # $ENV{'HADOOP_HOME'} should have been already set to
                # the right place in setRuntimeEnv
                $prog = "$ENV{'HADOOP_HOME'}/src/contrib/thriftfs/scripts/start_thrift_server.sh";                
            }
            else {
                my $hadoopCmd = "hadoop";
                if (-e "$main::INSTALLDIR/hadoop/bin-mapreduce1") {
                    # in hadoop release 2, the hadoop command is depreciated, we
                    # need to use the hdfs command instead
                    $hadoopCmd = "hdfs";
                }
                # $ENV{'HADOOP_HOME'} should have been already set to
                # the right place in setRuntimeEnv
                $prog = "$ENV{'HADOOP_HOME'}/bin/$hadoopCmd";    
            }

            my $progToLaunch = join(' ',
                $prog,
                $progArgs,
                );

            my $cmd = "$main::INSTALLDIR/bin/keepRunning $krArgs -kp $progToLaunch";
            if ($main::debug) { 
                print "Will run: $cmd\n"; 
            } 
            else {
                print "Running: $cmd\n"; 

                local $ENV{'JAVA_HOME'} = $me->javaHome($instance->appName());
                local $ENV{'HADOOP_HEAPSIZE'} = $maxHeapSize if ($maxHeapSize);
                local $ENV{'HADOOP_OPTS'} = $jvmArgs if ($jvmArgs);

                #
                # ha-jobtracker roles can only start when hadoop-name node is NOT in safe mode
                # before starting ha-jobtracker, check the safemode status of the namenode
                # every 30s for 10minutes. Exit and return an error if namenode does not come
                # out of safe mode in 10 minutes
                # Output sample: 'Safe mode is OFF'
                #
                if ($role eq 'ha-jobtracker' || $role eq 'hadoop-jobtracker') {
                    my $sleep = 30;
                    my $retries = 20;
                    my $minutes = ($sleep * $retries) / 60;
                    my $safe = 1;

                    for (my $i = 1; $i < $retries; $i++) {
                        my $statusCmd = $prog . " dfsadmin -safemode get";
                        my @output = `$statusCmd`;
                        foreach my $line (@output) {
                            if ($line =~ /Safe mode is OFF/) {
                                $safe = 0;
                                last;
                            } else {
                                next;
                            }
                        }
                        last if ($safe == 0);
                        print "(retry $i) hadoop-name node in safe mode. Sleeping for $sleep seconds before re-checking...\n";
                        sleep($sleep);
                    }
                    if ($safe == 1) {
                        print "ERROR: ha-jobtracker node not started due to hadoop-name in safemode > $minutes minutes.
                        Remaining nodes may not function properly. Investigate any issues on the namenodes and when
                        resolved, this may require an app restart\n"; 

                        exit(1);
                    }
                }

                ariba::Ops::Startup::Common::runKeepRunningCommand($cmd);
            }
        }
    }

    return @launchedInstances;
}

sub composeLaunchArguments {
    my($me, $instance) = @_;

    my $rotateInterval = 24 * 60 * 60; # 1 day

    my $instanceName = $instance->instance();
    my $service  = $me->service();
    my $prettyName = $instanceName;
    $prettyName .= "--" . $instance->logicalName() if $instance->logicalName();

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

    my $serverRoles = $instance->serverRoles();
    my $progArgs = ($serverRoles eq 'hdfsthrift') ? $instance->port() : $serverRoles;

    my ($jvmArgsCompose, $maxHeapSize) = ariba::Ops::Startup::Common::composeJvmArguments($me, $instance);
    my $jvmArgs = ariba::Ops::Startup::Common::expandJvmArguments($me, $prettyName, $jvmArgsCompose);

    return ($progArgs, $krArgs, $jvmArgs, $maxHeapSize);
}

sub sortRoles {
    my %order = (
        'zookeeper'         => 1,

        'hadoop-journal'    => 2,
        'hadoop-zkfc'       => 3,
        'hadoop-name'       => 4, 
        'hadoop-data'       => 5,

        'hbase-master'      => 6,
        'hbase-region'      => 7,

        'hadoop-jobtracker' => 8,
        'ha-jobtracker'     => 9,
        'mapreduce-zkfc'    => 10,
        'hadoop-task'       => 11,

        'hadoop-secondary'  => 12,

        'hadoop-thrift'     => 13,
        'hbase-thrift'      => 14,
    );
        
    return ariba::Ops::Startup::Common::sortRolesBasedOnOrder($::a, $::b, \%order);
}

sub sortRolesToStop {
    my %order = (
        'hadoop-thrift'     => 1,
        'hbase-thrift'      => 2,
        
        'mapreduce-zkfc'    => 3,
        'hadoop-jobtracker' => 4,
        'ha-jobtracker'     => 5,
        'hadoop-task'       => 6,

        'hbase-master'      => 7,
        'hbase-region'      => 8,

        'hadoop-secondary'  => 9,

        'hadoop-journal'    => 10,
        'hadoop-zkfc'       => 11,
        'hadoop-name'       => 12,
        'hadoop-data'       => 13,

        'zookeeper'         => 14,
    );
        
    return ariba::Ops::Startup::Common::sortRolesBasedOnOrder($::a, $::b, \%order);
}

sub createDirs {
    my $me = shift; 
    my @additionalDirs = @_;

    my @roots = ($me->default('Hadoop.LocalFsRoot'), $me->default('Hadoop.SharedFsRoot'), $me->default('tmpRoot'));

    foreach my $root (@roots) {
        if ($root && !(-d $root)) {
            print "Creating root directory: $root\n"; 
            my $user = scalar(getpwuid($>));
            r("$SUDO mkdir -p $root"); 
            r("$SUDO chown $user:ariba $root");
        }
    }

    # Only root dirs should be created using sudo. Other dirs should be created normally. 
    # Ex issue: /var/logi is root. Creating /var/logi/data/zookeeper with above code would
    # result in data owned by root while zookeeper is ok.
    foreach my $dir (@additionalDirs) {
        if ($dir && !(-d $dir)) {
            print "Creating directory: $dir\n"; 
            r("mkdir -p $dir"); 
        }
    }
}

1;

__END__
