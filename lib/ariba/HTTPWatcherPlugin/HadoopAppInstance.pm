#$Id: //ariba/services/monitor/lib/ariba/HTTPWatcherPlugin/HadoopAppInstance.pm#7 $
#
# This is shim code for http-monitor that
# implements two functions:
# init($initparam)
# urls(\%url)
#   Urls puts urls as keys to URLS, and a string to look for as value
#
# This is designed to grab all important URLs from Logi

package ariba::HTTPWatcherPlugin::HadoopAppInstance;

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

        for my $instance (sort { $a->instance() cmp $b->instance() } $product->appInstancesInCluster($cluster)) {
            my $url = $instance->url();
            next unless ($url && $url =~ /^http/);
        
            my $monUrl = ariba::monitor::Url->new($url);

            $monUrl->setHysteresis($hysteresis);
            $monUrl->setTimeout($timeout);
            $monUrl->setNotify($me->default('notify.email'));
            $monUrl->setProductName($product->name());
            $monUrl->setClusterName($cluster);

        my $displayName = $instance->instanceName();
        $displayName .= ", " . $instance->logicalName() if $instance->logicalName();
            $monUrl->setDisplayName($displayName);
            $monUrl->setApplicationName($instance->appName());
            $monUrl->setCommunity($instance->community());
            $monUrl->setLogURL($instance->logURL());
            if ($instance->appName() =~ /^(?:Name|JobTracker)$/o) {
                my $watchString = $instance->appName() eq 'Name' ? 'Active' : 'RUNNING';

                $monUrl->setRecordStatus("yes");
                $monUrl->setWatchString($watchString);
                $monUrl->setFollowRedirects(1);
            } 

            if ($instance->appName() eq 'HbaseMaster') {
                my $host = $instance->host(); 
                my $port = $product->default('Hbase.Master.HttpPort');
                $monUrl->setAdminURL("http://$host:$port") if ($port);
            }

            push @urls, $monUrl;
        }
    }

    map { print "config for "; $_->print() } @urls if $debug;

    return @urls;
}

1;
