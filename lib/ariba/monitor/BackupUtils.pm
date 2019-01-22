package ariba::monitor::BackupUtils;

#tmid: 149039
use strict;
use warnings;
use Data::Dumper;
use Carp;

use ariba::rc::InstalledProduct;
use ariba::Ops::ProductAPIExtensions;
use ariba::Ops::OracleClient;

my $defaultStaleAge = 3600 * 24 * 1.5; #1.5 days
my $debug = 0;

sub myDebug {
    my $debugstr = shift;
    $debugstr = Data::Dumper::Dumper $debugstr if ref $debugstr;
    print STDERR "$debugstr\n";
}

#localDoSql() is meant to always be run in an eval {}
{
my $oc;
sub localDoSql {
    my $sql = shift;
    my %args = @_;
    $args{timeout} = 60 unless $args{timeout};
    if(not $oc) {
        if(not $args{service}) {
            my $me = ariba::rc::InstalledProduct->new();
            $args{service} = $me->service();
        }
        my $product = ariba::rc::InstalledProduct->new('mon', $args{service});
        $oc = ariba::Ops::OracleClient->new($product->connectInfoForOracleClient());
        $oc->connect() or confess "error, could not connect to database, product 'mon', service '$args{service}': " . $oc->error();
    }
    my $ret = [];
    $oc->executeSqlWithTimeout($sql, $args{timeout}, $ret)
        or confess "query '$sql' timed out in $args{timeout} seconds";
    confess 'oracleError: ' . $oc->error()
        if $oc->error();
    return $ret;
}
}

#to be run by backup check script
#returns 'true' if backup is running, 'false' if it is not
sub backupIsRunning {
    my %args = @_;
    confess 'required argument "hostname" not found'
        unless $args{hostname};
    confess 'required argument "product" not found'
        unless $args{product};
    confess 'required argument "service" not found'
        unless $args{service};
    my $ret;
    eval {
        $ret = localDoSql(
            "select count(1) from DATA_BACKUP_STATUS where CHECK_HOSTNAME = '$args{hostname}' and PRODUCTNAME = '$args{product}' and SERVICE = '$args{service}'",
            service => $args{service});
        myDebug $ret if $debug;
    };
    #being kind of lazy here; if this thing throws, then $ret will be 'false',
    #which leads us to the 'backup is not running' fail-back state, which is
    #what we want to do.
    return 1 if
        $ret and
        $ret->[0];
    return 0;
}

#to be run by actual DR backup script
#returns nothing
#throws on exceptions
sub finishBackupRun {
    my %args = @_;
    confess 'required argument "hostname" not found'
        unless $args{hostname};
    confess 'required argument "product" not found'
        unless $args{product};
    confess 'required argument "service" not found'
        unless $args{service};
    eval {
        localDoSql(
            "delete from DATA_BACKUP_STATUS where CHECK_HOSTNAME = '$args{hostname}' and PRODUCTNAME = '$args{product}' and SERVICE = '$args{service}'",
            service => $args{service});
    };
    #TODO: ignore zero rows removed for now; meta-alerting later
    #this is fire and forget; just make sure we don't explode
}

#to be run by actual DR backup script
#returns nothing
#throws on exceptions
sub startBackupRun {
    my %args = @_;
    confess 'required argument "hostname" not found'
        unless $args{hostname};
    confess 'required argument "product" not found'
        unless $args{product};
    confess 'required argument "service" not found'
        unless $args{service};
    $args{backupType} = 'n/a' unless $args{backupType};

    $args{staleAge} = $defaultStaleAge unless $args{staleAge};

    #blindly create the table, ignore errors
    #justification: this won't run that often, and it will remove any
    #future requirement to remember to create this table.
    eval {
        my $sql = 'create table DATA_BACKUP_STATUS(
            CHECK_HOSTNAME              varchar2(128) not null,
            PRODUCTNAME                 varchar2(128) not null,
            SERVICE                     varchar2(128) not null,
            BACKUP_TYPE                 varchar2(128) not null,
            TIME_STARTED                number not null,
            CONSTRAINT DATA_BACKUP_STATUS PRIMARY KEY (CHECK_HOSTNAME,PRODUCTNAME,SERVICE)
        )';
        localDoSql($sql, service => $args{service});
    };

    #insert record for this run
    #if that fails with a constraint violation, then:
    #   a. pull the time-stamp
    #   b. check to see if it is stale
    #   c. if it is stale, issue an update and proceed
    #   d. if it is not stale, blow up
    eval {
        my $time = time;
        my $sql = qq(insert into DATA_BACKUP_STATUS(
                CHECK_HOSTNAME, 
                PRODUCTNAME,
                SERVICE,
                BACKUP_TYPE,
                TIME_STARTED
            ) values (
                '$args{hostname}',
                '$args{product}',
                '$args{service}',
                '$args{backupType}',
                $time
            )
        );
        my $ret;
        eval {
            $ret = localDoSql($sql, service => $args{service});
        };
        if($@) {
            if($@ =~ /unique constraint .*? violated/) {
                die "constraint violation\n"
            } else {
                die $@;
            }
        }
        myDebug $ret if $debug;
    };
    if(my $err = $@) {
        if($err eq "constraint violation\n") {
            myDebug "\$err=$err\n" if $debug;
            my $rowTime;
            eval {
                my $ret = localDoSql(
                    "select TIME_STARTED from DATA_BACKUP_STATUS where CHECK_HOSTNAME = '$args{hostname}' and PRODUCTNAME = '$args{product}' and SERVICE = '$args{service}'",
                    service => $args{service}
                );
                $rowTime = $ret->[0];
            };
            confess "select failed: $@" if $@;
            my $tupleStr = "existing row with primary key tuple ('$args{hostname}','$args{product}','$args{service}') has TIME_STARTED value $rowTime (\$args{staleAge}=$args{staleAge})";
            if($rowTime + $args{staleAge} > time) { #not stale; re-throw
                confess "$tupleStr: is not stale";
            }
            myDebug "$tupleStr: is stale. updating TIME_STARTED" if $debug;
            eval {
                my $time = time;
                my $ret = localDoSql(
                    "update DATA_BACKUP_STATUS set TIME_STARTED = $time where CHECK_HOSTNAME = '$args{hostname}' and PRODUCTNAME = '$args{product}' and SERVICE = '$args{service}'",
                    service => $args{service});
                myDebug $ret if $debug;
            };
            confess "update failed: $@" if $@;
        } else { #some other exception; re-throw
            confess $@;
        }
    }
}
1;
__END__

if($run_type eq 'normal') {
    #PRE:
    my_say 'backupIsRunning() pre:';
    my_say Dumper backupIsRunning(product => $product, service => $service);

    my_say 'table dump pre:';
    my_say Dumper localDoSql('select * from DATA_BACKUP_STATUS');

    #DURING
    startBackupRun(product => $product, service => $service, backupType => $backupType);

    my_say 'backupIsRunning() during:';
    my_say Dumper backupIsRunning(product => $product, service => $service);

    my_say 'table dump during:';
    my_say Dumper localDoSql('select * from DATA_BACKUP_STATUS');


    #AFTER
    finishBackupRun(product => $product, service => $service);

    my_say 'backupIsRunning() after:';
    my_say Dumper backupIsRunning(product => $product, service => $service);

    my_say 'table dump after:';
    my_say Dumper localDoSql('select * from DATA_BACKUP_STATUS');
    exit 0;
}

if($run_type eq 'backup_run_crashes') {
    #PRE:
    my_say 'backupIsRunning() pre:';
    my_say Dumper backupIsRunning(product => $product, service => $service);

    my_say 'table dump pre:';
    my_say Dumper localDoSql('select * from DATA_BACKUP_STATUS');

    #DURING
    startBackupRun(product => $product, service => $service, backupType => $backupType);

    my_say 'backupIsRunning() during:';
    my_say Dumper backupIsRunning(product => $product, service => $service);

    my_say 'table dump during:';
    my_say Dumper localDoSql('select * from DATA_BACKUP_STATUS');


    #CRASHED
    #finishBackupRun(product => $product, service => $service);

    #RE-RUN BACKUP
    startBackupRun(product => $product, service => $service, backupType => $backupType);
    exit 0;
}
=head1 BASIC FLOW

=over 4

=item * backup script runs startBackupRun()

=item * backup script does its thing

=item * backup script runs finishBackupRun()

=item * check script runs backupIsRunning()

=over 4

=item * if returns true, then backup is running

=item * if returns false, then backup is not running

=back

=item * $profit$

=back

=head1 SCHEMA

create table DATA_BACKUP_STATUS(
    CHECK_HOSTNAME              varchar2(128) not null,
    PRODUCTNAME                 varchar2(128) not null,
    SERVICE                     varchar2(128) not null,
    BACKUP_TYPE                 varchar2(128) not null,
    TIME_STARTED                number not null,
    CONSTRAINT OPSMETRICS_PK    PRIMARY KEY
                                    (   CHECK_HOSTNAME,
                                        PRODUCTNAME,
                                        SERVICE)
);

=over 4

=item CHECK_HOSTNAME

hostname of the DB running the backup

=item PRODUCTNAME

the product being backed up

=item SERVICE

the service being backed up

=item BACKUP_TYPE

the type of backup (incrementalPhysical, etc)

=item TIME_STARTED

epoch timestamp of the beginning of the backup

=back

=head1 OPEN QUESTIONS

=over 4

=item backupIsRunning() does not check for staleness

Should it?  That can be added; my first thought is to let the backup script itself handle that.  But does the backup script do any alerting?

If not, then backupIsRunning() needs to check staleness

=item more error handling

Is there a better way to check for DB errors than regexes?

=back

=cut
__END__
raw notes
'schema':
Example cron entries:
root@db35 ~ $ crontab -l|grep -v ^#|grep -i back
0 16 * * 4 /usr/local/ariba/bin/crontab-wrapper /usr/local/ariba/bin/bcv-backup -e -p -incrementalPhysical -bcv 1 acm prod
0 2,14 * * * /usr/local/ariba/bin/crontab-wrapper /usr/local/ariba/bin/bcv-backup -e -p -snap -bcv 2 acm prod
0 20 * * 4 /usr/local/ariba/bin/crontab-wrapper /usr/local/ariba/bin/bcv-backup -e -p -incrementalPhysical -bcv 1 aes prod
0 6,18 * * * /usr/local/ariba/bin/crontab-wrapper /usr/local/ariba/bin/bcv-backup -e -p -snap -bcv 2 aes prod
0 19 * * 4 /usr/local/ariba/bin/crontab-wrapper /usr/local/ariba/bin/bcv-backup -e -p -incrementalPhysical -bcv 1 an prod
0 5,17 * * * /usr/local/ariba/bin/crontab-wrapper /usr/local/ariba/bin/bcv-backup -e -p -snap -bcv 2 an prod
0 2 * * 4 /usr/local/ariba/bin/crontab-wrapper /usr/local/ariba/bin/bcv-backup -e -p -incrementalPhysical -bcv 1 anl prod
0 0,12 * * * /usr/local/ariba/bin/crontab-wrapper /usr/local/ariba/bin/bcv-backup -e -p -snap -bcv 2 anl prod
0 6 * * 4 /usr/local/ariba/bin/crontab-wrapper /usr/local/ariba/bin/bcv-backup -e -p -incrementalPhysical -bcv 1 buyer prod
0 4,16 * * * /usr/local/ariba/bin/crontab-wrapper /usr/local/ariba/bin/bcv-backup -e -p -snap -bcv 2 buyer prod
0 1 * * 4 /usr/local/ariba/bin/crontab-wrapper /usr/local/ariba/bin/bcv-backup -e -p -incrementalPhysical -bcv 1 edi prod
0 11,23 * * * /usr/local/ariba/bin/crontab-wrapper /usr/local/ariba/bin/bcv-backup -e -p -snap -bcv 2 edi prod
0 22 * * 4 /usr/local/ariba/bin/crontab-wrapper /usr/local/ariba/bin/bcv-backup -e -p -incrementalPhysical -bcv 1 mon prod
0 8,20 * * * /usr/local/ariba/bin/crontab-wrapper /usr/local/ariba/bin/bcv-backup -e -p -snap -bcv 2 mon prod
0 15 * * 4 /usr/local/ariba/bin/crontab-wrapper /usr/local/ariba/bin/bcv-backup -e -p -incrementalPhysical -bcv 1 perf prod
0 1,13 * * * /usr/local/ariba/bin/crontab-wrapper /usr/local/ariba/bin/bcv-backup -e -p -snap -bcv 2 perf prod
0 0 * * 4 /usr/local/ariba/bin/crontab-wrapper /usr/local/ariba/bin/bcv-backup -e -p -incrementalPhysical -bcv 1 piwik prod
0 10,22 * * * /usr/local/ariba/bin/crontab-wrapper /usr/local/ariba/bin/bcv-backup -e -p -snap -bcv 2 piwik prod
0 11 * * 4 /usr/local/ariba/bin/crontab-wrapper /usr/local/ariba/bin/bcv-backup -e -p -incrementalPhysical -bcv 1 s2 prod
0 9,21 * * * /usr/local/ariba/bin/crontab-wrapper /usr/local/ariba/bin/bcv-backup -e -p -snap -bcv 2 s2 prod
0 5 * * 4 /usr/local/ariba/bin/crontab-wrapper /usr/local/ariba/bin/bcv-backup -e -p -incrementalPhysical -bcv 1 s4 prod
0 3,15 * * * /usr/local/ariba/bin/crontab-wrapper /usr/local/ariba/bin/bcv-backup -e -p -snap -bcv 2 s4 prod
0 3 * * 4 /usr/local/ariba/bin/crontab-wrapper /usr/local/ariba/bin/bcv-backup -e -p -incrementalPhysical -bcv 1 sdb prod
0 2,14 * * * /usr/local/ariba/bin/crontab-wrapper /usr/local/ariba/bin/bcv-backup -e -p -snap -bcv 2 sdb prod
root@db35 ~ $

create table DATA_BACKUP_STATUS(
    CHECK_HOSTNAME              varchar2(128) not null,
    PRODUCTNAME                 varchar2(128) not null,
    SERVICE                     varchar2(128) not null,
    BACKUP_TYPE                 varchar2(128) not null,
    TIME_STARTED                number not null,
    CONSTRAINT OPSMETRICS_PK    PRIMARY KEY (CHECK_HOSTNAME,PRODUCTNAME,SERVICE)
);

CHECK_HOSTNAME: where the backup script runs from
PRODUCTNAME: sdb/s4/etc
SERVICE: prod/dev/etc
BACKUP_TYPE: incrementalPhysical, others?
TIME_STARTED: epoch time: 1234567890

Consider this invocation:
/usr/local/ariba/bin/bcv-backup -e -p -incrementalPhysical -bcv 1 sdb prod
on db35.snv, the table will contain, while the script is running:

insert into DATA_BACKUP_STATUS(
    CHECK_HOSTNAME, PRODUCTNAME, SERVICE, BACKUP_TYPE, TIME_STARTED
) values (
    'db35.snv.ariba.com','sdb','prod','incrementalPhysical',1234567890
);


The row will be deleted when the backup script is no longer running.
