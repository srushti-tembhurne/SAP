package ariba::Ops::ProductConfig::Hana;

use strict;
use Data::Dumper;
use Storable;
use Carp qw(confess);
use Time::Local;

use base qw(ariba::Ops::ProductConfig);
use ariba::Ops::ProductConfig::Constants qw(:all);
use ariba::Ops::ProductConfig::Utils qw(:all);

use ariba::Ops::HanaClient;
use ariba::rc::CipherStore;
use ariba::rc::Utils qw(executeLocalCommand);

### constants specific to this class
use constant TMP_MON => qw(/tmp/monitor_db.hana);

### everything can be derived from this starting point
use constant SAPSERVICES => '/usr/sap/sapservices';

use constant {
    ROLE_MASTER  => 'master',
    ROLE_SLAVE   => 'slave',
    ROLE_STANDBY => 'standby',
};

my %VALID_ROLES = (
    ROLE_MASTER()  => ROLE_MASTER,
    ROLE_SLAVE()   => ROLE_SLAVE,
    ROLE_STANDBY() => ROLE_STANDBY,
);

sub new
{
    my ($class, $args) = @_;

    my $self = $class->SUPER::new($args);

    $self->logger()->debug(func());

    $self->{sids}      = [];
    $self->{apps}      = {};
    $self->{extracted} = FALSE;
    $self->db_type(HANA_TYPE);

    bless $self, $class;
}

sub get_services_config {
    my ($self) = shift;

    my $func   = func();
    my $logger = $self->logger();
    $logger->debug($func);

    unless(-f SAPSERVICES) {
        $logger->error("$func: can't find '@{[SAPSERVICES]}'");
        return;
    }

    my @data;
    unless(slurp_file(SAPSERVICES, \@data)) {
        $logger->error("$func: failed to read @{[SAPSERVICES()]}: @data");
        return;
    }

    my %sid_info = ();
    for my $line (@data) {
        $line =~ s/^\s+//;
        next if $line =~ /^#/;

        my ($exepath) = $line =~ m|(/[\w/]+/exe)/|;
        next unless $exepath;

        my @t = split('/', $exepath);
        my $n = $#t - 1;
        my $inst = $t[$n--];
        my $sid = $t[$n--];
        my $path = join('/', @t[0..$n]);
        next unless $inst && $sid && $path;

        my $uid = lc($sid) . "adm";
        my ($inst_id) = $inst =~ /(\d+)/;

        # per SAP hana specs:
        #   legacy (single-container) port is always concat of "3", instance ID, and "15".
        #   MDC sysdb port is always concat of "3", instance ID, and "13".
        #
        # from the info in /usr/sap/sapservices, there's no way to tell whether this is a
        # single-container or MDC deployment, so we'll set both in the hash.

        # Later on, when we try to connect, we first try the sysdb port, and if that fails,
        # we try the single-container port. If we get a sysdb port connection, we know this
        # is an MDC deployment, in which case we should CLEAR the sql_port, because it must
        # be gotten by other MDC sysdb-specific queries.
        my $port       = '3' . $inst_id . '15';
        my $sysdb_port = '3' . $inst_id . '13';

        ### for single-container hana, dbname == sid.
        ### but we will have to revisit this for multitenant.
        my $dbname = $sid;

        my %sid_info = (
                'sid'      => $sid,
                'db_name'  => $dbname,
                'basepath' => $path,
                'exepath'  => $exepath,
                'admin_id' => $uid,
                'sql_port'   => $port,
                'sysdb_port' => $sysdb_port,
        );
        push(@{$self->{sids}}, \%sid_info);
    }
    return @{$self->{sids}};
}

sub get_MDC_config {
    my ($self) = shift;

    my $func   = func();
    my $logger = $self->logger();
    $logger->debug($func);

    my $mon     = $self->mon();
    my $user = "system";
    my $db_user = $mon->default("dbainfo.hana.$user.username");
    my $db_pass = $mon->default("dbainfo.hana.$user.password");
    my $sql = qq(select a.database_name,a.host,a.sql_port,a.coordinator_type,b.OS_USER)
            . qq( from sys_databases.m_services a , m_databases b where a.database_name = b.DATABASE_NAME)
            . qq( and a.service_name = 'indexserver' and  b.active_status = 'YES')
            . qq( and b.database_name != 'SYSTEMDB');

    my $host = $self->node_info()->{host};
    my $rc;
    for my $sid (@{$self->{sids}}) {
        my $sid_name = $sid->{sid};
        my $db_port = $sid->{sysdb_port};
        my $dbc = $self->connect($sid_name, $host, $db_port, $db_user, $db_pass);
        unless ( $dbc ){
            $logger->warn("$func: failed to connect to sid '$sid_name', skipping...");
            return;
        }
        my @data;
        eval { $dbc->executeSqlWithTimeout($sql, 10, \@data); };
        $sid->{dbcHandle} = $dbc;

        for my $line (@data){
            my ($dbName,$host, $port, $role,$osUser) = split(/\s+/, lc($line));
            next unless $VALID_ROLES{$role};

            $host = "$host." . $self->node_info()->{domain} unless $host =~ /\./;
            $sid->{DB_NAME}->{$dbName}->{slaves} = [];
            if ($role eq ROLE_MASTER) {
                $sid->{DB_NAME}->{$dbName}->{master} = $host;
                $sid->{DB_NAME}->{$dbName}->{sql_port} = $port;
                $sid->{DB_NAME}->{$dbName}->{os_user} = $osUser;
                $sid->{master} = $host unless $sid->{master};
            }elsif($role eq ROLE_SLAVE) {
                push @{$sid->{DB_NAME}->{$dbName}->{slaves}}, $host;
            }elsif($role eq ROLE_STANDBY) {
                push @{$sid->{DB_NAME}->{$dbName}->{standbys}}, $host;
            }
            $rc = TRUE;
        }
    }
    return $rc;
}

sub query_sids {
    my ($self) = shift;

    my $func   = func();
    my $logger = $self->logger();
    $logger->debug($func);

    my $sql     = "select name,DBNAME from @{[APP_TABLE()]}";

    my $rc;
    for my $sid (@{$self->{sids}}) {
        my @data;
        eval { $sid->{dbcHandle}->executeSqlWithTimeout($sql, 10, \@data); };
        $logger->warn("$func: error: '$@'") if($@ && $@ !~ /not found/);

        ### one app per row
        for my $line (@data) {
            $rc = TRUE;  # we have something to monitor!
            my ($app,$dbName) = split(/\s+/, lc($line));
            push(@{$sid->{DB_NAME}->{$dbName}{apps}}, $app);
        }
        $sid->{dbcHandle}->disconnect();
    }
    return $rc;
}

### our native hana connect method
sub connect {
    my ($self, $sid, $host, $port, $user, $pass) = @_;

    my $func   = func();
    my $logger = $self->logger();
    $logger->debug("$func: Connecting to sid=$sid, host=$host, port=$port, user=$user");

    my $hc = ariba::Ops::HanaClient->new($user, $pass, $host, $port);
    $hc->connect(10, 3);
    return unless ($hc->handle());
    $hc->handle()->{RaiseError} = TRUE;
    $hc->handle()->{PrintError} = FALSE;
    $hc->handle()->{AutoCommit} = TRUE;
    return $hc;
}

sub extract {
    my ($self) = shift;

    my $func   = func();
    my $logger = $self->logger();
    $logger->debug($func);

    $logger->logdie("$func: failed to get services config")  unless $self->get_services_config();
    $logger->logdie("$func: failed to get MDC config")       unless $self->get_MDC_config();
    $logger->logdie("$func: failed to query SIDs")           unless $self->query_sids();

    ### set extracted=true so that we can be ready for direct upload
    $self->setExtracted();
    $self->write_data_to_disk();

    ### run the upload
    $self->upload();
}

sub setExtracted {
    my ($self) = shift;
    $self->{extracted} = TRUE;
}

sub extracted {
    my ($self) = shift;
    return $self->{extracted};
}

sub loaded {
    my ($self, $val) = @_;
    $self->{_data} = $val if $val;
    return $self->{_data};
}

### write failure is non-critical because
### we still have data in mem for upload
sub write_data_to_disk {
    my ($self) = shift;

    my $func   = func();
    my $debug  = $self->debug();
    my $logger = $self->logger();
    $logger->debug($func);

    return unless $self->extracted();

    my $data;
    return unless $data = $self->format_data_for_write();
    $self->loaded($data);

    unless(store($data, TMP_MON)) {
        $logger->error("$func: write failed: $@ ($!)");
        return;
    }
    $logger->info("$func: wrote topology data to '@{[TMP_MON()]}'");
    return TRUE;
}

sub format_data_for_write {
    my ($self) = shift;

    my $func   = func();
    my $logger = $self->logger();
    $logger->debug($func);

    my $host     = $self->node_info()->{fqdn};
    my $mon_host = '-'; # should be set at gen-config time

    my @data;
    for my $sid (@{$self->{sids}}) {
        for my $dbName (keys %{$sid->{DB_NAME}}){
            print "dbName $dbName\n";
            next unless ($sid->{DB_NAME}->{$dbName}->{apps});

            my %h = (
                source_host   => $host,
                mon_host      => $mon_host,
                sid           => $sid->{sid},
                db_name       => $dbName,
                sql_port      => $sid->{DB_NAME}->{$dbName}->{sql_port},
                host_primary  => $sid->{DB_NAME}->{$dbName}->{master},
                app_name      => @{$sid->{DB_NAME}->{$dbName}->{apps}}     ? join(',', sort @{$sid->{DB_NAME}->{$dbName}->{apps}})     : '',
                host_slave    => defined $sid->{DB_NAME}->{$dbName}->{slaves}   ? join(',', sort @{$sid->{DB_NAME}->{$dbName}->{slaves}})   : '',
                host_failover =>  defined $sid->{DB_NAME}->{$dbName}->{standbys}   ? join(',', sort @{$sid->{DB_NAME}->{$dbName}->{standbys}})   : '',
                admin_id => $sid->{DB_NAME}->{$dbName}->{os_user},
            );
            push(@data, \%h);
        }
    }
    return @data ? \@data : undef;
}

sub load_data_from_disk {
    my ($self) = shift;

    my $func   = func();
    my $logger = $self->logger();
    $logger->debug($func);

    ### stat times are in GMT seconds since the epoch
    my ($file_age) = (stat(TMP_MON))[9] || $logger->logdie("$func: load '@{[TMP_MON()]}' failed: $!");
    $logger->logdie("$func: '@{[TMP_MON()]}': stale data") if $file_age < time() - UPLOAD_MAX_AGE;
    $logger->logdie("$func: load failed") unless my $data = retrieve(TMP_MON);
    return $data;
}

sub mondb_upsert_row {
    my ($self, $h, $dbh) = @_;

    my $func   = func();
    my $logger = $self->logger();
    $logger->debug($func);
    my $app_dbtype = $self->db_type();

    my $sql = qq`
        begin
            insert into @{[MON_TABLE()]}(sid, db_name, app_name, source_host, mon_host, sql_port,app_dbtype, host_primary, host_failover, host_slave, enabled,admin_id) 
            values(\'$h->{sid}\', \'$h->{db_name}\', \'$h->{app_name}\', \'$h->{source_host}\', \'$h->{mon_host}\', \'$h->{sql_port}\', \'$app_dbtype\',\'$h->{host_primary}\', \'$h->{host_failover}\', \'$h->{host_slave}\',\'Y\',\'$h->{admin_id}\');
        exception
        when dup_val_on_index then
            update @{[MON_TABLE()]} 
            set source_host = \'$h->{source_host}\', mon_host = \'$h->{mon_host}\', 
                app_name = \'$h->{app_name}\', sql_port = \'$h->{sql_port}\', 
                host_primary = \'$h->{host_primary}\', host_failover = \'$h->{host_failover}\', 
                host_slave = \'$h->{host_slave}\', last_updated = sysdate,
                enabled = 'Y', admin_id=\'$h->{admin_id}\'
            where sid = \'$h->{sid}\' and db_name = \'$h->{db_name}\' and app_dbtype = \'$app_dbtype\';
        end;`;

    $logger->debug("$func: sql = '$sql'");
    eval {
        my $sth = $dbh->prepare($sql) || die $dbh->errstr;
        $sth->execute() || die $dbh->errstr;
        $dbh->commit();
    };
    if($@) {
        $dbh->rollback();
        $dbh->disconnect();
        $logger->logdie("$func: update failed: $@");
    }
}

sub upload {
    my ($self) = shift;

    my $func   = $self->func();
    my $logger = $self->logger();
    $logger->debug($func);

    my $data;
    ### if we're fresh off an extract, no need to load from disk.
    if($self->extracted()) {
        $data = $self->loaded();
    } else {
        $data = $self->load_data_from_disk();
    }

    unless($data && @{$data}) {
        $logger->warn("$func: no data");
        return;
    }

    my $ch     = $self->connect_to_mondb_as_monuser();
    my $dbh    = $ch->handle();

    for my $h (@{$data}) {
        ### insert row, if exist then update
        $self->mondb_upsert_row($h, $dbh);
    }
    $ch->disconnect();
}

sub mondb_get_app_data {
    my ($self, $dbh) = @_;

    my $func   = func();
    my $logger = $self->logger();
    $logger->debug($func);

    my $sql = qq<select sid, db_name, app_name, host_primary, host_failover, host_slave, mon_host, sql_port,>
            . qq< (to_char(last_updated, 'SS MI HH24 DD MM YYYY')) as last_updated, enabled,admin_id from @{[MON_TABLE()]}>
            . qq< where app_name is not null and app_dbtype = ? order by sid, db_name, app_name>;

    $logger->debug("$func: sql = '$sql'");

    my $data;
    eval {
        $dbh->{FetchHashKeyName} = 'NAME_lc';
        my $sth = $dbh->prepare($sql);
        $sth->execute($self->db_type());
        $data = $sth->fetchall_arrayref({});
    };
    $logger->logdie("$func: select failed: $@") if($@);

    ### weed out stale records
    my @filtered;
    my $cutoff_time = time() - GENCONFIG_MAX_AGE;
    for my $row (@{$data}) {
        my ($sid, $apps) = ($row->{sid}, $row->{app_name});
        my @d = split(' ', $row->{last_updated});
        $d[4]--; # perl indexes month field at 0
        my $row_last_updated = timelocal(@d);
        unless($row_last_updated >= $cutoff_time) {
            $logger->warn("$func: skipping stale row (sid=$sid apps=$apps last_updated=$row_last_updated)");
            next;
        }
        push(@filtered, $row);
    }
    return @filtered ? \@filtered : undef;
}

### generate the DD.xml and roles.cfg configs for this dbtype.
sub gen_config {
    my ($self) = @_;

    my $func   = func();
    my $logger = $self->logger();
    $logger->debug($func);

    my $service = $self->mon()->service();
    my $ch      = $self->connect_to_mondb_as_monuser();
    my $dbh     = $ch->handle();

    my $data;
    unless($data = $self->mondb_get_app_data($dbh)) {
        $logger->warn("$func: no data found.");
        return undef;
    }

    my $monhost = $self->monserver();
    my $bkp_monhost = $self->backup_monserver();
    my $mon_dom = join('.', splice(@{[split(/\./, $monhost)]}, 1));

    my $dr_db_role_pfx  = 'dr-';
    my $have_secondary  = FALSE;

    my $ds = {};
    my %idx;
    for my $row (@{$data}) {
        my $master   = $row->{host_primary};
        my $slaves   = $row->{host_slave};
        my $standbys = $row->{host_failover};
        my $hosts    = $master;
        $hosts      .= ",$slaves" if $slaves;
        $hosts      .= ",$standbys" if $standbys;

        ### if this host's domain matches the mon host's domain, then we're primary, else we're secondary.
        my $dom = join('.', splice(@{[split(/\./, $master)]}, 1));

        my ($pri_db_role_pfx, $sec_db_role_pfx, $dbc_pfx) = '';
        if($dom eq $mon_dom) { # this entry is a 'ary relative to us
            $sec_db_role_pfx  = $dr_db_role_pfx;
        }
        else { # this entry is a 2ndary relative to us
            $dbc_pfx          = 'DR';
            $pri_db_role_pfx  = $dr_db_role_pfx;
            $have_secondary   = TRUE;
        }

        ### this is "pre-connect-time" static config, so hanaHosts should contain all hosts (including standbys)
        my %h = (
            userName  => 'system',
            serverID  => $row->{sid},
            dbName    => $row->{db_name},
            port      => $row->{sql_port},
            hostName  => $master,
            slaves    => $slaves,
            standbys  => $standbys,
            hanaHosts => $hosts,
            adminID   => $row->{admin_id},
        );

        # hanadatabasehosts* needs to be whitespace-separated
        my $role_hosts = $hosts;
        $role_hosts =~ tr/,/ /;

        ### SID can house more than one app, comma-separated.
        for my $app (split(',', lc($row->{app_name}))) {
            my $i = \$idx{$app}{pri}; $$i = '' unless $$i;
            my $j = \$idx{$app}{sec}; $$j = '' unless $$j;

            my $idx = $dbc_pfx ? $j : $i; # if $dbc_pfx is set, we're dealing with a 2ndary
            push(@{$ds->{$app}->{DBConnections}->{"${dbc_pfx}hana$$idx"}}, \%h);

            $ds->{$app}->{roles}->{primary}->{'monitor'} = $monhost if $monhost;
            $ds->{$app}->{roles}->{primary}->{'backup-monitor'} = $bkp_monhost if $bkp_monhost;
            $ds->{$app}->{roles}->{primary}->{"${pri_db_role_pfx}hanadatabase$$idx"} = $h{hostName};
            $ds->{$app}->{roles}->{primary}->{"${pri_db_role_pfx}hanadatabasehosts$$idx"} = $role_hosts;

            $ds->{$app}->{roles}->{secondary}->{'monitor'} = $bkp_monhost if $bkp_monhost;
            $ds->{$app}->{roles}->{secondary}->{'backup-monitor'} = $monhost if $monhost;
            $ds->{$app}->{roles}->{secondary}->{"${sec_db_role_pfx}hanadatabase$$idx"} = $h{hostName};
            $ds->{$app}->{roles}->{secondary}->{"${sec_db_role_pfx}hanadatabasehosts$$idx"} = $role_hosts;
            $ds->{$app}->{enabled} = $row->{enabled};

            ### For Reasons Unknown, the existing configs skip "1", so we
            ### will mimic it by using the following hokey adder checker.
            $$idx ? $$idx += 1 : $$idx += 2;
        }
    }

    ### no need to write 2ndary cluster info if we don't have any
    unless($have_secondary) { for my $app (keys %$ds) { delete $ds->{$app}->{roles}->{secondary}; } }

    return %$ds ? $ds : undef;
}

TRUE;
