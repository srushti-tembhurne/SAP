package ariba::monitor::StatusPage;

# $Id: //ariba/services/monitor/lib/ariba/monitor/StatusPage.pm#96 $

use File::Path;
use ariba::monitor::QueryManager;
use ariba::rc::Product;
use ariba::Ops::NetworkUtils;
use ariba::Ops::DatacenterController;
use ariba::Ops::ServiceController;
use strict;

my %productNames;

# static init code
for my $prod ( ariba::rc::Product->allProductNames() ){
    $productNames{lc($prod)} = "";
}

my $domain = ariba::Ops::NetworkUtils::domainForHost(ariba::Ops::NetworkUtils::hostname());

sub productNamesRef {
    return \%productNames;
}

#XXX see also vm

my %_statusToValue = (
    "unknown",  0,
    "default",  0,
    "crit",     0,
    "warn",     0.5,
    "info",     1,

    # don't use
    "crit-forced", 0,
    "warn-forced", 0.5,
    "info-forced", 1,
);

sub statusToValue {
    return $_statusToValue{$_[0]};
}


my %_statusValueToRGB = (
    1.0, '#00FF00',
    0.9, '#77FF00',
    0.8, '#99FF00',
    0.7, '#BBFF00',
    0.6, '#EEFF00',
    0.5, '#FFFF00',
    0.4, '#FFEE00',
    0.3, '#FFBB00',
    0.2, '#FF7700',
    0.1, '#FF4400',
    0.0, '#FF0000',
);

sub statusValueToRGB {
    my $statusValue = shift;

    if ( $statusValue > 1 || $statusValue < 0 ) {
        return undef;
    }

    my $roundedValue = _roundToTenths($statusValue);

    return $_statusValueToRGB{$roundedValue};
}

my %_statusToColor = (
    "unknown",      "default",
    "default",      "green",
    "crit",         "red",
    "warn",         "yellow",
    "info",         "green",

    # private, don't use
    "crit-forced",  "red-dark",
    "warn-forced",  "yellow-dark",
    "info-forced",  "green-dark",

);

sub statusToColor {
    return $_statusToColor{$_[0]} || $_statusToColor{'unknown'};
}

my %_colorsToRGB = (
        "default",      "#EEEEEE",
        "default-dim",  "#BBBBBB",

        "red",          "#FF6666",
        "red-dim",      "#FF3333",
        "red-dark",     "#B96666",
        "red-dark-dim", "#B02020",

        "yellow",       "#FFFF66",
        "yellow-dim",   "#FFFF33",
        "yellow-dark",  "#BFBF00",
        "yellow-dark-dim", "#B0B000",

        "green",        "#90EE90",
        "green-dim",    "#00CC00",
        "green-dark",   "#50BF50",
        "green-dark-dim", "#50B050",

        "black",        "#000000",
        "white",        "#FFFFFF",
        "grey",         "#CCCCCC",
        "grey-dim",     "#999999",
        "grey-dark",   "#555555",

        "baby-blue",    "#aaddff",
        "steel-blue",   "#bbccdd",
        "orange",       "#ff8844",
        "tan",          "#D2B48C",
        "purple",       "#cc99ff",
);

sub colorToRGB {
    return $_colorsToRGB{$_[0]} || $_colorsToRGB{'default'};
}

sub _roundToTenths {
    my $number = shift;

    $number *= 10;

    my $rn = int($number + .5);

    return $rn / 10;
}

#
# these 4 subs are wacky.  
# our status page deals with tabs of results for products
# We have some fake products that are other concepts:
# outstanding pages and datacenters.
#

sub commonProduct {
    my $datacenter = shift;

    my ($domainPrefix) = $domain =~ /(^.+?)\./;

    if ( $datacenter && (ariba::Ops::DatacenterController::isProductionRUMSDatacenters($datacenter) ) ||
            ariba::Ops::DatacenterController::isProductionRUMSDatacenters( $domainPrefix ) ) {
        return "ru1-ms";
    } elsif ( $datacenter && (ariba::Ops::DatacenterController::isProductionKSAMSDatacenters($datacenter) ) ||
            ariba::Ops::DatacenterController::isProductionKSAMSDatacenters( $domainPrefix ) ) {
        return "ksa1-ms";
    } elsif ( $datacenter && (ariba::Ops::DatacenterController::isProductionKSADatacenters($datacenter) ) ||
            ariba::Ops::DatacenterController::isProductionKSADatacenters( $domainPrefix ) ) {
        return "ksa1";
    } elsif ( $datacenter && (ariba::Ops::DatacenterController::isProductionUAEMSDatacenters($datacenter) ) ||
            ariba::Ops::DatacenterController::isProductionUAEMSDatacenters( $domainPrefix ) ) {
        return "uae1-ms";
    } elsif ( $datacenter && (ariba::Ops::DatacenterController::isProductionUAEDatacenters($datacenter) ) ||
            ariba::Ops::DatacenterController::isProductionUAEDatacenters( $domainPrefix ) ) {
        return "uae1";
    } elsif ( $datacenter && (ariba::Ops::DatacenterController::isProductionEUMSDatacenters($datacenter) ) ||
            ariba::Ops::DatacenterController::isProductionEUMSDatacenters( $domainPrefix ) ) {
        return "eu1-ms";
    } elsif ( $datacenter && (ariba::Ops::DatacenterController::isProductionEUDatacenters($datacenter) ) ||
            ariba::Ops::DatacenterController::isProductionEUDatacenters( $domainPrefix ) ) {
        return "eu1";
    } elsif ( $datacenter && (ariba::Ops::DatacenterController::isProductionRUDatacenters($datacenter) ) ||
            ariba::Ops::DatacenterController::isProductionRUDatacenters( $domainPrefix ) ) {
        return "ru1";
    } elsif ( $datacenter && (ariba::Ops::DatacenterController::isProductionCNMSDatacenters($datacenter) ) ||
            ariba::Ops::DatacenterController::isProductionCNMSDatacenters( $domainPrefix ) ) {
        return "cn1-ms";
    } elsif ( $datacenter && (ariba::Ops::DatacenterController::isProductionCNDatacenters($datacenter) ) ||
            ariba::Ops::DatacenterController::isProductionCNDatacenters( $domainPrefix ) ) {
        return "cn1";
    } elsif ( $datacenter && (ariba::Ops::DatacenterController::isProductionUSMSDatacenters($datacenter) ) ||
            ariba::Ops::DatacenterController::isProductionUSMSDatacenters( $domainPrefix ) ) {
        return "sc1";
    } elsif ( ( $datacenter && (ariba::Ops::DatacenterController::isProductionUSDatacenters($datacenter)) ) ||
         ariba::Ops::DatacenterController::isProductionUSDatacenters( $domainPrefix ) ) {
        return "snv";
    } else {
        return "pridc";
    }
}

sub replicationDatacenters {
    my $datacenter = shift;

    my ($domainPrefix) = $domain =~ /(^.+?)\./;

    if ( ( $datacenter && (ariba::Ops::DatacenterController::isProductionUSDatacenters($datacenter)) ) ||
         ariba::Ops::DatacenterController::isProductionUSDatacenters( $domainPrefix ) ) {
         return "bou";
    } elsif ( $datacenter && (ariba::Ops::DatacenterController::isProductionEUDatacenters($datacenter) ) || 
         ariba::Ops::DatacenterController::isProductionEUDatacenters( $domainPrefix ) ) {
         ## Just adding eu3 & ru3 as replication datacenter for EU & RU incase we add in future & it may have different name too        
         return "eu3";
    } elsif ( $datacenter && (ariba::Ops::DatacenterController::isProductionRUDatacenters($datacenter) ) || 
         ariba::Ops::DatacenterController::isProductionRUDatacenters( $domainPrefix ) ) {
         ## Just adding eu3 & ru3 as replication datacenter for EU & RU incase we add in future & it may have different name too
         return "ru3";
    } else {
         return "bckdc";
    }
}

sub disasterRecoveryProduct {
    my $datacenter = shift;

    my ($domainPrefix) = $domain =~ /(^.+?)\./;

    if ( $datacenter && (ariba::Ops::DatacenterController::isProductionRUMSDatacenters($datacenter) ) ||
        ariba::Ops::DatacenterController::isProductionRUMSDatacenters( $domainPrefix ) ) {
        return "ru2-ms";
    } elsif ( $datacenter && (ariba::Ops::DatacenterController::isProductionKSAMSDatacenters($datacenter) ) ||
        ariba::Ops::DatacenterController::isProductionKSAMSDatacenters( $domainPrefix ) ) {
        return "ksa2-ms";
    } elsif ( $datacenter && (ariba::Ops::DatacenterController::isProductionKSADatacenters($datacenter) ) || 
         ariba::Ops::DatacenterController::isProductionKSADatacenters( $domainPrefix ) ) {
        return "ksa2";
    } elsif ( $datacenter && (ariba::Ops::DatacenterController::isProductionUAEMSDatacenters($datacenter) ) ||
        ariba::Ops::DatacenterController::isProductionUAEMSDatacenters( $domainPrefix ) ) {
        return "uae2-ms";
    } elsif ( $datacenter && (ariba::Ops::DatacenterController::isProductionUAEDatacenters($datacenter) ) || 
         ariba::Ops::DatacenterController::isProductionUAEDatacenters( $domainPrefix ) ) {
        return "ksa2";
    } elsif ( $datacenter && (ariba::Ops::DatacenterController::isProductionEUMSDatacenters($datacenter) ) ||
        ariba::Ops::DatacenterController::isProductionEUMSDatacenters( $domainPrefix ) ) {
        return "eu2-ms";
    } elsif ( $datacenter && (ariba::Ops::DatacenterController::isProductionEUDatacenters($datacenter) ) || 
         ariba::Ops::DatacenterController::isProductionEUDatacenters( $domainPrefix ) ) {
        return "eu2";
    } elsif ( $datacenter && (ariba::Ops::DatacenterController::isProductionCNMSDatacenters($datacenter) ) ||
         ariba::Ops::DatacenterController::isProductionCNMSDatacenters( $domainPrefix ) ) {
        return "cn2-ms";
    } elsif ( $datacenter && (ariba::Ops::DatacenterController::isProductionCNDatacenters($datacenter) ) ||
         ariba::Ops::DatacenterController::isProductionCNDatacenters( $domainPrefix ) ) {
        return "cn2";
    } elsif ( $datacenter && (ariba::Ops::DatacenterController::isProductionRUDatacenters($datacenter) ) || 
        ariba::Ops::DatacenterController::isProductionRUDatacenters( $domainPrefix ) ) {
        return "ru2";
    # US Micro Services
    } elsif ( $datacenter && (ariba::Ops::DatacenterController::isProductionUSMSDatacenters($datacenter) ) ||
        ariba::Ops::DatacenterController::isProductionUSMSDatacenters( $domainPrefix ) ) {
        return "us1-ms";
    } elsif ( ( $datacenter && (ariba::Ops::DatacenterController::isProductionUSDatacenters($datacenter)) ) ||
         ariba::Ops::DatacenterController::isProductionUSDatacenters( $domainPrefix ) ) {
        return "us1";
    } else {
        return "bckdc";
    }
}

sub ackedPageSystemProduct {
    return "pages"; 
}

sub businessProcessProduct {
    return 'bpm';
}

sub businessObjectsProduct
{
    return 'boe';
}

sub rcProductName {
    return 'rc';
}

sub hanaMsProduct {
    return 'hana-ms';
}

sub fakeProductNameForDatacenter {
    my $datacenter = shift;
    # this is glue for our not well though out
    # secondary datacenter work
    # this should use ariba::Ops::MachineFields.pm
    # to compute this list

    my $tab;

    if ( defined $datacenter && ( ariba::Ops::DatacenterController::isProdDatacentersDR($datacenter) ||
            ariba::Ops::DatacenterController::isOpslabDatacenterDR($datacenter)) ) {
        $tab = disasterRecoveryProduct($datacenter);
    } elsif ( defined $datacenter && $datacenter eq "sjc2" ) {
        $tab = altDataCenterProduct();
    } elsif ( defined $datacenter && ariba::Ops::DatacenterController::isReplicationDatacenters($datacenter) ) {
        $tab = replicationDatacenters($datacenter);
    } else {
        $tab = commonProduct($datacenter);
    }
    
    return $tab;        
}

sub fakeProductNameForDnsDomain {
    my $domain = shift;

    my $tab;
    ($domain) = $domain =~ /(^.+?)\./;

    if ( ariba::Ops::DatacenterController::prodDatacentersDR( $domain ) ||
         ariba::Ops::DatacenterController::opslabDatacentersDR( $domain )) {
        $tab = disasterRecoveryProduct();
    } elsif ( $domain eq "sjc2" ) {
        $tab = altDataCenterProduct();
    } else {
        $tab = commonProduct();
    }
    
    return $tab;        
}

sub monitoredProductNames {

    my $service = shift();

    my @products = ariba::rc::InstalledProduct->installedProductsList($service);
    my @productNames = ();

    my %seen;
    my $serviceUsesMoreThanOneDatacenter = 0;

    # keep doc and pe from showing up on mon page
    $seen{doc} = 1;
    $seen{pe} = 1;
    $seen{opstools} = 1;

    for my $p ( @products ){
        # an, cat, aes/ops, aes/sony, unique on product name
        push(@productNames, $p->name()) unless $seen{$p->name()}++;

        # This is a bit of a hack to avoid faulting in all product objects.
        # This is predicated on the assumption that unless AN has a backup
        # datacenter, no other product will and thus there is no need to check
        # the others.
        if ($p->name() eq "an") {

            my @clusters = $p->allClusters();

            if ( scalar(@clusters) > 1 ) {
                $serviceUsesMoreThanOneDatacenter = 1;
            }
        }
    }

    @productNames = sort(@productNames);

    # This section is for "special products", which is defined as not a standard Ariba product (examples are BPM and Business Objects).
    # These products can not found with methods installedProductList and must be "manually" added to the list here.  There is some
    # degree of interdependency here, as the test depends on a query manager directory subdirectory, which won't exist until the
    # monitoring script is run, which depends on installing something with that script included.
    my $qmDir = ariba::monitor::QueryManager::dir();
    my $bpm = businessProcessProduct();
    if(-d "$qmDir/$bpm") {
        unshift(@productNames, $bpm);
    }

    my $boe = businessObjectsProduct();
    if(-d "$qmDir/$boe")
    {
        unshift(@productNames, $boe);
    }

    my $rc = rcProductName();
    if(-d "$qmDir/$rc") {
        unshift(@productNames, $rc);
    }


    my $bouDatacenter = 'bou';
    if(-d "/var/mon/query-storage/bou/") {
        unshift(@productNames, 'bou');
    }

    if (ariba::Ops::ServiceController::isProductionMsServicesOnly($service)){
        my $hanaMs = hanaMsProduct();
        if(-d "$qmDir/$hanaMs") {
            unshift(@productNames, $hanaMs);
        }
    }

    my $bckdc = disasterRecoveryProduct();

    #
    # bckdc case in the conditional below, is needed for devlab
    # where we send some results to backup datacenter (like shareplex
    # monitoring for dr) even when the product is deployed in a single
    # datacenter
    #
    if ( $serviceUsesMoreThanOneDatacenter || -d "$qmDir/$bckdc" ) {
        unshift(@productNames,
            ariba::monitor::StatusPage::disasterRecoveryProduct()
        );
    }

    unshift(@productNames, 
        ariba::monitor::StatusPage::ackedPageSystemProduct(),
        ariba::monitor::StatusPage::commonProduct(), 
    );

    return @productNames; 

}

sub opsDocURL {
    return "http://ops.ariba.com/documentation/prodops/";
}

sub opsProductDocURL {
    my $productName = lc(shift);

    my $docURL = opsDocURL();

    if ( $productName eq commonProduct() ) {
        $docURL .= "common/troubleshooting.shtml";
    } elsif ( $productName eq disasterRecoveryProduct() ) {
        $docURL .= "common/troubleshooting.shtml";
    } elsif ( $productName eq ackedPageSystemProduct() ) {
        $docURL .= "common/ackedpages.shtml";
    } elsif ( $productName eq businessProcessProduct() ) {
        $docURL .= "common/troubleshooting.shtml";
    } else {
        $docURL .= "product/$productName";
    }

    return $docURL;
}

sub caps {
    my $words = join("", @_);

    my @words = split(/\b/, $words); 
    my $camelWords = '';
    my $skipWordsRegex = 'has|for|to|from|in|over|not|by';

    foreach my $word (@words) { 
        if ($word =~ /^[a-z]/ && $word !~ /^($skipWordsRegex)$/) {
            $word = ucfirst($word);
        }
        $camelWords .= $word;
    }

    return $camelWords;
}

sub capsProductName {
    my $productName = lc(shift);

    if ( defined($productNames{$productName}) || 
         $productName eq businessProcessProduct() ||
         $productName eq rcProductName()){
        return uc($productName);
    } elsif ( $productName eq disasterRecoveryProduct() ) {
        return ucfirst(disasterRecoveryProduct());
    } else {
        return ucfirst($productName);
    }
}

sub parseQueryManagerFileForStatus {
    my $dir = shift;
    my $file = shift;

    my $queries = ariba::monitor::QueryManager->new("$dir/$file");
    $queries->readFromBackingStore(); #force a re-read

    return $queries->status();  
}

sub computeStatus {
    my $statusRef = shift;
    my $status = "unknown";

    $status = "info" if( $statusRef->{info} );
    $status = "info-forced" if( $statusRef->{'info-forced'} );
    $status = "warn-forced" if( $statusRef->{'warn-forced'} );
    $status = "warn" if( $statusRef->{warn} );
    $status = "crit-forced" if( $statusRef->{'crit-forced'} );
    $status = "crit" if( $statusRef->{crit} );

    return $status;
}

sub monitoringCSS {

    my $css =<<CSS;
body {
  margin-top: 0;
  background-color: white;
}

body, td, th {
  font-family: arial, helvetica, geneva, sans-serif;
  font-size: 13px;
}

a {
  text-decoration: none;
}

.small {
  font-size: 11px;
}

.tiny {
  font-size: 9px;
}

.tooltip {
    padding: 0.5em;
    max-width: 600px;
    height: auto;
    border: 1px solid black;
    background-color: white;
    overflow: hidden;
}

.indentSecondLine {
    margin: 0px;
    padding-left: 2em; 
    text-indent: -2em;
}

CSS

    # Have logical names for class colors
    for my $status (sort keys %_statusToColor) {

        my $rgb = colorToRGB(statusToColor($status));

        $css .= ".$status { background-color: $rgb; }\n";
    }

    return $css;
}

sub addAdminAppLinksToQueueResults {
    my $adminAppURL = shift;

    my $query     = $ariba::monitor::Query::_ourGlobalQuerySelf;
    my @results   = ();

    my $community = $query->communityId();
    my $product   = $query->productName();
    my $format    = $query->format();

    chomp($format);

    for my $result ($query->results()) {

        $result = sprintf("<html>$format</html>", split(/\t/, $result));

        if ($product eq 'an') {
            $result =~ s|([\w_]+?_queue\.item)\s+(\d+)|$1 <a target=admin href=$adminAppURL/doc?id=$2&community=$community>$2</a>|o;
        }

        push(@results, $result);
    }

    $query->setNoFormat(1);
    $query->setFormat('');

    if (scalar @results == 0) {
        return ();
    } else {
        return join("\n", @results);
    }
}

1;
