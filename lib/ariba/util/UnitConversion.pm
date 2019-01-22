package ariba::util::UnitConversion; 

use base Exporter; 

my %binaryMultipleFactors = ('B' => 0, 'K' => 10, 'M' => 20, 'G' => 30, 'T' => 40, 'P' => 50, 'E' => 60); 

sub strToNumOfBytes { 
	my $str = shift; 	
	my $numOfBytes = -1; 

	if ($str =~ /^\s*([\d\.]+)?\s*([BKMGTPE])/i) { 
		my $num = $1; 
		my $unit = uc($2); 
		$numOfBytes = $num * (1 << $binaryMultipleFactors{$unit}); 
	} 

	return $numOfBytes; 
} 

sub _createBinaryUnitConverters { 
	no strict 'refs'; 
	push(@EXPORT_OK, 'strToNumOfBytes'); 

	for my $unit (keys %binaryMultipleFactors) {
		next if ($unit eq 'B'); 
		my $subName = "strToNumOf${unit}Bs";  
		push(@EXPORT_OK, $subName); 

		*{$subName} = sub { 
			my $str = shift; 
			my $numOfBytes = strToNumOfBytes($str); 
			
			return $numOfBytes if ($numOfBytes < 0); 
			return $numOfBytes / (1 << $binaryMultipleFactors{$unit}); 
		} 
	} 
} 

_createBinaryUnitConverters(); 

1;

__END__ 

=pod

=head1 NAME
 
ariba::util::UnitConversion

=head1 DESCRIPTION
 
A set of unit conversion routines. 

=head1 SYNOPSIS 
 
 use ariba::util::UnitConversion qw(strToNumOfMBs); 

 print "MBs = " . strToNumOfMBs("1G");       # This prints: MBs = 1024
 print "MBs = " . strToNumOfMBs("2.4 gig");  # This prints: MBs = 2457.6
 print "MBs = " . strToNumOfMBs("3.5 GB");   # This prints: MBs = 3584

=head1 EXPORTABLE METHODS 

=item * strToNumOfBytes()
 
Returns the number of bytes the given string value represents, or -1 if error. Other similar exportable methods are strToNumOfKBs(), ..MBs(), ..GBs(), ..TBs(), ..PBs(), and ..EBs().

=cut 
