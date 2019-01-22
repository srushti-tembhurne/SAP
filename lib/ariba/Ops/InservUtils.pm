package ariba::Ops::InservUtils;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/InservUtils.pm#1 $

use strict;

my $debug = 0;

sub vvNamesFromFile {
	my $listFile = shift;
	my $vvListForVolume = shift;

	my @vvNames;

	return @vvNames unless (-r $listFile);

	open(LIST, $listFile) || return @vvNames;
	while (my $line = <LIST>) {                                                                                                                                       #
		# Format of the file:
		# fs: ora01data01
		# inserv: inserv.snv.ariba.com
		# vv: 00197-0
		# vv: 00197-2
		# vv: 00197-3
		#
		chomp($line);
		next if ($line =~ /^\s*$/);

		#
		# Match the volume name in the file
		#
		my ($name, $value) = split(/:\s*/, $line);

		if ($name eq "fs") {
			if ($value ne $vvListForVolume) {
				print "Error: Volume name in $listFile ($value) does not match $vvListForVolume specified on command line\n";
				return @vvNames;
			}
			next;
		} elsif ($name eq "inserv") { 
			unshift(@vvNames, $value);
		} elsif ($name eq "vv") {
			push(@vvNames, $value);
		} else {
			print "Warning: Unknown object specified as '$name' in '$listFile'\n";
		}
	}
	close(LIST);

	return @vvNames;
}

1;

__END__
