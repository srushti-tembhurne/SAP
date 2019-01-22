#
# $Id: //ariba/services/tools/lib/perl/ariba/Ops/HanaClient.pm#50 $

package ariba::Ops::HanaClient;

#
# Note:
# This file is based on OracleClient.pm, and was ported to Hana by Jason Dy-Johnson.
#

#
# warning:  this code is not threadsafe.  See calls to rememberStatementHandle()
#   and lastStatementHandle()
#

use strict;
use warnings;
use DBI;
use ariba::Ops::Utils;
use ariba::Ops::DBConnection;
use ariba::Ops::Constants;
use ariba::rc::Utils;
use File::Path;
use POSIX qw(strftime);

use Expect;

use constant DEFAULT_TIMEOUT => 60;

# Ideally we should take $admin_users from ariba::Ops::Constants -- HanaClient.pm and Constants.pm were checked in
# under the same CL. But we've noticed that some services/environments are somehow using the global version of
# HanaClient.pm (under /usr/local/tools/lib/) but with their "product-local" version of Constants.pm. In such cases,
# HanaClient.pm is blowing up because the constant is not being found in the product-local version of Constants.pm.
#
# To get around this (ugly, but safe), we can temporarily define the constant directly in HanaClient.pm.
# Eventually, after all products/environments have gotten updated tools bundles, we can check in a new
# HanaClient.pm CL that ONLY pulls the new constant from ariba::Ops::Constants. But til then, unfortunately,
# we'll have to define the constant in both files.

my $admin_users;
my $const_name = "hanaDBAdminUsers";
if(ariba::Ops::Constants->can($const_name)) {
    $admin_users = ariba::Ops::Constants->$const_name;
}
else {
    $admin_users = [ 'system', 'system_mon' ];
}

sub newFromDBConnection {
    my $class = shift;
    my $dbconnr = shift; # reference to a DBConnection object

    return(
           $class->new(
               $dbconnr->user(),
               $dbconnr->password(),
               $dbconnr->host(),
               $dbconnr->port())
           );
}

sub new {
    my $class = shift;
    my $dbuser = shift;
    my $dbpassword = shift;
    my $host = shift;
    my $port = shift || die "$class->new() requires user/password/host/port/database";
    my $hanaHosts = shift || [];

    # per SAP hana specs: instance ID is always the 2nd-and-3rd digit of the port.
    my $instanceId = substr($port, 1, 2);

    # only users with admin privs can query certain system views.
    my $is_admin = grep(/^$dbuser$/i, @$admin_users);

    my $self = {
        'user' => $dbuser,
        'password' => $dbpassword,
        'host' => $host,
        'port' => $port,
        'hanaHosts' => $hanaHosts,
        'handle' => undef,
        'statementHandles' => {},
        'lastStatementHandle' => {},
        'connected' => 0,
        'previousLDLibraryPath' => undef,
        'driver' => undef,
        'instance_id' => $instanceId,
        'is_admin' => $is_admin,
    };

    bless($self, $class);
    $self->setColsep();
    return $self;
}

sub is_admin {
    my $self = shift;
    return $self->{'is_admin'};
}

sub instanceId {
    my $self = shift;
    return $self->{'instance_id'};
}

sub driver {
    my $self = shift;

    # Determine which HDBC driver to use:
    # HDBODBC is the v1 client driver, and will likely remain in use on rh 5 hosts.
    # HDBODBC2 is the v2 client driver, which will eventually be installed on rh >= 6 hosts.
    # Always try to use the v2 driver if it exists.
    return $self->{driver} if $self->{driver};

    # we don't have the UnixODBC cpan module so will have to use system calls...
    my $cmd = 'PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin odbcinst -q -d'; # if installed, it's in /usr/bin
    my @results = qx($cmd);
    my %h;
    map { tr/[]//d; chomp; $h{$_} = $_; } grep /HDB/, @results;
    # always try to use the hana client 2 driver if it exists
    $self->{driver} = $h{HDBODBC2} || $h{HDBODBC}; # if none exist it'll be undef
    return $self->{driver};
}

sub DESTROY {
    my $self = shift;
    $self->dbg("DESTROY called");
    $self->disconnect();
}

sub user {
    my $self = shift;
    return $self->{'user'};
}

sub password {
    my $self = shift;
    return $self->{'password'};
}

sub host {
    my $self = shift;
    return $self->{'host'};
}

sub hanaHosts {
    my ($self, $val) = @_;

    $self->{'hanaHosts'} = $val if $val;
    return $self->{'hanaHosts'} || [];
}

sub colsep {
    my $self = shift;

    return $self->{'colsep'};
}

sub setColsep {
    my $self = shift;
    my $colsep = shift ;

    return $self->{'colsep'} = ( $colsep || "\t" );
}

sub debug {
    my $self = shift;
    return $self->{'debug'} || 0;
}

sub setDebug {
    my $self = shift;
    $self->{'debug'} = shift;
}

sub handle {
    my $self = shift;
    return $self->{'handle'};
}

sub setHandle {
    my $self = shift;
    $self->{'handle'} = shift;
}

sub error {
    my $self = shift;
    return $self->{'error'} || '';
}

sub setError {
    my $self = shift;
    $self->{'error'} = shift;
}

sub forgetStatementHandle {
    my $self = shift;
    my $handle = shift;
    delete ${$self->{'statementHandles'}}{$handle};
}

sub rememberStatementHandle {
    my $self = shift;
    my $handle = shift;

    ${$self->{'statementHandles'}}{$handle} = $handle;
    $self->{'lastStatementHandle'} = $handle;
}

sub remeberedStatementHandles {
    my $self = shift;
    return values %{$self->{'statementHandles'}};
}

sub lastStatementHandle {
    my $self = shift;
    return $self->{'lastStatementHandle'};
}

sub port() {
    my $self = shift;
    return $self->{'port'};
}

sub setPort() {
    my $self = shift;
    $self->{'port'} = shift;
}

sub connected {
    my $self = shift;
    return($self->{'connected'});
}

sub setConnected {
    my $self = shift;
    $self->{'connected'} = shift;
}

### set the cluster (landscape) config for this client connection.
sub load_cluster_config {
    my $self = shift;
    my $func = ${[caller(0)]}[3];

    return unless $self->connected();
    return TRUE if $self->cluster_config_loaded();

    return unless $self->_get_cluster_config();

    # we now have the realtime dynamically-divined cluster hosts, so we can override the static info.
    # plus, we can drop the standbys from the list.
    $self->hanaHosts([ $self->master(), @{$self->slaves()} ]);

    $self->cluster_config_loaded(TRUE);
    return TRUE;
}

sub cluster_config_loaded {
    my ($self, $val) = @_;
    $self->{'cluster_config_loaded'} = $val if $val;
    return $self->{'cluster_config_loaded'};
}

# if this is set, it means this is an MDC cluster. The value is the systemdb host.
sub sysdb_host {
    my ($self, $val) = @_;
    $self->{'sysdbhost'} = $val if $val;
    return $self->{'sysdbhost'} || '';
}

sub sysdb_port {
    my $self = shift;
    return unless $self->instanceId();

    # per SAP hana specs: MDC sysdb port is always "3" plus instance ID plus "13".
    return "3" . $self->instanceId() . "13";
}

sub _get_cluster_config {
    my $self = shift;
    my $func = ${[caller(0)]}[3];

    my @data;
    # NOTE: hana 2.0 no longer reports the sysdb sql port in the tenant m_services view, so we can
    # no longer use that as the indicator as to whether or not we're an MDC tenant. To maintain
    # compatibility with hana 1.x and 2.x, this is the suggestion from hana tech support:
    #
    #   "The best option is to check for the "mode" parameter in the "multidb" section in
    #   global.ini via M_INIFILE_CONTENTS. If it's not set or if it is set to singledb,
    #   then you are not running in a tenant database."
    #

    my $sql = qq<select host, service_name, coordinator_type from sys.m_services>
            . qq< where service_name in ('nameserver','indexserver')>;

    return unless $self->executeSqlWithTimeout($sql, 10, \@data) && @data;

    my ($master, @slaves, @standbys, $sysdb_host);
    for my $row (@data) {
        $row = lc($row);
        my ($host, $service, $role) = split(' ', $row);

        if($service eq 'nameserver' && $role eq 'master') {
            # This _might_ be an MDC cluster. We'll know for sure later. In case we are,
            # we need to record the [potential] sysdb host here.
            $sysdb_host = $host;
        }
        elsif($service eq 'indexserver') {
            if   ($role eq 'master' ) { $master       = $host;  }
            elsif($role eq 'slave'  ) { push(@slaves,   $host); }
            elsif($role eq 'standby') { push(@standbys, $host); }
        }
    }

    # If we're connected on the sysdb port, then we _must_ be an MDC sysdb master,
    # in which case we assign master as sysdb_host and unset sysdb_host. Then
    # we're done, and can get outta Dodge.
    if($self->port() == $self->sysdb_port()) {
        $self->master($sysdb_host);
        $self->sysdb_host(undef);
        return TRUE;
    }

    # Am I an MDC tenant? Do androids dream of electric sheep?
    $sql = qq<select count(*) from sys.m_data_volumes where (upper("FILE_NAME") like upper('%hdb%.0%'))>;

    my $result;
    return unless $self->executeSqlWithTimeout($sql, 10, \$result);

    ### TEMP HACK ###
    # the query to detect MDC tenant is unreliable -- it fails to detect tenants on port 30015 (or so we think).
    # We know, for now, that KSA and UAE are MDC deployments, so we'll manually set $result for them, so that
    # we can get SYSTEMDB monitored and backed up, until such time as we're able to deploy a permanent fix.

    $result = 1 if $self->host =~ /\.(ksa|uae)/i;

    if($result > 0) {
        # Yes. Must therefore get standby info from the landscape host config view.
        $self->dbg("I am an MDC tenant.");
        $sql = qq(select host from m_landscape_host_configuration where indexserver_actual_role = 'standby');
        my @data;
        return unless $self->executeSqlWithTimeout($sql, 10, \@data);
        @standbys = @data;
    }
    else {
        # No. Must therefore unset sysdb_host.
        $sysdb_host = undef;
    }

    $self->master($master);
    $self->sysdb_host($sysdb_host);
    $self->slaves([ sort(@slaves) ]);
    $self->standbys([ sort(@standbys) ]);

    return TRUE;
}

sub master {
    my ($self, $val) = @_;
    $self->{'master'} = $val if $val;
    return $self->{'master'};
}

sub slaves {
    my ($self, $val) = @_;
    $self->{'slaves'} = $val if $val;
    return $self->{'slaves'} || [];
}

sub standbys {
    my ($self, $val) = @_;
    $self->{'standbys'} = $val if $val;
    return $self->{'standbys'} || [];
}

sub version {
    my $self = shift;

    $self->_get_version_info() unless $self->{'version'};
    return $self->{'version'} || '';
}

sub revision {
    my $self = shift;

    $self->_get_version_info() unless $self->{'revision'};
    return $self->{'revision'} || '';
}

sub _get_version_info {
    my $self = shift;

    return unless $self->connected();

    my $data;
    my $sql = qq(select version from m_database);

    my @retVal;
    unless($self->executeSqlWithTimeout($sql, 10, \$data) && $data) {
        $self->setError("Error: failed to get version info");
        return;
    }

    # a hana version string looks like: 1.00.122.05.1481577062
    # normalize to ver.rev (i.e. "1.85" or "1.122" or "2.11"
    my ($ver, $rev) = $data =~ /^(\d+)\.\d+\.(\d+)/;

    $self->{'version'}  = $ver;
    $self->{'revision'} = $rev;
    return TRUE;
}

sub connect {
    my $self = shift;
    my $timeout = shift || DEFAULT_TIMEOUT;
    my $tries = shift || 1;

    return TRUE if($self->connected());

    my @urlList = $self->getUrlList();

    my ($cnt, $errs);
    foreach my $url (@urlList) {
        $self->dbg("url=$url");
        $self->connectInternal($url, $timeout, $tries);
        if((my $err = $self->error())) {
            $errs .= "$err\n";
            $cnt++;
            next;
        }
        last;
    }

    if($self->error()) {
        # set an error that's indicative the entire cluster connect failed.
        $self->setError("Error: *** cluster connect failed *** (tried $cnt of @{[scalar @urlList]} hosts):\n$errs");
        return;
    }

    $self->setConnected(TRUE);

    # get the db version info
    unless($self->version()) {
        $self->setError("Error: *** failed to obtain version info ***");
    }

    # only an admin user has privs to read the system views to obtain cluster topology.
    # standard users don't need this info so we can skip.
    # TODO: either lazy-load this or load it on-demand only, mainly to speed up hana-isup host-level connect testing.
    if($self->is_admin) {
        unless($self->load_cluster_config()) {
            $self->setError("Error: *** failed to obtain cluster topology");
        }
    }

    return ! $self->error();
}

sub connectNew {
    my $self = shift;
    my $dirPath = shift;
    my $timeout = shift || DEFAULT_TIMEOUT;
    my $tries = shift || 1;
    my $timeoutBetweenRetries = 5;

    return TRUE if($self->connected());

    $self->connectByHdbsql($tries);

    if($self->error()) {
        # error already set by connectByHdbsql
        return;
    }

    $self->setConnected(1);
    $self->{dirPath} = $dirPath;

    return TRUE;
}

sub getUrlList {
    my $self = shift;

    my $host = $self->host();
    my $port = $self->port();
    my $hanaHosts = $self->hanaHosts();
    my @urlList;

    if ($hanaHosts && @$hanaHosts) {
        foreach my $url (@$hanaHosts) {
            # DD.xml construct is host only, not host:port.  Append the port if it's not part of the $url.
            unless ( $url =~ /:\d+$/ ) {
                $url .= ":$port";
            }
            push (@urlList, $url);
        }
    }
    else {
        my $url = $host . ":" . $port;
        push (@urlList, $url);
    }

    return @urlList;
}

sub connectInternal {
    my $self = shift;
    my $url = shift;
    my $timeout = shift || DEFAULT_TIMEOUT;
    my $tries = shift || 1;

    my $handle;

    my $user = $self->user();
    my $password = $self->password();
    my $connectingTo;
    my $timeoutBetweenRetries = 5;

    if (!defined($password) || $password =~ /^\s*$/) {
        my $error = "Error: undefined or empty password for $url";
        $self->setError($error);
        return;
    }

    my $connectSub;
    my $driver = $self->driver();
    unless($driver) {
        my $errstr = "ODBC driver not found. (is unixODBC installed?)";
        $self->setError($errstr);
        $self->dbg("ERROR: $errstr");
        return;
    }

    $self->dbg("using driver '$driver'");

    if ( $url =~ /:\d+:\d+/ ){ ## We have a URL like 'url=hana1000.snv.ariba.com:30015:30015'
        $url =~ s/(.*:\d+):\d+/$1/; ## Strip off the extra :$port
    }

    $connectingTo = "user=$user url=$url";
    $self->dbg("conninfo=$connectingTo");

    $connectSub = sub {
                $handle = DBI->connect(
                                   "DBI:ODBC:DRIVER={$driver};ServerNode=$url",
                                   $user,
                                   $password
                                   #, \%dbiSettings
                                   );
        };

    for (my $try  = 0; $try < $tries; ++$try) {
        sleep($timeoutBetweenRetries) if $try; # sleep only after the 1st try

        if(!ariba::Ops::Utils::runWithTimeout($timeout, $connectSub)) {
            $self->setError("Timed-out trying to connect to [$connectingTo] after $timeout seconds, ".($try+1)." tries");
            $self->disconnect();
            next;
        } elsif ( $@ or !defined($handle)) {
            $self->setError("Error: $DBI::errstr for [$connectingTo]");
            $@ = '';
            last;
        } else {
            $self->setError(undef);
            last;
        }
    }

    if( $self->error() ) {
        $self->dbg($self->error());
        return;
    }
    $self->setHandle($handle);

    return 1;
}

sub constructUrl {
    my $self = shift;

    my $host = $self->host();
    my $port = $self->port();
    my $hanaHosts = $self->hanaHosts();
    my $url;

    if ($hanaHosts) {
        $url = join( ";", @$hanaHosts );
    }
    else {
        $url = $host . ":" . $port;
    }

    return $url;
}

sub disconnect {
    my $self = shift;

    # deal with any statement handles that have "leaked"

    for my $sth ( $self->remeberedStatementHandles() ) {
        $self->forgetStatementHandle($sth);
        $sth->cancel();
    }

    my $handle = $self->handle();

    if ( defined ($handle) ) {
        $handle->disconnect();
        $self->setHandle(undef);
    }

    $self->setConnected(0);
}

sub executeSqlWithTimeout {
    my $self = shift;
    my $sql = shift;
    my $timeout = shift || DEFAULT_TIMEOUT;
    my $resultsRef = shift;
    my $bindVariablesRef = shift;
    my $asHash = shift;
    $asHash = 0 if not defined $asHash;
    my $coderef;
    my $start = time();


    if ($self->debug()) {
        $self->dbg("sql=$sql; timeout = $timeout; resultsRef = $resultsRef");
        $self->dbg("bindVariablesRef=$bindVariablesRef") if $bindVariablesRef;
    }

    if ( ref($resultsRef) eq "ARRAY" ) {
        $self->dbg('ref($resultRef) eq "ARRAY"');
        $coderef = sub { @$resultsRef = $self->executeSql($sql, $bindVariablesRef, $asHash); };
    } else {
        $coderef = sub { $$resultsRef = $self->executeSql($sql, $bindVariablesRef, $asHash); };
    }

    if(! ariba::Ops::Utils::runWithTimeout($timeout,$coderef) ) {

        $self->handleExecuteSqlTimeout();
        my $end = time();
        my $duration = "start=" . strftime("%H:%M:%S", localtime($start)) .
                " end=" . strftime("%H:%M:%S", localtime($end));

        #
        # We have a newline in this string, because Query.pm gets a subject
        # for notification requests based on splitting on the first \n --
        # which means without this newline, the entire SQL ends up in the
        # subject of the notification request, and hence, also the page.
        #
        # some cell phones that prodops use do not handle long subjects well
        # (such as the iPhone), and this makes acking pages difficult.
        #
        # see TMID:62550
        #
        my $errorString = $self->timedOutErrorString() . ":\n  [$sql] $duration";
        $self->setError($errorString);
        if ( ref($resultsRef) eq "ARRAY" ) {
            @$resultsRef = ($errorString);
        } else {
            $$resultsRef = $errorString;
        }
        return 0;
    }

    if($self->debug) {
        my $duration = time() - $start;
        $self->dbg("'$sql' took $duration secs.");
    }

    return 1;
}

sub timedOutErrorString {
    my $class = shift;

    return "timed out running sql";
}

sub executeSql {
    my $self = shift;
    my $sql = shift;
    my $bindVariablesRef = shift;
    my $asHash = shift;
    $asHash = 0 if not defined $asHash;

    my @results = ();

    my $handle = $self->handle();

    unless ($handle) {
        return (wantarray()) ? @results : undef;
    }
    $self->dbg("SQL: [$sql]");
    my $colsep = $self->colsep();

    # old monitoring library allowed this
    $sql =~ s/;\s*$//;

    #for handling longs
    $self->dbg("SQL: LongReadLen is '" . $handle->{LongReadLen} . "'");
    $self->dbg("SQL: LongTruncOk is '" . $handle->{LongTruncOk} . "'");
    $handle->{LongTruncOk} = 1;

    my $sth = $handle->prepare($sql) || return $self->returnStatementHandleError($sql);

    $self->rememberStatementHandle($sth);

    if ($bindVariablesRef && @$bindVariablesRef) {
        $sth->execute(@$bindVariablesRef);
    } else {
        $sth->execute();
    }

    if ( $handle->err() ) {

        my $error = $handle->errstr();

        if ( $error =~ /user requested cancel of current operation/ ) {
            $sth->cancel();
            die $error;
        } else {
            $self->setError($error);
            return ref($self)."->executeSql(): $error for sql: $sql";
        }
     }
    if ( $sql =~ /^\s*select/i ) {
        no warnings;  # silence spurious undef complaints
        if ( $asHash ) { #requested to be returned as hash
          while( my $row = $sth->fetchrow_hashref() ) {
            push(@results, $row);
          }
        } else {
          while( my @row = $sth->fetchrow_array() ) {
            push(@results, join($colsep, @row));
          }
        }
        use warnings;
    }

    $self->forgetStatementHandle($sth);

    if (wantarray) {
        return @results;
    } else {
        return $results[0];
    }
}

# get this back to the caller. the error and sql strings can have embedded
# newlines which mess up saving to the query.
sub returnStatementHandleError {
    my $self = shift;
    my $sql  = shift;

    my $handle = $self->handle();
    my $error  = $handle->errstr();

    chomp($sql);
    chomp($error);

    $sql =~ s/\s+/ /g;
    $error =~ s/\s+/ /g;

    $self->setError("executeSql(): Couldn't prepare sth [$sql] error: [$error]");

    return undef;
}

sub handleExecuteSqlTimeout {
    my $self = shift();

    my $sth = $self->lastStatementHandle();

    eval { # $sth may be an unblessed ref
        $sth->cancel();
    };

    $self->forgetStatementHandle($sth);

}

sub dataFilePath {
    my $self = shift;

    unless ( $self->handle() ) {
        warn("Invalid HanaClient database handle\n");
        return;
    }

    my @resultSet = ();
    my $resultSetRef = \@resultSet;

    my $sSQL = 'select @@datadir';

    my $resultExec = $self->executeSqlWithTimeout($sSQL, DEFAULT_TIMEOUT, $resultSetRef);

    unless ( $resultExec ) {
        warn("SQL execution error\n");
        return;
    }

    if ( $self->error() ) {
        warn("SQL execution error\n");
        return;
    }

    my $rowCount = @$resultSetRef;

    if( $rowCount > 0 ) {
        if ( $self->debug() ) {
            print("DEBUG: Dumping the result set:\n");
            foreach my $s ( @$resultSetRef ) {
                print("$s\n");
            }
        }

    } else {
        warn("Cannot find the data file path\n");
        return;
    }

    return($resultSet[0]);
}

#why?  Because of https://product-jira.ariba.com/browse/HOA-16125
#For some reason, we aren't able to consistently connect to HANA
#via the Perl ODBC driver.  So, we'll do it with the native HANA
#client.
sub executeSqlByFile {
    my $self = shift;
    my $sql = shift;
    my %args = @_;
    $self->setError();
    my $dbUsername = $args{user} || $self->user();
    my $dbPassword = $args{password} || $self->password();
    my $dbServerHost = $args{host} || $self->host();
    my $dbPort = $args{port} || $self->port();
    eval {   #basic sanity checking
        die 'no sql passed' unless $sql;
        die 'no dbUsername found' unless $dbUsername;
        die 'no dbPassword found' unless $dbPassword;
        die 'no dbServerHost found' unless $dbServerHost;
        die 'no dbPort found' unless $dbPort;
    };
    if($@) {
        $self->setError("executeSqlByFile exception: $@");
        return undef;
    }

    my $sqlFile;
    my @returnRows = eval {
        $sqlFile = eval {
            #let's make the file that will contain the SQL to execute
            local $SIG{ALRM} = sub { die "timed out\n"; };
            alarm 5;

            #insecure, but no big deal here...I hope
            my $rand = int rand 10240000 + $$;
            my $file = "/tmp/hdbclient_sqlin_$rand";
            open my $fh, '>', $file or die "open $file failed: $!";
            print $fh $sql or die "print to $file failed: $!";
            close $fh or die "close $file failed: $!";
            return $file;
        };
        alarm 0;
        die "Creation of sqlfile failed: $@" if $@;

        my @returnRows = ();

        #close your eyes...
        my $sep = 'HLlwgSyym1n69bijZxNkfw5ITWE';
        $ENV{PATH} = "/opt/sap/hdbclient:/bin:/usr/bin:$ENV{PATH}"
            unless $ENV{PATH} =~ /\/opt\/sap\/hdbclient/;

        #glorious hard-coded path and command-line
        my $command = "/opt/sap/hdbclient/hdbsql -n $dbServerHost:$dbPort -u $dbUsername -F $sep -j -p $dbPassword -I \"$sqlFile\"";
    	my @allLines = eval {
           local $SIG{ALRM} = sub { die "timed out\n"; };
           #Due to HOA-32419 changing from 6000 seconds to 12000 seconds as per log "/home/svclq7/s4/logs/s4restore25may.txt"
           alarm 12000;  #yay arbitrary numbers
           my $ret = `$command 2>&1`;  #not sure what to do with STDERR here
           return split "\n", $ret;
        };
        alarm 0;
        if($@) {  #get rid of the stray hdbsql program if it is hanging around
            my $err = $@;
            #clean the insecure password on the command-line
            $command =~ s/-p .*? -I/-p password -I/;
            eval {  #make sure the cleanup commands don't timeout/throw
                local $SIG{ALRM} = sub { die "timed out\n"; };
                alarm 5;
                my $pidToKill = `ps -deaf|grep " $$ "|grep /opt/sap/hdbclient/hdbsql|grep -v grep|awk '{print \$2}'`;
                if($pidToKill and $pidToKill =~ /^\d+$/) {
                    kill 15, $pidToKill;
                    sleep 2;
                    kill 9, $pidToKill;
                }
            };
            alarm 0;
            if($@) {
                $err .= " and attempt to kill potentially hung hdbsql command also failed: $@";
            }
            die "hdbsql command ($command) failed: $err";
        }
        shift @allLines;  #get rid of the 'header' line
        foreach my $line (@allLines) {

            #all of this henious crap needs more error checking
            my @allFields = split $sep, $line;
            shift @allFields;
            my @row = ();
            foreach my $field (@allFields) {
                #crazy crap here to cleanup output
                #TODO XXX Guaranteed to be incomplete!
                #at a minimum, it'll not be handling naked \
                $field =~ s/^ "//;
                if($field =~ /" $/) {
                    $field =~ s/" $//;
                } else {
                    $field =~ s/"$//;
                }
                $field =~ s/\\"/"/g;
                push @row, $field;
            }
            push @returnRows, \@row;
        }
        return @returnRows;
    };
    alarm 0;
    my $exception = $@;
    if(-e $sqlFile) { #get rid of the sqlfile if it's there
        eval {
            local $SIG{ALRM} = sub { die "timed out\n"; };
            alarm 5; #maybe if I snap a rubber band on my wrist every time
                     #I put in a hard-coded timeout I'll stop doing that...
            unlink $sqlFile or die "failed to unlink $sqlFile: $!";
        };
        alarm 0;
        if($@) {
            $exception .= " and attempt to unlink $sqlFile failed: $@";
        }
    }
    if($exception) {
        $self->setError("executeSqlByFile exception: $exception");
        return undef;
    }
    return @returnRows;
}
#
# uses hdbclient to run the specified file
# HanaClient does not need to be connected(), but must have
# been initialized with a valid DBConnection or db info
sub executeSqlFile {
    my $self = shift;
    my $fileName = shift;

    $self->setError();

    unless ( -f $fileName ) {
        $self->setError("File not found: $fileName ");
        return;
    }

    unless ( -r $fileName ) {
        $self->setError("File not readable: $fileName ");
        return;
    }

    my $sql = eval {
        local $SIG{ALRM} = sub { die "timed out\n"; };
        alarm 5;
        my $in = '';
        open my $fh, '<', $fileName or die "failed to open $fileName for reading: $!";
        read $fh, $in, 10240000 or die "failed to read $fileName: $!";
        close $fh or die "failed to close $fileName: $!";
        return $in;
    };
    alarm 0;
    if($@) {
        $self->setError("failed to read $fileName: $@");
        return undef;
    }

    #this line should be safe and correct because executeSqlByFile() does not
    #throw any exceptions, and itself calls setError()
    return $self->executeSqlByFile($sql);
}

sub dbExport {
    my $self = shift;
        my $schemaName = shift;
        $schemaName = uc($schemaName);
        my $exportDirPath = shift;

        my $command = "export " . "\"$schemaName\"." . "\"*\"" . " as binary into '" . $exportDirPath . "' with replace threads 10";

        print "export command=$command\n" if $self->debug();
        $self->executeSqlOnDBHost($command,$exportDirPath);

        return(0) if($self->error());
        return 1;
}

sub executeSqlOnDBHost{
    my $self = shift;
    my $sql = shift;
    my $dirPath = shift;
    my %args = @_;

    my $dbServerHost = $args{host} || $self->host();
    my $dbUsername = $args{user} || $self->user();
    my $dbPassword = $args{password} || $self->password();
    my $dbPort = $args{port} || $self->port();

    my ($hostUser,$hostPassword ) = getHostUserAndPassword();

    my $rand = int rand 10240000 + $$;
    my $sqlFile = $dirPath."/hdbclient_sqlin_onDBHost_$rand";
    open my $fh, '>', $sqlFile or die "open $sqlFile failed: $!";
    print $fh $sql or die "print to $sqlFile failed: $!";
    close $fh or die "close $sqlFile failed: $!";

    my $sep = 'HLlwgSyym1n69bijZxNkfw5ITWE';
    my @returnRows = ();

    my $command = "/opt/sap/hdbclient/hdbsql -n $dbServerHost:$dbPort -u $dbUsername -F $sep -j -p $dbPassword -I \"$sqlFile\"";
    my $sshCmd = "ssh $hostUser\@$dbServerHost '$command'";

    my @output;
    my $ret = ariba::rc::Utils::executeRemoteCommand($sshCmd,$hostPassword,0,undef,undef,\@output);
    $sshCmd =~ s/-p .*? -I/-p password -I/;

    if(-e $sqlFile) {
        local $SIG{ALRM} = sub { die "timed out\n"; };
        unlink $sqlFile or die "failed to unlink $sqlFile: $!";
    }
    unless($ret){
        $self->setError("Error running on Hana DBHost,hdbsql command ($command) failed: @output\n");
        return undef;
    }

    ##########Excluding below HANA error codes###########
    ## [30138] -> return code by HANA if restoring schema is empty
    ## * 2048: column store error: table import failed:  [30138] No such schema in the import path.
    ## =========================
    ## [30101] -> return code by HANA if export empty schema
    ## [2048]: column store error: export failed: [30101] No objects to export found in building the list
    ####################################################
    if ( grep { $_ =~/(failed|error)/si && $_ !~ /\[(30138|30101)\]/is } @output ){
        $self->setError("Error: Failed to run command ($command)\n DB Error: @output\n");
        return undef;
    }

    if ( $sql =~ /^\s*select/i ) {
        shift @output;
        foreach my $line (@output){
            my @allFields = split $sep, $line;
            shift @allFields;
            my @row = ();
            foreach my $field (@allFields) {
                $field =~ s/^\s?"//;
                if($field =~ /" $/) {
                    $field =~ s/" $//;
                } else {
                    $field =~ s/"$//;
                }
                $field =~ s/\\"/"/g;
                push @row, $field;
            }
            push @returnRows, join(' ',@row);
        }
    }
    return @returnRows;
}

sub dropTablesForImport {
    my $self = shift;
    my $dryrun = shift;

    #
    # get the list of tables
    #
    my $timeout = 240;
    my $sql = "Select table_name from m_cs_tables where schema_name = CURRENT_USER";
    my @results = $self->executeSqlByFile($sql);
    if($self->error()) {
        $self->setError("Failure to run \$sql=$sql: " . $self->error());
        return(0);
    }
    foreach my $resultRow (@results) {
        my $result = $resultRow->[0];
        my $sql = "DROP TABLE $result";
        if($dryrun) {
            print "Would: $sql\n" if $self->debug();
        } else {
            print "Run: $sql\n" if $self->debug();
             my @results = $self->executeSqlByFile($sql);
             if($self->error()) {
                 $self->setError("Failure to run \$sql=$sql: " . $self->error());
                 return(0);
             }

        }
    }

    return(1);
}

sub dbImport {
    my $self = shift;
    my $schemaName = shift;
    $schemaName = uc($schemaName);
    my $importDirPath = shift;
    my $srcSchema = shift;
    $srcSchema = uc($srcSchema) if($srcSchema);
    my $dirPath = shift;

    $srcSchema = undef if($srcSchema eq $schemaName);

    my $rename = " ";
    if($srcSchema) {
        $rename = " rename schema $srcSchema to $schemaName ";
    }

    my $importSchema = $srcSchema || $schemaName;

    my $sql = "import " . "\"$importSchema\"." . "\"*\"" . " as binary from '" . $importDirPath . "' with${rename}replace threads 40";
    my @results;
    $self->executeSqlOnDBHost($sql,$dirPath);

    if($self->error()) {
        $self->setError("Failure to run \$sql=$sql: " . $self->error());
        return(0);
    }

    return 1;
}

sub getHostUserAndPassword {

    my $hostUser = `whoami`;
    chomp($hostUser);
    my $hostPassword;
    if ( $hostUser =~ /^(robot\d+|cqrobot\d+)$/ ){
        $hostPassword = $hostUser;
    }else{
        $hostPassword = ariba::rc::Passwords::lookup( $hostUser );
    }
    die "Password not defined for User: $hostUser\n" unless ($hostPassword);

    return $hostUser, $hostPassword;
}

sub connectByHdbsql{
    my $self = shift;
    my $tries = shift || 1;
    my $timeout = shift || DEFAULT_TIMEOUT;
    my $timeoutBetweenRetries = 5;

    my $dbServerHost = $self->host();
    my $dbUsername = $self->user();
    my $dbPassword = $self->password();
    my $dbPort = $self->port();

    my ($hostUser,$hostPassword ) = getHostUserAndPassword();

    my $command = "/opt/sap/hdbclient/hdbsql -n $dbServerHost:$dbPort -u $dbUsername -j -p $dbPassword -j select 1 from dummy";  ##just to check connected to DB or not
    my $sshCmd = "ssh $hostUser\@$dbServerHost '$command'";

    my @output;
    my $ret;
    my $connectSub = sub {
        $ret = ariba::rc::Utils::executeRemoteCommand($sshCmd,$hostPassword,0,undef,undef,\@output);
    };
    for (my $try  = 0; $try < $tries; ++$try) {
        sleep($timeoutBetweenRetries) if $try;
        if (! ariba::Ops::Utils::runWithTimeout($timeout, $connectSub)){
            $self->setError("Timed-out trying to connect to [$dbServerHost] after $timeout seconds, ".($try+1)." tries");
            next;
        }else{
	    $sshCmd =~ s/-p .*? -I/-p password -I/;
            $ret .= join (' ',@output);
            if ($ret =~ /rows? selected/i) {
                $self->setError(undef);
                last;
            }else{
                $self->setError("Error: in connecting $dbServerHost:$dbPort, username:$dbUsername, Error:$ret");
                return undef;
            }
        }
    }

    return 1;
}

sub debugLog {
    my $self = shift;
    $self->{debugLog} ||= shift;
    return $self->{debugLog};
}

sub dbg {
    my $self = shift;
    my $str  = shift || '';

    return unless $self->debug;

    my $func = ${[caller(1)]}[3];
    my $t = strftime("%d-%b-%Y %H:%M:%S", localtime());
    my $txt = "[$t] [$$] [DEBUG] $func: $str";

    print "$txt\n";
    if($self->debugLog) {
        if(open(my $fh, '>>', $self->debugLog)) {
            print $fh "$txt\n";
            close($fh);
        }
    }
}

1;
