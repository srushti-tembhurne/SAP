package ariba::Ops::NetworkDeviceManager;
 
# $Id: //ariba/services/tools/lib/perl/ariba/Ops/NetworkDeviceManager.pm#11 $

use strict;
use ariba::Ops::Machine;
use ariba::Ops::DatacenterController;

# Class methods

sub newFromMachine {
	my $class   = shift;
	my $machine = shift;
	my $proxy = shift;

    # packages must follow perl bareword rules (alphanum + underscore).
    # coerce hyphens to underscore, then raise an exception if we still
    # find non-bareword chars.

    my $os = $machine->os();
    $os =~ s/-/_/g;
    $os = lc($os);

    unless($os =~ /^\w+$/) {
        $@ = "invalid OS name"; # set exception in case caller wants to do something with it
		printf STDERR "Couldn't load class for host: [%s] with OS: [%s] Error = $@\n", $machine->hostname(), $os;
        return;
    }

    my $className = "ariba::Ops::NetworkDevice::$os";

	#
	# This is LAME, but since ops-migrate-ss runs from the build, but gets
	# label locked, we need to force it to load from the cfengine depot.
	#
	# UGGG!
	#
	my @SAVE = @INC;
	if($0 =~ /ops-migrate-ss/) {
		@INC = grep { $_ !~ m|/home/| } @INC;
		push(@INC, "/usr/local/ariba/lib");
	}

	eval qq(require $className);

	@INC = @SAVE;

	if ($@) {
		printf STDERR "Couldn't load class [%s] for host: [%s] with OS: [%s]\n", $className, $machine->hostname(), $machine->os();
		printf STDERR "Error = $@\n";
		return;
	}

	return $className->newFromMachine($machine, $proxy);
}

sub newFromDatacenter {
	my $class = shift;
	my $datacenter = shift;
	my $classType = shift;
	my $proxy = shift;

	return unless ($datacenter && $classType);

	if ($classType eq 'inserv') {
		$datacenter = "opslab,lab1" if ($datacenter =~ /opslab/);
	}

	my %match = (
			'os'          => $classType,
			'datacenter'  => $datacenter,
			'status'      => 'inservice',
		    );

	my @machines = ariba::Ops::Machine->machinesWithProperties(%match);

	unless(@machines) {
		return;
	} 

	my @selves;
	for my $machine (@machines) {
		my $self = $class->newFromMachine($machine, $proxy);
		push @selves, $self;
	}

	if (wantarray()) {	
		return @selves;
	} elsif (scalar(@selves)) {
		return $selves[0]; 
	} else {
		return;
	}
}

sub ndmFromList {
	my $listRef = shift;
	my $hostname = shift;

	for my $ndm (@$listRef) {

		return $ndm if $ndm->hostname() eq $hostname

	}

	return;

}

sub arpTableAndCamTableForSwitchAndAccessPassword {

	my $switch         = shift;
	my $accessPassword = shift;


	my $networkDevice = ariba::Ops::NetworkDeviceManager->newFromMachine($switch);

	$networkDevice->setAccessPassword($accessPassword);

	my $arpTable      = $networkDevice->arpTable();
	my $camTable      = $networkDevice->camTable();


	return ($arpTable, $camTable);
}

1;

__END__
