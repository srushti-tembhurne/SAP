# $Id: //ariba/services/tools/lib/perl/ariba/Ops/NetworkDevice/ios.pm#8 $
package ariba::Ops::NetworkDevice::ios;

use strict;
use base qw(ariba::Ops::NetworkDevice::BaseDevice);
use ariba::Ops::NetworkUtils;
use ariba::Ops::Machine;

my $hostname = ariba::Ops::NetworkUtils::hostname();

sub invalidVLAN {
        my $self = shift;
        my $vlan = shift;

        return 1 if !$vlan || $vlan > 1000 || $vlan == 1;
        return 0;
}

sub broadcastPing {
	my $self = shift;

	my $machine = $self->machine();

	my $tier    = ariba::Ops::NetworkUtils::hostnameToTier($machine->hostname());
	my $domain  = $machine->dnsDomain();
	my $bcast   = ariba::Ops::NetworkUtils::hostToAddr("broadcast.n$tier.$domain");

	if ($self->connect()) {
		return $self->sendCommand("ping ip $bcast size 1024 repeat 2");
	}

	return 0;
}

sub arpTable {
	my $self  = shift;

	my $table = ();
	my $snmp  = $self->snmp();

	$snmp->setTimeout(30);
	$snmp->setRetries(5);
	$snmp->setEnums(1);
	$snmp->setSprintValue(1);

	unless ($self->broadcastPing()) {
	print "Couldn't do a broadcast ping!\n";
	}

	my $walked = $snmp->bulkWalkOids('ipNetToMediaPhysAddress');

	while (my ($iid, $vars) = each %$walked) {

		my $mac = ariba::Ops::NetworkUtils::formatMacAddress($vars->{'ipNetToMediaPhysAddress'}) || next;

		# Normalize these.
		$iid =~ s/^1\.//;

		$table->{$mac} = $iid;
	}

	return $table;
}

sub camTable {
	my $self  = shift;

	my $table = ();
	my $snmp  = $self->snmp();

	$snmp->setTimeout(30);
	$snmp->setRetries(5);
	$snmp->setEnums(1);
	$snmp->setSprintValue(1);

	my %vlans  = ();
	my @oids   = qw(dot1dTpFdbPort dot1dTpFdbAddress dot1dBasePortIfIndex ifDescr ifAlias);

	my $hardwareType = $self->machine->hardwareType();
	my $vlanIndexOID = 'vlanIndex';

	if ($hardwareType =~ /^2960$/) {
		$vlanIndexOID = 'entLogicalDescr';
	}

	my $walked = $snmp->bulkWalkOids($vlanIndexOID);

	# Find each vlan first
	while (my ($iid, $vars) = each %$walked) {

		# Argh - this comes back as a string - make it numeric.
		my $vlan = $vars->{$vlanIndexOID};
		$vlan =~ s/\D+//g;

		# skip invalid vlans. i.e we only care about vlans from 2 - 1000
		next if $self->invalidVLAN($vlan);

		$vlans{$vlan} = 1;
	}

	# Walk each VLAN, and reconnect as $community@vlan - required by Cisco
	for my $vlan (sort keys %vlans) {

		print "camTable(): Working on VLAN $vlan\n" if $self->debug();;

		$snmp->setVlan($vlan);

		my $walked = $snmp->bulkWalkOids(@oids);

		while (my ($iid, $vars) = each %$walked) {

			# if we don't have a dot1dTpFdbPort, then this key is
			# really from an interface - so merge it into the vars hash
			my $portNum = $vars->{'dot1dTpFdbPort'} || next;

			for my $oid (qw(dot1dBasePortIfIndex)) {

				#Adding new key value pair for dot1dBasePortIfIndex to this hash.
				$vars->{$oid} = $walked->{$portNum}->{$oid};
			}



			# walk the tree to get at the other indicies
			my $ifIndex = $vars->{'dot1dBasePortIfIndex'} || next;

			# We don't want to find macs on Etherhannel ports
			next if ($walked->{$ifIndex}->{'ifDescr'} =~ m/^Port-channel/ );
				$vars->{'ifDescr'} = $walked->{$ifIndex}->{'ifDescr'};

			# We've found what we're looking for a MAC <-> Name mapping
			my $ifName = $vars->{'ifDescr'} || next;

			# Get the currecnt Alias for the Interface
			$vars->{'ifAlias'} = $walked->{$ifIndex}->{'ifAlias'};
			my $ifAlias = $vars->{'ifAlias'};

			# Cleanup the mac to be something usable.
			my $mac = lc($vars->{'dot1dTpFdbAddress'});

			# Crap from the SNMP query
			# "00 D0 58 F6 6A 40 "
			$mac =~ s/"//g;
			$mac =~ s/\s*$//g;
			$mac =~ s/\s+/:/g;
			$mac = ariba::Ops::NetworkUtils::formatMacAddress($mac);

			print "\tFound port $ifName with name [$ifAlias] and MAC Address: $mac\n" if $self->debug();

			# Do we need anything more complex than this?
			$table->{$ifName} = {
				'macAddr'  => $mac,
				'portName' => $ifAlias,
			};
		}
	}

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

	# catop.pm uses snmp V3 for this.
	# As we have the mechanism for setting enable I prefer to use the cipherStore for holding passwords.	

	if ($self->inEnableMode() || $self->enable()) {
		my $configPrompt = sprintf('%s.config.#', $self->shortName());
		my $configInterfacePrompt = sprintf('%s.config-if.#', $self->shortName());
		$self->sendCommand("configure terminal", $self->enablePrompt(), $configPrompt);
		$self->sendCommand("interface $port", $configPrompt, $configInterfacePrompt); 
		$self->sendCommand("description $name", $configInterfacePrompt);
		$self->sendCommand("end", $configInterfacePrompt, $self->enablePrompt());
		$self->sendCommand("running-config startup-config\r", $self->enablePrompt());
	}
}

sub getConfig {
	my $self = shift;

	$self->sendCommand('term length 0');

	return $self->SUPER::getConfig();
}

sub getSDMStatus {

	my $self = shift;

	my $timeout =10;
	$self->enable();
	# Get SDM details	
	my $lines = $self->sendCommand('show sdm prefer', $self->enablePrompt(), undef, $timeout);
	my $output = (split(/\n/, $lines))[1];

	return $output;
}
	
sub getObjectStatus {

	my $self = shift;

	my $timeout =10;

	# Get all Tracking Object details	
	my $output = $self->sendCommand('show track brief', $self->commandPrompt(), undef, $timeout);
	my %table = ();
	my ($id, $state);

	for my $line (split /\n/, $output) {


		next unless $line =~ /^\d/;
	
		# columns are separated by 2 or more whitespaces.
		my @values = split (/\s{2,}/, $line);

		$id = $values[0];
		if ($values[4] =~ /Up/) {
			$state = 1;
		} elsif ($values[4] =~ /Down/) {
			$state = 0;
		} else {
			$state = undef;
		}

		$table { $id } = $state;
	}
	return %table;
}

sub loginName {
	my $self = shift;

	# Most devices running ios should login as root

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
	my $snmp   = $self->snmp();
	my $hardwareType = $self->machine->hardwareType();

	for my $ps (1..3) {

		my $value = undef;

		### Different versions of IOS have different MIBs and OIDs
		$value = $snmp->valueForOidExpr("chassisPs${ps}Status.0");
		if ($value eq "NOSUCHOBJECT") {
			$value = $snmp->valueForOidExpr("ciscoEnvMonSupplyState.$ps");
		}

		# "NULL" is ok - just means that it doesn't have that power supply.
		# We only use one ps in 3750 the second ps would be external. We don't want to monitor second.
		# We only use one ps in the 2960 console switches. We don't want to monitor second.
		next if !$value || $value =~ /NULL/ || $value eq "NOSUCHOBJECT" || ($hardwareType =~ /^3750|^2960/ && $ps == 2);

		$status{$ps} = $value;
	}

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

	my $snmp = $self->snmp();

	# we want to find the name and status of ports that are members of etherchannels
	# we also want to find the group the port belongs to (pagpAdminGroupCapability).

	my @oids = qw( pagpEthcOperationMode ifName ifOperStatus pagpAdminGroupCapability );
	my $walked = $snmp->bulkWalkOids(@oids);
	my $results = ();

	while (my ($iid, $vars) = each %$walked) {
		my $ifName = $vars->{'ifName'};
		my $pagpEthcOperationMode = $vars->{'pagpEthcOperationMode'};
		my $ifOperStatus = $vars->{'ifOperStatus'};
		my $pagpAdminGroupCapability = $vars->{'pagpAdminGroupCapability'};

		if ($pagpEthcOperationMode  && $pagpEthcOperationMode ne 'off') {

			# populate results hash
			$results->{$pagpAdminGroupCapability}->{$ifName} = {
				'pagpEthcOperationMode' => $pagpEthcOperationMode,
				'ifOperStatus' => $ifOperStatus,
			};
		}
	}

	return $results;
}

sub changePassword {
	my $self           = shift;
	my $accessPassword = shift;
	my $enablePassword = shift;

        $self->enable();

	# Expect needs ()'s either escaped, or using .'s
	my $configPrompt = sprintf('%s.config(-line)?.#', $self->shortName());
                
	$self->sendCommand('conf t', $self->enablePrompt(), $configPrompt);

	if ($enablePassword) {

		$self->sendCommand("enable secret $enablePassword", $configPrompt);
	}

	if ($accessPassword) {

		# We no longer set a password for each connection. We use the user database
		
		# change the current password in the database
		# 3640 do not have username secret option
		if ( $self->machine->hardwareType() eq '3640' || $self->machine->hardwareType() eq '2912') {
			$self->sendCommand("username root password $accessPassword", $configPrompt);
		} else {
			$self->sendCommand("username root secret $accessPassword", $configPrompt);
		}

		$self->sendCommand("username root secret $accessPassword", $configPrompt);

		# make sure the lines are configured correctly.
		$self->sendCommand('line con 0', $configPrompt);
		$self->sendCommand('no password', $configPrompt);
		$self->sendCommand('login local', $configPrompt);
		$self->sendCommand('exit', $configPrompt);

		$self->sendCommand('line vty 0 4', $configPrompt);
		$self->sendCommand('no password', $configPrompt);
		$self->sendCommand('login local', $configPrompt);
		$self->sendCommand('exit', $configPrompt);
	}

	$self->sendCommand('exit', $configPrompt, $self->enablePrompt());
	$self->sendCommand('write mem', $self->enablePrompt());

	if ($self->handle()->exp_before() =~ /\[OK\]/) {
		return 1;
	}

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

	my $snmp  = $self->snmp();
	$snmp->setTimeout(30);
	$snmp->setRetries(5);
	$snmp->setEnums(1);
	$snmp->setSprintValue(1);

	my $activeUnitModule = $snmp->valueForOidExpr("cRFStatusUnitId.0");
	my $peerUnitState = $snmp->valueForOidExpr("cRFStatusPeerUnitState.0");

	return ($activeUnitModule, $peerUnitState);     

}

#
# MCL tool calls this -- since inserv.pm implements this instead of overloading
# sendCommand()... that said, we need to pass a config prompt here anyway in
# order for the expect parsing to work the ios magick changing prompt of
# annoyance.
#
sub _sendCommandLocal {
	my $self = shift;
	my $cmd = shift;
	my $configPrompt = '.*config[^#]*#';

	return($self->SUPER::_sendCommandLocal($cmd, undef, $configPrompt));
}

1;

__END__
