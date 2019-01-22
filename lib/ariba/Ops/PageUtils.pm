package ariba::Ops::PageUtils;
#
# put page server items that depend on product api here
#
# See also CFEngineMonitoringGlueUtils.pm for similar functions that should be called
# from cfengine instead of this
#
# $Id: //ariba/services/tools/lib/perl/ariba/Ops/PageUtils.pm#11 $

use strict;

use ariba::Ops::Constants;
use ariba::rc::InstalledProduct;
use ariba::rc::Globals;

sub pageServer {
    return monitorServer($_[0]);
}

#
# Only in rare cases does this need to be called with an argument
#

sub monitorServer {
    my $optionalProductObject = shift;

    my $me = $optionalProductObject || ariba::rc::InstalledProduct->new();
    my $cluster = $me->currentCluster();

    my $monserver = ($me->hostsForRoleInCluster('monitor', $cluster))[0] ||
        ($me->hostsForRoleInCluster('monserver', $cluster))[0];

    unless ($monserver || $me->name() eq 'mon') {
        my $mon = ariba::rc::InstalledProduct->new('mon', $me->service());
        $monserver = ($mon->hostsForRoleInCluster('monserver', $cluster))[0]
    }

    if ( $monserver ) {
        return $monserver;
    } else {
        return undef;
    }
}

=head1

monitorServerForDatacenterByProduct()

    FUNCTION: Get the mon server based on InstalledProduct

   ARGUMENTS: an InstalledProduct object

     RETURNS: the correct mon server as a scalar hostname

=cut

sub monitorServerForDatacenterByProduct {
    my $me = shift;

    my @all_clusters = $me->allClusters();

    if ( scalar @all_clusters < 2 ){
        ## If there's less than 2 clusters, use ariba::Ops::PageUtils::monitorServer()
        return monitorServer( $me );
    }
    my $machineDatacenter = ariba::Ops::Machine->new()->datacenter();
    my $mainDatacenter = $me->mainDatacenterForCluster($me->currentCluster());

    my $monRole;
    my $monServer;

    if ($mainDatacenter eq $machineDatacenter) {
        $monRole = 'monserver',
    } else {
        $monRole = 'backup-monserver',
    }

    ($monServer) = $me->hostsForRoleInCluster($monRole, $me->currentCluster());

    return $monServer;
}

sub usePagedForService {
    my $service = shift;

    # the existance of a failsafePagerAddress for a service means
    # that service wants to use paged

    return defined(ariba::Ops::Constants::failsafePagerAddressForService($service));
}

# Normalize the subject line for all callers.
sub emailSubjectForSubject {
    my $subject  = shift;
    my $product  = shift;
    my $service  = shift;
    my $customer = shift;
    my $cluster = shift;

    undef($cluster) unless ( ariba::rc::Globals::isActiveActiveProduct($product) );

    my @prepend  = ();

    for my $item (($customer, $product, $service, $cluster)) {

        push(@prepend, $item) if defined $item;
    }

    return join(' ', @prepend, $subject);
}

1;
