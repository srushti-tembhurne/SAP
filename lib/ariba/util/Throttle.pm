#!/usr/local/bin/perl -w

#
# ariba::util::Throttle;
#
# provides a callback function to throttle CPU usage
# to a specified percent.  The math is theoretically
# sound, but actual CPU use will vary based on overhead,
# and the frequency (regularity) your loops call the
# sleep() method.
#

use strict;

use POSIX;

package ariba::util::Throttle;

sub new {
	my $class = shift;
	my $pct = shift || 20;


	my $self = {};

	bless ( $self, $class );

	$self->setPercent($pct);

	$self->{'timeval'} = (POSIX::times())[0];

	return($self);
}

sub reset {
	my $self = shift;
	$self->{'timeval'} = (POSIX::times())[0];
}

sub setPercent {
	my $self = shift;
	my $pct = shift || 20;

	$self->{'cap'} = 1 - ($pct / 100);
	$self->{'multiplier'} = ( (100 / $pct) - 1 ) / 100;
	$self->{'percent'} = $pct;
}

sub percent {
	my $self = shift;
	return ( $self->{'percent'} );
}

sub sleep {
	my $self = shift;

	my $last = $self->{'timeval'};
	my $now  = (POSIX::times())[0];
	my $diff = $now - $last;

	# lots of really small sleep states don't help
	# so we have this defense against loops calling sleep too much.
	if($diff < 7) {
		return;
	}

	my $sleep = $diff * $self->{'multiplier'};

	#
	# this means we don't promise a rate, but it's a defense against
	# loops that don't call sleep enough.
	#
	if($sleep > $self->{'cap'}) {
		$sleep = $self->{'cap'};
	}

	select(undef, undef, undef, $sleep);

	$self->{'timeval'} = (POSIX::times())[0];
}

1;
