package ariba::Ops::CommonMachineMethods;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/CommonMachineMethods.pm#43 $

use strict;
use ariba::Ops::MachineFields;
use ariba::Ops::NetworkUtils;
use ariba::Ops::DatacenterController;

my $fields      = $ariba::Ops::MachineFields::fields;
my $valueValidationMap  = $ariba::Ops::MachineFields::valueValidationMap;

my @deviceTypes = qw(net host);

###############
# class methods

sub listFields {
    my $class = shift;

    # NOTE:  (added this note on 2016/12/01) 'networkTier' is added here for reasons unknown.  It should be in
    # MachineFields.pm, along with all the other fields.  grep'ing in the tools/monitor repository base does not
    # find anything where the string 'networkTier' is used, *other than* in this file and Machine.pm, and in that
    # file, the only reference to this method is in pod documentation.  In my opinion, this could/should be
    # removed, so if it's still here, say 6 months from the above date, remove it and see if anything breaks.

    #perl has a bug where sort() in a scalar context returns undef!
    my @sortedFields = sort (keys %{$fields}, 'networkTier');

    return @sortedFields;
}

# XXX
sub describeAllFields {
    my $class = shift;

    my %fieldDescriptions = map { $_, $fields->{$_}->{'desc'} } keys %{$fields};

    return \%fieldDescriptions;
}

sub describeField {
    my ($class, $field) = @_;

    return $fields->{$field}->{'desc'};
}

sub listValidValuesForField {
    my ($class, $field) = @_;

    return @{$fields->{$field}->{'values'}};
}

# Leverage the opsService field in machinedb (if it exists) to find hosts for
# a specific service.  Currently applicable to UAE/KSA in ksa2 and PROD/PROD2
# in snv and us1
sub machinesWithPropertiesForService {
    my ($class, $service, %fieldMatchMap) = @_;

    my @machines = ($class->_matchPropertiesInObjects(\%fieldMatchMap));
    
    @machines = grep { !($_->opsService() && ($_->opsService() ne $service)) } @machines;

    return @machines;
}

sub machinesWithProperties {
    my ($class, %fieldMatchMap) = @_;

    return ($class->_matchPropertiesInObjects(\%fieldMatchMap));
}

sub validateField {
    my ($class, $field, $value) = @_;

    return 0 unless defined $value and $value !~ /^\s*$/;

    my $fieldMatchValues = $fields->{$field}->{'values'};

    if (scalar @{$fieldMatchValues} > 1) {
        if ($value =~ /,/) {
            $value =~ s/\s//g; 
            my @values = split /,/, $value;
            foreach my $val (@values) {
                next if (grep { /^$val$/ } @{$fieldMatchValues});
                return 0;
            }
            return 1;
        } else {
            return 1 if grep { /^$value$/ } @{$fieldMatchValues};
        }
    } elsif ($value =~ /^$valueValidationMap->{$fieldMatchValues->[0]}$/) {

        return 1;
    }
    
    return 0;
}

sub isRequired {
    my ($class, $field) = @_;

    return $fields->{$field}->{'required'};
}

sub isSARequired {
    my ($class, $field) = @_;

    return $fields->{$field}->{'saRequired'};
}

sub allDeviceTypes {
    my $class = shift;

        return @deviceTypes;
}

##################
# instance methods

sub attributeAsString {
    my $self = shift;
    my $attribute = shift;

    return join(', ', $self->attribute($attribute));
}

sub deviceType {
    my $self = shift;

    my $hardwareVendor = lc( $self->hardwareVendor() );

    if ($hardwareVendor && (
        $hardwareVendor eq "f5" || 
        $hardwareVendor =~ /palo alto/ || 
        $hardwareVendor eq "cisco" || 
        $hardwareVendor eq "netscreen" || 
        $hardwareVendor eq "cyclades" || 
        $hardwareVendor eq "avocent" || 
        $hardwareVendor eq "netgear" ||
        $hardwareVendor eq "foundry" ||
        $hardwareVendor eq "arista")) {

        return "net";
    } elsif ($hardwareVendor) {
        return "host";
    } else {
        return "unknown";
    }
}

sub snmpCommunity {
    my $self = shift;

    my $deviceType = $self->deviceType();
    my $deviceOs = $self->os();
    my $snmpVersion = $self->snmpVersion() || 1;
    my $deviceDc = $self->datacenter();

    my $communityString = "public";
    my $module = "snmp-community.pl";

    eval "require \"$module\"";
    unless ($@) {
        $communityString = snmpCommunityForDevice($deviceType, $deviceOs, $snmpVersion, $deviceDc);
    } else {
        #warn "Warning: ariba::Ops::Machine::snmpCommunity unable to load $module\n";
        #warn "         returning default community\n";
    }

    return $communityString;
}

sub provides {
    my ($self,@services) = @_;

    return 0 unless scalar @services > 0;

    my @provides = $self->providesServices();

    # do we provide *any* of these services?
    for my $service (@services) {

        return 1 if grep( /^$service$/, @provides);
    }

    return 0;
}

sub hasProperties {
    my ($self, %fieldMatchMap) = @_;

    my @machines;
    push(@machines, $self);

    return(ref($self)->_matchPropertiesInObjects(\%fieldMatchMap, \@machines));
}

sub isValidHardwareType {
    my ($self, $runningType) = @_;

    my $hardwareType = $self->hardwareType();
    # if machinedb's value is not in MachineFields.pm, no need to check further
    return 0 if (!ariba::Ops::Machine->validateField('hardwareType', $hardwareType));

    # when hardwareType() returns "axi", machinedb must be either "axi_2u" or "axi_4u"
    if ($runningType eq 'axi') {
        return 1 if $hardwareType eq 'axi_2u';
        return 1 if $hardwareType eq 'axi_4u';
        return 0;
    }

    # when hardwareType() returns "ultra_10", machinedb value of "ultra_5" is okay
    if ($runningType eq 'ultra_10') {
        return 1 if $hardwareType eq 'ultra_5';
    }

    # when hardwareType() returns "ultra_60", machinedb value of "e220r" is okay
    if ($runningType eq 'ultra_60') {
        return 1 if $hardwareType eq 'e220r';
    }

    # any other values returned from hardwareType() must be exact match with machinedb
    return ($hardwareType eq $runningType);
}

# This is broken for dcs that serve multiple services (snv, us1, ksa2)
# The first DC to match will return the service. Eg any snv host used for prod2 will return prod.
sub service {
    my $self = shift;

    # MachineDB doesn't (and shouldn't!) include the concept of a Release
    # Control service. But we still want to combine some environments
    # under a standard heading.
    my $datacenter = $self->datacenter();

    if (ariba::Ops::DatacenterController::isProductionUSDatacenters($datacenter)) {
        return 'prod';
    } elsif (ariba::Ops::DatacenterController::isProductionEUDatacenters($datacenter)) {
        return 'prodeu';
    } elsif (ariba::Ops::DatacenterController::isProductionRUDatacenters($datacenter)) {
        return 'prodru';
    } elsif (ariba::Ops::DatacenterController::isProductionCNDatacenters($datacenter)) {
        return 'prodcn';
    } elsif (ariba::Ops::DatacenterController::isProductionUSMSDatacenters($datacenter)) {
        return 'prodms';
    } elsif (ariba::Ops::DatacenterController::isProductionEUMSDatacenters($datacenter)) {
        return 'prodeums';
    } elsif (ariba::Ops::DatacenterController::isProductionRUMSDatacenters($datacenter)) {
        return 'prodrums';
    } elsif (ariba::Ops::DatacenterController::isProductionCNMSDatacenters($datacenter)) {
        return 'prodcnms';
    } elsif (ariba::Ops::DatacenterController::isProductionKSADatacenters($datacenter)) {
        return 'prodksa';
    } elsif (ariba::Ops::DatacenterController::isProductionUAEDatacenters($datacenter)) {
        return 'produae';
    } elsif (ariba::Ops::DatacenterController::isProductionUAEMSDatacenters($datacenter)) {
        return 'produaems';
    } elsif (ariba::Ops::DatacenterController::isProductionKSAMSDatacenters($datacenter)) {
        return 'prodksams';
    } elsif (ariba::Ops::DatacenterController::isOpslabDatacenters($datacenter)) {
        return 'lab';
    } elsif (ariba::Ops::DatacenterController::isSalesDatacenters($datacenter)) {
        return 'sales';
    } elsif (ariba::Ops::DatacenterController::isSc1lab1Datacenters($datacenter)) {
        return 'sc1lab1';
    } elsif (ariba::Ops::DatacenterController::isDevlabDatacenters($datacenter)) {
        return 'dev';
    } elsif ($datacenter eq "atl") {
        return 'procuri';
    } else {
        warn "\"$datacenter\" is not a configured datacenter!\n";
        return 'unknown';
    }
}

sub networkTier {
    my $self = shift;
    my $ipAddr = $self->ipAddr();
    my $mask = $self->netmask();

    return('n' . ariba::Ops::NetworkUtils::hostnameToTier($ipAddr, $mask));
}

# Always normalize these out.
sub setMacAddress {
    my $self  = shift;
    my $value = shift;

    $self->SUPER::setMacAddress( ariba::Ops::NetworkUtils::formatMacAddress($value) );
}

sub setMacAddrSecondary {
    my $self  = shift;
    my $value = shift;

    $self->SUPER::setMacAddrSecondary( ariba::Ops::NetworkUtils::formatMacAddress($value) );
}

1;

__END__
