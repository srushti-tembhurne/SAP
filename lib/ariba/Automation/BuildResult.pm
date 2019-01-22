package ariba::Automation::BuildResult;

#
# Encapsulated info about a build failure
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
        my $self = {};
        bless ($self,$class);
		if ($hashref)
		{
			foreach my $key (keys %$hashref)
			{
				$self->{$key} = $hashref->{$key};
			}
		}
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

	sub dump
	{
		my ($self) = @_;
		print $self->{'product'} . ": " . $self->{'robot'} . " => " . $self->{'reason'} . "\n";
		if ($self->{'failures'})
		{
			print Dumper ($self->{'failures'});
		}
	}
}

1;
