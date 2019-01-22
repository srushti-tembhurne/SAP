# $Id: //ariba/services/tools/lib/perl/ariba/Ops/NetworkDevice/catos.pm#2 $
package ariba::Ops::NetworkDevice::catos;

# a collection of subroutines doing stuff with catos.

use strict;
use base qw(ariba::Ops::NetworkDevice::BaseDevice);

# These are well-known, set by the network team.
my $PORT_AUTH_PASSWORD = '402932210E64252';
my $PORT_PRIV_PASSWORD = 'IC8dE1PutW';

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

		return $self->sendCommand("ping -s $bcast 1024 2");
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
	my @oids   = qw(dot1dBasePortIfIndex dot1dTpFdbAddress dot1dTpFdbPort ifName portIfIndex portName);

	my $walked = $snmp->bulkWalkOids('vlanIndex');

	# Find each vlan first
	while (my ($iid, $vars) = each %$walked) {

		# Argh - this comes back as a string - make it numeric.
		my $vlan = $vars->{'vlanIndex'} + 0;

		# skip invalid vlans
		next if $self->invalidVLAN($vlan);

		# 
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

			for my $oid (qw(dot1dBasePortIfIndex portName portIfIndex)) {

				$vars->{$oid} = $walked->{$portNum}->{$oid};
			}

			# walk the tree to get at the other indicies
			my $ifIndex = $vars->{'dot1dBasePortIfIndex'} || next;

			$vars->{'ifName'} = $walked->{$ifIndex}->{'ifName'};

			# We've found what we're looking for a MAC <-> Name mapping
			my $ifPort = $vars->{'ifName'} || next;

			# Cisco to SNMP port renaming
			my $oidPort = $ifPort;
			$oidPort =~ s|/|\.|;

			# Sometimes the walk doesn't get the portname - so
			# refetch it explictly.
			my $portName = $walked->{$oidPort}->{'portName'} || 
				$snmp->valueForOidExpr("CISCO-STACK-MIB::portName.$oidPort") || '';

			# Cleanup the mac to be something usable.
			my $mac = lc($vars->{'dot1dTpFdbAddress'});

			# Crap from the SNMP query
			# "00 D0 58 F6 6A 40 "
			$mac =~ s/"//g;
			$mac =~ s/\s*$//g;
			$mac =~ s/\s+/:/g;
			$mac = ariba::Ops::NetworkUtils::formatMacAddress($mac);

			print "\tFound port $ifPort with name [$portName] and MAC Address: $mac\n" if $self->debug();

			# Do we need anything more complex than this?
			$table->{$ifPort} = {
				'macAddr'  => $mac,
				'portName' => $portName,
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

	my @oids   = qw(ifName ifHighSpeed);
	my $walked = $snmp->bulkWalkOids(@oids);

	while (my ($iid, $vars) = each %$walked) {
		my $ifName = $vars->{'ifName'} || next;
		my $ifHighSpeed = $vars->{'ifHighSpeed'} || next;

		# Do we need anything more complex than this?
		$table->{$ifName} = {
			'ifHighSpeed' => $ifHighSpeed,
			};
	}

	return $table;
}





sub enablePrompt {
	my $self = shift;

	return sprintf('%s> .enable. ', $self->shortName());
}

sub getConfig {
	my $self = shift;

	$self->sendCommand('set length 0');

	# switches can take a while to return running config.
	my $timeout = 60;
	return $self->SUPER::getConfig($timeout);
}

sub powerSupplyStatus {
	my $self   = shift;

	my %status = ();
	my $snmp   = $self->snmp();

	for my $ps (1..3) {

		my $value = $snmp->valueForOidExpr("chassisPs${ps}Status.0");

		# "NULL" is ok - just means that it doesn't have that power supply.
		next if !$value || $value =~ /NULL/;

		$status{$ps} = $value;
	}

	return %status;
}

sub combinedDuplexStatus {
	my $self   = shift;

	my @errors = ();
	my $snmp   = $self->snmp();

	my @oids   = qw(vlanPortVlan portIfIndex portName portDuplex portType portAdditionalOperStatus ifName ifSpeed);

	my $walked = $snmp->bulkWalkOids(@oids);

	while (my ($iid, $vars) = each %$walked) {

		# skip invalid vlans
		next if $self->invalidVLAN($vars->{'vlanPortVlan'});

		# if we don't have a portIfIndex, then this key is really from
		# an interface - so merge it in.
		my $ifIndex = $vars->{'portIfIndex'} || next;

		if ($walked->{$ifIndex}) {

			for my $oid (qw(ifName ifSpeed)) {

				$vars->{$oid} = $walked->{$ifIndex}->{$oid};
			}
		}

		my $status = $vars->{'portAdditionalOperStatus'} || 0;

		# BITS doesn't enum itself properly - even Bill Fenner didn't
		# have any ideas. Will pose to the net-snmp list.
		#
		# 00 80 disabled(8)
		# 08 00 notConnected(4)
		# 40 00 connected(1)

		if ($status =~ /40\s*00/) {

			$status = 'connected';

		} elsif ($status =~ /08\s*00/) {

			$status = 'notConnected';

		} elsif ($status =~ /00\s*80/) {

			$status = 'disabled';

		} else {
			$status = 'unknown';
		}

		next unless $status eq 'connected';

		my $vlan   = $vars->{'vlanPortVlan'};
		my $name   = $vars->{'portName'}   || '';
		my $duplex = $vars->{'portDuplex'} || 'unknown';
		my $type   = $vars->{'portType'}   || 'unknown';
		my $port   = $vars->{'ifName'}     || 'unknown';
		my $speed  = $vars->{'ifSpeed'}    || 1 / 10000000;

		if ($self->debug()) {
			print "vlan      : $vlan\n";
			print "portName  : $name\n";
			print "portDuplex: $duplex\n";
			print "portType  : $type\n";
			print "ifIndex   : $ifIndex\n";
			print "ifName    : $port\n";
			print "ifSpeed   : $speed Mb\n\n";
		}

		if ($duplex ne 'full') {

			# TMID: 11623 - ignore the port that hosts the SpectraLogic
			# AIT tape library. It only works at 10/half (broken!)
			next if $name =~ /spectra/i;

			push @errors, "port $port type $type ($name) set to $duplex $speed\n";
		}

		if ($name =~ /^\s*$/) {
			push @errors, "port $port type $type in use but missing a description\n";
		}
	}

	return join('', @errors);
}

sub setPortName {
	my $self = shift;
	my $port = shift;
	my $name = shift;

	$self->enable();

	$self->sendCommand("set port name $port $name", $self->enablePrompt());
}

sub changePassword {
	my $self           = shift;
	my $accessPassword = shift;
	my $enablePassword = shift;

        $self->enable();
	$self->setSendCR(0);

	my $successful     = 0;

	# The spaces are important - they are after the :
	if ($enablePassword) {

		$self->sendCommand('set enablepass', $self->enablePrompt(), 'Enter old password:');

		# This is the old password.
		$self->sendCommand($self->enablePassword(), ' ', 'Enter new password:');

		$self->sendCommand($enablePassword, ' ', 'Retype new password:');
		$self->sendCommand($enablePassword, ' ', 'Password changed');

		if ($self->handle()->match() =~ /Password changed/) {
			$successful++;
		}
	}

	if ($accessPassword) {

		$self->sendCommand('set password', $self->enablePrompt(), 'Enter old password:');

		# This is the old password.
		$self->sendCommand($self->accessPassword(), ' ', 'Enter new password:');

		$self->sendCommand($accessPassword, ' ', 'Retype new password:');
		$self->sendCommand($accessPassword, ' ', 'Password changed');

		if ($self->handle()->match() =~ /Password changed/) {
			$successful++;
		}
	}

	# reset this
	$self->setSendCR(1);

	# Check to see if one or both changes were ok.
	if ($accessPassword && $enablePassword && $successful == 2) {

		return 1;

	} elsif (($accessPassword || $enablePassword) && $successful == 1) {

		return 1;
	}

	return 0;
}

sub loginName {
        my $self = shift;

        if (defined ($self->machine->useSsh())) {
                return 'root';
        } 
        return '';
}

1;

__END__
