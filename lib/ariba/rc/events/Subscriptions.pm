package ariba::rc::events::Subscriptions;

#
# E-mail management: Facade in front of DB::Email to hide database 
# operations from caller + combine multiple steps
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
use ariba::rc::events::Constants;
use ariba::rc::events::client::Event;
use ariba::rc::events::EventChannel;
use ariba::rc::events::DB::Email;
use ariba::rc::events::Mailer;
use ariba::rc::events::Unsubscribe;
use ariba::rc::events::Schedule;

{
    #
    # Constants
    #
    use constant CHANNEL_NAME => 'subscriptions';
    use constant MAIL_FAILURE => 0;
    use constant MAIL_SUCCESS => 1;
    use constant CUTOFF_TIME => 60 * 60 * 8; # eight hours specified in seconds

    #
    # List of methods we hand-off to DB::Email; avoids having to write
    # stubs for each one we want
    #
    my %PASSTHRU = 
    (
        'get_all_subscriptions' => 1,
		'queue_event' => 1, 
		'has_subscription' => 1, 
		'get_delivery_log' => 1, 
		'update_schedule' => 1,
		'get_schedule' => 1,
		'get_queue_size' => 1, 
		'expire_db' => 1,
    );

    #
    # Constructor
    #
    sub new
    {
        my ($class) = @_;
        my $self = 
        {    
            'verbose' => 0, 
            'db_email' => new ariba::rc::events::DB::Email (),
            'last_error' => "",
            'cutoff' => CUTOFF_TIME,
            'channel_name' => CHANNEL_NAME,
        };
        bless ($self, $class);
        return $self;
    }

    #
    # Return last error that occured. Origin is usually 
    # ariba::rc::events::Mailer 
    #
    sub get_last_error
    {
        my ($self) = @_;
        return $self->{'last_error'};
    }

    #
    # Set to true for verbose debug output
    #
    sub set_verbose 
    {
        my ($self, $value) = @_;
        $value = $value || 0;
        $self->{'verbose'} = $value;
    }

    #
    # Subscribe an e-mail address to a channel
    #
    sub subscribe
    {
        my ($self, $channel, $email, $remote_addr) = @_;
        my $subscription_id = $self->{'db_email'}->subscribe ($channel, $email, $remote_addr) || "";
        if ($subscription_id)
        {
            $self->send_subscribe_event ($channel, $email, $remote_addr, $subscription_id);
            return $subscription_id;
        }
        return 0;
    }

    #
    # Unsubscribe an e-mail address from a channel
    #
    sub unsubscribe
    {
        my ($self, $channel, $email, $remote_addr) = @_;
        $self->{'db_email'}->unsubscribe ($channel, $email);
        $self->send_unsubscribe_event ($channel, $email, $remote_addr);
    }

    # 
    # Send an e-mail message
    #
    sub deliver_email
    {
        my ($self, $subscription_id, $queue_id, $email, $event, $channel) = @_;

        my $schedule = $self->get_schedule ($email);
        if (! ariba::rc::events::Schedule::can_email_now ($schedule))
		{
            $self->{'db_email'}->log_delivery ($queue_id, MAIL_FAILURE, "not in schedule");
            $self->{'db_email'}->mark_as_delivered ($queue_id, $subscription_id, $event);
			return 0;
		}

        #
        # Don't send e-mail if it is a dupe
        #
        if ($self->{'db_email'}->is_duplicate_email ($queue_id, $event))
        {
            $self->{'db_email'}->mark_as_delivered ($queue_id, $subscription_id, $event);
            $self->{'db_email'}->log_delivery ($queue_id, MAIL_FAILURE, "duplicate");
            carp "Not sending duplicate e-mail for $subscription_id" if $self->{'verbose'};
            return 1;
        }
    
        my $mailer = new ariba::rc::events::Mailer();
        $mailer->set_verbose (1) if $self->{'verbose'};

        #
        # Generate unsubscribe key
        #
        my $unique_key = ariba::rc::events::Unsubscribe::make_key ($email, $channel->name());
        my $key = ariba::rc::events::Unsubscribe::generate ($unique_key, ariba::rc::events::Constants::salt());

        #
        # Attempt to send...
        #
        my $err = $mailer->send ($email, $event, $channel, $key);

        if (! $err)
        {
            #
            # Success: Message delivered
            #
            $self->{'db_email'}->mark_as_delivered ($queue_id, $subscription_id, $event);
            $self->{'db_email'}->log_delivery ($queue_id, MAIL_SUCCESS);
        }
        else
        {
            #
            # Fail: Message couldn't be delivered
            #
            $self->{'last_error'} = $mailer->get_last_error();
            $self->{'db_email'}->log_delivery ($queue_id, MAIL_FAILURE, $self->{'last_error'});
        }

        return $err;
    }

    #
    # Find queued subscriptions, send e-mail
    #
    sub send
    {
        my ($self, $registry, $nomail, $limit) = @_;

        # 
        # DEBUG: Set to true, method won't send e-mail
        #
        $nomail = $nomail || 0;

        #
        # DEBUG: Set to true, method won't send more than 1 e-mail
        #
        $limit = $limit || 0;

        my $db = new ariba::rc::events::DB();

        #
        # Get list of undelivered e-mail
        #
        my $undelivered = $self->{'db_email'}->get_undelivered ();
        my $now = time();
        my ($ok, $failed) = (0, 0);

        #
        # Send e-mails
        #
        foreach my $queued (@$undelivered)
        {
            my $event = $db->fetch ($queued->{'event_id'}) || "";
            next unless $event;

            my $channel = $registry->get_feed ($queued->{'channel'}) || "";
            next unless $channel;

            next if $nomail;
            
            #
            # Don't send if a cutoff time is defined and message was queued
            # more than n seconds ago
            #
            if ($self->{'cutoff'} && (($now - $queued->{'create_date'}) > $self->{'cutoff'}))
            {
                ++$failed;
                carp "Won't send e-mail: Message is too old" if $self->{'verbose'};
                $self->{'db_email'}->mark_as_delivered ($queued->{'queue_id'}, $queued->{'subscription_id'}, $event);
                $self->{'db_email'}->log_delivery ($queued->{'queue_id'}, MAIL_FAILURE, "Message too old");
                last if $limit;
                next;
            }

            #
            # Attempt delivery
            #
            my $err = $self->deliver_email 
            (
                $queued->{'subscription_id'}, 
                $queued->{'queue_id'}, 
                $queued->{'email'}, 
                $event, 
                $channel
            );

            if ($err)
            {
                ++$failed;
                carp "Couldn't send e-mail: " . $self->get_last_error() if $self->{'verbose'};
            }
            else
            {
                ++$ok;
                print "ok: #" . $queued->{'queue_id'} . " sent to " . $queued->{'email'} . "\n" if $self->{'verbose'};
            }
        
            last if $limit;
        }

        print "Success: $ok\nFailed: $failed\n" if $self->{'verbose'};
    }

    #
    # Notify subscription channel of changes
    #
    sub _generate_event_title
    {
        my ($self, $channel, $email, $verb) = @_;
		my $direction = $verb eq "subscribed" ? "to" : "from";
        return "$email $verb $direction $channel";
    }
    
    sub _generate_event_description
    {
        my ($self, $channel, $email, $verb, $remote_addr, $subscription_id) = @_;

        $subscription_id = $subscription_id || "";

        my $buf = <<FIN;
E-mail: $email<br>
Channel: $channel<br>
Action: $verb<br>
Address: $remote_addr
FIN

        if ($subscription_id)
        {
            $buf .= <<FIN;
<br>Subscription ID: $subscription_id
FIN
        }

        return $buf;
    }

    sub _send_event
    {
        my ($self, $title, $description) = @_;

        my $event = new ariba::rc::events::client::Event
        (
            {
                channel => $self->{'channel_name'},
                title => $title,
                description => $description,
            }
        );

        if (! $event->publish())
        {
            carp "Failed to publish event" if $self->{'verbose'};
        }
    }
    
    sub send_subscribe_event
    {
        my ($self, $channel, $email, $remote_addr, $subscription_id) = @_;
        my $verb = "subscribed";
        my $title = $self->_generate_event_title ($channel, $email, $verb);
        my $description = $self->_generate_event_description ($channel, $email, $verb, $remote_addr, $subscription_id);
        $self->_send_event ($title, $description);
    }

    sub send_unsubscribe_event
    {
        my ($self, $channel, $email, $remote_addr) = @_;
        my $verb = "unsubscribed";
        my $title = $self->_generate_event_title ($channel, $email, $verb);
        my $description = $self->_generate_event_description ($channel, $email, $verb, $remote_addr);
        $self->_send_event ($title, $description);
    }

    #
    # Pass named methods through to db_email
    #
    sub AUTOLOAD
    {
        no strict "refs";
        my ($self, @args) = @_;
        my @classes = split /::/, $AUTOLOAD;
        my $method  = $classes[$#classes];
        if (exists $PASSTHRU{$method})
        {
            return $self->{'db_email'}->$method (@args);
        }
        carp "Unknown method $method called on " . ref ($self) . "\n";
        return;    
    }

    #
    # Destructor
    #
    sub DESTROY
    {
        my ($self) = @_;
        delete $self->{'db_email'}; 
    }
}

1;
