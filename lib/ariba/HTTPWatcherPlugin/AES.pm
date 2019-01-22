#$Id: //ariba/services/monitor/lib/ariba/HTTPWatcherPlugin/AES.pm#29 $
#
# This is shim code for http-monitor that
# implements two functions:
# init($initparam)
# urls(\%url)
#   Urls puts urls as keys to URLS, and a string to look for as value
#
# This is designed to grab all important URLs from AN
# release config files

package ariba::HTTPWatcherPlugin::AES;

use strict;
use ariba::rc::InstalledProduct;
use ariba::Ops::Constants;

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

    printf("%s %s() added:\n", (caller)[0,3]) if $debug;

    my $me = ariba::rc::InstalledProduct->new();
    my $hysteresis = 3.5 * 60; # 3.5 mins, has to be < 4
    my $timeout = 15; # time the url has to reply

    # Pass this back to the caller
    my @urls = ();

    for my $product ( @products ) {
        my $cluster = $product->currentCluster();
        my $customer = $product->customer();
        my $productName = $product->name();

        my $baseRelease = $product->baseReleaseName();
        $baseRelease =~ s|\s*\(.*\)||;

        my $baseMajorRelease = $product->baseMajorReleaseName();
        my $baseBuild = $product->baseBuildName();

        { #front door URL via web server
            my $url =  $product->default('sourcing_incominghttpserverurl') || $product->default('sourcing_internalurl');

            # due to the possibility of ANL and AES customers with
            # the same names, we need to append this to the url,
            # otherwise monitoring will hit the analysis site.
            $url .= "/Sourcing/enterprise.jsp";

            my $monUrl = ariba::monitor::Url->new($url);

            $monUrl->setWatchString("Ariba Sourcing");

            $monUrl->setFollowRedirects(1);
            $monUrl->setHysteresis($hysteresis);
            $monUrl->setTimeout($timeout);
            $monUrl->setNotify($me->default('notify.email'));
            $monUrl->setProductName($productName);
            $monUrl->setCustomerName($customer);
            $monUrl->setRecordStatus("yes");

            $monUrl->setDisplayName("$customer front door");
            $monUrl->setSeverity(1); # AES, ANL, ACM are single tenant

            # for front-door URLs of instances that are integrated, record
            # the product names of the other instances that rely on this one
            # being up.
            if ($product->isInstanceSuiteDeployed()) {
                $monUrl->setSuiteIntegrated("Yes");
                $monUrl->setSuiteProductNames( $product->otherInstanceSuiteMembersList() );
            }

            push @urls, $monUrl;
        }

        for my $instance ($product->appInstancesInCluster($cluster)) {

            my $host = $instance->host();

            my ($url, $watchString, $errorString);

            if ( $instance->launchedBy() eq "sourcing" ) {
                $url = $instance->monitorStatsURL();
                $errorString = '<ApplicationBuildNumber>exception</ApplicationBuildNumber>';
            } else {
                my $port = $instance->port();
                $watchString = 'BEA WebLogic Server';
                $url = "http://${host}:${port}/console/login/LoginForm.jsp";
            }

            my $monUrl = ariba::monitor::Url->new($url);

            $monUrl->setErrorString($errorString) if ($errorString);
            $monUrl->setWatchString($watchString) if ($watchString);
            $monUrl->setHysteresis($hysteresis);
            $monUrl->setTimeout($timeout);
            $monUrl->setNotify($me->default('notify.email'));
            $monUrl->setProductName($productName);
            $monUrl->setCustomerName($customer);
            $monUrl->setNoPage("true");
            $monUrl->setPageAfterDownInMinutes(60);

            my $logURL = $instance->logURL();

            $monUrl->setApplicationName($instance->appName());

            $monUrl->setDisplayName($instance->instanceName());
            $monUrl->setLogURL($logURL);

            push @urls, $monUrl;
        }
    }

    map { print "config for "; $_->print() } @urls if $debug;

    return @urls;
}

1;
