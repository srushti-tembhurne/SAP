#!/usr/local/bin/perl -w
package ariba::monitor::Change;
#
# A class that represents a change history entry
# $Id: //ariba/services/monitor/lib/ariba/monitor/Change.pm#3 $
#

=pod

=head1 NAME

ariba::monitor::Change

=head1 SYNOPSIS

  # ProductionChange is a subclass of Change that provides the 'dir' for saving.
  my $change = ariba::monitor::ProductionChange->newWithHash(
  	time      => time(),
  	type      => "s2",
	subType   => "pfizer", 
  	oldValue  => "buildName-1",
  	newValue  => "buildName-2",
  );
  $change->save();

=head1 METHODS

=over 5

=cut

use strict;
use POSIX qw(strftime);

use ariba::Ops::PersistantObject;
use base qw(ariba::Ops::PersistantObject);

=item newWithHash()

Creates a new change object with attribs specified using a hash.
Valid hash attributes are: 

  time        The time of change. Defaults to current time.
  type        The type of change. Defaults to 'general'
  subType     The sub type of the change. Used for customer or category of type.
  oldValue    The old value of the change.
  newValue    The new value of the change.

=cut

sub newWithHash {
	my $class = shift;
	my %attribs = @_; 

	$attribs{'time'} = time() unless ($attribs{'time'});
	$attribs{'type'} = 'general' unless ($attribs{'type'});

	my $instanceName = $class->instanceNameForHash(%attribs);
	my $self = $class->SUPER::new($instanceName);
	bless($self, $class);

	$self->set(%attribs);

	return $self;
}

=item instanceNameForHash()

Generates an instance name based on the same hash as newWithHash

=cut

sub instanceNameForHash {
	my $class = shift;
	my %attribs = @_;
	my @nameParts;
	my $instanceName;

	my $time = $attribs{time} || time();
	my $date = strftime('%Y-%m-%d', localtime($time));
	my $type = $attribs{type} || 'general';
	my $subType = $attribs{subType};

	push(@nameParts, $type);
	push(@nameParts, $subType) if ($subType);
	push(@nameParts, strftime('%Y%m%d%H%M%S', localtime($time)));

	map { $_ =~ s/[^\w]//g } @nameParts;
	my $name = join('-', @nameParts);

	$instanceName = $type;
	$instanceName .= "-$subType" if ($subType);
	$instanceName .= "/$date";
	$instanceName .= "/$name";

	my $suffix = '';
	my $suffixNumber = 0;
	while ($class->objectWithNameExists("$instanceName$suffix")) {
		$suffixNumber++;
		$suffix = ".$suffixNumber";
	}
	$instanceName .= $suffix if ($suffix);
	
	return $instanceName;
}

=item set()

Sets a hash list of attribs.

=cut

sub set {
	my $self = shift;
	my %attribs = @_; 

	map { $self->setAttribute($_, $attribs{$_}) } keys(%attribs);
}

=item changesForTimeRange()

Returns a list of instances of Change objects for the specified time range.

=cut

sub changesForTimeRange {
	my $class = shift; 
	my $startTime = shift;
	my $endTime = shift || time();
	my @changes; 

	my $dir = $class->dir(); 
	return @changes unless ($dir && $startTime); 

	my %datesForTimeRange;
	# Root dir
	if (opendir(my $dh, $dir)) {
		my @types = grep(!/^\./, readdir($dh));
		closedir($dh);
		
		# Type-subType dir
		foreach my $type (@types) {
			if (opendir(my $dh, "$dir/$type")) {
				my @dates = grep(!/^\./, readdir($dh)); 
				closedir($dh); 
				
				# Date dir
				foreach my $date (@dates) {
					my $validDates = $class->dateHashForTimeRange($startTime, $endTime);
					next unless ($validDates->{$date});

					if (opendir(my $dh, "$dir/$type/$date")) {
						my @files = grep(!/^\./, readdir($dh));
						closedir($dh);
						
						# PO files
						foreach my $file (@files) {
							my $change = $class->new("$type/$date/$file");
							if ($change->time() && 
								$change->time() >= $startTime &&
								$change->time() < $endTime) {
								push(@changes, $change); 
							}
						}
					}
				}
			}
		}
	}

	return @changes;
}

sub lastChangeForType {
	my $class = shift;
	my $type = shift;
	my $subType = shift;

	my $dir = $class->dir(); 
	return undef unless ($dir && $type); 

	$type .= "-$subType" if ($subType);

	# Root/type dir
	if (opendir(my $dh, "$dir/$type")) {
		my @dates = grep(!/^\./, readdir($dh)); 
		closedir($dh); 
			
		# Date dir
		foreach my $date (sort { $b cmp $a } @dates) {
			if (opendir(my $dh, "$dir/$type/$date")) {
				my @files = grep(!/^\./, readdir($dh));
				closedir($dh);
				
				# PO files
				foreach my $file (sort { $b cmp $a } @files) {
					return $class->new("$type/$date/$file");
				}
			}
		}
	}

	return undef;
}
=item dateHashForTimeRange()

Utility function to return a list of dates for a given time range.

=cut

my %dateHashCache;
sub dateHashForTimeRange {
	my $class = shift; 
	my $startTime = shift;
	my $endTime = shift || time();

	$startTime = $class->minTime() if ($startTime < $class->minTime()); 
	$endTime = $class->maxTime() if ($endTime > $class->maxTime());

	my $cacheKey = "$startTime-$endTime";
	
	unless ($dateHashCache{$cacheKey}) {
		my %dates; 
		my $time = $startTime;

		while ($time < $endTime) {
			my $date = strftime('%Y-%m-%d', localtime($time));
			$dates{$date} = $time;
			$time += 86400;
		}

		$dateHashCache{$cacheKey} = \%dates;
	}

	return $dateHashCache{$cacheKey};
}

=item minTime()

A constant for the minimal time (start date) of a change object.
Basically ten years ago.

=cut

sub minTime {
	my $class = shift;

	return time() - 10 * 365 * 86400;	# 10 years
}

=item maxTime()

A constant for the maximum time (end date) of a change object.
Basically one year in the future.

=cut

sub maxTime {
	my $class = shift; 

	return time() + 365 * 86400;	# 1 year
}

return 1;
