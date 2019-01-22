#!/usr/local/bin/perl -w

package ariba::Ops::PreCheck;
use strict;
use ariba::Ops::TopologyValidator;

sub validateHostAffinity {

    my ($oldProduct,$newProduct,$role,$ignoreHostAffinityValidation) = @_;

    my $ret = 0;
    my @oldAppInstances = $oldProduct->appInstances();
    my @newAppInstances = $newProduct->appInstances();

    my %oldTopologyHash = map {$_->logicalName() => $_->host()} grep { $_->logicalName() =~ /$role/i } @oldAppInstances;
    my %newTopologyHash = map {$_->logicalName() => $_->host()} grep { $_->logicalName() =~ /$role/i } @newAppInstances;

    if (keys (%newTopologyHash) != keys (%oldTopologyHash)) {
       print "Host Affinity has failed\n";
       print "Number of $role is not same in ". $oldProduct->buildName." and ".$newProduct->buildName()."\n"; 
       $ret = -1;
    }
    elsif (!defined($ignoreHostAffinityValidation)){
       foreach my $key (sort keys %oldTopologyHash) {
        if ($oldTopologyHash{$key} ne $newTopologyHash{$key}) {
             print "Host Affinity has failed\n";
             print "$key has been moved from ".$oldTopologyHash{$key}." to ".$newTopologyHash{$key}."\n";
             $ret = -1;
          }
       }
    }
    return $ret;
}

sub validateHostAndPortClash {

    my ($oldProduct,$newProduct) = @_;
    my $ret = 0;
    my @oldAppInstances = $oldProduct->appInstances();
    my @newAppInstances = $newProduct->appInstances();
    
    my $bucket0 = 0;
    my $bucket1 = 1;
    #B0/new B1/old 
    my @bucket0NewInstances = grep { $_->recycleGroup() == $bucket0 } @newAppInstances ;
    my @bucket1OldInstances = grep { $_->recycleGroup() == $bucket1 } @oldAppInstances ;

    my @combinedAppInstances = ();
    push(@combinedAppInstances,@bucket0NewInstances);
    push(@combinedAppInstances,@bucket1OldInstances);

    my @clashList = ariba::Ops::TopologyValidator::getPortClashDetails(\@combinedAppInstances);
    if(scalar(@clashList) != 0){
        print @clashList;
        $ret = -1;
    }
    
    return $ret;
}

sub performPreCheck {

    my ($oldProduct,$newProduct) = @_;
    my $catSearchReturn = validateHostAffinity($oldProduct,$newProduct,'CatSearch');
    my $managerReturn = validateHostAffinity($oldProduct,$newProduct,'Manager','ignoreHostAffinityValidation');
    my $portClashReturn = validateHostAndPortClash($oldProduct,$newProduct);
    if (($catSearchReturn == -1) || ($managerReturn == -1) || ($portClashReturn == -1)) {
        return -1
    }
    return 0;
}

1;

