package ariba::Ops::DatabaseManager;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/DatabaseManager.pm#1 $

# this is an abstract class for ::BerkeleyDB and ::RDBMS
# they inherit from this.

use strict;

my $DEBUG = 1;

###############
# Shared Class Data

my $_dbHandles	= {};
my $_dbEnv	= undef;

=pod

=head1 NAME

ariba::Ops::DatabaseManager - Generic Database Connection and Handle Manager

=head1 SYNOPSIS

package Foo;

use strict;
use vars qw(@ISA);

@ISA = qw(ariba::Ops::DatabaseManager::BerkeleyDB);

my $handle = Foo->handle( $dbName );

package main;

use Foo;

Foo->setBackingStore(
	'type' => 'BTree',
	'dir'  => '/tmp',
);

=head1 DESCRIPTION

Generic DB Access class. Provides handle caching..

=head1 API

=over 4

=cut

###############
# Class Methods

sub setPrimaryColumn {
	my $class  = shift;
	my $dbName = shift;
	my $column = shift;

	$_dbHandles->{$dbName}->{'primary'} = $column;
}

sub primaryColumn {
	my $class  = shift;
	my $dbName = shift;

	return $_dbHandles->{$dbName}->{'primary'};
}

sub setDBEnv {
	my $class = shift;
	my $env   = shift;

	$_dbEnv   = $env;
}

sub dbEnv {
	my $class = shift;
	return $_dbEnv;
}

sub setConnected {
	my $class  = shift;
	my $dbName = shift;
	
	$_dbHandles->{$dbName}->{'connected'} = 1;
}

=pod

=item * isConnected( dbName )

Check if you are connected to named database. Returns 1 upon success

=cut

sub isConnected {
	my $class  = shift;
	my $dbName = shift;

	return $_dbHandles->{$dbName}->{'connected'} || 0;
}

=pod

=item * setHandle( dbName, handle )

Caches a database handle. Handle can be any blessed reference

=cut

sub setHandle {
	my $class  = shift;
	my $dbName = shift;
	my $handle = shift;

	$_dbHandles->{$dbName}->{'handle'} = $handle;

	$class->setConnected($dbName);
}

=pod

=item * handle( dbName )

Returns a cached handle.

Will attempt to connect to dbName if no active handle exists.

=cut

sub handle {
	my $class  = shift;
	my $dbName = shift;

	unless ($class->isConnected($dbName)) {

		eval { $class->_connectToDB($dbName) };

		if ($@) {
			die "Couldn't connect to database: $dbName - $@";
		}
	}

	return $_dbHandles->{$dbName}->{'handle'};
}

=pod

=item * handles()

Returns all currently opened and cached handles.

=cut

sub handles {
	my $class   = shift;
	my @handles = ();

	while (my ($handleName, $handle) = each %{$_dbHandles}) {

		if ($class->isConnected($handleName)) {
			push @handles, $handle->{'handle'};
		}
	}

	return @handles;
}

=pod

=item * disconnect( dbName )

Mark the dbName handle as inactive, and disconnect.

=cut

sub disconnect {
	my $class  = shift;
	my $dbName = shift;

	$_dbHandles->{$dbName}->{'connected'} = 0;
}

1;

__END__

=pod

=back

=head1 AUTHOR

Daniel Sully <dsully@ariba.com>

=cut
