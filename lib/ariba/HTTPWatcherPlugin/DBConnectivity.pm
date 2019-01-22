# $Id: //ariba/services/monitor/lib/ariba/HTTPWatcherPlugin/DBConnectivity.pm#30 $
#
# This is shim code for http-monitor that
# implements two functions:
# init($initparam)
# urls(\%url)
#   Urls puts urls as keys to URLS, and a string to look for as value
#
# This is designed to grab all important URLs from AN
# release config files

package ariba::HTTPWatcherPlugin::DBConnectivity;

use strict;
use ariba::rc::InstalledProduct;
use ariba::monitor::VendorOutageList;
use ariba::Ops::Startup::Apache;
use ariba::Ops::Constants;
use ariba::monitor::AppInstanceStats;

my $debug = $main::debug;

sub init {
    my $serviceName = shift;
    my $clusterName = shift;
    my $prodName = shift;

    my @products = ariba::rc::InstalledProduct->installedProductsListInCluster($serviceName, $prodName, undef, $clusterName);

    for my $product ( @products ) {
        printf("%s called for %s%s\n", (caller)[0], $product->name(), $product->service()) if $debug;
    }

    return @products;
}

# dump list of URLS in http-watcher-config format

sub urls {
    my @products = @_;
    my @urls = ();

    return @urls unless @products;

    printf("%s %s() added:\n", (caller)[0,3]) if $debug;

    my $me = ariba::rc::InstalledProduct->new();

    for my $product (@products) {
        my $productName = $product->name();
        my $cluster = $product->currentCluster();
        my $service = $product->service();

        my $timeout = 35; # time the url has to reply

        if ($productName =~ /^(anl|acm)$/) {
            my $customer = $product->customer();
            my @instances = $product->appInstancesInCluster($cluster);
            for my $instance (@instances) {


                my $url = $instance->vikingDatabaseStatusURL();
                my $errorString = '<Status>\s*Error:(.+)\s*</Status>';

                my $monUrl = ariba::monitor::Url->new($url);

                $monUrl->setErrorString($errorString);

                # this will only record an up->down in the downtime db if
                # there is a positive notification from the node that it
                # cannot talk to the db (the error string matches)
                $monUrl->setForceSickOnConnectionError(1);

                $monUrl->setTimeout($timeout);
                $monUrl->setNotify($me->default('notify.email'));
                $monUrl->setProductName($productName);
                $monUrl->setCustomerName($customer) if $customer;

                my $logURL = $instance->logURL();
                my $displayName = $instance->instance();

                $monUrl->setDisplayName("Connection to DB");
                $monUrl->setRecordStatus("yes");
                $monUrl->setLogURL($logURL);

                push @urls, $monUrl;

            }
        }

        # This checks for DB connectivity by trying to access a non-existing AN profile
        if ($productName eq "an") {
            my $baseUrl = $product->default('WOCGIAdaptorURLSecure');
            my $buyerUrl = "$baseUrl/Discovery.aw/ad/viewProfile?anid=AN01009999999";
            my $watchString = "profile you requested does not exist";
            my $timeout = 15;
            my $hysteresis = 3.5 * 60; # 3.5 mins, has to be < 4

            my $monUrl = ariba::monitor::Url->new($buyerUrl);

            $monUrl->setWatchString($watchString);
            $monUrl->setTimeout($timeout);
            $monUrl->setNotify($me->default('notify.email'));
            $monUrl->setProductName($productName);

            $monUrl->setDisplayName("Connection to DB");
            $monUrl->setRecordStatus("yes");
            $monUrl->setFollowRedirects(1);
            $monUrl->setUseCookies(1);
            $monUrl->setTryCount(3);
            $monUrl->setStoreOutput(1);
            $monUrl->setHysteresis($hysteresis);

            push @urls, $monUrl;

            # <Database name="<schemaname>" >
            # <Timestamp><timestamp></Timestamp>
            # <Status> OK |Error:<error string></Status>
            # </Database>
        }

        if ($productName =~ m/^(s2|s4pm)$/ && $product->releaseName() !~ /^9s4/) {

            my @instances = $product->appInstancesInCluster($cluster);
            my $customer = $product->customer();
            for my $instance (@instances) {


                my ($url, $errorString);

                $url = $instance->databaseStatusURL();
                $errorString = '<Status>\s*Error:(.+)\s*</Status>';

                my $monUrl = ariba::monitor::Url->new($url);

                $monUrl->setErrorString($errorString);

                # this will only record an up->down in the downtime db if
                # there is a positive notification from the node that it
                # cannot talk to the db (the error string matches)
                $monUrl->setForceSickOnConnectionError(1);

                $monUrl->setTimeout($timeout);
                $monUrl->setNotify($me->default('notify.email'));
                $monUrl->setProductName($productName);
                $monUrl->setCustomerName($customer) if $customer;

                my $logURL = $instance->logURL();
                my $displayName = $instance->instance();

                $monUrl->setDisplayName("Connection to DB");
                $monUrl->setRecordStatus("yes");
                $monUrl->setLogURL($logURL);
                $monUrl->setUiHint("General");

                push @urls, $monUrl;
            }
            # Pick 3 random urls
            if (my $numUrls = scalar(@urls)) {

                # If there are 3 or less urls, all of them are selected
                unless ($numUrls < 4) {
                    my @pickedUrlIndex;

                    # Pick a different random urls until we get 3 of them
                    while (@pickedUrlIndex < 3) {

                        my $pick = int(rand($numUrls));

                        # Pick a url only if it hasn't picked yet
                        push (@pickedUrlIndex, $pick) unless (grep {$_ == $pick} @pickedUrlIndex)
                    }

                    @urls = map {$urls[$_]} @pickedUrlIndex;
                }
            }

            if (@urls) {
                my $url = shift @urls;
                $url->setSecondaryURLs(@urls);
                @urls = ($url);
            }

        } 

        if($productName eq 'sdb') {
            #
            # check load status here
            #
            my @instances = $product->appInstancesLaunchedByRoleInCluster("sdbtask", $cluster);
            my $instance = $instances[0];
            my $monitorStats = ariba::monitor::AppInstanceStats->newFromAppInstance($instance);
            $monitorStats->fetch();
            my $loadStatus = $monitorStats->dnBLoadStatus();

            my $base = $product->default('vendedurls.frontdoortoplevel');
            my $u = $base . "/SDB/services/SupplierData";
            my $monUrl = ariba::monitor::Url->new($u);
            my $post = "<?xml version='1.0' encoding='UTF-8'?><soapenv:Envelope xmlns:soapenv='http://schemas.xmlsoap.org/soap/envelope/' xmlns:xsd='http://www.w3.org/2001/XMLSchema' xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance'>
<soapenv:Body>
        <ns1:getSupplier soapenv:encodingStyle='http://schemas.xmlsoap.org/soap/encoding/' xmlns:ns1='http://webservice.sdb.ariba'>
                <aribaId xsi:type='soapenc:string' xmlns:soapenc='http://schemas.xmlsoap.org/soap/encoding/'>0000000001</aribaId>
        </ns1:getSupplier>
</soapenv:Body>
</soapenv:Envelope>";

            $monUrl->appendToHttpHeaders("SoapAction: query");
            my $authToken = $product->default('Ops.AppInfo.ASMSharedSecret');
            $monUrl->appendToHttpHeaders("Cookie: AuthToken=$authToken");
            $monUrl->setPostBody( $post );
            $monUrl->setContentType('text/xml');
            $monUrl->setUseOutOfBandErrors(1);
            $monUrl->setWatchString('aribaId.*0000000001.*aribaId');

            $monUrl->setDisplayName("Connection to Soap Query");
            $monUrl->setRecordStatus("yes");
            $monUrl->setUiHint("General");
            $monUrl->setTimeout($timeout);
            $monUrl->setNotify($me->default('notify.email'));
            $monUrl->setProductName($productName);
            $monUrl->setSaveRequest(1);

            $monUrl->setForceInfoOnWarn(0);

            push(@urls, $monUrl);
        }

    }

    map { print "config for "; $_->print() } @urls if $debug;

    return @urls;
}

1;
