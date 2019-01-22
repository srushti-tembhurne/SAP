# $Id: //ariba/services/monitor/lib/ariba/HTTPWatcherPlugin/DeploymentDefaultsUrls.pm#73 $
#
# This is shim code for http-monitor that
# implements two functions:
# init($initparam)
# urls(\%url)
#   Urls puts urls as keys to URLS, and a string to look for as value
#
# This is designed to grab all important URLs from AN
# release config files

package ariba::HTTPWatcherPlugin::DeploymentDefaultsUrls;

use strict;
use ariba::rc::InstalledProduct;
use ariba::monitor::Utils;
use ariba::monitor::VendorOutageList;
use ariba::Ops::Startup::Apache;
use ariba::Ops::Constants;

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

    my $mon = ariba::rc::InstalledProduct->new('mon', $product->service());

    my $hysteresis = 3.5 * 60; # 3.5 mins, has to be < 4
    my $timeout = 15; # time the url has to reply
    my $productName = $product->name();

    if ( $product->default('EstoreTenant.Config1.apcCatalogSearchURL') ) {
        my $url = $product->default('EstoreTenant.Config1.apcCatalogSearchURL');
        if($url =~ /\?/) {
            $url .= '&';
        } else {
            $url .= "?";
        }
        $url .= 'q=(paper)&start=0&rows=1';

        my $monUrl = ariba::monitor::Url->new($url);
        $monUrl->setHysteresis($hysteresis);
        $monUrl->setWatchString('lst');
        $monUrl->setNotify($mon->default('notify.email'));
        $monUrl->setProductName($productName);
        $monUrl->setDisplayName("APC Catalog Search");

        push @urls, $monUrl;
    }

    if ( $product->default('EstoreServiceConfig.loginServiceURL') ) {
        my $url = $product->default('EstoreServiceConfig.loginServiceURL');
        $url =~ s/processXml/monitorStats/;

        my $monUrl = ariba::monitor::Url->new($url);
        $monUrl->setHysteresis($hysteresis);
        $monUrl->setWatchString('XMLServiceApp');
        $monUrl->setNotify($mon->default('notify.email'));
        $monUrl->setProductName($productName);
        $monUrl->setDisplayName("Login Service");

        push @urls, $monUrl;
    }

    if ( $product->default('EstoreAmexVerification.MYCAUrl') ) {
        my $url = $product->default('EstoreAmexVerification.MYCAUrl');

        my $monUrl = ariba::monitor::Url->new($url);
        $monUrl->setHysteresis($hysteresis);
        $monUrl->setNotify($mon->default('notify.email'));
        $monUrl->setProductName($productName);
        $monUrl->setDisplayName("MYCA");

        push @urls, $monUrl;
    }

    if ( $product->default('vendedurls.fxserverurl') ){
        my $url = $product->default('vendedurls.fxserverurl') . "/ad/exchangeRates";

        my $monUrl = ariba::monitor::Url->new($url);
        $monUrl->setHysteresis($hysteresis);
        $monUrl->setWatchString("AUD,USD");
        $monUrl->setNotify($mon->default('notify.email'));
        $monUrl->setProductName($productName);
        $monUrl->setDisplayName("FX Exchange Rates");

        push @urls, $monUrl;
    }

    if ( $product->default('vendedurls.addressserverurl') ){
        my $url = $product->default('vendedurls.addressserverurl') . "/ad/stateZip";

        my $monUrl = ariba::monitor::Url->new($url);
        $monUrl->setHysteresis($hysteresis);
        $monUrl->setWatchString("WY82001");
        $monUrl->setNotify($mon->default('notify.email'));
        $monUrl->setProductName($productName);
        $monUrl->setDisplayName("AIS State/Zipcode mappings");

        push @urls, $monUrl;
    }

    if ( $product->default('vendedurls.ediinthandler') ){

        my $url = $product->default('vendedurls.ediinthandler');
        my $monUrl = ariba::monitor::Url->new($url);

        $monUrl->setWatchString("successful");
        $monUrl->setNotify($mon->default('notify.email'));
        $monUrl->setProductName($productName);
        $monUrl->setDisplayName("EDIINT AS2 POST URL");
        $monUrl->setTimeout(35);

        push @urls, $monUrl;
    }

    if ( $product->default('edi.communication.vanurl') ){
        my $url = $product->default('edi.communication.vanurl');

        my $monUrl;

        if ($product->default('edi.communication.vanid') eq 'INOVIS') {

            $monUrl = ariba::monitor::Url->new($url);
            $monUrl->setDisplayName("Inovis VAN");

            $monUrl->setProductName('edi-van');
            $monUrl->setRecordStatus("yes");

            $monUrl->setOutageSchedule( ariba::monitor::VendorOutageList->outageForVendor('inovis') );

        } else {
            $url =~ s|(http[s]?://[\w\.:]*).*|$1|;

            $monUrl = ariba::monitor::Url->new($url);
            $monUrl->setProductName('edi-van');
            $monUrl->setDisplayName("Sterling VAN");

            #$monUrl->setOutageSchedule( #ariba::monitor::VendorOutageList->outageForVendor('sterling') );
        }

        $monUrl->setTimeout(20);
        $monUrl->setNotify($mon->default('notify.email'));
        $monUrl->setHysteresis($hysteresis);

        push @urls, $monUrl;
    }

    if ($productName eq 'help' && $product->default('vendedurls.frontdoor')) {
        my $url = $product->default('vendedurls.frontdoor');
        my $monUrl;

        #
        # XXXX this does not work yet
        #
        if (0) {
            my $asnOpeningPage = "$url?ss=AribaDoc&doc=AN&ut=s&rn=&ul=";
            $monUrl = ariba::monitor::Url->new($asnOpeningPage);

            $monUrl->setDisplayName("ASN Opening Help Page");
            $monUrl->setHysteresis($hysteresis);
            $monUrl->setWatchString("Introduction to Ariba SN");
            $monUrl->setNotify($mon->default('notify.email'));
            $monUrl->setProductName($productName);

            push @urls, $monUrl;
        }

        my $cxmlSearch = "$url/ad/monops?q=cxml&search=Search&app=AribaNetwork&ul=";

        $monUrl = ariba::monitor::Url->new($cxmlSearch);

        $monUrl->setDisplayName("Search for cXML");
        $monUrl->setHysteresis($hysteresis);
        $monUrl->setWatchString("Creating and Managing Catalogs");
        $monUrl->setNotify($mon->default('notify.email'));
        $monUrl->setProductName($productName);

        push @urls, $monUrl;
    }

    if ($productName eq 'an' && $product->default('cybersource.merchant1.serverurl')) {

        my $monUrl = ariba::monitor::Url->new( $product->default('cybersource.merchant1.serverurl') );

        $monUrl->setDisplayName("CyberSource");
        $monUrl->setHysteresis($hysteresis);
        $monUrl->setWatchString("ics_rmsg=This request was not in HTTP format");
        $monUrl->setNotify($mon->default('notify.email'));
        $monUrl->setProductName($productName);

        push @urls, $monUrl;
    }


    if ( $product->default('actransactionurl') && $productName eq 'an' ) {

        my $url = $product->default('actransactionurl');

        # per bug 59273 add hysteresis
        my $timeout = 35;
        my $monUrl = ariba::monitor::Url->new($url);
        $url =~ s/^https/http/i;
        $monUrl = ariba::monitor::Url->new($url);
        my $email = $mon->default('notify.email');
        $email .= ";" . $mon->default('notify.ANemail');

        unless ( $monUrl->complete() ) {
            $monUrl->setWatchString("");
            $monUrl->setHysteresis($hysteresis);
            $monUrl->setTimeout($timeout);
            $monUrl->setNotify($email);
            $monUrl->setProductName($productName);
            $monUrl->setDisplayName('AN Transaction URL Insecure');

            push @urls, $monUrl;
        }
    }

    if ( $product->default('actransactioncerturl') && $productName eq 'an' ) {

        my $url = $product->default('actransactioncerturl');

        # per bug 59273 add hysteresis
        my $timeout = 35;
        my $monUrl = ariba::monitor::Url->new($url);

        unless ( $monUrl->complete() ) {
            $monUrl->setWatchString("");
            $monUrl->setHysteresis($hysteresis);
            $monUrl->setTimeout($timeout);
            $monUrl->setNotify($mon->default('notify.email'));
            $monUrl->setProductName($productName);
            $monUrl->setDisplayName('AN Certificate Transaction URL Secure');

            my $certsDir = $mon->installDir() . '/lib/certs';
            my $certFile = "$certsDir/ops.ariba.com.cert";
            my $certKeyFile = "$certsDir/ops.ariba.com.key";
            my $certKeyPassword = $mon->default('SSLCertificate.password');
            $monUrl->setClientCertFile($certFile);
            $monUrl->setClientCertKeyFile($certKeyFile);
            $monUrl->setClientCertKeyPassword($certKeyPassword);

            push @urls, $monUrl;
        }
    }


    for my $key ( 'acbuyerurl', 'acsupplierurl' ){

        next unless ( $productName eq 'an');

        if ( $product->default($key) ){
            my $url = $product->default($key);

            my $monUrl = ariba::monitor::Url->new($url);

            unless ( $monUrl->complete() ) {
                $monUrl->setWatchString("");
                $monUrl->setHysteresis(undef);
                $monUrl->setNotify($mon->default('notify.email'));
                $monUrl->setProductName($productName);
                $monUrl->setDisplayName($url);

                push @urls, $monUrl;
            }
        }

        #my $loginURL = "https://svcdev.ariba.com/Supplier.aw/ad/login?username=nramani-supplier@ariba.com&password=welcome";
    }

    if ( $product->default('vendedurls.cxmlhome') ){
        my $url = "http://" . $product->default('vendedurls.cxmlhome');

        my $monUrl = ariba::monitor::Url->new($url);

        $monUrl->setWatchString("the catalog has errors");
        $monUrl->setHysteresis(undef);
        $monUrl->setNotify(undef);
        $monUrl->setProductName($productName);
        $monUrl->setDisplayName("Current CXML dtd");

        push @urls, $monUrl;
    }

    if ( $product->default('fax.visionlab.url') ){
        #
        # for now we're going to use the ping URL since we need time
        # to sort out the post stuff.
        #
        # my $url = $product->default('fax.visionlab.url');
        my $url = "https://upload.venali.net/xml2fax/1.1/ping.asp";

        my $monUrl = ariba::monitor::Url->new($url);

        $monUrl->setWatchString("");
        $monUrl->setHysteresis(15 * 60);
        $monUrl->setTimeout(20);
        $monUrl->setNotify(undef);
        $monUrl->setProductName('fax');
        $monUrl->setRecordStatus("yes") unless $product->service() eq "sales";
        $monUrl->setDisplayName("3rdParty Vision Lab FAX Post");

        push @urls, $monUrl;
    }

    if ( $product->default('fax.xpedite.authenticateuserurl') ){

        my $url = $product->default('fax.xpedite.authenticateuserurl');
        my ($username, $password);

        if ($product->default('fax.xpedite.httpspost.userid')) {
            $username = $product->default('fax.xpedite.httpspost.userid');
            $password = $product->default('fax.xpedite.httpspost.password');
        } else {
            $username = $product->default('fax.xpedite.xpediteid');
            $password = $product->default('fax.xpedite.xpeditepassword');
        }

        my $monUrl = ariba::monitor::Url->new($url);

        $monUrl->setContentType('multipart/form-data; boundary="-"');

my @post = <<ENDOFPOST;

---
Content-Disposition: form-data; name="XpediteUserID"

$username
---
Content-Disposition: form-data; name="XpeditePassword"

$password
---
Content-Disposition: form-data; name="PasswordEncoding"

PLAINTEXT
---
Content-Disposition: form-data; name="AuthTokenTimeout"

100
---
Content-Disposition: form-data; name="Version"

1.0
---
Content-Disposition: form-data; name="TrackingInfo"

ClientVersion=1,ClientName=http-watcher,ClientVariant=none,ClientConfig=Standalone,OSversion=Solaris,user.name=none,LanguageCode=EN,CountryCode=US
-----
ENDOFPOST


        $monUrl->setPostBody(@post);

        $monUrl->setWatchString("Success");
        $monUrl->setHysteresis(15 * 60);
        $monUrl->setTimeout(20);
        $monUrl->setNotify(undef);
        $monUrl->setProductName('fax');
        $monUrl->setDisplayName("3rdParty Xpedite FAX AuthenticateUser");
        $monUrl->setOutageSchedule( ariba::monitor::VendorOutageList->outageForVendor('xpedite') );
        $monUrl->setRecordStatus("yes") unless $product->service() eq "sales";

        push @urls, $monUrl;
    }

    my $trustWeaverXMLPath = $product->default("Ops.TrustWeaverSignatureSwitchXML");
    if ($trustWeaverXMLPath) {
        my $sswitchDefs = {};
        ariba::util::XMLWrapper::parse($trustWeaverXMLPath, $sswitchDefs);
        if (keys %$sswitchDefs) {

            my $sswitchUrl = ariba::monitor::Url->new
                ($sswitchDefs->{"wsdl:definitions.wsdl:service.wsdl:port.soap12:address.location"});

my @post = <<ENDOFPOST;
<?xml version="1.0" encoding="utf-8"?>
<soap12:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:soap12="http://www.w3.org/2003/05/soap-envelope">
    <soap12:Body />
</soap12:Envelope>
ENDOFPOST

            $sswitchUrl->setPostBody(@post);
            $sswitchUrl->setContentType("application/soap+xml; charset=utf-8");
            $sswitchUrl->setWatchString("ProductEdition");

            # these are set according to the SLA agreement
            # //ariba/services/operations/documentation/vendors/trustweaver_sla.doc

            $sswitchUrl->setHysteresis(10 * 60);
            $sswitchUrl->setTimeout(60);

            $sswitchUrl->setNotify($mon->default('notify.email'));
            $sswitchUrl->setProductName('invoice-signing');
            $sswitchUrl->setDisplayName("3rdParty TrustWeaver Signature Switch Service");
            $sswitchUrl->setRecordStatus("yes");

            my $pkcs12File = $product->default("esigclient.identitykeystore.file");
            $pkcs12File = $product->installDir() . "/$pkcs12File";

            $sswitchUrl->setClientCertPkcs12File($pkcs12File);
            $sswitchUrl->setClientCertKeyPassword($product->default("esigclient.identitykeystore.password"));

            push(@urls, $sswitchUrl);
        }
    }

    if ( $productName eq "ws" || $productName eq "aesws" || $productName eq "ssws" || $productName eq "cws" || $productName =~ /^ows/o) {

        my $webserverRole;
        if ( $productName eq "ws" ) {
            $webserverRole = "webserver";
        } elsif ( $productName eq "aesws" ) {
            $webserverRole = "aes-webserver";
        } elsif ( $productName eq "ssws" ) {
            $webserverRole = "ss-webserver";
        } elsif ( $productName eq "cws" ) {
            $webserverRole = "cwswebserver";
       } elsif ( $productName =~ /^ows/o ) {
            $webserverRole = "ows-webserver";
        }

        my @webservers = $product->hostsForRoleInCluster(
                    $webserverRole,
                    $product->currentCluster()),

        my $httpsPort = $product->default('webserverhttpsport');
        my $httpPort = $product->default('webserverhttpport');
        my $certHttpsPort = $product->default('certserverhttpsport');

        my @urlTypes = (
            {
                type     => 'page',
                protocol => 'http',
                port     => $httpPort,
                display  => 'http',
            },
            {
                type     => 'page',
                protocol => 'https',
                port     => $httpsPort,
                display  => 'https',
            },
        );

        if ( defined($certHttpsPort) ) {
            push (@urlTypes,
            {
                type     => 'SSLCertOnly',
                protocol => 'https',
                port     => $certHttpsPort,
                display  => 'https certserver',
            });
        }

        for my $www (@webservers) {

            for (my $i = 0; $i < @urlTypes; $i++) {

                next if ( $productName eq "cws" && $urlTypes[$i]->{protocol} eq "http" );
                my $url = $urlTypes[$i]->{protocol} . "://$www:" . $urlTypes[$i]->{port};


                my $monitoredUrl = $url;

                if ($productName eq "ssws") {
                    $monitoredUrl .= '/notfound.html';
                } elsif ($productName eq "ws") {
                    $monitoredUrl .= '/default.htm';
                } elsif ($productName eq "cws") {
                    $monitoredUrl .= '/balancer-manager';
                }

                my $monUrl = ariba::monitor::Url->new($monitoredUrl);
                $monUrl->setWatchString("");
#                if ( $productName eq "cws" ){ $monUrl->setWatchString("Session Timed Out"); }
                $monUrl->setHysteresis(undef);
                $monUrl->setNotify(undef);
                $monUrl->setProductName($productName);
                $monUrl->setDisplayName("$www " . $urlTypes[$i]->{display});

                if ($urlTypes[$i]->{type} eq 'SSLCertOnly') {
                    $monUrl->setCheckSSLCertOnly(1);
                } else {
                    $monUrl->setCheckSSLCertOnly(0);
                }

                if ($urlTypes[$i]->{display} =~ /certserver/) {
                    my $certsDir = $mon->installDir() . '/lib/certs';
                    my $certFile = "$certsDir/ops.ariba.com.cert";
                    my $certKeyFile = "$certsDir/ops.ariba.com.key";
                    my $certKeyPassword = $mon->default('SSLCertificate.password');
                    $monUrl->setClientCertFile($certFile);
                    $monUrl->setClientCertKeyFile($certKeyFile);
                    $monUrl->setClientCertKeyPassword($certKeyPassword);
                }

                my $apacheUrl = ariba::Ops::Startup::Apache::logViewerUrlForProductRoleHostPort($product, $webserverRole, $www, $urlTypes[$i]->{port});

                $monUrl->setLogURL($apacheUrl);


                #
                # Put jkstatus link as inspector link on
                # mon page for now, for use with debugging
                #
                if ( $productName eq "ssws" || $productName eq "aesws") {
                    my $jkStatusURL = "$url/jkstatus";
                    $monUrl->setInspectorURL($jkStatusURL);
                }

                push @urls, $monUrl;
            }

            # Check the adaptor status page for each webserver
            if ( $productName eq "ws" && $product->default('woadminurl') ) {

                my $url = sprintf("https://$www:$httpsPort%s", $product->default('woadminurl'));

                my $monUrl = ariba::monitor::Url->new($url);

                $monUrl->setWatchString("");
                $monUrl->setHysteresis(undef);
                $monUrl->setNotify(undef);
                $monUrl->setTimeout(60);
                $monUrl->setProductName($productName);
                $monUrl->setDisplayName("WO Adaptor Status Page on $www");
                $monUrl->setStoreOutput(1);
                $monUrl->setSaveRequest(1);

                push @urls, $monUrl;
            }

            # Check the plugin status page for each webserver
            # jkstatus has been very flaky and times out all
            # the time. Disable this monitoring for now, until
            # its more stable. TMID: 23121
            if ( 0 && $productName eq "ssws" ) {

                my $url = "http://$www:$httpPort/jkstatus";

                my $monUrl = ariba::monitor::Url->new($url);

                $monUrl->setWatchString("");
                $monUrl->setHysteresis(5 * 60); # 5 minutes
                $monUrl->setNotify(undef);
                $monUrl->setProductName($productName);
                $monUrl->setDisplayName("JK Status Page on $www");

                # due to a bug in the loadbalancer, one of the webservers
                # might experience a higher load than another.  This should
                # give enough time to avoid false errors.
                $monUrl->setTimeout(35);

                push @urls, $monUrl;
            }
        }
    }

    if ( $productName eq "ws" || $productName eq "ssws" || $productName eq "cws" ) {

        # admin webservers for this service/cluster
        my $adminserverRole;
        if ( $productName eq "ws" ) {
            $adminserverRole = "adminserver";
        } elsif ( $productName eq "ssws" ) {
            $adminserverRole = "ss-adminserver";
        } elsif ( $productName eq "cws" ) {
            $adminserverRole = "cwsadminserver";
        }

        my @adminservers = $product->hostsForRoleInCluster(
            $adminserverRole, $product->currentCluster()
        );

        my @protocols = "https";
        my @ports     = $product->default('webserverhttpsport');

        for my $admin (@adminservers) {
            for (my $i = 0; $i < @protocols; $i++) {
                my $url = "$protocols[$i]://$admin:$ports[$i]";

                if ( $productName eq "cws" ){ $url .= '/balancer-manager'; }
                my $monUrl = ariba::monitor::Url->new($url);
                $monUrl->setWatchString("");
                $monUrl->setHysteresis(undef);
                $monUrl->setNotify(undef);
                $monUrl->setProductName($productName);
                $monUrl->setDisplayName("adminserver at $admin $protocols[$i]");

                my $apacheUrl = ariba::Ops::Startup::Apache::logViewerUrlForProductRoleHostPort($product, $adminserverRole, $admin, $ports[$i]);

                $monUrl->setLogURL($apacheUrl);

                push @urls, $monUrl;
            }
        }

        # Add integration legacy front door
        if ( $productName eq 'ws' ) {
            my $monUrl;
            my $serviceName =  $product->service();
            my $int_host = ariba::monitor::Utils::integration_host($productName, $serviceName, 1);
            if ( ariba::monitor::Utils::dns_exists($int_host)) {
                $monUrl = ariba::monitor::Url->new("https://$int_host");
                $monUrl->setWatchString("");
                $monUrl->setHysteresis(undef);
                $monUrl->setNotify(undef);
                $monUrl->setProductName($productName);
                $monUrl->setDisplayName("integration legacy front door");
                push @urls, $monUrl;
            }
        }
    }

    map { print "config for "; $_->print() } @urls if $debug;

    return @urls;
}

1;

