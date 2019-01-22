# $Id: //ariba/services/monitor/lib/ariba/HTTPWatcherPlugin/SSRealms.pm#37 $
#
# This is shim code for http-monitor to to grab realms and their associated
# URLs for shared service database.
#

package ariba::HTTPWatcherPlugin::SSRealms;

use strict;
use ariba::rc::InstalledProduct;
use ariba::Ops::ProductAPIExtensions;
use ariba::Ops::Utils;
use ariba::Ops::OracleClient;
use ariba::Ops::ServiceController;
use ariba::monitor::Utils;

my $debug = $main::debug;

## Cache file names
my $urlCache;
my $urlCacheAdv;
#   integration cache file names
my $urlCacheInt;
my $urlCacheIntAdv;

my $resultsForRealmType;
my $hysteresis = 3.5 * 60; # 3.5 mins, has to be < 4

# Integration flags
my $has_integration;
my $has_integration_legacy;
# Integration host names
my $int_name;
my $int_name_legacy;

my ($INTEGRATED, $STANDALONE) = ("integrated", "standalone");

# This takes an additional string argument to determine whether to return
# "integrated" or "standalone" (non-integrated) realms.
# If this arg is undef it will return all realms (old behaviour).
#

sub init {
    my $serviceName = shift;
    my $clusterName = shift;
    my $prodName = shift;
    my $realmType = shift; # this should be 'integrated' or 'standalone'

    if ($realmType ) {
        $realmType = lc($realmType);
        if ( ($realmType ne $INTEGRATED) && ($realmType ne $STANDALONE)) {
            die "Error in ".__PACKAGE__."::urls()  second arg must be either $INTEGRATED or $STANDALONE";
        }
        $resultsForRealmType = $realmType;
    }
    else {
        $resultsForRealmType = undef;
    }

    if (  ariba::rc::InstalledProduct->isInstalled($prodName, $serviceName) ) {
        my $product = ariba::rc::InstalledProduct->new($prodName, $serviceName);

        return undef unless ( $product->currentCluster() eq $clusterName );

        # determine if the service supports advanced integration urls
        $int_name = ariba::monitor::Utils::integration_host('ssws', $serviceName);
        if ($int_name) {
            my $dns_exists = ariba::monitor::Utils::dns_exists($int_name);
            if ($dns_exists) {
                $has_integration = 1;
            }
        }

        # determine if the service supports legacy integration urls
        $int_name_legacy = ariba::monitor::Utils::integration_host('ssws', $serviceName, 1);
        if ($int_name_legacy) {
            my $check_product = $product->name();
            my $check_service = $product->service();
            
            # Remove integration legacy front door monitoring for Buyer and s4 in SNV,EU,RU - HOA-167097
            if (($check_product eq 's4' || $check_product eq 'buyer') && ($check_service eq 'prod' || $check_service eq 'prodeu' || $check_service eq 'prodru')) {
                $has_integration_legacy = 0;
            } elsif ( ariba::monitor::Utils::dns_exists( $int_name_legacy ) ) {
                $has_integration_legacy = 1;
            }
        }

        printf("%s called for %s%s\n", (caller)[0], $product->name(), $product->service()) if $debug;

        $urlCache    = "/tmp/" . $product->name(). "-" . $product->service();
        $urlCacheAdv = "/tmp/" . $product->name(). "-" . $product->service() . '-adv';
        $urlCacheInt = "/tmp/" . $product->name(). "-" . $product->service() . '-int';
        $urlCacheIntAdv = "/tmp/" . $product->name(). "-" . $product->service() . '-intadv';

        if ($realmType) {
            $urlCache .= "-$realmType";
            $urlCacheAdv .= "-$realmType";
        }
        $urlCache .= "-db-urlcache";
        $urlCacheAdv .= "-db-urlcache";
        $urlCacheInt .= "-db-urlcache";
        $urlCacheIntAdv .= "-db-urlcache";

        return $product;
    }

    return undef;
}

# return list of URLs in http-watcher-config format (monitoring url objects)
#
# This needs to check realmtab and communitytab and get a list of
# urls for each enabled realm and their corresponding communities.
#
sub urls {
    my $product = shift;

    my @urls = ();
    my @urls_adv = ();
    # integration urls
    my @urls_int = ();
    my @urls_int_adv = ();

    return @urls unless $product;

    my @urls_ret = ();

    my $product_name = $product->name();

    unless ( shouldFetchFromDB() ){
        printf("%s %s() fetched from db too recently, returning cache.\n", (caller)[0,3]) if $debug;
        return (readUrlCacheCombined($product));
    }

    my $customerLoginURLs = $product->default('System.PasswordAdapters.PasswordAdapter1.LoginURLs');
    my $customerLoginURLTemplate = $customerLoginURLs->[0];

    my $watchString = "(Login to Ariba|Status 401)";

    printf("%s %s() added:\n", (caller)[0,3]) if $debug;

    my $me = ariba::rc::InstalledProduct->new();

    my $timeout = 20; # 20 secs

    my %activeCommunities = ();
    for my $appInstance ( $product->appInstances() ) {
        $activeCommunities{$appInstance->community()} = 1 if $appInstance->community();
    }

    my $oc = logIntoDB($product) || warn "can't log into db";

    my $service = $product->service();

    eval {
        my $colSep = ariba::Ops::OracleClient->colsep();

        my $selectClause = "SELECT rt.name, ct.communityid, rt.id, rpt.rp_EnterpriseUserURLFormat";
        my $fromClause = "FROM realmtab rt, communitytab ct";
        my $whereClause = "WHERE rt.id = ct.realmid AND rt.state = 'enabled'";

        if ($resultsForRealmType) {
            my $integrationComparator;
            if ($resultsForRealmType eq $INTEGRATED) {
                $integrationComparator = '<>';
            }
            else {
                $integrationComparator = '=';
            }

            $fromClause .= q`, realmprofiletab rpt`;
            $whereClause .= qq`
                        AND (rpt.rp_Id = rt.id)
                        AND (rpt.rp_IntegrationStatus $integrationComparator 0)
                        AND (rpt.rp_PartitionNumber = 0)
                        AND (rpt.rp_PurgeState = 0)
                        AND (rpt.rp_Active = 1)
                   `;
        }

        my $sql = join(" ", $selectClause, $fromClause, $whereClause);


        my @results;
        $oc->executeSqlWithTimeout($sql, 60, \@results);

        for my $result (@results) {
            my ($realm_name, $communityId, $realm_id, $urlFormat) = split($colSep, $result);

            # skip inactive communites; in prod this will not be an
            # issue, but in many devlab services realms are assigned
            # to communities that don't have any nodes assigned to
            # them
            next unless $activeCommunities{$communityId};

            #
            # XXXX Hack for now, to get rid of reporting realms
            #
            next if ($realm_name =~ /^rpt_/);
            #
            # also skip this one -- it won't work and it's a known test realm.
            #
            next if ($realm_name =~ /^analysisadmin$/i);

            next if (!(ariba::Ops::ServiceController::checkFunctionForService($service, 'ssrealms')) && $realm_name =~ /^rpt/);

            #
            # XXXX Hack for now, ssws rewrite rule is not correct and need to be fixed
            #
            next if ($realm_name =~ /\./);

            my $url = $customerLoginURLTemplate;

            # check if url is advanced
            my $adv_str = '';
            my $is_advanced = isAdvancedRealm ($service, $product, $realm_id);
            if ( $is_advanced ) {
                $adv_str = ' advanced';
                $url = $urlFormat;
            }

            $url =~ s|<realm>|$realm_name|g;

            my $monUrl = ariba::monitor::Url->new($url);
            update_mon_url($me, $product, $realm_name, $communityId, $adv_str, $watchString, $timeout, $url, $monUrl);

            if ($is_advanced) {
                push(@urls_adv, $monUrl);
            }
            else {
                push(@urls, $monUrl);
            }

            # add integration urls
            if ( $has_integration ) {
                my $context = 'Buyer';
                $context = 'Sourcing' if ( $product_name eq 's4' );
                if ($is_advanced) {
                    my $url_int = "https://$int_name/$context/Main?realm=$realm_name";
                    # create seperate new mon url for integration url
                    my $intUrl = ariba::monitor::Url->new($url_int);
                    update_mon_url($me, $product, "", 0, $adv_str, $watchString, $timeout, $url_int, $intUrl);
                    push(@urls_int_adv, $intUrl);
                }
                if ($has_integration_legacy) {
                    my $url_int_legacy = "https://${int_name_legacy}/$context/Main?realm=$realm_name";
                    # create seperate new mon url for integration url
                    my $intUrlLegacy = ariba::monitor::Url->new($url_int_legacy);
                    update_mon_url($me, $product, "", 0, $adv_str, $watchString, $timeout, $url_int_legacy, $intUrlLegacy);
                    push(@urls_int, $intUrlLegacy);
                }
            }
        }
        $oc->disconnect();
    };

    my $error = $@ || $oc->error();

    if ($error) {
        warn $error if ($debug);   # propagate unexpected errors
    } else {
        writeUrlCache(0, @urls);
        writeUrlCache(1, @urls_adv);
        writeUrlCache(2, @urls_int) if ($has_integration_legacy);
        writeUrlCache(3, @urls_int_adv) if ($has_integration);
    }

    map { print "config for "; $_->print() } @urls if $debug;

    return(readUrlCacheCombined($product));
}

sub update_mon_url {
    my ($me, $product, $realm_name, $communityId, $adv_str, $watchString, $timeout, $url, $monUrlref)  = @_;

    $monUrlref->setWatchString($watchString);
    $monUrlref->setFollowRedirects(1);
    $monUrlref->setUseCookies(1);
    $monUrlref->setStopOnError(1);
    $monUrlref->setTimeout($timeout);
    $monUrlref->setNotify($me->default('notify.email'));
    $monUrlref->setProductName($product->name());
    if ( $realm_name ) {
        $monUrlref->setRealmName($realm_name);
    }

    if ( $url =~ /\-integration\-legacy/ ) {
        $monUrlref->setDisplayName($product->name() . " integration legacy front door");
        $monUrlref->setRecordStatus('yes');
        $monUrlref->setSeverity(0);
    }
    elsif ( $url =~ /\-integration/ ) {
        $monUrlref->setDisplayName($product->name() . " integration advanced front door");
        $monUrlref->setRecordStatus('yes');
        $monUrlref->setSeverity(0);
    }
    # non integration realms
    elsif ($resultsForRealmType && $resultsForRealmType eq $INTEGRATED) {
        $monUrlref->setDisplayName($product->name() . "$adv_str integrated realms front door");
        $monUrlref->setRecordStatus('no');
    } else {
        $monUrlref->setDisplayName($product->name() . "$adv_str front door");
        $monUrlref->setRecordStatus('yes');
        $monUrlref->setSeverity(0);
    }
    $monUrlref->setStoreOutput(1);

    #FIXME temporary hack to avoid paging on saml sites that don't use externalSite=true,
    # only used for newyorklife (realm nylprocure-t).
    $monUrlref->setStopFollowingOnPattern("externalSite=true|siteminderagent");
    if ($communityId) {
        $monUrlref->setCommunity($communityId);
    }
    $monUrlref->setHysteresis($hysteresis);
    $monUrlref->setNotifyWhenSick(1);
    $monUrlref->setSaveRequest(1);
}


sub logIntoDB {
    my $product = shift;

    my $oc = ariba::Ops::OracleClient->new(ariba::Ops::ProductAPIExtensions::connectInfoForOracleClient($product));

    if ($oc) {
        $oc->connect();
    }

    my $productName = $product->name();

    print "Will open db connection for $productName to fetch realm urls\n" if ($debug);

    return $oc;
}

sub writeUrlCache {
    my $advanced = shift;
    my @urls = @_;

    if ( $advanced == 3 ) {
        # save to legacy integration urls cache
        open(CACHE, "> $urlCacheIntAdv") if ($has_integration);
    }
    elsif ( $advanced == 2 ) {
        # save to advanced integration urls cache
        open(CACHE, "> $urlCacheInt") if ($has_integration_legacy);
    }
    elsif ( $advanced == 1 ) {
        open(CACHE, "> $urlCacheAdv");
    }
    else {
        open(CACHE, "> $urlCache");
    }
    for my $url ( @urls ) {
        $url->saveToStream(*CACHE);
    }
    close(CACHE);

    return 1;
}


sub hasUrlCache {

    my $product = shift;
    my $advanced = shift || 0;

    my $cache_file = $urlCache;
    if ( $advanced == 3 ) {
        $cache_file = $urlCacheIntAdv if ($has_integration);
    }
    elsif ( $advanced == 2 ) {
        $cache_file = $urlCacheInt if ($has_integration_legacy);
    }

    elsif ( $advanced == 1 ) {
        $cache_file = $urlCacheAdv;
    }

    if (-s $cache_file) {
        # the file is not empty
        return 1;
    }
    return 0;
}

sub readUrlCacheCombined {

    my $product = shift;

    my @returnUrls = ();
    my $urls;

    # Add legacy urls
    if ( hasUrlCache($product, 0) ) {
        $urls = readUrlCache($product, 0);
        push(@returnUrls, $urls);
    }
    # Add advanced urls
    if ( hasUrlCache($product, 1) ) {
        $urls = readUrlCache($product, 1);
        push(@returnUrls, $urls);
    }

    # Add legacy integration urls
    if ( $has_integration_legacy && hasUrlCache($product, 2) ) {
        $urls = readUrlCache($product, 2);
        push(@returnUrls, $urls);
    }

    # Add advanced integration urls
    if ( $has_integration && hasUrlCache($product, 3) ) {
        $urls = readUrlCache($product, 3);
        push(@returnUrls, $urls);
    }

    # return legacy front door if neither returned
    unless (@returnUrls) {
        $urls = defaultFrontDoorForProduct($product, 0);
        push(@returnUrls, $urls);
    }

    return @returnUrls;
}



sub readUrlCache {

    my $product = shift;
    my $advanced = shift || 0;

    # since these get added to the Url class cache we don't
    # need to worry about returning the objects

    #
    # first sort the urls we have based on community
    #
    my $urlsForCommunity;
    if ( $advanced == 3) {
        open(CACHE, $urlCacheIntAdv) if ($has_integration);
    }
    elsif ( $advanced == 2) {
        open(CACHE, $urlCacheInt) if ($has_integration_legacy);
    }
    elsif ( $advanced == 1 ) {
        open(CACHE, $urlCacheAdv);
    }
    else {
        open(CACHE, $urlCache);
    }

    for my $url (ariba::monitor::Url->createObjectsFromStream(*CACHE)) {
        push(@{$urlsForCommunity->{$url->community()}}, $url);
    }
    close(CACHE);

    #
    # then randomly pick a url to monitor from each community
    #
    my @randomUrlPerCommunity;
    srand();

    for my $community (keys(%$urlsForCommunity)) {
        my @communityUrls = @{$urlsForCommunity->{$community}};
        my $count = scalar(@communityUrls);
        my $pick = int(rand($count));

        $communityUrls[$pick]->deleteAttribute('community');
        push(@randomUrlPerCommunity, $communityUrls[$pick]);
    }

    my @urls;

    # Pick 3 random urls from 3 different communities
    if (my $numUrls = scalar(@randomUrlPerCommunity)) {

        # If there are 3 or less communities, all of them are selected
        if ($numUrls < 4) {
            @urls = @randomUrlPerCommunity;
        } else {
            my @pickedUrlIndex;

            # Pick a different random community until we get 3 of them
            while (@pickedUrlIndex < 3) {

                my $pick = int(rand($numUrls));

                # Pick a url only if it hasn't picked yet
                push (@pickedUrlIndex, $pick) unless (grep {$_ == $pick} @pickedUrlIndex)
            }

            @urls = map {$randomUrlPerCommunity[$_]} @pickedUrlIndex;
        }
    }
    my $url = shift @urls;
    $url->setSecondaryURLs(@urls) if ($url);

    unless ($url) {
        $url = defaultFrontDoorForProduct($product, 0);
    }

    return $url;
}

sub shouldFetchFromDB {
    my $lastFetch = (stat($urlCache))[9] || 0;

    my $frequency = 60*15;

    if ( time() > ($lastFetch + $frequency) ){
        return 1;
    } else {
        return undef;
    }
}

# See ariba::HTTPWatcherPlugin::TomcatAppInstance
# returns monitoring url for the default front door for a product
sub defaultFrontDoorForProduct  {
    my $product = shift;
    my $advanced = shift;

    my $productName = $product->name();
    my $me = ariba::rc::InstalledProduct->new();

    my $url = $product->default('VendedUrls.FrontDoor');

    # make the front door advanced format
    my $advanced_str = '';
    my @hosts;
    if ( $advanced == 1 ) {
        $advanced_str = ' advanced';
        @hosts = $product->default('System.Security.MultiFrontDoorHostName');
        if ( @hosts ) {
            $url = $hosts[1];
        }
    }

    my $monUrl = ariba::monitor::Url->new($url);

    $monUrl->setWatchString("Ariba.*Inc.\\s+All Rights Reserved");
    $monUrl->setFollowRedirects(1);

    # front-door for s4/buyer/s4pm should never fail to load
    # increase the timeout to allow modjk time to failover
    my $timeout = 35; # time the url has to reply
    $monUrl->setTimeout($timeout);

    $monUrl->setNotify($me->default('notify.email'));
    $monUrl->setProductName($productName);
    $monUrl->setRecordStatus("yes");
    $monUrl->setHysteresis($hysteresis);
    $monUrl->setNotifyWhenSick(1);
    $monUrl->setDisplayName("$productName${advanced_str} front door");
    $monUrl->setSaveRequest(1);
    $monUrl->setSkipSSLCheck(1);

    return $monUrl;
}

# realmsDir(product,serviceName) - Get the 'realms' directory that contains the realm info for each
#     realm for a product.
sub realmsDir {
    my $product = shift;
    my $serviceName = shift;

    my $productName = $product->name();
    my $realms_dir;

    if ( $serviceName =~ /^prod/ ) {
        $realms_dir = "/fs/$productName$serviceName/realms";
    }
    else {
        $realms_dir = $product->configDir();
        $realms_dir =~ s|config|realms|g;
    }

    return $realms_dir;
}

# isAdvancedRealm(realms_dir, realm_id) - checks a realm to see if it is advanced or not.
sub isAdvancedRealm {
    my ($serviceName, $product, $realm_id) = @_;

    my $realms_dir = realmsDir($product, $serviceName);

    my $param_filename = "$realms_dir/realm_$realm_id/config/Parameters.table";
    # read in Parameters.table for realm id
    my $params;
    if ( -f $param_filename ) {
        $params = ariba::Ops::PropertyList->newFromFile($param_filename);
    }
    else {
        return 0;
    }

    my $security_path = "Partitions.prealm_$realm_id.Application.Security";
    #  FrontDoorId will be 'Legacy' or 'Advanced'. Legacy realms will generally not have a 'Security' section
    my $front_door_id = $params->valueForKeyPath("$security_path.FrontDoorId") || '';

    my $host_index = '';
    my @frontdoors;

    if ( $front_door_id ) {
        # These parameters found by searching for Application.Security in our code
        $host_index = $params->valueForKeyPath("$security_path.MultiFrontDoorHostIndex") || '';
    }

    my $advanced = 0;
    if ( $front_door_id eq 'Advanced' && $host_index eq '2' ) {
        $advanced = 1;
    }

    # return advanced
    return $advanced;
}

1;

