# $Id: //ariba/services/tools/lib/perl/ariba/Ops/MySQLHelper.pm#3 $
package ariba::Ops::MySQLHelper;

use strict;

my $debug = 0;

sub lockAndFlushMyISAMTables {
	my $class = shift;
	my $mySQLClient = shift;
	my $timeout = shift;

	unless ( defined ($mySQLClient) ) {
		warn("Invalid MySQLClient\n");
		return(0);
	}

	unless ( $mySQLClient->handle() ) {
		warn("Invalid MySQLClient database handle\n");
		return(0);
	}

	unless ( defined ($timeout) ) {
		warn("Timeout is not specified\n");
		return(0);
	}

	# Lock tables
	my @aStatements = ariba::Ops::MySQLHelper->listOfLockTableStatementsForMyISAMTables($mySQLClient, $timeout );
	unless ( @aStatements ) {
		warn("Error in getting the list of SQL statements containing tables to be locked.\n");
		return(0);
	}

	my $resultExec = $mySQLClient->executeSqlSetWithTimeout ( \@aStatements, $timeout );
	unless ( $resultExec ) {
		warn("Error in executing lock table statements\n");
		return(0);
	}

	# Flush tables
	@aStatements = ariba::Ops::MySQLHelper->listOfFlushTableStatementsForMyISAMTables( $mySQLClient, $timeout );
	unless ( @aStatements ) {
		warn("Error in getting the list of SQL statements containing tables to be flushed.\n");
		return(0);
	}

	$resultExec = $mySQLClient->executeSqlSetWithTimeout ( \@aStatements, $timeout );
	unless ( $resultExec ) {
		warn("Error in executing flush table statements\n");
		return(0);
	}

	return(1);
}


sub unlockMyISAMTables {
	my $class = shift;
	my $mySQLClient = shift;
	my $timeout = shift;

	unless ( defined ($mySQLClient) ) {
		warn("Invalid MySQLClient\n");
		return(0);
	}

	unless ( $mySQLClient->handle() ) {
		warn("Invalid MySQLClient database handle\n");
		return(0);
	}

	unless ( defined ($timeout) ) {
		warn("Timeout is not specified\n");
		return(0);
	}

	# unlock tables
	my $sSQL = "unlock tables";
	my @aStatements = ( $sSQL );

	my $resultExec = $mySQLClient->executeSqlSetWithTimeout ( \@aStatements, $timeout );
	unless ( $resultExec ) {
		warn("Error in executing lock table statements\n");
		return(0);
	}

	return(1);
}


sub listOfLockTableStatementsForMyISAMTables {
	my $class = shift;
	my $mySQLClient = shift;
	my $timeout = shift;

	my $sSQL = "select concat('lock tables ',table_schema,'.',table_name,' read;') from information_schema.tables where engine='MyISAM' and TABLE_SCHEMA != 'information_schema'";

	my @aStatements = ariba::Ops::MySQLHelper->_generateSetOfSqlToExecute( $mySQLClient, $sSQL, $timeout );

	return(@aStatements);
}

sub listOfFlushTableStatementsForMyISAMTables {
	my $class = shift;
	my $mySQLClient = shift;
	my $timeout = shift;

	my $sSQL = "select concat('flush tables ',table_schema,'.',table_name,';') from information_schema.tables where engine='MyISAM' and TABLE_SCHEMA != 'information_schema'";

	my @aStatements = ariba::Ops::MySQLHelper->_generateSetOfSqlToExecute( $mySQLClient, $sSQL, $timeout );

	return(@aStatements);
}

sub _generateSetOfSqlToExecute {
	my $class = shift;
	my $mySQLClient = shift;
	my $sSQL = shift;
	my $timeout = shift;

	unless ( defined ($mySQLClient) ) {
		warn("Invalid MySQLClient\n");
		return();
	}

	unless ( $mySQLClient->handle() ) {
		warn("Invalid MySQLClient database handle\n");
		return();
	}

	unless ( defined ($sSQL) ) {
		warn("Invalid select statement\n");
		return();
	}

	unless ( defined ($timeout) ) {
		warn("Timeout is not specified\n");
		return();
	}

	my @resultSet = ();
	my $resultSetRef = \@resultSet;

	my $resultExec = $mySQLClient->executeSqlWithTimeout($sSQL, $timeout, $resultSetRef);

	unless ( $resultExec ) {
		warn("SQL execution error\n");
		return();
	}

	if ( $mySQLClient->error() ) {
		warn("SQL execution error\n");
		return();
	}

	my $rowCount = @$resultSetRef;

	if( $rowCount > 0 ) {
		if ( $debug ) {
			print("DEBUG: List of statements in the result set:\n");
				
			foreach my $s ( @$resultSetRef ) {
				print("\t$s\n");
			}
		}

	} else {
		warn("Result set was supposed to contain SQL statements to execute, but is empty\n");
		return();
	}

	return(@resultSet);
}

sub getDataDir {
	my $class = shift;
	my $dbc = shift;
	my $timeout = shift || 60;

	unless ( defined ($dbc) ) {
		warn("Invalid MySQLClient\n");
		return;
	}

	unless ( $dbc->handle() ) {
		warn("Invalid MySQLClient database handle\n");
		return;
	}

	unless ( defined ($timeout) ) {
		warn("Timeout is not specified\n");
		return;
	}

	my $sql = "select \@\@datadir";
	my @results;

	my $resultExec = $dbc->executeSqlWithTimeout(
		$sql,
		$timeout,
		\@results
	);

	unless ( $resultExec ) {
		warn("SQL execution error\n");
		return undef;
	}

	return(@results);
}

sub getBinLogsDir {
	my $class = shift;
	my $dbc = shift;
	my $timeout = shift || 60;

	unless ( defined ($dbc) ) {
		warn("Invalid MySQLClient\n");
		return;
	}

	unless ( $dbc->handle() ) {
		warn("Invalid MySQLClient database handle\n");
		return;
	}

	unless ( defined ($timeout) ) {
		warn("Timeout is not specified\n");
		return;
	}

	my $sql = "select \@\@innodb_log_group_home_dir";
	my @results;

	my $resultExec = $dbc->executeSqlWithTimeout(
		$sql,
		$timeout,
		\@results
	);

	unless ( $resultExec ) {
		warn("SQL execution error\n");
		return undef;
	}

	my $logdir = $results[0];
	$logdir =~ s|/innodb-logs$||;

	return($logdir);
}

sub backupBinLogDirForLogDir {
	my $class = shift;
	my $logdir = shift;

	$logdir =~ s|log01|log02|;
	return($logdir);
}

1;

__END__
