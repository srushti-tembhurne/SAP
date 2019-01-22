package ariba::Ops::MarkLogic::LoadConfig;

use strict;
use warnings;
use ariba::rc::Product;
use ariba::Ops::MarkLogic::ConfigParser;
use Data::Dumper;

my $constants = {
    METRICS => 'mls-metric.cfg',
    DB_HOST => 'mls-db-host.cfg'
};
my $port = '8002';

my $configDir = ariba::rc::Product->_computeDeployRootFromNothing() . "/" .
                 ariba::rc::Product->_configSubDirectory();
##my $configDir = '../config/';

sub new {
    my ($class,@args)= shift;

    my $self ={};

    bless $self, $class;

    $self->initialise();
    return $self;
}

sub initialise {
    my $self = shift;

    for my $key (keys %{$constants}){
        $self->{$key} = $self->loadFile($constants->{$key});
    }
    $self->getClusterName();
    $self->{PORT} = $port;
}

sub currentCluster{
    my $self = shift;

    for my $key (keys %{$self->{DB_HOST}}){
        if ($key =~ /^primary/isg){
            return $key;
        }
    }
}

sub loadFile {
    my ($self, $fName) =@_;

    $fName = $configDir.'/'.$fName;
    my $cfgParser = ariba::Ops::MarkLogic::ConfigParser->new($fName);

    return $cfgParser->{_DATA};
}

sub getClusterName{
    my $self = shift;

    return $self->{CLUSTER} if ($self->{CLUSTER});
    for my $key (keys %{$self->{DB_HOST}}){
        if ($key =~ /^primary/isg){
            my ($cluster) = $key =~ /-(.*)/isg;
            $self->{CLUSTER} = $cluster;
            return $cluster;
        }
    }
}

1;
