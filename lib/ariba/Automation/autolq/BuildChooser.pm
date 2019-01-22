package ariba::Automation::autolq::BuildChooser;

#
# Abstract build chooser
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
        my ($class) = @_;
        my $self = 
        {
        };
        bless ($self, $class);
        return $self;
    }

	sub get_label
	{
		croak "This is an abstract class - you must call an implementation in a subclass";
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
        croak "Unknown method: $accessor\n";
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
