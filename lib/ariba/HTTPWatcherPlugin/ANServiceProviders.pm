# $Id: //ariba/services/monitor/lib/ariba/HTTPWatcherPlugin/ANServiceProviders.pm#13 $
#
# This is shim code for http-monitor to to grab all important commmerce-services
# URLs for AN
#

package ariba::HTTPWatcherPlugin::ANServiceProviders;

use strict;
use ariba::rc::InstalledProduct;
use ariba::Ops::ProductAPIExtensions;
use ariba::Ops::Utils;
use ariba::Ops::OracleClient;

my $debug = $main::debug;
my $urlCache;

sub init {
    my $serviceName = shift;
    my $clusterName = shift;
    my $prodName = shift;

    if (  ariba::rc::InstalledProduct->isInstalled($prodName, $serviceName) ) {
        my $product = ariba::rc::InstalledProduct->new($prodName, $serviceName);

        return undef unless ( $product->currentCluster() eq $clusterName );

        printf("%s called for %s%s\n", (caller)[0], $product->name(), $product->service()) if $debug;

        $urlCache    = "/tmp/" . $product->name(). "-" . $product->service() . "-db-urlcache";

        return $product; 
    }

    return undef;
}

# dump list of URLS in http-watcher-config format
#
# This needs to check both the service table 
# select title, post_url from service where deployment = 'Production' and post_url is not null
# select title, punchout_url from service where deployment = 'Production' and punchout_url is not null
#
# and
# org_transactions -> org, transaction where org is in service provider or
#  s_p_g and org.deployment="Production"
#
#
#

sub urls {
    my $product = shift;
    my @urls = ();

    return @urls unless $product;

    unless ( shouldFetchFromDB() ){
        printf("%s %s() fetched from db too recently, returning cache.\n", (caller)[0,3]) if $debug;
        return readUrlCache();
    }

    printf("%s %s() added:\n", (caller)[0,3]) if $debug;

    my $me = ariba::rc::InstalledProduct->new();
    
    my $hysteresis = 15 * 60; # 15 mins
    my $timeout = 20; # 20 secs

    my $oc = logIntoDB($product) || warn "can't log into db";

    eval {
        my @cols = qw(punchout_url post_url);
        my $colSep = ariba::Ops::OracleClient->colsep();

        my %urlsHash = ();

        for my $col (@cols){
            my $sql = "select title, $col from service where deployment = 'Production' and $col is not null and status = 'Enabled' and title not in ('NetworkRFxView', 'NetworkLogin')";

            my @results;
            $oc->executeSqlWithTimeout($sql, 60, \@results);
            if ($oc->error()) {
                print "Oracle Error: ", $oc->error() if ($debug); 
                next;
            }

            for my $result (@results) {
                my ($title, $url) = split($colSep, $result);

                next unless ($title && $url);
                next if ($url =~ m|^@|o);

                if($title =~ /Ariba\s+SSP/ && $col =~ /(?:punchout_url|post_url)/) {
                    #
                    # SSP punchout has a %s that gets replaced with an
                    # ANID... this ANID was provided by Kam Yue as a
                    # value to use with monitoring for this.
                    #
                    $url = sprintf($url, "AN13000000227");
                }

                # filter out duplicate URLs
                next if exists($urlsHash{$url});
                $urlsHash{$url} = 1;

                my $monUrl = ariba::monitor::Url->new($url);

                #$monUrl->setWatchString($watchstring);
                $monUrl->setHysteresis($hysteresis);
                $monUrl->setTimeout($timeout);
                $monUrl->setNotify($me->default('notify.email'));
                $monUrl->setProductName($product->name());
                $monUrl->setDisplayName("3rdParty $title $col");
                $monUrl->setUrlType("cXML");    # use cXML monitoring on this URL
                $monUrl->setRecordStatus('no');

                if ($title eq 'TRE service post_url') {
                    $monUrl->setSeverity(1);
                }

                push(@urls, $monUrl);
            }
        }
        $oc->disconnect();
    };


    if ($@) {
        warn $@;   # propagate unexpected errors
    }

    writeUrlCache(@urls);

    map { print "config for "; $_->print() } @urls if $debug;

    return @urls;
}

sub logIntoDB {
    my $product = shift;

    my $oc = ariba::Ops::OracleClient->new(ariba::Ops::ProductAPIExtensions::connectInfoForOracleClient($product));

    if ($oc) {
        $oc->connect();
    }

    my $productName = $product->name();

    print "Will open db connection for $productName to fetch service urls\n" if ($debug);

    return $oc;
}

sub writeUrlCache {
    my @urls = @_;

    if (@urls) {
        open(CACHE, "> $urlCache");
        for my $url ( @urls ) {
            $url->saveToStream(*CACHE);
        }
        close(CACHE);
    }

    return 1;
}

sub readUrlCache {
    # since these get added to the Url class cache we don't
    # need to worry about returning the objects

    open(CACHE, $urlCache);
    my @urls = ariba::monitor::Url->createObjectsFromStream(*CACHE);
    close(CACHE);

    return @urls;
}

sub shouldFetchFromDB {

    my $lastFetch = (stat($urlCache))[9] || 0;
    my $frequency = 60*60*4;

    if ( time() > ($lastFetch + $frequency) ){
        return 1;
    } else {
        return undef;
    }
}

1;
