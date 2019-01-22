package ariba::rc::HadoopAppInstance;

use strict;

use base qw(ariba::rc::AbstractAppInstance);

use Net::Telnet;

=pod

=head1 NAME

ariba::rc::HadoopAppInstance

=head1 VERSION

$Id: //ariba/services/tools/lib/perl/ariba/rc/HadoopAppInstance.pm#3 $

=head1 DESCRIPTION

A HadoopAppInstance is an app instance that consists of Hadoop, Flume, Hbase, and ZooKeeper apps.

=head1 SEE ALSO

ariba::rc::AbstractAppInstance, ariba::rc::AppInstanceManager, ariba::rc::Product

=head1 CONSTANTS

=over 4

=item * FLUME_NODE

Name of the Flume node

=item * FLUME_MASTER_NODE

Name of the Flume Master node

=item * HADOOP_NAME_NODE

Name of the Hadoop NameNode

=item * HADOOP_DATA_NODE

Name of the Hadoop Data Node 

=item * HADOOP_JOBTRACKER_NODE

Name of the Hadoop JobTracker node 

=item * HADOOP_TASKTRACKER_NODE

Name of the Hadoop TaskTracker node 

=item * HADOOP_SECONDARY_NODE 

Name of the Hadoop Secondary NameNode

=item * HBASE_REGION_NODE

Name of the Hbase Region node

=item * HBASE_MASTER_NODE

Name of the Hbase Master node

=item * ZOOKEEPER_NODE 

Name of the ZooKeeper node

=cut

sub FLUME_NODE              { return 'Flume';           }
sub FLUME_MASTER_NODE       { return 'FlumeMaster';     }
sub HADOOP_NAME_NODE        { return 'Name';            }
sub HADOOP_DATA_NODE        { return 'Data';            }
sub HADOOP_JOBTRACKER_NODE  { return 'JobTracker';      } 
sub HADOOP_TASKTRACKER_NODE { return 'TaskTracker';     } 
sub HADOOP_SECONDARY_NODE   { return 'SeconaryName';    } 
sub HBASE_REGION_NODE       { return 'HbaseRegion';     } 
sub HBASE_MASTER_NODE       { return 'HbaseMaster';     }
sub ZOOKEEPER_NODE          { return 'ZooKeeper';       }

=head1 METHODS

=item * needsNightlyRecycle() 

Returns true if the node requires nightly recycle. 

=cut

sub needsNightlyRecycle {
    my $self = shift; 

    if ($self->appName() eq FLUME_NODE) { 
        return 1; 
    } else { 
        return 0;
    }
}


=item * url() 

@Override 

=cut 

sub url {
    my $self = shift; 

    my $host = $self->host(); 
    my $port = $self->port(); 
    my %pathForApp = (
        Name        => '/dfshealth.jsp', 
        JobTracker  => '/jobtracker.jsp',
    );
    
    if ($host && $port && $self->appName() !~ /Thrift/) {
        my $protocol = 'http'; 
        my $path = '';

        $path = $pathForApp{$self->appName()} if ($pathForApp{$self->appName()});

        return "$protocol://$host:$port$path"; 
    } else { 
        return;
    }
}

=item * logUrl() 

@Override

=cut

sub logURL { 
    my $self = shift;

    # Hadoop Name and JobTracker nodes could be run using hadoop-daemon script, which names
    # the logs with the server role instead of the instance name as it has no concept of
    # instance.

    my $url = $self->SUPER::logURL(); 
    my $nodeName = $self->alias() . "-" . $self->instanceId();
    my $serverRole = $self->serverRoles(); 

    $url =~ s/\b($nodeName)\b/$1|$serverRole/ if ($url && $serverRole);

    return $url;    
}

=item * jmxUrl() 

Returns the JMX url if the node supports JMX monitoring

=cut

sub jmxUrl {
    my $self = shift; 

    my $host = $self->host(); 
    my $port = $self->port(); 

    $port = $self->manager()->product->default('Hbase.Master.HttpPort') if ($self->appName() eq 'HbaseMaster');

    my @supportedApps = qw(Data JobTracker Name SecondaryName TaskTracker HbaseMaster HbaseRegion);

    return unless (grep { $self->appName() eq $_ } @supportedApps);
    return "http://$host:$port/jmx";
}

=item * jmxUrlForHeapUsage() 

Returns the JMX url for the heap usage if the node supports it. 

=cut

sub jmxUrlForHeapUsage {
    my $self = shift; 
    
    my $url = $self->jmxUrl(); 
    return $url && "$url?qry=java.lang:type=Memory";
}

=item * isUpResponseRegex() 

@Override

=cut

sub isUpResponseRegex {
    my $self = shift; 

    if ( $self->appName() eq ZOOKEEPER_NODE ) { 
        return 'imok'; 
    } 

    return '\w';
}

=item * checkIsUp() 

@Override 

=cut 
sub checkIsUp {
    my $self = shift; 
    
    if ( $self->appName() eq ZOOKEEPER_NODE ) { 
        my $host = $self->host();
        my $port = $self->port();
        my $output;

        eval {
            my $telnet = Net::Telnet->new(Host => $host, Port => $port, Telnetmode => 1);
            $telnet->print("ruok");
            $output = $telnet->getline();
        };

        $self->setIsUpChecked(1);
        $self->setIsUp(0);

        my $isUpResponseRegex = $self->isUpResponseRegex();
        if ( $output && $output =~ /$isUpResponseRegex/ ) {
            $self->setIsUp(1);
        }

        return $self->isUp();
    } else { 
        return $self->SUPER::checkIsUp(); 
    }
}

sub supportsRollingRestart {
    my $self = shift;

    if($self->appName() eq ZOOKEEPER_NODE) {
        return 1;
    } else {
        return 0;
    }
}

1;
