package ariba::Ops::NetworkDevice::nxos;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/NetworkDevice/nxos.pm#3 $
# network device driver for cisco nexus switch

use strict;
use base qw(ariba::Ops::NetworkDevice::BaseDevice);
use ariba::Ops::NetworkUtils;
use ariba::Ops::Machine;

my $hostname = ariba::Ops::NetworkUtils::hostname();

sub invalidVLAN {
        my $self = shift;
        my $vlan = shift;

        # not implemented
        return 0;
}

sub broadcastPing {
	my $self = shift;

    # not implemented
	return 0;
}

sub arpTable {
	my $self  = shift;

	my $table = ();
	my $snmp  = $self->snmp();

    # not functional yet
	return $table;
}

sub camTable {
	my $self  = shift;

	my $table = ();

    # not functional yet
	return $table;
}

sub portsSpeedTable {
	my $self  = shift;

	my $table = ();
	my $snmp  = $self->snmp();

	$snmp->setTimeout(30);
	$snmp->setRetries(5);
	$snmp->setEnums(1);
	$snmp->setSprintValue(1);

	my @oids   = qw(ifDescr ifHighSpeed);
	my $walked = $snmp->bulkWalkOids(@oids);

	while (my ($iid, $vars) = each %$walked) {
		my $ifName = $vars->{'ifDescr'} || next;
		my $ifHighSpeed = $vars->{'ifHighSpeed'} || next;

		# Do we need anything more complex than this?
		$table->{$ifName} = {
			'ifHighSpeed' => $ifHighSpeed,
			};
	}

	return $table;
}


sub setPortName {
	my $self = shift;
	my $port = shift;
	my $name = shift;

    # not implemented
    return;
}

sub getConfig {
	my $self = shift;

	$self->sendCommand('term length 0');

	return $self->SUPER::getConfig();
}

sub getSDMStatus {
	my $self = shift;

    # not implemented
    return; 
}
	
sub getObjectStatus {
	my $self = shift;

	my %table = ();

    # not functional yet
	return %table;
}

sub loginName {
	my $self = shift;

	# Most devices running ios should login as root ???

	my $routeServerWithLogin = $self->routeServerWithLogin();

	if (defined $routeServerWithLogin) {
		if ($routeServerWithLogin == 1) {
			return 'rviews';
		} else {
			return '';
		}
	}
        
        if ($hostname =~ m/\.ru(?:1|2)\./igs) {
             return 'RULogin77#4';
        } else {
	    return 'root';
        }
}

sub powerSupplyStatus {
	my $self   = shift;

	my %status = ();

    # not functional yet
    return %status;
}

sub combinedDuplexStatus {
	my $self   = shift;

	my @errors = ();
	my $snmp   = $self->snmp();

	# Gathering all these details as they are avaliable via catos.pm
	my @oids   = qw(dot3StatsDuplexStatus ifIndex ifAlias ifDescr ifOperStatus);

	my $walked = $snmp->bulkWalkOids(@oids);

	while (my ($iid, $vars) = each %$walked) {

		# We don't care about VLANs just physical ports

		my $ifIndex = $vars->{'ifIndex'} || next;
		my $duplex = $vars->{'dot3StatsDuplexStatus'} || next;

		for my $oid (qw(ifAlias ifDescr ifOperStatus ifSpeed)) {
			$vars->{$oid} = $walked->{$ifIndex}->{$oid};
		}

		my $ifStatus = $vars->{'ifOperStatus'};

		#We only care about interfaces that are up

		next unless ($ifStatus =~ /^up$/m);

		my $port   = $vars->{'ifDescr'};
		my $name   = $vars->{'ifAlias'};

		if ($duplex !~ /full/i) {
			push @errors, "port $port ($name) set to $duplex\n";
		}

	}
	
	return join('', @errors);
}

sub getPortsWithNoDesc {
	# This method takes a switch network device as input
	# and returns a reference to an array of its non VLAN 
	# interfaces that are up and have no description

	my $self   = shift;

	my @errors = ();
	my $snmp   = $self->snmp();

	# Gathering all these details as they are avaliable via catos.pm
	my @oids   = qw(portIfIndex portType ifAlias ifDescr ifOperStatus);

	my $walked = $snmp->bulkWalkOids(@oids);

	while (my ($iid, $vars) = each %$walked) {

		# We don't care about VLANs just physical ports

		my $ifIndex = $vars->{'portIfIndex'} || next;
		my $portType = $vars->{'portType'} || next;

		for my $oid (qw(ifAlias ifDescr ifOperStatus)) {
			$vars->{$oid} = $walked->{$ifIndex}->{$oid};
		}

		my $ifStatus = $vars->{'ifOperStatus'};

		#We only care about interfaces that are up

		next unless ($ifStatus =~ /^up$/m);

		my $port   = $vars->{'ifDescr'};
		my $name   = $vars->{'ifAlias'};

		if ($name =~ /^\s*$/) {
			push @errors, "port $port in use but missing a description\n";
		}
                
	}
        
	return \@errors;
}

sub getEtherChannelPorts {
	my $self = shift;

	my $results = ();

    # not functional yet
	return $results;
}

# this queries a device and retrieves data on channel status
# both port channel and vpc
#
sub channelStatus {
    my $self = shift;
    my $pcstatus = {};  # store the port channel data
    my $vpcstatus = {}; # store the vpc data
    
	my $snmp   = $self->snmp();

	# Gathering the statuses
	my @ifoids = qw(ifIndex ifName ifAlias ifOperStatus);
    my @pcoids = qw(clagAggPortListPorts clagAggPortListInterfaceIndexList);
    my @vpcoids = qw(ciscoVpcMIB);

    my $ifwalk = $snmp->bulkWalkOids(@ifoids);
    my $pcwalk = $snmp->bulkWalkOids(@pcoids);
    my $vpcwalk = $snmp->bulkWalkOids(@vpcoids);

    # loop through all the port channels
    while ( my ($pcidx, $vars) = each %$pcwalk ) {
        my $ifdata = $ifwalk->{$pcidx};
        $pcstatus->{$pcidx}->{name} = $ifdata->{ifName};
        $pcstatus->{$pcidx}->{alias} = $ifdata->{ifAlias} if $vars->{ifAlias};
        $pcstatus->{$pcidx}->{status} = $ifdata->{ifOperStatus};
        # get all the members and their status
        my $packedindexstr =  $vars->{clagAggPortListInterfaceIndexList};
        my @ifidxs = ariba::Ops::NetworkUtils::snmpOctetstrToNumbers($packedindexstr);
        foreach my $idx (@ifidxs) {
            $ifdata = $ifwalk->{$idx};
            $pcstatus->{$pcidx}->{members}->{$idx}->{name} = $ifdata->{ifName};
            $pcstatus->{$pcidx}->{members}->{$idx}->{status} = $ifdata->{ifOperStatus};
            $pcstatus->{$pcidx}->{members}->{$idx}->{alias} = $ifdata->{ifAlias} if $ifdata->{ifAlias};
        } 
    }
    
    # loop through all vpc query data with keys like 10 10.2 10.3 etc
    while ( my ($key, $vars) = each %$vpcwalk ) {
        next if $key == 0; # no vpc configured

        # $key is in the form of d or d.d 
        # for example 10, 10.2 where 10 is the vpc number (domain id)
        $key =~ /^(\d+)/;
        my $vpcnum = $1;
        # present for any underline interface information
        # cVpcStatusHostLinkIfIndex.10.24 = INTEGER: 369098775
        my $ifidx = $vars->{cVpcStatusHostLinkIfIndex}; 

        if ( !$ifidx ) {
            # vpc level data
            #
            # cVpcRoleStatus.10 = INTEGER: primary(2)
            # cVpcDualActiveDetectionStatus.10 = INTEGER: false(2)
            $vpcstatus->{$vpcnum}->{role} = $vars->{cVpcRoleStatus};
            $vpcstatus->{$vpcnum}->{dualactivedetectionstatus} = $vars->{cVpcDualActiveDetectionStatus};

            # --- peer keep alive
            # cVpcPeerKeepAliveUdpPort.10 = Gauge32: 3200
            # cVpcPeerKeepAliveStatus.10 = INTEGER: alive(2)
            my $peerkeepalivedata = {};
            $peerkeepalivedata->{udpport} = $vars->{cVpcPeerKeepAliveUdpPort};
            $peerkeepalivedata->{status} = $vars->{cVpcPeerKeepAliveStatus};
            $peerkeepalivedata->{vrfname} = $vars->{cVpcPeerKeepAliveVrfName};
            
            $vpcstatus->{$vpcnum}->{peerkeepalive} = $peerkeepalivedata;

            # --- peerlink data (a port channel)
            my $peerlinkifindex = $vars->{cVpcStatusPeerLinkIfIndex};
            my $ifdata = $ifwalk->{$peerlinkifindex};
            if ( $ifdata ) {
                my $peerlinkdata = {};
                $peerlinkdata->{name} = $ifdata->{ifName};
                $peerlinkdata->{status} =  $ifdata->{ifOperStatus};
                $peerlinkdata->{alias} = $ifdata->{ifAlias} if $ifdata->{ifAlias};

                $vpcstatus->{$vpcnum}->{peerlink} = $peerlinkdata;
            }
        } else {
            # host link member data
            #
            # cVpcStatusHostLinkIfIndex.10.24 = INTEGER: 369098775
            # cVpcStatusHostLinkStatus.10.24 = INTEGER: downStar(2)
            # cVpcStatusHostLinkConsistencyStatus.10.24 = INTEGER: notApplicable(3)
            # cVpcStatusHostLinkConsistencyDetail.10.24 = STRING: Consistency Check Not Performed
            # 

            # data for this one channel with interface index $ifidx retrieve above
            my $ifdata = $ifwalk->{$ifidx} if $ifidx;
            my $linkdata = {};
            $linkdata->{hostlinkstatus} = $vars->{cVpcStatusHostLinkStatus};
            $linkdata->{name} = $ifdata->{ifName};
            $linkdata->{status} = $ifdata->{ifOperStatus};
            $linkdata->{alias} = $ifdata->{ifAlias};

            $vpcstatus->{$vpcnum}->{hostlinks}->{$ifidx} = $linkdata;
        }
    }

    my $status = {pcstatus => $pcstatus, vpcstatus => $vpcstatus};
    return $status;
}

sub changePassword {
	my $self           = shift;
	my $accessPassword = shift;
	my $enablePassword = shift;

    # not implemented
	return 0;
}

sub runTrace {
	my $self = shift;
	my $peer = shift;
	my $timeout = shift;
 
	my $results = $self->sendCommand("trace $peer",undef,undef,$timeout);

	return $results;
}

sub getActiveSupervisorModule {
	my $self = shift;

    # not implemented
	return (undef, undef);     

}

#
# MCL tool calls this -- since inserv.pm implements this instead of overloading
# sendCommand()... that said, we need to pass a config prompt here anyway in
# order for the expect parsing to work the ios magick changing prompt of
# annoyance. ????
# leave it for nxos unless verify false
sub _sendCommandLocal {
	my $self = shift;
	my $cmd = shift;
	my $configPrompt = '.*config[^#]*#';

	return($self->SUPER::_sendCommandLocal($cmd, undef, $configPrompt));
}

1;

__END__
