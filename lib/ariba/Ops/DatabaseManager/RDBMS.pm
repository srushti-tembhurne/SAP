package ariba::Ops::DatabaseManager::RDBMS;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/DatabaseManager/RDBMS.pm#2 $

use strict;
use ariba::Ops::DatabaseManager;
use DBI;

# inherit helper methods
use vars qw(@ISA);
@ISA   = qw(ariba::Ops::DatabaseManager);

my $DEBUG = 0;

#################
# Class variables

my $ClassVars = {
	'DBType'	=> 'Oracle',
	'DBName'	=> '',
	'DBUser'	=> 'tmaster1',
	'DBPass'	=> 'tmaster1',
};

###############
# Class methods

sub DBType {
	my $class = shift;
	return $ClassVars->{'DBType'};
}

sub setDBType {
	my $class  = shift;
	my $dbType = shift;

	my @drivers = DBI->available_drivers();

	unless (grep { $dbType } @drivers) {
		print "DBType: [$dbType] is not a valid DBI driver!\n";
		print "Available drivers are: @drivers\n";
		die;
	}
	
	$ClassVars->{'DBType'} = $dbType;
}

sub DBName {
	my $class = shift;
	return $ClassVars->{'DBName'};
}

sub setDBName {
	my $class = shift;
	$ClassVars->{'DBName'} = shift;
}

sub DBUser {
	my $class = shift;
	return $ClassVars->{'DBUser'};
}

sub setDBUser {
	my $class = shift;
	$ClassVars->{'DBUser'} = shift;
}

sub DBPass {
	my $class = shift;
	return $ClassVars->{'DBPass'};
}

sub setDBPass {
	my $class = shift;
	$ClassVars->{'DBPass'} = shift;
}

#
sub _connectToDB {
	my $class  = shift;
	my $dbName = shift;

	return 1 if $class->isConnected($dbName);

	print "in _connectToDB with dbName: [$dbName]\n" if $DEBUG;

	my $db     = 0;
	my $attr   = { 
		PrintError => 1, 
		RaiseError => 0, 
		AutoCommit => 1,
		LongReadLen => 256*1024,
	};

	my $dbType = $class->DBType();
	my $dbUser = $class->DBUser();
	my $dbPass = $class->DBPass();
		     $class->setDBName($dbName);

	DBI->trace($DEBUG);
	
	unless( $db && $db->FETCH('Active') && $db->ping() ) {

		$db = DBI->connect("dbi:$dbType:$dbName",$dbUser,$dbPass,$attr) ||
			die "Cannot connect to database: $DBI::errstr";
	}

	$class->setHandle($dbName, $db);
}

sub disconnect {
	my $class  = shift;
	my $dbName = shift;

	my $handle = $class->handle($dbName);

	$handle->disconnect();

	$class->SUPER::disconnect($dbName);
}

sub columns {
	my $class = shift;


}

1;

__END__
