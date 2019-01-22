package ariba::Ops::Startup::Logi;
#
# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/Logi.pm#13 $
#
# Need to split this into multiple apps (Hadoop, Pig, Flume, etc) later

use strict;

use ariba::Ops::Startup::Common;
use ariba::rc::Utils;
use ariba::rc::InstalledProduct;

my $SUDO = ariba::rc::Utils::sudoCmd();
my $envSetup = 0;

sub setRuntimeEnv {
    my $me = shift;

    return if $envSetup;

    my $installDir = $me->installDir();
    
    my $isLogi1 = $me->releaseName() eq '1.0';
    
    if ($isLogi1) {
    $main::INSTALLDIR = $installDir;    # ariba::Ops::Startup::Common->setupEnvironment started to use this.

    $ENV{'JAVA_HOME'} = ariba::Ops::Startup::Common::javaHomeForProduct($me);
    $ENV{'HADOOP_HOME'} = "$installDir/hadoop";
    $ENV{'PIG_HOME'} = "$installDir/pig";
    $ENV{'FLUME_HOME'} = "$installDir/flume";
    $ENV{'HBASE_HOME'} = "$installDir/hbase";
    $ENV{'ZOOKEEPER_HOME'} = "$installDir/zookeeper";

    $ENV{'FLUME_CONF_DIR'} = "$ENV{'FLUME_HOME'}/conf"; 
    $ENV{'HADOOP_CONF_DIR'} = "$ENV{'HADOOP_HOME'}/conf"; 
    $ENV{'HBASE_CONF_DIR'} = "$ENV{'HBASE_HOME'}/conf"; 
    $ENV{'TEMP'} = '/tmp';

    $ENV{'LOGSDIR'} = ariba::Ops::Startup::Common::logsDirForProduct($me) unless ($ENV{'LOGSDIR'});

    $ENV{'PIG_LOG_DIR'} = "$ENV{'LOGSDIR'}/pig";
    $ENV{'HADOOP_LOG_DIR'} = "$ENV{'LOGSDIR'}/hadoop";
    $ENV{'ZOO_LOG_DIR'} = "$ENV{'LOGSDIR'}/zookeeper";

    my @ldLibrary = (
        );

    my @pathComponents = (
        "$ENV{'JAVA_HOME'}/bin",
        "$ENV{'HADOOP_HOME'}/bin",
        "$ENV{'FLUME_HOME'}/bin",
        "$ENV{'PIG_HOME'}/bin",
        "$ENV{'HBASE_HOME'}/bin",
        "$ENV{'ZOOKEEPER_HOME'}/bin",
        "$installDir/bin",
        );

    my @classes = (
        "$ENV{'HADOOP_HOME'}",
        "$ENV{'HADOOP_HOME'}/conf",
        "$ENV{'HADOOP_HOME'}/lib",
        "$ENV{'FLUME_HOME'}",
        "$ENV{'FLUME_HOME'}/lib",
        "$ENV{'PIG_HOME'}",
        "$ENV{'PIG_HOME'}/lib",
        "$ENV{'HBASE_HOME'}",
        "$ENV{'HBASE_HOME'}/lib",
        "$ENV{'ZOOKEEPER_HOME'}",
        "$ENV{'ZOOKEEPER_HOME'}/lib",
        );
	ariba::Ops::Startup::Common::setupEnvironment(\@ldLibrary, \@pathComponents, \@classes);
    }
    else {
    my $hadoop = ariba::rc::InstalledProduct->new('hadoop', $me->service());
    my $hadoopDir = $hadoop->installDir();
 
    $main::INSTALLDIR = $installDir;    # ariba::Ops::Startup::Common->setupEnvironment started to use this.

    $ENV{'JAVA_HOME'} = ariba::Ops::Startup::Common::javaHomeForProduct($me);
    $ENV{'HADOOP_HOME'} = "$hadoopDir/hadoop/share/hadoop/mapreduce1";
    $ENV{'PIG_HOME'} = "$installDir/pig";
    $ENV{'HBASE_HOME'} = "$hadoopDir/hbase";
    $ENV{'ZOOKEEPER_HOME'} = "$hadoopDir/zookeeper";

    $ENV{'HADOOP_CONF_DIR'} = "$ENV{'HADOOP_HOME'}/conf"; 
    $ENV{'HBASE_CONF_DIR'} = "$ENV{'HBASE_HOME'}/conf"; 
    $ENV{'TEMP'} = '/tmp';

    $ENV{'LOGSDIR'} = ariba::Ops::Startup::Common::logsDirForProduct($me) unless ($ENV{'LOGSDIR'});

    $ENV{'PIG_LOG_DIR'} = "$ENV{'LOGSDIR'}/pig";
  

    my @ldLibrary = (
        );

    my @pathComponents = (
        "$ENV{'JAVA_HOME'}/bin",
        "$ENV{'HADOOP_HOME'}/bin",
        "$ENV{'PIG_HOME'}/bin",
        "$ENV{'HBASE_HOME'}/bin",
        "$ENV{'ZOOKEEPER_HOME'}/bin",
        "$installDir/bin",
        );

    my @classes = (
        "$ENV{'HADOOP_HOME'}",
        "$ENV{'HADOOP_HOME'}/conf",
        "$ENV{'HADOOP_HOME'}/lib",
        "$ENV{'PIG_HOME'}",
        "$ENV{'PIG_HOME'}/lib",
        "$ENV{'HBASE_HOME'}",
        "$ENV{'HBASE_HOME'}/lib",
        "$ENV{'ZOOKEEPER_HOME'}",
        "$ENV{'ZOOKEEPER_HOME'}/lib",
        );
    ariba::Ops::Startup::Common::setupEnvironment(\@ldLibrary, \@pathComponents, \@classes);
	}
	
    

    $envSetup++;
}

sub createDirs {
    my $me = shift; 
    my @additionalDirs = @_;

    #my @roots = ($me->default('Hadoop.LocalFsRoot'), $me->default('Hadoop.SharedFsRoot'), $me->default('tmpRoot'));
    #no hadoop fs creation since hadoop is seperate out
    my @roots = ();
  
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
