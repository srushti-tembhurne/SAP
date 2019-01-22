# $Id: //ariba/services/monitor/lib/ariba/HTTPWatcherPlugin/WOFAppInstance.pm#15 $
#
# This is shim code for http-monitor that
# implements two functions:
# init($initparam)
# urls(\%url)
#   Urls puts urls as keys to URLS, and a string to look for as value
#
# This is designed to grab all important URLs from AN
# release config files

package ariba::HTTPWatcherPlugin::WOFAppInstance;

use strict;
use ariba::rc::InstalledProduct;
use ariba::rc::ArchivedProduct;

my $debug = $main::debug;

sub init {
    my $serviceName = shift;
    my $clusterName = shift;
    my $prodName = shift;

    if (ariba::rc::InstalledProduct->isInstalled($prodName, $serviceName)) {

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

    my $product_name = $product->name();

    return @urls if $product->name() eq 'estore';

    printf("%s %s() added:\n", (caller)[0,3]) if $debug;

    my $me = ariba::rc::InstalledProduct->new();

    my $hysteresis = 3.5 * 60; # 3.5 mins, has to be < 4
    my $timeout = 15; # time the url has to reply

    my $cluster = $product->currentCluster();

    for my $instance (sort { $a->instance() cmp $b->instance() } $product->appInstancesInCluster($cluster)) {
    
        my $watchstring;
        if ($instance->isDispatcher()) {
            $watchstring = '(isPrimary>false|Worker\d+>alive)';
        } else {
            $watchstring = undef;
        }

        my $url = $instance->monitorStatsURL();
        my $monUrl = ariba::monitor::Url->new($url);

        $monUrl->setWatchString($watchstring);
        $monUrl->setHysteresis($hysteresis);
        $monUrl->setTimeout($timeout);
        $monUrl->setNotify($me->default('notify.email'));
        $monUrl->setProductName($product->name());

        $monUrl->setApplicationName($instance->appName());
        $monUrl->setCommunity($instance->community());
        $monUrl->setLogURL($instance->logURL());
        $monUrl->setNoPage("true");
        $monUrl->setPageAfterDownInMinutes(60);

        my $displayName = $instance->instanceName();
        $displayName .= ", " . $instance->logicalName() if $instance->logicalName();
        $monUrl->setDisplayName($displayName);
        $monUrl->setInstanceName($instance->instanceName());

        push @urls, $monUrl;

        # build a URL for any front-door applications we need to report to
        # customers, based on the recordStatus 

        my $recordStatus = $instance->recordStatus();

        my $adaptorUrl;

        if ($product->default("wocgiadaptorurlsecure")) {
            $adaptorUrl = $product->default("wocgiadaptorurlsecure");
        } else {
            $adaptorUrl = $product->default("wocgiadaptorurl");
        }

        my $appUrl = $adaptorUrl."/".$instance->exeName().$product->default('anapplicationnamesuffix');

        if ( defined($recordStatus) and $recordStatus eq "yes" and 
            ( !ariba::monitor::Url->_objectWithNameExistsInCache($appUrl) || 
            !defined(ariba::monitor::Url->_objectWithNameFromCache($appUrl)->complete()) )
            ){

            my $recordURL = ariba::monitor::Url->new($appUrl);
            $recordURL->setWatchString($watchstring);
            $recordURL->setHysteresis($hysteresis + 20);
            $recordURL->setNotify($me->default('notify.email'));
            $recordURL->setProductName($product->name());
            $recordURL->setDisplayName($instance->exeName());
            $recordURL->setRecordStatus($recordStatus);
            if($recordURL->displayName() =~ /^(?:Buyer|Supplier|ANCXMLPunchOutProcessor|.*Admin.*)$/) {
                $recordURL->setSeverity(0);
            }
            $recordURL->setComplete("yes");

            if ( $instance->redir() && $instance->redir() =~ /xml/ ) {
                # give our cXML inbound apps more time to reply
                $recordURL->setTimeout(35);
            } elsif ( $instance->instance() =~ /EDIIntHandler/ ) {
                # give EDIIntHandler front door more time to reply
                $recordURL->setTimeout(35);
            } else {
                $recordURL->setTimeout($timeout);
            }

            push @urls, $recordURL;
        }
    }

    map { print "config for "; $_->print() } @urls if $debug;

    return @urls;
}

1;
