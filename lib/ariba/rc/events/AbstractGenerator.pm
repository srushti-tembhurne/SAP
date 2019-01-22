package ariba::rc::events::AbstractGenerator;

#
# Interface for server-side events
#

use strict;
use warnings;
use vars qw ($AUTOLOAD);
use Carp;
use Data::Dumper;

{
    #
    # Constructor
    #
    sub new
    {
        my ($class, $event, $channel) = @_;
        my $self =
        {
            'event' => $event,
            'channel' => $channel,
            'dbh' => 0,
            'dbfile' => "", 
            'initialized' => 0,
        };
        bless ($self, $class);
        return $self;
    }
 
    #
    # Return a string for type, see ariba::rc::events::Constants
    # for a list of existing types.
    #
    sub type
    {
    }

    #
    # Publish the event to the channel provided to the constructor.
    #
    # Examples: Generator::RSS writes an RSS file to disk. 
    #           Generator::Email sends an e-mail message.
    #
    # Return true if an error occured.
    #
    sub publish
    {
    }

    #
    # Return unique ID generated for this event
    #
    sub get_event_id
    {
    }

    #
    # Show debugging information
    #
    sub dump
    {
    }

    #
    # Accessors
    #
    sub AUTOLOAD
    {
        no strict "refs";
        my ($self, $newval) = @_;

        my @classes = split /::/, $AUTOLOAD;
        my $accessor = $classes[$#classes];

        if (exists $self->{$accessor})
        {
            if (defined ($newval))
            {
                $self->{$accessor} = $newval;
            }
            return $self->{$accessor};
        }
        carp "Unknown method: $accessor\n";
    }

    #
    # Destructor
    #
    sub DESTROY
    {
        my ($self) = @_;
    }

}

1;
