package ariba::Ops::DatabaseManager::BerkeleyDB;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/DatabaseManager/BerkeleyDB.pm#3 $

use strict;
use ariba::Ops::DatabaseManager;
use BerkeleyDB;

# inherit helper methods
use vars qw(@ISA);
@ISA   = qw(ariba::Ops::DatabaseManager);

my $DEBUG = 0;

#################
# Class variables

my $ClassVars = {
	'DBType'	=> 'Btree',
	'Duplicate'	=> 1,
	'Transactions'	=> 0,
	'Dir'		=> '/tmp',
};

###############
# Class methods

sub DBType {
	my $class = shift;
	return $ClassVars->{'DBType'};
}

sub setDBType {
	my $class = shift;
	$ClassVars->{'DBType'} = shift;
}

sub Duplicate {
	my $class = shift;
	return $ClassVars->{'Duplicate'};
}

sub setDuplicate {
	my $class = shift;
	$ClassVars->{'Duplicate'} = 1;
}

sub unsetDuplicate {
	my $class = shift;
	$ClassVars->{'Duplicate'} = 0;
}

sub Transactions {
	my $class = shift;
	return $ClassVars->{'Transactions'};
}

sub setTransactions {
	my $class = shift;
	$ClassVars->{'Transactions'} = 1;
}

sub unsetTransactions {
	my $class = shift;
	$ClassVars->{'Transactions'} = 0;
}

sub Dir {
	my $class = shift;
	return $ClassVars->{'Dir'};
}

sub setDir {
	my $class = shift;
	$ClassVars->{'Dir'} = shift;
}

sub _connectToDB {
	my $class  = shift;
	my $dbName = shift;

	return 1 if $class->isConnected($dbName);

	my $db;
	my $property = '';
	my $flags    = '';
	
	# try and grab the class version of the environment
	my $env = $class->dbEnv();
	
	unless (defined $env) {

		$flags = $class->Transactions() ?
			DB_CREATE | DB_INIT_MPOOL | DB_INIT_LOCK | DB_INIT_TXN | DB_RECOVER | DB_THREAD :
			DB_CREATE | DB_INIT_MPOOL | DB_INIT_CDB;
		
		$env = BerkeleyDB::Env->new(
			-Flags          => $flags,
			-Home		=> $class->Dir(),
			-Verbose	=> 1,
		) or die "BerkeleyDB::Env: [$!] [$BerkeleyDB::Error]";

		$class->setDBEnv($env);
	}
	
	if ($class->Duplicate()) {
		$property = DB_DUP|DB_DUPSORT;
	} else {
		$property = 0;
	}

	#
	if ($DEBUG) {
		print "Class: $class\n";
		print "\tFlags: DB_CREATE | DB_INIT_MPOOL | ";

		if ($class->Transactions()) {
			print "DB_INIT_LOCK | DB_INIT_TXN\n";
		} else {
			print "DB_INIT_CDB\n"
		}

		print "\tEnv: $env\n";
		print "\tProperty: $property\n";
		print "\tFilename: $dbName\n";
		print "\tDir: $class->Dir()\n";
		print "\n";
	}

	# frob the instansiation of the db accordingly. 
	if ($class->DBType() =~ /btree/i) {

		$db = BerkeleyDB::Btree->new(
			-Flags          => DB_CREATE,
			-Env            => $env,
			-Property	=> $property,
			-Filename       => $dbName,
		) or die "BerkeleyDB::Hash: [$BerkeleyDB::Error]";

	} elsif ($class->DBType() =~ /hash/i)  {

		$db = BerkeleyDB::Hash->new(
			-Flags          => DB_CREATE,
			-Env            => $env,
			-Property	=> $property,
			-Filename       => $dbName,
		) or die "BerkeleyDB::Hash: [$BerkeleyDB::Error]";

	} else {
		die "Invalid DBType specified: [$class->DBType()]";
	}

	$class->setHandle($dbName, $db);

	return 1;
}

sub disconnect {
	my $class   = shift;
	my $dbName  = shift;

	my @handles = ();

	if (defined $dbName and $dbName !~ /^\s*$/) {

		push @handles, $class->handle($dbName);

	} else {
		push @handles, $class->handles();
	}

	for my $handle (@handles) {

		$handle->db_close();
		undef $handle;

		$class->SUPER::disconnect($dbName);
	}
}

sub commit {
	my $class  = shift;
	my $dbName = shift;

	my @handles = ();

	if (defined $dbName and $dbName !~ /^\s*$/) {
		push @handles, $class->handle($dbName);

	} else {
		push @handles, $class->handles();
	}

	for my $handle (@handles) {
		$handle->db_sync();
	}
}

1;

__END__
