package ariba::Automation::autolq::BuildChooserFactory;

#
# Abstract build chooser
#

use strict 'vars';
use warnings;
use vars qw ($AUTOLOAD);
use Carp qw (cluck);
use Data::Dumper;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../lib/perl";
use lib "$FindBin::Bin/../../bin";
use ariba::Automation::autolq::BuildChooser::LatestStable;
use ariba::Automation::autolq::BuildChooser::Latest;
{
	#
	# Constants
	#

	my $TYPE_LATEST_STABLE = "LATEST-STABLE";
    my $TYPE_LATEST = "LATEST";

	my %TYPES = 
	(
		$TYPE_LATEST_STABLE => "ariba::Automation::autolq::BuildChooser::LatestStable", 
		$TYPE_LATEST => "ariba::Automation::autolq::BuildChooser::Latest", 
	);

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

	#
	# Public interface
	#
	sub get_class
	{
		my ($self, $type) = @_;
		if (! exists $TYPES{$type})
		{
			cluck "Unknown build chooser class: $type";
			return 0;
		}
		my $classname = $TYPES{$type};
		my $chooser = new $classname;
		return $chooser;
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
        cluck "Unknown method: $accessor\n";
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
