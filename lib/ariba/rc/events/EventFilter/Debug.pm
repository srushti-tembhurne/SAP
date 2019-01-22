package ariba::rc::events::EventFilter::Debug;

#
# Event Debug Filter
#

use strict;
use warnings;
use vars qw ($AUTOLOAD);
use Carp;
use Data::Dumper;
use File::Copy;
use XML::RSS;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../lib/perl";
use lib "$FindBin::Bin/../../bin";
use ariba::rc::events::AbstractEventFilter;
use base ("ariba::rc::events::AbstractEventFilter");
use ariba::rc::events::Constants;
use ariba::rc::events::client::Event;
use ariba::rc::events::EventChannel;

{
    #
    # Constructor
    #
    sub new
    {
        my ($self, $event, $channel) = @_;
        return $self->SUPER::new ($event, $channel);
    }

    #
    # 
    #
    sub execute
    {
        my ($self, $event, $channel) = @_;

        my $description = $event->description();

        $description .= <<FIN;
<p>
Debug:
</p>
<style>
b.key { color: #0000FF; }
</style>
FIN

        $description .= "RC Event Version: " . ariba::rc::events::Constants::version() . "<br>";
        $description .= "<p><tt><pre>" . $event->dump() . "</pre></tt></p>";
        $description .= "<p><tt><pre>" . $channel->dump() . "</pre></tt></p>";

        foreach my $key (sort keys %ENV)
        {
            $description .= <<FIN;
<b class="key">$key:</b> $ENV{$key}<br>
FIN
        }

        $event->description ($description);
    }
}

1;
