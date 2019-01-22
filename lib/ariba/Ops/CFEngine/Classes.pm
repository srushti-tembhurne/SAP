package ariba::Ops::CFEngine::Classes;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/CFEngine/Classes.pm#27 $
# set various classes for cfengine
# this is really module:setclasses - but p4 doesn't like the :
# so there's a symlink. this will be fixed if the p4 server is moved off NT.

use strict;
use lib qw(/usr/local/ariba/lib);

use ariba::Ops::NetworkUtils;
use ariba::Ops::Constants;
use ariba::Ops::Machine;

my $debug = 0;

my @machineAttributes = qw(hardwareType dnsDomain datacenter arch providesServices os service);

sub setDebug {
	my $class = shift;

	$debug = shift;
}

sub printClasses {
	my $class = shift;
	$class->_setClasses('print');
}

sub returnClasses {
	my $class = shift;
	return $class->_setClasses('return');
}

sub _setClasses {
	my $class  = shift;
	my $action = shift;

	local $^W = 0;

	my @classes  = qw(common);

	my $hostname = ariba::Ops::NetworkUtils::hostname();

	# HPUX machines don't always give the FQDN with hostname()
	my $host   = ariba::Ops::NetworkUtils::addrToHost( ariba::Ops::NetworkUtils::hostToAddr($hostname) );
	my $tier   = ariba::Ops::NetworkUtils::hostnameToTier($host);

	# Try and guess the tier from the hostname
	# Net 172. problem.
	unless (defined $tier) {

		if ($hostname =~ /^\S+-n([0-3])\./) {
			$tier = $1;
		} else {
			$tier = 0;
		}
	}

	# open the machinedb
	my $machine = ariba::Ops::Machine->new($host);
	my $combinedRev;

	# always add the hostname as a class.
	push @classes, (split(/\./, $host))[0];
	push @classes, $host;
	push @classes, "tier$tier";

	# short os version
	my $release = $machine->osVersion();
	push @classes, $release;

	my $memSize = $machine->memorySize();
	push @classes, $memSize . "MB";

	my $os = $machine->os() if $machine;
	
	if ($machine) {

		for my $attribute (@machineAttributes) {
			if (defined $machine->$attribute()) {
				push @classes, $machine->$attribute();
			}
		}

		# ack. backwards compatibility
		# and for package distribution
		if (defined $machine->os() and $machine->os() eq 'sunos') {
			push @classes, 'solaris';
			$os = 'solaris';

			$combinedRev = "$os$release";
			$combinedRev =~ s/5\.//;
		}
		
		# Cfengine should have this defined already but it doesn't
		# seem to work so I'm putting this in for now
		if (defined $machine->os() and $machine->os() eq 'hp-ux') {
			push @classes, 'hpux';
			$os = 'hpux';

			if ($release eq 'B.11.11') {
				$combinedRev = "${os}11i";
			} else {
				$combinedRev = "${os}11";
			}
		}

		# redhat munging
		if (defined $machine->os() and $machine->os() eq 'redhat') {
			push @classes, 'linux';
			$os = 'redhat';

			if ( defined $machine->arch() and $machine->osVersion() ) {
				push @classes, $machine->osVersion;

				$combinedRev = "$os$release";
				$combinedRev =~ s/(redhat\d).*/$1/i;
			}

		}

                # Defining CentOS as linux and version
                if (defined $machine->os() and $machine->os() eq 'centos') {
                        push @classes, 'linux';
                        $os = 'centos';

                        if ( defined $machine->arch() and $machine->osVersion() ) {
                                push @classes, $machine->osVersion;

                                $combinedRev = "$os$release";
                                $combinedRev =~ s/(centos\d).*/$1/i;
                        }

                }


		# Need to make sure 000100 cfengine script gets information about SUSE
		# See TMID: 150754
		if (defined $machine->os() and $machine->os() eq 'suse') {
			push @classes, 'linux';
			$os = 'suse';

			if ( defined $machine->arch() and $machine->osVersion() ) {
				push @classes, $machine->osVersion;

				$combinedRev = "$os$release";
				$combinedRev =~ s/(suse\d).*/$1/i;
			}

		}

                # Add os->arch.
		# See TMID: 176032
                my $os = $machine->os();
                my $arch = $machine->arch();
                push ( @classes, "${os}-${arch}" );

		push @classes, $combinedRev;

		# Add $arch to $combinedRev
		# See TMID: 176032
		push ( @classes, "${combinedRev}-${arch}" );

		# Define a non-storage pseudo-class.
		# This is a convenience class used to address all non-storage hosts.
		# The primary use case for this is to distribute a different kernel
		# to storage and non-storage hosts.

		my $providesStorage = 0;

		foreach my $provides ($machine->providesServices()) {
			if ($provides eq 'storage') {
				$providesStorage = 1;
				last;
			}
		}

		push( @classes, 'nonstorage' ) unless $providesStorage;


		my @allClasses = @classes;

		# Define psuedo-class <hardwareType>-<class> for all classes of this host. 
		# This will allow us to install packages per <hardwareType>-<class> (e.g. x4140-app, x4100m2-mon).
		my $hardwareType = $machine->hardwareType();
		foreach my $class ( @allClasses ) {
			push ( @classes, "${hardwareType}-${class}" );
		}

		# Define psuedo-class <datacenter>-<class> for all classes of this host. 
		# This will allow us to install packages per <datacenter>-<class> (e.g. opslab-nonstorage, devlab-app, snv-util).
		my $dataCenter = $machine->datacenter();
		foreach my $class ( @allClasses ) {
			push ( @classes, "${dataCenter}-${class}" );
		}

		# Define psuedo-class <service>-<class> for all classes of this host.
		# This will allow us to install packages per <service>-<class> (e.g. lab-nonstorage, dev-app, prod-util).
		if ( defined $machine->service() ) {
			my $service = $machine->service();
			
			foreach my $class ( @allClasses ) {
				push ( @classes, "${service}-${class}" );
			}
		}
	}


	###################################################
	# results format.
	if ($action eq 'print') {
		map { print "+$_\n" } @classes;

	} elsif ($action eq 'return') {
		my %return = map { $_ => 1 } @classes;
		   $return{'os'}	 = $os;
		   $return{'osRev'}	 = $release;
		   $return{'datacenter'} = $machine->datacenter();
		   $return{'hostname'}   = $hostname;
		   $return{'arch'}       = $machine->arch();
		return \%return;
	}
}

1;

__END__
