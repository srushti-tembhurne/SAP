package ariba::Automation::BuildFailDB;

#
# Build Failure Database
#

use strict 'vars';
use warnings;
use vars qw ($AUTOLOAD);
use Carp;
use Data::Dumper;
use DBD::SQLite;
use ariba::Automation::BuildResult;

{
    #
    # Constructor
    #
    sub new
    {
        my ($class, $dbfile) = @_;
		$dbfile = $dbfile || "";

        my $self = 
		{
			# true if we have connected to the database
			'_initialized' => 0, 

			# path to sqlite database file
			'_db_file' => $dbfile || "/home/rc/etc/build_history.db",

			# name of table
			'_table_name' => "build_fail",

			# field order: names match BuildResult class fields
			'_order' => 
			[
				"product", 
				"release", 
				"robot", 
				"status",
				"hostname", 
				"fail_type", 
				"pretty_print", 
				"responsible", 
				"buildTime"
			],
		};

        bless ($self,$class);
        return $self;
    }

	# 
	# connect to database
	#
	sub init
	{
		my ($self) = @_;

		# only attempt to connect once, otherwise bail early
		return if $self->{'_initialized'};

		# connect to sqlite database 
		$self->{'dbh'} = DBI->connect ("dbi:SQLite:dbname=" . $self->_db_file(), "", "");

		# mark class as initialized
		$self->{'_initialized'} = 1;
	}

	# 
	# create build history table 
	#
	sub create_db
	{
		my ($self) = @_;

		my $table = $self->_table_name();

		# insert statement
		my $sql = <<FIN;
CREATE TABLE $table
(
	logfile VARCHAR(64) PRIMARY KEY,
	product VARCHAR(64),
	release VARCHAR(16),
	robot varchar(32),
	status INTEGER,
	hostname varchar(128),
	fail_type VARCHAR(16),
	pretty_print VARCHAR(192),
	responsible VARCHAR(16),
	build_date INTEGER
);
FIN

		$self->{'dbh'}->do ($sql);

		#
		# Create index on status field
		#
		my $index0 = join "", $table, "status";
		$sql = <<FIN;
CREATE INDEX $index0 ON $table (status)
FIN
		$self->{'dbh'}->do ($sql);
	}

	# 
	# Returns oldest and newest build dates
	#
	sub date_range
	{
		my ($self) = @_;
		$self->init();

		my @ranges;
		foreach my $range ("MIN", "MAX")
		{
			my $sql = "SELECT $range(build_date) FROM " . $self->_table_name();
            my $rows = $self->{'dbh'}->selectall_arrayref ($sql);
            if ($#$rows != -1)
            {
                push @ranges, ${$$rows[0]}[0];
            }
		}

		return \@ranges;
	}

	#
	# Returns a count of build results for each status and 
	# a total. 
	#
	# 0 = FAILURE
	# 1 = success
	#

	sub count
	{
		my ($self) = @_;
		$self->init();

		my @status;
		foreach my $status (0, 1)
		{
			my $sql = "SELECT COUNT(*) FROM " . $self->_table_name() . " WHERE STATUS='$status'";
			my $rows = $self->{'dbh'}->selectall_arrayref ($sql);
			if ($#$rows != -1)
			{
				push @status, ${$$rows[0]}[0];
			}
		}
		
		push @status, $status[0] + $status[1];
		return \@status;
	}

	#
	# delete BuildResult object from database
	#
	# Takes ARRAYREF of primary keys i.e. dir/file of build log
	#
	sub delete
	{
		my ($self, $deleted_keys) = @_;

		my @ids;

		foreach my $key (@$deleted_keys)
		{
			push @ids, $self->quote ($key);
		}

		if ($#ids == -1)
		{
			return;
		}

		$self->init();
		my $sql = "DELETE FROM " . $self->_table_name() . " WHERE logfile IN (" . (join ",", @ids) . ")";
		return $self->{'dbh'}->do ($sql);
	}

	#
	# insert BuildResult object into database
	#
	sub insert
	{
		my ($self, $result) = @_;
		$self->init();

		# logdir + logfile = primary key
		my $logfile = join "/", $result->dir(), $result->file();

		# build insert statement
		my @values = ( $self->quote ($logfile) );
		
		foreach my $key (@{$self->{'_order'}})
		{
			my $value = $result->$key() || "";
			if ($key eq "status")
			{
				$value = $value eq "success" ? 1 : 0;
			}
			push @values, $self->quote ( $value );
		}

		my $sql = "INSERT INTO " . $self->_table_name() . " VALUES (" . (join ", ", @values) . ")";
		return $self->{'dbh'}->do ($sql);
	}

	#
	# get rows ordered by build_date with a specified limit
	#

	sub select
	{
		my ($self, $limit) = @_;
		$self->init();
		my $sql = "SELECT * FROM " . $self->_table_name() . " WHERE status='0' ORDER BY build_date DESC LIMIT $limit";
		my $rows = $self->{'dbh'}->selectall_arrayref ($sql);
		return $rows;
	}

	#
	# return true if BuildResult object already exists
	#
	sub exists
	{
		my ($self, $key) = @_;
		$self->init();
		my $sql = "SELECT * FROM " . $self->_table_name() . " where logfile = '$key'";
		my $sth = $self->{'dbh'}->prepare ($sql);
		$sth->execute();
		my $row = $sth->fetch;
		return $#$row == -1 ? 0 : 1;
	}

	# 
	# Surround a string with single quotes
	#
	sub quote 
	{
		my ($self, $str) = @_;
		return "'" . $str . "'";
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
		delete $self->{'dbh'};
		$self->{'_initialized'} = 0;
    }

}

1;
