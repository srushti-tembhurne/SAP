# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Inserv/VolumeLun.pm#3 $
package ariba::Ops::Inserv::VolumeLun;
use base qw(ariba::Ops::PersistantObject);
use strict;

use ariba::Ops::Inserv::lunExport;

my $BACKING_STORE = undef;

sub dir {
	my $class = shift;

	return $BACKING_STORE;
}

sub setDir {
	my $class = shift;
	my $dir = shift;

	$BACKING_STORE = $dir;

	ariba::Ops::Inserv::lunExport->setDir($BACKING_STORE);
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
			'exports', '@ariba::Ops::Inserv::lunExport',
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

	#
	# we need to do fiddling to make this re-re-entrant, since PO caches all
	# this stuff, and the original code uses object state to track duplication
	#
	my @empty;
	my %seenExport;
	my %seenVlun;
	for my $line (@$outputRef) {
		$line =~ s|^\s*||;

		last if ($line =~ /^---/);

		if ($line =~ /^\d+/) {
			my ($lun, $vvName, $hostname, $port) = (split(/\s+/, $line))[0,1,2,4];

			$hostname .= ".ariba.com";

			my $vlun = $class->SUPER::new("volume-$instance-$vvName");
			unless($seenVlun{"volume-$instance-$vvName"}) {
				$vlun->setName(0);
				$vlun->setExports(@empty);
				$seenVlun{"volume-$instance-$vvName"} = 1;
			}
			my $lunExport = ariba::Ops::Inserv::lunExport->new("lunExport-$lun-$instance-$hostname");
			unless($seenExport{"lunExport-$lun-$instance-$hostname"}) {
				$lunExport->setPorts(@empty);
				$lunExport->setHost(0);
				$seenExport{"lunExport-$lun-$instance-$hostname"} = 1;
			}

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
