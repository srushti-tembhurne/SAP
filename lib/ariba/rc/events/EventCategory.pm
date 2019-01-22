package ariba::rc::events::EventCategory;

#
# Class represents event category data
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
        my ($class, $hashref) = @_;
        my $self = $hashref ? $hashref : {};
        bless ($self, $class);
        return $self;
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
