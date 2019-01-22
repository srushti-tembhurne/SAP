#!/usr/local/bin/perl -w
#
# $Id: //ariba/services/monitor/lib/ariba/DBA/SampleSQLQueries.pm#27 $
#
# This is a template with bunch of useful dba type queries.
# New queries can be added, and cronjob setup to either display the results
# to ops page or log it to a file.
#
# This script can be run as 'monprod' unix user.
# It needs to know oracle users: system and perfstat passwords.
#

use strict;

package ariba::DBA::SampleSQLQueries;

use ariba::rc::InstalledProduct;
use ariba::rc::Utils;
use ariba::Ops::ProductAPIExtensions;
use ariba::Ops::OracleClient;
use ariba::Ops::DBConnection;

my $debug = 0;

my $timeoutOccured = 0;

my $oracleError = undef;

sub executeSQLQuery {

    my $mon = shift;
    my $sqlQueryName = shift;
    my $dbc = shift;
    my $displayResults = shift;
    my $timeout = shift;

    my @results  = ();

    undef($oracleError);
    $timeoutOccured = 0;

    my $cluster  = $mon->currentCluster();
    my $hostname = ariba::Ops::NetworkUtils::hostname();

    print "In executeSQLQuery() for query = $sqlQueryName\n" if ($debug);

    my $type = $dbc->type();
    my $host = $dbc->host();
    my $instance = uc($dbc->sid());

    # system/$systempass@$instance
    my $isPhysicalReplication = $dbc->isDR() && $dbc->isPhysicalReplication();
    my $user = $isPhysicalReplication ? 'sys' : 'system';
    my $pass;
    my $sql;
    my %sqlForName= (
        version         => q`select version from v$instance`,
        isup            => q`select 'TEST' xxx from dual`,
        getVolume       => q`select file_name from dba_data_files order by file_name`,
        logLocations    => q`select member from v$logfile`,
        archiveLogDestinations => q`select destination from v$archive_dest where process = 'ARCH' 
                                    and valid_type = 'ONLINE_LOGFILE'`,
        startBackup     => q`alter database begin backup`,
        endBackup       => q`alter database end backup`,
        checkBackupMode => q`select distinct t.tablespace_name, b.status from dba_data_files t,
                            v$backup b ,dba_tablespaces tb where file_id = file# 
                            and t.tablespace_name=tb.tablespace_name and tb.STATUS != 'READ ONLY'`,
        setReadWrite    => q`alter database guard none`,
        setReadOnly     => q`alter database guard all`,
        switchLogs      => q`alter system switch logfile`,
        findCurrentLog  => q`select (select destination from v$archive_dest where dest_id=1)
                            || '*' || (select min(sequence#) from v$log
                            where status in ('ACTIVE','CURRENT'))||'.arc' from dual`,
        topio           => q`execute get_top_io()`,
        alertLogFile    => q`select a.value||'/alert_'||b.INSTANCE_NAME||'.log' from 
                            v$diag_info a, v$instance b where a.name='Diag Trace'`,
        rmanArchiveLogs => q`select destination from v$archive_dest where binding='MANDATORY'`,
        rmanDRArchiveLogs => q`select destination from v$archive_dest where dest_name='STANDBY_ARCHIVE_DEST'`,

        # Physical Replication Data Guard SQLs
        # results is  'LOGICAL STANDBY' or 'PHYSICAL STANDBY'
        physicalReplication_standbyMode     => q`select DATABASE_ROLE from v$database`,
        # results is 'MOUNTED-IDLE', 'APPLY STOP', etc
        physicalReplication_standbyStatus   => q`select decode((select open_mode from v$database)||'-'||(select recovery_mode from v$archive_dest_status where instr(DESTINATION,'oraarch_stby') > 0 and dest_name like 'LOG_ARCHIVE_DEST%' ), 'MOUNTED-IDLE','APPLY STOP','MOUNTED-MANAGED','APPLY','MOUNTED-MANAGED REAL TIME APPLY','APPLY REAL TIME','READ ONLY-IDLE','READ ONLY','READ ONLY WITH APPLY-MANAGED REAL TIME APPLY','APPLY REAL TIME OPEN','READ ONLY WITH APPLY-MANAGED','APPLY OPEN','UNKNOWN') from dual;`,
        # use "physicalReplication_standbyStatus" to check status
        physicalReplication_setReadOnlyMode => q`exec EXECUTE IMMEDIATE 
            'ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL';`,
        # use "physicalReplication_standbyStatus" to check status
        physicalReplication_setLogApplyMode => q`ALTER DATABASE RECOVER MANAGED STANDBY 
            DATABASE DISCONNECT;`,
        physicalActiveRealtimeReplication_setLogApplyMode => q`ALTER DATABASE RECOVER MANAGED STANDBY 
            DATABASE USING CURRENT LOGFILE DISCONNECT;`,
        # list of applied log file names that can be unlinked
        physicalReplication_logfilesApplied => q`select name from V$ARCHIVED_LOG where 
            REGISTRAR='RFS' and APPLIED='YES'`,
        # value is time-delay, time_computed is last sampling time
        physicalReplication_standbyLag  => q`select name, value, time_computed from 
            v$dataguard_stats where name='apply lag'`,
        physicalReplication_standbyTransportLag => q`select name, value, time_computed from 
            v$dataguard_stats where name='transport lag'`,
    );

    if ($sqlForName{$sqlQueryName}) {
    
        $sql = $sqlForName{$sqlQueryName};

    } elsif ($sqlQueryName eq "perf") {

        # perfstat/$perfstatpass@$instance
        $sql = q`execute statspack.snap()`;
        $user = "perfstat";

    } elsif ($sqlQueryName eq "shmem") {

        $sql = q`
                select 
                    decode(sign(ksmchsiz - 80), -1, 0, 
                    trunc(1/log(ksmchsiz - 15, 2)) - 5) bucket, 
                    sum(ksmchsiz) free_space, 
                    count(*) free_chunks, 
                    trunc(avg(ksmchsiz)) average_size, 
                    max(ksmchsiz) biggest 
                from 
                    sys.x$ksmsp 
                where 
                    ksmchcls = 'free' 
                group by 
                    decode(sign(ksmchsiz - 80), -1, 0, 
                    trunc(1/log(ksmchsiz - 15, 2)) - 5) 
                `;

        $pass = $mon->default("dbainfo.$user.password");

        push(@results, executeAndDisplayQueryResults(
            $user, $pass, $instance, $host, $sql, $displayResults
        ));

        # sys/$syspass@$instance
        $sql = q`
            select 
            ksmchcom contents, 
            count(*) chunks, 
            sum(decode(ksmchcls, 'recr', ksmchsiz)) 
            recreatable, 
            sum(decode(ksmchcls, 'freeabl', ksmchsiz)) 
            freeable, 
            sum(ksmchsiz) total 
            from 
            sys.x$ksmsp 
            where 
            ksmchcls not like 'R%' 
            group by 
            ksmchcom`;
    } else {
        $oracleError = "No sql defined for '$sqlQueryName'"; 
        print $oracleError, "\n" if ($debug);
    }

    $pass = $mon->default("dbainfo.$user.password");
    
    push(@results, executeAndDisplayQueryResults(
        $user, $pass, $instance, $host, $sql, $displayResults, $timeout
    )) if ($sql);

    if (wantarray()) {
        return (@results);
    } else {
        return $results[0];
    }
}

sub executeAndDisplayQueryResults {
    my ($user, $pass, $sid, $host, $sql, $displayResults, $timeout) = @_;

    my @results = ();

    my $oc = ariba::Ops::OracleClient->new($user, $pass, $sid, $host);
    $oc->connect() || do {
        $oracleError = "Error: Could not connect to $user\@$sid: " . $oc->error();
        print $oracleError, "\n" if ($debug || $displayResults);
    };

    # optionally run with a timeout.
    if (defined $timeout) {
        if ($oc->executeSqlWithTimeout($sql, $timeout, \@results)) {
            $timeoutOccured = 0;
        } else {
            $timeoutOccured = 1;
        }
    } else {
        @results = $oc->executeSql($sql);
    }

    $oracleError = undef;
    if ($oc->error()) {
        $oracleError = $oc->error();
    } elsif ($timeoutOccured) {
        $oracleError = "$sql timed out in $timeout sec(s)!";
    }

    if ($displayResults) {
        if (scalar @results > 0) {
            print join("\n", @results);
            print "\n";
        }

        if ($oracleError) {
            print("Oracle Error: $oracleError\n");
        }
    }

    $oc->disconnect();

    return (@results);
}

sub oracleError {
    return $oracleError;
}

sub timeoutOccured {
    return $timeoutOccured;
}

1;

__END__
