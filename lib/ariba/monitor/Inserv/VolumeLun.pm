# $Id: //ariba/services/monitor/lib/ariba/monitor/Inserv/VolumeLun.pm#3 $
package ariba::monitor::Inserv::VolumeLun;

############################################################################
############################################################################
############################################################################
############################################################################
############################################################################
############################################################################
############################################################################
#
# NetworkDeviceManager.pm and the related sub libraries are being moved
# to //ariba/services/tools/lib/perl/ariba/Ops/...
#
# If you need to make changes to this file, make them there, and change your
# calling code to use ariba::Ops::NetworkDeviceManager instead.
#
############################################################################
############################################################################
############################################################################
############################################################################
############################################################################
############################################################################
############################################################################


use base qw(ariba::Ops::PersistantObject);
use strict;

use ariba::monitor::Inserv::lunExport;

my $BACKING_STORE = undef;

sub dir {
	my $class = shift;

	return $BACKING_STORE;
}

sub setDir {
	my $class = shift;
	my $dir = shift;

	$BACKING_STORE = $dir;

	ariba::monitor::Inserv::lunExport->setDir($BACKING_STORE);
}

sub remove {
	my $self = shift;


	for my $lunExport ($self->exports()) {
		$lunExport->remove()
	}

	$self->SUPER::remove(); 
}

sub objectLoadMap {
	my $class = shift;

	my %map = (
			'exports', '@ariba::monitor::Inserv::lunExport',
		  );

	return \%map;
}

sub validAccessorMethods {
        my $class = shift;

	my $methodsRef = $class->SUPER::validAccessorMethods();

        $methodsRef->{'name'} = undef;
        $methodsRef->{'exports'} = undef;
        $methodsRef->{'fs'} = undef;

        return $methodsRef;
}

sub vlunsFromCmdOutput {
	my $class = shift;
	my $outputRef = shift;
	my $instance = shift;
	my $filesystem = shift;

	my @volumes;

	for my $line (@$outputRef) {
		$line =~ s|^\s*||;

		last if ($line =~ /^---/);

		if ($line =~ /^\d+/) {
			my ($lun, $vvName, $hostname, $port) = (split(/\s+/, $line))[0,1,2,4];

			$hostname .= ".ariba.com";

			my $vlun = $class->SUPER::new("volume-$instance-$vvName");
			my $lunExport = ariba::monitor::Inserv::lunExport->new("lunExport-$lun-$instance-$hostname");

			if ($lunExport->ports() && !grep($_ eq $port, $lunExport->ports())) {
				$lunExport->appendToAttribute('ports', $port);
			} elsif (!$lunExport->ports()) {
				$lunExport->setPorts($port);
			}

			unless ($lunExport->host()) {
				$lunExport->setLun($lun);
				$lunExport->setHost($hostname);
				if ($vlun->exports()) {
					$vlun->appendToAttribute('exports', $lunExport);
				} else {
					$vlun->setExports($lunExport);
				}
			}

			unless ($vlun->name()) {
				$vlun->setName($vvName);
				$vlun->setFs($filesystem) if $filesystem;
				push(@volumes, $vlun);
			} 
		}
	}

	return @volumes;
}

1;
