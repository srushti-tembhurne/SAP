package ariba::rc::events::EventConfig;

#
# Transform /home/rc/etc/events.xml into tree to be 
# consumed by EventRegistry
#

use strict;
use warnings;
use Carp;
use Data::Dumper;
use Sort::Versions;
use XML::Simple;

{
    # 
    # Constants
    #
    my $DEFAULT_ORDER = 100;

    #
    # Constructor
    #
    sub new
    {
        my ($class, $config_file) = @_;

        my $self = 
        {
            'config_file' => $config_file,
            'order' => [],
            'channels' => {},
        };

        bless ($self, $class);
        return $self;
    }

    #
    # Get channels in the order defined in events.xml
    #
    sub get_order
    {
        my ($self) = @_;
        return $self->{'order'};
    }

    #
    # Return true if channel is an aggregator channel, 
    # specified like so: robot*
    #
    sub is_aggregator
    {
        my ($self, $channel_name) = @_;
        return substr ($channel_name, -1, 1) eq '*' ? 1 : 0;
    }

    #
    # Return true if channel exists
    #
    sub has_channel
    {
        my ($self, $channel_name) = @_;
        return exists $self->{'channels'}->{$channel_name} ? 1 : 0;
    }

    #
    # Return data structure representing events.xml
    #
    sub parse_events
    {
        my ($self) = @_;

        my $channels = [];
        my $categories = [];

        eval 
        { 
            ($channels, $categories) = $self->_parse_events(); 
        };

        if ($@)
        {
            carp "FATAL: Failed parsing events file via " . $self->{'config_file'} . ": $@\n";
        }

        return ($channels, $categories);
    }

    sub _parse_events
    {
        my ($self) = @_;

        my $xs = new XML::Simple();
        my $tree = $xs->XMLin ($self->{'config_file'});
        my @listref;
        my @categories;
        my %order;

        foreach my $tag (keys %$tree)
        {
            # 
            # Parse channel categories
            #
            if ($tag eq "category")
            {
                foreach my $key (keys %{$tree->{$tag}})
                {
                    my $hashref = 
                    {
                        name => $key,
                    };
                    foreach my $category_value (keys %{$tree->{$tag}->{$key}})
                    {
                        $hashref->{$category_value} = $tree->{$tag}->{$key}->{$category_value};
                    }
                    push @categories, $hashref;
                }
                next;
            }
            
            #
            # Parse channels
            #
            foreach my $channel (keys %{$tree->{$tag}})
            {
                # allow for ordered channels: lower numbers come first
                my $order = $tree->{$tag}->{$channel}->{'order'} || $DEFAULT_ORDER;

                # keep channels by order
                push @{$order{$order}}, $channel unless $self->is_aggregator ($channel);

                # all channels have a name
                my $hashref = 
                {
                    'name' => $channel, 
                };

                # blast data found in <channel> tag into dictionary
                foreach my $key (keys %{$tree->{$tag}->{$channel}})
                {
                    $hashref->{$key} = $tree->{$tag}->{$channel}->{$key};
                }

                $self->{'channels'}->{$channel} = 1;
                push @listref, $hashref;
            }
        }

        # 
        # Maintain pleasant order of channels for display purposes
        #
        my @order;
        my @sorted = sort { versioncmp($a, $b) } keys %order;
        foreach my $s (@sorted)
        {
            push @order, @{$order{$s}};
        }
        $self->{'order'} = \@order;
        
        #
        # Return array containing hashrefs of channel information
        # suitable for creating EventChannel classes
        #
        return (\@listref, \@categories);
    }
}

1;
