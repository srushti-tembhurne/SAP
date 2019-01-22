package ariba::rc::events::EventFilter::StripPerlWarnings;

#
# Remove "Too late to run INIT blocK" and other unwanted warnings 
# from event description; Apply tt tag to event description if 
# not already there
#

use strict;
use warnings;
use vars qw ($AUTOLOAD);
use Carp;
use Data::Dumper;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../lib/perl";
use lib "$FindBin::Bin/../../bin";
use ariba::rc::events::AbstractEventFilter;
use base ("ariba::rc::events::AbstractEventFilter");
use ariba::rc::events::client::Event;

{
    # 
    # Constants
    #
    my @UNWANTED = 
    (
        "Too late to run INIT block at",
    );

    #
    # Constructor
    #
    sub new
    {
        my ($self, $event, $channel) = @_;
        return $self->SUPER::new ($event, $channel);
    }

    #
    # Remove unwanted warnings 
    #
    sub execute
    {
        my ($self, $event, $channel) = @_;

        my $description = $event->description();
        my @lines = split /\n/, $description;

        #
        # Form regular expression from list of unwanted strings
        #
        my $unwanted = join "|", @UNWANTED;
        my @cooked;
        
        # 
        # Check each line for unwanted strings
        #
        foreach my $line (@lines)
        {
            if ($line =~ m#($unwanted)#i)
            {
                next;
            }
            push @cooked, $line;
        }

        #
        # Generate final description
        #
        my $buf = join "\n", @cooked;

        #
        # Insert HTML break tag if necessary
        #
        if ($buf !~ m#<[^>]+>#gm)
        {
            $buf = join "<br>\n", @cooked;
        }
        $event->description ("<tt>" . $buf . "</tt>");
    }
}

1;
