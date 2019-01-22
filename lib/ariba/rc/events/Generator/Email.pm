package ariba::rc::events::Generator::Email;

#
# Sample Code for creating an Event Generator class
# that sends e-mail...
#

use strict;
use warnings;
use vars qw ($AUTOLOAD);
use Carp;
use Data::Dumper;
use MIME::Lite;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../lib/perl";
use lib "$FindBin::Bin/../../bin";
use ariba::rc::events::Generator;
use base ("ariba::rc::events::Generator");
use ariba::rc::events::DB;
use ariba::rc::Utils;
use ariba::rc::events::Constants;
use dmail::LockLib;

{
    my $EVENT_TYPE = ariba::rc::events::Constants::channel_type_email();

    #
    # Constructor
    #
    sub new
    {
        my ($self, $event, $channel) = @_;
        return $self->SUPER::new ($event, $channel);
    }

    #
    # Get event type
    #
    sub type
    {
        return $EVENT_TYPE;
    }

    #
    # Send e-mail
    #
    sub publish_event
    {
        my ($self) = @_;

        my $channel = $self->{'channel'};
        my $event = $self->{'event'};

        #
        # Make new DB class to get/put events from/to datastore
        #
        my $db = new ariba::rc::events::DB();

        #
        # Insert event into database, returns unique id number
        #
        my $id = $db->insert ($event, $channel);

        #
        # Generate unique link to event viewer for this event
        #
        my $event_link = ariba::rc::events::Constants::view_event_url ($id, $channel->name);

        #
        # Default to From: line available in Constants if not supplied by events.xml
        #
        my $from = $channel->from() || ariba::rc::events::Constants::email_from();

        #
        # Default owner to from line if not supplied by events.xml
        #
        my $owner = $channel->owner() || $from;
        
        #
        # Default Content-type: field available from Constants if not supplied by events.xml
        #
        my $content_type = ariba::rc::events::Constants::email_content_type();

        #
        # Append notice to message body
        #
        my $version = ariba::rc::events::Constants::version();
        my $className = ref ($self);
        my $description = $event->description();
        $description .= <<FIN;
<p>
<font size="-1" color="#909090">
This is an automated message from $className version $version.<br>
Contact <a href="mailto:$owner">$owner</a> for any questions concerning this message.
</font>
</p>
FIN

        #
        # Generate text/html message
        #
        my $msg = MIME::Lite->new
        (
            'From'     => $from,
            'To'       => $channel->name(),
            'Subject'  => $event->title(),
            'Type'     => $content_type,
            'Data'     => $description,
       );

        #
        # Send message
        #
        eval 
        { 
            $msg->send() 
        };

        if ($@) 
        {
            carp "Couldn't send e-mail to $channel Re: \"" . $event->title() . "\", $@\n";
            return 1;
        }

        return 0;
    }
}

1;
