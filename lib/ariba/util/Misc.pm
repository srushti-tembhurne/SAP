# 
# $Id: //ariba/services/tools/lib/perl/ariba/util/Misc.pm#2 $
#
# A package that contains miscellaneous utility functions

package ariba::util::Misc; 

use strict;

=pod

=head1 NAME

ariba::util::Misc

=head1 DESCRIPTION

A list of miscellaneous functions that are not big enough to be in its own
package.

=head1 METHODS

=over 4

=item * compareVersion(version1, version2)

Returns the following values based on version1 and version2 text - ex: 1.2.3

	If version1 is greater than version2, return 1
	If version1 is same as version2, return 0
	If version1 is less than version2, return -1	

=cut
 
sub compareVersion {
	my $version1 = shift; 
	my $version2 = shift; 

	return 0 unless (defined($version1) || defined($version2)); 
	return -1 unless (defined($version1)); 
	return 1 unless (defined($version2));

	my @version1 = split(/\./, $version1); 
	my @version2 = split(/\./, $version2); 
	
	my $highestIndex = $#version1 > $#version2 ? $#version1 : $#version2; 

	for (my $i = 0; $i <= $highestIndex; $i++) {
		return -1 unless (defined($version1[$i])); 
		return 1 unless (defined($version2[$i]));

		return $version1[$i] <=> $version2[$i] unless ($version1[$i] == $version2[$i]);
	}

	return 0;
}
 
sub xmlNameForText {
	my $text = shift;

	if ($text) {
		$text =~ s/[^\w]*\b(\w)(\w*)\b[^\w]*/\U$1\L$2/g;
		$text = lcfirst($text);
	}

	return $text;
}

sub textForXmlName {
	my $name = shift; 

	if ($name) {
		$name =~ s/(\w)([A-Z])/$1 \L$2/g;
	}

	return $name;
}

sub test { 

	my %versions = (
		'1.2.2' => '1.2.3',
		'1.2.3' => '1.2.3',
		'1.2.4' => '1.2.3',
	);

	foreach my $v1 (sort { compareVersion($a, $b) } keys(%versions)) {
		my $v2 = $versions{$v1};
		print "Comparing $v1 <=> $v2: ", compareVersion($v1, $v2), "\n"; 
	}
}

return 1;
