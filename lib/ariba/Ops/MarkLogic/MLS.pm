package ariba::Ops::MarkLogic::MLS;

use strict;
#use warnings;
use Data::Dumper;
use base qw(ariba::Ops::MarkLogic::LoadConfig);
use ariba::Ops::NetworkUtils;
use ariba::Ops::DateTime;
use ariba::Ops::MarkLogic::JSON::PP;

$JSON::PP::true=1;
$JSON::PP::false=0;

my $hostname = ariba::Ops::NetworkUtils::hostname();

sub new {
    my ($class,@args )= @_;

    my $self ={};

    bless $self, $class;

    $self->initialise();
    $self->{product} = shift(@args);    
    $self->{service} = shift(@args);    
    return $self;
}

sub getDBsforProduct{
    my ($self,$product) = @_;

    my $cluster = $self->currentCluster();
    return @{$self->{DB_HOST}->{$cluster}->{$product}->{database}};
}


sub getDBMetricFor {
    my ($self,$type,$product) =@_;

    $type='database-status' unless($type);
    if ($product){
        for my $key (keys %{$self->{METRICS}}){
            if ($key =~ /^$product-$type$/isg){
                return $self->{METRICS}->{$key};
            }
        }
    }else{
        for my $key (keys %{$self->{METRICS}}){
            if ($key =~ /^default-$type$/isg){
                return $self->{METRICS}->{$key};
            }
        }
    }
}

sub getDBStatus {
    my ($self,$dbName,$dbMetric) =@_;

    my $hashVal ={};
    my $url = 'http://'.$self->{CLUSTER}.':'.$self->{PORT}.'/manage/LATEST/databases/'.$dbName.'?view=status';

    my $hash = $self->RestCall($url);

    $dbMetric = $self->getDBMetricFor() unless($dbMetric);

    $self->hashWalkMain($hash,$dbMetric,$hashVal);

    return $hashVal;
}

sub getForestStatus{
    my ($self,$dbName,$forestMetric) =@_;

    my $hashVal ={};
    my $url = 'http://'.$self->{CLUSTER}.':'.$self->{PORT}.'/manage/LATEST/forests?view=status&database-id='.$dbName;

    my $hash = $self->RestCall($url);

    $forestMetric = $self->getDBMetricFor('forest-status') unless($forestMetric);

    $self->hashWalkMain($hash,$forestMetric,$hashVal);

    return $hashVal;
}

sub getHostsForCluster{
    my $self = shift;

    my $url = 'http://'.$self->{CLUSTER}.':'.$self->{PORT}.'/manage/LATEST/hosts';
    my $resp = $self->RestCall($url);
    
    my @hosts=();

    for (@{$resp->{'host-default-list'}->{'list-items'}->{'list-item'}}){
        push @hosts, $_->{nameref};
    }
    return @hosts;
}

sub getHostStatus{
    my ($self,$host) =@_;

    my $hashVal ={};
    my $url = 'http://'.$self->{CLUSTER}.':'.$self->{PORT}.'/manage/LATEST/hosts/'.$host.'?view=status';

    my $hash = $self->RestCall($url);

    my $hostMetric = $self->getDBMetricFor('host-status');

    $self->hashWalkMain($hash,$hostMetric,$hashVal);

    return $hashVal;

}

sub getClusterStatus{
    my $self = shift;

    my $hashVal ={};
    my $url = 'http://'.$self->{CLUSTER}.':'.$self->{PORT}.'/manage/LATEST/clusters/'.$self->{CLUSTER}.'-cluster?view=status';

    my $hash = $self->RestCall($url);

    my $clusetrMetric = $self->getDBMetricFor('cluster-status');
    ##print Dumper($clusetrMetric);

    $self->hashWalkMain($hash,$clusetrMetric,$hashVal);

    return $hashVal;
}

sub getCountfor{
    my ($self,$type) = @_;

    my $hashVal ={};
    my $url = 'http://'.$self->{CLUSTER}.':'.$self->{PORT}.'/manage/LATEST/'.$type;
    my $hash = $self->RestCall($url);

    my $dbCountmetric = $self->getDBMetricFor($type.'-count');

    $self->hashWalkMain($hash,$dbCountmetric,$hashVal);

    return $hashVal;
}


sub hashWalkMain{
    my ($self,$hash,$metric,$hashVal) =@_;

    while (my ($key, $val) = each %$metric) {
        if ( $key =~ /^title/i ){
            ##do nothin as of now TBL
             next;
        }
        if (ref $val eq "HASH"){
            hashWalk($val,$hash->{$key},$hashVal,sub {
                my ($value) = @_;
            });
        }elsif(ref $val eq "ARRAY" ){
            my ($table) = grep {$_=~/table:/} @$val;
            ($table) = $table=~ /<table:(.*?)>/isg;
            for my $k (@$val){
                next if ($k=~ /table:/);
                if (ref $k eq "HASH"){
                    hashWalk($k,$hash->{$key},$hashVal,sub {
                        my ($value) = @_;
                    });
                }else{
                    ##$hashVal->{$table}->{$k} = $hash->{$key}->{$k}->{value}.' '.$hash->{$key}->{$k}->{units};
                    if (ref $hash->{$key}->{$k} eq "HASH"){
                        $hashVal->{$table}->{$k} = $hash->{$key}->{$k}->{value};
                    }else{
                        $hashVal->{$table}->{$k} = $hash->{$key}->{$k};
                    }
                    #if ($hashVal->{$table}->{$k} =~ /^available/i){
                    #    $hashVal->{$table}->{$k} = "true" ; 
                    #}elsif ($hashVal->{$table}->{$k} =~ /^unavailable/i){
                    #    $hashVal->{$table}->{$k} = "false";
                    #}
                }
            }
        }
    }
}

sub RestCall{
    my ($self, $url) = @_;
 
    if ( $url =~ /\?/i ){
        $url .='&format=json';
    }else{
        $url .='?format=json';
    }
    my $jsonText = `curl -s --anyauth --user admin:admin -H "Content-type: application/json" -X GET "$url"`;

    my $json = JSON::PP->new->allow_nonref;
    return $json->decode($jsonText);
#    return from_json($jsonText);

}

sub hashWalk {
    my ($hash, $h,$hashVal,$fn) = @_;

    my $table1;
    while (my ($key, $value) = each %$hash) {
        if ('HASH' eq ref $value) {
            hashWalk($value,$h->{$key},$hashVal,$fn);
        }elsif(ref $value eq "ARRAY" ){
            my ($table) = grep {$_=~/table:/} @$value;
            ($table) = $table=~ /<table:(.*?)>/isg;
            $table=~ s/table://g;
            for (@$value){
                next if ($_=~ /table:/);
                ##$hashVal->{$table}->{$_} = $h->{$key}->{$_}->{value}." ".$h->{$key}->{$_}->{units};
                if ( ref $h->{$key}->{$_} eq "HASH" ){
                    $hashVal->{$table}->{$_} = $h->{$key}->{$_}->{value};
                }else{
                    $hashVal->{$table}->{$_} = $h->{$key}->{$_};
                }
                #if ($hashVal->{$table}->{$_} =~ /^available/i){
                #    $hashVal->{$table}->{$_} = "true" ; 
                #}elsif ($hashVal->{$table}->{$_} =~ /^unavailable/i){
                #    $hashVal->{$table}->{$_} = "false";
                #}
            }
        }else{
            if (! $table1){
                my @keys = keys (%$hash);
                my ($table) = grep { $_ =~ /table:/i} @keys;
                ($table1) = $table=~ /<table:(.*?)>/isg;
            }
            next if ($key=~ /table:/i);
            if ( ref $h->{$key} eq "HASH"){
                $hashVal->{$table1}->{$key} = $h->{$key}->{value};
            }else{
                $hashVal->{$table1}->{$key} = $h->{$key};
            }
            #if ($hashVal->{$table1}->{$key} =~ /^available/i){
            #    $hashVal->{$table1}->{$key} = "true" ;
            #}elsif ($hashVal->{$table1}->{$key} =~ /^unavailable/i){
            #    $hashVal->{$table1}->{$key} = "false";
            #}
            ##print "$key and $value\n";
            
        }
    }
}

sub influxit{
    my ($self,$hash, $dbName) = @_;

    my $type;
    if ($dbName =~ /\.ariba\.com/i){
        $type = 'host';
    }else{
        $type = 'db';
    }

    my $emit = ",product=".$self->{'product'}.",service=".$self->{'service'}.",$type=".$dbName.",ran_on_host=".$hostname.",ran_by=".$0." ";

    while (my ($table,$value) = each %$hash){
            my $emit1 = $table.$emit;
        while(my ($key, $val) = each %$value){
            if ($val =~ /[a-z]+/i && $val !~ /(true|false)/i){
                $emit1 .= "$key=\"".$val."\",";
            }else{
                $emit1 .= "$key=".$val.",";
            }
        }
        #$emit1 .= ariba::Ops::DateTime::prettyTime(time());
        $emit1 =~ s/\,$//;
        print "$emit1\n";
    }
}

sub setProduct{
    my $self = shift;

    return $self->{product} if ($self->{product});
    $self->{product} = shift;
}

sub setService{
    my $self = shift;

    return $self->{service} if ($self->{service});
    $self->{service} = shift;
}

1;
