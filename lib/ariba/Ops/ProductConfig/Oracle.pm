package ariba::Ops::ProductConfig::Oracle;

use strict;
use Data::Dumper;

use base qw(ariba::Ops::ProductConfig);
use Carp                                    qw(confess);

use ariba::Ops::ProductConfig::Constants    qw(:all);
use ariba::Ops::ProductConfig::Utils        qw(:all);
use ariba::Ops::NetworkUtils;
use ariba::Ops::OracleClient;
use ariba::Ops::Machine;
use ariba::rc::CipherStore;
use ariba::rc::Utils;

### constants specific to this class
use constant TNSNAMES => qw(/etc/tnsnames.ora);
use constant ORATAB   => qw(/etc/oratab);
use constant TMP_MON  => qw(/tmp/monitor_db.oracle);

sub new
{
    my ($class, $args) = @_;

    my $debug = $args->{debug};

    my $self = $class->SUPER::new($args);
    
    $self->logger()->info(func());

    $self->{dbtype}          = ORACLE_TYPE;
    $self->{db_sids}         = [];
    $self->{tnsnames}        = {};
    $self->{veritas}         = {};
    $self->{sid_product_map} = {};

    bless $self, $class;
}

sub sids
{
    my ($self) = shift;

    ### populate when its empty
    $self->parse_oratab() unless (scalar (@{$self->{db_sids}}));

    wantarray () ? return (@{$self->{db_sids}}) : return ($self->{db_sids});
}

sub tnsnames
{
    my ($self) = shift;

    ### Populate the hash
    $self->parse_tnsnames() unless (scalar (keys %{$self->{tnsnames}}));

    return ($self->{tnsnames});
}

sub veritas
{
    my ($self) = shift;

    ### Populate hash
    $self->parse_veritas_config() unless (scalar (keys %{$self->{veritas}}));

    return ($self->{veritas});
}

sub sid_product_map
{
    my ($self) = shift;

    $self->map_sid_to_product() unless (scalar (keys %{$self->{sid_product_map}}));

    return ($self->{sid_product_map});
}

sub tnsnames_file
{
    return TNSNAMES;
}

sub oratab_file
{
    return ORATAB;
}

sub upload
{
    my ($self) = @_;

    my $func   = func();
    my $debug  = $self->debug();
    my $logger = $self->logger();
    $logger->info("Calling $func");

    my $db_type = $self->{dbtype};
    my $oc      = $self->connect_to_mondb_as_monuser();
    my $dbh     = $oc->handle();

    ### Open flat file to read
    open (my $inp, "<", TMP_MON) || die "Unable to open file: " . TMP_MON . "\n";
    my @all_data = <$inp>;
    close ($inp);

    $logger->info("$func: Beginning to upload in db");

    ### upload the data
    foreach my $line (@all_data)
    {
        ### SID,APP_NAME,VIP,DB_HOST,PORT,SOURCE_HOST,MON_HOST,ROLES.cfg info ( will have primary failover nodes )
        chomp ($line);
        my (@line) = split (',', $line, -1);

        ### convert to ds
        my $line_hash;
        $line_hash->{sid}          = $line[0];
        $line_hash->{app_name}     = $line[1];
        $line_hash->{vip}          = $line[2];
        $line_hash->{db_host}      = $line[3];
        $line_hash->{port}         = $line[4];
        $line_hash->{source_host}  = $line[5];
        $line_hash->{mon_host}     = $line[6];
        $line_hash->{primary_host} = $line[3];

        ### If db host not present, then its vip format (primary, failover)
        unless ($line_hash->{db_host})
        {
            ### roles.cfg will have 2 parts : primary/failover
            my @roles = split (/\s/, $line[-1]);
            $line_hash->{primary_host}  = $roles[0];
            $line_hash->{failover_host} = $roles[1];
        }

        ### If vip and primary_host are null, toss the record from flat file
        next unless ( $line_hash->{vip} || $line_hash->{primary_host} );

        ### insert row, if exist then update
	$self->mondb_upsert_row($line_hash, $dbh);
    }
    $dbh->disconnect();

    return 1;
}

sub mondb_upsert_row {

    my ($self, $lh, $dbh) = @_;

    my $func   = func();
    my $logger = $self->logger();
    $logger->info("$func: insert-updating record...");

    ### Get all the values
    my $sid           = $lh->{sid};
    my $app_name      = $lh->{app_name};
    my $vip           = $lh->{vip};
    my $port          = $lh->{port};
    my $primary_host  = $lh->{primary_host};
    my $failover_host = $lh->{failover_host};
    my $source_host   = $lh->{source_host};
    my $mon_host      = $lh->{mon_host};
    my $db_type       = $self->{dbtype};

    my $mon_table = ariba::Ops::ProductConfig::Constants::MON_TABLE;
    my $sql = qq`
        begin
            dbms_output.put_line('inserting record');
            insert into $mon_table(sid, app_name, app_dbtype, vip, sql_port, host_primary, host_failover, source_host, mon_host)values (\'$sid\', \'$app_name\', \'$db_type\', \'$vip\', \'$port\', \'$primary_host\', \'$failover_host\', \'$source_host\', \'$mon_host\');
        exception
        when dup_val_on_index then
            dbms_output.put_line('updateing record');
            update $mon_table set sid = \'$sid\', app_name = \'$app_name\', vip = \'$vip\', sql_port =\'$port\', host_primary = \'$primary_host\', host_failover = \'$failover_host\', source_host = \'$source_host\', mon_host = \'$mon_host\', last_updated = sysdate where sid = \'$sid\' and app_dbtype = \'$db_type\' and (app_name is null or app_name = \'$app_name\' ) and ( vip is null or vip = \'$vip\');
        end;`;

    eval {
        $logger->debug("$func: sql: $sql");
        my $sth = $dbh->prepare($sql);
        $sth->execute();
        $sth->finish();
        $logger->info("Commiting upsert ...");
        $dbh->commit();
    };

    if ($@)
    {
        $dbh->rollback();
        $dbh->disconnect();
        $logger->logdie("Error:$@");
    }
}

sub extract
{
    my ($self) = @_;

    my $func   = func();
    my $debug  = $self->debug();
    my $logger = $self->logger();
    $logger->info($func);

    ### Get all db_sids
    my $db_sids = $self->sids();
    $logger->debug("DB Sids:". Dumper($db_sids));

    ### Get tnsnames ds
    my $tnsnames = $self->tnsnames();
    $logger->debug("Tns Name :". Dumper($tnsnames));

    ### Get veritas config
    my $veritas = $self->veritas();
    $logger->debug("Veritas Info :". Dumper($veritas));

    ### Get sid to product info
    my $sid_2_product = $self->sid_product_map();
    $logger->info("Product to sid mapping :". Dumper($sid_2_product));

    ### Get flipped monhost name 
    my $mon_host = $self->get_flipped_info($self->monserver(), $self->backup_monserver() );

    ### Write the file
    open (my $fo, ">", TMP_MON) || die "can't write \n";
    $logger->info("Writing on to file: ". TMP_MON);
    foreach my $sid (@{$db_sids})
    {
        ### SID,APP_NAME,VIP, DB_HOST,PORT,SOURCE_HOST,MON_HOST,ROLES.cfg info ( will have primary failover nodes )
        my ( $vip, $db_host );
        if ( $veritas->{$sid} ) {
            ### Use "SID_A" or "SID_B" depending on current host's datacenter
            $vip = $self->get_flipped_info($tnsnames->{"$sid". "_A"}->[0], $tnsnames->{"$sid". "_B"}->[0]);
        } else {
            $db_host = $tnsnames->{$sid}->[0];
        }
        print $fo "$sid,$sid_2_product->{$sid},$vip,$db_host,$tnsnames->{$sid}->[1],$tnsnames->{$sid}->[2],$mon_host,$veritas->{$sid}\n";
    }
    $logger->info("Done writing");
    close ($fo);
}

### This function returns data that matches the domain
### For e.g SID_A or SID_B which ever matches the host's datacenter
### e.g between monserver and backup_monserver, return the one that matches host's datacenter
sub get_flipped_info
{
    my ($self,$host_a, $host_b) = @_;

    ### Get current hosts data center
    my $cur_host     = ariba::Ops::NetworkUtils::hostname();
    my $host_machine = ariba::Ops::Machine->new($cur_host);
    my $host_dc      = lc($host_machine->datacenter());

    my @host_a = split(/\./, $host_a);
    my @host_b = split(/\./, $host_b);

    ( $host_a[1] eq $host_dc ) ? return $host_a : return $host_b;
}

sub parse_oratab
{
    my ($self, $debug) = @_;

    ### Open oratab and grab all the sids
    my $oratab = $self->oratab_file();

    open (my $fh, "<", $oratab) || die "ERROR: Couldn't open $oratab file \n";

    my @sids = ();
    while (my $line = <$fh>)
    {
        chomp ($line);

        ### Ignore comments and empty lines
        next if ($line =~ m/^\s*#/ || $line =~ m/^\s*$/ || $line =~ m/^\/\//);

        ### Get only sid
        my @arr = split (/:/, $line);

        push (@sids, $arr[0]);
    }

    close ($fh);

    ## Store in ds
    $self->{db_sids} = \@sids;
}

sub parse_tnsnames
{
    my ($self, $debug) = @_;

    my $tnsnames = $self->tnsnames_file();

    open (my $fh, "<", $tnsnames) || die "Error: Couldn't open $tnsnames file \n";

    my $tnsnames_map = {};
    my $cur_line     = undef;

    my @all_sids;
    my $begin = 0;
    while (my $line = <$fh>)
    {
        chomp ($line);
        ### Ignore comments
        next if ($line =~ m/^#/ || $line =~ m/^=/ || $line =~ m/^>/);

        ### Collapse all spaces
        $line =~ s/\s+//g;

        ### Want a line that has WORLD - no need for WORLD.A, WORLD.B
        ### S4MIG02.WORLD = (DESCRIPTION = (ADDRESS = (PROTOCOL= TCP)(Host= leadwood)(Port= 1521)) (CONNECT_DATA = (SERVER = DEDICATED)(SID = S4MIG02)))

        ### Toggle based on "WORLD"
        if ($line =~ m/\bWORLD\b/)
        {
            $begin = ($begin) ? 0 : 1;
        }

        $cur_line .= $line if ($begin);

        unless ($begin)
        {
            ### Push only, if line contains world
            if ($cur_line && $cur_line =~ m/\bWORLD\b/)
            {
                push (@all_sids, $cur_line);
                $cur_line = $line;
                $begin    = 1;
            }
        }
    }

    ### push the last line that's left in the buffer
    push (@all_sids, $cur_line);

    close ($fh);

    ### Get current hostname & grab domain name
    my $hostname = ariba::Ops::NetworkUtils::hostname();
    my ($host, $domain) = ($hostname =~ /(.*?)\.(.*)/);

    foreach my $entry (@all_sids)
    {
        ### Get SID, host & port #
        my ($sid) = ($entry =~ /(.*)\.WORLD/);
        my ($db_host, $port) = ($entry =~ /Host\s*=(.*)\s*\).*Port\s*=(\d*)\s*/i);

        ### If the hostname do not have ariba.com, then its devlab
        $db_host = qq($db_host.$domain) if ($db_host !~ /ariba/);

        $tnsnames_map->{$sid} = ["$db_host", "$port", $hostname];
    }

    $self->{tnsnames} = $tnsnames_map;
}

sub parse_veritas_config
{
    my ($self, $debug) = @_;

    my $func   = func();
    my $debug  = $self->debug();
    my $logger = $self->logger();
    $logger->info($func);

    my $service = $self->service();
    my $user    = $self->monuser();

    my $cipher = ariba::rc::CipherStore->new($service);
    my $passwd = $cipher->valueForName($user);

    my $veritas_conf = {};
    my $db_sids      = $self->sids();

    ### Get current hostname & grab domain name
    my $hostname = ariba::Ops::NetworkUtils::hostname();
    my ($host, $domain) = ($hostname =~ /(.*?)\.(.*)/);

    $main::quiet = TRUE;

    ### For each sid, find the veritas primary and failover host info
    foreach my $sid (@{$db_sids})
    {
        my (@sid_resource, @sid_group, @system_list);
        my ($sid_resource_cmd, $sid_res);

        ### Get Sid Resource first
        for (my $i = 1; $i < 5;$i++)
        {
            $sid_resource_cmd = qq(sudo /opt/VRTSvcs/bin/hares -display -type Oracle | awk '/ Sid .* $sid/ {print \$1}');
            ariba::rc::Utils::executeLocalCommand($sid_resource_cmd, undef, \@sid_resource, undef, 1, undef, $passwd);

            ### The above command uses expect-cover.pl and sometimes the data is in 1st or 2nd element
            ### Also, added in loop, sometimes executeLocal and password, doesnt get output
            my @sid_res = grep{$_ =~ /oracle/i } @sid_resource;
            $sid_res = shift @sid_res;
            last if ( $sid_res =~ /oracle/i);
            sleep(5);
        }

        next if ( $sid_res !~ /oracle/i);
        $logger->debug("Sid Resource Cmd: $sid_resource_cmd");
        $logger->debug("Sid resource output: $sid_res");

        ### Get sid group name
        my $sid_group_cmd = qq(sudo /opt/VRTSvcs/bin/hares -display $sid_res | awk '/ Group / {print \$NF}');
        ariba::rc::Utils::executeLocalCommand($sid_group_cmd, undef, \@sid_group, undef, 1, undef, $passwd);
        $logger->debug("Sid Group Cmd: $sid_group_cmd");
        $logger->debug("Sid group output: $sid_group[0]");

        ### Get the systemlist now
        my $system_list = qq(sudo /opt/VRTSvcs/bin/hagrp -display $sid_group[0]|grep " SystemList ");
        ariba::rc::Utils::executeLocalCommand($system_list, undef, \@system_list, undef, 1, undef, $passwd);
        $logger->debug("System Cmd: $system_list");
        $logger->debug("System list output: $system_list[0]");

        ### Massaging the data before use
        $system_list[0] =~ s/\s+/%%/g;
        my @system_list_arr = split (/%%/, $system_list[0]);

        ### Store in ds
        $veritas_conf->{$sid} = qq($system_list_arr[3].$domain $system_list_arr[5].$domain);
    }

    $main::quiet = FALSE;
    $self->{veritas} = $veritas_conf;
}

sub map_sid_to_product
{
    my ($self, $debug) = @_;

    my $func   = func();
    my $debug  = $self->debug();
    my $logger = $self->logger();
    $logger->info($func);

    my $db_sids  = $self->sids();
    my $tnsnames = $self->tnsnames();

    my $sid_to_product_map = ();
    my $sql                = qq(select name from monitor_tools.app_name);

    foreach my $db_sid (@{$db_sids})
    {
        my $db_host = $tnsnames->{$db_sid}->[0];
        my $db_port = $tnsnames->{$db_sid}->[1];

        ### Connect to application db and get sid to product map
        my $oc = $self->connect_to_app_db($db_host, $db_sid, $db_port);

        ### If db connection is not succesful, skip
        unless($oc) {
            $logger->warn("$db_sid: connect failed, skipping...");
            next;
        }

        ### Get application's name -- forms or approval etc
        ### Not caputuring table not found error
        my @data;
        eval {
            @data = $oc->executeSql($sql);
        };
        
        $sid_to_product_map->{$db_sid} = (scalar (@data) ? lc($data[0]) : undef);
    }

    $self->{sid_product_map} = $sid_to_product_map if (scalar (keys %{$sid_to_product_map}));
}

sub connect_to_app_db
{
    my ($self, $db_host, $db_sid, $db_port) = @_;

    ### Get system user from mon's dd.xml
    my $system_user = qq(system);
    my $system_pass = $self->mon()->default("dbainfo.$system_user.password");

    my $oc = $self->oracle_db_connection($system_user, $system_pass, $db_sid, $db_host);
    return ($oc);
}

##### roles.cfg should not write flipped information, but DD.xml should have flipped info
sub _format_roles
{
    my ($self, $roles_dbinfo) = @_;

    my $roles_map    = {vip     => 'database',  mon       => 'monitor', 'dr-vip' => 'dr-database', 'dr-mon' => 'backup-monitor', dbs => 'database'};
    my $cluster_map  = {primary => 'secondary', secondary => 'primary'};
    my $roles_hash   = ();

    foreach my $cluster(keys %{$roles_dbinfo})
    {
        foreach my $key (keys %{$roles_dbinfo->{$cluster}})
        {
            my $i = 0;
            $i = '' if ($i == 0);

            my $sub_hash = $roles_dbinfo->{$cluster}->{$key};
            foreach my $sh_key (sort keys %{$sub_hash})
            {
                $roles_hash->{$cluster}->{$roles_map->{$key} . "$i"} = (length ($sub_hash->{$sh_key}) > 1) ? "$sh_key $sub_hash->{$sh_key}" : $sh_key;
                if (exists $roles_dbinfo->{$cluster_map->{$cluster}})
                {
                    $roles_hash->{$cluster_map->{$cluster}}->{$roles_map->{"dr-$key"} . "$i"} = (length ($sub_hash->{$sh_key}) > 1) ? "$sh_key $sub_hash->{$sh_key}" : $sh_key;
                }
                $i++;
            }
        }
    }

    return $roles_hash;
}

sub gen_config
{
    my ($self) = @_;

    my $func   = func();
    my $debug  = $self->debug();
    my $logger = $self->logger();
    $logger->info($func);

    ### Connect to mon db
    my $mon = $self->mon();
    my $oc  = $self->connect_to_mondb_as_monuser();
    my $dbh = $oc->handle();
    my $db_type = $self->{dbtype};

    ### Get rows ordered by app_name
    my $mon_table = ariba::Ops::ProductConfig::Constants::MON_TABLE;
    my $sql = qq(select sid,app_name,vip,host_primary,host_failover,mon_host,enabled from $mon_table where app_name is not null and app_dbtype = '$db_type' order by SID,app_name);
    my $sth = $dbh->prepare($sql) || die "Couldn't prepare statement: $sql " . $dbh->errstr;
    $sth->execute() || $logger->logdie("Error in sql: $sql, db error: " . $dbh->errstr);

    my $arr_ref = $sth->fetchall_arrayref();
    $sth->finish();

    ### Build ds with the rows fetched from mon db (one to one between sid to product or one to many also supported)
    my $ds = {};
    foreach my $arr (@$arr_ref)
    {
        my $cur;
        $cur->{sid}           = $arr->[0];
        $cur->{app_name}      = my $app_name = $arr->[1];
        $cur->{vip}           = $arr->[2];
        $cur->{host_primary}  = $arr->[3];
        $cur->{host_failover} = $arr->[4];
        $cur->{mon_host}      = $arr->[5];
        $cur->{enabled}       = $arr->[6];
        push (@{$ds->{$app_name}}, $cur);
    }

    ### All the product configs will be stored and later on written to respective files
    my $pc = {};

    ### Build dd.xml - Should write flipped data
    foreach my $app_name (keys %{$ds})
    {

        ### Foreach array, build serverId, hostname, username
        my @apps_dbinfo    = ();
        my @apps_dr_dbinfo = ();
        my %roles_dbinfo   = ();
        my @app_arr      = @{$ds->{$app_name}};

        ### Loop through arrray
        ### The data from db, has to be separated and stored in 2 buckets (primary, secondary)
        ### If vip name domain and monserver domain match, then its primary.  Otherwise, its secondary
        foreach my $hash (@app_arr)
        {
            my %cur;
            $cur{serverId}        = $hash->{sid};
            $cur{hostname}        = $hash->{vip} || $hash->{host_primary};
            $cur{username}        = qw(system);

            ### If mon's domain and record from db (vip/hostname) domain are same, then its primary data
            ### Dynamic orientation is determined by monserver
            my @arr     = split(/\./, $cur{hostname});
            my @mon_arr = split(/\./, $self->monserver() );
            my $cluster = ( $arr[1] eq $mon_arr[1] ) ? "primary" : "secondary";
            
            $cur{replicationType} = qw(physical-active-realtime) if ( $cluster eq 'secondary' );

            ### Store in 2 diferent ds
            ( $cluster eq 'primary' ) ?  push (@apps_dbinfo, \%cur) : push(@apps_dr_dbinfo, \%cur);

            ### If vip present, then vip { db1 db1}, if not database01 db1 database02 db2
            if ($hash->{vip})
            {
                $roles_dbinfo{$cluster}->{vip}->{$hash->{vip}} = "{ $hash->{host_primary} $hash->{host_failover} }";
            }
            else
            {
                $roles_dbinfo{$cluster}->{dbs}->{$hash->{host_primary}}  = 1 if ($hash->{host_primary});
                $roles_dbinfo{$cluster}->{dbs}->{$hash->{host_failover}} = 1 if ($hash->{host_failover});
            }

            $roles_dbinfo{$cluster}->{mon}->{$hash->{mon_host}} = 1;

            ### info for us
            $pc->{$app_name}->{enabled} = $hash->{enabled};
        }

        ### DBConnections
        $pc->{$app_name}->{DBConnections} = { $app_name => [ @apps_dbinfo ] , "DR$app_name" => [ @apps_dr_dbinfo] };

        ### roles.cfg will be either :
        ### database01  db136.lab1.ariba.com
        ### database02  db144.lab1.ariba.com
        ### OR
        ### dbvip   { db144.lab1.ariba.com db136.lab1.ariba.com}

        # breaking the roles string into a hash so that the parent can parse it for combined config -AlexN
        $pc->{$app_name}->{roles} = $self->_format_roles(\%roles_dbinfo);
    }

    return %$pc ? $pc : undef;
}

1;
