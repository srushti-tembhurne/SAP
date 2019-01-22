package ariba::rc::events::EventPublisher;

#
# Given an event, import the named class and call publish()
#

use strict;
use warnings;
use Carp;
use Data::Dumper;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../lib/perl";
use lib "$FindBin::Bin/../../bin";
use ariba::rc::events::Constants;
use ariba::rc::events::client::Event;
use ariba::rc::events::EventRegistry;

{
	#
	# Constants
	#
	my $DEBUG = 1;

    #
    # Constructor
    #
    sub new
    {
        my ($class) = @_;
        my $self = 
        {
            'published' => "",
        };
        bless ($self, $class);
        return $self;
    }
 
    sub get_published_channels
    {
        my ($self) = @_;
        return $self->{'published'};
    }

    #
    # Get list of channels to publish to; Automatically add "all" channel
    # unless we are republishing an event.
    #
    sub _get_channels
    {
        my ($self, $event) = @_;
        my $channels = $event->channel();
        $channels =~ s/[\+,;]/ /gm;
        my @channels;
        # push @channels, ariba::rc::events::Constants::channel_all() unless $event->republished(); # TODO: Uncomment
        push @channels, split /\s+/, $channels;
        return @channels;
    }

    #
    # Publish event via class publish() method
    #
    sub publish
    {
        my ($self, $dirtyEvent) = @_;

		print STDERR "EventPublisher: Creating event from dirty object\n" if $DEBUG;
        my $event = ariba::rc::events::client::Event->newFromDirtyObject ($dirtyEvent);

        if (! $event->is_valid())
        {
            carp "Publish failed: Event missing required attributes\n";
            return 1;
        }

        #
        # Make new registry
        #
		print STDERR "EventPublisher: Creating new event registry\n" if $DEBUG;
        my $registry = new ariba::rc::events::EventRegistry();

        # 
        # Count number of failed deliveries: one event can be sent to 
        # multiple channels
        #
        my $fail = 0;

        #
        # Avoid duplicates: Keep hash of channels written to
        #
        my %seen;

        #
        # Support for writing event to multiple channels
        #
        my @channels = $self->_get_channels ($event);
        my @published;

        #
        # Send one event to many channels
        #
		print STDERR "EventPublisher: Publishing to " . ($#channels+1) . " channel(s)\n" if $DEBUG;

        foreach my $channel_name (@channels)
        {
            # don't send dupes
            next if $seen{$channel_name};
            $seen{$channel_name} = 1;
            
            # track recently-published channels
            push @published, $channel_name;

            # fetch named class from registry by event/channel name
			print STDERR "EventPublisher: Fetching feeder for $channel_name\n" if $DEBUG;
            my $feeder = $registry->get_feeder ($event, $channel_name);

            # fail on unknown channel
            if (! $feeder)
            {
                carp "Channel not found: $channel_name\n";
                $fail++;
                next;
            }

			print STDERR "EventPublisher: Publishing \"" . $event->title() . "\" to $channel_name\n" if $DEBUG;
            # publish returns true if an error occured
            my $err = $feeder->publish();

            # complain, tally up failures
            if ($err)
            {
                carp "Couldn't publish event for channel $channel_name\n";
                $fail++;
            }
        }

        $self->{'published'} = \@published;

		print STDERR "EventPublisher: Finished publishing\n" if $DEBUG;
        # if even one publish failed, return an error
        return $fail;
    }
}

1;
