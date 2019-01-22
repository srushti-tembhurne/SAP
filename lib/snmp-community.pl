#
# This routine is here to get a snmp community for devices.
# It's checked in here so that cfengine pushes do not send this to
# all the hosts out there. It's a security hole.
#

use ariba::Ops::DatacenterController;

sub snmpCommunityForDevice {
    my $deviceType  = shift;
    my $deviceOs    = shift;
    my $snmpVersion = shift || 1;
    my $deviceDc    = shift;

    my $return = '';

    if (($deviceOs eq "servertech") or ($deviceType eq "net" and $deviceOs ne "ldir") or ($deviceOs eq "ldir" and $snmpVersion > 1) or ($deviceOs eq 'css') ) {
        $return = "hk550vxi";
    } else {
        $return = "public";

        if ((ariba::Ops::DatacenterController::isOpslabDatacenters($deviceDc) ) or 
            (ariba::Ops::DatacenterController::isDevlabDatacenters($deviceDc) )) {
            $return = "SvmARBus";
        }
    }

    return $return;
}

1;
