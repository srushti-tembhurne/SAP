#
# $Id: //ariba/services/tools/lib/perl/ariba/Ops/DBConnection.pm#104 $
#
# A package to keep Database connection information. Has helpful
# constructors to extract this from connection dictionaries in products
# DD.xml
#
#
# MODIFIED FOR HANASIM

package ariba::Ops::DBConnection;

use strict;

use ariba::rc::Product;
use ariba::Ops::NetworkUtils qw(:all);
use ariba::Ops::Constants;

my $typeMain = "main";
my $typeRepl = "replicated";
my $typeDr = "dr";
my $typeReporting = "reporting";
my $typeGeneric = "generic";
my $typeMainGeneric = "${typeMain}-${typeGeneric}";
my $typeDrGeneric = "${typeDr}-${typeGeneric}";
my $typeEdi = "edi";
my $typeMainEdi = "${typeMain}-${typeEdi}";
my $typeDrEdi = "${typeDr}-${typeEdi}";
my $typeRman = "rman";
my $typeMainRman = "${typeMain}-${typeRman}";
my $typeDrRman = "${typeDr}-${typeRman}";
my $typeStar = "star";
my $typeMainStar= "${typeMain}-${typeStar}";
my $typeMainStarShared = "${typeMain}-${typeStar}-shared";
my $typeMainStarDedicated = "${typeMain}-${typeStar}-dedicated";
my $typeDrStar= "${typeDr}-${typeStar}";
my $typeDrStarShared = "${typeDr}-${typeStar}-shared";
my $typeDrStarDedicated = "${typeDr}-${typeStar}-dedicated";

my $typeSupplier = "supplier";
my $typeBuyer = "buyer";
my $typeEStore = "estore";
my $typeEStoreBuyer = "estorebuyer";
my $typeMainSupplier = "${typeMain}-${typeSupplier}";
my $typeMainBuyer = "${typeMain}-${typeBuyer}";
my $typeDrSupplier = "${typeDr}-${typeSupplier}";
my $typeDrBuyer = "${typeDr}-${typeBuyer}";
my $typeMainEStore = "${typeMain}-${typeEStore}";
my $typeMainEStoreBuyer = "${typeMain}-${typeEStoreBuyer}";
my $typeDrEStoreBuyer = "${typeDr}-${typeEStoreBuyer}";

my $typeMigration = "migration";
my $typeMainMigration = "${typeMain}-${typeMigration}";
my $typeDrMigration = "${typeDr}-${typeMigration}";
my $typeMigrationSource = "migrationSource";
my $typeMainMigrationSource = "${typeMain}-${typeMigrationSource}";
my $typeMigrationOriginal = "migrationOriginal";
my $typeMainMigrationOriginal = "${typeMain}-${typeMigrationOriginal}";
my $typeDrMigrationOriginal = "${typeDr}-${typeMigrationOriginal}";

my $typeLuna = 'luna';
my $typeMainLuna = "$typeMain-$typeLuna";

my $MYSQL_TYPE = "mysql";
my $ORACLE_TYPE = "oracle";
my $HANA_TYPE = "hana";
my $ASE_TYPE = "ase";

my $typeHana = $HANA_TYPE;
my $typeHanaSupplier = "$typeHana-$typeSupplier";

my %cachedConnections = ();

#
# class methods
#


sub new
{
    my $class = shift;
    my $user = shift;
    my $pass = shift;
    my $sid = shift;
    my $host = shift;

    my $type = shift;
    my $schemaId = shift;

    my $product = shift;

    my @realHosts = @_;


    if ($host && $sid && $user &&
        $host !~ /dummy/i &&
        $user !~ /dummy/i &&
        $sid !~ /dummy/i &&
        @realHosts) {

        #
        # if host name is not fully qualified make it fully
        # qualified
        #
        unless (isFQDN($host)) {
            $host = addrToHost(hostToAddr($host));
        }
    } else {
        return undef;
    }

    my $self = {};

    bless($self,$class);

    $self->setProduct($product);

    $self->setUser($user);
    $self->setPassword($pass);
    $self->setSid($sid);
    $self->setHost($host);
    $self->setRealHosts(@realHosts);
    $self->setType($type);

    $self->setCommunity($schemaId);
    $self->setSchemaId($schemaId);

    return $self;
}

sub _schemaIdForConnectionDict
{
    my $dictKeypath = shift;
    my $base = shift;

    my $id;

    if($base && ($dictKeypath ne $base)) {
            # this is for parsing DD.xml DBC's that might not be using numeric suffix,
            # i.e. tag names like "HANA(\w+)" and "drHANA(\w+)", such as what supplierrisk uses.
            ($dictKeypath) =~ /$base(.+)$/;
            return $1;
    }

    $dictKeypath =~ m|[^\d]+(\d*)$|;
    $id = $1;
    $id = int($id) if $id;

    return $id;
}

#
# this function sets up relations between different dbconnections.
# relationship that indicate if one is replicated from the other.
#
sub _computeAndSetPeers
{
    my $class = shift;
    my @connections = @_;

    for my $connection (@connections) {
        # cache connection
        next if ( _cachedForPeers($connection) );

        my @peers;

        my $type = $connection->type();
        my $schemaId = $connection->schemaId();
        my $dbtype   = $connection->dbType;
        for my $peerConnection (@connections) {
            next if ($peerConnection == $connection);
            next if $peerConnection->dbType ne $dbtype; # peers must be of the same dbtype!
            my $peerSchemaId = $peerConnection->schemaId();
            my $peerType = $peerConnection->type();
#
#            #
#            #
#            # setup peers as follows (make sure they are in the
#            # same schema)
#            #
#            # peers-of-main: reporting, dr
#            # peers-of-reporting: main
#            # peers-of-dr: main
#            #
#            # make sure that we do not flag dr and reporting db's
#            # as peers
#            #
            if (
                (!$peerSchemaId && !$schemaId)
                ||
                ($peerSchemaId && $schemaId && $peerSchemaId eq $schemaId)
             ) {
                if ( ($type eq $typeReporting && $peerType eq $typeDr) ||
                     ($peerType eq $typeReporting && $type eq $typeDr) ) {
                    next;
                }
                my $drType = $class->peerTypeForConnectionType($type);
                next unless $drType eq $peerType;
                push(@peers, $peerConnection);
            }
        }
        $connection->setPeers(@peers);
    }
}

#
# this call takes the primary DBC, and a service, and returns an array
# that is the real primary and the real secondary as defined by primary lives
# in pridc and secondary lives in backdc... this is only useful in failover
# scenarios where convert configs may have been run, but it is pretty much
# required when you can't assume the config is in either state.
#
sub sanitizeDBCs {
    my $dbc = shift;
    my $service = shift;

    my $mon = ariba::rc::InstalledProduct->new('mon', $service);
    my @copyhosts = $mon->hostsForRoleInCluster('copyhost', 'secondary');
    @copyhosts = $mon->hostsForRoleInCluster('monserver', 'secondary') unless(scalar(@copyhosts));
    my $primaryCopyhost = shift(@copyhosts);

    my $machine = ariba::Ops::Machine->new($primaryCopyhost);
    my $datacenter = $machine->datacenter();

    my $dbcHost = $dbc->host();

    if($dbcHost =~ /$datacenter/) {
        #
        # $dbc is in 'secondary' cluster
        #
        return($dbc->drDBPeer(), $dbc);
    }

    return($dbc, $dbc->drDBPeer());
}

# returns the real host names of the given virtual host, in order.
sub _realHostsForProductAndHost {
    my $class = shift;
    my $product = shift;
    my $host = shift;

    return () unless($host); # this occasionally happens with non-existant DR

    my @realHosts = $product->hostsForVirtualHostInCluster($host);

    # if $host is not a virtual host it is the only
    # possible 'real' host
    @realHosts = ($host) if (!scalar(@realHosts));

    return @realHosts;
}
{
my $local_storage;
sub connectionsFromProducts
{
    my $class = shift;
    # Added to try and deal with S4 slowness.  When called from cgi-bin/vm, the second argument will be an array ref.  In that
    # case, we set a flag to skip _computeAndSetPeers, and then slurp everything from the array ref.
    my (@products, $vmFlag);
    if (ref ($_[0]) eq 'ARRAY')
    {
        $vmFlag = TRUE;
        @products = @{$_[0]};
    }
    else
    {
        @products = @_;
    }
    my $storage_key;
    $storage_key .= $_->name() foreach (@products);
    return @{$local_storage->{$storage_key}} if (exists $local_storage->{$storage_key});

    my @dictionaries;
    my @productConnections;

    for my $product (@products) {

        # Because there are loop short-circuits, we need to populate
        # @dictionaries at the top of the loop, and then after the loop
        if (scalar(@productConnections)) {
            $class->_computeAndSetPeers(@productConnections) unless $vmFlag;
            push(@dictionaries, @productConnections);
            @productConnections = ();
        }

        my $name = $product->name();
        $name = 'AUC' if $name =~ /^community$/i;

        my ($user, $pass, $sid, $host, $type, $replicationType);

        my $dictKeypath;
        my $schemaId;
        my @realHosts;

        my $c;
        my $dbType;
        my $port;
        my $database;
        my $hanaHosts;
        #
        # Connection information can be specified in config files
        # in one of two styles:
        # 1. Network products style DBConnections.<product>.username
        # 2. Platform style System.Database.AribaDBUserName
        #
        # switch based on which one we see
        #

        $dictKeypath = "System.Database";
        #
        # check if we should get dbconnection info from platform
        # type Parameters.table
        #
        if ( $product->default("$dictKeypath.AribaDBUsername") ) {

            $user = $product->default("$dictKeypath.AribaDBUsername");
            $pass = $product->default("$dictKeypath.AribaDBPassword");
            # this is not set correctly for hana servers
            # of course, I don't know what it *should* be
            $sid = $product->default("$dictKeypath.AribaDBServer");
            $host = $product->default("$dictKeypath.AribaDBHostname");
            $dbType = $product->default("$dictKeypath.AribaDBType");
            $port = $product->default("$dictKeypath.AribaDBPort");
            $database = $product->default("$dictKeypath.AribaDatabase");

            # saw some configs where HanaDBHosts was not defined. In such case we should use AribaDBHostname.
            $hanaHosts = $product->default("$dictKeypath.HanaDBHosts") || [ $host ];
            @realHosts = $class->_realHostsForProductAndHost($product, $host);
            my $dbname = $product->default("$dictKeypath.HanaDBName") || $sid;
            my $admid = $product->default("$dictKeypath.HanaDBAdminID");

            $type = $typeMain;

            $c = $class->new($user, $pass, $sid, $host,
                    $type,
                    $schemaId,
                    $product,
                    @realHosts);
            if ($c) {
                $c->setDbServerType($dbType);
                $c->setPort($port) if $port;
                $c->setDatabase($database) if $database;
                $c->setHanaHosts($hanaHosts);
                $c->dbname($dbname);
                $c->admid($admid);
                $c->setIsVirtual();
            }
            push(@productConnections, $c) if ($c);

            #
            # is there a dr database?
            #
            if ( @realHosts = $product->hostsForRoleInCluster('dr-database') ) {
                $host = $product->virtualHostForRoleInCluster('dr-database');

                $type = $typeDr;

                $c = $class->new($user, $pass, $sid, $host,
                        $type,
                        $schemaId,
                        $product,
                        @realHosts);
                if ($c) {
                    $c->setDbServerType($dbType);
                    $c->setPort($port) if $port;
                    $c->setDatabase($database) if $database;
                    $c->setHanaHosts($hanaHosts);
                    $c->dbname($dbname);
                    $c->admid($admid);
                    $c->setIsVirtual();
                }
                push(@productConnections, $c) if ($c);

            }

            next;

        }

        #
        # Connection dictionaries below are from platform style
        # config files.
        #
        # main connection dictionaries transaction schema +
        # data warehouse schemas
        #
        for $dictKeypath ($product->defaultKeysForPrefix("System.DatabaseSchemas.Schema")) {
            $user = $product->default("$dictKeypath.AribaDBUsername");
            $pass = $product->default("$dictKeypath.AribaDBPassword");
            $sid = $product->default("$dictKeypath.AribaDBServer");
            $host = $product->default("$dictKeypath.AribaDBHostname");
            $dbType = $product->default("$dictKeypath.AribaDBType");
            $port = $product->default("$dictKeypath.AribaDBPort");
            $database = $product->default("$dictKeypath.AribaDatabase");

            # saw some configs where HanaDBHosts was not defined. In such case we should use AribaDBHostname.
            $hanaHosts = $product->default("$dictKeypath.HanaDBHosts") || [ $host ];
            @realHosts = $class->_realHostsForProductAndHost($product, $host);
            my $dbname = $product->default("$dictKeypath.HanaDBName") || $sid;
            my $admid = $product->default("$dictKeypath.HanaDBAdminID");

            $schemaId = _schemaIdForConnectionDict($dictKeypath);
            if ($schemaId) {
                $type = $typeMainStar;
            } else {
                $type = $typeMain;
            }

            $c = $class->new($user, $pass, $sid, $host,
                    $type,
                    $schemaId,
                    $product,
                    @realHosts);

            if ($c) {
                $c->setDbServerType($dbType);
                $c->setPort($port) if $port;
                $c->setDatabase($database) if $database;
                $c->setHanaHosts($hanaHosts);
                $c->dbname($dbname);
                $c->admid($admid);
                $c->setIsVirtual();
                my $defaultSchema = $product->default("System.DatabaseSchemas.DefaultDatabaseSchema");
                if ( $defaultSchema && _schemaIdForConnectionDict($defaultSchema) eq $schemaId ) {
                    unshift(@productConnections, $c);
                } else {
                    push(@productConnections, $c) if ($c);
                }
            }

            #
            # star schemas are not DRed
            #
            next if ($schemaId);

            #
            # is there a dr database?
            #
            if ( @realHosts = $product->hostsForRoleInCluster('dr-database') ) {
                $host = $product->virtualHostForRoleInCluster('dr-database');

                $type = $typeDr;

                $c = $class->new($user, $pass, $sid, $host,
                        $type,
                        $schemaId,
                        $product,
                        @realHosts);
                if ($c) {
                    $c->setDbServerType($dbType);
                    $c->setPort($port) if $port;
                    $c->setDatabase($database) if $database;
                    $c->setHanaHosts($hanaHosts);
                    $c->dbname($dbname);
                    $c->admid($admid);
                    $c->setIsVirtual();
                }
                push(@productConnections, $c) if ($c);

            }

            next;
        }

        #
        # Starting in Hawk the system-level database connection
        # information is broken out into it's own section.
        # Save this in databaseHash to refer back to it later
        #
        my %databaseHash = ();
        my $databasePrefix = "System.Databases.";
        for $dictKeypath ($product->defaultKeysForPrefix(quotemeta($databasePrefix))) {
            my $key = $dictKeypath;
            $key =~ s/^$databasePrefix//;

            $databaseHash{$key}{HOST} = $product->default("$dictKeypath.AribaDBHostname");
            $databaseHash{$key}{SID} = $product->default("$dictKeypath.AribaDBServer");
            $databaseHash{$key}{TYPE} = $product->default("$dictKeypath.AribaDBSchemaType");
            $databaseHash{$key}{DBTYPE} = $product->default("$dictKeypath.AribaDBType");
            $databaseHash{$key}{PORT} = $product->default("$dictKeypath.AribaDBPort");
            $databaseHash{$key}{HANAHOSTS} = $product->default("$dictKeypath.HanaDBHosts") || [];
            $databaseHash{$key}{HANADBNAME} = $product->default("$dictKeypath.HanaDBName") || $sid;
            $databaseHash{$key}{HANADBADMINID} = $product->default("$dictKeypath.HanaDBAdminID");
        }

        #
        # This may not exist in all deployments; use it if it does,
        # but fall back to old method of determining primary/DR sid
        # matchups
        my %drDatabaseHash = ();
        my $drDatabasePrefix = "Ops.DrDatabases.";
        for $dictKeypath ($product->defaultKeysForPrefix(quotemeta($drDatabasePrefix))) {

            my $key = $dictKeypath;
            $key =~ s/^$drDatabasePrefix//;
            my $sid = $product->default("$dictKeypath.AribaDBServer");

            $drDatabaseHash{$key}{HOST} = $product->default("$dictKeypath.AribaDBHostname");
            $drDatabaseHash{$sid}{HOST} = $product->default("$dictKeypath.AribaDBHostname");
            $drDatabaseHash{$key}{SID} = $product->default("$dictKeypath.AribaDBServer");
            $drDatabaseHash{$sid}{SID} = $product->default("$dictKeypath.AribaDBServer");
            $drDatabaseHash{$key}{TYPE} = $product->default("$dictKeypath.AribaDBSchemaType");
            $drDatabaseHash{$sid}{TYPE} = $product->default("$dictKeypath.AribaDBSchemaType");
            $drDatabaseHash{$key}{DBTYPE} = $product->default("$dictKeypath.AribaDBType");
            $drDatabaseHash{$sid}{DBTYPE} = $product->default("$dictKeypath.AribaDBType");
            $drDatabaseHash{$key}{REPLICATIONTYPE} = $product->default("$dictKeypath.ReplicationType");
            $drDatabaseHash{$sid}{REPLICATIONTYPE} = $product->default("$dictKeypath.ReplicationType");
            $drDatabaseHash{$key}{HANAHOSTS} = $product->default("$dictKeypath.HanaDBHosts") || [];
            $drDatabaseHash{$sid}{HANAHOSTS} = $product->default("$dictKeypath.HanaDBHosts") || [];
            $drDatabaseHash{$key}{HANADBNAME} = $product->default("$dictKeypath.HanaDBName") || $sid;
            $drDatabaseHash{$sid}{HANADBNAME} = $product->default("$dictKeypath.HanaDBName") || $sid;
            $drDatabaseHash{$key}{HANADBADMINID} = $product->default("$dictKeypath.HanaDBAdminID");
            $drDatabaseHash{$sid}{HANADBADMINID} = $product->default("$dictKeypath.HanaDBAdminID");
        }

        for $dictKeypath ($product->defaultKeysForPrefix("System.DatabaseSchemas.Transaction.Schema")) {
            push(@productConnections, $class->_processPlatformPTable($product, $dictKeypath, $typeMain, \%databaseHash, \%drDatabaseHash));
        }

	for $dictKeypath ($product->defaultKeysForPrefix("System.DatabaseSchemas.ReplicatedTransaction.Schema")) {
            push(@productConnections, $class->_processPlatformPTable($product, $dictKeypath, $typeRepl, \%databaseHash, \%drDatabaseHash));
        }

        #
        #  Make sure that the default schema is at the front of the connections list
        #
        if(my $defaultSchema = $product->default("System.DatabaseSchemas.DefaultDatabaseSchema")) {
            my $defaultId = _schemaIdForConnectionDict($defaultSchema);
            my $defaultDbc;
            for (my $i = 0; $i <= $#productConnections; $i++) {
                if($productConnections[$i]->schemaId() eq $defaultId &&
                   $productConnections[$i]->isMain()) {
                    $defaultDbc = splice(@productConnections, $i, 1);
                    last;
                }
            }
            unshift(@productConnections, $defaultDbc) if $defaultDbc;
        }

        for $dictKeypath ( $product->defaultKeysForPrefix("System.DatabaseSchemas.Star.Dedicated.Schema")) {
            push(@productConnections, $class->_processPlatformPTable($product, $dictKeypath, $typeMainStarDedicated, \%databaseHash, \%drDatabaseHash));
        }

        for $dictKeypath ( $product->defaultKeysForPrefix("System.DatabaseSchemas.Star.Shared.Schema")) {
            push(@productConnections, $class->_processPlatformPTable($product, $dictKeypath, $typeMainStarShared, \%databaseHash, \%drDatabaseHash));
        }

        for $dictKeypath ( $product->defaultKeysForPrefix("System.DatabaseSchemas.Generic.Schema")) {
            push(@productConnections, $class->_processPlatformPTable($product, $dictKeypath, $typeMainGeneric, \%databaseHash, \%drDatabaseHash));
        }

        #
        # Starting in AN48 we have buyer/supplier types of
        # connections, each serving a scalable number of communities
        #
        my $networkDatabasePrefix = "dbs.db";
        for my $dictKeypath ($product->defaultKeysForPrefix(quotemeta($networkDatabasePrefix))) {
            my $key = $dictKeypath;
            $key =~ s/^$networkDatabasePrefix//;

            my $userPrefix = $product->default("$dictKeypath.usernamePrefix");
            my $namePrefix = $product->default("$dictKeypath.namePrefix");
            my $accountType = $product->default("$dictKeypath.accountType");
            my $host = $product->default("$dictKeypath.hostname");
            my $port = $product->default("$dictKeypath.port");
            my $database = $product->default("$dictKeypath.database");
            my $replicationType = $product->default("$dictKeypath.replicationType");
            $pass = $product->default("$dictKeypath.password");
            $sid = $product->default("$dictKeypath.serverid");

            @realHosts = $class->_realHostsForProductAndHost($product, $host);

            #
            # calculate account type here
            #
            # For AN LUNA, with anhdbsql script, this line is generating an un-init'd error for $_.  This can be fixed
            # as done here, but it could foul up other processing, so it will need careful testing. TODO
            my ($isDr, $nameType) = map { lc if $_ } ($namePrefix =~ /^(DR)?(.+)$/i);

            if ($isDr) {
                $type = $typeDr;
            } else {
                $type = $typeMain;
            }

            if ($accountType ne "directory") {
                $type .= "-$accountType";
            }

            # for edi schema?
            if ($nameType ne $name) {
                $type .= "-$name";
            }

            my $communitiesRangeString = $product->default("$dictKeypath.communities");
            my @communities;
            if ($communitiesRangeString) {
                @communities = split(',', $communitiesRangeString);
            } else {
                @communities = (0);
            }
            for my $community (@communities) {
                my $user = $userPrefix;
                $user .= $community if($community != 0);

                $c = $class->new($user, $pass, $sid, $host,
                        $type,
                        $community,
                        $product,
                        @realHosts);
                if ($c) {
                    $c->setDbServerType($product->default("$dictKeypath.dbtype") || $ORACLE_TYPE);
                    $c->setReplicationType($replicationType) if $replicationType;
                    $c->setPort($port) if $port;
                    $c->setDatabase($database) if $database;
                    if (!$isDr) {
                        unshift(@productConnections, $c);
                    } else {
                        push(@productConnections, $c);
                    }
                }
            }
        }

        #
        #
        # Connection dictionaries below are from network style
        # config files.
        #
        # main connection dictionaries (single db, or dir+communities)
        #
        for $dictKeypath ($product->defaultKeysForPrefix("dbconnections.$name")) {

            $user = $product->default("$dictKeypath.username");
            $pass = $product->default("$dictKeypath.password");
            $sid = $product->default("$dictKeypath.serverid");
            $host = $product->default("$dictKeypath.hostname");
            $port = $product->default("$dictKeypath.port");
            $database = $product->default("$dictKeypath.database");
            $type = $typeMain;

            $schemaId = _schemaIdForConnectionDict($dictKeypath);

            @realHosts = $class->_realHostsForProductAndHost($product, $host);

            $c = $class->new($user, $pass, $sid, $host,
                    $type,
                    $schemaId,
                    $product,
                    @realHosts);
            if ($c) {
               $c->setDbServerType($product->default("$dictKeypath.dbtype") || $ORACLE_TYPE);
                $c->setPort($port) if $port;
                $c->setDatabase($database) if $database;
                unless ($schemaId) {
                    unshift(@productConnections, $c);
                } else {
                    push(@productConnections, $c);
                }
            }

        }

        #
        # Connection dictionaries below are from network style
        # config files for HANA DBs.
        #
        # main connection dictionaries (single db, or dir+communities)
        #
        my $match = "dbconnections.(dr)?hana";
        for $dictKeypath ( $product->defaultKeysForPrefix($match) ) {

            $user     = $product->default("$dictKeypath.username");
            $pass     = $product->default("$dictKeypath.password") || $product->default("dbainfo.hana.system.password");
            $sid      = $product->default("$dictKeypath.serverid");
            my $dbname= $product->default("$dictKeypath.dbname") || $sid;
            $host     = $product->default("$dictKeypath.hostname");
            $port     = $product->default("$dictKeypath.port") || 30015;
            my $admid = $product->default("$dictKeypath.adminid");
            my $hosts = $product->default("$dictKeypath.hanahosts");

            my @hanaHosts;
            if ( $hosts ) {
                $hosts =~ s/,\s+/,/g;
                @hanaHosts = split(',', $hosts);
            }
            else {
                # a product can have more than one hana cluster -- make sure the
                # carpet (the role num) matches the drapes (the dbconnection num).
                my ($n) = $dictKeypath =~ /(\d+)$/;
                $n = '' unless defined $n;
                @hanaHosts = $product->hostsForRoleInCluster( "hanadatabasehosts$n", $product->currentCluster() );
            }

            unless ( grep /$host/, @hanaHosts ){
                unshift (@hanaHosts, $host), unless($name =~ /hanasim/);
            }

            my ($base) = $dictKeypath =~ /($match)/;
            $type = $dictKeypath =~ /drhana/i ? $typeDr : $typeMain;

            $schemaId = _schemaIdForConnectionDict($dictKeypath, $base);

            @realHosts = $class->_realHostsForProductAndHost($product, $host);

            $c = $class->new($user, $pass, $sid, $host,
                    $type,
                    $schemaId,
                    $product,
                    @realHosts);
            if ($c) {
                $c->setDbType( $HANA_TYPE );
                $c->setHanaHosts( \@hanaHosts );
                $c->setPort( $port );
                $c->dbname($dbname);
                $c->admid($admid);
                $c->setIsVirtual();
                push(@productConnections, $c);
            }

        }

        # This is for HANADBs non-monitoring use.  Note that the keys for prefix method acts like a regex:  hanadbs\.db.*
        # Except it does need to be quoted to protect the literal dot here.
        for $dictKeypath ($product->defaultKeysForPrefix(quotemeta ("hanadbs.db"))) {

            # These are the field names supplied by HANADBs:
            #       accountType
            #       dbtype
            #       namePrefix
            #       usernamePrefix
            #       cipherblocktextpassword   Not currently used, at least not directly (2015/06/12).
            #       serverId
            #       hostname
            #       port
            #       instance
            #       url                       Not currently used (2015/06/12).
            my $userPrefix = $product->default("$dictKeypath.usernamePrefix");
            my $namePrefix = $product->default("$dictKeypath.namePrefix");
            my $accountType = $product->default("$dictKeypath.accountType");
            my $host = $product->default("$dictKeypath.hostname");
            # For the <DBs> tag, there is no 'OR', just the default selection.  Is this OK for HANA?? TODO
            $pass = $product->default("$dictKeypath.password") || $product->default("dbainfo.hana.system.password");
            $sid  = $product->default("$dictKeypath.serverid");
            # Port setting is done in various ways for other DBConnection types, need to research this.  TODO
            my $port = $product->default("$dictKeypath.port") || 30015;
            $dbType = $product->default("$dictKeypath.dbtype");
            my $instance = $product->default("$dictKeypath.instance");
            my $dbname= $product->default("$dictKeypath.dbname") || $sid;
            my $admid = $product->default("$dictKeypath.adminid");

            my @hanaHosts;
            @hanaHosts = $product->hostsForRoleInCluster( 'hanadatabasehosts', $product->currentCluster() );

            unless ( grep /$host/, @hanaHosts ){
                unshift @hanaHosts, $host;
            }
            my $communitiesRangeString = $product->default("$dictKeypath.communities");
            my @communities;
            if ($communitiesRangeString) {
                @communities = split(',', $communitiesRangeString);
            } else {
                @communities = (0);
            }

            $schemaId = _schemaIdForConnectionDict($dictKeypath);

            @realHosts = $class->_realHostsForProductAndHost($product, $host);

            for my $community (@communities) {
                my $user = $userPrefix;
                # Community types for Hana are supplier specific, otherwise it is a 'directory' account type
                # which is plain Hana.
                if($community != 0) {
                    $user .= $community;
                    $type = $typeHanaSupplier;
                } else {
                    $type = $typeHana;
                }

                $c = $class->new($user, $pass, $sid, $host,
                        $type,
                        $community,
                        $product,
                        @realHosts);
                if ($c) {
                $c->setDbServerType($dbType);
                $c->setDbType( $HANA_TYPE );
                $c->setHanaHosts( \@hanaHosts );
                $c->setPort( $port );
                $c->setAccountType($accountType);
                $c->setInstance($instance);
                $c->dbname($dbname);
                $c->admid($admid);
                $c->setIsVirtual();
                push(@productConnections, $c);
                }
            }
        }

        #
        # Connection dictionaries below are from network style
        # config files for EDI-type DBs.
        #
        # main connection dictionaries (single db, or dir+communities)
        #
        for $dictKeypath ($product->defaultKeysForPrefix("dbconnections.edi")) {

            $user = $product->default("$dictKeypath.username");
            $pass = $product->default("$dictKeypath.password");
            $sid = $product->default("$dictKeypath.serverid");

            $host = $product->virtualHostForRoleInCluster('edi-database');
            $port = $product->default("$dictKeypath.port");
            $database = $product->default("$dictKeypath.database");
            #
            # these are not for the *product* edi, they are for the
            # connection type; product edi will not have roles e.g.
            # edi-database
            #
            last unless $host;

            $type = $typeMainEdi;

            $schemaId = _schemaIdForConnectionDict($dictKeypath);

            @realHosts = $class->_realHostsForProductAndHost($product, $host);

            $c = $class->new($user, $pass, $sid, $host,
                    $type,
                    $schemaId,
                    $product,
                    @realHosts);
            if ($c) {
                $c->setDbServerType($product->default("$dictKeypath.dbtype") || $ORACLE_TYPE);
                $c->setPort($port) if $port;
                $c->setDatabase($database) if $database;
                push(@productConnections, $c);
            }

        }

        #
        # Connection dictionaries below are from network style
        # config files for DR EDI-type DBs.
        #
        # main connection dictionaries (single db, or dir+communities)
        #
        for $dictKeypath ($product->defaultKeysForPrefix("dbconnections.dredi")) {

            $user = $product->default("$dictKeypath.username");
            $pass = $product->default("$dictKeypath.password");
            $sid = $product->default("$dictKeypath.serverid");
            my $replicationType = $product->default("$dictKeypath.replicationType");

            $host = $product->virtualHostForRoleInCluster('edi-dr-database');
            $port = $product->default("$dictKeypath.port");
            $database = $product->default("$dictKeypath.database");
            #
            # these are not for the *product* edi, they are for the
            # connection type; product edi will not have roles e.g.
            # edi-database
            #
            last unless $host;

            $type = $typeDrEdi;

            $schemaId = _schemaIdForConnectionDict($dictKeypath);

            @realHosts = $class->_realHostsForProductAndHost($product, $host);

            $c = $class->new($user, $pass, $sid, $host,
                    $type,
                    $schemaId,
                    $product,
                    @realHosts);
            if ($c) {
                $c->setDbServerType($product->default("$dictKeypath.dbtype") || $ORACLE_TYPE);
                $c->setReplicationType($replicationType) if $replicationType;
                $c->setPort($port) if $port;
                $c->setDatabase($database) if $database;
                push(@productConnections, $c);
            }

        }

        for $dictKeypath ($product->defaultKeysForPrefix("dbconnections.rman*")) {

            $user = $product->default("$dictKeypath.username");
            $pass = $product->default("$dictKeypath.password");
            $sid = $product->default("$dictKeypath.serverid");
            $host = $product->default("$dictKeypath.hostname");
            $port = $product->default("$dictKeypath.port");
            $database = $product->default("$dictKeypath.database");
            $type = $typeMainRman;

            $schemaId = _schemaIdForConnectionDict($dictKeypath);

            @realHosts = $class->_realHostsForProductAndHost($product, $host);

            $c = $class->new($user, $pass, $sid, $host,
                    $type,
                    $schemaId,
                    $product,
                    @realHosts);
            if ($c) {
                $c->setDbServerType($product->default("$dictKeypath.dbtype") || $ORACLE_TYPE);
                $c->setPort($port) if $port;
                $c->setDatabase($database) if $database;
                push(@productConnections, $c);
            }

        }

        for $dictKeypath ($product->defaultKeysForPrefix("dbconnections.drrman*")) {

            $user = $product->default("$dictKeypath.username");
            $pass = $product->default("$dictKeypath.password");
            $sid = $product->default("$dictKeypath.serverid");
            my $replicationType = $product->default("$dictKeypath.replicationType");
            $host = $product->default("$dictKeypath.hostname");
            $port = $product->default("$dictKeypath.port");
            $database = $product->default("$dictKeypath.database");
            $type = $typeDrRman;

            $schemaId = _schemaIdForConnectionDict($dictKeypath);

            @realHosts = $class->_realHostsForProductAndHost($product, $host);

            $c = $class->new($user, $pass, $sid, $host,
                    $type,
                    $schemaId,
                    $product,
                    @realHosts);
            if ($c) {
                $c->setDbServerType($product->default("$dictKeypath.dbtype") || $ORACLE_TYPE);
                $c->setReplicationType($replicationType) if $replicationType;
                $c->setPort($port) if $port;
                $c->setDatabase($database) if $database;
                push(@productConnections, $c);
            }

        }

        #
        # reporting connection dictionary (for products that have
        # a seperate reporting db). This is in here for backward
        # compatibility. We use dr-db now for reporting.
        #
        for $dictKeypath ($product->defaultKeysForPrefix("dbconnections.reportingdb")) {
            $user = $product->default("$dictKeypath.username");
            $pass = $product->default("$dictKeypath.password");
            $sid = $product->default("$dictKeypath.serverid");

            $host = $product->virtualHostForRoleInCluster('reporting-database');

            $type = $typeReporting;
            $schemaId = _schemaIdForConnectionDict($dictKeypath);

            @realHosts = $class->_realHostsForProductAndHost($product, $host);

            $port = $product->default("$dictKeypath.port");
            $database = $product->default("$dictKeypath.database");
            #
            # HACK: get reporting db name fully qualified, the magic in 'new'
            # does not work for repdb2 from andb1.bou.ariba.com
            #
            unless (isFQDN($host)) {
                $host = $product->virtualHostForRoleInCluster('reporting-database');
            }


            $c = $class->new($user, $pass, $sid, $host,
                    $type,
                    $schemaId,
                    $product,
                    @realHosts);
            if ($c) {
                $c->setDbServerType($product->default("$dictKeypath.dbtype") || $ORACLE_TYPE);
                $c->setPort($port) if $port;
                $c->setDatabase($database) if $database;
                push(@productConnections, $c)
            }

        }

        #
        # dr database is now listed in connection dict, as it is used
        # for reporting.
        #
        my @drConnections = $product->defaultKeysForPrefix("dbconnections.dr$name");

        if (@drConnections) {
            for $dictKeypath (@drConnections) {

                $user = $product->default("$dictKeypath.username");
                $pass = $product->default("$dictKeypath.password");
                $sid = $product->default("$dictKeypath.serverid");
                my $replicationType = $product->default("$dictKeypath.replicationType");

                $host =  $product->default("$dictKeypath.hostname") ||
                    $product->virtualHostForRoleInCluster('dr-database');

                $type = $typeDr;
                $schemaId = _schemaIdForConnectionDict($dictKeypath);

                @realHosts = $class->_realHostsForProductAndHost($product, $host);

                $port = $product->default("$dictKeypath.port");
                $database = $product->default("$dictKeypath.database");

                $c = $class->new($user, $pass, $sid, $host,
                        $type,
                        $schemaId,
                        $product,
                        @realHosts);
                if ($c) {
                    $c->setDbServerType($product->default("$dictKeypath.dbtype") || $ORACLE_TYPE);
                    $c->setReplicationType($replicationType) if $replicationType;
                    $c->setPort($port) if $port;
                    $c->setDatabase($database) if $database;
                    push(@productConnections, $c);
                }

            }
        } else {

            #
            # when products had seperate reporting db, dr database was not
            # listed in connection dictionary. cons up an object based on
            # other information.
            #
            $host = $product->virtualHostForRoleInCluster("dr-database");

            if ($host) {

                for $dictKeypath ($product->defaultKeysForPrefix("dbconnections.$name")) {
                    $user = $product->default("$dictKeypath.username");
                    $pass = $product->default("$dictKeypath.password");
                    $sid = $product->default("$dictKeypath.serverid");

                    $type = $typeDr;
                    $schemaId = _schemaIdForConnectionDict($dictKeypath);

                    @realHosts = $class->_realHostsForProductAndHost($product, $host);

                    $port = $product->default("$dictKeypath.port");
                    $database = $product->default("$dictKeypath.database");

                    $c = $class->new($user, $pass, $sid, $host,
                            $type,
                            $schemaId,
                            $product,
                            @realHosts);
                    if ($c) {
                        $c->setDbServerType($product->default("$dictKeypath.dbtype") || $ORACLE_TYPE);
                        $c->setPort($port) if $port;
                        $c->setDatabase($database) if $database;
                        push(@productConnections, $c);
                    }

                }
            }
        }

        #
        # check for migration db connections
        #
        $dictKeypath = 'Migration';
        if ( $product->default("$dictKeypath.username") ) {

            $user = $product->default("$dictKeypath.username");
            $pass = $product->default("$dictKeypath.password");
            $sid = $product->default("$dictKeypath.serverId");
            $host = $product->default("$dictKeypath.hostname");
            $port = $product->default("$dictKeypath.port");
            $database = $product->default("$dictKeypath.database");

            @realHosts = $class->_realHostsForProductAndHost($product, $host);

            $type = $typeMainMigration;

            $c = $class->new($user, $pass, $sid, $host,
                    $type,
                    undef,
                    $product,
                    @realHosts);
            if ($c) {
                $c->setDbServerType($product->default("$dictKeypath.dbtype") || $ORACLE_TYPE);
                $c->setPort($port) if $port;
                $c->setDatabase($database) if $database;
                push(@productConnections, $c);
            }

            if ( $product->default("$dictKeypath.DrHostname") ) {

                my $drHost = $product->default("$dictKeypath.DrHostname");

                @realHosts = $class->_realHostsForProductAndHost($product, $drHost);

                $type = $typeDrMigration;

                $c = $class->new($user, $pass, $sid, $drHost,
                        $type,
                        undef,
                        $product,
                        @realHosts);
                if ($c) {
                    $c->setDbServerType($product->default("$dictKeypath.dbtype") || $ORACLE_TYPE);
                    $c->setPort($port) if $port;
                    $c->setDatabase($database) if $database;
                    push(@productConnections, $c);
                }
            }

        }

        $dictKeypath = 'MigrationSource';
        if ( $product->default("$dictKeypath.username") ) {

            $user = $product->default("$dictKeypath.username");
            $pass = $product->default("$dictKeypath.password");
            $sid = $product->default("$dictKeypath.serverId");
            $host = $product->default("$dictKeypath.hostname");

            @realHosts = $class->_realHostsForProductAndHost($product, $host);
            $port = $product->default("$dictKeypath.port");
            $database = $product->default("$dictKeypath.database");

            $type = $typeMainMigrationSource;

            $c = $class->new($user, $pass, $sid, $host,
                    $type,
                    undef,
                    $product,
                    @realHosts);
            if ($c) {
                $c->setDbServerType($product->default("$dictKeypath.dbtype") || $ORACLE_TYPE);
                $c->setPort($port) if $port;
                $c->setDatabase($database) if $database;
                push(@productConnections, $c);
            }

        }

        $dictKeypath = 'MigrationOriginal';
        if ( $product->default("$dictKeypath.username") ) {

            $user = $product->default("$dictKeypath.username");
            $pass = $product->default("$dictKeypath.password");
            $sid = $product->default("$dictKeypath.serverId");
            $host = $product->default("$dictKeypath.hostname");

            @realHosts = $class->_realHostsForProductAndHost($product, $host);
            $port = $product->default("$dictKeypath.port");
            $database = $product->default("$dictKeypath.database");

            $type = $typeMainMigrationOriginal;

            $c = $class->new($user, $pass, $sid, $host,
                    $type,
                    undef,
                    $product,
                    @realHosts);
            if ($c) {
                $c->setDbServerType($product->default("$dictKeypath.dbtype") || $ORACLE_TYPE);
                $c->setPort($port) if $port;
                $c->setDatabase($database) if $database;
                push(@productConnections, $c);
            }

            if ( $product->default("$dictKeypath.DrHostname") ) {

                my $drHost = $product->default("$dictKeypath.DrHostname");

                @realHosts = $class->_realHostsForProductAndHost($product, $drHost);

                $type = $typeDrMigrationOriginal;

                $c = $class->new($user, $pass, $sid, $drHost,
                        $type,
                        undef,
                        $product,
                        @realHosts);
                if ($c) {
                    $c->setDbServerType($product->default("$dictKeypath.dbtype") || $ORACLE_TYPE);
                    $c->setPort($port) if $port;
                    $c->setDatabase($database) if $database;
                    push(@productConnections, $c);
                }
            }
        }

    }

    # For the last iteration of the product loop
    $class->_computeAndSetPeers(@productConnections) unless $vmFlag;
    push(@dictionaries, @productConnections);
    $local_storage->{$storage_key} = \@dictionaries;
    return @dictionaries;
}
}

# Method requires a product, db type and account type.
sub connectionsFromProductsByDBTypeAndAccountType
{
    my $class = shift;
    my $product = shift;
    my $dbType = shift;
    my $accountType = shift;

    my @connections;
    my @tempConnections;

    for my $dbc (ariba::Ops::DBConnection->connectionsFromProducts($product)) {
        if ($dbc->dbType() && $dbc->dbType() eq $dbType) {
            push(@tempConnections, $dbc);
        }
        elsif ($dbc->type() && $dbc->type() eq $dbType) {
            push(@tempConnections, $dbc);
        }
    }

    # The product and db type selected a basic set, now search it to find those with account
    # type matching the input type.
    for my $dbc (@tempConnections) {
        if ($dbc->accountType() && $dbc->accountType() eq $accountType) {
            push @connections, $dbc;
        }
    }

    if (wantarray()) {
        return(@connections);
    } else {
        if (@connections) {
            return $connections[0];
        } else {
            return undef;
        }
    }
}

sub connectionsToMySQLFromProducts
{
    my $class = shift;
    my @products = @_;

    my @dictionaries;

    for my $product (@products) {

        my $name = $product->name();

        my @productConnections;

        my ($user, $pass, $sid, $host, $type);

        my $dictKeypath;
        my $schemaId;
        my @realHosts;

        my $c;

        #
        # Connection for MySQL to be read by monitoring
        #

        for $dictKeypath ($product->defaultKeysForPrefix("mysqldbconnections.$name")) {

            my $host = $product->default("$dictKeypath.host");
            my $port = $product->default("$dictKeypath.port");
            my $database = $product->default("$dictKeypath.database");
            my $user = $product->default("$dictKeypath.user");
            my $pass = $product->default("$dictKeypath.password");

            my $sid = $port . ":" . $database;

            last unless $host;

            my $type = $typeMain;

            my $schemaId = _schemaIdForConnectionDict($dictKeypath);

            my @realHosts = $class->_realHostsForProductAndHost($product, $host);

            my $c = $class->new($user, $pass, $sid, $host,
                    $type,
                    $schemaId,
                    $product,
                    @realHosts);

            if ($c) {

                $c->setDbServerType($MYSQL_TYPE);
                $c->setPort($port);
                $c->setDatabase($database);

                unless ($schemaId) {
                    unshift(@productConnections, $c);
                } else {
                    push(@productConnections, $c);
                }
            }
        } # end for dict key

        $class->_computeAndSetPeers(@productConnections);

        push(@dictionaries, @productConnections);

    } # end for product


    return @dictionaries;
}

sub connectionsToMySQLForProductOfDBType
{
    my $class = shift;
    my $product = shift;
    my $dbType = shift;

    my @connections;

    for my $dbc (ariba::Ops::DBConnection->connectionsToMySQLFromProducts($product)) {
        if ($dbc->type() eq $dbType) {
            push(@connections, $dbc);
        }
    }

    if (wantarray()) {
        return(@connections);
    } else {
        if (@connections) {
            return $connections[0];
        } else {
            return undef;
        }
    }
}

sub connectionsForProductOfDBType
{
    my $class = shift;
    my $product = shift;
    my $dbType = shift;

    my @connections;

    for my $dbc (ariba::Ops::DBConnection->connectionsFromProducts($product)) {
        if ($dbc->type() && $dbc->type() eq $dbType) {
            push(@connections, $dbc);
        }
    }

    if (wantarray()) {
        return(@connections);
    } else {
        if (@connections) {
            return $connections[0];
        } else {
            return undef;
        }
    }
}

sub connectionsForProductOfDBServerType
{
    my $class = shift;
    my $product = shift;
    my $dbServerType = shift;
    my $dbcs_ref = shift; # optional arrayref of dbconnections to search

    my @connections;

    my @dbcs = ($dbcs_ref && ref($dbcs_ref) eq "ARRAY")
        ? @$dbcs_ref
        : ariba::Ops::DBConnection->connectionsFromProducts($product);

    for my $dbc (@dbcs) {
        if ($dbc->dbServerType() eq $dbServerType) {
            push(@connections, $dbc);
        }
    }

    if (wantarray()) {
        return(@connections);
    } else {
        if (@connections) {
            return $connections[0];
        } else {
            return undef;
        }
    }
}

sub connectionsForProductOfDBTypeAndInCommunity
{
    my $class = shift;
    return ($class->connectionsForProductOfDBTypeAndSchemaId(@_));
}

sub connectionsForProductOfDBTypeAndSchemaId
{
    my $class = shift;
    my $product = shift;
    my $dbType = shift;
    my $schemaId = shift;

    $schemaId = int($schemaId) if defined($schemaId) && $schemaId =~ m/^\d+$/;

    my @dbtypeConnections = $class->connectionsForProductOfDBType($product, $dbType);
    my @connections;

    for my $dbc (@dbtypeConnections) {
        if (!$schemaId || $dbc->schemaId() eq $schemaId) {
            push(@connections, $dbc);
        }
    }

    if (wantarray()) {
        return(@connections);
    } else {
        if (@connections) {
            return $connections[0];
        } else {
            return undef;
        }
    }
}

sub uniqueConnectionsByHost
{
    my $class = shift;
    my @connections = @_;

    my %uniqueConnections;
    for my $connection (reverse @connections) {
        my $key = $connection->host();
        $uniqueConnections{lc($key)} = $connection;
    }

    return (values(%uniqueConnections));
}

sub uniqueConnectionsByHostAndSid
{
    my $class = shift;
    my @connections = @_;

    my %uniqueConnections;
    for my $connection (reverse @connections) {
        my $key = $connection->host() . $connection->sid();
        $uniqueConnections{lc($key)} = $connection;
    }

    return (values(%uniqueConnections));
}

sub uniqueConnectionsByHostAndPort
{
    my $class = shift;
    my @connections = @_;

    my %uniqueConnections;
    for my $connection (reverse @connections) {
        my $key = $connection->host() . $connection->port();
        $uniqueConnections{lc($key)} = $connection;
    }

    return (values(%uniqueConnections));
}

sub uniqueConnectionsByHostAndSidAndSchema
{
    my $class = shift;
    my @connections = @_;

    my %uniqueConnections;
    for my $connection (reverse @connections) {
        my $key = $connection->host() . $connection->sid() .  $connection->user();
        $uniqueConnections{lc($key)} = $connection;
    }

    return (values(%uniqueConnections));
}

sub _cachedForPeers
{
    my $connection = shift;

    # uniquely identify this connection object by logical key
    my $cachekey = $connection->type()."|".$connection->schemaId()."|".$connection->dbType();

    # do we already have a connection object in the cache with this logical key
    if ( !exists $cachedConnections{$cachekey} ) {
      # no - put it in the cache and store it's ref as the value
      $cachedConnections{$cachekey} = $connection;
      return 0;
    }
    # yes - this connection is in the cache by it's LOGICAL key, but is it the exact same instance?
    if ( $connection != $cachedConnections{$cachekey} ) {
      # the connection that is cached for this logical key is not the same instance
      # so let's get the cached conn's peers and set the passed in conn's peers with it.
      # As long as the two connections logically match, the peers will be (logically) the same
      my $cachedconn = $cachedConnections{$cachekey};
      $connection->setPeers($cachedconn->peers());
    }
    return 1;
}

sub typeMain
{
    return $typeMain;
}

sub typeDr
{
    return $typeDr;
}

sub typeEdi {
    return $typeEdi;
}

sub typeHana {
    return $typeHana;
}

sub typeHanaSupplier {
    return $typeHanaSupplier;
}

sub typeMainEdi {
    return $typeMainEdi;
}

sub typeDrEdi {
    return $typeDrEdi;
}

sub typeMainEStore {
    return $typeMainEStore;
}

sub typeMainEStoreBuyer {
    return $typeMainEStoreBuyer;
}

sub typeStar {
    return $typeStar;
}

sub typeGeneric
{
    return $typeGeneric;
}

sub typeMainStar
{
    return $typeMainStar;
}

sub typeMainStarShared
{
    return $typeMainStarShared;
}

sub typeMainStarDedicated
{
    return $typeMainStarDedicated;
}

sub typeMainSupplier
{
    return $typeMainSupplier;
}

sub typeMainBuyer
{
    return $typeMainBuyer;
}

sub typeMainGeneric
{
    return $typeMainGeneric;
}

sub typeDrStar
{
    return $typeDrStar;
}

sub typeDrStarShared
{
    return $typeDrStarShared;
}

sub typeDrStarDedicated
{
    return $typeDrStarDedicated;
}

sub typeDrSupplier
{
    return $typeDrSupplier;
}

sub typeDrBuyer
{
    return $typeDrBuyer;
}

sub typeDrGeneric
{
    return $typeDrGeneric;
}

sub typeDrEStoreBuyer
{
    return $typeDrEStoreBuyer;
}

sub typeReporting
{
    return $typeReporting;
}

sub typeMainMigration {
    return $typeMainMigration;
}

sub typeDrMigration {
    return $typeDrMigration;
}

sub typeMainMigrationSource {
    return $typeMainMigrationSource;
}

sub typeMainMigrationOriginal {
    return $typeMainMigrationOriginal;
}

sub typeDrMigrationOriginal {
    return $typeDrMigrationOriginal;
}

#
# begin instance methods
#
sub setAccountType
{
    my $self = shift;
    my $accountType = shift;

    $self->{accountType} = $accountType;
}

sub accountType
{
    my $self = shift;

    return $self->{accountType};
}

sub setUser
{
    my $self = shift;
    my $user = shift;

    $self->{user} = $user;
}

sub user
{
    my $self = shift;

    return $self->{user};
}

sub setPassword
{
    my $self = shift;
    my $password = shift;

    $self->{password} = $password;
}

sub password
{
    my $self = shift;

    return $self->{password};
}

sub setSid
{
    my $self = shift;
    my $sid = shift;

    $self->{sid} = lc($sid);
}

sub sid
{
    my $self = shift;

    return $self->{sid};
}

sub dbname {
    my ($self, $dbname) = @_;
    $self->{dbname} = $dbname if $dbname;
    return $self->{dbname};
}

sub admid {
    my ($self, $admid) = @_;
    $self->{admid} = $admid if $admid;
    return $self->{admid};
}

sub setHost
{
    my $self = shift;
    my $host = shift;

    $self->{host} = lc($host);
}

sub host
{
    my $self = shift;

    return $self->{host};
}

sub setPort
{
    my $self = shift;
    my $port = shift;

    $self->{port} = $port;
}

sub port
{
    my $self = shift;

    return $self->{port};
}

sub setDatabase
{
    my $self = shift;
    my $database = shift;

    $self->{database} = $database;
}

sub database
{
    my $self = shift;

    return $self->{database};
}

sub setRealHosts
{
    my $self = shift;
    my @hosts = @_;

    push(@{$self->{realHosts}}, @hosts);
}

sub realHosts
{
    my $self = shift;

    return (@{$self->{realHosts}});
}

sub setPeers
{
    my $self = shift;

    my @peers = @_ if @_;;

    push(@{$self->{peers}}, @peers);
}

sub peers
{
    my $self = shift;

    return (@{$self->{peers}});
}

sub setCommunity
{
    my $self = shift;
    my $community = shift;

    $self->{community} = $community;
}

sub community
{
    my $self = shift;

    return $self->{community};
}

sub setSchemaId
{
    my $self = shift;
    my $schemaId = shift;

    $schemaId = '' unless defined $schemaId;

    if($schemaId =~ /^\d+$/) {
            $schemaId = int($schemaId);
    }
    else {
            # this is a DD.xml schema "name" style ID such as is found in supplierrisk and suppliermanagement.
            $schemaId = lc($schemaId);
    }

    $self->{schemaId} = $schemaId;
}

sub schemaId
{
    my $self = shift;

    return $self->{schemaId};
}

sub setType
{
    my $self = shift;
    my $type = shift;

    $self->{type} = $type;
}

sub type
{
    my $self = shift;

    return $self->{type};
}

sub setDbServerType {
    my $self = shift;
    my $dbType = shift;
    $dbType = lc($dbType) if $dbType;
    $self->{dbServerType} = $dbType;
}

sub dbServerType {
    my $self = shift;

    my $type = $self->{dbServerType};
    $type = $ORACLE_TYPE unless $type;

    return $type;
}

sub setDbType
{
    my $self = shift;
    my $type = shift;

    $self->{dbServerType} = $type;
}

sub dbType
{
    my $self = shift;

    return $self->{dbServerType};
}

# determine if the DB connection is for a Hana db or not. Simplifies processing in other methods
# that need to determine the DB type before acting.
sub isHana
{
    my $self = shift;

    my $dbtype = $self->dbServerType || '';
    return ( lc($dbtype) eq lc(hanaDBServerType()) );
}

# determine if the DB connection is for a Oracle db or not. Simplifies processing in other methods
# that need to determine the DB type before acting.
sub isOracle
{
    my $self = shift;

    my $dbtype = $self->dbServerType || '';
    return ( lc($dbtype) eq lc(oracleDBServerType()) );
}

sub setHanaHosts
{
    my $self = shift;
    my $hanaHosts = shift;

    # should always be an arrayref
    $self->{hanaHosts} = $hanaHosts || [];
}

sub hanaHosts
{
    my $self = shift;

    return $self->{hanaHosts};
}

# determine if the DB connection is for an ASE db or not. Simplifies processing in other methods
# that need to determine the DB type before acting.
sub isASE
{
    my $self = shift;

    my $dbtype = $self->dbServerType || '';
    return ( lc($dbtype) eq lc(aseDBServerType()) );
}

# Support for possible instance number useage in DD.xml file.
sub setInstance
{
    my $self = shift;
    $self->{instance} = shift;
}

sub instance
{
    my $self = shift;

    return $self->{instance};
}

sub setProduct
{
    my $self = shift;
    my $product = shift;

    $self->{product} = $product;
}

sub product
{
    my $self = shift;

    return $self->{product};
}

sub setReplicationType
{
    my $self = shift;
    my $replicationType = shift;

    $self->{replicationType} = $replicationType;
}

sub replicationType
{
    my $self = shift;

    return $self->{replicationType};
}

sub reportingDBPeer
{
    my $self = shift;

    for my $peer ($self->peers()) {
        if ($peer->type() eq $typeReporting) {
            return $peer;
        }
    }

    return undef;
}

sub drDBPeer
{
    my $self = shift;

    for my $peer ($self->peers()) {
        if ($peer->isDR()) {
            return $peer;
        }
    }

    return undef;
}

# is the replication type logical or physical?
sub isPhysicalReplication
{
    my $self = shift;

    my $dbcToCheck;

    if ($self->isDR()) {
        $dbcToCheck = $self;
    } else {
        $dbcToCheck = $self->drDBPeer();
    }

    return 0 if !$dbcToCheck || !$dbcToCheck->replicationType();

    return 1 if $dbcToCheck->replicationType() =~ m/physical/;

    return 0;
}

sub isPhysicalActiveReplication
{
    my $self = shift;

    my $dbcToCheck;

    if ($self->isDR()) {
        $dbcToCheck = $self;
    } else {
        $dbcToCheck = $self->drDBPeer();
    }

    return 0 if !$dbcToCheck || !$dbcToCheck->replicationType();

    return 1 if $dbcToCheck->replicationType() =~ m/physical-active/;

    return 0;
}

sub isPhysicalActiveRealtimeReplication
{
    my $self = shift;

    my $dbcToCheck;

    if ($self->isDR()) {
        $dbcToCheck = $self;
    } else {
        $dbcToCheck = $self->drDBPeer();
    }

    return 0 if !$dbcToCheck || !$dbcToCheck->replicationType();

    return 1 if $dbcToCheck->replicationType() =~ m/physical-active-realtime/;

    return 0;
}

sub mainDBPeer
{
    my $self = shift;

    for my $peer ($self->peers()) {
        if ($peer->isMain()) {
            return $peer;
        }
    }

    return undef;
}

sub isEdi {
    my $self = shift;
    my $type = $self->type();

    return 1 if $type =~ /edi/;

    return 0;
}

sub isGeneric {
    my $self = shift;
    my $type = $self->type();

    return 1 if $type =~ /generic/;

    return 0;
}

sub isStarSchema {
    my $self = shift;
    my $type = $self->type();

    return 1 if $type =~ /star/;

    return 0;
}

# is this connection object a Main connection?
sub isMain {
    my $self = shift;

    my $type = $self->type();
    my $class = ref($self);

    return 1 if $class->isMainType($type);

    return 0;
}

#
# end instance methods
#

sub isMainType {
    my $class = shift;
    my $type = shift;

    return $type =~ /^$typeMain/;
}

# is this connection object a DR connection?
sub isDR {
    my $self = shift;

    my $type = $self->type();
    my $class = ref($self);

    return 1 if $class->isDRType($type);

    return 0;
}

sub isDRType {
    my $class = shift;
    my $type = shift;

    return $type =~ /^$typeDr/;
}

sub isReplicated {
    my $self = shift;
    my $type = $self->type();
    my $class = ref($self);

    return 1 if $class->isReplicatedType($type);
    return 0;
}

 sub isReplicatedType {
    my $class = shift;
    my $type = shift;

    return $type =~ /^$typeRepl/;
}

sub peerTypeForConnectionType {
    my $class = shift;
    my $ctype = shift;

    my $peerType = $ctype;

    if ($class->isDRType($ctype)) {
        $peerType =~ s/$typeDr/$typeMain/;
    } else {
        $peerType =~ s/$typeMain/$typeDr/;
    }

    return $peerType;
}

sub oracleDBServerType { return lc($ORACLE_TYPE); }
sub mysqlDBServerType  { return lc($MYSQL_TYPE);  }
sub hanaDBServerType   { return lc($HANA_TYPE);   }
sub aseDBServerType    { return lc($ASE_TYPE);    }

sub _processPlatformPTable {
    my $class = shift;
    my $product = shift;
    my $dictKeypath = shift;
    my $type = shift;
    my $databaseHash = shift;
    my $drDatabaseHash = shift;
    my $port;
    my $hanaHosts;
    my $dbname;
    my $admid;

    my($host, $sid, $dbtype, @schemas, @dictionaries, @realHosts, @realDrHosts, $replicationType);
    my $keySuffix = (split(/\./, $dictKeypath))[-1];

    if($keySuffix =~ m/SchemaSet(\d*)$/i) {
        my $userPrefix = $product->default("$dictKeypath.AribaDBUserNamePrefix");
        my $pass = $product->default("$dictKeypath.AribaDBPassword");
        foreach my $key ($product->defaultKeysForPrefix($dictKeypath . ".")) {
            if($key =~ m/Schema(\d*)$/i) {
                my $schemaId = $1;
                $schemaId = int($schemaId) if $schemaId;
                my $user = $product->default("$key.AribaDBUserName");
                push(@schemas, [$schemaId, $user, $pass]);
            } elsif($key =~ m/Range(\d*)$/i) {
                my $userNumber = $product->default("$key.FirstAribaDBUserNumber");
                my $startId = $product->default("$key.FirstSchemaNumber");
                my $endId = $product->default("$key.LastSchemaNumber");

                for(my $i = $startId; $i <= $endId; $i++) {
                    push(@schemas, [$i, $userPrefix . $userNumber, $pass]);
                    $userNumber++;
                }
            }
        }
    } elsif($keySuffix =~ m/Schema(\d*)$/i) {
        my $schemaId = $1;
        $schemaId = int($schemaId) if $schemaId;
        my $user = $product->default("$dictKeypath.AribaDBUserName");
        my $pass = $product->default("$dictKeypath.AribaDBPassword");
        push(@schemas, [$schemaId, $user, $pass]);
    }

    my $database = $product->default("$dictKeypath.Database");
    if ($database) {
        $host = $databaseHash->{$database}{HOST};
        $sid = $databaseHash->{$database}{SID};
        $dbtype = $databaseHash->{$database}{DBTYPE};
        $port = $databaseHash->{$database}{PORT};

        # saw some configs where HanaDBHosts was not defined. In such case we should use AribaDBHostname.
        $hanaHosts = $databaseHash->{$database}{HANAHOSTS} || [ $host ];
        $dbname = $databaseHash->{$database}{HANADBNAME};
        $admid = $databaseHash->{$database}{HANADBADMINID};
    } else {
        $sid = $product->default("$dictKeypath.AribaDBServer");
        $host = $product->default("$dictKeypath.AribaDBHostname");
        $port = $product->default("$dictKeypath.AribaDBPort");

        # saw some configs where HanaDBHosts was not defined. In such case we should use AribaDBHostname.
        $hanaHosts = $product->default("$dictKeypath.HanaDBHosts") || [ $host ];
        $dbtype = $databaseHash->{$sid}{DBTYPE} if($sid);
        $dbname = $product->default("$dictKeypath.HanaDBName");
        $admid = $product->default("$dictKeypath.HanaDBAdminID");
    }

    @realHosts = $class->_realHostsForProductAndHost($product, $host);

    foreach my $dbRef (@schemas) {
        my ($schemaId, $user, $pass) = @$dbRef;
        my $c = $class->new($user, $pass, $sid, $host,
                $type,
                $schemaId,
                $product,
                @realHosts);
        if($c) {
            $c->setDbServerType($dbtype) if($dbtype);
            $c->setPort($port);
            $c->setHanaHosts($hanaHosts);
            $c->dbname($dbname);
            $c->admid($admid);
            $c->setIsVirtual();
            push(@dictionaries, $c);
        }
        #
        # is there a dr database?
        #

        # use the primary/DR sid matching from P.table if it
        # exists...
        if (keys %$drDatabaseHash ) {
            my $base;
            if($database && exists($drDatabaseHash->{$database})) {
                $base = $drDatabaseHash->{$database};
            } elsif(exists($drDatabaseHash->{$sid})) {
                $base = $drDatabaseHash->{$sid};
            } else {
                next;
            }

            my $drhost = $base->{HOST};
            my $drsid  = $base->{SID};
            $replicationType = $base->{REPLICATIONTYPE};
            my $drtype = $class->peerTypeForConnectionType($type);
            my $drHanaHosts = $base->{HANAHOSTS} || [ $drhost ];

            @realDrHosts = $class->_realHostsForProductAndHost($product, $drhost);

            my $c = $class->new($user, $pass, $drsid, $drhost,
                    $drtype,
                    $schemaId,
                    $product,
                    @realDrHosts);
            if($c) {
                $c->setDbServerType($dbtype) if($dbtype);
                $c->setPort($port);
                $c->setHanaHosts($drHanaHosts);
                $c->setReplicationType($replicationType);
                $c->dbname($dbname);
                $c->admid($admid);
                $c->setIsVirtual();
                push(@dictionaries, $c);
            }

            #... else fall back to the old assumption that there is only one TX SID and it
            # is DR'd on the dr-database host
            #
        } elsif ( $c and !$c->isStarSchema() and  @realDrHosts = $product->hostsForRoleInCluster('dr-database') ) {
            my $drhost = $product->virtualHostForRoleInCluster('dr-database');

            my $drtype = $typeDr;

            my $c = $class->new($user, $pass, $sid, $drhost,
                    $drtype,
                    $schemaId,
                    $product,
                    @realDrHosts);
            if ($c) {
                $c->setDbServerType($dbtype) if($dbtype);
                push(@dictionaries, $c) if ($c);
            }

        }
    }
    return @dictionaries;
}

sub connectionsForProductOfAllMainDBType {
    my $class = shift;
    my $product = shift;
    my $dbType = $typeMain;

    my @connections;

    for my $dbc (ariba::Ops::DBConnection->connectionsFromProducts($product)) {
        if ($dbc->type() && $dbc->type() =~ /^$dbType/) {
            push(@connections, $dbc);
        }
    }

    if (wantarray()) {
        return(@connections);
    } else {
        if (@connections) {
            return $connections[0];
        } else {
            return undef;
        }
    }
}

# setIsVirtual(): convenience method to flag whether the primary host for this DBC is a virtual host
sub setIsVirtual {
   my $self = shift;

   return unless $self;

   my @reals = $self->realHosts;
   return unless @reals;

   if(@reals > 1) {
       $self->{isVirtual} = TRUE;
       return;
   }

   $self->{isVirtual} = TRUE unless $reals[0] eq $self->host;
}

# isVirtual(): the getter for setIsVirtual().
sub isVirtual {
   my $self = shift;
   return $self->{isVirtual};
}

#wrapper method that reuses existing methods to give very high level details about DB connections per product, service, dbtype etc. mainly used as a helper to cgi-bin/ script thats serving the response as a json to external systems like Grafana
sub dbconnections_api {
    my $self = shift;
    my ($product, $dbtype) = @_;

    my @ret;
    my $p = ariba::rc::InstalledProduct->new($product);

    my @all_dbcs = ariba::Ops::DBConnection->connectionsFromProducts([$p]);
    my @unique_dbcs = ariba::Ops::DBConnection->uniqueConnectionsByHostAndPort(@all_dbcs);

    for my $dbc (@unique_dbcs) {
        # restrict to dbtype if requested
        next if ( $dbtype && $dbtype ne $dbc->dbServerType() );

        my $dbhost = $dbc->host();
        $dbhost    =~ s/:\d+//; # strip port
        my $dbport =  $dbc->port();
        my $dbsid  = uc($dbc->sid());
        $dbsid     =~ s/^([^.]+).*/$1/;
        my $dbname =  uc($dbc->dbname()) || $dbsid;

        push @ret, {
            dbhost => $dbhost,
            dbport => "$dbport",
            sid    => $dbsid,
            dbname => $dbname,
            dbtype => $dbc->dbServerType()
        };
    }

    return \@ret;
}

1;
