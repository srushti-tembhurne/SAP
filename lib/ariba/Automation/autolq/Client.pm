package ariba::Automation::autolq::Client;

#
# Auto LQ Client - talks to Daemon.pm
#

use strict;
use warnings;
use vars qw ($AUTOLOAD);
use Carp;
use Data::Dumper;
use LWP::Simple;
use ariba::Automation::autolq::Errors;

{
    #
    # Constants
    #

    my $URL = "http://rc.ariba.com:46601";

    #
    # Constructor
    #
    sub new
    {
        my ($class, $file) = @_;
        my $self = {};
        bless ($self,$class);
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

    #
    # Tell the autolqd to start deployment + run LQ
    #
    # Returns one of two results:
    #
    # ok = went better than expected
    # unknown_error = server gave unexpected (empty) response
    #
    sub start_lq
    {
        my ($self, $deployment, $user) = @_;

        #
        # Form URL into autolqd
        #
        my $url = $URL . "/qual/start?deployment=$deployment&user=$user";

        #
        # Fetch web page
        #
        my $buf = get ($url);

        #
        # Deal with empty responses to avoid undefined variable complaints
        #
        $buf = defined ($buf) ? $buf : "";

        #
        # Check for failure
        #
        if (! defined ($buf) || ! length ($buf))
        {
            $buf = ariba::Automation::autolq::Errors::unknown_error();
        }

        #
        # Remove stray end-of-line characters
        #
        chomp $buf;

        #
        # Interpret result + return to caller
        #
        if ($buf eq ariba::Automation::autolq::Errors::ok())
        {
            return 0;
        }
        return $buf;
    }
}

1;
