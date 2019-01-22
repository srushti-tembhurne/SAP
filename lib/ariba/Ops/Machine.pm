package ariba::Ops::Machine;

# $Id$

use strict;

use ariba::Ops::Constants;
use ariba::Ops::CommonMachineMethods;
use ariba::Ops::MachineFields;
use ariba::Ops::PersistantObject;
use ariba::Ops::NetworkUtils;

use base qw(ariba::Ops::CommonMachineMethods ariba::Ops::PersistantObject);

###############
# class methods

sub new {
    my $class = shift;
    my $hostname = shift || ariba::Ops::NetworkUtils::hostname();

    my $self = $class->SUPER::new($hostname);

    $self->setHostname($hostname) unless $self->hostname();
    return $self;
}

sub attribute {
    my $self = shift;
    my $key = shift;

    return($self->networkTier()) if($key eq 'networkTier');
    return($self->SUPER::attribute($key));
}

sub objectLoadMap {
    my $class = shift;

    my $map = $class->SUPER::objectLoadMap();

    $map->{'providesServices'} = '@SCALAR';
    $map->{'wwns'} = '@SCALAR';

    return $map;
}

sub listObjects {
    my $class = shift;
    my @list  = ();

    my @dirs = glob($class->dir() . "/*");
    for my $dir (@dirs) {
        next unless -d $dir;

        opendir(DIR, $dir) or die "Can't open $dir: $!\n";
        my @files = grep($_ !~ /^\./o, readdir(DIR));
        closedir(DIR);

        foreach my $file (sort @files) {
            push(@list, $class->new($file)) or warn "Can't create new $class: $!";
        }   
    }
    
    return @list;
}

sub dir {
    my $class = shift;
    return ariba::Ops::Constants->machinedir();
}

sub _computeBackingStoreForInstanceName {
    my $class = shift;
    my $instanceName = shift;

    # this takes the instance name as an arg
    # so that the class method objectExists() can call it

    # parse out the domain part
    my $domain = (split /\./, $instanceName, 2)[1] || '';

    my $file = join '/', ($class->dir(), $domain, $instanceName) ;

    map { $file =~ s/$_//go } qw(`"'>|;);

    $file =~ s/\.\.//o;
    $file =~ s|//|/|go;

    return $file;
}

sub databaseName {
        my $class = shift;

        return "AN Operations";
}

# Attempting to overload the validateField method in CommonMachineMethods.pm, to use the "multiple" key for fields, as currently
# found for the field providesServices.  This is needed because the parent method does not split a value with multiple parts, to
# check each, it rather is taking the value whole, which often will fail.
sub validateField
{
    my $class = shift;
    my $field = shift;
    my $value = shift;

    return 0 unless defined $value and $value !~ /^\s*$/;

    # If the field in question has the multiple field, process here, else process in the parent module.
    if (exists $ariba::Ops::MachineFields::fields->{$field}->{multiple} && $ariba::Ops::MachineFields::fields->{$field}->{multiple})
    {
        # Split the value into pieces and check each for validity.  Return a list of Booleans, in the same
        # order as the pieces passed in, so the caller can process as needed.
        my @results;
        for my $subValue (split /[,\s]+/, $value)
        {
            push @results, $class->SUPER::validateField ($field, $subValue);
        }
        return (@results);
    }
    else
    {
        # Call the parent method:
        return $class->SUPER::validateField ($field, $value);
    }
}

##################
# instance methods

sub save {
    my $self = shift;
    $self->setLastUpdated(time);
    $self->SUPER::save();
}

sub recursiveSave {
    my $self = shift;
    $self->setLastUpdated(time);
    $self->SUPER::recursiveSave();
}

1;

__END__

=head1 NAME

ariba::Ops::Machine - manage the machine database

=head1 SYNOPSIS

   use ariba::Ops::Machine;

   my @fields = ariba::Ops::Machine->listFields();

   my @machines = ariba::Ops::Machine->listObjects();

   my $machine = ariba::Ops::Machine->new($ARGV[0]) || die "Usage: $0 <machine>";

   my $datacenter = $machine->datacenter();

   print $machine->osVersion();

=head1 DESCRIPTION

Provides methods to manipulate the machine database

=head1 CLASS METHODS

   new( $hostname ) - 
    returns a new ariba::Ops::Machine object.  Defaults to the current machine.

   listFields() - list available machine fields
    returns an array

   describeAllFields() - describe all available fields
    returns a hash reference

   describeField( $fieldName ) - describe a specific field
    returns a scalar string
    
   listValidValuesForField( $fieldName ) - list the valid enumerations for a field
    returns an array

   machinesWithProperties( %hash ) - Find the list of machines matching the input values

    The hash should look like:

    my %hash = (
        'os'            => 'sunos',
        'datacenter'    => 'snv',
        'providesServices' => 'web, app',
    );

    returns an array of ariba::Ops::Machine objects

   validateField( $fieldName, $value )
    returns true or false

   isRequired( $fieldName ) - check to see if the field is a required attribute
    returns true or false

=head1 INSTANCE METHODS

   allDeviceTypes()         list of all device types in the db
   assetTag()               Ariba Asset Tag
   cageNumber()                         Cage Number
   comment()                Additional Comments
   consoleServer()          Serial Console Server
   consoleServerPort()          Serial Console Server Port
   cpuCount()               Number of CPUs
   cpuSpeed()               Speed of CPUs (Mhz/Ghz)
   datacenter()             Datacenter Location
   defaultRoute()           Default Route
   deviceType()             Type of device "net" or "host"
   dnsDomain()              DNS Domain
   hardwareType()           Hardware Model
   hardwareVendor()         Hardware Vendor
   hasProperties(%hash)         Similar to machinesWithProperties
   hostname()               Hostname
   ipAddr()             IP Address
   ipAddrSecondary()            Secondary IP Address
   lastUpdated()            Last Updated Time
   macAddr()                MAC Address
   macAddrSecondary()           Secondary MAC Address
   memorySize()             Memory Size (Megabytes)
   netmask()                Netmask
   networkSwitch()          Network Switch the machine is plugged into
   networkSwitchPort()          Switch Port the machine is plugged into
   networkSwitchPortSecondary()     Secondary Switch Port the machine is plugged into
   networkSwitchSecondary()     Secondary Network Switch the machine is plugged into
   os()                 Operating System
   osVersion()              Operating System Version
   owner()              Owning Group
   rackNumber()             Rack Number
   rackPorts()              Rack Network Port
   rackPosition()           Rack Position
   etherChannel1Ports()         Interfaces that are a member of etherChannel1
   etherChannel2Ports()         Interfaces that are a member of etherChannel2
   etherChannel3Ports()         Interfaces that are a member of etherChannel3
   providesServices()           Array of Services
   serialNumber()           Serial Number of Device
   service()                Service Type
   snmpCommunity()          SNMP Community String
   status()             Status

   All instance methods may have 'set' appended to them to set the value. IE:

   $machine->setSerialNumber( 123456 );
   
=head1 AUTHOR

Daniel Sully <dsully@ariba.com>

=head1 SEE ALSO

ariba::Ops::SearchablePersistantObject, ariba::Ops::PersistantObject

=cut
 
