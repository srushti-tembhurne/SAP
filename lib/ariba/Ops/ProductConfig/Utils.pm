package ariba::Ops::ProductConfig::Utils;

use strict;
use warnings;
use Data::Dumper;

use ariba::rc::InstalledProduct;
use ariba::rc::CipherStore;
use ariba::rc::Utils qw(executeLocalCommand);
use ariba::Ops::NetworkUtils qw(hostname);
use ariba::Ops::OracleClient;
use ariba::Ops::ProductConfig::Constants qw(:all);

use Exporter qw(import);
our @EXPORT = qw(create_product_config_table is_exists_product_config_table);
our @EXPORT_OK = qw(func dbg mklogfile logconf slurp_file get_node_info);
our %EXPORT_TAGS = (all => [@EXPORT_OK]);

### useful for logging/debugging:
#   For more info on caller(), do a "man perlfunc" or "perldoc perlfunc"
#   and search for "caller", or you can always google it...
sub func { return ${[caller(1)]}[0,3]; }

### useful when manually debugging:
#   You can just put dbg($self->{debug}, any_text) anywhere you want, and it will automagically
#   print (or not) to STDERR, tacking on the package and func from whence it was called,
#   based on debug setting.
sub dbg {
    my ($dbg, $msg) = @_;
    print STDERR "[DEBUG] " . func() . " -- $msg\n" if $dbg;
}

sub get_node_info {
    my $fqdn = ariba::Ops::NetworkUtils::hostname();
    my ($host, $domain) = $fqdn =~ /^([^.]+)\.(.*)/;
    my $ipaddr = ariba::Ops::NetworkUtils::ipForHost($fqdn);

    return {
        'host'   => $host,
        'domain' => $domain,
        'fqdn'   => $fqdn,
        'ip'     => $ipaddr
    };
}

### I wrote this before remembering perl already had File::Slurp!
#   But this one has been fully vetted for my needs and works well,
#   and there have been known compat issues with the cpan module.
#   So it shall remain for now.
sub slurp_file {
    my ($file, $dataref) = @_;

    my $err;
    open(my $fh, "<", $file) || do { $err = "$!"; return FALSE; };

    if(ref($dataref) eq "SCALAR") {
        if($err) {
            $$dataref = $err;
            return FALSE;
        }
        {
            local $/ = undef;
            $$dataref = <$fh>;
        }
    } elsif(ref($dataref) eq "ARRAY") {
        if($err) {
            @$dataref = $err;
            return FALSE;
        }
        @$dataref = <$fh>;
    }
    close($fh);
    return TRUE;
}

sub create_product_config_table
{
    my ($debug) = shift;

    my $err = is_exists_product_config_table($debug);
    return $err if ( $err );

    ### Create mon object
    my $mon = ariba::rc::InstalledProduct->new();

    ### Create the table - Get the metadata for db connection
    my $mon_host = $mon->default("dbconnections.mon.hostname");
    my $mon_user = $mon->default("dbconnections.mon.username");
    my $mon_sid  = $mon->default("dbconnections.mon.serverid");
    my $mon_pass = $mon->default("dbconnections.mon.password");

    dbg($debug, "mon_host:$mon_host, mon_user:$mon_user, mon_sid:$mon_sid ...");

    if ($mon_host && $mon_user && $mon_sid && $mon_pass)
    {
        my $sql = ariba::Ops::ProductConfig::Constants::CREATE_PRODUCT_CONFIG_TABLE;

        dbg($debug, "Connecting to : $mon_host as $mon_user ...");

        my $oc = ariba::Ops::OracleClient->new($mon_user, $mon_pass, $mon_sid, $mon_host);
        my $ret = $oc->connect();

        my $dbh = $oc->handle();
        $dbh->{RaiseError} = 1;
        $dbh->{AutoCommit} = 0;

        return "Error connecting to database... \n" unless ($ret);

        my $sth = $dbh->prepare($sql);
        $sth->execute();

        if ($sth->err())
        {
            $dbh->rollback();
            $dbh->disconnect();
            return "Error: " . $sth->err();
        }
        else
        {
            $dbh->commit();
            $dbh->disconnect();
            dbg($debug, "Done creating table.");
        }
    }
    else
    {
        return "Error connecting to database, check credentails... \n";
    }

    return "Table:product_config created";
}

### Returns useful message or 0
sub is_exists_product_config_table
{
    my ($debug) = shift;

    ### Create mon object
    my $mon = ariba::rc::InstalledProduct->new();

    ### Check if the table exists or not
    my $system_user = qq(system);
    my $system_pass = $mon->default("dbainfo.$system_user.password");
    my $mon_user    = $mon->default("dbconnections.mon.username");
    my $mon_host    = $mon->default("dbconnections.mon.hostname");
    my $mon_sid     = $mon->default("dbconnections.mon.serverid");

    ### Connect to mondb as system user
    my $oc = ariba::Ops::OracleClient->new($system_user, $system_pass, $mon_sid, $mon_host);
    my $ret = $oc->connect();
    my $pc_table = ariba::Ops::ProductConfig::Constants::PC_TABLE_NAME;

    ### Return true for db connectivity issues
    return "Error connecting to mondb using system credentials, $pc_table not created" unless ( $ret );

    my $sql = qq(select 1 from dba_tables where lower(table_name) = lower('$pc_table') and lower(owner) = lower('$mon_user'));

    dbg($debug, "SQL: $sql");

    my $exists = $oc->executeSql($sql);
    ($exists) ? return "Table $pc_table already exists and hence not creating" : return 0;
}

sub logconf {
    my ($obj) = shift;

    my $level = 'INFO';
    $level = 'DEBUG' if $obj->debug();

    my $logconf = q(
        log4perl.rootLogger              = ) . $level . q(, LOG1
        log4perl.appender.LOG1           = Log::Log4perl::Appender::File
        log4perl.appender.LOG1.filename  = ) . $obj->logfile() . q(
        log4perl.appender.LOG1.size      = 10485760
        log4perl.appender.LOG1.max       = 5
        log4perl.appender.LOG1.mode      = append
        log4perl.appender.LOG1.layout    = Log::Log4perl::Layout::PatternLayout
        log4perl.appender.LOG1.layout.ConversionPattern = %d %p %m %n
    );
    return \$logconf;
}

### not sure if we can guarantee /var/log/tools exists everywhere...
sub mklogfile {
    my ($obj) = shift;

    ### make the logs "keepRunning" style so that LogViewer can pick them up.

    my $name = $obj->mon()->name();
    my $monuser = $obj->monuser();
    my $service = $obj->service();
    my $cipher = ariba::rc::CipherStore->new($service);
    my $passwd = $cipher->valueForName($monuser);
    my $logdir = "@{[LOGDIR()]}/$service/$name";

    unless(-d $logdir && -w _ && -x _) {
        my @cmds = ("sudo mkdir -p $logdir",
                    "sudo chown $monuser $logdir",
                    "sudo chmod 755 $logdir"
                   );

        $main::quiet = TRUE; # shutup the goddamn executeLocalCommand
        for my $cmd (@cmds) {
            my @output;
            unless(executeLocalCommand($cmd, undef, \@output, undef, 1, undef, $passwd)) {
                print "@{[func()]} -- ERROR: failed: rc='@output'\n";
                exit(1);
            }
        }
        $main::quiet = FALSE;
    }

    my $pid = $$;
    my $prog = $obj->prog();
    my $host = $obj->node_info()->{fqdn};
    my $args = $obj->action();
    $args .= '-' . $obj->db_type() if $obj->db_type();
    my $logfile = "keepRunning-$prog-$args\@$host-$pid.1";

    return "$logdir/$logfile";
}

TRUE;
