#
# $Id: //ariba/services/tools/lib/perl/ariba/util/Cronjob.pm#8 $
#
# A module to manage cronjob's properties
#
package ariba::util::Cronjob;

use strict;

sub new
{
	my ($class) = @_;

	my $self = {};

	$self->{'minute'} = -1 ;
	$self->{'hour'} = -1 ;
	$self->{'day'} = -1 ;
	$self->{'month'} = -1 ;
	$self->{'weekday'} = -1 ;
	$self->{'command'} = "" ;
	$self->{'comment'} = "" ;

	bless ($self,$class);

	return $self;
}

sub command
{
	my ($self) = shift;

	return $self->{'command'};
}

sub comment
{
	my ($self) = shift;

	return $self->{'comment'};
}

sub name
{
	my ($self) = shift;

	return $self->{'name'};
}

sub schedule
{
	my ($self) = shift;

	my @sched;

	push(@sched, $self->{'minute'});
	push(@sched, $self->{'hour'});
	push(@sched, $self->{'day'});
	push(@sched, $self->{'month'});
	push(@sched, $self->{'weekday'});

	return \@sched;
}


sub setCommand
{
	my ($self, $command) = @_;

	$self->{'command'} = $command;
}

sub setComment
{
	my ($self, $comment) = @_;

	$self->{'comment'} = $comment;
}

sub setName
{
	my ($self, $name) = @_;

	$self->{'name'} = $name;
}

sub setSchedule
{
	my ($self, $schedule) = @_;
	my @sched = @$schedule;

	my @scheduleFields = ('minute', 'hour', 'day', 'month', 'weekday');

	for (my $i = 0; $i <= $#sched; $i++) {

		if ($sched[$i] =~ m|\*/| or $sched[$i] =~ m|-|) {
			$sched[$i] = _convertTimeSlot($sched[$i], $scheduleFields[$i]);
		}
	}

	if ($schedule->[0] =~ /^#/ && $sched[0] !~ /^#/) {
		$sched[0] = "#" . $sched[0];
	}

	for (my $i = 0 ; $i < scalar(@scheduleFields); $i++) {
		$self->{$scheduleFields[$i]} = $sched[$i];
	}
}

sub _convertTimeSlot {
	my $timeSlot = shift;
	my $timeSlotType = shift;

	my %maxUnitsForType = (
						'minute' => 60,
						'hour' => 24,
						'day' => 30, #XXXX What do we do about feb and months with 31 days
						'month' => 12,
						'weekday' => 7,
					);


	my $maxUnits = $maxUnitsForType{$timeSlotType};
	my @newRange = ();

	if ($timeSlot =~ m|\*/|) {
		my $frequency = (split(/\//, $timeSlot))[1];

		srand();
		my $startTime = sprintf("%d",rand(0 + ($frequency - 1)));

		for (my $i = $startTime; $i < $maxUnits; $i += $frequency) {
			push @newRange, $i;
		}

	} elsif ($timeSlot =~ m|-|) {
		my @timeRange = split(/-/, $timeSlot);
		
		for (my $i = $timeRange[0]; $i <= $timeRange[1]; $i++) {
			push @newRange, $i;
		}

	} else {
		die "Couldn't do crontab time conversion on: [$timeSlot]!";
	}

	return join(',', @newRange);
}

1;
