#
# Math functions for Ariba products
#
# $Id: //ariba/services/monitor/lib/ariba/monitor/Math.pm#1 $
#

package ariba::monitor::Math;

require Math::BigInt;

#
# Convert a base 10 integer (in string form) to a base 36 string. 
# Use for converting POIDs to Fax/Mail IDs.
#
sub base10toBase36{
	my $number = shift;

	$number = Math::BigInt->new($number);

	return 0 if $number == 0;

	my @digits = (0..9,'a'..'z');

	my $result = "";

	while ($number > 0) {
		my $quotient = Math::BigInt->new($number / 36);
		my $modulus = $number % 36;

		$result .= $digits[$modulus];
		$number = $quotient;
	}

	return join('', reverse(split(//, $result)));
}

1;
