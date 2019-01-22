package ariba::rc::events::EventChannel;

#
# Class represents event channel data
#

use strict;
use warnings;
use vars qw ($AUTOLOAD);
use Carp;
use Data::Dumper;

{
    #
    # Constants
    #
    my %DEFAULTS = 
    (
        'trigger' => "",
        'filter' => "",
        'title' => "",
        'description' => "",

        # Probably specific to RSS
        'limit' => 0,

        # Specific to RSS
        'uri' => "",
        'file' => "",
        'dir' => "", 

        # Specific to E-mail
        'from' => "", 
		'subscription' => 1, 
    );

    #
    # Constructor
    #
    sub new
    {
        my ($class, $hashref) = @_;
        my $self = $hashref ? $hashref : {};

        # apply default values
        foreach my $key (keys %DEFAULTS)
        {
            if (! exists $self->{$key})
            {
                $self->{$key} = $DEFAULTS{$key};
            }
        }
        bless ($self, $class);
        return $self;
    }

	#
	# True if one can subscribe to this channel
	#
	sub can_subscribe
	{
		my ($self) = @_;
		return $self->{'subscription'};
	}

    #
    # Debugging
    #
    sub dump
    {
        return Dumper ($_[0]);
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
