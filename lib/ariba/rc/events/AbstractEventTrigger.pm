package ariba::rc::events::AbstractEventTrigger;

#
# Interface for event trigger classes
#

use strict 'vars';
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

        $hashref = {} unless $hashref;
        $hashref->{'verbose'} = $hashref->{'verbose'} || 0;
        $hashref->{'debug'} = $hashref->{'debug'} || 0;

        my $self = 
        {
            'verbose' => $hashref->{'verbose'},
            'debug' => $hashref->{'debug'},
        };
        bless ($self,$class);
        return $self;
    }

    #
    # Override me
    #
    sub execute
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
