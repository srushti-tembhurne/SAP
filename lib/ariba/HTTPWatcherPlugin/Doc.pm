# $Id: //ariba/services/monitor/lib/ariba/HTTPWatcherPlugin/Doc.pm#3 $
#
# This is shim code for http-monitor that
# implements two functions:
# init($initparam)
# urls(\%url)
#   Urls puts urls as keys to URLS, and a string to look for as value
#
# This is designed to grab all important URLs from AN
# release config files

package ariba::HTTPWatcherPlugin::Doc;

use strict;
use ariba::rc::InstalledProduct;
use ariba::monitor::VendorOutageList;

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

    #
    # http-watcher runs very often, but we only want to check doc every so often
    # because it's expensive
    #

    my $lastTimeRanFile = "/tmp/$productName-$service-lastTimeRanFile-ariba::HTTPWatcherPlugin::Doc";
    my $oneHourAgo = time() - 3600;

    if ( ! -f $lastTimeRanFile || (stat($lastTimeRanFile))[9] < $oneHourAgo ) {

        if ( $product->default('VendedUrls.EntryURL') ){
            my $url = $product->default('VendedUrls.EntryURL');

            my $monUrl = ariba::monitor::Url->new($url);
            $monUrl->setFollowRedirects("yes");
            $monUrl->setWatchString('You may not access Documentation@Ariba from a web browser.');
            $monUrl->setNotify($me->default('notify.email'));
            $monUrl->setProductName($productName);
            $monUrl->setDisplayName("$productName error page");
            $monUrl->setRecordStatus("yes");

            push (@urls, $monUrl);

            # example post          
            #  <form method="post" action="http://service.ariba.com/doc/librarian/start">
            #      <input name="ss" value="AribaDoc" type="hidden"/>
            #      <input name="doc" value="AN" type="hidden"/>
            #      <input name="ut" value="e" type="hidden"/>
            #      <input name="rn" value="someRealm" type="hidden"/>
            #   <input type=submit>
            #    </form>
            #
            #
            # We'd like to do this post, but geturl right now doesn't collect cookies
            # that are set at run time by the server.  When that's fixed, turn this on.
            #
            #$monUrl->setContentType('application/x-www-form-urlencoded');
            #$monUrl->setPostBody("ss=AribaDoc&doc=AN&ut=e&someRealm=rn");


            # example search against google mini
            #
            #<form method="get" action="http://search.ariba.com/search" 
            #   onsubmit="
            #       sitesearch.value = location.hostname + 
            #           location.pathname.replace(/\/(index.htm)?$/,''); 
            #       proxystylesheet.value = 'http://' + location.hostname + 
            #           '/doc/resources/ariba.xslt'; 
            #       host_url.value = 'http://' + location.hostname;
            #">
            #
            #<input type="text" name="q" style="margin-right:10px;" accesskey="4" size=40 maxlength="255" val ue=""/>
            #<input type="hidden" name="site" value="ariba"/>
            #<input type="hidden" name="client" value="ariba"/>
            #<input type="hidden" name="output" value="xml_no_dtd"/>
            #<input type="submit" name="search" value="Search">
            #
            #<!-- define the three hidden field 'variables' assigned above -->
            #<input type="hidden" name="sitesearch" value=""/>
            #<input type="hidden" name="proxystylesheet" value=""/>
            #<input type="hidden" name="host_url" value=""/>
            #</form>
            #
            #http://search.ariba.com/search?q=california&site=ariba&client=ariba&
            #output=xml_no_dtd&search=Search&sitesearch=svcdev.ariba.com%2Fdoc%2FAribaNetwork&
            #proxystylesheet=http%3A%2F%2Fsvcdev.ariba.com%2Fdoc%2Fresources%2Fariba.xslt&
            #host_url=http%3A%2F%2Fsvcdev.ariba.com
            my $baseUrl = $product->default('BaseURL');

            my $hostname = $baseUrl;
            $hostname =~ s|http://||;
            
            my $siteSearch = $hostname . "/doc/AribaNetwork";
            my $proxyStyleSheet = $baseUrl . "/doc/resources/ariba.xslt";
            my $hostUrl = $baseUrl;
            my $site = "ariba";
            my $client = "ariba";
            my $output = "xml_no_dtd";
            my $q = "california";
    
            $url = "http://search.ariba.com/search?" .
                "q=$q&" .
                "site=$site&" .
                "client=$client&" .
                "output=$output&" .
                "sitesearch=$siteSearch&" .
                "proxystylesheet=$proxyStyleSheet&" .
                "host_url=$hostUrl";

            $monUrl = ariba::monitor::Url->new($url);
            $monUrl->setFollowRedirects("yes");
            $monUrl->setWatchString('secure co-location facility');
            $monUrl->setNotify($me->default('notify.email'));
            $monUrl->setProductName($productName);
            $monUrl->setDisplayName("$productName google mini search");
            $monUrl->setRecordStatus("yes");
            
            
            push (@urls, $monUrl);
        }

        open(FILE, "> $lastTimeRanFile");
        print FILE $$,"\n";
        close(FILE);
    }

        map { print "config for "; $_->print() } @urls if $debug;

        return @urls;
}

1;
