package ariba::Ops::Startup::Buyer;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/Buyer.pm#10 $

use strict;

use File::Path;
use File::Basename;
use ariba::Ops::Url;
use ariba::Ops::Startup::Common;
use ariba::Ops::Startup::Tomcat;
use ariba::rc::Utils;
use XML::Simple;

sub printError {
    my $errorCode = shift;
    my $name = shift;
    my $errorString = shift;
    my $refreshBundleDA = shift;

    print "failed\n";
    print "WARN: could not notify $name about the new publish bundle.  This is non-blocking.\n";
    print "You need to manually tell $name to load the bundle.  See https://wiki.ariba.com:8443/pages/viewpage.action?pageId=20480175\n";
    print "$errorCode,  String: $errorString\n";
}

sub refreshBundle {
    #
    # Call Direct action via arches front door
    # Print message if refreshBundle was successful or not
    #
    my $service = shift;
    return unless (ariba::rc::InstalledProduct->isInstalled('arches', $service));
    my $arches = ariba::rc::InstalledProduct->new('arches', $service);
    my $url = $arches->default('VendedUrls.FrontDoorTopLevel');
    my $refreshBundleDA = $url . "/Arches/api/refreshBundle/ariba.catalog";

    my $refreshBundleUrl = ariba::Ops::Url->new($refreshBundleDA);
    $refreshBundleUrl->setTimeout(60);
    $refreshBundleUrl->setUseOutOfBandErrors(1);
    my $xml = $refreshBundleUrl->request();

    print "\n";
    print "Informing " . $arches->name() . " about the publish bundle refresh: ";

    my $errorString = $refreshBundleUrl->error();
    printError( "Direct Action Error", $arches->name(), $errorString, $refreshBundleDA ) if $errorString;
    
    unless ( $errorString ) {
        my $resultRef;
        eval { $resultRef = XMLin( $xml ); };
        if ( $@ ) {
            printError( "Parse error in xml: $@", $arches->name(), $xml, $refreshBundleDA );
        } elsif ( $resultRef->{ response } eq 'OK' ) {
            print "success\n";
        } else {
            printError( "Success string 'OK' not found in xml", $arches->name(), $xml, $refreshBundleDA );
        }
    }

    print "\n";
    return 1;
}

#
# refreshBundle() example of output of DA to refresh bundle
# ie. DEV8 service: http://svcdev8ows.ariba.com/Arches/api/refreshBundle/ariba.catalog
#<requestResponse>
#  <jobId>ariba.catalog</jobId>
#  <response>OK</response>
#</requestResponse>
#

1;

__END__
