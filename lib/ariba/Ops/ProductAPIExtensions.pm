#
# $Id: //ariba/services/tools/lib/perl/ariba/Ops/ProductAPIExtensions.pm#44 $
#
package ariba::Ops::ProductAPIExtensions;

use ariba::rc::Product;
use ariba::Ops::NetworkUtils;
use ariba::Ops::Machine;
use ariba::util::PerlRuntime;
use ariba::Ops::DBConnection;

=pod

=head1 NAME

ariba::Ops::ProductAPIExtensions

=head1 DESCRIPTION

Extensions to the ariba::rc::Product API

=head1 SYNOPSIS

use ariba::Ops::ProductAPIExtensions;
...
my $product = ariba::rc::InstalledProduct->new(...
$product->

=head1 METHODS

=over 4

=cut

INIT {
    install();
}

=pod

=item * install 

=cut
sub install {
    ariba::util::PerlRuntime::addCategoryToClass(__PACKAGE__, ariba::rc::Product);
}

=pod

=item * datacenters 

=cut
sub datacenters {
    datacentersForProducts($_[0]);
}

=pod

=item * datacentersForProducts 

=cut
sub datacentersForProducts {
    my (@products) = @_;

    my %dataCenters;

    for my $product (@products) {
        for my $host ($product->allHosts()) {
            my $machine = ariba::Ops::Machine->new($host);
            my $dataCenter = $machine->datacenter();

            $dataCenters{$dataCenter}++ if ($dataCenter);
        }
    }

    return (keys(%dataCenters));
}

=pod

=item * _copyhostForProductAndCluster 

=cut
sub _copyhostForProductAndCluster {
    my $product = shift;
    my $cluster = shift;

    my $copyhost = ($product->hostsForRoleInCluster("copyhost", $cluster))[0];

    return ($copyhost);
}

=pod

=item * mainDatacenterForCluster 

=cut
sub mainDatacenterForCluster {
    mainDatacenterForProductAndCluster(@_);
}

=pod

=item * mainDatacenterForProductAndCluster 

=cut
sub mainDatacenterForProductAndCluster {
    my $product = shift;
    my $cluster = shift;

    # Don't try to create a machine on undef if a copyhost doesn't exist
    # for that cluster. This can happen for products that aren't DR ready.
    my $copyhost = _copyhostForProductAndCluster($product, $cluster) || return undef;

    my $machine = ariba::Ops::Machine->new($copyhost);
    my $dataCenter = $machine->datacenter();

    return $dataCenter;
}

=pod

=item * mainDomainForCluster 

=cut
sub mainDomainForCluster {
    mainDomainForProductAndCluster(@_);
}

=pod

=item * mainDomainForProductAndCluster 

=cut
sub mainDomainForProductAndCluster {
    my $product = shift;
    my $cluster = shift;

    my $copyhost = _copyhostForProductAndCluster($product, $cluster);

    eval "use ariba::Ops::NetworkUtils"; die "Eval Error: $@\n" if ($@);

    my $domain = ariba::Ops::NetworkUtils::domainForHost($copyhost);

    return $domain;
}

=pod

=item * connectionKeypaths 

=cut
sub connectionKeypaths {
    connectionKeypathsForProduct(@_);
}

=pod

=item * connectionKeypathsForProduct 

=cut
sub connectionKeypathsForProduct {
    my $product = shift;

    my $name = $product->name();

    #
    # this product has two names -- and the DB connections are on the
    # "other" name in DD.xml
    #
    $name = "auc" if($name eq 'community');

    my @keys;
    if ($product->default("System.Database.AribaDBUsername")) {
        @keys = ("System.Database");
    } elsif ($product->default("System.DatabaseSchemas.DefaultDatabaseSchema")){
        #
        # get all db connections keys, and make sure that the
        # default one is the first in the list
        #
        my $key = ("System.DatabaseSchemas." . $product->default("System.DatabaseSchemas.DefaultDatabaseSchema"));
        @keys = ($key);
        for my $dbConnectionKey (
            $product->defaultKeysForPrefix("System.DatabaseSchemas.Transaction.Schema"),
            $product->defaultKeysForPrefix("System.DatabaseSchemas.Star.Dedicated.Schema"),
            $product->defaultKeysForPrefix("System.DatabaseSchemas.Star.Shared.Schema") ) {
            if ($dbConnectionKey eq $key) {
                next;
            } else {
                push(@keys, $dbConnectionKey);
            }
        }
    } elsif ($product->defaultKeysForPrefix("System.DatabaseSchemas.Schema")){
        @keys = sort($product->defaultKeysForPrefix("System.DatabaseSchemas.Schema"));
    } else {
        ### hana DD.xml dbconnections are of the form "dbconnections.hana"
        @keys = sort($product->defaultKeysForPrefix("dbconnections.$name"),
                     $product->defaultKeysForPrefix("dbconnections.hana"),
                     $product->defaultKeysForPrefix("dbs.db"));
        my @edikeys = $product->defaultKeysForPrefix("dbconnections.edi");
        if($product->name() eq "an" and @edikeys) {
            push(@keys, @edikeys);
        }
    }

    if( $product->defaultKeysForPrefix("mysqldbconnections.$name") ) {
        my @mysqlkeys = sort($product->defaultKeysForPrefix("mysqldbconnections.$name"));
        push(@keys, @mysqlkeys);
    }

    if (wantarray()) {
        return @keys;
    } else {
        if (@keys) {
            return (@keys)[0];
        } else {
            return undef;
        }
    }
}

=pod

=item * starSchemaKeypaths 

=cut
sub starSchemaKeypaths {
    starSchemaKeypathsForProduct(@_);
}

=pod

=item * starSchemaKeypathsForProduct 

=cut
sub starSchemaKeypathsForProduct {
    my $product = shift;

    my $name = $product->name();

    my @keys;

    if ($product->defaultKeysForPrefix("System.DatabaseSchemas.Schema")){
        push(@keys, $product->defaultKeysForPrefix("System.DatabaseSchemas.Schema\\d\+"));
    }
    if ($product->defaultKeysForPrefix("System.DatabaseSchemas.Star.Shared.Schema")){
        push(@keys, $product->defaultKeysForPrefix("System.DatabaseSchemas.Star.Shared.Schema\\d\+"));
    }
    if ($product->defaultKeysForPrefix("System.DatabaseSchemas.Star.Dedicated.Schema")){
        push(@keys, $product->defaultKeysForPrefix("System.DatabaseSchemas.Star.Dedicated.Schema\\d\+"));
    }

    #perl has a bug where sort() in a scalar context returns undef!
    my @sortedKeys = sort(@keys);
    return @sortedKeys;
}

=pod

=item * sharedStarSchemaKeypaths 

=cut
sub sharedStarSchemaKeypaths {
    sharedStarSchemaKeypathsForProduct(@_);
}

=pod

=item * sharedStarSchemaKeypathsForProduct

=cut
sub sharedStarSchemaKeypathsForProduct {
    my $product = shift;

    my @dbcs = ariba::Ops::DBConnection->connectionsForProductOfDBType(
        $product, ariba::Ops::DBConnection::typeMainStarShared()
    );

    my %ids;
    map { $ids{$_->schemaId()} = 1 } @dbcs;

    return (sort keys(%ids));
}

=pod

=item * transactionSchemaKeypaths 

=cut
sub transactionSchemaKeypaths {
    transactionSchemaKeypathsForProduct(@_);
}

=pod

=item * transactionSchemaKeypathsForProduct 

=cut
{
my $local_storage;
sub transactionSchemaKeypathsForProduct {
    my $product = shift;
    return @{$local_storage->{$product->name()}} if (exists $local_storage->{$product->name()}); 
    my @dbcs = ariba::Ops::DBConnection->connectionsForProductOfDBType(
        $product, ariba::Ops::DBConnection::typeMain()
    );

    my %ids;
    map { $ids{$_->schemaId()} = 1 } @dbcs;
    
    $local_storage->{$product->name()} = [(sort keys(%ids))];
    return @{$local_storage->{$product->name()}};
}
}

=pod

=item * communityIds 

=cut
sub communityIds {
    communityIdsForProduct(@_);
}

=pod

=item * starSchemaIds 

=cut
sub starSchemaIds {
    starSchemaIdsForProduct(@_);
}

=pod

=item * sharedStarSchemaIds

=cut
sub sharedStarSchemaIds {
    sharedStarSchemaIdsForProduct(@_);
}

=pod

=item * transactionSchemaIds 

=cut
sub transactionSchemaIds {
    transactionSchemaIdsForProduct(@_);
}

=pod

=item * reportingConnectionKeypaths 

=cut
sub reportingConnectionKeypaths {
    my $product = shift;

    my $name = $product->name();

    my @keys;

    #
    # backward compatible way of getting to reporting db connex dict.
    #
    @keys = $product->defaultKeysForPrefix("dbconnections.reportingdb");

    unless (@keys) {
        @keys = $product->defaultKeysForPrefix("dbconnections.dr$name");
    }

    if (wantarray()) {
        return @keys;
    } else {
        if (@keys) {
            return (sort(@keys))[0];
        } else {
            return undef;
        }
    }
}

=pod

=item * reportingCommunityKeypaths 

=cut
sub reportingCommunityKeypaths {
    my $product = shift;

    my $name = $product->name();

    my @keys;

    @keys = $product->defaultKeysForPrefix("dbconnections.reportingdb\\d\+");

    unless (@keys) {
        @keys = $product->defaultKeysForPrefix("dbconnections.dr$name\\d\+");
    }

    #perl has a bug where sort() in a scalar context returns undef!
    my @sortedKeys = sort(@keys);
    return @sortedKeys;
}

=pod

=item * communityIdsForProduct 

=cut
sub communityIdsForProduct {
    my $product = shift;
    my %ids;

    for my $connection ( ariba::Ops::DBConnection->connectionsFromProducts($product) ) {
        $ids{$connection->community()} = 1 if ($connection->community());
    }

    my @ids = sort(keys(%ids));
    return @ids;
}

=pod

=item * communityIdsForProductOfType 

=cut
sub communityIdsForProductOfType {
    my $product = shift;
    my $type = shift;
    my %ids;

    my $i = 1;
    while(1) {
        my $key = "DBs.DB$i.accountType";
        my $dbtype = $product->default($key);
        last unless($dbtype);

        if(lc($type) eq lc($dbtype)) {
            $key = "DBs.DB$i.Communities";
            my $communities = $product->default($key);
            my @list = split(',',$communities);
            foreach my $community (@list) {
                $ids{$community} = 1;
            }
        }
        $i++;
    }

    my @ids = sort(keys(%ids));
    return @ids;
}

=pod

=item * starSchemaIdsForProduct 

=cut
sub starSchemaIdsForProduct {
    my $product = shift;

    my $name = $product->name();

    my @keys;
    for my $key (starSchemaKeypathsForProduct($product)) {
        $key =~ s|System\.DatabaseSchemas\.Schema||i;
        push(@keys, $key);
    }

    return @keys;
}

=pod

=item * sharedStarSchemaIdsForProduct

=cut
sub sharedStarSchemaIdsForProduct {
    my $product = shift;

    my @keys;
    for my $key (sharedStarSchemaKeypathsForProduct($product)) {
        $key =~ s|System\.DatabaseSchemas\.Star\.Shared||i;
        push(@keys, $key);
    }

    return @keys;
}

=pod

=item * transactionSchemaIdsForProduct 

=cut
sub transactionSchemaIdsForProduct {
    my $product = shift;

    my $name = $product->name();

    my @keys;
    for my $key (transactionSchemaKeypathsForProduct($product)) {
        $key =~ s|System\.DatabaseSchemas\.Transaction\.Schema||i;
        push(@keys, $key) if $key =~ /\d+/;
    }

    return @keys;
}

=pod

=item * connectInfoForOracleClient 

=cut

sub connectInfoForOracleClient {
    my $product = shift;

    my ($tx) = ariba::Ops::DBConnection->connectionsFromProducts($product);
    return ($tx->user(), $tx->password(), $tx->sid(), $tx->host());

}

=pod

=item * connectInfoWithDBType

=cut

sub connectInfoWithDBType {
    my $product = shift;

    my ($tx) = ariba::Ops::DBConnection->connectionsFromProducts($product);
    return ($tx->dbType(), $tx->user(), $tx->password(), $tx->sid(), $tx->host(), $tx->port());

}

=item * connectInfoForMySQLClient 

=cut
sub connectInfoForMySQLClient {
    my $product = shift;
    my $dictKeypath = shift;

    $dictKeypath = connectionKeypathsForProduct($product) unless ($dictKeypath);

    my $host = $product->default("$dictKeypath.host");
    my $port = $product->default("$dictKeypath.port");
    my $database = $product->default("$dictKeypath.database");
    my $user = $product->default("$dictKeypath.user");
    my $pass = $product->default("$dictKeypath.password");

    return ($user, $pass, $host, $port, $database);
}

=pod

=item * setAQLConnectInfoOnQueryManager 

=cut
sub setAQLConnectInfoOnQueryManager {
    my $product = shift;
    my $queryManager = shift;

    $queryManager->setAQLConnectInfo($product);
}

=pod

=item * setCommunitiesSQLConnectInfoOnQueryManager 

=cut
sub setCommunitiesSQLConnectInfoOnQueryManager {
    my $product = shift;
    my $queryManager = shift;

    my @communityConnections = grep { $_->community() } grep { !$_->isDR() } ariba::Ops::DBConnection->connectionsFromProducts($product);

    for my $dbc (@communityConnections) {
        # This guarantees that this method only works for Oracle instances, which is the assumption made when it was first created.
        next unless ($dbc->dbServerType() eq ariba::Ops::DBConnection->oracleDBServerType());
        $queryManager->setSQLConnectInfo($dbc->user(), $dbc->password, $dbc->sid, $dbc->host(), $dbc->community());
    }
}

=pod

=item * setStarSchemasSQLConnectInfoOnQueryManager 

=cut
sub setStarSchemasSQLConnectInfoOnQueryManager {
    my $product = shift;
    my $queryManager = shift;

    my @starSchemaIds = starSchemaIdsForProduct($product);
    my @connectKeypaths = starSchemaKeypathsForProduct($product);

    for (my $i = 0; $i < @connectKeypaths; $i++) {
        my $starSchemaId = $starSchemaIds[$i];
        my $connectKeypath = $connectKeypaths[$i];

        $queryManager->setSQLConnectInfo(connectInfoForOracleClient($product, $connectKeypath), $starSchemaId);
    }
}

=pod

=item * setTransactionSchemaSQLConnectInfoOnQueryManager 

=cut
sub setTransactionSchemaSQLConnectInfoOnQueryManager {
    my $product = shift;
    my $queryManager = shift;

    foreach my $schemaId (transactionSchemaIdsForProduct($product)) {
        my ($dbc) = ariba::Ops::DBConnection->connectionsForProductOfDBTypeAndSchemaId( $product, ariba::Ops::DBConnection::typeMain(), $schemaId);

        $queryManager->setSQLConnectInfoFromDBConnection($dbc, $schemaId);
    }
}

=pod

=item * activeDBRoleForHostInCluster 

=cut
sub activeDBRoleForHostInCluster {
    my $product = shift;
    my $host = shift;
    my $cluster = shift;

    #XXXX FIX THIS!!!!!  Some callers call this with args in wrong order!!
    if ( ref($host) ) {
        my $temp = $host;
        $host = $product;
        $product = $temp;
    }

    my @roles = ('database', 'reporting-database', 'dr-database') ;

    for my $role (@roles) {

            my $virtualHost = $product->virtualHostForRoleInCluster($role, $cluster) || next;
            my $activeHost  = $product->activeHostForVirtualHostInCluster($virtualHost, $cluster);

        if (defined $activeHost && $host eq $activeHost) {
            return $role;
        }
    }

    return undef;
}

=pod

=item * productsToRestartAfterDeployment 

=cut
sub productsToRestartAfterDeployment {
    my $product = shift;

    my @answer;
    
    if (ariba::rc::InstalledProduct->isInstalled("ws", $product->service())) {
        my $wsProd = ariba::rc::InstalledProduct->new("ws", $product->service());
        foreach my $role ($wsProd->allRolesInCluster("primary")) {
            if (scalar($product->appInstancesVisibleViaRoleInCluster($role,
                                          "primary"))) {
                push @answer, "ws";
                last;
            }
        }
    }

    if (ariba::rc::InstalledProduct->isInstalled("aesws", $product->service)) {
        my $aeswsProd = ariba::rc::InstalledProduct->new("aesws", $product->service());
        foreach my $role ($aeswsProd->allRolesInCluster("primary")) {
            if (scalar($product->appInstancesVisibleViaRoleInCluster($role,
                                          "primary"))) {
                push @answer, "aesws";
                last;
            }
        }
    }

    if (ariba::rc::InstalledProduct->isInstalled("ssws", $product->service)) {
        my $sswsProd = ariba::rc::InstalledProduct->new("ssws", $product->service());
        foreach my $role ($sswsProd->allRolesInCluster("primary")) {
            if (scalar($product->appInstancesVisibleViaRoleInCluster($role,
                                          "primary"))) {
                push @answer, "ssws";
                last;
            }
        }
    }

    return @answer;
}

=pod

=item * webserverRole

maps webserver product name to role in that webserver product's roles.cfg 

=cut

sub webserverRole {
    my $product = shift;

    my $productName = $product->name();

    my $role = 'webserver';

    my $prefix = $productName;
    $prefix =~ s/ws//;

    $role = $prefix . "-" . $role if $prefix;

    if ( $productName =~ /cws/i ){
        $role = 'cwswebserver';
    }

    if ( $productName =~ /mws/i ){
        $role = 'mwswebserver';
    }

    return $role;
}

=pod

=back

=cut

1;
