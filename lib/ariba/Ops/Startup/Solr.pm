package ariba::Ops::Startup::Solr;

# $Id $

use strict;

use File::Path;
use File::Basename;
use Cwd;
use ariba::Ops::Startup::Common;
use ariba::Ops::Machine;
use ariba::Ops::ServiceController;
use ariba::rc::Utils;

my $envSetup = 0;

# Only do this once.
chomp(my $arch = lc(`uname -s`));
chomp(my $kernelName = `uname -s`);

sub setRuntimeEnv {
        my $me = shift;

        return if $envSetup;

        my $installDir = $me->installDir();
        $ENV{'LOGSDIR'} = ariba::Ops::Startup::Common::logsDirForProduct($me) unless ($ENV{'LOGSDIR'});

        $ENV{'JAVA_HOME'} = $me->javaHome();
        $ENV{'SOLR_LOG_DIR'} = "$ENV{'LOGSDIR'}/solr";
        $ENV{'TEMP'} = '/tmp';

        # we're not using cfengine
        $ENV{'SOLR_HOME'} = "$installDir/solr/example";

        my @ldLibrary = (
        );

        my @pathComponents = (
                "$ENV{'SOLR_HOME'}/bin",
                "$ENV{'JAVA_HOME'}/bin",
                "$installDir/bin",
        );

        my @classes = (
                "$ENV{'SOLR_HOME'}",
                );

        ariba::Ops::Startup::Common::setupEnvironment(\@ldLibrary, \@pathComponents, \@classes);

        $envSetup++;
}

sub launch {
        my $me = shift;
        my $apps = shift;
        my $role = shift;
        my $community = shift;

        if ( $role =~ /^aucsolr/ ){
            #print "** Running launch for '$role'\n";
            return launchAUCSolr( $me, $apps, $role );
        } else {
            return launchAppsForRole($me, $apps, $role, $community);
        }
}

sub launchAUCSolr {
    my($me, $apps, $role) = @_;
    my @launchedInstances;

    my $cluster   = $me->currentCluster();
    my $installDir = $me->installDir();

    my $flavor = lc $role;
    $flavor =~ s/^aucsolr//; ## role = aucsolrsearch or aucsolrindexer, flavor will be search or indexer

    my @instances = $me->appInstancesOnHostLaunchedByRoleInClusterMatchingFilter(
        ariba::Ops::NetworkUtils::hostname(), $role, $cluster, $apps);

    foreach my $instance (@instances) {

        my ($progArgs, $krArgs, $jvmArgs) = composeLaunchArguments($me, $instance);

        ## Options here are IndexerDataDir and SearchDataDir
        my $flav = ucfirst $flavor;
        my $solrDataDir = $me->default("Solr.${flav}DataDir");
        unless ( $solrDataDir ) { die "Couldn't read Solr.${flav}DataDir from DD\n"; }
        unless (-d $solrDataDir) {
            eval { mkpath($solrDataDir, 0, 0770) };
            if ($@) {
                die "Couldn't create $solrDataDir: $@";
            }
        }

        ## cd to proper Solr directory (auc_indexer or auc_search)
        ## config dir: auc_indexer/solr/auc_core/conf/
        my $old = getcwd();
        chdir "$installDir/solr/auc_$flavor" 
            or die "could not chdir to $installDir/solr/auc_$flavor\n";

        my $port = $instance->port();
        my $instanceName = $instance->instance();

        ## From Praveer on how to start AUC_Solr*
        ## cd <INSTALLED_FOLDER>/solr/auc_<node_type>
        ## java -jar start.jar Djetty.port=<port>
        my $command = $me->javaHome($instance->appName()) . "/bin/java $jvmArgs -jar start.jar -Djetty.port=$port -Dinstancename=$instanceName";

        ## We'll use KR for this:
        my $com = "$main::INSTALLDIR/bin/keepRunning $krArgs -kp $command";

        if ($main::debug) {
            print "Will run: $com\n";
        } else {
            local $ENV{'JAVA_HOME'} = $me->javaHome($instance->appName());
            local $ENV{'JVMFLAGS'} = $jvmArgs;

            print "$com\n";
            ariba::Ops::Startup::Common::runKeepRunningCommand($com);
        }

        push (@launchedInstances, $instance);

        ## cd back to where we were
        chdir "$old" 
            or die "could not chdir to $installDir/solr/auc_$flavor\n";
    }

    if ( $role eq 'aucsolrindexer' ){
        ariba::Ops::Startup::Solr::generateAUCRsync($cluster);
    }

    return @launchedInstances;
}

sub launchAppsForRole {
        my($me, $apps, $role, $community) = @_;

        my $cluster   = $me->currentCluster();
        my $installDir = $me->installDir();

        my @instances = $me->appInstancesOnHostLaunchedByRoleInClusterMatchingFilter(
                ariba::Ops::NetworkUtils::hostname(), $role, $cluster, $apps);

        my @launchedInstances;
        for my $instance (@instances) {

                my $instanceName = $instance->instance();
                my $instanceCommunity = $instance->community();

                if ($instanceCommunity && $community && $instanceCommunity != $community) {
                        next;
                }

                push (@launchedInstances, $instance) ;

                my ($progArgs, $krArgs, $jvmArgs) = composeLaunchArguments($me, $instance);


                my $additionalVmArgs =join(" ",
                                     );

                my $solrDataDir = $me->default("Solr.DataDir");
                unless ( $solrDataDir ) { die "Couldn't read Solr.DataDir from DD\n"; }
                unless (-d $solrDataDir) {
                     eval { mkpath($solrDataDir, 0, 0770) };
                     if ($@) {
                         die "Couldn't create $solrDataDir: $@";
                     }
                }
                

                my $jettyPort = $me->default("Solr.Port");
                unless ( $jettyPort ) { die "Couldn't read Solr.Port from DD\n"; }
   
                 my $extrajvmArgs = join(" ",
                "-Dsolr.installdir=$ENV{'SOLR_HOME'}/..",
                "-Dsolr.solr.home=$installDir/config/templates/solr/solr",
                "-Djetty.home=$ENV{'SOLR_HOME'}",
                "-Djetty.port=$jettyPort",
                "-Djava.util.logging.config.file=$installDir/config/solr/logging.properties",
                "-Dsolr.data.dir=$solrDataDir",
                        );

                #ToDo: sharding for solr.data.dir
               
                my $prog = join(" ",
                                $me->javaHome($instance->appName()) . "/bin/java",
                                $jvmArgs,
                                $extrajvmArgs,
                                "-jar $ENV{'SOLR_HOME'}/start.jar",
                                );




                my $progToLaunch = join(' ',
                        $prog,
                        $progArgs,
                        );

                my $com = "$main::INSTALLDIR/bin/keepRunning $krArgs -kp $progToLaunch";
                if ($main::debug) {
                        print "Will run: $com\n";
                } else {
                        local $ENV{'JAVA_HOME'} = $me->javaHome($instance->appName());
                        local $ENV{'JVMFLAGS'} = $jvmArgs;

                        print "$com\n";
                        ariba::Ops::Startup::Common::runKeepRunningCommand($com);
                }
        }

        return @launchedInstances;
}

sub composeLaunchArguments {
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

        if (!(ariba::Ops::ServiceController::isProductionServicesOnly($service))) {
                $krArgs .= " -kc 2";
        }

        my $serverRoles = $instance->serverRoles();
        my $progArgs = '';

        my $jvmArgs = ariba::Ops::Startup::Common::composeJvmArguments($me, $instance);

        return ($progArgs, $krArgs, $jvmArgs);
}

sub generateAUCRsync {
    my ($cluster) = @_;
    ## Since we have all this info, we'll write a script to rsync the indexer data
    my $script = "$ENV{'ARIBA_DEPLOY_ROOT'}/bin/rsync-index.sh";

    my $rsync = ariba::rc::Utils::rsyncCmd();

    my $auc = ariba::rc::InstalledProduct->new("community", $ENV{'ARIBA_SERVICE'});
    my $srcDir = $auc->default('Solr.IndexerDataDir') || die "Couldn't read Solr.IndexerDataDir from DD!\n";
    my $dstDir = $auc->default('Solr.SearchDataDir') || die "Couldn't read Solr.SearchDataDir from DD!\n";

    my @instances = $auc->appInstancesLaunchedByRoleInCluster( 'aucsolrsearch', $cluster );

    my @searches = $auc->hostsForRoleInCluster('aucsolrsearch', $auc->currentCluster);

    open my $OUT, '>', $script or die "Could not open '$script' for writing: $!\n";
    print $OUT <<EOT;
#!/bin/sh
## Script automatically generated from ariba::Ops::Startup::Solr::generateAUCRsync()
EOT

    ## handle search nodes
    print $OUT "\n## rsync primary/secondary Indexer to associated Search nodes\n";
    foreach my $search ( @searches ){
        print $OUT "$rsync $srcDir $search\:\:$dstDir\n";
    }

    ## curl http://<searchnode_host>:<port1>/solr/admin/cores?action=RELOAD&core=auc_core
    ## Success: <int name="status">0</int>
    print $OUT "\n## Tell search nodes to reload indexes:\n";
    foreach my $instance ( @instances ){
        my $host = $instance->host();
        my $port = $instance->port();
        print $OUT "wget --no-check-certificate -q -O /dev/null http://$host:$port/solr/admin/cores?action=RELOAD&core=auc_core\n";
    }

    close $OUT or die "Error closing '$script' after writing: $!\n";
    ## And make the script executable:
    chmod 0755, $script || die "Error running 'chmod 0755 $script':$!\n";
}

1;

__END__

