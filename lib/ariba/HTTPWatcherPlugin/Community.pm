# $Id: //ariba/services/monitor/lib/ariba/HTTPWatcherPlugin/Community.pm#18 $
#
# This is shim code for http-monitor that
# implements two functions:
# init($initparam)
# urls($service,$cluster,$product)
package ariba::HTTPWatcherPlugin::Community;

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

    my $me = ariba::rc::InstalledProduct->new($product);

    my $timeout = 15; # time the url has to reply
    my $productName = $product->name();
    my $service = $product->service();
    my $port = $product->default('WebserverHttpPort');
    my $hysteresis = 1;

    my $frontdoor = $me->default( "VendedUrls.FrontDoor" );
    my @apphosts = $product->hostsForRoleInCluster('communityapp', $product->currentCluster() );
    push @apphosts, $product->hostsForRoleInCluster('communityappadmin', $product->currentCluster() );

    my $url = $product->default( 'SiteURLSecure' );
    $url .= '/internal/phpinfo.php';
    my $monUrl = ariba::monitor::Url->new($url);
    $monUrl->setFollowRedirects("yes");
    $monUrl->setWatchString('Exception');
    $monUrl->setNotify($me->default('notify.email'));
    $monUrl->setProductName($productName);
    $monUrl->setDisplayName("community front door");
    $monUrl->setRecordStatus("yes");
    $monUrl->setHysteresis($hysteresis);
    push (@urls, $monUrl);

    my @monUrls = ( 
        ## 01/17/2014 - Per Amita, these 4 URLs are what we want to monitor externally
	    ## 04/12/2015 - HOA-56036 - Remove monitoring for item_id=Doc3089
        ## 05/05/2016 - HOA-68776 - Need to update connect urls in ops page after AUC GA 0.8.6 on 5/9
        'https://support.ariba.com/AUC_Phones/phone_page/Transactions/en/seller/post',
        'https://support.ariba.com/auc_support_tab/Legacy_Chat_Availability/Transactions/en/seller/post',
        'https://support.ariba.com/XML_Export/Modified_IDs?Count=1',
    );

    foreach my $host ( @apphosts ){
        my $url = "http://$host:$port/internal/phpinfo.php";
        my $logUrl = "http://${host}:61502/lspatapache/community/";
        my $monUrl = ariba::monitor::Url->new($url);
        $monUrl->setFollowRedirects("yes");
        $monUrl->setWatchString('Exception');
        $monUrl->setNotify($me->default('notify.email'));
        $monUrl->setProductName($productName);
        $monUrl->setDisplayName("Application instance '$host:$port'");
        $monUrl->setLogURL($logUrl);
        $monUrl->setRecordStatus("yes");
        push (@urls, $monUrl);
    }
    
    $hysteresis = 3.5 * 60;
    foreach $url ( @monUrls ){
        my $monUrl = ariba::monitor::Url->new($url);
        $monUrl->setHysteresis($hysteresis);
        $monUrl->setTimeout($timeout);
        $monUrl->setFollowRedirects("yes");
        $monUrl->setNotify($me->default('notify.email'));
        $monUrl->setProductName($productName);
        $monUrl->setDisplayName("community external required URL ($url)");
        $monUrl->setRecordStatus("no");
        push (@urls, $monUrl);
    }

    map { print "config for "; $_->print() } @urls if $debug;

    return @urls;
}

1;
