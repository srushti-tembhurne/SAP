package ariba::Ops::HadoopProperties;

use XML::XPath;
use XML::XPath::XMLParser;

#
# lib to get hadoop specific properties 
# This assumes that hadoop/bin/hadoop-env has been run and that the HBASE_HOME
# environment variable has been set
#
# For now this runs locally, but will update to run on the DR cluster once engr updates their configs
# ie. $ENV{'HBASE_HOME'} = "/home/svctest/hadoop/HadoopR2-13/hbase";
# ie. $ENV{'HADOOP_HOME'} = "/home/svctest/hadoop/HadoopR2-13/hadoop";
#
my $hbaseSiteFile = "/conf/hbase-site.xml";
my $hdfsSiteFile = "/conf/hdfs-site.xml";
my $mapredSiteFile ="/etc/hadoop/mapred-site.xml";

sub getHbaseZookeeperQuorum {
    my $hbaseHome = shift;

    return getXmlValue("hbase.zookeeper.quorum", $hbaseHome . $hbaseSiteFile);
}

sub getHbaseZookeeperPropertyClientPort {
    my $hbaseHome = shift;
    my $hbaseSiteCfg = shift;

    return getXmlValue("hbase.zookeeper.property.clientPort", $hbaseSiteCfg) if $hbaseSiteCfg;
    return getXmlValue("hbase.zookeeper.property.clientPort", $hbaseHome . $hbaseSiteFile);
}

sub getHbaseRegionServerInfoPort {
    my $hbaseHome = shift;

    return getXmlValue("hbase.regionserver.info.port", $hbaseHome . $hbaseSiteFile);
}

sub getHbaseMasterInfoPort {
    my $hbaseHome = shift;

    return getXmlValue("hbase.master.info.port", $hbaseHome . $hbaseSiteFile);
}

sub getNamenodehost {
    my ($hbaseHome, $nn) = @_;

    my $dfsNamenodeHttpAddress = getNamenodeHttpAddress($hbaseHome, $nn);
    my @host = split(":", $dfsNamenodeHttpAddress);

    return $host[0];
}

sub getNamenodeHttpAddress {
    my ($hbaseHome, $nn) = @_;

    my $dfsNameservice = getDfsNameservices($hbaseHome);

    return getXmlValue("dfs.namenode.http-address.$dfsNameservice.$nn", $hbaseHome . $hdfsSiteFile);
}

sub getJobtrackerhost {
    my ($hbaseHome, $jt) = @_;

    my $jtHttpRedirectAddress = getJobtrackerHttpRedirectAddress($hbaseHome, $jt);
    my @host = split(":", $jtHttpRedirectAddress);

    return $host[0];
}

sub getJobtrackerHttpRedirectAddress {
    my ($hbaseHome, $jt) = @_;

    return getXmlValue("mapred.ha.jobtracker.http-redirect-address.hajobtracker.$jt", $hbaseHome . $mapredSiteFile);
}

sub getJobtrackernode {
    my $hbaseHome = shift;

    return getXmlValue("mapred.jobtrackers.hajobtracker", $hbaseHome . $mapredSiteFile);
}

sub getNamenode {
    my $hbaseHome = shift;

    my $nameServices = getDfsNameservices($ENV{'HBASE_HOME'});

    return getXmlValue("dfs.ha.namenodes.$nameServices", $hbaseHome . $hdfsSiteFile);
}

sub getDfsNameservices {
    my $hbaseHome = shift;

    return getXmlValue("dfs.nameservices", $hbaseHome . $hdfsSiteFile);
}

sub getXmlValue {
    my ($param, $siteFile) = @_;

    return 0 unless(-f $siteFile);

    my $xp = XML::XPath->new(filename => $siteFile); 
    my $value = $xp->find("/configuration/property[name=\'$param\']/value");

    return $value;
}

=begin
# sample xml snippet of parameters
# /home/svctest/hadoop/HadoopR2-13/hbase/conf/hbase-site.xml
...
<property>
<name>hbase.zookeeper.quorum</name>
<value>hdp114.lab1.ariba.com, hdp131.lab1.ariba.com, hdp108.lab1.ariba.com</value>
...
<property>
<name>hbase.zookeeper.property.clientPort</name>
<value>52000</value>
...
=cut

1;
