package ariba::Ops::ProductConfig;

use strict;
use Carp                    qw(confess);
use XML::Simple             qw(XMLout);
use Log::Log4perl           qw(get_logger :levels);
use File::Basename;
use Data::Dumper;

use ariba::Ops::OracleClient;
use ariba::Ops::ProductConfig::Constants    qw(:all);
use ariba::Ops::ProductConfig::Utils        qw(:all);
use ariba::rc::CipherStore;
use ariba::rc::Utils                        qw(executeLocalCommand);

sub new
{
    my ($class, $args) = @_;

    my $self = {};
    bless $self, $class;

    ### initialize
    $self->_initialize($args);
    return $self;
}

sub _initialize
{
    my ($self, $args) = @_;

    ### setup service
    $self->{mon_obj} = my $mon = $args->{mon_obj};
    my $service = $self->mon()->service();
    $self->service($service);
    $self->monuser("mon$service");
    $self->svcuser("svc$service");
    $self->db_type(lc($args->{dbtype}));
    $self->action(lc($args->{action}));
    $self->debug($args->{debug});

    my ($monhost)        = $mon->hostsForRoleInCluster('monserver', $mon->currentCluster());
    my ($backup_monhost) = $mon->hostsForRoleInCluster('backup-monserver', $mon->currentCluster());
    $self->monserver($monhost);
    $self->backup_monserver($backup_monhost);

    ### setup logging
    $self->logfile(mklogfile($self));
    Log::Log4perl::init(logconf($self));
    $self->logger(get_logger());

    ### The gen-config factory.
    #   For gen-config, we need the specialized classes for all known db types.
    #   For future, we will look into further optimizing by loading the subclasses
    #   at the gen-config sub, only for all known db types as returned from
    #   mon db query.
    unless(${[caller(2)]}[0] eq __PACKAGE__) { # prevent recursion
        for my $dbtype (@DBTYPES) {
            my $classname = __PACKAGE__ . '::' . ucfirst($dbtype);
            $self->logger()->info("@{[func()]}: loading $classname");

            eval("use $classname");
            confess "Error loading $classname: $@ ($!)\n" if($@);
            my $class = $classname->new($args);
            $self->{$dbtype} = $class;
        }
    }
}

sub extract {
    my ($self) = @_;
    $self->logger()->logdie("@{[func()]}: not implemented in base class.");
}

sub upload {
    my ($self) = @_;
    $self->logger()->logdie("@{[func()]}: not implemented in base class.");
}

sub oracle_db_connection
{
    my ($self, $user, $pass, $sid, $host) = @_;

    my $func = func();
    my $logger = $self->logger();
    $logger->info("$func: connecting to (sid=$sid, user=$user, host=$host)");

    my $oc = ariba::Ops::OracleClient->new($user, $pass, $sid, $host);
    unless($oc->connect()) {
        $logger->error("$func: connect failed: " . $oc->error());
        return;
    }

    $oc->handle()->{RaiseError} = TRUE;
    $oc->handle()->{PrintError} = FALSE;
    $oc->handle()->{AutoCommit} = FALSE;
    return $oc;
}

### Merge the db-specific configs by app.
sub merge_configs {
    my ($self, $cfg) = @_;

    my $logger = $self->logger();
    $logger->debug(func());

    my %apps;
    for my $dbtype (@DBTYPES) { $apps{$_} = {} for(keys %{$cfg->{$dbtype}}); }

    my $service = $self->service();
    my $clusterName = $self->mon()->currentCluster();

    for my $app (keys %apps) {
        $apps{$app}->{xml}->{MetaData} = {
            ReleaseName => ucfirst($app) . 'Rel',
            BranchName  => "//ariba/ond/$app/trunk",
            ServiceName => $service,
            ClusterName => $clusterName,
        };

        #### merge the roles
        for my $dbtype (@DBTYPES) {
            for my $cluster (keys %{$cfg->{$dbtype}->{$app}->{roles}}) {
                for my $role(keys %{$cfg->{$dbtype}->{$app}->{roles}->{$cluster}}) {
                    $apps{$app}->{roles}->{$cluster}->{$role} = $cfg->{$dbtype}->{$app}->{roles}->{$cluster}->{$role};
                }
            }
        }

        ### merge the dbconnections
        for my $dbtype (@DBTYPES) {
            for my $conn (keys %{$cfg->{$dbtype}->{$app}->{DBConnections}}) {

                ### Save dpc on/off information
                $apps{$app}->{enabled} = $cfg->{$dbtype}->{$app}->{enabled};

                push(@{$apps{$app}->{xml}->{DBConnections}->{$conn}},
                     @{$cfg->{$dbtype}->{$app}->{DBConnections}->{$conn}});
            }
        }
    }
    return \%apps;
}

### write one app config
sub write_app_config {
    my ($self, $app, $cfg, $loc) = @_;

    my $func   = func();
    my $debug  = $self->debug();
    my $logger = $self->logger();
    $logger->debug($func);

    return unless $app && $cfg && $loc;

    ### build xml strings for each app
    my $fp = "$loc/$app/config";

    ### Create the product directory
    unless(-d $fp) {
        $logger->info("$func: creating directory '$fp'");
        $main::quiet = TRUE;
        unless(executeLocalCommand("mkdir -p '$fp'")) {
            $logger->error("$func: mkdir failed: $!");
            $main::quiet = FALSE;
            return;
        }
        $main::quiet = FALSE;
    }

    ### BuildName
    my $fn = "$fp/BuildName";
    $logger->info("$func: writing $fn");

    open(my $fh, ">", $fn) || do {
        $logger->error("$func: write failed: $!");
        return;
    };
    print $fh ucfirst($app) . "Rel-1\n";
    close($fh);

    ### roles.cfg
    $fn = "$fp/roles.cfg";
    $logger->info("$func: writing $fn");

    open(my $fh, ">", $fn) || do {
        $logger->error("$func: write failed: $!");
        return;
    };

    ### roles.cfg should not write flipped data
    ### If clusterName eq 'primary', then order is 'primary, secondary'
    ### If clusterName eq 'secondary', then order is 'secondary, primary'
    my $map = { primary   => [qw(primary secondary)],
                secondary => [qw(secondary primary)] };

    my $clusterName = $self->mon()->currentCluster();
    my $roles_order = $map->{$clusterName};
    my @clusters    = qw(primary secondary);
    my $i = 0;

    foreach my $cluster ( @{$roles_order} )
    {
        my $rh = $cfg->{roles}->{$cluster};
        print $fh "cluster = $clusters[$i]\n" if ( scalar(keys %{$rh}) );

        for my $role_name (sort keys %{$rh}) {
            printf $fh "%-20s\t%s\n", $role_name, $rh->{$role_name};
        }
        print $fh "\n";
        $i++;
    }
    close($fh);

    ### DD.xml
    $fn = "$fp/DeploymentDefaults.xml";
    $logger->info("$func: writing $fn");

    my $xml     = XML::Simple->new(RootName => 'XML');
    my $xml_str = $xml->XMLout($cfg->{xml}, suppressempty => 1, noattr => 1, keyattr => ['MetaData', 'dbconnections']);

    open(my $fh, ">", $fn) || do {
        $logger->error("$func: write failed: $!");
        return;
    };
    print $fh $xml_str;
    close($fh);
}

sub copy_config_dir {
    my ($self, $src, $dest) = @_;

    my $func   = func();
    my $logger = $self->logger();
    $logger->debug($func);

    my $monuser = $self->monuser();
    my $svcuser = $self->svcuser();
    my $service = $self->service();

    ### copy them to $out_loc now
    my $cmd = "sudo su - $svcuser -c 'cp -r $src $dest'";

    my @output;
    my $cipher = ariba::rc::CipherStore->new($service);
    my $passwd = $cipher->valueForName($monuser);

    $logger->info("$func: copying configs from $src to $dest");
    my $rc;
    $main::quiet = TRUE;
    unless(executeLocalCommand($cmd, undef, \@output, undef, 1, \$rc, $passwd)) {
            $logger->error("$func: copy configs failed: rc=$rc");
            $main::quiet = FALSE;
            return;
    }
    $main::quiet = FALSE;
    return TRUE;
}

### Each db subclass is responsible for generating its own config structure.
### Right now, we're just looking for dbconnections and roles by app name.
### Here's where we'll build the Grand Unified Config.
sub gen_unified_config {
    my ($self) = @_;

    my $func   = func();
    my $debug  = $self->debug();
    my $logger = $self->logger();
    $logger->debug($func);

    my $configs = {};
    for my $dbtype (@DBTYPES) {
        if($self->{$dbtype}) {
            my $r = $self->{$dbtype}->gen_config();
            $configs->{$dbtype} = $r if $r;
        }
    }

    my $merged = $self->merge_configs($configs);

    for my $app (keys %$merged) {
        unless($self->write_app_config($app, $merged->{$app}, GENCONFIG_TMPDIR)) {
            $logger->error("$func: '$app': failed to write configs");
        }

        ### Write configs in real location vs temp location
        if ( $merged->{$app}->{enabled} eq 'Y' )
        {
            ### copy the configs from temp loc to svcuser loc
            my $svcuser = $self->svcuser();
            $self->copy_config_dir(GENCONFIG_TMPDIR."/$app", "/home/$svcuser");
        }
    }
}

sub update_enabled_flag
{
    my ($self, $val, $app_name) = @_;

    ### app_name & val is mandatory
    my $msg ;
    $msg = qq(product name is missing) unless ( $app_name );
    $msg = qq(value is missing) unless ( $val );
    
    return $msg if ( $msg );

    ### Connect to mondb
    my $logger = $self->logger();
    my $oc     = $self->connect_to_mondb_as_monuser();

    return "Unable to connect to mon db as monuser" unless ( $oc );

    my $dbh =  $oc->handle();

    eval
    {
        ### Build sql 
        my $sql = qq( update product_config set enabled = ? where app_name = ? );

        ### Prepare & execute sql
        my $sth = $dbh->prepare($sql);
        $sth->execute($val, $app_name);

        $sth->finish();
        $dbh->commit();

        $msg = qq(Committing ... );
        $logger->info("$msg");
    };

    if ( $@ )
    {
        $msg = "Transactions rollbacked... $@ \n";
        $dbh->rollback();
        $logger->logdie("Error: $msg");
    }
    
   ### Return the message
   return $msg;
}

sub mon
{
    my ($self) = @_;
    return ($self->{mon_obj});
}

sub logger
{
    my ($self, $val) = @_;
    $self->{logger} = $val if ($val);
    return ($self->{logger});
}

sub debug
{
    my ($self, $val) = @_;
    $self->{debug} = $val if ($val);
    return ($self->{debug});
}

sub db_type
{
    my ($self, $val) = @_;
    $self->{dbtype} = $val if ($val);
    return ($self->{dbtype});
}

sub monserver
{
    my ($self, $val) = @_;
    $self->{mon_host} = $val if ($val);
    return ($self->{mon_host});
}

sub backup_monserver
{
    my ($self, $val) = @_;
    $self->{backup_monhost} = $val if ($val);
    return ($self->{backup_monhost});
}

sub service
{
    my ($self, $val) = @_;
    $self->{service} = $val if ($val);
    return $self->{service};
}

sub svcuser
{
    my ($self, $val) = @_;
    $self->{svcuser} = $val if ($val);
    return $self->{svcuser};
}

sub monuser
{
    my ($self, $val) = @_;
    $self->{monuser} = $val if ($val);
    return $self->{monuser};
}

sub prog
{
    my ($self) = shift;
    $self->{prog} = $self->{prog} || basename($0);
    return $self->{prog};
}

sub action
{
    my ($self, $val) = @_;
    $self->{action} = $val if ($val);
    return $self->{action};
}

sub node_info {
    my ($self) = shift;
    $self->{node_info} = $self->{node_info} || get_node_info();
    return $self->{node_info};
}

sub logfile {
    my ($self, $val) = @_;
    $self->{logfile} = $val if ($val);
    return $self->{logfile};
}

sub connect_to_mondb_as_monuser
{
    my ($self) = shift;

    my $func   = func();
    my $logger = $self->logger();
    $logger->debug($func);

    my $mon      = $self->mon();
    my $mon_host = $mon->default("dbconnections.mon.hostname");
    my $mon_user = $mon->default("dbconnections.mon.username");
    my $mon_sid  = $mon->default("dbconnections.mon.serverid");
    my $mon_pass = $mon->default("dbconnections.mon.password");

    unless ( $mon_host && $mon_user && $mon_sid && $mon_pass )
    {
        $logger->logdie("$func: missing mon db connect info");
    }

    my $ch = $self->oracle_db_connection($mon_user, $mon_pass, $mon_sid, $mon_host);
    $logger->logdie("$func: failed to connect to mon db") unless $ch;
    return $ch;
}

TRUE;
