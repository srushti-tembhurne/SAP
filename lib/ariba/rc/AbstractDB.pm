package ariba::rc::AbstractDB;

#
# Abstract interface for databases + common functions
#

use strict;
use warnings;
use vars qw ($AUTOLOAD);
use Carp qw(cluck);
use Data::Dumper;
use DBD::SQLite;
use ariba::Automation::Utils::Try;

{
    #
    # Constructor
    #
    sub new
    {
        my ($class) = @_;
        my $self = 
        {
            'initialized' => 0,
            'dbfile' => 0,
            'dbh' => 0,
            'retries' => 15, 
            'expire_days' => 30,
        };
        bless ($self, $class);
        return $self;
    }

    # 
    # Subclasses should return path to database file
    #
    sub get_dbfile
    {
    }

    #
    # Connect to DB
    #
    sub initialize
    {
        my ($self) = @_;

        #
        # Initialize once
        #
        return if $self->initialized();
        $self->initialized (1);

        #
        # Allow caller to specify alternate db file
        #
        $self->{'dbfile'} = $self->{'dbfile'} || $self->get_dbfile();

        #
        # Open connection to DB
        #
        $self->{'dbh'} = DBI->connect ("dbi:SQLite:dbname=" . $self->{'dbfile'}, "", "");
    }

    #
    # Delete database from disk i.e. drop all tables
    #
    sub delete_db
    {
        my ($self) = @_;

        $self->{'dbfile'} = $self->{'dbfile'} || $self->get_dbfile();
        
        return unless -e $self->{'dbfile'};

        if (! unlink $self->{'dbfile'})
        {
            cluck "Can't delete " . $self->{'dbfile'} . "\n";
            return 0;
        }

        return 1;
    }

    #
    # Create DB
    #
    sub create_db
    {
    }

    #
    # Create indexes
    #
    sub create_indexes
    {
    }

    #
    # Expire records
    #
    sub expire_db
    {
    }

    #
    # Shortcut for dbh->do() with retry wrapper
    #
    sub do
    {
        my ($self, $query) = @_;
        my $ok = ariba::Automation::Utils::Try::retry
        (
            $self->{'retries'},
            "database is locked",
            sub { $self->{'dbh'}->do ($query); }
        );
		if (exists $ENV{'EVENTS_DB_DEBUG'})
		{
			print "$query\n";
			if (! $ok)
			{
				cluck "Failed to execute \"$query\": $@";
			}
		}
        return $ok;
    }

    #
    # Change path to dbfile 
    #
    sub set_dbfile
    {
        my ($self, $file) = @_;
        $self->{'dbfile'} = $file;
    }

    #
    # Escape single quotes + quote remainder
    #
    sub quote
    {
        my ($self, $buf) = @_;

        #
        # SQLite escapes single-quotes with ''
        #
        $buf =~ s/'/''/gm;
        return "'" . $buf . "'";
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

        #
        # Destroy DB connection
        #
        delete $self->{'dbh'} if exists $self->{'dbh'};

        #
        # Reset initialize state
        #
        $self->initialized (0);
    }
}

1;
