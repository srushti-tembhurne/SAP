package ariba::Ops::NetworkDevice::pix;

use strict;
use base qw(ariba::Ops::NetworkDevice::BaseDevice);


sub commandPrompt { 
    #This method will allow logging on to the -2 firewalls
    my $self = shift;

    my $str = substr($self->shortName(), 0, 10);

    return $str . '[\w\-]*> ';
}

sub enablePrompt { 
    #This method will allow logging on to the -2 firewalls
    my $self = shift;

    my $str = substr($self->shortName(), 0, 10);

    return $str . '[\w\-]*# ';
}

sub getConfig {
    my $self = shift;

    if ( $self->machine->osVersion() eq '7.0') {
        $self->sendCommand('term pager 0');
    } else {
        $self->sendCommand('no pager');
    }

    return $self->SUPER::getConfig();
}

sub getSystemStatus {
    my $self = shift;

    my $primaryStatus = 0;
    my $secondaryStatus = 0;

    my $snmp  = $self->snmp();
    $snmp->setTimeout(30);
    $snmp->setRetries(5);
    $snmp->setEnums(1);
    $snmp->setSprintValue(1);

    # perl SNMP doesn't work with .primaryUnit, we need to pass it the interger value.
    # from CISCO-FIREWALL-MIB:
    # primaryUnit(6),
    # secondaryUnit(7),

    # SNMP get status for Primary and Secondary:
    # CISCO-FIREWALL-MIB::cfwHardwareStatusDetail.primaryUnit = STRING: Standby unit
    # CISCO-FIREWALL-MIB::cfwHardwareStatusDetail.secondaryUnit = STRING: Active unit

    $primaryStatus = $snmp->valueForOidExpr("cfwHardwareStatusDetail.6");
    $secondaryStatus = $snmp->valueForOidExpr("cfwHardwareStatusDetail.7");

    return $primaryStatus, $secondaryStatus;
}

sub loginName {
    my $self = shift;
    my $osVersion = $self->machine->osVersion();

    # All firewall devices are going to login as root.
    if ( defined ($self->machine->useSsh())) {
        return 'root';
    }

    return '';

}


sub changePassword {
    my $self           = shift;
    my $accessPassword = shift;
    my $enablePassword = shift;

        $self->enable();

    # Expect needs ()'s either escaped, or using .'s
    my $configPrompt = sprintf('%s.config(-line)?.#', $self->shortName());

    $self->sendCommand('conf t', $self->enablePrompt(), $configPrompt);

    $self->sendCommand("enable password $enablePassword", $configPrompt);

    # We've turned on login prompts to access the serial console 
    $self->sendCommand("no aaa authentication serial console LOCAL", $configPrompt);
    $self->sendCommand("no aaa authentication ssh console LOCAL", $configPrompt);
    $self->sendCommand("no username cisco", $configPrompt);
    $self->sendCommand("username root password $accessPassword", $configPrompt);
    $self->sendCommand("aaa authentication serial console LOCAL", $configPrompt);
    $self->sendCommand("aaa authentication ssh console LOCAL", $configPrompt);

    $self->sendCommand('exit', $configPrompt, $self->enablePrompt());
    $self->sendCommand('write mem', $self->enablePrompt());

    if ($self->handle()->exp_before() =~ /\[OK\]/) {
        return 1;
    }

    return 0;
}

sub getDuplexState {
    #This method gets the duplex status of firewall interfaces that are up
    my $self   = shift;

    my @errors = ();

    $self->enable();
    my $output = $self->sendCommand('show interface', $self->enablePrompt());

    for my $interface (split /^Interface /m, $output) {
        my @lines = split (/\n/, $interface);

        # Only check interfaces that are up
        if ($lines[0] =~ /up.*up/i){

            # Ignore virtual interfaces
            next if ($lines[0] =~ /Virtual/i);

            my @int = split (/\s+/, $lines[0]);
            my $name = $int[0];
            my $desc = $int[1];
            my $duplex = (split(/\s+/,$lines[2]))[1];
            # for TenGig firewall interfaces duplex state is on the fourth line 
            # the Cisco bug id for this is CSCtn15254
            $duplex = (split(/\s+/,$lines[3]))[1] if ($name =~ /TenGigabitEthernet/i);
            ($duplex) = $duplex =~ /\((.*?)\)/;
        
            # If duplex state is not full, add it to the errors array
            push (@errors, "port $name $desc set to $duplex\n") if ($duplex !~ /full/i);
        }
    }

    return join('', @errors);

}

sub portSpeedTable {
    my $self = shift;

    if($self->psTable()) {
        return($self->psTable());
    }

    my $table = {};
    my $snmp  = $self->snmp();

    $snmp->setTimeout(30);
    $snmp->setRetries(5);
    $snmp->setEnums(1);
    $snmp->setSprintValue(1);

    my $oid = ariba::SNMP::ConfigManager::_cleanupOidExpr( "ifNumber.0", $self->machine() );
    my $numberOf = $snmp->valueForOidExpr($oid);

    for(my $i = 1; $i <= $numberOf; $i++) {
        my $oid = ariba::SNMP::ConfigManager::_cleanupOidExpr( "ifDescr.$i", $self->machine() );
        my $desc = $snmp->valueForOidExpr($oid);
        last unless($desc);

        $oid = ariba::SNMP::ConfigManager::_cleanupOidExpr( "ifSpeed.$i", $self->machine() );
        my $speed = $snmp->valueForOidExpr($oid);
        $speed /= 1000000;

        $table->{$desc} = $speed;
    }

    $self->setPsTable($table);

    return($table);
}

1;

__END__
