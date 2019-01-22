package ariba::Ops::CFEngine::MonitoringGlueUtils;
#
# $Id: //ariba/services/tools/lib/perl/ariba/Ops/CFEngine/MonitoringGlueUtils.pm#7 $
#
# See also ariba::Ops::PageUtils.pm for when you are allowed to use the Product API
# for similar functionality
#

use strict;

use ariba::Ops::Machine;
use ariba::Ops::NetworkUtils;

# These globals are used to store results and speed up subsequent calls.
my @monServerList;
my @monMarkedServerList;
my $currentDc;
my $checkedForMarkedServers;

sub pageServer {
	return monitorServer();
}

# Input: a hosts's name
# Output: array of all service names that run in the same datacenter for the host
sub allMonitoringServers {
    my $host = shift || ariba::Ops::NetworkUtils::hostname();

    my $machine = ariba::Ops::Machine->new($host);
    my $datacenter = $machine->monitoringDatacenter() || $machine->datacenter();
    if ( !@monServerList || ( $currentDc ne $datacenter )) {
        $currentDc = $datacenter;
        my %match = (
                datacenter  => $datacenter,
                providesServices => 'mon',
                status => 'inservice',
        );
        @monServerList = ariba::Ops::Machine->machinesWithProperties(%match);
    }

    return @monServerList;
}

sub monitorServer {
	my $host = shift || ariba::Ops::NetworkUtils::hostname();

	#
	#XXX Do a very bogus algorithm to 
	#XXX find a monitoring server when we don't have the product API to help.
	#XXX This needs to deal with
	#XXX multiple datacenters that have a primary/backup relationship
	#
	#XXX (snv/bou, opslab/opslabdr) and needs to deal with the case where
	#XXX there are multiple services in a single datacenter (devlab)
	#XXX the correct solution would be to multicast to find out monitoring server
	#XXX but because of the pixes we can't depend on multicast in all places.
	#
	#XXX This depends on machine db having the pseudo role "mon", and depends
	#XXX on any machine running the product API role backup-monserver running
	#XXX the queryd-proxy
	#

	my $currentMachine = ariba::Ops::Machine->new($host);

	my $monitoringDatacenter = $currentMachine->monitoringDatacenter() || $currentMachine->datacenter();

	# First try to see if monserverForDatacenter is set.  If it is, use that
	my @monitoringServers;
    if ( @monMarkedServerList && ( $monitoringDatacenter eq $currentDc )) {
        # If we created @monMarkedServerList on a previous pass and the datacenter is the same, just return it.
        @monitoringServers = @monMarkedServerList;
    }
    elsif ( !$checkedForMarkedServers ) {
        my %match = (
            datacenter  => $monitoringDatacenter,
            providesServices => 'mon',
            status => 'inservice',
            monserverForDatacenter => 1,
        );
	    @monitoringServers = @monMarkedServerList = ariba::Ops::Machine->machinesWithProperties(%match);
        $currentDc = $monitoringDatacenter;
        $checkedForMarkedServers = 1;
    }
    @monitoringServers = allMonitoringServers( $host ) unless @monitoringServers;

	my @machines = sort {$a->hostname() cmp $b->hostname()} @monitoringServers;

	# take the last one

	my $monserver = pop(@machines);

	if ( $monserver ) {
		return $monserver->hostname();
	} else {
		return undef;
	}
}

# Input: a service name
# Output: the host name of the monitoring server for the service
sub monitoringServerForService {
    my $service = shift;

    my @allMonServers = allMonitoringServers();

    my $monserver;
    # First try to match $service to $opsService within a machinedb file.
    foreach my $server ( @allMonServers ) {
        my $opsService = $server->opsService();
        if ( $opsService && $opsService eq $service ) {
            $monserver = $server->hostname();
            last;
        }
    } 

    # Otherwise use the old math
    $monserver = monitorServer() unless ( $monserver );

    return $monserver;
}

1;
