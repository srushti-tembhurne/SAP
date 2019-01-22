#!/usr/local/bin/perl

use strict;

package ariba::monitor::TicketThrottler;

use base qw(ariba::Ops::PersistantObject);

sub new {
	my $class = shift;
	my $self = $class->SUPER::new("throttler");

	$self->setThrottleTMID(undef);
	$self->setLastThrottleTime(0);
	$self->setExpireTime(30*60); # default to 15 minutes
	$self->setThrottleThreshold(5); # 5 tickets over 15 minutes throttles
    $self->setTicketArray([]);

	return $self;
}

sub addTicket {
	my $self = shift;

	my @array = $self->ticketArray();

	push(@array, time());

    $self->setTicketArray(@array);

	unless($self->throttleTMID()) {
		if(scalar(@array) > $self->throttleThreshold()) {
			$self->openThrottleTicket();
		}
	}
}

sub expireTickets {
	my $self = shift;
	my @array = $self->ticketArray();

    my $expireTime = time() - $self->expireTime();
    @array = grep { $_ > $expireTime; } @array;

    $self->setTicketArray(@array);

	# do we expire the throttle ticket?
	if($self->throttleTMID() &&
		scalar(@array) < $self->throttleThreshold() &&
		$self->lastThrottleTime() < time() - ($self->throttleThreshold()*2)) {
			#
			# first update the ticket
			#
			my $subject = "Throttling ended at " . scalar(localtime()) . "(TMID:" . $self->throttleTMID() . ")";
			my $body = "\nThrottled tickets ended at " . scalar(localtime()) . "\n";

			#
			# unset our internal TMID
			#
			$self->setThrottleTMID(undef);
	}
}

sub openThrottleTicket {
	my $self = shift;

	my $subject = sprintf("Opening of new tickets throttled [%s]", scalar(localtime));
	my $note = sprintf("\nThe opening of new tickets has been throttled because more than %d tickets have\nbeen opened in the last %d minutes\n\n", $self->throttleThreshold(), int($self->expireTime()/60));
	$note .= "Information for tickets not opened due to the throttling will be tracked as notes\nadded to this ticket.";

	$self->setThrottleTMID(1);
	$self->setLastThrottleTime(time());
}

sub save { return undef; }
sub recursiveSave { return undef; }
sub dir { return("/dev/null"); }
sub remove { return undef; }

1;
