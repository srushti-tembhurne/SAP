package ariba::monitor::AppInstancesKRStringcounter;

# $Id: //ariba/services/monitor/lib/ariba/monitor/AppInstancesKRStringcounter.pm#1 $

=head1 

USAGE:

 This class contains methods that allows you to get the count of a string in appinstance KR logs

For an appinstance, 

 my $self = ariba::monitor::AppInstancesKRStringcounter->newFromAppInstancesKRStringcounter($instance);
 my $cont = $self->fetch();
 my $count = $self->findStringCount($cont,"all taks threads are busy,rolling");

AUTHOR: Narenthiran Rajaram

=cut

use strict;
use vars qw(@ISA);
use ariba::monitor::Url;

@ISA = qw(ariba::monitor::Url);


sub newFromAppInstancesKRStringcounter {
    my $class = shift;
    my $appInstance = shift;
    my $krurl = shift;
    my $KRStatsURL;
    if ((caller(1))[3] eq 'ariba::monitor::AppInstancesKRStringcounter::findStringCount') {
      $KRStatsURL = '$krurl';
    } else {
      $KRStatsURL = $appInstance->logURL();
    }
    return undef unless ($KRStatsURL);
    my $self = $class->SUPER::new($KRStatsURL);
    return $self;
}

sub fetch {
    my $url_obj = shift;
    $url_obj->setTryCount(3);
    $url_obj->setTimeout(60);
    my $html;
    eval
    {
   $html = $url_obj->request();
    };
   if($@) {
    my $url = $url_obj->fullUrl;
    return "Unable to fetch $url : $@";
   } else {
    return $html;
   }

}

sub findStringCount {
    my $self = shift;
    my $cont= shift;
    my $txtfind = shift;
    chomp($txtfind);
   if ($cont =~ m/Unable to fetch/i) {
      return $cont;
   } elsif ($cont !~ m/Log files matching/i ||  $cont !~ m/tail<\/a>/i) {
      my $failURL = $self->fullUrl;
      return "Unable to fetch KR log from $failURL";
   } else {
    $cont =~ m/<a href\=\"(.*?)\n/i;
    my $m = $1;
    $m =~ m/.*<a href\=\"(.*?)\"/igs;
    my $kr = $1;
    my $kr_obj = __PACKAGE__->newFromAppInstancesKRStringcounter($self,$kr);
    my $krcont = fetch($kr_obj);
    if ($krcont =~ m/Unable to fetch/i) {
       return $krcont;
    } else {
    $krcont =~ s/\n\r\t\f//igs;
    my $busycount = 0;
    while ($krcont =~ m/${txtfind}/igs) {
     $busycount++;
   }
     return $busycount;
    }
   }
}



1;
