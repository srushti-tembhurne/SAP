#!/usr/local/bin/perl -w
#
# $Id: //ariba/services/monitor/lib/ariba/DBA/HanaSampleSQLQueries.pm
#
# This is a template with bunch of useful dba type queries.
# New queries can be added, and cronjob setup to either display the results
# to ops page or log it to a file.
#
# This script can be run as 'monprod' unix user.
# It needs to know hana users: system passwords.
#

use strict;

package ariba::DBA::HanaSampleSQLQueries;

use ariba::rc::InstalledProduct;
use ariba::rc::Utils;
use ariba::Ops::ProductAPIExtensions;
use ariba::Ops::HanaClient;
use ariba::Ops::DBConnection;


my $debug;

my $timeoutOccured = 0;

my $hanaError = undef;

sub executeSQLQuery {

    my $mon = shift;
    my $sqlQueryName = shift;
    my $dbc = shift;
    my $displayResults = shift;
    my $timeout = shift;
    my $comment =  shift;

    my @results  = ();

    undef($hanaError);
    $timeoutOccured = 0;

    my $hostname = ariba::Ops::NetworkUtils::hostname();

    print "In executeSQLQuery() for query = $sqlQueryName\n" if ($debug);

    my $host = $dbc->host();

    #for testing
    #if ( grep(/hana/, $host)) {
    #     print "overriding host connection info from $host to $hostname\n";
    #     $host = $hostname;
    #}

    # system/$systempass@$instance
    my $user = $mon->default("dbainfo.hana.system.username");
    my $pass;
    my $sql;
    my %sqlForName= (
        createSnapshot  => qq{backup data create snapshot COMMENT '$comment'},
        #dropSnapshot    => qq{backup data close snapshot BACKUP_ID (SELECT BACKUP_ID FROM "PUBLIC"."M_BACKUP_CATALOG" WHERE COMMENT = '$comment') SUCCESSFUL '$comment'},
        checkSnapshot   => q{select count(*) from M_SNAPSHOTS where FOR_BACKUP='TRUE'},
        listHosts       => 'select host,INDEXSERVER_ACTUAL_ROLE from m_landscape_host_configuration',
    );

    $pass = $mon->default("dbainfo.hana.system.password");

    if ($sqlForName{$sqlQueryName}) {
        $sql = $sqlForName{$sqlQueryName};
    } elsif ( $sqlQueryName eq 'dropSnapshot' ) {
        $sql = genDropSql( $user, $pass, $dbc, $displayResults, $timeout, $comment );
    } else {
        $hanaError = "No sql defined for '$sqlQueryName'";
        print $hanaError, "\n" if ($debug);
    }

    print "sql to execute:$sql\n" if ($debug);

    push(@results, executeAndDisplayQueryResults(
        $user, $pass, $dbc, $sql, $displayResults, $timeout
    )) if ($sql);

    if (wantarray()) {
        return (@results);
    } else {
        return $results[0];
    }
}

sub executeAndDisplayQueryResults {
    my ($user, $pass, $dbc, $sql, $displayResults, $timeout) = @_;

    my @results = ();

    my $hc = ariba::Ops::HanaClient->new($user, $pass, $dbc->host(), $dbc->port(), $dbc->hanaHosts());
    $hc->connect() || do {
        $hanaError = "Error: Could not connect to hana server user=$user: " . $hc->error();
        print $hanaError, "\n" if ($debug || $displayResults);
    };

    # optionally run with a timeout.
    if (defined $timeout) {
        if ($hc->executeSqlWithTimeout($sql, $timeout, \@results)) {
            $timeoutOccured = 0;
        } else {
            $timeoutOccured = 1;
        }
    } else {
        @results = $hc->executeSql($sql);
    }

    $hanaError = undef;
    if ($hc->error()) {
        $hanaError = $hc->error();
    } elsif ($timeoutOccured) {
        $hanaError = "$sql timed out in $timeout sec(s)!";
    }

    if ($displayResults || $debug) {
        if (scalar @results > 0) {
            print join("\n", @results);
            print "\n";
        }

        if ($hanaError) {
            print("hana Error: $hanaError\n");
        }
    }

    $hc->disconnect();

    return (@results);
}

sub hanaError {
    return $hanaError;
}

sub timeoutOccured {
    return $timeoutOccured;
}

sub genDropSql {
    my ($user, $pass, $dbc, $displayResults, $timeout, $comment) = @_;
    ## Generate this SQL:
    ## BACKUP DATA CLOSE SNAPSHOT BACKUP_ID <backup_id> SUCCESSFUL <external_id>

    my $sql = 'backup data close snapshot backup_id ';

    my $query = <<END;
select backup_id
from M_BACKUP_CATALOG
where ENTRY_TYPE_NAME='data snapshot'
and backup_Id = (select max(backup_id) from M_BACKUP_CATALOG where
entry_type_name='data snapshot' );
END

    my @res = executeAndDisplayQueryResults( $user, $pass, $dbc, $query, $displayResults, $timeout );
    $sql .= $res[0];
    $sql .= " SUCCESSFUL '$comment'";

    return $sql;
}

sub hostMap {
    my ( $mon, $dbc ) = @_;
    my $ret;

    my @hosts = ariba::DBA::HanaSampleSQLQueries::executeSQLQuery($mon, "listHosts", $dbc);
    ## This returns an array of tab separated host/type pairs:
    ## $VAR1 = [
    ##      #0
    ##      "hana1001\tSLAVE",
    ##      #1
    ##      "hana1002\tSTANDBY",
    ##      #2
    ##      "hana1000\tMASTER"
    ##    ];
    foreach my $host ( @hosts ){
        my ( $name, $type ) = split /\t/, $host;
        $ret->{ $name } = $type;
    }
    return $ret;
}

sub amIMaster {
    my ( $mon, $dbc, $hostname ) = @_;
    my $ret = 0; ## Assume false

    my $hostMap = ariba::DBA::HanaSampleSQLQueries::hostMap($mon, $dbc );

    foreach my $host ( keys %{ $hostMap } ){
        if ( $hostMap->{ $host } eq 'MASTER' && $hostname =~ /$host/ ){
            $ret = 1;
            last; ## We found it, no reason to keep going through the list
        }
    }
    return $ret;
}

sub amIStandby {
    my ( $mon, $dbc, $hostname ) = @_;
    my $ret = 0; ## Assume false

    my $hostMap = ariba::DBA::HanaSampleSQLQueries::hostMap($mon, $dbc );

    foreach my $host ( keys %{ $hostMap } ){
        if ( $hostMap->{ $host } eq 'STANDBY' && $hostname =~ /$host/ ){
            $ret = 1;
            last; ## We found it, no reason to keep going through the list
        }
    }
    return $ret;
}

sub whoIsMaster {
    my ( $mon, $dbc ) = @_;
    my $master = undef;

    # From //ariba/services/tools/lib/perl/ariba/Ops/DBConnection.pm
    # In sub connectionsFromProducts
    # $host = $product->default("$dictKeypath.AribaDBHostname");

    my $dbhost = $dbc->host();
    my ($suffix) = $dbhost =~ m/(?:[^\.]+)(.*)/;

    my $hostMap = ariba::DBA::HanaSampleSQLQueries::hostMap($mon, $dbc );
    foreach my $host ( keys %{ $hostMap } ){
        $master = $host if ( $hostMap->{ $host } eq 'MASTER' );
        if ( $master ) {
	    if ($master =~ /\.ariba\.com/i){
		##for hana169 $master is hana169.lab1.ariba.com : if so do not suffix
		return lc($master);
	    }
            return lc($master).$suffix;
        }
    }
    return $master;
}

1;

__END__
