#
# $Id: //ariba/services/tools/lib/perl/ariba/Ops/MySQLClient.pm#3 $

package ariba::Ops::MySQLClient;

#
# Note:
# This file is based on OracleClient.pm, and was ported to MySQL by Hide Inada.
#

#
# warning:  this code is not threadsafe.  See calls to rememberStatementHandle()
#   and lastStatementHandle()
#

use strict;
use DBI;
use ariba::Ops::Utils;
use ariba::Ops::DBConnection;
use ariba::rc::Utils;
use File::Path;
use POSIX qw(strftime);

use Expect;

my @DEFAULTMYSQLHOMESEARCHPATH = (
	"/usr/local/mysql",
);

use constant DEFAULT_TIMEOUT => 60;
use constant MYSQL_DEFAULT_SERVER_PORT => 3306;

sub newFromDBConnection {
	my $class = shift;
	my $dbconnr = shift; # reference to a DBConnection object 

#	print("DEBUG:MySQLClient->newFromDBConnection: " . '$dbconnr->sid():' . $dbconnr->sid() . "\n");

	my ($port, $database) = split(":", $dbconnr->sid()); # contains port number and database name if MySQL
	if ( ! $database ) {
#		print(q|DEBUG: $database is not set. Setting to $user| . "\n");
		$database = $dbconnr->user;
	}

	return(
		   $class->new(
			   $dbconnr->user(),
			   $dbconnr->password(),
			   $dbconnr->host(),
			   $port, 
			   $database
					   )
		   );
}

sub new {
	my $class = shift;
	my $dbuser = shift;
	my $dbpassword = shift;
	my $host = shift;
	my $port = shift;
	my $database = shift || die "$class->new() requires user/password/host/port/database";

	my $self = {
		'user' => $dbuser,
		'password' => $dbpassword,
		'host' => $host,
		'port' => $port,
		'database' => $database,

		'handle' => undef,

		'statementHandles' => {},
		'lastStatementHandle' => {},

		'previousLDLibraryPath' => undef,
	};

	bless($self, $class);

	$self->setColsep();

	return $self;	
}

sub DESTROY {
	my $self = shift;

	if($self->debug()) {
		print("DEBUG: DESTROY called\n");
	}

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
	return $self->{'error'};
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

sub previousLDLibraryPath {
	my $self = shift;
	return $self->{'previousLDLibraryPath'};
}

sub setPreviousLDLibraryPath {
	my $self = shift;
	$self->{'previousLDLibraryPath'} = shift;
}

sub _setupMySQLHomeUsingSearchPath {
	my $self = shift;
	my $mysqlHomeSearchPathRef = shift;

	my $home;

	for my $dir ( @$mysqlHomeSearchPathRef ) {
		if (-d $dir) {
			$home = $dir;
			last;
		}
	}

	my $envName = sharedLibEnvName(); # should be 'LD_LIBRARY_PATH' on RH

	my $oldMySQLHome = $ENV{'MYSQL_HOME'};
	my $oldSharedLibPath = $ENV{$envName};

	if ($home) {
		$ENV{'MYSQL_HOME'} = $home;
		my $oldLib = $ENV{$envName};

		$ENV{$envName} = "$home/lib";
		$ENV{$envName} .= ":$oldLib" if ($oldLib);
 	}

	return ($oldMySQLHome, $oldSharedLibPath);
}

sub port() {
	my $self = shift;
	return $self->{'port'};
}

sub setPort() {
	my $self = shift;
	$self->{'port'} = shift;
}

sub database() {
	my $self = shift;
	return($self->{'database'});
}

sub setDatabase() {
	my $self = shift;
	$self->{'database'} = shift;
}

sub connect {
	my $self = shift;
	my $timeout = shift || DEFAULT_TIMEOUT;
	my $tries = shift || 1;

	my ($previousMySQLHome, $previousSharedLibraryPath) = $self->_setupMySQLHomeUsingSearchPath(\@DEFAULTMYSQLHOMESEARCHPATH);

	$self->setPreviousLDLibraryPath($previousSharedLibraryPath);

	my %dbiSettings = (
		PrintError => 0,
		RaiseError => 0,
		AutoCommit => 1,
		LongReadLen => 256*1024,	# max blob size
		LongTruncOk => 1,		# get partial blobs
	);

	my $handle;

	my $user = $self->user();
	my $password = $self->password();
	my $host = $self->host();
	my $connectingTo;
	my $database = $self->database();
	my $port = $self->port();

	if (!defined($password) || $password =~ /^\s*$/) {
		my $error = "Error: undefined or empty password for host [$host], port [$port], database [$database]";
		$self->setError($error);
		return;
	}

	my $connectSub;

	$connectingTo = "user=$user host=$host port=" . $port . " database=$database";

	if ( $self->debug() ) {
		if( $ENV{'MYSQL_HOME'} ) {
			print("DEBUG: MYSQL_HOME=$ENV{'MYSQL_HOME'}\n");
		} else {
			print("DEBUG: MYSQL_HOME is not defined\n");
		}
		
		print("DEBUG: Connecting to: " . $connectingTo . "\n");
	}

	$connectSub = sub { 
			$handle = DBI->connect(
								   "DBI:mysql:database=$database;host=$host;port=$port",
								   $user, 
								   $password, 
								   \%dbiSettings
								   );
		};

	for (my $try  = 0; $try < $tries; ++$try) {

		if(!ariba::Ops::Utils::runWithForcedTimeout($timeout, $connectSub)) {

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
		if( $self->debug() ) {
			print($self->error() . "\n");
		}

		return undef 
	}
	$self->setHandle($handle);

	return 1;
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

	if ( defined( $self->previousLDLibraryPath() ) ) {
		my $envName = sharedLibEnvName();

		$ENV{$envName} = $self->previousLDLibraryPath();
	}

}

sub executeSqlWithTimeout {
	my $self = shift;
	my $sql = shift;
	my $timeout = shift || DEFAULT_TIMEOUT;
	my $resultsRef = shift;
	my $bindVariablesRef = shift;

	my $coderef;
	my $start = time();


	if ($self->debug()) {
		print("DEBUG: sql=$sql; timeout = $timeout; resultsRef = $resultsRef\n");
		if( $bindVariablesRef) {
			print("DEBUG: bindVariablesRef=$bindVariablesRef\n");
		}
	}

	if ( ref($resultsRef) eq "ARRAY" ) {
		if ($self->debug()) {
			print('DEBUG: ref($resultRef) eq "ARRAY"' . "\n");
		}

		$coderef = sub { @$resultsRef = $self->executeSql($sql, $bindVariablesRef); };
	} else {
		$coderef = sub { $$resultsRef = $self->executeSql($sql, $bindVariablesRef); };
	}

	if ($self->debug()) {
		print("DEBUG: Calling runWithForcedTimeout()\n");
	}

	if(! ariba::Ops::Utils::runWithForcedTimeout($timeout,$coderef) ) {

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

	my @results = ();

	my $handle = $self->handle();

	unless ($handle) {
		return (wantarray()) ? @results : undef;
	}

	my $colsep = $self->colsep();

	# old monitoring library allowed this
	$sql =~ s/;\s*$//;	

	print "DEBUG SQL: [$sql]\n" if $self->debug();

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
		local $^W = 0;  # silence spurious -w undef complaints
		while( my @row = $sth->fetchrow_array() ) {
			push(@results, join($colsep, @row));
		}
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


sub executeSqlSetWithTimeout {
	my $self = shift;
	my $statementSetRef = shift;
	my $timeout = shift;

	unless ( $self->handle() ) {
		warn("Invalid MySQLClient database handle\n");
		return;
	}

	unless ( defined ($statementSetRef) ) {
		warn("Invalid reference to statement set\n");
		return;
	}

	unless ( defined ($timeout) ) {
		warn("Timeout is not specified\n");
		return;
	}

	my $rowCount = @$statementSetRef;

	if( $rowCount > 0 ) {
		foreach my $sSQL ( @$statementSetRef ) {
			my @resultSet = ();

			my $resultExec = $self->executeSqlWithTimeout($sSQL, $timeout, \@resultSet);

			unless ( $resultExec ) {
				warn("SQL execution error :" . $self->error() . "\n");
				return;
			}

			if ( $self->error() ) {
				warn("SQL execution error :" . $self->error() . "\n");
				return;
			}
		}
	} else {
		warn("Statement set is empty\n");
		return;
	}

	return(1);
}

sub dataFilePath {
	my $self = shift;

	unless ( $self->handle() ) {
		warn("Invalid MySQLClient database handle\n");
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


1;
