package ariba::rc::events::DB;

#
# SQLite database wrapper for Events
#
# TODO: Convert this to use Oracle (maybe)
# 

use strict;
use warnings;
use vars qw ($AUTOLOAD);
use Carp;
use Data::Dumper;
use DBD::SQLite;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../lib/perl";
use lib "$FindBin::Bin/../../bin";
use ariba::rc::events::Constants;
use ariba::rc::events::client::Event;
use ariba::rc::AbstractDB;
use base ("ariba::rc::AbstractDB");

{
    #
    # Constructor
    #
    sub new
    {
        my ($self) = @_;
        my $class = $self->SUPER::new ();
		$class->{'expire_days'} = ariba::rc::events::Constants::expire_days();
		return $class;
    }

    #
    # Return path to db file
    #
    sub get_dbfile
    {
        return exists $ENV{'EVENT_DB'}
            ? $ENV{'EVENT_DB'}
            : ariba::rc::events::Constants::event_db_file();
    }

    #
    # Create DB
    #
    sub create_db
    {
        my ($self) = @_;
        $self->initialize();
        my $tablename = ariba::rc::events::Constants::event_db_table_events();

        my $query = <<FIN;
CREATE TABLE $tablename
(
    id INTEGER PRIMARY KEY,
    channel varchar(96),
    title varchar(255),
    description blob,
    create_date INTEGER
);
FIN

        $self->{'dbh'}->do ($query);
    }

    #
    # Create indexes into events table
    #
    sub create_indexes
    {
        my ($self) = @_;
        $self->initialize();
        my $tablename = ariba::rc::events::Constants::event_db_table_events();

        #
        # Create index on channel field
        #
        my $index0 = join "", $tablename, "channel";
        my $query = <<FIN;
CREATE INDEX $index0 ON $tablename (channel)
FIN
        $self->{'dbh'}->do ($query);
    }

    #
    # Insert Event object into DB
    #
    sub insert
    {
        my ($self, $event, $channel) = @_;
        $self->initialize();

        #
        # generate insert statement
        #
        my @values = ('NULL', $self->quote ($channel->name()));
        foreach my $key ("title", "description")
        {
            push @values, $self->quote ($event->$key);
        }
        push @values, time();

        my $tablename = ariba::rc::events::Constants::event_db_table_events();
        my $query = "INSERT INTO $tablename values (" . (join ",", @values) . ")";
        my $ok = $self->do ($query);
        return 0 unless $ok;

        my $id = $self->{'dbh'}->func('last_insert_rowid');
        return $id;
    }

    sub fetch_events
    {
        my ($self, $channel, $limit) = @_;
        $self->initialize();

        #
        # Generate select statement
        #
        my $tablename = ariba::rc::events::Constants::event_db_table_events();
        my $channel_name = ref ($channel) ? $channel->name() : $channel; ## TODO: Remove this (handy for testing though)
        my $query = "SELECT * FROM $tablename WHERE channel = '$channel_name' ORDER BY id DESC LIMIT $limit";
        my $row = $self->{'dbh'}->selectall_arrayref ($query);
        my @events;

        while ($#$row != -1)
        {
            my $listref = shift @$row;
            my $hashref = $self->coerce_row_to_event ($listref);

            #
            # Convert rows to Event object
            #
            my $event = new ariba::rc::events::client::Event->newFromDirtyObject ($hashref);
            push @events, $event;
        }

        return \@events;
    }
        
    #
    # Fetch event from DB
    #
    sub fetch
    {
        my ($self, $id) = @_;
        $self->initialize();

        #
        # Generate select statement
        #
        my $tablename = ariba::rc::events::Constants::event_db_table_events();
        my $query = "SELECT * FROM $tablename WHERE id = '$id'";
        my $row = $self->{'dbh'}->selectall_arrayref ($query);

        #
        # Return 0 unless we got row from db
        #
        if ($#$row != -1)
        {
            my $listref = shift @$row;
            my $hashref = $self->coerce_row_to_event ($listref);

            #
            # Convert rows to Event object
            #
            my $event = new ariba::rc::events::client::Event->newFromDirtyObject ($hashref);
            return $event;
        }
        return 0;
    }

    sub coerce_row_to_event
    {
        my ($self, $listref) = @_;

        #
        # Generate hashref from DB row
        # 
        return
        {
            'id' => $$listref[0],
            'channel' => $$listref[1],
            'title' => $$listref[2],
            'description' => $$listref[3],
            'create_date' => $$listref[4],
        };
    }

    #
    # Expire records from event db
    #
    sub expire_db
    {
        my ($self) = @_;

        #
        # Optional: Set expire_days to 0 = no expire
        #
        if (! $self->{'expire_days'})
        {
            return;
        }

        $self->initialize();
        my $tablename = ariba::rc::events::Constants::event_db_table_events();

        # create_date is kept as seconds since epoch
        my $old = time() - (60 * 60 * 24 * $self->{'expire_days'});

        my $query = <<FIN;
DELETE FROM $tablename WHERE create_date < '$old'
FIN
        $self->do ($query);
    }
}

1;
