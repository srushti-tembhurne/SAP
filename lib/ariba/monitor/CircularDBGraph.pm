#
# $Id: //ariba/services/monitor/lib/ariba/monitor/CircularDBGraph.pm#43 $
#
package ariba::monitor::CircularDBGraph;
#
# This package is a front end of graphing data previously stored in a
# circular db.
#
# It uses gnuplot to do this graphing
#
use ariba::monitor::CircularDB;
use ariba::rc::Utils;

use strict;
use POSIX qw(strftime);
use Symbol;

my $gnuPlot = exists(&gnuPlotCmd) ? gnuPlotCmd() : "/usr/local/bin/gnuplot";
my $debug = 0;

my $gnuPlotVersion;

# avoid testing for gnuplot version on machines without gnuplot
if (-x $gnuPlot) {
	chomp($gnuPlotVersion = `$gnuPlot -V`);
	$gnuPlotVersion =~ s|gnuplot\s*(.*)\s*patchlevel.*|$1|;
}


my $smallLegendMaxSize = 48;
my $legendMaxSize = 128;


=pod

=head1 NAME

ariba::monitor::CircularDBGraph - Graph Circular Database

=head1 SYNOPSIS

	use ariba::monitor::CircularDBGraph

	my $pctmem = ariba::monitor::CircularDB->new("app11.snv.pctmem");
	my $pctcpu = ariba::monitor::CircularDB->new("app11.snv.pctcpu");

	#
	# Graph memory usage for past year
	#
	$graph = ariba::monitor::CircularDBGraph->new("year.png", 962834948, 994370948, $pctmem);
	$graph->graph();

	#
	# Graph memory AND cpu usage for past quarter
	#
	$graph = ariba::monitor::CircularDBGraph->new("quarter.png", 986536000, 994370948, $pctmem, $pctcpu);
	$graph->graph();

=head1 DESCRIPTION

CircularDBGraph provides frontend to graphing data in one or more
CircularDBs. It uses gnuplot to plot the data and generate png files.

It uses CircularDB's readRecords() method to get data out of the database.

=head1 PUBLIC CLASS METHODS

=over 4

=item * new(imagefile, startTime, endTime, @cdbs)


This creates a CircularDBGraph instance and configures
that instance to plot data stored in @cdbs circular database,
over the range start through end, and the image file to be 'imagefile'.

Returns a CircularDBGraph instance.

=cut
sub new
{
	my ($class,$outputFile,$start,$end,@cdbs) = @_;

	if ($start && $end && $start >= $end) {
		die "start time $start should be less than end time $end\n";
	}

	my $self = {};

	$self->{outputFile} = $outputFile;
	$self->{start} = $start;
	$self->{end} = $end;
	$self->{circularDBsToPlot} = [@cdbs];
	$self->{legendMaxSize} = $smallLegendMaxSize;

	$self->{debug} = 0;

	bless($self, $class);

	$self->setGraphStyle("lines");
	$self->setShowData(1);
	$self->setShowTrend(0);
	$self->setCookData(1);
	$self->setFixLogscale('0.0000001');

	return ($self);
}

=pod

=head1 PUBLIC INSTANCE METHODS

=item * setGraphStyle(style)

Set the style of the graph. These are gnuplot styles. Possible values are:

`lines`, `points`, `linespoints`, `impulses`, `dots`,
`steps`, `fsteps`, `histeps`, `errorbars`, `xerrorbars`, `yerrorbars`,
`xyerrorbars`, `boxes`, `boxerrorbars`, `boxxyerrorbars`, `financebars`,
`candlesticks` or `vector`

=cut
sub setGraphStyle
{
	my $self = shift();

	$self->{style} = shift();
}

=pod

=item * graphStyle()

Get the graph style.

=cut
sub graphStyle
{
	my $self = shift();

	return ($self->{style});
}

=pod

=item * setGraphSize(size)

Set the size of the graph. Values are 'large' and 'small'.

=cut
sub setGraphSize
{
	my $self = shift();

	$self->{size} = shift();

	if ($self->{size} eq 'small'){
		$self->{legendMaxSize} = $smallLegendMaxSize;
	} else {
		$self->{legendMaxSize} = $legendMaxSize;
	}
	
}

=pod

=item * graphSize()

Get the graph size.

=cut
sub graphSize
{
	my $self = shift();

	return ($self->{size});
}


=pod

=item * setGraphTitle(string)

Set the title of the graph.

=cut
sub setGraphTitle
{
	my $self = shift();

	$self->{title} = shift();
}

=pod

=item * graphTitle()

Get the graph title.

=cut

sub graphTitle
{
	my $self = shift;

	return $self->{title};
}

=pod

=item * setFixLogscale(string)

Set the way the graph will be fixed if logscale is activated.
If a log scale is used, it will replace values below 0 by this value.
Example : undefined values such as 1/0 or very small values like '0.00000001'

=cut
sub setFixLogscale
{
	my $self = shift();

	$self->{fixLogscale} = shift();
}

=pod

=item * fixLogscale()

Get the way the graph will be fixed if logscale is activated.
It is the value that will replace all the values below zero if
a log scale is used.

=cut

sub fixLogscale
{
	my $self = shift;

	return $self->{fixLogscale};
}


=pod

=item * setGraphType(type)

Set the type of the graph. Values are 'gif' and 'png'.

=cut
sub setGraphType
{
	my $self = shift();

	$self->{type} = shift();
}

=pod

=item * graphType()

Get the graph type.

=cut
sub graphType
{
	my $self = shift();

	return ($self->{type});
}

=pod

=item * showData()

Does this graph show the underlying data?

=cut
sub showData
{
	my $self = shift();

	return ($self->{showData});
}

=pod

=item * setShowData()

Set this graph to show/hide the underlying data.

=cut
sub setShowData
{
	my $self = shift();

	$self->{showData} = shift();
}

=pod

=item * showTrend()

Does this graph show trending data?

=cut
sub showTrend
{
	my $self = shift();

	return ($self->{showTrend});
}

=pod

=item * setShowTrend()

Set this graph to show/hide trending data.

=cut
sub setShowTrend
{
	my $self = shift();

	$self->{showTrend} = shift();
}

=pod

=item * setGraphLogScale(axis)

Turn on logscale on axis.

=cut
sub setGraphLogScale
{
	my $self = shift();

	$self->{logscale} = shift();
}

=pod

=item * graphLogScale()

Get the graph logscale.

=cut
sub graphLogScale
{
	my $self = shift();

	return ($self->{logscale});
}

=pod

=item * setCriticalThreshold(value)

Turn on the critical threshold and set the value to draw

=cut
sub setCriticalThreshold
{
	my $self = shift();

	$self->{criticalThreshold} = shift();
}

=pod

=item * criticalThreshold()

Get the critical threshold value to draw if this graph shows the critical threshold.

=cut
sub criticalThreshold
{
	my $self = shift();

	return ($self->{criticalThreshold});
}

=pod

=item * setWarningThreshold(value)

Turn on the warning threshold and set the value to draw

=cut
sub setWarningThreshold
{
	my $self = shift();

	$self->{warningThreshold} = shift();
}

=pod

=item * warningThreshold()

Get the warning threshold value to draw if this graph shows the warning threshold.

=cut
sub warningThreshold
{
	my $self = shift();

	return ($self->{warningThreshold});
}

=pod

=item * cookData()

Does this graph show cooked data?

=cut
sub cookData
{
	my $self = shift();

	return ($self->{cookData});
}

=pod

=item * setCookData()

Set this graph to cook data.

=cut
sub setCookData
{
	my $self = shift();

	$self->{cookData} = shift();
}


=pod

=item * setGraphInversed(true|false)

If true, shows graphs with black background.  Default is false.

=cut
sub setGraphInversed
{
	my $self = shift();

	$self->{inversed} = shift();
}

=pod

=item * graphInversed()

Get the graph background color

=cut
sub graphInversed
{
	my $self = shift();

	return ($self->{inversed});
}

=pod

=cut

sub gnuplot
{
	my $self = shift;
	my $plotFH = shift;
	my $cmd = shift;

	print $plotFH "$cmd\n";
	print "$cmd\n" if $self->debug();
}

=pod

=item * setYRange( yMin, yMax )

Set yrange.
YMax must be greater than yMin.

=cut
sub setYRange
{
	my $self = shift();
	my $yMin = shift();
	my $yMax = shift();

	($yMax, $yMin) = ($yMin, $yMax) if ($yMax < $yMin);

	$self->{ymin} = $yMin;
	$self->{ymax} = $yMax;
}

=pod

=item * yRange()

Get the Y range

=cut
sub yRange
{
	my $self = shift();

	return ($self->{ymin}, $self->{ymax});
}

=pod

=item * setXRange( xMin, xMax )

Set xrange.
XMax must be greater than XMin.

=cut
sub setXRange
{
	my $self = shift();
	my $xMin = shift();
	my $xMax = shift();

	($xMax, $xMin) = ($xMin, $xMax) if ($xMax < $xMin);

	$self->{xmin} = $xMin;
	$self->{xmax} = $xMax;
}

=pod

=item * xRange()

Get the X range

=cut
sub xRange
{
	my $self = shift();

	return ($self->{xmin}, $self->{xmax});
}


=pod

=item * setXRangeOffset( xMinOffset, xMaxOffset )

Set xrange offset.

=cut
sub setXRangeOffset
{
	my $self = shift();
	my $xMin = shift();
	my $xMax = shift();

	$self->{xminoffset} = $xMin;
	$self->{xmaxoffset} = $xMax;
}

=pod

=item * xRangeOffset()

Get the X range offset

=cut
sub xRangeOffset
{
	my $self = shift();

	return ($self->{xminoffset}, $self->{xmaxoffset});
}


=pod

=item * setDebug( debug )

Set debug mode.

=cut
sub setDebug
{
	my $self = shift();
	my $dbg = shift();

	$self->{debug} = $dbg;
}

=pod

=item * debug()

Get debug mode

=cut
sub debug
{
	my $self = shift();

	return $self->{debug};
}

=pod

=item * setFillStyle( fillStyle )

Set filling style.

=cut
sub setFillStyle
{
	my $self = shift();
	my $fillStyle = shift();

	$self->{fillStyle} = $fillStyle;
}

=pod

=item * fillStyle()

Get the filling style format

=cut
sub fillStyle
{
	my $self = shift();

	return $self->{fillStyle};
}


=pod

=item * graph()

Generate the graph. It is possible to plot up to 8 different cdbs on the same
graph (we use 8 distinct colors).

For it to be useful and comparable, it is recommended that data with similar
units be plotted on the same graph. This routine will handle at most 2 buckets
of dissimilar units, and plot them on y1 (left vertical axis) and y2 (right
vertical axis). For additional data that does not fit either of the buckets,
it will be simply not plotted.

=cut

sub graph
{
	my $self = shift();

	my $start = $self->{start};
	my $end = $self->{end};
	my $output = $self->{outputFile};
    

	my ($xStart, $xEnd) = $self->xRange();
	my $redirect = '';

	ariba::monitor::CircularDB->createScratchDir();
	my $scratchRoot = ariba::monitor::CircularDB->scratchDir();

	if ($self->debug()) {
		$redirect = "> $scratchRoot/gnuplot$$ 2> $scratchRoot/gnuploterr$$";

	} elsif (defined $output and $output !~ /^\s*$/) {

		$redirect = "> /dev/null 2> /dev/null";
	}

	my $plotFH = gensym();
	open($plotFH, "| $gnuPlot $redirect") or die "ERROR: Couldn't open [$gnuPlot $redirect]: $!";
	

	# and now the output type and size
	if (defined $self->{type} and $self->{type} eq 'svg') {

		if (defined $self->{size} and $self->{size} eq 'large') {

			$self->gnuplot($plotFH, "set terminal svg size 1120,696 fname 'Trebuchet'");

		} elsif (defined $self->{size} and $self->{size} eq 'medium') {

			$self->gnuplot($plotFH, "set terminal svg size 800,456 fname 'Trebuchet'");

		} else {
			$self->gnuplot($plotFH, "set terminal svg size 480,216 fname 'Tahoma' fsize 11");
		}

	} else {

		if (defined $self->{size} and $self->{size} eq 'large') {

			if ($gnuPlotVersion >= 4.2) {
				$self->gnuplot($plotFH, "set terminal png size 1120,696");
			} else {
				$self->gnuplot($plotFH, "set size 1.75,1.45");
			}

		} elsif (defined $self->{size} and $self->{size} eq 'medium') {

			if ($gnuPlotVersion >= 4.2) {
				$self->gnuplot($plotFH, "set terminal png size 800,456");
			} else {
				$self->gnuplot($plotFH, "set size 1.25,0.95");
			}

		} else {

			if ($gnuPlotVersion >= 4.2) {
				$self->gnuplot($plotFH, "set terminal png size 480,216");
			} else {
				$self->gnuplot($plotFH, "set size 0.75,0.45");
			}
		}

		if ($self->{inversed}) {
			if ($gnuPlotVersion >= 4.2) {
				$self->gnuplot($plotFH, "set terminal png small x000000 xffffff x444444");
			} else {
				$self->gnuplot($plotFH, "set terminal png small color x000000 xffffff x444444");
			}
		} else {
			if ($gnuPlotVersion >= 4.2) {
				$self->gnuplot($plotFH, "set terminal png small");
			} else {
				$self->gnuplot($plotFH, "set terminal png small color");
			}
		}
	}

	#
	if (defined $output and $output !~ /^\s*$/) {

		ariba::monitor::CircularDB->createDirForFile($output);
		$self->gnuplot($plotFH, "set output \"$output\"");
	}

	if (defined $self->{logscale}) {
		$self->gnuplot($plotFH, sprintf("set logscale %s", $self->{logscale}));
	}

	if ( defined $self->{title} ) {
		$self->gnuplot($plotFH, sprintf("set title \"%s\"", $self->{title}));
	}

	$self->gnuplot($plotFH, "set grid");
	$self->gnuplot($plotFH, "set key below");
	$self->gnuplot($plotFH, "set xdata time");

	# if gnuplot >= 3.8, we can pass it unixtime
	my $dateFormat;

	# TODO: use %s as gmtime with more recent version of gnuplot
	if ($gnuPlotVersion >= 3.8) {

		$dateFormat = undef;
		$self->gnuplot($plotFH, "set timefmt \"%s\"");

	} else {
		$dateFormat = '%m/%d/%Y,%H:%M:%S';
		$self->gnuplot($plotFH, "set timefmt \"$dateFormat\"");
	}

	my ($ylabel, $y2label);

	my $graphStyle  = $self->graphStyle();
	my $fillStyle  = $self->fillStyle();
	my $numPlots	= 0;
	my $plotCmd	= 'plot';
	my $forGraphing = $self->cookData();
	my %axes	= ();
	my @styles	= ();

	if ($gnuPlotVersion >= 3.8) {
		@styles = qw(3 1 2 9 10 8 7 13);
	} else {
		@styles = qw(9 8 7 10 14 12 11 13);
	}

	if ( $fillStyle ) {
		$self->gnuplot($plotFH, "set style fill $fillStyle");
	}


	# We use a hashtable to count how many time is used a cdb's name.
	# So if a cdb's name is used twice or more, we will use the cdb's 
	# longer name instead
	my %listOfCdb = ();
	for my $cdb (@{$self->{circularDBsToPlot}}) {

		my $name = $cdb->name();

		$listOfCdb{$name}++;
	}

	for my $cdb (@{$self->{circularDBsToPlot}}) {


		my $name = $cdb->name();

		# If the cdb name is used more than once,
		# we use it's longer name
		if ($listOfCdb{$name} > 1) {
			$name = $cdb->longerName();
		}

		my $units = $cdb->units();
		my $dataType = $cdb->dataType();

		$name =~ s/\.ariba\.com//g;

		if (length($name) > $self->{legendMaxSize}) {
			my $halfSize = int(($self->{legendMaxSize} - 5) / 2);
			$name = substr($name, 0, $halfSize) . '[...]' . substr($name, - $halfSize );
		}
        
		my $dataFile = "$scratchRoot/$name.dat";
		$dataFile =~ s#[^\w\d_:\.\/-]#_#go;

		ariba::monitor::CircularDB->createDirForFile($dataFile);

		my $fh = gensym();
		open($fh, "> $dataFile") || die "Could not open $dataFile\n";

		my ($realStart, $realEnd) = $cdb->printRecords(
			$start, $end, undef, $fh, $dateFormat, $forGraphing, 1
		);

		close($fh);


		if ($forGraphing && $dataType eq "counter") {
			#
			# Work around for counter-based cpu usage, which is really a
			# percentage once it's cooked. This will allow linux and sun
			# cpu graphs to have the same units and be comparable.
			# 
			if ($name =~ /percent/i) {
				$units = "percent";
			}

			$name .= "($units)";
		}

		my $axis = $axes{$units};

		unless($axis) {
			$axis = $axes{$units} = keys %axes >= 1 ? 'x1y2' : 'x1y1';
		}

		if ($units) {
			if ($axis =~ m|y1|) {
				$ylabel = $units;
			} else {
				$y2label = $units;
			}
		}

		# uncomment these lines to disable bucketing
		#$axis = "x1y1";
		#$y2label = undef;




		# Data can be processed on the fly by gnuplot.
		#  int the "using 1:2" statement, "2" represent the
		#  y value to be read (2 means here gnuplot has to read 
		#  the 2nd column of the datas).
		#  So if a log scale is used and the way to fix it is defined,
		#  each value below 0 will be replaced by the value provided by fixLogscale.


		my $yaxis = '2';
		if (defined $self->{logscale}) {
			if (defined	$self->{fixLogscale}) {

				# We use the ? operator :
				# condition ? TRUE : FALSE
				#
				# So if the y value is > 0 we use it.
				# If the y value <= 0, then we replace this value by the one provided
				#  by fixLogscale
				$yaxis = '($2>0?$2:' . $self->{fixLogscale} . ')';

				# If the value provided by fixLogscale is a numeric one
				# we signal to the user we have replaced all the values below zero by
				# the value provided by fixLogscale
				if ($self->{fixLogscale} =~ m/\d+\.?\d*/) {	
					$ylabel .= ' [' .$self->{fixLogscale} . ' means zero] ';
					$y2label .= ' [' .$self->{fixLogscale} . ' means zero] ';
				}
			}
		}

		if ( $self->showData() ) {
			my $style = $styles[$numPlots];
			#$style = "" if ($graphStyle eq "histogram");
			#$graphStyle = "" if ($graphStyle eq "histogram");

			$plotCmd .= " \"$dataFile\" using 1:$yaxis axes $axis title \"$name\"" .
				" with $graphStyle $style,";
				# This needs gnuplot 3.8i+ - we can change it once sysadmin installs
				#" with $graphStyle lw 1.5 lt $styles[$numPlots],";

				$numPlots++;
				$numPlots %= scalar(@styles);
		}

		if ( $self->showTrend() ) {
			$plotCmd .= " \"$dataFile\" using 1:$yaxis smooth bezier axes $axis title \"$name trend\"" .
				" with $graphStyle $styles[$numPlots],";
				# This needs gnuplot 3.8i+ - we can change it once sysadmin installs
				#" with $graphStyle lw 1.5 lt $styles[$numPlots],";

				$numPlots++;
				$numPlots %= scalar(@styles);
		}

		if ( $self->criticalThreshold() ) {
			$plotCmd .= " " . $self->criticalThreshold() . " " . 'lt rgb "red" notitle,';
		}

		if ( $self->warningThreshold() ) {
			$plotCmd .= " " . $self->warningThreshold() . " " . 'lt rgb "yellow" notitle,';
		}

		unless ($xStart) {
			$xStart = $realStart;
		} else {
			$xStart = $realStart < $xStart ? $realStart : $xStart;
		}

		unless ($xEnd) {
			$xEnd = $realEnd;
		} else {
			$xEnd = $realEnd > $xEnd ? $realEnd : $xEnd;
		}
	}

	chop $plotCmd;

	# copy these, as to be able to set xtics
	my ($xStartOffset, $xEndOffset) = $self->xRangeOffset() || (0, 0);
	my ($xrangeBegin, $xrangeEnd) = ($xStart + $xStartOffset, $xEnd + $xEndOffset);

	if (defined $dateFormat) {
		$xrangeBegin = POSIX::strftime($dateFormat, localtime($xStart));
		$xrangeEnd   = POSIX::strftime($dateFormat, localtime($xEnd));
	}

	$self->gnuplot($plotFH, "set xrange [\"$xrangeBegin\":\"$xrangeEnd\"]");
	$self->gnuplot($plotFH, "set ylabel \"$ylabel\"") if $ylabel;

	
	my ($yMin, $yMax) = $self->yRange();

	if (defined($yMin) && defined($yMax)) {
		$self->gnuplot($plotFH, "set yrange [\"$yMin\":\"$yMax\"]");
	}

	if ($y2label) {
		$self->gnuplot($plotFH, "set y2label \"$y2label\"");
		$self->gnuplot($plotFH, "set y2tics");
	}

	my $oneHour = 3600;

	# for plots longer than a quarter, skip day and hour information
	if ($xEnd - $xStart <= 30 * $oneHour) {

		# day
		$self->gnuplot($plotFH, "set format x \"%H:%M\\n%m/%d\"");

	} elsif ($xEnd - $xStart <= 9 * 24 * $oneHour) {

		if ($ylabel && $ylabel eq "per day") {
			$self->gnuplot($plotFH, "set format x \"%b %d\"");
		} else {
			# week
			$self->gnuplot($plotFH, "set format x \"%H:%M\\n%b %d\"");
		}

	} elsif ($xEnd - $xStart <= 35 * 24 * $oneHour) {

		# month
		$self->gnuplot($plotFH, "set format x \"%b %d\"");

	} elsif ($xEnd - $xStart <= 4 * 31 * 24 * $oneHour) {

		# quarter
		$self->gnuplot($plotFH, "set format x \"%b %d\"");

	} else {
		# > quarter
		$self->gnuplot($plotFH, "set format x \"%m/%y\"");
	}

	$self->gnuplot($plotFH, $plotCmd);


	close($plotFH);
	ariba::monitor::CircularDB->removeScratchDir() unless $debug;

	return 1;
}

sub main
{
	my $sincos = 0;
	my $sin;
	my $cos;
	my $graph;

	my $foo = ariba::monitor::CircularDB->new("web11.snv.ariba.com.2.in");

	$graph = ariba::monitor::CircularDBGraph->new("all.png", undef, undef, $foo); 
	$graph->graph();

	exit();

	if ($sincos) {
		$sin = ariba::monitor::CircularDB->new("test/sin","sin",5000,"gauge");
		$cos = ariba::monitor::CircularDB->new("test/cos","cos",5000,"gauge");

		my $start = time();
		my $t;
		my (@sin, @cos);
		my $i = 0;

		for ($t=$start; $t<$start+300*300; $t+=300){
			($sin[$i][0], $sin[$i][1]) = ($t, sin($t/3000)*50+50);
			($cos[$i][0], $cos[$i][1]) = ($t, cos($t/3000)*50+50);
			$i++;
		}

		$sin->writeRecords(@sin);
		$cos->writeRecords(@cos);

		print "Wrote:\n";
		#$sin->printHeader();
		#$sin->printRecords();

		#print "\n\nRead Back:\n";
		#$sin->print();

		$graph = ariba::monitor::CircularDBGraph->new("sincos.png", 
										undef,
										undef,
										#$start,
										#$t, 
										$sin, 
										$cos);
		$graph->graph();
	}

	my $pctmem =
	ariba::monitor::CircularDB->new("app11.snv.ariba.com.pctcpu");

	$graph = ariba::monitor::CircularDBGraph->new("year.png", 962834948,
		994370948, $pctmem); $graph->graph();

	$graph = ariba::monitor::CircularDBGraph->new("quarter.png",
		986536000, 994370948, $pctmem, $sin); $graph->graph();

	$graph = ariba::monitor::CircularDBGraph->new("month.png", 991870948,
		994370948, $pctmem); $graph->graph();

	$graph = ariba::monitor::CircularDBGraph->new("week.png", 993766148,
		994370948, $pctmem); $graph->graph();

	$graph = ariba::monitor::CircularDBGraph->new("day.png", 994270948,
		994370948, $pctmem); $graph->graph();
}

#main();

1;

__END__

=pod

=back

=head1 AUTHOR

Manish Dubey <mdubey@ariba.com>

=head1 SEE ALSO

	ariba::monitor::CircularDB

=cut

