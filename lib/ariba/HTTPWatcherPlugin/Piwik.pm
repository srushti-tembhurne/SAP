# $Id: //ariba/services/monitor/lib/ariba/HTTPWatcherPlugin/Piwik.pm#6 $
#
# This is shim code for http-monitor that
# implements two functions:
# init($initparam)
# urls(\%url)
#   Urls puts urls as keys to URLS, and a string to look for as value
#
# This is designed to grab all important URLs from AN
# release config files

package ariba::HTTPWatcherPlugin::Piwik;

use strict;
use ariba::rc::InstalledProduct;

my $debug = $main::debug;

sub init {
    my $serviceName = shift;
    my $clusterName = shift;
    my $prodName = shift;

    if (  ariba::rc::InstalledProduct->isInstalled($prodName, $serviceName) ) { 

        my $product = ariba::rc::InstalledProduct->new($prodName, $serviceName);

        return undef unless ( $product->currentCluster() eq $clusterName );

        printf("%s called for %s%s\n", (caller)[0], $product->name(), $product->service()) if $debug;

        return $product;
    }

    return undef;
}

# dump list of URLS in http-watcher-config format

sub urls {
    my $product = shift;
    my @urls = ();

    return @urls unless $product;

    printf("%s %s() added:\n", (caller)[0,3]) if $debug;

    my $me = ariba::rc::InstalledProduct->new();

    my $timeout = 15; # time the url has to reply
    my $productName = $product->name();
    my $service = $product->service();

    my $wwwhost = $product->default('ServiceHost');
    my @apphosts = $product->appInstancesLaunchedByRoleInCluster('piwikapps', $product->currentCluster() );
    my $apphost = $apphosts[0]->host();
    
    my $port = $product->default('webserver_port');
    my $index = $product->default('FastCGI.PiwikIndex');
    if($index =~ m|docroot/(.*)$|) {
        $index = $1;
        my $url = "https://${wwwhost}:${port}/$index";
        my $logUrl = "http://${apphost}:61502/lspat/$service/piwik";
        my $monUrl = ariba::monitor::Url->new($url);
        $monUrl->setFollowRedirects("yes");
        $monUrl->setWatchString('Open Source Web Analytics');
        $monUrl->setNotify($me->default('notify.email'));
        $monUrl->setProductName($productName);
        $monUrl->setDisplayName("Piwik Front Door");
        $monUrl->setRecordStatus("no");
        $monUrl->setLogURL($logUrl);

        push (@urls, $monUrl);
    }

    map { print "config for "; $_->print() } @urls if $debug;

    return @urls;
}

1;
