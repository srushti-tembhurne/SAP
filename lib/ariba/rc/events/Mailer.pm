package ariba::rc::events::Mailer;

#
# Sends e-mail given an event+channel
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
use ariba::rc::events::DB;
use ariba::rc::events::Constants;

{
    #
    # Constructor
    #
    sub new
    {
        my ($class) = @_;
        my $self = 
        {    
            'verbose' => 0, 
            'last_error' => "",
        };
        bless ($self, $class);
        return $self;
    }

    sub set_verbose 
    {
        my ($self, $value) = @_;
        $value = $value || 0;
        $self->{'verbose'} = $value;
    }

    sub get_last_error
    {
        my ($self) = @_;
        return $self->{'last_error'};
    }

    #
    # Send e-mail
    #
    sub send
    {
        my ($self, $to, $event, $channel, $unsubscribe_key) = @_;
        $unsubscribe_key = $unsubscribe_key || "";

        #
        # Make new DB class to get/put events from/to datastore
        #
        my $db = new ariba::rc::events::DB();

        #
        # Generate unique link to event viewer for this event
        #
        my $event_link = ariba::rc::events::Constants::view_event_url ($event->id, $channel->name);

        #
        # Default to From: line available in Constants if not supplied by events.xml
        #
        my $from = ariba::rc::events::Constants::email_from();

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

        #
        # Generate unsubscribe link if desired
        #
        my $unsubscribe_link = "";
        if ($unsubscribe_key)
        {
            my $link = ariba::rc::events::Constants::unsubscribe_url ($channel->name, $to, $unsubscribe_key);
            $unsubscribe_link = <<FIN;
<br>
To unsubscribe from this mailing, <a href="$link">click here</a>. 
FIN
        }

        #
        # Message footer
        #
        my $channelName = $channel->name();
        $description .= <<FIN;
<p>
<font size="-1" color="#909090">
This is an automated message to event channel $channelName.<br>
Contact <a href="mailto:$owner">$owner</a> for any questions concerning this message.
$unsubscribe_link
</font>
</p>
FIN

        #
        # Generate text/html message
        #
        my $msg = MIME::Lite->new
        (
            'From'               => $from,
            'To'                 => $to,
            'Subject'            => $event->title(),
            'Type'               => $content_type,
            'Data'               => $description,
            'X-Event-Channel'    => $channel->name(), 
            'X-Event-ID'         => $event->id(),
            'X-Mailer'           => $className . "/" . $version,
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
            $self->{'last_error'} = $@;
            if ($self->{'verbose'})
            {
                carp "Couldn't send e-mail to $to Re: \"" . $event->title() . "\", $@\n";
            }
            return 1;
        }

        return 0;
    }
}

1;
