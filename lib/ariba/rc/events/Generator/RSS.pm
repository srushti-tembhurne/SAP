package ariba::rc::events::Generator::RSS;

#
# Create RSS 2.0 file 
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
use ariba::rc::events::Generator;
use base ("ariba::rc::events::Generator");
use ariba::rc::events::DB;
use ariba::rc::events::Subscriptions;
use ariba::rc::events::Utils;
use ariba::rc::events::Constants;
use dmail::LockLib;

{
    #
    # Constants
    #
    my $EVENT_TYPE = 'RSS';
    my $RSS_VERSION = '2.0';

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
    # To generate RSS 1.0 for whatever reason, make subclass then 
    # override rss_version to return 1.0
    #
    sub rss_version
    {
        return $RSS_VERSION;
    }

    #
    # Write RSS file to disk:
    #
    # - dmail::LockLib used to assure atomic writes
    #
    # Returns error state (true) if something failed
    #
    sub publish_event
    {
        my ($self) = @_;

        my $channel = $self->{'channel'};

        my $dir = $channel->dir() || ariba::rc::events::Constants::root_dir();

        # make destination dir if it doesn't exist
        if (! -d $dir)
        {
            if (! mkdir ($dir))
            {
                carp "Can't mkdir $dir, $!\n";
                return 1;
            }
        }
        
        #
        # Make new DB class to get/put events from/to datastore
        #
        my $db = new ariba::rc::events::DB();

        #
        # Insert event into database, returns unique id number
        #
        my $id = $db->insert ($self->{'event'}, $channel);

        #
        # Enqueue subscriptions if any
        #
        my $subscription_manager = new ariba::rc::events::Subscriptions();
        $subscription_manager->queue_event ($channel->name(), $id);

        #
        # Path to RSS file on disk
        #
        my $file = join "/", $dir, $channel->file();
        
        #
        # generate url to feed
        #
        my $url = join "/", ariba::rc::events::Constants::root_url(), $channel->file();

        #
        # Custom URIs can be specified
        #
        if ($channel->uri())
        {
            $url = join "/", ariba::rc::events::Constants::root_url(), $channel->uri(), $channel->file();
        }

        #
        # Grab lockfile
        #
        my $lockfile = "$file.busy";
        dmail::LockLib::forceQuiet();
        unless (dmail::LockLib::requestlock ($lockfile, ariba::rc::events::Constants::lockfile_timeout()))
        {
            carp "Can't get lockfile $lockfile for $file\n";
            return 1;
        }

        #
        # Make new RSS generator
        #
        my $rss = XML::RSS->new (version => $self->rss_version());

        #
        # Maximum number of items to publish
        #
        my $limit = $channel->limit() || ariba::rc::events::Constants::max_events();

        #
        # Fetch events for this channel from datastore
        #
        my $events = $db->fetch_events ($channel, $limit);

        #
        # Update channel information
        #
        $rss->channel
        (
            title => $self->{'channel'}->title(),
            link => $url,
            description => $self->{'channel'}->description(),
        );

        #
        # Write events as items to RSS file
        #
        foreach my $event (@$events)
        {
            #
            # pubDate expected to be in RFC-822 format
            #
            my $pubdate = ariba::rc::events::Utils::pub_date ($event->{'create_date'});
        
            #
            # Generate unique link to event viewer for this event
            #
            my $event_link = ariba::rc::events::Constants::view_event_url ($event->id(), $channel->name);
            
            #
            # Make new rss item from event data
            # 
            $rss->add_item
            (
                mode => 'insert',
                title => $event->title(),
                link => $event_link, 
                description => $event->description(),
                pubDate => $pubdate,
                guid => $event->id(),
            );
        }

        #
        # Write rss data to tempfile then mv into place
        #
        my $tmpfile = "$file.tmp";

        if (! open FILE, ">$tmpfile")
        {
            carp "Can't create $tmpfile, $!\n";
            return 1;
        }

        print FILE $rss->as_string . "\n";

        if (! close FILE)
        {
            carp "Can't close $tmpfile, $!\n";
            unlink $tmpfile || carp "Can't unlink $tmpfile, $!\n";
            return 1;
        }

        #
        # Atomic install of new rss file
        #
        if (! move ($tmpfile, $file))
        {
            carp "Can't move $tmpfile to $file, $!\n";
            unlink $tmpfile;
            return 1;
        }

        dmail::LockLib::releaselock ($lockfile);

        return 0;
    }
}

1;
