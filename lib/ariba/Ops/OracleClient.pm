#
# $Id: //ariba/services/tools/lib/perl/ariba/Ops/OracleClient.pm#48 $

package ariba::Ops::OracleClient;

#
# warning:  this code is not threadsafe.  See calls to rememberStatementHandle()
#   and lastStatementHandle()
#

use strict;
use DBI;
use DBD::Oracle;
use ariba::Ops::Utils;
use ariba::Ops::DBConnection;
use ariba::rc::Utils;
use File::Path;
use POSIX qw(strftime);
use Carp;
use Expect;

my $DEFAULT_TIMEOUT = 60;
my $DEFAULT_LISTENER_PORT = 1521;

my @DEFAULTORACLEHOMESEARCHPATH = (
	"/usr/local/oracle",
);


sub new {
	my $class = shift;
	my $dbuser = shift;
	my $dbpassword = shift;
	my $dbsid = shift || die "$class->new() requires dbuser/dbpassword/dbsid";
	my $tnsAdminDir = shift;

	my $host = $tnsAdminDir;

	if (-d $tnsAdminDir) {
		$host = undef;
	} else {
		$tnsAdminDir = undef;
	}

	my $self = {
		'user' => $dbuser,
		'password' => $dbpassword,
		'sid' => $dbsid,
		'host' => $host,
		'tnsAdminDir' => $tnsAdminDir,

		'handle' => undef,

		'statementHandles' => {},
		'lastStatementHandle' => {},

		'previousLDLibraryPath' => undef,
		'previousTNSAdmin' => undef,
	};

	bless($self, $class);

	return $self;	
}

sub newFromDBConnection {
	my $class = shift;
	my $dbc = shift;

	return ($class->new($dbc->user(), $dbc->password(),
						$dbc->sid(), $dbc->host()));
}

sub newSystemConnectionFromDBConnection {
	my $class = shift;
	my $dbc = shift;
	my $product = $dbc->product();

	require ariba::rc::InstalledProduct;

	my $mon = ariba::rc::InstalledProduct->new("mon", $product->service());

	return($class->new('system', $mon->default('dbainfo.system.password'),
					$dbc->sid(), $dbc->host()));
}

sub colsep {
	my $class = shift;

	return "\t";
}

sub DESTROY {
	my $self = shift;
	$self->disconnect();
	#
	# cleanup any TNS dirs left over
	#
	$self->cleanupOracleENV();
}

sub user {
	my $self = shift;
	return $self->{'user'};
}

sub password {
	my $self = shift;
	return $self->{'password'};
}

sub sid {
	my $self = shift;
	return $self->{'sid'};
}

sub host {
	my $self = shift;
	return $self->{'host'};
}

sub tnsAdminDir {
	my $self = shift;
	return $self->{'tnsAdminDir'};
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

sub previousTNSAdmin {
	my $self = shift;
	return $self->{'previousTNSAdmin'};
}

sub setPreviousTNSAdmin {
	my $self = shift;
	$self->{'previousTNSAdmin'} = shift;
}

sub _setupOracleHomeUsingSearchPath {
	my $self = shift;
	my $oracleHomeSearchPathRef = shift;

	my $home;

	for my $dir ( @$oracleHomeSearchPathRef ) {
		if (-d $dir) {
			$home = $dir;
			last;
		}
	}

	my $envName = sharedLibEnvName();

	my $oldOracleHome = $ENV{'ORACLE_HOME'};
	my $oldSharedLibPath = $ENV{$envName};

	if ($home) {
		$ENV{'ORACLE_HOME'} = $home;
		my $oldLib = $ENV{$envName};

		$ENV{$envName} = "$home/lib";
		$ENV{$envName} .= ":$oldLib" if ($oldLib);
 	}

	return ($oldOracleHome, $oldSharedLibPath);
}

sub connect {
	my $self = shift;
	my $timeout = shift || $DEFAULT_TIMEOUT;
	my $tries = shift || 1;

	my ($previousOracleHome, $previousSharedLibraryPath) = $self->_setupOracleHomeUsingSearchPath(\@DEFAULTORACLEHOMESEARCHPATH);

	$self->setPreviousLDLibraryPath($previousSharedLibraryPath);
	$self->setPreviousTNSAdmin($ENV{'TNS_ADMIN'});

	if ( defined($self->tnsAdminDir()) ) {
		$ENV{'TNS_ADMIN'} = $self->tnsAdminDir();
	} elsif ( -f "$ENV{'HOME'}/config/tnsnames.ora" ) {
		$ENV{'TNS_ADMIN'} = "$ENV{'HOME'}/config";
	}

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
	my $sid = $self->sid();
	my $host = $self->host();
	my $connectingTo;

	#
	# connecting as sys requires additional clause 'as sysdba' or
	# 'as sysoper'
	#
	if ($user eq "sys") {
		$dbiSettings{'ora_session_mode'} = DBD::Oracle::ORA_SYSDBA();
	}

	if (!defined($password) || $password =~ /^\s*$/) {
		my $error = "Error: undefined or empty password for SID: [$sid] - perhaps ./startup needs to be run?";
		$self->setError($error);
		return undef;
	}

	if ($self->debug()) {
		print "DEBUG: ORACLE_HOME=$ENV{'ORACLE_HOME'}\n";
		print "DEBUG: Connecting to: dbi:Oracle:host=$host;sid=$sid, $user, $password\n";
	}

	my $connectSub;

	if (defined($host)) {

		$connectingTo = "user=$user sid=$sid host=$host port=$DEFAULT_LISTENER_PORT";
		$connectSub = sub { 
			$handle = DBI->connect(
				"dbi:Oracle:host=$host;sid=$sid;port=$DEFAULT_LISTENER_PORT", $user, $password, \%dbiSettings
			);
		};

	} else {

		$connectingTo = "user=$user sid=$sid";
		$connectSub = sub {
			$handle = DBI->connect(
				"dbi:Oracle:$sid", $user, $password, \%dbiSettings
			);
		};
	}

	for (my $try  = 0; $try < $tries; ++$try) {

		if(!ariba::Ops::Utils::runWithForcedTimeout($timeout, $connectSub)) {
			$self->setError("Timed-out trying to connect to [$connectingTo] after $timeout seconds, ".($try+1)." tries");
			$self->disconnect();
			next;
		} elsif ( $@ or !defined($handle)) {
			# TMID 43600
			# Connection should retry after ORA-12537
			if ($DBI::err =~ /ORA-12537/i) {
				$self->setError("Timed-out (ORA-12537) trying to connect to [$connectingTo] after $timeout seconds, ".($try+1)." tries");
				$self->disconnect();
				next;
			} else {
				$self->setError("Error: $DBI::errstr for [$connectingTo]");
				$@ = '';
				last;
			}
		} else {
			$self->setError(undef);
			last;
		}
	}

	return undef if $self->error();

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

	if ( defined( $self->previousTNSAdmin() ) ) {
		$ENV{'TNS_ADMIN'} = $self->previousTNSAdmin();
	}
}

sub executeSqlWithTimeout {
	my $self = shift;
	my $sql = shift;
	my $timeout = shift || $DEFAULT_TIMEOUT;
	my $resultsRef = shift;
	my $bindVariablesRef = shift;

	my $coderef;
	my $start = time();

	if ( ref($resultsRef) eq "ARRAY" ) {
		$coderef = sub { @$resultsRef = $self->executeSql($sql, $bindVariablesRef); };
	} else {
		$coderef = sub { $$resultsRef = $self->executeSql($sql, $bindVariablesRef); };
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

sub dbExport {
	my $self = shift;
	my $exportParamsHash = shift;
	return $self->_doExportImport($exportParamsHash, "export");
}

sub dbImport {
	my $self = shift;
	my $importParamsHash = shift;
        my $dataPump = shift;
	return $self->_doExportImport($importParamsHash, "import",$dataPump);
}

sub _doExportImport {
	my $self = shift;
	my $paramsHash = shift;
	my $action = shift;
        my $dataPump = shift;

	if ($action ne "import" && $action ne "export") {
		$self->setError("_doExportImport called with unrecognized action: $action");
		return undef;
	}

	if ( !ref($paramsHash) || ref($paramsHash) ne "HASH" ) {
		$self->setError("$action: argument must be a hash ref containing values");
		return undef;
	}

	my ($previousOracleHome, $previousSharedLibraryPath, $previousTnsAdmin, $previousNLSLang, $tnsDir) = $self->setupOracleENVForHostAndSid($self->host(), $self->sid());
	# let initialize errors percolate up
	return unless $tnsDir;

	my $binaryName = ($action eq "export" ? "expdp": $dataPump ? "impdp" : "imp");
	my $command = $ENV{'ORACLE_HOME'} . "/bin/" .  $binaryName;
	my @args = $self->user() . "@" . $self->sid();


	while (my ($keyword, $value) = each %{ $paramsHash } ) {

		if (ref($value) eq "ARRAY" ) {
			push @args, $keyword . "='(" . join("," => @{$value} ) . ")'";
		} else {
			push @args, $keyword . "='" . $value . "'";
		}
	}

	my $commandString = "$command @args";
	if ($self->debug()) {
		print "DEBUG: $action: Running command:\n";
		print "DEBUG: $commandString\n";
	} else {
	 	$commandString .= " > /dev/null 2>&1";
	}


	unless( open(EXPCMD, "|$commandString" ) ) {
		$self->setError("$action: Failed to run $binaryName binary: $!");
		return undef;
	}
	if ( !ref($paramsHash) || ref($paramsHash) ne "HASH" ) {
		$self->setError("$action: argument must be a hash ref containing values");
		return undef;
	}

	print EXPCMD $self->password(),"\n";

	unless( close(EXPCMD) ) {
		if ($!) {
			$self->setError("$action: Syserror closing $binaryName pipe: $!");
		} else {
			$self->setError("$action: $binaryName command returned status $?");
		}
	}

	$self->cleanupOracleENV($previousOracleHome, $previousSharedLibraryPath, $previousTnsAdmin, $previousNLSLang, $tnsDir);

	return 1;
}

sub setupOracleENVForDBCs {
	my $self = shift;
	my @dbcs = @_;

	my (@results);
	for my $dbc (ariba::Ops::DBConnection->uniqueConnectionsByHostAndSid(@dbcs)) {
		@results = $self->setupOracleENVForHostAndSid($dbc->host(), $dbc->sid());
	}
	return @results;
}

sub _initializeExportImportENV {
	my $self = shift;

	#carp "Use of _initializeExportImportENV is deprecated\n";

	return $self->setupOracleENVForHostAndSid($self->host(), $self->sid());
}

sub setupOracleENVForHostAndSid {
	my $self = shift;
	my $host = shift;
	my $sid = shift;

	# create TNS dir/file
	my $tnsDir = "/tmp/OracleClient".$$;

	# obtain and set the correct encoding using sql
	my @results = $self->executeSql("SELECT USERENV ('LANGUAGE') FROM DUAL");
	my $previousNLSLang = $ENV{'NLS_LANG'};
	$ENV{'NLS_LANG'} = shift @results;

	my @oracleHomeSearchPath = @DEFAULTORACLEHOMESEARCHPATH;
	my ($previousOracleHome, $previousSharedLibraryPath) = $self->_setupOracleHomeUsingSearchPath(\@oracleHomeSearchPath);

	unless ( -d $tnsDir ) {
		eval { mkpath($tnsDir, 0, 0755) };
		if ($@) {
			$self->setError("setupOracleENVForHostAndSid: failed to create tmp dir for export/import: $@");
			return;
		}
	}

	my $tnsnamesFileName = $tnsDir."/tnsnames.ora";
	my $sqlnetFileName = $tnsDir."/sqlnet.ora";

	unless ( open( SQLNETFILE, ">$sqlnetFileName") ) {
		$self->setError("setupOracleENVForSid: failed to create sqlnet.ora in $tnsDir: $!");
		return;
	}

	my $sqlnetString = 
		"AUTOMATIC_IPC = ON\n".
		"TRACE_LEVEL_CLIENT = OFF\n".
		"NAMES.DEFAULT_DOMAIN = world\n".
		"SQLNET.EXPIRE_TIME = 10\n";

	print SQLNETFILE $sqlnetString;
	close SQLNETFILE;

	unless ( open( TNSFILE, ">>$tnsnamesFileName") ) {
		$self->setError("setupOracleENVForHostAndSid: failed to create tnsnames.ora in $tnsDir: $!");
		return;
	}

	print TNSFILE $sid, ".world=", ariba::rc::Utils::connectStringForSidOnHost($sid, $host), "\n";
	close TNSFILE;

	# set TNS environment variable
	my $previousTnsAdmin = $ENV{'TNS_ADMIN'};
	$ENV{'TNS_ADMIN'} = $tnsDir;

	return ($previousOracleHome, $previousSharedLibraryPath, $previousTnsAdmin, $previousNLSLang, $tnsDir);
}

sub cleanupOracleENV {
	my $self = shift;
	my ($previousOracleHome, $previousSharedLibraryPath, $previousTnsAdmin, $previousNLSLang, $tnsDir) = @_;

	my $envName = sharedLibEnvName();

	$tnsDir = $tnsDir || $ENV{'TNS_ADMIN'};

	$ENV{'ORACLE_HOME'} = $previousOracleHome;
	$ENV{$envName} = $previousSharedLibraryPath;
	$ENV{'TNS_ADMIN'} = $previousTnsAdmin;
	if ($previousNLSLang) {
		$ENV{'NLS_LANG'} = $previousNLSLang;
	} else {
		delete($ENV{'NLS_LANG'});
	}

	rmtree($tnsDir) if ($tnsDir && -e $tnsDir);
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

	my $colsep = ref($self)->colsep();

	print "DEBUG SQL: [$sql]\n" if $self->debug();

	$self->setError();

	if ( $sql =~ /^\s*exec/i ) {
		$sql =~ s/^\s*exec\w*//;
		my $realSql;

		$handle->func(30000, 'dbms_output_enable');
		# If a BEGIN was provided, then just pass that sql on,
		# Otherwise, wrap in BEGIN END; and chop extra ; off
		if ( $sql !~ m/\bBEGIN\b/ ) {
			# old monitoring library allowed this
			$sql =~ s/;\s*$//;	
			$realSql = " BEGIN $sql; END;";
		} else {
			$realSql = $sql;
		}
		my $sth = $handle->prepare($realSql) || return $self->returnStatementHandleError($sql);
		$self->rememberStatementHandle($sth);
		$sth->execute();

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

		while(my $rv = $handle->func('dbms_output_get')) {
			push(@results, $rv);
		}

		$self->forgetStatementHandle($sth);

	} else {

		# old monitoring library allowed this
		$sql =~ s/;\s*$//;	
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
			while( my $row = $sth->fetchrow_hashref() ) {
				push(@results, $row);
			}
		}

		$self->forgetStatementHandle($sth);
	}

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

#
# uses sqlplus to run the specified file
# OracleClient does not need to be connected(), but must have
# been initialized with a valid DBConnection or db info
sub executeSqlFile {
	my $self = shift;
	my $file = shift;
	my $outputRef = shift;

	$self->setError();

	unless ( -f $file ) {
		$self->setError("File not found: $file ");
		return;
	}

	my $dbUsername = $self->user();
	my $dbPassword = $self->password();
	my $dbServerid = $self->sid();
	my $dbServerHost = $self->host();

	#
	# accumulate interesting output in output buffer
	#
	my $output = "";

	#
	# setup environment to run sqlplus
	#
	$ENV{'ORACLE_HOME'} = '/usr/local/oracle';
	my $envName = ariba::rc::Utils::sharedLibEnvName();
	$ENV{$envName} = "$ENV{'ORACLE_HOME'}/lib";
	$ENV{'PATH'} = "$ENV{'ORACLE_HOME'}/bin:$ENV{'PATH'}";
	my $command = "sqlplus";

	my $connectString = ariba::rc::Utils::connectStringForSidOnHost($dbServerid, $dbServerHost);

	print "\n" . '=' x 50 . "\n" if $self->debug();
	print "Connect string is $connectString\n" if $self->debug();

	my @sqlplusArgs = ("$dbUsername\@\"$connectString\"", "\@$file" );

	print ">>>>Running $file\n" if $self->debug();
	print "command = $command @sqlplusArgs \n" if $self->debug();

	my $error = "";

	my $sqlplus = Expect->spawn($command, @sqlplusArgs);
	my $exited = 0;
	$sqlplus->log_stdout(0);
	$sqlplus->expect(30,
			['Enter password: ', sub {
			my $self = shift;
			$self->log_stdout(0);
			$self->send("$dbPassword\r");
			$self->expect(0, '-re', "\r\n");
			$self->log_stdout(1);
			}]);

	$sqlplus->expect(undef, 
		['eof' => sub { 
			$exited = 1;
		}],
		['-re','SQL>' => sub {
			$exited = 1;		
		}],
		['-re','^ERROR' => sub {
			$error .= $sqlplus->match() . $sqlplus->after();
			return exp_continue();
		}],
		['-re','^ORA' => sub {
			$error = $sqlplus->match() . $sqlplus->after();
			return exp_continue();
		}],
		['-re','^SP' => sub {
			$error .= $sqlplus->match() . $sqlplus->after();
			return exp_continue();
		}],
	);

	if ($error) {
		$self->setError($error);
		$output = undef;
	} else {
		$output .= $sqlplus->exp_before();
	}

	undef $sqlplus;
	return $output;
}

1;
