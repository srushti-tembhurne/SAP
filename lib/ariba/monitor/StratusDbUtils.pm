#!/usr/local/bin/perl
package ariba::monitor::StratusDbUtils;

use strict;
no warnings;
use ariba::Ops::OracleClient;
use ariba::Ops::HanaClient;
use ariba::Ops::Constants;
use ariba::Ops::DateTime;
use ariba::Ops::DBConnection;
use ariba::rc::InstalledProduct;
use Data::Dumper;
use Net::SSH::Perl;
use YAML qw(LoadFile);
use DBI;
use POSIX;

sub new
{
    my $class = shift;
    my $args = shift;

    my $self = 
        {
            "_dbCfg" => $args->{dbCfg},
            "_metricsCfg" => $args->{metricsCfg},
            "user" => $args->{db_user} || "system",
            "use_active_host" => $args->{use_active_host} || 0,
            "debug" => $args->{debug},
            "bucket_number" => $args->{bucket_number},
            "bucket_total" => $args->{bucket_total},
        };
    bless ($self,$class);
    $self->_initialize() or die "Fail to initialize $class\n";
    return $self;
}

sub _initialize
{
    my $self = shift;
    if (defined $self->{_dbCfg} && -e $self->{_dbCfg})
    {
        $self->{DBCFG} = LoadFile($self->{_dbCfg});
    }
    #else
    #{
    #    return 0;
    #}

    if ($self->{_dbCfg} =~ /db_(.*)$/)
    {
        $self->{dbType} = $1
    }
    else
    {
        return 0;
    }
    $self->{logfile} = $self->getLogFile();
    my $user = $self->{user};
    my $me = ariba::rc::InstalledProduct->new();
    $self->{pwd} = $me->default("dbainfo.$user.password");
    $self->{hana_pwd} = $me->default("dbainfo.hana.system.password");
    $self->{hana_port} = '30015';
    chomp($self->{hostname} = `hostname`);
    chomp($self->{ranAsUser} = `whoami`);
    $self->{tl_values} = {};
    return 1;

}

sub getLogFile
{
    my $self = shift;
    return $self->{logfile} if defined $self->{logfile};

    my $timestamp = time();
    my($day, $month, $year) = (localtime)[3,4,5];
    $month = sprintf '%02d', $month+1;
    $day   = sprintf '%02d', $day;
    if( ! -d '/tmp/fovea') 
    {
        `mkdir '/tmp/fovea'`;
    }

    #my $logfile = "/tmp/fovea/$self->{dbType}_db_mon.log."."$year$month$day";
    my $logfile = "/tmp/fovea/$self->{dbType}_db_mon.log."."$year$month$day"."_".time();
    return $logfile;
}

sub loadMetricConfigs
{
    my $self = shift;

    return $self->{cf_hash} if exists $self->{cf_hash};
    return unless (defined ($self->{_metricsCfg}) && -e $self->{_metricsCfg});
    open(my $FH, '<', $self->{_metricsCfg}) or die "Fail to open $self->{_metricsCfg} for reading:$!\n";
    my @metricConfigs = <$FH>;
    close ($FH);

    my $cfhash;

    my $line = 0;
    foreach my $cf(@metricConfigs){
        $line++;
        next if($cf =~ /^\#/);
        chomp($cf);
        next if($cf !~ /\!\!/);
        my @temp  = split /\s+\!\!\s+/, $cf;

        my $metric = {};
        my $sid    = $temp[0];
        my $m_name = $temp[2];

        if ( $m_name =~ /AUTO$/ )
        {
            die "ERROR: missing header info for multirow query, check $m_name metrics of $self->{_metricsCfg} on line $line\n"
                unless scalar(@temp) == 5;
            $metric->{header} = $temp[4];
        }

        $metric->{sql} = $temp[3];

        # we provide special, uniquely named table-level tags/fields that are based on some standard-logic
        # these can be used by specifying them with the table name. Tags are denoted with 't', e.g.:
        #    ... !! TABLE,TAG1|t,TAG2|t,FIELD1,FIELD2,FIELD3 !! ...
        my $table = $temp[1];
        if ( $table =~ /,/ ) {
            my @tvalues = ();
            ($table, @tvalues) = split( /\s*\,\s*/, $table );
            foreach my $tv_name ( @tvalues ) {
                my $tag      = 0;   # default is field
                my $modifier = '';

                # if we have modifier, it will be to designate tag (not field)
                if ( $tv_name =~ /\s*(.*)\s*\|(.*)/ ) {
                    $tv_name  = $1;
                    $modifier = $2;
                    $tag = 1  if ( $modifier =~ /t/ );
                }

                # multiple metrics (even in the same table/measurement), using a special table-level field/tag,
                # should all specify it (in case some get removed later) but we'll take only the first occurence.
                # And, of course, the special table-level field/tag will get populated only once in the table.
                next if ( exists $self->{tl_values}{$table}{$tv_name} );

                $self->{tl_values}{$table}{$tv_name} = { tag => $tag };
            }
        }
        $metric->{table} = $table;

        $cfhash->{$sid}{$m_name} = $metric;
    }
    $self->{cf_hash} = $cfhash;
    return $cfhash;
}

sub getPmonValue 
{
    my $self = shift;
    my $sid = shift;

    chomp(my $pmon = `ps -ef | grep pmon | grep $sid | grep -v grep | tail -1`);
    return $pmon;
}

sub getActiveDbHost 
{
    my $self = shift;
    my $sid = shift;
    my $runningHost = $self->{hostname};
    ($runningHost eq $self->{DBCFG}->{$sid}->{primary})? return $self->{DBCFG}->{$sid}->{alternate} : return $self->{DBCFG}->{$sid}->{primary};    
} 

sub getTableName
{
    my $self = shift;
    my $args = shift;

    my $sid = $args->{sid};
    my $measurement = $args->{measurement};
    my $metricHash = $args->{metricHash};

    my $tableName = (defined $metricHash->{$sid}->{$measurement}->{table})? 
        $metricHash->{$sid}->{$measurement}->{table} : 
        $metricHash->{default}->{$measurement}->{table};
    return $tableName;
}

sub processMetricHash
{
    my $self = shift;
    my $args = shift;
    
    my $timeout = 20;
    my $res;

    my $sid = $args->{sid};
    my $host = $args->{host};
    $self->logit("info","Processing $sid.............................................."); 
    my $c = $args->{c} || $self->getDbConnection({user => $self->{user}, pwd => $self->{pwd},sid => $sid, host =>  $host});
    $self->loadMetricConfigs();
    my $methash = $self->{cf_hash}->{$sid} || $self->{cf_hash}->{default};

    foreach my $metric(keys %$methash){
        my $m      = $methash->{$metric};
        my $sql    = $m->{sql};
        my $influx = $m->{table};

        my @result;
        my $timeoutOccured = !$c->executeSqlWithTimeout($sql, $timeout, \@result);
        if(scalar(@result) == 0 || $c->error())
        {
            $self->logit("ERROR", $c->error()) if($c->error());
            next;
        }
        if($timeoutOccured){ $self->logit("warn", "Timed Out running". Dumper $m ."\n");}
        else 
        {
            if($metric =~ /AUTO$/){
                #The column names are part of the returned results; multi row/multi column.
                my $row_num =0;
                if (ref($result[0]) ne 'HASH' && $result[0] =~ /\t/)
                {
                    #Data returned from Hana DB is tab delimited.
                    $self->reformatResult({result => \@result, header => $m->{header}});
                }
                elsif (ref($result[0]) eq 'HASH')
                {
                    $self->logit("info","How did this happen?\n");
                }
                else 
                {
                    my $result_dump = Dumper \@result;
                    $self->logit("info","sql of unexpected data type = $sql\n");
                    $self->logit("info",$result_dump);
                    next;
                }
                my @header_list = sort (split /,/, $m->{header});
                foreach my $row(@result){
                    my @fields = keys %$row;
                    my $header_index = 0;
                    foreach my $f(sort @fields){
                        my $header_col = $header_list[$header_index];
                        (my $header_col_without_modifier = $header_col) =~ s/\|.*$//;
                        $self->logit("ERROR","field miss matched: $header_col v.s $f") unless $f =~ /^$header_col_without_modifier(\|[tifs])?$/i;
                        $res->{$sid}->{$influx}->[$row_num]->{$header_list[$header_index++]} = $row->{$f};
                    }
                    $row_num++;
                }
            }
            else {
                if (ref($result[0]) ne 'HASH')
                {
                    $res->{$sid}->{$influx}->[0]->{$metric} = $result[0];
                }
                else
                {
                    my @keys = keys %{$result[0]};
                    $res->{$sid}->{$influx}->[0]->{$metric} = $result[0]->{$keys[0]};
                }
            }
        } 
    }
    return $res;
}

sub reformatResult
{
    my $self = shift;
    my $args = shift;

    my $result = $args->{result};
    my $header = $args->{header};

    #Hana return tab-delimited data 
    my @titleRow = split /,/, $header;
    my $r = 0;
    my $new_result = [];
    foreach my $row (@$result)
    {
        my $rowmap = {};
        my @rowData = split /\t/, $row;
        for (0 .. $#titleRow)
        {
            my $key = $titleRow[$_];
            $rowmap->{$key} = $rowData[$_];
        }
        $result->[$r] = $rowmap;
        $r += 1;
    }
}

sub sendResultToInflux
{
    my $self = shift;
    my $args = shift;

    my $res = $args->{res};
    my $pName = $args->{pName};
    my $service = $args->{service};
    my $dbhost = $args->{dbhost};
    my $dbport = $args->{dbport};

    my @fres;
    foreach my $sids(keys %$res){
        foreach my $table (keys %{$res->{$sids}}) {

            # get any special table-level tags/fields for this table
            my ($tl_tags, $tl_fields) = $self->get_special_table_level_tags_fields({
                service      => $service,
                table        => $table,
                inBackup     => $args->{inBackup},
                isReplicated => $args->{isReplicated},
                isPhysicalActiveRealtimeReplication => $args->{isPhysicalActiveRealtimeReplication},
            });

            my $tags = $table.",product=".$pName.",service=".$service.",sid=".$sids;
            $tags .= ",dbhost=".$dbhost.",dbport=".$dbport;
            $tags .= ",ran_as_user=".$self->{ranAsUser}.",ran_on_host=".$self->{hostname}.",ran_by=".$0;
            $tags .= $tl_tags  if ( $tl_tags );

            my @mets = $res->{$sids}->{$table};
            foreach my $records(@mets){
                foreach my $fields(@$records){
                    my $a2emit;
                    my $additional_tags = '';
                    my @columns = sort keys %$fields;
                    foreach my $col( @columns){
                        $col =~ s/\s+$//g;
                        $col =~ s/^\s+//g;
                        $col =~ s/([\s,])/\\$1/g;

                        $fields->{$col} = 0 unless(defined $fields->{$col} && $fields->{$col} =~ /\S+/);

                        my $val = $fields->{$col};

                        if($self->isString($val)) { $val = '"'.$val.'"';}

                        if ($col =~ /\|(.*)/)
                        {
                            my $modifiers = $1;
                            (my $col_name = $col) =~ s/\|.*//;
                            if ($modifiers =~ /t/)
                            {
                                # if tag modifier, keep raw field value (i.e., dont wrap with double-quotes)
                                $val = $fields->{$col};

                                # space, comma and = sign in tag value should be escaped
                                $val =~ s/([ ,=])/\\$1/g;
                                $additional_tags .= ",$col_name=$val";
                            }
                            elsif ($modifiers =~ /([ifs])/)
                            {
                                my $matched_modifier = $1;
                                $a2emit .= $self->enforce_data_type({col_name => $col_name, value => $val, type => $matched_modifier});
                            }
                            else
                            {
                                $self->logit("Error", "unidentified modifier for $col in measurement $table");
                                $a2emit .= "$col_name=$val,";
                            }
                        }
                        else
                        {
                            $a2emit .= "$col=".$val.",";
                        }
                    }
                    next unless(defined($a2emit));
                    my $final = $tags . $additional_tags ." ". $a2emit;
                    $final =~ s/\,$//;
                    $final .= $tl_fields if ( $tl_fields );
                    #print "$final\n";     #telegraf picks this up and post to influx
                    #influxit($final);
                    $self->logit("info",$final);
                    $self->printInfluxLine($final);
                    #push @fres, $final;
                }
            }
        }
    }  
}

sub get_special_table_level_tags_fields {
    my ($self, $p) = @_;

    my $service       = $p->{service} || '';
    my $table         = $p->{table}   || '';
    my $in_backup     = $p->{inBackup}     ? 1 : 0;
    my $is_replicated = $p->{isReplicated} ? 1 : 0;
    my $is_physical_active_realtime_replication = $p->{isPhysicalActiveRealtimeReplication} ? 1 : 0;

    my ($tl_tags, $tl_fields) = ('', '');

    my $tl_values = $self->{tl_values}{$table} || {};

    my ($full_backup_threshold, $incr_backup_threshold, $any_backup_threshold) = ariba::Ops::Constants->backupFreqHana($service) if $service;

    foreach my $tv_key ( keys %$tl_values ) {
        my $tv = $tl_values->{$tv_key};
        my $kv_string = '';

        # here we have some basic table-level tags/fields
        # NOTE: make sure you format string/number values well and handle escaping of characters
        if ( $tv_key =~ /backup_age_crit_threshold/ ) {
            next unless ( $service );
            $kv_string = ( $tv_key =~ /^full/ ) ? "$tv_key=$full_backup_threshold" : 
                         ( $tv_key =~ /^incr/ ) ? "$tv_key=$incr_backup_threshold" : 
                         ( $tv_key =~ /^any/  ) ? "$tv_key=$any_backup_threshold"  : 
                         '';
        }
        elsif ( $tv_key eq 'is_replicated' ) {
            $kv_string = "is_replicated=$is_replicated";
        }
        elsif ( $tv_key eq 'is_physical_active_realtime_replication' ) {
            $kv_string = "is_physical_active_realtime_replication=$is_physical_active_realtime_replication";
        }
        elsif ( $tv_key eq 'in_backup' ) {
            $kv_string = "in_backup=$in_backup";
        }

        if ( $tv->{tag} ) {
            $tl_tags .= ",$kv_string";
        } else {
            $tl_fields .= ",$kv_string";
        }
    }

    return ($tl_tags, $tl_fields);
}

sub enforce_data_type
{
    my $self = shift;
    my $args = shift;

    my $col_name = $args->{col_name};
    my $value = $args->{value};
    my $type = $args->{type};

    if ( ($type eq 'i' && $value =~ /^\-?\d+$/) || ($type eq 'f' && $value =~ /^\-?\d+(\.\d+)?$/) || ($type eq 's') )
    {
        # for type=s, if it's not already enclosed within double quotes, do it now
        $value = '"'.$value.'"' if ($type eq 's' && $value !~ /^\".*\"$/);
        return "$col_name=$value,"; 
    }
    else
    {
        return "${col_name}_${type}=${value},";  
    }
    
}

sub isNumber
{
    my $self = shift;
    my $val  = shift;

    return ( $val =~ /^[+-]?((\d+(\.\d*)?)|(\.\d+))$/ ) ? 1 : 0;
}

sub isString
{
    my $self = shift;
    my $val = shift;

    # if it's enclosed within double quotes OR if it's not a number, then it is a string
    return ( $val =~ /^\".*\"$/ || !$self->isNumber($val) ) ? 1 : 0;
}

sub getDbConnection
{
    my $self = shift;
    my $args = shift;

    if ($args->{dbType} eq 'oracle')
    {
        return $self->getOracleConnection($args);
    }
    else
    {
        return $self->getHanaConnection($args);
    }
}

sub getOracleConnection 
{
    my $self = shift;
    my $args = shift;
    my ($user,$pwd,$sid,$host) = ($self->{user}, $self->{pwd}, $args->{sid}, $args->{host});
    my $productName = $args->{productName};
    my $oracleClient = ariba::Ops::OracleClient->new($user, $pwd, $sid, $host);

    eval {local $SIG{__WARN__} = sub {}; $oracleClient->connect(20,4)}; 
    if ($@ || $oracleClient->error())
    {
        $self->logit("ERROR", $oracleClient->error());
        print "oracle_health,sid=$sid,dbhost=$host,product=$productName isup=1\n";
    }

    return $oracleClient;
}

sub getHanaConnection
{
    my $self = shift;
    my $args = shift;

    my ($user,$pwd,$port,$host,$hanaHosts) = ($self->{user}, $self->{hana_pwd}, $args->{port}, $args->{host}, $args->{hanaHosts});
    my $productName = $args->{productName};
    my $hanaClient = ariba::Ops::HanaClient->new($user, $pwd, $host, $port, $hanaHosts);
    eval {local $SIG{__WARN__} = sub {}; $hanaClient->connect(20,4)}; 
    if ($@ || $hanaClient->error()) 
    {
        $self->logit("ERROR", $hanaClient->error());
        print "hana_isup,dbhost=$host,dbport=$port cluster_connection_status=0\n";
    }
    return $hanaClient;
}

sub getDbUniqueConnections
{
    my $self = shift;
    my $args = shift;

    my $service = $args->{service};
    my $prodName = $args->{prodName};
    my @products = ariba::rc::InstalledProduct->installedProductsList($service);

    my $dbcInfo;
    foreach my $product (@products)
    {
        my $pName = $product->name;
        my $cluster = $product->currentCluster();
        next if (defined($prodName) && ($pName ne $prodName));

	my (@all_dbcs, @dbcs, @unique_dbcs);
	if($self->{dbType} eq 'hana') {
        	@all_dbcs    = ariba::Ops::DBConnection->connectionsFromProducts([$product]);
		@dbcs = grep { $_->isHana } @all_dbcs;
        	@unique_dbcs = ariba::Ops::DBConnection->uniqueConnectionsByHostAndPort(@dbcs);
	}
	elsif ($self->{dbType} eq 'oracle') {
        	@all_dbcs    = ariba::Ops::DBConnection->connectionsFromProducts($product);
		@dbcs = grep { $_->isOracle } @all_dbcs;
        	@unique_dbcs = ariba::Ops::DBConnection->uniqueConnectionsByHostAndSid(@dbcs);
	}

        foreach my $dbc (@unique_dbcs)
        {
            my $dbType = $dbc->dbServerType();
            next unless $dbType eq $self->{dbType};
            my $productName = $dbc->product()->name();

            ### There're dbconnections with no port info.  Since, dbport is getting inserted in influx as a tag,
            ### it needs to have a default value
            my $port = $dbc->port() || "-1";
            my $isDR = $dbc->isDR();
            next if $isDR;
            # replication properties n/a for hana monitoring
            my $isReplicated = $dbc->isHana ? 0 : $dbc->isReplicated();
            my $isPhysicalActiveRealtimeReplication = $dbc->isHana ? 0 : $dbc->isPhysicalActiveRealtimeReplication();

            my $virtualHost = $dbc->host();
            my $backupHostname = $dbc->product()->activeHostForVirtualHostInCluster($virtualHost, $cluster);
            my $host = $self->{use_active_host} ? $backupHostname : $virtualHost;
            next unless $host;
            my $sid = uc($dbc->sid());

            my $hanaHosts = $dbType eq 'oracle' ? [] : $dbc->hanaHosts();

            my $c;
            eval {$c = $self->getDbConnection({dbType => $dbType,host => $host, hanaHosts => $hanaHosts, port => $port, sid => $sid, productName => $productName});};
            next if ($@);

            my $inBackup;
            eval {
                $inBackup = ariba::monitor::BackupUtils::backupIsRunning(
                    product  => $pName,
                    service  => $service,
                    hostname => $backupHostname
                );
            };
            $inBackup = 0  if ( $@ );

            if (!$c->error())
            {
                push @$dbcInfo, {
                    dbType  => $dbType,
                    product => $productName,
                    host    => $host,
                    port    => $port,
                    sid     => $sid,
                    isDR    => $isDR,
                    isReplicated => $isReplicated,
                    isPhysicalActiveRealtimeReplication => $isPhysicalActiveRealtimeReplication,
                    inBackup => $inBackup,
                    c       => $c,
                };
            }

            if ( $dbType eq 'hana' && (my $sys_db_host = $c->sysdb_host()) ) {
                my $sys_db_port = $c->sysdb_port();
                my $sys_dbc;
                eval { $sys_dbc = $self->getDbConnection({dbType => $dbType, host => $sys_db_host, port => $sys_db_port, sid => $sid}); };
                next if ($sys_dbc->error());

                push @$dbcInfo, {
                    dbType  => $dbType,
                    product => $productName,
                    host    => $sys_db_host,
                    port    => $sys_db_port,
                    sid     => $sid,
                    isDR    => $isDR,
                    isReplicated => $isReplicated,
                    isPhysicalActiveRealtimeReplication => $isPhysicalActiveRealtimeReplication,
                    inBackup => $inBackup,
                    c       => $sys_dbc,
                };
            }
        }
    }
    if (defined $self->{bucket_total} && defined $self->{bucket_number})
    {
        my $dbc_length = scalar @$dbcInfo;
        my ($lower_index,$upper_index) = $self->get_splice_index({bucket_number => $self->{bucket_number}, bucket_total => $self->{bucket_total}, array_length => $dbc_length});
        my @sort_array = sort {"$a->{sid}.$a->{host}.$a->{product}" cmp "$b->{sid}.$b->{host}.$b->{product}"} @$dbcInfo;
        my @dbc_splice = splice( @sort_array, $lower_index, $upper_index - $lower_index + 1);
        return \@dbc_splice;
    } else
    {
        return $dbcInfo;
    }
}

sub get_splice_index
{
    my $self = shift;
    my $args = shift;
    my $part_number = $args->{bucket_number};
    my $array_length = $args->{array_length};
    my $total = ($args->{bucket_total} < $args->{array_length}) ? $args->{bucket_total} : $args->{array_length} ;

    if ($part_number <= 0 || $part_number > $total)
    {
        exit;
    }
    my $lower_index = floor(($part_number-1) * $array_length / $total);
    my $upper_index = floor($part_number * $array_length / $total)-1;
    print "l = $lower_index; u = $upper_index\n" if $self->{debug};
    return ($lower_index,$upper_index);
}

sub runQueryForAllConnections
{
    my $self = shift;
    my $args = shift;

    my $service = $args->{service};
    my $prodName = $args->{prodName};
    my $dbcs = $self->getDbUniqueConnections({service => $service, prodName => $prodName});
    if ($self->{debug})
    {
        print "SID: $_->{sid},  HOST: $_->{host}, PORT: $_->{port}, PRODUCT: $_->{product}\n" foreach @$dbcs;
        exit if ($self->{debug} == 2);
    }
    foreach my $dbcInfo (@$dbcs)
    {
        my $res = $self->processMetricHash({sid => $dbcInfo->{sid}, host => $dbcInfo->{host}, c => $dbcInfo->{c}});
        $self->sendResultToInflux({
            res => $res,
            pName => $dbcInfo->{product},
            service => $service,
            dbhost => $dbcInfo->{host},
            dbport => $dbcInfo->{port},
            inBackup => $dbcInfo->{inBackup},
            isReplicated => $dbcInfo->{isReplicated},
            isPhysicalActiveRealtimeReplication => $dbcInfo->{isPhysicalActiveRealtimeReplication},
        });
    }
}

sub executeSql
{
    my $self =shift;
    my $args = shift;

    my $db = $args->{connection};
    my $timeout = $args->{timeout};
    my $sql = $args->{sql};
    my $result = $args->{result};

    if ($self->{dbType} eq 'oracle')
    {
        return !$db->executeSqlWithTimeout($sql, $timeout, $result);
    }
    else
    {
        @$result = $db->executeSql($sql);
        return 1;
    }
}

sub logit
{
    my $self = shift;
    my $level = shift;
    my $msg = shift;

    return if ! $self->{debug};

    open (my $fh, '>>', $self->{logfile}) or die "can not open logfile:$!\n";
    #print ariba::Ops::DateTime::prettyTime(time()) . " (" . "$level" . ") " . $msg . "\n";
    print $fh ariba::Ops::DateTime::prettyTime(time()) . " (" . "$level" . ") " . $msg . "\n";
    close ($fh) or die "can not close logfile\n"; 
}

sub printInfluxLine
{
    my $self = shift;
    my $msg = shift;
    print $msg,"\n";
}

1;
