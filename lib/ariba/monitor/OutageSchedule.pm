package ariba::monitor::OutageSchedule;

use strict;

use POSIX;

=pod

=head1 NAME

ariba::monitor::OutageSchedule - Methods for flagging scheduled outages

=head1 VERSION

$Id: //ariba/services/monitor/lib/ariba/monitor/OutageSchedule.pm#2 $

=head1 SYNOPSIS

  use ariba::monitor::OutageSchedule;

  @timeRangeStrings = (
    'mon 12:00-15:00', 
    'sat 19:00-23:59', 
    'sun 00:00-00:30', 
    'daily 03:00-03:15',
	'1 00:00-04:00'
  );

  $sched = ariba::monitor::OutageSchedule->new(@timeRangeStrings);

  # return time range string of current outage, or undef:
  $currentlyInOutage = $sched->isInScheduledOutage();

=head1 DESCRIPTION

OutageSchedule is initialized with an array of time range strings.
It may then determine if the current time falls inside any of those
ranges.

=head1 TIME RANGE STRING FORMAT

TimeRangeStrings are of the format sun|mon|tue|wed|thu|fri|sat|daily HH:MM-HH:MM.
Times must not "wrap" past midnight, so a downtime from Friday at 11pm to Saturday morning
at 2am is two strings:

	fri 23:00-23:59
	sat 00:00-02:00

"Daily" is a special day name that matches any day. Day names are not case sensitive.

=head1 PUBLIC CLASS METHODS

=over 12

=item * new(@timeRangeStrings)

Instantiate the OutageSchedule class. Creates an accessor for the given array 
of time range strings, called timeRangeStrings().  Returns undef if any of the
@timeRangeStrings are invalid.

=head1 PRIVATE CLASS METHODS

=item * _parseTimeRangeString()

From a given time range string, return an array containing the lowercase day name abbreviation,
the start time, and the end time, with colons stripped from each time code. Returned array looks
like ('sat', '1900', '2359')

=item * _parseLocaltime()

Returns an array containing the lowercase current day name abbreviation, and time of day 
with colon stripped. Returned array looks like ('tue','2312')

=item * _isValidTimeRangeString()

Return 1 if the given time range string appears to be valid, undef if not.

=back

=head1 INSTANCE METHODS

=over 12

=item * timeRangeStrings()

Return array of timeRangeStrings

=item * isInScheduledOutage()

If the current time falls inside any of the values returned by timeRangeStrings(),
then return the timeRangeString of the current outage. Otherwise, return undef.

=head1 AUTHORS

  Alex Sandbak <asandbak@ariba.com>
  Dan Grillo <dan@ariba.com>

=back

=cut

sub new {
	my $class = shift;
	my @timeRangeStrings = @_;

	my $self = {
		'timeRangeStrings' => undef
	};

	my @validTimeRangeStrings;
	for my $string ( @timeRangeStrings ) {
		if (defined($class->_isValidTimeRangeString($string))) {
			push(@validTimeRangeStrings, $string);
		} else {
			# some of our input is bogus.   Make the caller deal.
			return undef;
		}
	}
	$self->{'timeRangeStrings'} = \@validTimeRangeStrings;

	bless($self, $class);

	return $self;
}

sub timeRangeStrings {
	my $self = shift;

	if ( defined($self->{'timeRangeStrings'} ) ) {
		return @{$self->{'timeRangeStrings'}};
	} else {
		return undef;
	}
}

sub isInScheduledOutage {
	my $self = shift;

	my $class = ref($self);
	my ($nowDayName, $nowTime, $nowDayOfMonth) = $class->_parseLocaltime();

	for my $timeRangeString ( $self->timeRangeStrings() ) {
		my ($outageDayName, $startTime, $endTime) = $class->_parseTimeRangeString($timeRangeString);

		if ( $outageDayName =~ /[a-z]/) { # original day of week style
			if (($nowDayName eq $outageDayName) || ($outageDayName eq 'daily')) {
				if (($nowTime >= $startTime) && ($nowTime <= $endTime)) {
					return $timeRangeString;
				}
			}
		} else { # we need to check based on date not day of week
			if ($nowDayOfMonth == $outageDayName) {
				if (($nowTime >= $startTime) && ($nowTime <= $endTime)) {
					return $timeRangeString;
				}
			}
		}
	}

	return undef;
}

sub _parseTimeRangeString {
	my $self = shift;
	my $timeRangeString = shift;

	my ($dayName, $times) = split(' ',$timeRangeString);

	$times =~ s/://g;

	my ($startTime, $endTime) = split('-',$times);

	return (lc($dayName), $startTime, $endTime);
}

sub _parseLocaltime {
	my $self = shift;

	my @now  = localtime();

	my $dayName = strftime("%a",@now);
	my $nowTime = strftime("%H%M",@now);
	my $nowDayOfMonth = $now[3];

	return (lc($dayName), $nowTime, $nowDayOfMonth);
}

sub _isValidTimeRangeString {
	my $self = shift;
	my $timeRangeString = shift;

	my ($dayName, $startTime, $endTime) = $self->_parseTimeRangeString($timeRangeString);

	if(($endTime > 2359) || ($startTime > $endTime)) {
		return undef;
	}

	if ($dayName =~ /[daily|sun|mon|tue|wed|thu|fri|sat]/) {
		return 1;
	} elsif (($dayName =~ /^\d+$/) && ($dayName > 0) && ($dayName < 32)) {
		return 1;
	} else {
		return undef;
	}
}

1;
