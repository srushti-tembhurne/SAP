#!/usr/local/bin/perl

package ariba::Ops::MCL::Helpers::MonX;

use LWP::UserAgent;
use JSON;

use ariba::rc::Globals;
use ariba::Ops::MCL;
use ariba::Ops::Logger;
my $logger = ariba::Ops::Logger->logger();

sub checkDiskQuota {
    my $product = shift;
    my $service = shift;

    my $username = ariba::rc::Globals::deploymentUser($product, $service);
    my $url = "http://monx.lab1.ariba.com/api/v1/datatable/Alerts-Services-$service-Products-$product-general";
    my $ua = LWP::UserAgent->new();
    my $ret;

    my $response = $ua->get($url);
    if($response->is_success) {
        my $json = decode_json($response->decoded_content);
        my $alerts = $json->{'results'}->{'rows'};
        foreach my $alert (@$alerts) {
            if($alert->{'status'} eq 'crit' and $alert->{'collection_source'} eq 'netapp_collector' and $alert->{'object'} =~ m/$username/) {
                $ret .= 'Error: Quota for ' . $alert->{'object'} . " in critical state\n"
            }
        }
        $ret = "OK" unless $ret;
    } else {
        $ret = "Error: Failed to get quota information from MonX";
    }

    return $ret;
}

1;
