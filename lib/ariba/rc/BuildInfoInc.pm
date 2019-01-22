package ariba::rc::BuildInfoInc;

use strict;
use warnings;
use DBD::SQLite;
use vars qw ($AUTOLOAD);
use Carp qw(cluck);

use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../lib/perl";
use lib "$FindBin::Bin/../lib/perl";
use lib "$FindBin::Bin/../bin";
use ariba::Automation::Utils::Try;

use constant DB_FILE => "/home/rc/etc/buildinfo.db";
use constant DB_TABLE => "buildinfoinc";

sub getDBFile {
    return DB_FILE;
}

sub getDBTable {
    return DB_TABLE;
}

sub initialize {
    my $dbFile = getDBFile();
    my $dbh = DBI->connect ("dbi:SQLite:dbname=$dbFile", "", "");
    
    return $dbh;
}

sub insertBuildName {
    my $buildname = shift;
    my $tablename = getDBTable();
    my $dbh = initialize();
    
    checkDBtableExists($dbh);
    
    my $query = "insert into $tablename values ($buildname) \;";
    $dbh->do($query);
}

sub fetchBuildName {
    my $tablename = getDBTable();
    
    my $dbh = initialize();
    my $query = "select buildname from $tablename \;";
    my $status = $dbh->do($query);
    print "$status\n";    
    
}


sub checkDBtableExists {
    my $dbh = shift;
    my $tablename = getDBTable();
    my $query = "select * from $tablename \;";
    my $status = $dbh->do($query);
    
    if($status != 1) {
        createTable($dbh);
    }
}

sub createTable {
    my $dbh = shift;
    my $tablename = getDBTable();
    my $query = <<QRY;
    create table $tablename (buildname varchar(96));
QRY

    $dbh->do($query);
}

sub do {
    my $query = shift;
    my $ok = ariba::Automation::Utils::Try::retry
               (5, "Database is Locked", sub { $dbh->do($query);} );
    
    if (exists $ENV{'EVENTS_DB_DEBUG'}) {
        print "$query\n";
        if (! $ok) {
            cluck "Failed to execute \"$query\": $@";
        }
    }
    
    return $ok;
}


1;
