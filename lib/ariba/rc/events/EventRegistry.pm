package ariba::rc::events::EventRegistry;

#
# Class responsible for keeping track of RSS feed data:
#
# Name:           Arbitrary unique identifier
# Title:          Brief description of event
# File:           Name of file to write data to
# Description:    Verbose pretty-print nature/purpose of feed
# Class:          Name of class to generate data

use strict;
use warnings;
use Carp;
use Data::Dumper;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../lib/perl";
use lib "$FindBin::Bin/../../bin";
use ariba::rc::events::EventConfig;
use ariba::rc::events::EventChannel;
use ariba::rc::events::EventCategory;
use ariba::rc::events::Constants;
use ariba::rc::events::Generator::RSS;

{
    #
    # Constants
    #
	my $DEBUG = 1;
    my $CATEGORIES = 'categories';
    my $AGGREGATOR_TYPE = 'aggregators';
    my $REGISTRY_TYPE = 'registry';

    #
    # Map list of available types from Constants to internal types 
    #
    my %TYPES = 
    (
        ariba::rc::events::Constants::channel_type_aggregator() => $AGGREGATOR_TYPE,
        ariba::rc::events::Constants::channel_type_rss() => $REGISTRY_TYPE,
    );

    #
    # Constructor
    #
    sub new
    {
        my ($class, $config_file) = @_;

        # allow an alternate config file to be specified for testing
        $config_file = $config_file || $ENV{'RC_EVENT_REGISTRY'} || ariba::rc::events::Constants::config_file();

		# create hashref to hold class data 
        my $self = 
        {
            'config_manager' => new ariba::rc::events::EventConfig ($config_file),
        };

        # get listref of channels for events
        my ($event_channels, $event_categories) = $self->{'config_manager'}->parse_events();

		# loop over event categories
        if ($#$event_categories != -1)
        {
            foreach my $category (@$event_categories)
            {
				# convert hashref into EventCategory object
                my $event_category = new ariba::rc::events::EventCategory ($category);
                $self->{$CATEGORIES}->{$event_category->name()} = $event_category;
            }
        }

		# loop over event channels
        if ($#$event_channels != -1)
        {
            foreach my $channel (@$event_channels)
            {
                # check if channel is valid
                if (exists $TYPES{$channel->{'type'}})
                {
                    # convert hashref into EventChannel object
                    my $event_channel = new ariba::rc::events::EventChannel ($channel);
                    $self->{$TYPES{$channel->{'type'}}}->{$event_channel->{'name'}} = $event_channel;
                }
                else
                {
                    carp "Unknown channel type encountered in $config_file: " . $channel->{'type'} . "\n";
                }
            }
        }

        bless ($self, $class);
        return $self;
    }

    #
    # Fetch channel categories
    #
    sub get_categories
    {
        my ($self) = @_;
        return sort keys %{$self->{$CATEGORIES}};
    }

    #
    # Get an EventCategory object by name
    #
    sub get_category
    {
        my ($self, $category_name) = @_;
        return $self->{$CATEGORIES}->{$category_name};
    }

    #
    # Fetch EventConfig class
    #
    sub get_config_manager
    {
        my ($self) = @_;
        return $self->{'config_manager'};
    }
 
    #
    # Fetch EventChannel object by channel name
    #
    sub get_feed
    {
        my ($self, $channel_name, $event) = @_;

        # true if any aggregator channels have been defined
        my $has_aggregators = $self->{$AGGREGATOR_TYPE} ? 1 : 0;

        # can't find exact match: attempt to find matching aggregator
        # channel
        if ($has_aggregators && ! exists $self->{$REGISTRY_TYPE}->{$channel_name})
        {
            # iterate over available aggregator channels
            foreach my $aggregator (keys %{$self->{$AGGREGATOR_TYPE}})
            {
                # rule is a regular expression
                my $rule = $self->{$AGGREGATOR_TYPE}->{$aggregator}->rule();

                # if specified channel matches rule, transform it 
                if ($channel_name =~ m#^$rule$#)
                {
                    my $channel = $self->{$AGGREGATOR_TYPE}->{$aggregator};

					# allow client to optionally specify channel title
					my $channel_title = $channel_name;
					if ($event && $event->channel_name())
					{
						$channel_title = $event->channel_name();
					}

                    # transform EventChannel object using data from caller
                    $channel->name ($channel_name);
                    $channel->title ($channel_title);
                    $channel->description ("Events for $channel_name");
                    $channel->file ($channel_name . ".rss");
                    $channel->type (ariba::rc::events::Constants::channel_type_rss());
                    return $channel;
                }
            }

            # can't find channel: write to channel "unknown" as last ditch effort
            $channel_name = ariba::rc::events::Constants::channel_unknown();
        }

        return $self->{$REGISTRY_TYPE}->{$channel_name};
    }

    #
    # Get array of all EventChannel objects
    #
    sub get_feeds
    {
        my ($self) = @_;

        # make ordered list of channels
        my @feeds;
        foreach my $feed (@{$self->{'config_manager'}->get_order()})
        {
            push @feeds, $self->{$REGISTRY_TYPE}->{$feed};
        }

        # return array of EventChannel objects
        return @feeds;
    }

    #
    # Fetch registry entry by channel name
    #
    sub get_feeder
    {
        my ($self, $event, $channel_name) = @_;

        # get channel object by name
        my $channel = $self->get_feed ($channel_name, $event); 

		print STDERR "EventRegistry: get_feeder for $channel_name\n" if $DEBUG;
        # get named class
        my $classToLoad = $channel->class();

        # load named class
        eval "use $classToLoad;";

        # check for errors loading class
        if ($@) 
        {
            carp "Error loading $classToLoad for $self: $@\n";
            return 0;
        }
        
        # instantiate generator class
        my $feed = $classToLoad->new ($event, $channel);

        # check for class not found
        if (! $feed)
        {
            carp "Class $classToLoad not found for channel $channel_name\n";
            return 0;
        }

		print STDERR "EventRegistry: Successfully created $classToLoad\n" if $DEBUG;
        return $feed;
    }
}

1;
