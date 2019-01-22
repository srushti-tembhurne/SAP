package ariba::rc::events::DB::Email;

#
# SQLite database wrapper for e-mail database tables
#
# Follows API + inherits from ariba::rc::AbstractDB
# 

use strict;
use warnings;
use vars qw ($AUTOLOAD);
use Carp;
use Data::Dumper;
use DBD::SQLite;
use Digest::MD5 qw (md5_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../lib/perl";
use lib "$FindBin::Bin/../../bin";
use ariba::rc::AbstractDB;
use base ("ariba::rc::AbstractDB");
use ariba::rc::events::Constants;

{
    #
    # Constants
    #
    my $DEFAULT_LIMIT = 30;

    #
    # Day of Week lookup
    #
    my @DOW = qw (sun mon tue wed thu fri sat);
    my %DOW;
    foreach my $i (0 .. $#DOW)
    {
        $DOW{$DOW[$i]} = $i;
    }

    #
    # These lists have a tight relationship between the database schema
    # and the select statements. DBD::SQLite returns ordered data as a 
    # listref of listrefs. If you add a field to the schema or change 
    # a SELECT statement, these ordered lists must also be updated.
    #
    my $TABLES = 
    {
        'subscription_id' => 
        {
            'fields' => 
            [ 
                'subscription_id', 
            ],
        },
        'subscriptions' => 
        {
            'fields' => 
            [ 
                'subscription_id', 'email', 'channel', 'create_date', 'remote_addr'
            ],
        },
        'schedules' => 
        {
            'fields' => 
            [
                'id', 'email', 'enabled', 'tz', 
            ],
        },
        'availability' => 
        {
            'fields' => 
            [
                'id', 'dow', 'start_hour', 'start_min', 'end_hour', 'end_min',
            ],
        },
        'undelivered_join' => 
        {
            'fields' => 
            [
                'subscription_id', 'email', 'channel', 'create_date', 'remote_addr',
                'queue_id', 'subscription_id', 'event_id', 'create_date', 'delivery_date', 'delivered', 
            ],
        },
        'maillog_join' => 
        {
            'fields' => 
            [ 
				"subscription_id", "email", "channel", "create_date", "remote_addr",
                "maillog_id", "queue_id", "create_date", "status", "message",
                "queue_id", "subscription_id", "event_id", "create_date", "delivery_date", "delivered", 
            ],
        },
    };

    #
    # Constructor
    #
    sub new
    {
        my ($self) = @_;
        return $self->SUPER::new ();
    }

    #
    # Return path to db file
    #
    sub get_dbfile
    {
        return exists $ENV{'EVENT_SUBSCRIPTION_DB'} 
            ? $ENV{'EVENT_SUBSCRIPTION_DB'}
            : ariba::rc::events::Constants::subscription_db_file();
    }   

    # 
    # Create E-mail Databases
    #
    sub create_db
    {
        my ($self) = @_;
        $self->initialize();

        my $query = <<FIN;
CREATE TABLE subscriptions
(
    subscription_id INTEGER PRIMARY KEY,
    email varchar(192),
    channel varchar(96),
    create_date INTEGER,
    remote_addr varchar(15)
);
FIN

        $self->{'dbh'}->do ($query);
        $self->{'dbh'}->do ("CREATE INDEX subscription_channel on subscriptions (channel)");
        $self->{'dbh'}->do ("CREATE INDEX subscription_email on subscriptions (email)");
        $self->{'dbh'}->do ("CREATE INDEX subscription_index on subscriptions (channel,email)");
        $self->{'dbh'}->do ("CREATE INDEX subscription_created on subscriptions (create_date)");

        $query = <<FIN;
CREATE TABLE queue
(
    queue_id INTEGER PRIMARY KEY,
    subscription_id INTEGER,
    event_id INTEGER,
    create_date INTEGER,
    delivery_date INTEGER,
    delivered INTEGER
);
FIN

        $self->{'dbh'}->do ($query);
        $self->{'dbh'}->do ("CREATE INDEX queue_delivered on queue (delivered)");

        $query = <<FIN;
CREATE TABLE dupes 
(
    subscription_id INTEGER,
    checksum varchar(32)
);
FIN
        $self->{'dbh'}->do ($query);
        $self->{'dbh'}->do ("CREATE INDEX dupes_index on dupes (subscription_id, checksum)");

        $query = <<FIN;
CREATE TABLE maillog
(
    maillog_id INTEGER PRIMARY KEY,
    queue_id INTEGER,
    create_date INTEGER,
    status INTEGER,
    message TEXT
);
FIN
        $self->{'dbh'}->do ($query);
    
        $query = <<FIN;
CREATE TABLE schedule
(
    id INTEGER PRIMARY KEY, 
    email varchar(192),
    enabled INTEGER,
    tz varchar(192)
)
FIN
        $self->{'dbh'}->do ($query);
        $self->{'dbh'}->do ("CREATE INDEX schedule_email on schedule (email)");

        $query = <<FIN;
CREATE TABLE availability
(
    id INTEGER,
    dow INTEGER,
    start_hour INTEGER(2),
    start_min INTEGER(2),
    end_hour INTEGER(2),
    end_min INTEGER(2)
);
FIN
        $self->{'dbh'}->do ($query);
        $self->{'dbh'}->do ("CREATE INDEX availability_id on availability (id)");
        $self->{'dbh'}->do ("CREATE INDEX availability_dow on availability (dow)");
    }

    #
    # Expire records from event db
    #
    sub expire_db
    {
        my ($self) = @_;

        # Optional: Set expire_days to 0 = no expire
        return unless $self->{'expire_days'};

        $self->initialize();

        # create_date is kept as seconds since epoch
        my $old = time() - (60 * 60 * 24 * $self->{'expire_days'});

        my $query = <<FIN;
DELETE FROM queue WHERE queue.create_date < $old
FIN
        $self->do ($query);

        $query = <<FIN;
DELETE FROM maillog WHERE create_date < $old
FIN
        $self->do ($query);
    }

    #
    # Log delivery details 
    #
    sub log_delivery
    {
        my ($self, $queue_id, $status, $message) = @_;
        $self->initialize();
        my $now = time();
        $message = $message || "";
        $message = $self->quote ($message);
        my $query = <<FIN;
INSERT INTO maillog VALUES (NULL, $queue_id, $now, $status, $message)
FIN
        $self->do ($query);
    }

    #
    # Get data from maillog joined with queue/subscription tables
    #
    sub get_delivery_log
    {
        my ($self, $limit) = @_;
        $limit = $limit || $DEFAULT_LIMIT;
        $self->initialize();

        my $query = <<FIN;
SELECT * FROM subscriptions, maillog, queue
    WHERE 
    subscriptions.subscription_id = queue.subscription_id AND 
    maillog.queue_id = queue.queue_id
    ORDER BY maillog.create_date DESC
    LIMIT $limit
FIN
        
        my $row = $self->{'dbh'}->selectall_arrayref ($query);
        my @logentries;

        while ($#$row != -1)
        {
            my $listref = shift @$row;
            push @logentries, $self->coerce_maillog_data ($listref);
        }

    return \@logentries;
    }

    #
    # Avoid duplicate e-mails using MD5 against message body
    #
    sub is_duplicate_email
    {
        my ($self, $subscription_id, $event) = @_;
        $self->initialize();
        my $checksum = md5_hex ($event->description());
        my $query = <<FIN;
SELECT subscription_id FROM dupes WHERE subscription_id='$subscription_id' and checksum='$checksum'
FIN
        my $row = $self->{'dbh'}->selectall_arrayref ($query);
        return $#$row == -1 ? 0 : 1;
    }

    #
    # Get subscriptions by channel
    #
    sub get_subscriptions
    {
        my ($self, $channel_name) = @_;
        $self->initialize();

        my $query = <<FIN;
SELECT subscription_id FROM subscriptions WHERE channel = '$channel_name'
FIN
        my $row = $self->{'dbh'}->selectall_arrayref ($query);
        my @queue;

        while ($#$row != -1)
        {
            my $values = shift @$row;
            my $subscription_id = $$values[0];
            push @queue, $subscription_id;
        }
        
        return \@queue;
    }

    #
    # Queue delivery for an event
    #
    sub queue_event
    {
        my ($self, $channel_name, $event_id) = @_;
        $self->initialize();

        #
        # Fetch subscriptions for channel
        #
        my $queue = $self->get_subscriptions ($channel_name);

        # 
        # No subscriptions for this channel
        #
        return if $#$queue == -1;

        my $now = time();

        #
        # Insert subscriptions
        #
        foreach my $id (@$queue)
        {
            my $query = <<FIN;
INSERT INTO queue VALUES (NULL, $id, $event_id, $now, 0, 0)
FIN
            $self->do ($query);
        }
    }

    #
    # Subscribe to channel via e-mail
    #
    sub subscribe
    {
        my ($self, $channel_name, $email, $remote_addr) = @_;
        $self->initialize();
        my $now = time();
        my $query = <<FIN;
INSERT INTO subscriptions VALUES (NULL, '$email', '$channel_name', $now, '$remote_addr')
FIN
        $self->do ($query);
        return $self->{'dbh'}->func('last_insert_rowid');
    }

    #
    # Unsubscribe from channel
    #
    sub unsubscribe 
    {
        my ($self, $channel_name, $email, $remote_addr) = @_;
        $self->initialize();

        #
        # Delete from queue + dupes + maillog tables
        #
        my $subscription_id = $self->get_subscription_id ($email);
        if ($subscription_id)
        {
            my $query = <<FIN;
DELETE FROM queue WHERE subscription_id = $subscription_id
FIN
            $self->do ($query);

			$query = <<FIN;
DELETE FROM dupes WHERE subscription_id = $subscription_id
FIN
            $self->do ($query);
        }

        # 
        # Delete from subscriptions table
        #
        my $query = <<FIN;
DELETE FROM subscriptions WHERE email='$email' AND channel='$channel_name'
FIN
        $self->do ($query);
    }

    #
    # Given e-mail address, return subscription id
    #
    sub get_subscription_id
    {
        my ($self, $email) = @_;
        my $query = <<FIN;
SELECT subscription_id FROM subscriptions WHERE email='$email'
FIN
        my $row = $self->{'dbh'}->selectall_arrayref ($query);
        return 0 if $#$row == -1;
        my $listref = shift @$row;
        return 0 if $#$listref == -1;
        my $hashref = $self->coerce_subscription_id_data ($listref);
		return $hashref->{'subscription_id'};
    }
    
    #
    # Get subscription info given e-mail + channel name
    #
    sub get_subscription
    {
        my ($self, $email, $channel_name) = @_;
        $self->initialize();
        my $query = <<FIN;
SELECT * FROM subscriptions WHERE email='$email' AND channel='$channel_name'
FIN
        my $row = $self->{'dbh'}->selectall_arrayref ($query);
        return 0 if $#$row == -1;

        my $listref = shift @$row;
        return 0 if $#$listref == -1;

        return $self->coerce_subscription_data ($listref);
    }

    #
    # Get all subscriptions
    #
    sub get_all_subscriptions
    {
        my ($self, $channel_name) = @_;
        $self->initialize();

        #
        # Optional values
        #
        my @specifics = ();
        if ($channel_name)
        {
            push @specifics, "channel='$channel_name'";
        }
        my $specifics = $#specifics == -1 ? "" : "WHERE " . (join " AND ", @specifics);

        my $query = <<FIN;
SELECT * FROM subscriptions $specifics ORDER BY email
FIN
        my $row = $self->{'dbh'}->selectall_arrayref ($query);
        my @rows;
        while (my $listref = shift @$row)
        {
            push @rows, $self->coerce_subscription_data ($listref);
        }
        return \@rows;
    }

    #
    # Returns true if subscription exists for e-mail + channel name 
    #
    sub has_subscription
    {
        my ($self, $email, $channel_name) = @_;
        $self->initialize();
        my $subscription_data = $self->get_subscription ($email, $channel_name);
        return $subscription_data && exists $subscription_data->{'subscription_id'} ? 1 : 0;
    }

    #
    # Get count of undelivered messages
    #
    sub get_queue_size
    {
        my ($self) = @_;
        $self->initialize();
        my $query = <<FIN;
SELECT COUNT(*) as k FROM queue WHERE delivered='0'
FIN
        my $row = $self->{'dbh'}->selectall_arrayref ($query);
        if ($#$row == -1)
        {
            return 0;
        }
        my $listref = shift @$row;
        my $undelivered = shift @$listref || 0;
        return $undelivered;
    }

    #
    # Get undelivered queued messages
    #
    sub get_undelivered
    {
        my ($self) = @_;
        $self->initialize();
        my $query = <<FIN;
SELECT * FROM subscriptions, queue
    WHERE 
    queue.delivered='0' AND 
    subscriptions.subscription_id = queue.subscription_id
    ORDER BY queue.create_date
FIN

        my $row = $self->{'dbh'}->selectall_arrayref ($query);
        my @undelivered;

        foreach my $i (0 .. $#$row)
        {
            my $hashref = $self->coerce_undelivered_data ($$row[$i]);
            push @undelivered, $hashref;
        }
        return \@undelivered;
    }

    #
    # Coerce data from sqlite into hashref
    #
    sub coerce_subscription_id_data
    {
        my ($self, $data) = @_;
        return $self->_coerce ($data, "subscription_id");
    }

    sub coerce_undelivered_data
    {
        my ($self, $data) = @_;
        return $self->_coerce ($data, "undelivered_join");
    }

    sub coerce_subscription_data
    {
        my ($self, $data) = @_;
        return $self->_coerce ($data, "subscriptions");
    }

    sub coerce_schedule_data
    {
        my ($self, $data) = @_;
        return $self->_coerce ($data, "schedules");
    }

    sub coerce_availability_data
    {
        my ($self, $data) = @_;
        return $self->_coerce ($data, "availability");
    }

    sub coerce_maillog_data
    {
        my ($self, $data) = @_;
        return $self->_coerce ($data, "maillog_join");
    }

    sub _coerce
    {
        my ($self, $data, $table_id) = @_;
        my $hashref;
        foreach my $field (@{$TABLES->{$table_id}->{'fields'}})
        {
            my $value = shift @$data;
            $hashref->{$field} = $value;
        }
        return $hashref;
    }

    #
    # Mark message as delivered
    #
    sub mark_as_delivered
    {
        my ($self, $queue_id, $subscription_id, $event) = @_;
        $self->initialize();
        my $now = time();
        my $query = <<FIN;
UPDATE queue SET delivered='1', delivery_date='$now' WHERE queue_id = '$queue_id'
FIN
        $self->do ($query);

        my $checksum = md5_hex ($event->description());

        $query = <<FIN;
INSERT INTO dupes VALUES ('$subscription_id', '$checksum')
FIN
        $self->do ($query);
    }

    #
    # Get schedule by e-mail address
    #
    sub get_schedule
    {
        my ($self, $email) = @_;
        $self->initialize();
        my $query = <<FIN;
SELECT * FROM schedule WHERE 
    schedule.email = '$email'
FIN

        my $row = $self->{'dbh'}->selectall_arrayref ($query);
        my %dow;

        if ($#$row == -1)
        {
            # no schedule on disk: return empty hash
            return \%dow;
        }

        # 
        # Map: day of week => availability rows
        #
        my $id;
        while (my $data = shift @$row)
        {
            my $schedule = $self->coerce_schedule_data ($data);
            $id = $schedule->{'id'} unless $id;
            %dow = %$schedule;
        }

        $query = <<FIN;
SELECT * FROM availability WHERE id = '$id'
FIN

        $row = $self->{'dbh'}->selectall_arrayref ($query);
        while (my $data = shift @$row)
        {
            my $avail = $self->coerce_availability_data ($data);
            $dow{$avail->{'dow'}} = $avail;
        }

        return \%dow;
    }

    # 
    # Update schedule data
    #
    sub update_schedule
    {
        my ($self, $email, $enabled, $timezone, $data) = @_;

        #
        # Delete old schedule
        #
        my $old_schedule = $self->get_schedule ($email);
        my $id = 'NULL';

        if ($old_schedule)
        {
			$id = $old_schedule->{'id'};
            $self->do ("DELETE FROM schedule WHERE email = '$email'");
            $self->do ("DELETE FROM availability WHERE id = '$id'");
        }

        my $query = <<FIN;
INSERT INTO schedule VALUES ($id, '$email', $enabled, '$timezone')
FIN
        $self->do ($query);

        #
        # Generate an ID number unless caller provided one
        #
        if ($id eq "NULL")
        {
            $id = $self->{'dbh'}->func('last_insert_rowid');
        }

        #
        # Transform HTML form values into SQL query
        #
        foreach my $d (0 .. $#DOW)
        {
            my $start = $data->{$d. "start"} || "";
            my $end = $data->{$d. "end"} || "";
            next if $start eq "--" || $end eq "--";
            
            my $day = $DOW{$DOW[$d]};
            next unless ($day >= 0 && $day <= 6);

            my ($start_hour, $start_min) = split /:/, $start;
            my ($end_hour, $end_min) = split /:/, $end;
            next unless $self->is_integer ($start_hour, $start_min, $end_hour, $end_min);
            
            my $query = <<FIN;
INSERT INTO availability VALUES ($id, $day, $start_hour, $start_min, $end_hour, $end_min)
FIN
            $self->do ($query);
        }
    }

    #
    # True if all values provided are numbers
    #
    sub is_integer
    {
        my ($self, @values) = @_;
        while (my $value = shift @values)
        {
            if ($value !~ m#^\d+$#)
            {
                return 0;
            }
        }
        return 1;
    }
}

1;
