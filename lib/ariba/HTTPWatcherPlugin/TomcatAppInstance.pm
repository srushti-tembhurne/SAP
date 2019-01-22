#$Id: //ariba/services/monitor/lib/ariba/HTTPWatcherPlugin/TomcatAppInstance.pm#54 $
#
# This is shim code for http-monitor that
# implements two functions:
# init($initparam)
# urls(\%url)
#   Urls puts urls as keys to URLS, and a string to look for as value
#
# This is designed to grab all important URLs from AN
# release config files

package ariba::HTTPWatcherPlugin::TomcatAppInstance;

use strict;
use ariba::rc::InstalledProduct;
use ariba::rc::Globals;
use ariba::monitor::OutageSchedule;

my $debug = $main::debug;

sub init {
    my $serviceName = shift;
    my $clusterName = shift;
    my $prodName = shift;

    my @products = ariba::rc::InstalledProduct->installedProductsListInCluster($serviceName, $prodName, undef, $clusterName);

    for my $product ( @products ) {
        printf("%s called for %s,%s,%s\n", (caller)[0], $product->name(), $product->service(), $product->customer()) if $debug;
    }

    return @products;
}

# dump list of URLS in http-watcher-config format

sub urls {
    my @products = @_;

    printf("%s %s() added:\n", (caller)[0,3]) if $debug;

    my $me = ariba::rc::InstalledProduct->new();

    my $hysteresis = 3.5 * 60; # 3.5 mins, has to be < 4
    my $timeout = 15; # time the url has to reply

    my @urls = ();

    for my $product ( @products ) {
        my $customer = $product->customer();
        my $productName = $product->name();
        my $cluster = $product->currentCluster();

        # For active/active products, only check front door from mon's cluster
        my $notInSameClusterAsMon = ariba::rc::Globals::isActiveActiveProduct($productName) && $cluster ne $me->currentCluster();

        # front door
        # buyer, s4 and s4pm front door monitoring is done by SSRealm plug-in
        # SSRealm is hitting real customers front door
        unless ($notInSameClusterAsMon || (grep {$productName eq $_} (ariba::rc::Globals::sharedServiceSourcingProducts(), ariba::rc::Globals::sharedServiceBuyerProducts()))) {

            my $url = $product->default('VendedUrls.FrontDoor');

            if ($productName eq 's2') {
                $url .= "?realm=System&passwordadapter=SourcingSupplierUser";
            }

            if ($productName eq 'dms') {
                $url .= "/monitor/v1/ping";
            }

            my $monUrl = ariba::monitor::Url->new($url);

            if ( $productName =~ /spotbuy/i ){
                $monUrl->setWatchString('<title>(Search Results|Spot Buy)</title>');
            } else {
                $monUrl->setWatchString("Ariba.*Inc.\\s+All Rights Reserved");
            }
            $monUrl->setFollowRedirects(1);

            $monUrl->setHysteresis($hysteresis);
            #
            # give S2 some more time to respond as it has multiple
            # nodes
            if ($productName eq 's2') {
                $monUrl->setTimeout(35);
            } else {
                $monUrl->setTimeout($timeout);
            }

            $monUrl->setNotify($me->default('notify.email'));
            $monUrl->setProductName($productName);
            $monUrl->setCustomerName($customer);
            $monUrl->setRecordStatus("yes");
            $monUrl->setClusterName($cluster);

            if ($customer) {
                $monUrl->setDisplayName("$customer front door");
                $monUrl->setSeverity(1); # s2 is single tenant
            } else {
                $monUrl->setDisplayName("$productName front door");
            }

            # for front-door URLs of instances that are integrated, record
            # the product names of the other instances that rely on this one
            # being up.
            if ($product->isASPProduct() && $product->isInstanceSuiteDeployed()) {
                $monUrl->setSuiteIntegrated("Yes");
                $monUrl->setSuiteProductNames( $product->otherInstanceSuiteMembersList() );
            }

            # For sdb front door as it uses corp authentication
            if ($productName eq 'sdb') {
                $monUrl->setStopFollowingOnPattern(quotemeta("SDB/Main/ad/loginPage/SSOActions"));
            }

            push @urls, $monUrl if ($url);

            if( $productName eq 'supplierrisk' ) {
                $url.="/#/Admin?securePort=30015";

                my $monUrl2 = ariba::monitor::Url->new($url);
                $monUrl2->setDisplayName("Supplier Risk Admin Link");
                $monUrl2->setHysteresis($hysteresis);
                $monUrl2->setTimeout($timeout);
                $monUrl2->setProductName($productName);
                $monUrl2->setCustomerName($customer);
                $monUrl2->setSeverity(2);
                $monUrl2->setRecordStatus("yes");
                $monUrl2->setPageAfterDownInMinutes(60);
                $monUrl2->setNotify($me->default('notify.email'));

                push @urls, $monUrl2 if ($url);
            }

            if( $productName eq 'suppliermanagement' ) {
                $url.="/rest/#/Dashboard";

                my $monUrl2 = ariba::monitor::Url->new($url);
                $monUrl2->setDisplayName("suppliermanagement front door");
                $monUrl2->setHysteresis($hysteresis);
                $monUrl2->setTimeout($timeout);
                $monUrl2->setProductName($productName);
                $monUrl2->setCustomerName($customer);
                $monUrl2->setSeverity(2);
                $monUrl->setWatchString('<iframe id="ReturnToS4IFrame" style="display:none"></iframe>');
                $monUrl2->setRecordStatus("yes");
                $monUrl2->setPageAfterDownInMinutes(60);
                $monUrl2->setNotify($me->default('notify.email'));

                push @urls, $monUrl2 if ($url);
            }

        }

        #
        # s4 apps take too long to come up after nightly
        # recycle. Put them in planned outage for that time.
        #
        # A P0 defect 1-A09D9 has been filed to fix this.
        #
        my $outage;
        if ($productName eq "s4") {
            $outage = ariba::monitor::OutageSchedule->new('daily 22:00-23:59', 'daily 18:00-19:00');
        }
        if ($productName eq "buyer") {
            $outage = ariba::monitor::OutageSchedule->new('daily 23:00-23:59', 'daily 00:00-00:20');
        }

        for my $instance (sort { $a->instance() cmp $b->instance() } $product->appInstancesInCluster($cluster)) {
            next unless ($instance->isTomcatApp() || $instance->isSpringbootApp());

            #
            # monitorstats direct action is only supported in anl
            # phobos or later
            #
            if ($productName eq "anl" &&
                $product->baseMajorReleaseName() <= 3.0) {
                next;
            }

            my $url = $instance->monitorStatsURL();

            my $monUrl = ariba::monitor::Url->new($url);

            $monUrl->setHysteresis($hysteresis);
            $monUrl->setTimeout($timeout);
            $monUrl->setNotify($me->default('notify.email'));
            $monUrl->setProductName($product->name());
            $monUrl->setCustomerName($customer);
            $monUrl->setClusterName($cluster);

            my $displayName = $instance->instanceName();
            $displayName .= ", " . $instance->logicalName() if $instance->logicalName();
            $monUrl->setDisplayName($displayName);
            $monUrl->setInstanceName($instance->instanceName());
            $monUrl->setApplicationName($instance->appName());
            $monUrl->setCommunity($instance->community());
            $monUrl->setLogURL($instance->logURL());
            $monUrl->setInspectorURL($instance->inspectorURL());
            $monUrl->setNoPage("true");
            $monUrl->setPageAfterDownInMinutes(60);

            my $watchString;
            if ($instance->isSpringbootApp()) {
                $watchString = $instance->isUpResponseRegex();
            } else {
                # Tomcat apps: Engineering has confirmed that seeing this string means the node is up 
                $watchString = '</monitorStatus>';
            }
            $monUrl->setWatchString($watchString);

            if ($outage) {
                $monUrl->setOutageSchedule($outage);
            }

            push @urls, $monUrl;
        }
    }

    map { print "config for "; $_->print() } @urls if $debug;

    return @urls;
}

1;
