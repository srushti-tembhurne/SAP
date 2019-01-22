# $Id: //ariba/services/monitor/lib/ariba/monitor/AggregateCDB.pm#7 $
#
# This class needs following items revisited:
#  - constructor, split new vs newWith*
#  - storage 
#  - algorithms
#
#
package ariba::monitor::AggregateCDB;

use strict;

use ariba::monitor::CircularDB;
use ariba::monitor::CDBFactory;
use ariba::monitor::misc;
use ariba::Ops::PersistantObject;
use base qw(ariba::Ops::PersistantObject);
use FileHandle;
use Math::Interpolate qw(linear_interpolate robust_interpolate);

my $acdbExt = '.acdb';
my $debug   = 0;
my $prefix  = 'Aggregate Part ';

sub new {
	my ($class,$instance) = @_;

	my $name = $instance;

	if ($name =~ m|$acdbExt$|) {
		$name =~ s/$acdbExt//;
	}

	if ($instance !~ m#^(/|\.)#) {
		$instance =~ s#[^\w\d_:\.\/-]#_#go;
	}

	if ($instance !~ m|$acdbExt$|) {
		$instance .= $acdbExt;
	}

	my $self = $class->SUPER::new($instance);

	$self->setName($name);

	return $self;
}

sub fileName {
	my $self = shift;
	return $self->_backingStore();
}

sub dataType {
	my $self = shift;
	return $self->SUPER::dataType() || 'gauge';
}

sub units {
	my $self = shift;
	return $self->SUPER::units() || '';
}

sub dir {
	my $class = shift;

	return ariba::monitor::misc::circularDBDir();
}

sub setCdbs {
	my $self = shift;

	my @names = ();

	for my $obj (@_) {
		my $name = $obj->fileName(); 
		$name =~ s#[^\w\d_:\.\/-]#_#go if ($name =~ m/^file:\/\//i );
		push @names, $name;
	}

	$self->SUPER::setCdbs(@names);
}

sub cdbs {
	my $self = shift;
	my @cdbs = ();

	if (defined $self->{'cdbs'} && scalar @{$self->{'cdbs'}} > 0) {
		return @{$self->{'cdbs'}};
	}

	for my $name ($self->SUPER::cdbs()) {
		push @{$self->{'cdbs'}}, ariba::monitor::CDBFactory->new($name);
	}

	return @{$self->{'cdbs'}};
}

sub readRecords {
        my ($self,$start,$end,$numRequired,$arrayRef) = @_;

	my @cdbs = $self->cdbs();

	# return from the driver cdb.
	return $cdbs[0]->readRecords($start,$end,$numRequired,$arrayRef);
}

sub printRecords {
	my $self = shift;
	my $start = shift;
	my $end = shift;
	my $numRequested = shift;
	my $outFH = shift || *STDOUT;
	my $dateFormat = shift;
	my $cookedForGraphing = shift;

	ariba::monitor::CircularDB->createScratchDir();
	my $scratchRoot = ariba::monitor::CircularDB->scratchDir();

	my @dataFiles   = ();
	my %parsedData  = ();
	my (@realStart,@realEnd);


	# We use a hashtable to count how many time is used a cdb's name.
	# So if a cdb's name is used twice or more, we will use the cdb's 
	# longer name instead
	my %listOfCdb = ();
	for my $cdb ($self->cdbs()) {

		my $name = $cdb->name() || "Unknown $cdb";

		$listOfCdb{$name}++;
	}


	for my $cdb ($self->cdbs()) {

		my $name = $cdb->name() || "Unknown $cdb";

		# If the cdb name is used more than once,
		# we use it's longer name
		if ($listOfCdb{$name} > 1) {
			$name = $cdb->longerName();
		}


		if ($name !~ /^$prefix/) {
			$name = $prefix . $name;
		}

		my $dataFile = "$scratchRoot/$name.dat";
		$dataFile =~ s#[^\w\d_:\.\/-]#_#go;

		ariba::monitor::CircularDB->createDirForFile($dataFile);

		# for later consumption
		push @dataFiles, $dataFile;

		my ($realStart,$realEnd);

		print STDERR localtime()." ariba::monitor::AggregateCDB about to work on $dataFile\n" if $debug;

		unless (-f $dataFile) {

			print STDERR localtime() . " ariba::monitor::AggregateCDB creating $dataFile\n" if $debug;
			my $fh = FileHandle->new(">$dataFile") || die "Could not open $dataFile\n";

			($realStart, $realEnd) = $cdb->printRecords(
				$start, 
				$end, 
				undef,
				$fh, 
				$dateFormat,
				$cookedForGraphing,
			);
			$fh->close();

		} else {

			print STDERR localtime() . " ariba::monitor::AggregateCDB reusing $dataFile\n" if $debug;
			my $fh = FileHandle->new($dataFile) || die "Could not open $dataFile\n";
			my @db = <$fh>;
			$fh->close();  
					
			$realStart = (split /\s+/, shift @db)[0];
			$realEnd   = (split /\s+/, pop @db)[0];
		}

		if ($debug) {
			print STDERR localtime() . " ariba::monitor::AggregateCDB realStart: [$realStart]\n";
			print STDERR localtime() . " ariba::monitor::AggregateCDB realEnd: [$realEnd]\n";
		}

		push @realStart, $realStart;
		push @realEnd, $realEnd;

		# this is about a minute faster than a while <FH> loop when dealing with large files.
		open(DATA, $dataFile) or die "Can't open $dataFile: $!";
		sysread(DATA, my $rawData, -s DATA);
		close DATA;

		for my $line (split /\n/, $rawData) {
			my ($time,$data) = split ' ', $line;
			$parsedData{$dataFile}->{$time} = $data;
		}
	}

	# do the linear interpolation
	my $driver = shift @dataFiles;

	my @driverXValues = ();
	my %interpolatedValues = ();

	# setup initial xy mapping
	for my $time (sort { $a <=> $b } keys %{$parsedData{$driver}}) {

		next unless $time =~ /^\d+$/;

		push @driverXValues, $time;
		$interpolatedValues{$time} = $parsedData{$driver}->{$time};
	}

	print STDERR localtime() . " Driver: $driver\n" if $debug;

	for my $follower (@dataFiles) {

		my @followerXValues = ();
		my @followerYValues = ();

		print STDERR localtime() . " Follower: $follower\n" if $debug;

		# XXX - how to deal with undefs?
		for my $time (sort { $a <=> $b } keys %{$parsedData{$follower}}) {
			next unless $time =~ /^\d+$/;
			push @followerXValues, $time;
			push @followerYValues, $parsedData{$follower}->{$time};
		}

		for my $x (@driverXValues) {

			# silence undefs
			$^W = 0;

			my ($interpolatedY, $ySlope) = linear_interpolate($x, \@followerXValues, \@followerYValues);

			$interpolatedValues{$x} += $interpolatedY;
		}
	}

	print STDERR localtime() . " Sorting keys for interpolated values.\n" if $debug;

	for my $x (sort { $a <=> $b } keys %interpolatedValues) {

		print $outFH "$x $interpolatedValues{$x}\n";
	}

	return ($realStart[0], $realEnd[0]);
}

1;

__END__
