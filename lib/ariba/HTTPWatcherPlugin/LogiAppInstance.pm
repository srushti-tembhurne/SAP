#$Id: //ariba/services/monitor/lib/ariba/HTTPWatcherPlugin/LogiAppInstance.pm#5 $
#
# This is shim code for http-monitor that
# implements two functions:
# init($initparam)
# urls(\%url)
#   Urls puts urls as keys to URLS, and a string to look for as value
#
# This is designed to grab all important URLs from Logi

package ariba::HTTPWatcherPlugin::LogiAppInstance;

use strict;
use ariba::rc::InstalledProduct;
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
        my $productName = $product->name();
        my $cluster = $product->currentCluster();

        # front door
        my $server = ($product->hostsForRoleInCluster('logi-server', $product->currentCluster()))[0];
        next unless ($server); 

        my $port = $product->default('WebServerHttpPort');
        my $url = "http://$server:$port";
        my $monUrl = ariba::monitor::Url->new($url);

        $monUrl->setWatchString('Logi');
        $monUrl->setFollowRedirects(1);

        $monUrl->setHysteresis($hysteresis);
        $monUrl->setTimeout($timeout);

        $monUrl->setNotify($me->default('notify.email'));
        $monUrl->setNoPage("true");
        $monUrl->setProductName($productName);
        $monUrl->setRecordStatus("no");
        $monUrl->setSeverity(2);

        $monUrl->setDisplayName("$productName front door");

        push(@urls, $monUrl) if ($url);

        my $outage = ariba::monitor::OutageSchedule->new('daily 00:00-01:00');

        for my $instance (sort { $a->instance() cmp $b->instance() } $product->appInstancesInCluster($cluster)) {
            my $url = $instance->url();
            next unless ($url && $url =~ /^http/);
        
            my $monUrl = ariba::monitor::Url->new($url);

            $monUrl->setHysteresis($hysteresis);
            $monUrl->setTimeout($timeout);
            $monUrl->setNotify($me->default('notify.email'));
            $monUrl->setProductName($product->name());

            my $displayName = $instance->instanceName();
            $displayName .= ", " . $instance->logicalName() if $instance->logicalName();
            $monUrl->setDisplayName($displayName);
            $monUrl->setInstanceName($instance->instanceName());
            $monUrl->setApplicationName($instance->appName());
            $monUrl->setCommunity($instance->community());
            $monUrl->setLogURL($instance->logURL());
            $monUrl->setNoPage("true");

            $monUrl->setOutageSchedule($outage) if ($instance->appName() eq 'Flume');

            push @urls, $monUrl;
        }
    }

    map { print "config for "; $_->print() } @urls if $debug;

    return @urls;
}

1;
