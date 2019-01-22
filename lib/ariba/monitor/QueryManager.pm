
# wing keys can be set in a queries hash as hints to QueryManager:
#   runForCommunities: create Query object for ',' seperated list of
#                        communities
#   runForSchemaIds: create Query object for ',' seperated list of schema IDs
#   aggregationMethod: rows|counts create an AggregateQuery for
#                                list of communities Queries
#                                rows: combine results using simple addition
#                                      of results.
#                                counts: combine results by simply listing
#                                        each row from results one after
#                                        the other (may be sorted?)
#
#

package main;

require "sysexits.ph";

package ariba::monitor::QueryManager;

use strict;
use vars qw(@ISA);
use Cwd qw( realpath );

use ariba::monitor::Query;
use ariba::monitor::AggregateQuery;

use ariba::Ops::Utils;
use ariba::Ops::Machine;

use ariba::Ops::PersistantObject;

use ariba::rc::Utils;
use ariba::rc::Globals;

use dmail::LockLib;
use Data::Dumper;
use DateTime;

use Scalar::Util qw(looks_like_number);

@ISA = qw(ariba::Ops::PersistantObject);

our $inf_field_type_string = "string";
our $inf_field_type_raw = "raw";

my $monitorDir  = ariba::monitor::misc::monitorDir();
my $qmExtension = ".qm";
my $ran_as_user;


sub newWithDetails
{
    my $class        = shift;
    my $qmName       = shift () || die "need queryManagerName";
    my $productName  = shift;
    my $serviceName  = shift;
    my $customerName = shift;
    my $clusterName  = shift;
    my $queriesHash  = shift;
    my $subDir       = shift;

    # Maintain backward compatibility with old API / datastore without cluster concept
    if (ref ($clusterName) eq 'HASH')
    {
        $queriesHash = $clusterName;
        undef ($clusterName);
    }
    undef ($clusterName) unless (ariba::rc::Globals::isActiveActiveProduct($productName));

    #
    # obsolete API
    #
    if (ref ($qmName) eq "HASH")
    {
        #old API ordering
        die "Error: wrong order of args to ${class}->new()\n";
    }
    if (ref ($customerName) eq "HASH")
    {
        #old API ordering
        die "Error: wrong order of args to ${class}->new()\n";
    }

    my $id = $class->generateInstanceName($qmName, $productName, $customerName, $clusterName, $subDir);
    my $self = $class->SUPER::new($id);
    bless ($self, $class);

    my $makerFile = $class->_computeBackingStoreForInstanceName($id) . ".inprogress-marker";
    $self->setInProgressMarkerFile($makerFile);
    $self->setName($qmName);
    $self->setProductName($productName);
    $self->setCustomer($customerName);
    $self->setCluster($clusterName);
    $self->setService($serviceName);
    $self->setRunTime(undef);
    $self->setTotalThreadTime(undef);

    $self->setTickMetaData(1);
    if (defined $queriesHash->{"influx_details"})
    {
        my $inf = $queriesHash->{"influx_details"};
        $self->setInflux($inf->{'measurement'});
        my $script = realpath "$0";
        $self->setTags($self->_computeTags($productName, $serviceName, $script, $inf->{tags}));
        delete $queriesHash->{"influx_details"};
    }

    if (ref ($queriesHash) eq "HASH")
    {
        $self->convertQueriesHashToQuery($queriesHash, $subDir);
    }
    else
    {
        #old style setting of details, with run method on Query
        #this is not allowed
        die "Error: details should not be set like this anymore\n";
    }

    return $self;
}

sub generateInstanceName
{
    my $class        = shift;
    my $qmName       = shift;
    my $productName  = shift;
    my $customerName = shift;
    my $clusterName  = shift;
    my $subDir       = shift;

    # Maintain backward compatibility for existing datastore without cluster concept
    undef ($clusterName) unless (ariba::rc::Globals::isActiveActiveProduct($productName));

    my $qmDir = $productName;
    if (defined ($customerName))
    {
        $qmDir .= "/$customerName";
    }
    if (defined ($clusterName))
    {
        $qmDir .= "/$clusterName";
    }
    if (defined ($subDir))
    {
        $qmDir .= "/$subDir";
    }

    my $id = "$qmDir/$qmName";

    return $id;
}

sub objectLoadMap
{
    my $class = shift;

    my $mapRef = $class->SUPER::objectLoadMap();

    $$mapRef{'queries'}           = '@ariba::monitor::Query';
    $$mapRef{'runForCommunities'} = '@SCALAR';
    $$mapRef{'runForSchemaIds'}   = '@SCALAR';

    return $mapRef;
}

sub dir
{
    my $class = shift;

    return ariba::monitor::misc::queryManagerStorageDir();
}

sub _computeBackingStoreForInstanceName
{
    my $class        = shift;
    my $instanceName = shift;

    # this takes the instance name as an arg
    # so that the class method objectExists() can call it

    my $file;

    if ($instanceName =~ m|^/|)
    {
        $file = $instanceName;
    }
    else
    {
        $file = $class->dir() . "/" . $instanceName;
    }

    if ($instanceName !~ m|$qmExtension$|)
    {
        $file .= $qmExtension;
    }

    $file =~ s/\.\.//o;
    $file =~ s|//|/|go;

    return $file;
}

sub _computeTags
{
    my ($self, $productName, $serviceName, $caller, $inf_tags) = @_;

    my $hostname = ariba::Ops::NetworkUtils::hostname();
    my $dc       = ariba::Ops::Machine->new()->datacenter();
    my $tag_str  = qq(product=$productName,dc=$dc,service=$serviceName,ran_on_host=$hostname,ran_by=$caller);

    ### Return if $tag_str is null
    return ($tag_str) unless ($inf_tags);

    ### Escape space
    $tag_str =~ s/(\s+)/\\$1/g;

    my @tags = split (/,/, $inf_tags);    ### Append all the other flags, besides product,service etc
    foreach my $tag (@tags)
    {
        next if ($tag =~ /^product/);
        next if ($tag =~ /^service/);
        next if ($tag =~ /^dc/);
        $tag_str .= ",$tag";
    }
    return ($tag_str);
}

#
# return instances of QueryManager objects on disk for a given product.
# this is to that vm knows what objects to display for a product tab.
#
sub instancesForProduct
{
    my $class    = shift;
    my $product  = shift;
    my $customer = shift;
    my $cluster  = shift;

    my $root = $class->dir();

    my $productRoot = $root;
    $productRoot = "$root/$product" if ($product);
    $productRoot .= "/$customer" if ($customer);
    $productRoot .= "/$cluster"  if ($cluster);

    my @instances;
    opendir (QMDIR, $productRoot) || return @instances;
    my @contents = grep (!/^\./o, readdir (QMDIR));
    closedir (QMDIR);

    @contents = grep (($_ = "$productRoot/$_"), @contents);

    for my $file (sort (grep (-f $_, @contents)))
    {
        $file =~ s|^$root/||;
        next unless ($file =~ m|$qmExtension$|);
        my $qm = $class->new($file);
        push (@instances, $qm);
    }

    for my $sdir (grep (-d $_, @contents))
    {
        $sdir =~ s|^$root/||;

        # when we recurse we do not pass customer/cluster, because
        # it only shows up in the path at the top
        push (@instances, $class->instancesForProduct($sdir));
    }

    return @instances;
}

sub DESTROY
{
    my $self = shift;

    $self->deleteAttribute('queries');

    $self->_doneProgress();
}

sub convertQueriesHashToQuery
{
    my $self        = shift;
    my $queriesHash = shift;
    my $subDir      = shift;

    my @queries;

    for my $queryName (sort (keys (%$queriesHash)))
    {
        my $qhashRef = $queriesHash->{$queryName};

        my %queryHash = %$qhashRef;
        #
        # some keys in the hash are actually hints to QueryManager
        # process them at this level and do not pass it down
        # to Query constructor
        #
        for my $qmHint (qw(runForCommunities runForSchemaIds aggregationMethod recordAggregateDBFileName))
        {

            delete $queryHash{$qmHint} if $qhashRef->{$qmHint};
        }

        my $aggregateOn           = $qhashRef->{"aggregationMethod"};
        my $qmHint                = "runForCommunities";
        my %communitiesAndSchemas = ();

        my @communities = (0);
        if ($qhashRef->{$qmHint})
        {
            @communities = split (/\s*,\s*/, $qhashRef->{$qmHint});
            push (@{$communitiesAndSchemas{"community"}}, @communities);
            $self->setRunForCommunities(@communities);
        }

        $qmHint = "runForSchemaIds";
        my @schemaIds = (0);
        if ($qhashRef->{$qmHint})
        {
            @schemaIds = split (/\s*,\s*/, $qhashRef->{$qmHint});
            push (@{$communitiesAndSchemas{"schema"}}, @schemaIds);
            $self->setRunForSchemaIds(@schemaIds);
        }

        #
        # If no hint was set, add a fake entry, so we can get
        # a query object created
        #
        unless (keys (%communitiesAndSchemas))
        {
            push (@{$communitiesAndSchemas{"none"}}, @schemaIds);
        }

        my (@queryList, $q, $querySubDir);

        for my $subQuery (keys (%communitiesAndSchemas))
        {
            my @parts = @{$communitiesAndSchemas{$subQuery}};
            for my $part (@parts)
            {

                my $communityQueryName = $queryName;
                my %communityQueryHash = %queryHash;
                if ($aggregateOn)
                {
                    $communityQueryHash{'isPartOfAggregate'} = 1;
                }
                $querySubDir = $subDir;

                if ($part > 0)
                {
                    $communityQueryName = "$queryName for $subQuery $part";
                    $communityQueryHash{"${subQuery}Id"} = $part;

                    unless ($qhashRef->{"uiHint"} eq "ignore")
                    {
                        if ($qhashRef->{"uiHint"})
                        {
                            $communityQueryHash{"uiHint"} = "$qhashRef->{'uiHint'}/$subQuery $part";
                        }
                        else
                        {
                            $communityQueryHash{"uiHint"} = "$subQuery $part";
                        }
                    }

                    if ($subDir)
                    {
                        $querySubDir = "$subDir/$part";
                    }
                    else
                    {
                        $querySubDir = $part;
                    }
                }

                $q = ariba::monitor::Query->newFromHash($communityQueryName, $self->productName(), $self->service(), $self->customer(), $self->cluster(), \%communityQueryHash, $querySubDir, $self,);

                push (@queryList, $q);
            }
        }

        push (@queries, @queryList);

        if ($aggregateOn)
        {
            $q = ariba::monitor::AggregateQuery->newWithSubQueries($queryName, $self->productName(), $self->service(), $self->customer(), $self->cluster(), $subDir, $aggregateOn, $qhashRef->{'recordAggregateDBFileName'}, $self, @queryList);

            push (@queries, $q);
        }
    }

    $self->setQueries(@queries);
}

#
# given an expando and list of expandos, recursively get all the Query object
# that will live under that expando (this is used for getting
# commulative status, runtime and other stats for the expando)
#
sub _queriesForExpandoAndChildren
{
    my $self     = shift;
    my $expando  = shift;
    my @expandos = @_;

    my @queries = $self->queriesForExpando($expando);

    for my $childExpando (@expandos)
    {
        next if ($childExpando eq $expando);

        unless ($childExpando =~ m|^$expando/|)
        {
            last;
        }
        push (@queries, $self->queriesForExpando($childExpando));
    }

    return @queries;

}

#
# get commulative status of the expando based on it's own Query objects
# and any other child expando's Query objects.
#
sub statusForExpando
{
    my $self     = shift;
    my $expando  = shift;
    my @expandos = @_;

    #
    # This code does not look at status on query manager but directly
    # looks into each query object. This has a side effect of expando
    # remaining in the right state even when corresponding query manager
    # might have been marked crit due to staleness. Magic behavior!
    #
    my $status = ariba::monitor::Query::combineStatusOfQueries($self->_queriesForExpandoAndChildren($expando, @expandos));

    return $status;
}

sub setServerConnection
{
    my $self = shift;
    $self->{'serverConnection'} = shift;
}

sub serverConnection
{
    my $self = shift;
    return $self->{'serverConnection'};
}

sub setOracleClient
{
    my $self          = shift;
    my $oracleClient  = shift;
    my $connectionTag = shift;

    if ($connectionTag)
    {
        $self->{'oracleClientForTag'}{$connectionTag} = $oracleClient;
    }
    else
    {
        $self->{'oracleClient'} = $oracleClient;
    }

    for my $query ($self->queries())
    {
        if (
            (!$connectionTag && !$query->communityId() && !$query->schemaId())
            || (   $query->communityId()
                && $connectionTag
                && $query->communityId() eq $connectionTag)
            || (   $query->schemaId()
                && $connectionTag
                && $query->schemaId() eq $connectionTag)
           )
        {
            $query->setOracleClient($oracleClient);
        }
    }
}

sub oracleClient
{
    my $self          = shift;
    my $connectionTag = shift;

    if ($connectionTag)
    {
        return $self->{'oracleClientForTag'}{$connectionTag};
    }
    else
    {
        return $self->{'oracleClient'};
    }
}

sub setHanaClient
{
    my $self          = shift;
    my $hanaClient    = shift;
    my $connectionTag = shift;

    if ($connectionTag)
    {
        $self->{'hanaClientForTag'}{$connectionTag} = $hanaClient;
    }
    else
    {
        $self->{'hanaClient'} = $hanaClient;
    }

    for my $query ($self->queries())
    {
        if (
            (!$connectionTag && !$query->communityId() && !$query->schemaId())
            || (   $query->communityId()
                && $connectionTag
                && $query->communityId() eq $connectionTag)
            || (   $query->schemaId()
                && $connectionTag
                && $query->schemaId() eq $connectionTag)
           )
        {
            $query->setHanaClient($hanaClient);
        }
    }
}

sub hanaClient
{
    my $self          = shift;
    my $connectionTag = shift;

    if ($connectionTag)
    {
        return $self->{'hanaClientForTag'}{$connectionTag};
    }
    else
    {
        return $self->{'hanaClient'};
    }
}

sub setMySQLClient
{
    my $self          = shift;
    my $mySQLClient   = shift;
    my $connectionTag = shift;

    if ($connectionTag)
    {
        $self->{'mySQLClientForTag'}{$connectionTag} = $mySQLClient;
    }
    else
    {
        $self->{'mySQLClient'} = $mySQLClient;
    }

    for my $query ($self->queries())
    {
        if (
            (!$connectionTag && !$query->communityId() && !$query->schemaId())
            || (   $query->communityId()
                && $connectionTag
                && $query->communityId() eq $connectionTag)
            || (   $query->schemaId()
                && $connectionTag
                && $query->schemaId() eq $connectionTag)
           )
        {
            $query->setMySQLClient($mySQLClient);
        }
    }
}

sub mySQLClient
{
    my $self          = shift;
    my $connectionTag = shift;

    if ($connectionTag)
    {
        return $self->{'mySQLClientForTag'}{$connectionTag};
    }
    else
    {
        return $self->{'mySQLClient'};
    }
}

sub setSQLConnectInfoFromDBConnection
{
    my $self   = shift;
    my $dbconn = shift;

    my $dbServerType = $dbconn->dbServerType();
    if ($dbServerType && $dbServerType eq ariba::Ops::DBConnection->hanaDBServerType()) {
        return $self->setSQLConnectInfoForHana($dbconn->user(), $dbconn->password(), $dbconn->host(), $dbconn->port(), undef, @_);
    }
    else {
        return $self->setSQLConnectInfo($dbconn->user(), $dbconn->password(), $dbconn->sid(), $dbconn->host(), @_);
    }
}

sub setSQLConnectInfo
{
    my $self          = shift;
    my $user          = shift;
    my $password      = shift;
    my $sid           = shift;
    my $hostname      = shift;
    my $connectionTag = shift;

    eval 'use ariba::Ops::OracleClient';
    die "Eval Error: $@\n" if ($@);

    my $oracleClient = ariba::Ops::OracleClient->new($user, $password, $sid, $hostname);

    unless ($oracleClient->connect(20, 4))
    {
        # this will show up in the qm backing store file at least
        $self->setSQLError($oracleClient->error());
    }
    else
    {
        $self->setSQLError();
    }

    $self->setOracleClient($oracleClient, $connectionTag);
}

sub setSQLConnectInfoForMySQL
{
    my $self = shift;

    my $user     = shift;
    my $password = shift;
    my $hostname = shift;
    my $port     = shift;
    my $database = shift;

    my $connectionTag = shift;

    eval 'use ariba::Ops::MySQLClient';
    die "Eval Error: $@\n" if ($@);

    my $mySQLClient = ariba::Ops::MySQLClient->new($user, $password, $hostname, $port, $database);

    unless ($mySQLClient->connect(20, 4))
    {
        # this will show up in queryInspector
        $self->setSQLError($mySQLClient->error());
    }
    else
    {
        $self->setSQLError();
    }

    $self->setMySQLClient($mySQLClient, $connectionTag);
}

sub setSQLConnectInfoForHana
{
    my $self = shift;

    my $user     = shift;
    my $password = shift;
    my $hostname = shift;
    my $port     = shift;
    my $database = shift;

    my $connectionTag = shift;

    eval 'use ariba::Ops::HanaClient';
    die "Eval Error: $@\n" if ($@);

    my $hanaClient = ariba::Ops::HanaClient->new($user, $password, $hostname, $port, $database);

    unless ($hanaClient->connect(20, 4))
    {
        # this will show up in queryInspector
        $self->setSQLError($hanaClient->error());
    }
    else
    {
        $self->setSQLError();
    }

    $self->setHanaClient($hanaClient, $connectionTag);
}

sub setSQLConnectInfoFromOracleClient
{
    my $self          = shift;
    my $oracleClient  = shift;
    my $connectionTag = shift;

    eval 'use ariba::Ops::OracleClient';
    die "Eval Error: $@\n" if ($@);

    unless ($oracleClient->isa("ariba::Ops::OracleClient"))
    {
        die "setSQLConnectInfoFromOracleClient() requires an ariba::Ops::OracleClient";
    }

    $self->setOracleClient($oracleClient, $connectionTag);
}

sub setSQLConnectInfoFromHanaClient
{
    my $self          = shift;
    my $hanaClient    = shift;
    my $connectionTag = shift;

    eval 'use ariba::Ops::HanaClient';
    die "Eval Error: $@\n" if ($@);

    unless ($hanaClient->isa("ariba::Ops::HanaClient"))
    {
        die "setSQLConnectInfoFromHanaClient() requires an ariba::Ops::HanaClient";
    }

    $self->setHanaClient($hanaClient, $connectionTag);
}

sub setSQLConnectInfoFromMySQLClient
{
    my $self          = shift;
    my $mySQLClient   = shift;
    my $connectionTag = shift;

    eval 'use ariba::Ops::MySQLClient';
    die "Eval Error: $@\n" if ($@);

    unless ($mySQLClient->isa("ariba::Ops::MySQLClient"))
    {
        die "setSQLConnectInfoFromMySQLClient() requires an ariba::Ops::MySQLClient";
    }

    $self->setMySQLClient($mySQLClient, $connectionTag);
}

sub setAQLClient
{
    my $self          = shift;
    my $aqlClient     = shift;
    my $connectionTag = shift;

    if ($connectionTag)
    {
        $self->{'aqlClientForTag'}{$connectionTag} = $aqlClient;
    }
    else
    {
        $self->{'aqlClient'} = $aqlClient;
    }

    for my $query ($self->queries())
    {
        $query->setAQLClient($aqlClient);
    }
}

sub AQLClient
{
    my $self          = shift;
    my $connectionTag = shift;

    if ($connectionTag)
    {
        return $self->{'aqlClientForTag'}{$connectionTag};
    }
    else
    {
        return $self->{'aqlClient'};
    }
}

sub setAQLConnectInfo
{
    my $self          = shift;
    my $product       = shift;
    my $connectionTag = shift;

    eval 'use ariba::Ops::AQLClient';
    die "Eval Error: $@\n" if ($@);

    my $aqlClient = ariba::Ops::AQLClient->new($product);

    $aqlClient->connect();

    $self->setAQLClient($aqlClient, $connectionTag);
}

sub setAQLConnectInfoFromAQLClient
{
    my $self          = shift;
    my $aqlClient     = shift;
    my $connectionTag = shift;

    eval 'use ariba::Ops::AQLClient';
    die "Eval Error: $@\n" if ($@);

    unless ($aqlClient->isa("ariba::Ops::AQLClient"))
    {
        die "setAQLConnectInfoFromAqlClient() requires an ariba::Ops::AQLClient";
    }

    $self->setAQLClient($aqlClient, $connectionTag);
}

sub run
{
    my $self = shift;

    for my $query ($self->queries())
    {

        next if $query->skip();

        $query->run();
        $query->runProcessAnswer();
    }
}

sub generateTickMetaData
{
    my $self = shift;

    my $service = $self->service();

    ### Hardcoding to run only for test,dev and prod
    return if ( $service ne 'test' and $service ne 'dev' and $service ne 'prod');

    my $measurement_name = $self->{_info}->{influx};
    return unless ( $measurement_name );

    my $dt = DateTime->today( time_zone => 'local' );
    my $year  = $dt->year;
    my $month = sprintf( "%02d", $dt->month() );
    my $day   = sprintf( "%02d", $dt->day() );
    my $d     = "$year-$month-$day";

    my $nfs_loc   = { dev => "/subzero/opsdumps/$d/stratus", test => "/subzero/opsdumps/$d/stratus", prod => "/nfs/never/monprod/stratus/$d" };

    ### Create base directory, if not present with 777, so other non mon<service> scripts can write the data
    my $fs = $nfs_loc->{$service};
    unless ( -e $fs )
    {
        ariba::rc::Utils::mkdirRecursively($fs);
        chmod(0777,$fs);
    }

    my $meta_data = ();
    for my $query ($self->queries())
    {
        my $inf_field   = $query->{_info}->{inf_field};
        my $sql         = $query->{_info}->{sql};

        next if ( !$inf_field && !$sql );

        my @fields ;
        if ( $sql )
        {
            if ( ref($query->{_info}->{results}) eq 'ARRAY')
            {
                my $hash = $query->{_info}->{results}->[0];
                my @tempf= ( keys %{$hash});
                @fields = map{ lc($_)} @tempf;
            }
            if ( ref($query->{_info}->{results}) eq 'HASH')
            {
                foreach my $key (keys %{$query->{_info}->{results}})
                {
                        push(@fields, lc($key));
                }
            }
        } else {
            push(@fields, $inf_field);
        }

        foreach my $field ( @fields )
        {
            ### Create alert meta file only if the query has 'crit' condition defined
            if ( $query->{_info}->{crit} )
            {
                $meta_data->{$measurement_name}->{$field}->{info} = $query->{_info}->{info};
                $meta_data->{$measurement_name}->{$field}->{warn} = $query->{_info}->{warn};
                $meta_data->{$measurement_name}->{$field}->{crit} = $query->{_info}->{crit};
            }
        }
    }

    ### Generate flat file
    my $script_name = ariba::Ops::Utils::basename($0);
    foreach my $measurement ( keys %{$meta_data} )
    {
        my $f_name = qq($fs/threshold_).qq($script_name).qq(--).qq($measurement).qq(.txt);
        open(my $fh, ">", $f_name) || die "error:$!\n";
        foreach my $field ( keys %{$meta_data->{$measurement}} )
        {
            my $row = qq($measurement;$field;);
            my $field_hash = $meta_data->{$measurement}->{$field};
            foreach my $key ( keys %{$field_hash} )
            {
                $row .= qq($key:$field_hash->{$key};) if defined $field_hash->{$key};
            }
            print $fh "$row\n";
        }
        close($fh);
    }
}

sub generateInfluxLines
{
    my $self = shift;

    my $influxLines = {};

    for my $query ($self->queries())
    {
        next if ($query->{_info}->{measurement});

        ### Get ran_as_user. We'll store it in global variable and use it later
        $ran_as_user  = $query->{_info}->{ranAsUser};

        ### Run for schemas
        my $schema_id = ($query->{_info}->{schemaId}) ? $query->{_info}->{schemaId} : undef;

        ### Get meta info
        my $cid         = ($query->{_info}->{communityId}) ? $query->{_info}->{communityId} : 0;
        my $results     = $query->{_info}->{results};
        my $group_by    = $query->{_info}->{group_by} || undef;
        my $inf_tags    = ($query->{_info}->{inf_tags}) ? ($query->{_info}->{inf_tags}) : undef;
        my $inf_default = $query->{_info}->{inf_default};
        my $inf_field   = $query->{_info}->{inf_field};
        my $inf_field_type  = ($query->{_info}->{inf_field_type}) ? $query->{_info}->{inf_field_type} : $inf_field_type_raw;
        my $row_key     = $group_by || qq(row_1);

        ### lower case only tag name and not values
        my $new_tags;
        if ( $inf_tags )
        {
            my @all_tags = split(/\,/,$inf_tags);
            foreach my $tag ( @all_tags )
            {
                my ($tag_name,$tag_value) = split(/=/,$tag);
                $tag_name = lc($tag_name);
                $new_tags .= qq($tag_name=$tag_value,)
            }

            ### Remove last comma
            $new_tags =~ s/\,$//;
        }

        ### Make the measurement for dropping, if there's a change
        $influxLines->{RECREATE_MEASUREMENT} = 1 if ( $new_tags && $new_tags ne $inf_tags && !$influxLines->{RECREATE_MEASUREMENT});
        $inf_tags = $new_tags;

        ### Escape space in tag and community
        $inf_tags =~ s/(\s+)/\\$1/g if ( $inf_tags );
        $cid      =~ s/(\s+)/\\$1/g if ( $cid );

        ### If rfc is present
        if ($cid)
        {
            ### Concat with existing group_by
            $row_key = ($group_by) ? qq(community=$cid) . qq(_) . $group_by : qq(community=$cid);

            ### Add community to existing tags
            $query->{_info}->{inf_tags} = $inf_tags = ($inf_tags) ? qq(community="$cid",$inf_tags) : qq(community="$cid");
        }

        if ( $schema_id )
        {
            ### Concat with existing group_by
            $row_key = ($group_by) ? qq(schema_id=$schema_id) . qq(_) . $group_by : qq(schema_id=$schema_id);

            ### Add community to existing tags
            $query->{_info}->{inf_tags} = $inf_tags = ($inf_tags) ? qq(schema_id="$schema_id",$inf_tags) : qq(schema_id="$schema_id");
        }

        ### Escape comma's in tag values && Process multi-col results
        if ( $inf_tags )
        {
            $inf_tags = $self->escape_commas_between_quotes($inf_tags);
            $influxLines->{$row_key}->{tag} = $inf_tags;
        }

        if (ref ($results) eq 'HASH')
        {
            ### Copy key/value to influxLines hash
            foreach my $key (keys %{$results})
            {
                $influxLines->{$row_key}->{$key} = $self->doubleQuote($results->{$key}, $inf_field_type);
            }
        }
        elsif (ref ($results) eq 'ARRAY')  ### AoA or AoH
        {
            my $i = 0;
            foreach my $row (@{$results})
            {
                if ( ref($row) eq 'HASH' )
                {
                    $i++;
                    $influxLines->{$i} = $row;
                    $influxLines->{$i}->{tag} = ( $inf_tags ) ? $inf_tags.qq(,row_id=$i) : qq(row_id=$i);
                } elsif ( ref($row) eq 'ARRAY' || ref($row) eq '' )
                {
                    $influxLines->{$row_key}->{$inf_field."_cnt"} = scalar(@{$query->{_info}->{results}});
                    $influxLines->{$row_key}->{$inf_field}        = join(",",@{$query->{_info}->{results}});
                }
            }
        }
        else
        {
            ### When sql error happens, it'll be a scalar and inf_field will be null
            $inf_field = "error_str" if ( $results || $inf_default ) && (!$inf_field);
            $influxLines->{$row_key}->{$inf_field} = ( (!defined $results) || $results eq '' ) ? $inf_default : $results;
            $influxLines->{$row_key}->{$inf_field} = $self->doubleQuote($influxLines->{$row_key}->{$inf_field}, $inf_field_type);
        }
    }
    #print "influx_hash" . Dumper($influxLines);
    return ($influxLines);
}

sub escape_commas_between_quotes
{
	my $self = shift;
	my $inf_tags = shift;

	my @quote_index;
        my $new_inf_tags;

        my $previous_c = '';
        my $espace_flag = -1;

	my @str = split(//, $inf_tags);
	foreach my $c (@str)
        {
		if ($c eq '"' && $previous_c ne '\\')
                {
			  $espace_flag *= -1;
		}

		$c = '\\'.$c if($espace_flag == 1 && $c eq ',' && $previous_c ne '\\');
		$new_inf_tags .= $c;

		$previous_c = $c;
        }

        #remove double quotes and escaped double quotes in tags values
        $new_inf_tags =~ s/(\\)?\"//g;

	return $new_inf_tags;

}

sub printInfluxLines
{
    my $self        = shift;
    my $influxLines = shift;

    my $measurement = $self->{_info}->{influx};
    my $parent_tag  = $self->{_info}->{tags};

    ### Prepend ran_as_user tags
    $parent_tag  .= qq(,ran_as_user=$ran_as_user);

    return unless ($measurement);

    foreach my $row_key (keys %{$influxLines})
    {

       if ( $row_key eq 'RECREATE_MEASUREMENT' )
        {
            eval {
                open( my $fh, ">>", "/tmp/stratus-recreate-measurement");
                print $fh "$measurement\n";
                close($fh);
            };
            next;
        }

        my $row = $influxLines->{$row_key};
        my $fields;
        foreach my $key (sort keys %{$row})
        {
            my $value   = $row->{$key};
            my $lc_key  = lc ($key);

            ### Do not generate field, if both key and value are empty(for some reason)
            next unless ($key || $value);
            next if ($key eq 'tag');

            ### Store strings in double quotes
            # only do this if NOT already double quoted
            $fields .= (looks_like_number($value) ||  $value =~ /^\".+\"$/ || $value =~ /^\"\"$/ ) ? qq($lc_key=$value,) : qq($lc_key="$value",);
        }

        ### Do not generate line when there're no fields
        next unless ($fields);
        chop ($fields);

        ### alert_id is for kapacitor/ops.ariba.com -> alert validation
        ### escape = & comma
        my $alert_id = $row->{tag};
        $alert_id =~ s/([=,])/\\$1/gi if ($alert_id);

        my $line = qq($measurement,$parent_tag);
        $line .= qq(,$row->{tag}) if ($row->{tag});
        $line .= qq(,alert_id=$alert_id) if ( $alert_id);
        $line .= qq( $fields) if ($fields);
        print "$line\n";
    }
}

sub processQueries
{
    my $self               = shift;
    my $quickView          = shift;
    my $notifyEmailAddress = shift;
    my $notifyOnWarn       = shift;
    my $notifyOnCrit       = shift;

    $self->run();

    ### Ignore the error, if metadata generation can't happen for any reason
    eval {
        $self->generateTickMetaData() if ( $self->tickMetaData() );
    };

    my $influxLines = $self->generateInfluxLines();
    $self->printInfluxLines($influxLines);

    # no clue what correct return value should be
    return 1;
}

sub doubleQuote
# util function that will try to determine if value needs to be enclosed in doubleQuotes
{
      my $self               = shift;
      my $value              = shift;
      my $treatAs            = shift;
      # a hack - rm \n if exist - we really need to rewrite with tests influx line rendering!
      $value =~ s/\n//g;

      if ( (! defined $treatAs ) || $treatAs ne $inf_field_type_string ) {

        # return as is
        return $value
      }
      # this is a string, if not already double quoted do so now
      if  ( $value !~ /^\".+\"$/ ) {
         $value =~ s/[\n\"]//g;
         $value = '"' . $value . '"';
      }
      return $value;
}

1;
