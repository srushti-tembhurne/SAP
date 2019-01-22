package ariba::rc::events::Generator;

#
# Base class for event generators.
#

use strict;
use warnings;
use vars qw ($AUTOLOAD);
use Carp;
use Data::Dumper;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../lib/perl";
use lib "$FindBin::Bin/../../bin";
use ariba::rc::events::AbstractGenerator;
use base ("ariba::rc::events::AbstractGenerator");

{
    #
    # Constructor
    #
    sub new
    {
        my ($self, $event, $channel) = @_;
        return $self->SUPER::new ($event, $channel);
    }

    # 
    # Extract a list of classes from events.xml
    #
    sub extract_class_list
    {
        my ($self, $field) = @_;
        my @raw = split /,/, $field;
        my @cooked;
        foreach my $class (@raw)
        {
            $class =~ s/^\s+//;
            $class =~ s/\s+$//;
            next unless length ($class);
            push @cooked, $class;
        }
        return @cooked;
    }

    #
    # Parent method for publishing events
    #
    sub publish
    {
        my ($self) = @_;
        my $event = $self->{'event'};
        my $channel = $self->{'channel'};

        #
        # Support for event filters
        #
        if ($channel->filter())
        {
            my @filters = $self->extract_class_list ($channel->filter());
            foreach my $filter (@filters)
            {
                $self->execute_handler ($event, $channel, $filter);
            }
        }

        #
        # Publish event
        #
        my $err = $self->publish_event();

        # 
        # Support for multiple triggers per channel
        #
        if (! $event->republished() && $channel->trigger())
        {
            my @triggers = $self->extract_class_list ($channel->trigger());
            foreach my $trigger (@triggers)
            {
                $self->execute_handler ($event, $channel, $trigger);
            }
        }
        
        return $err;
    }

    #
    # Call named class' execute() method against supplied event + channel
    #
    sub execute_handler
    {
        my ($self, $event, $channel, $classToLoad) = @_;

        # load named class
        eval "use $classToLoad;";

        # check for errors loading class
        if ($@)
        {
            carp "Error loading $classToLoad for $self: $@\n";
            return 0;
        }

        # instantiate generator class
        my $class = $classToLoad->new ($event, $channel);

        # check for class not found
        if (! $class)
        {
            carp "Class $classToLoad not found for channel " . $channel->name() . "\n";
            return 0;
        }

        my $res;
        
        eval
        {
            $res = $class->execute ($event, $channel);
        };

        if ($@)
        {
            carp ref ($self) . " Failure executing $classToLoad: $@\n";
        }

        return $res;
    }
}

1;
