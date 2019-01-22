package ariba::util::Math;

=pod

=head1 VERSION

$Id: //ariba/services/tools/lib/perl/ariba/util/Math.pm#1 $

=head1 NAME

ariba::util::Math - Utility math functions

=head1 SYNOPSIS
	
 use ariba::util::Math; 

 my @xyDataPoints = ([1, 2], [3, 4]); 
 my $slope = ariba::util::Math::linearRegressionSlopeForXyDataPoints(\@xyDataPoints);

=head1 DESCRIPTION

A list of utility functions that does math computation. 

=head1 CLASS METHODS

=over 4

=item * linearRegressionSlopeForXyDataPoints ($xyDataPointsArrayRef) 

Computes the slope of the provided data points using simple linear regression.
http://en.wikipedia.org/wiki/Simple_linear_regression

Params: 
	$xyDataPointsArrayRef    Array ref containing x and y values. 
	                      Ex: [[1, 2], [3, 4], ... [x, y]]

Returns:
	Slope of the x and y data points using simple linear regression. 

Example Calculation: 
	sum of x:  1,  2,  3,  4,  5   = 15
	sum of y:  10, 12, 14, 16, 20  = 72
	sum of xy:     10, 24, 42  64  100 = 240
	sum of x^2:    1,  4,  9,  16, 25  = 55
	count n:  5
	n(xy) - (x)*(y): 5 * 240 - 15 * 72 = 120
	n(x^2) - (x)^2: 5 * 55 - 15*15 = 50
	slope = 120 / 50 = 2.4

=cut 

sub linearRegressionSlopeForXyDataPoints {
	my $dataPoints = shift; 

	return unless (ref($dataPoints) eq 'ARRAY' && scalar(@$dataPoints));
	
	my $count = scalar(@$dataPoints); 
	my $sumX = 0; 
	my $sumY = 0; 
	my $sumXY = 0;
	my $sumXX = 0;

	foreach my $data (@$dataPoints) {
		my $x = $data->[0];
		my $y = $data->[1];

		return unless (defined($x) && defined($y));

		$sumX += $x; 
		$sumY += $y;
		$sumXY += $x * $y; 
		$sumXX += $x * $x;
	}

	my $numerator = $count * $sumXY - $sumX * $sumY; 
	my $denominator = $count * $sumXX - $sumX * $sumX; 

	return unless ($denominator);

	return $numerator / $denominator;	
}

=item * xForYUsingSlopeAndIntercept ($y, $slope, $intercept) 

Computes the X value based on the provided info using the straight
line formula: y = mx + b, where m = slope, and b = y-intercept

Params: 
	$y          Y value
	$slope      Slope of the line
	$intercept  Y-interception value

Returns: 
	X value based on the provided info using straight line formula.
	x = (y - b) / m

=cut

sub xForYUsingSlopeAndIntercept {
	my $y = shift; 
	my $slope = shift; 
	my $intercept = shift;

	return unless ($slope);	

	my $x = ($y - $intercept) / $slope;

	return $x;
}

return 1;
