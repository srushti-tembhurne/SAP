#
#
# $Id: //ariba/services/tools/lib/perl/ariba/util/SharedMemory.pm#16 $
#
# This module provides simple API to store and retrieve scalars in
# sharedmemory.
#
# API calls:
#
#  new(key): create a new segment (or attach to an existing one) with key
#  read: read contents of sharedmemory
#  write: write new value to sharedmemory
#  destroy: delete sharedmemory segment
#  exists: check to see if the shared memory segment exists.
#

use strict;
use Digest::MD5 qw( md5_hex );

package ariba::util::SharedMemory;

# Linux, FreeBSD and HP-UX
# IPC_CREAT = 512
# IPC_PRIVATE = 0
# IPC_RMID = 0
# IPC_STAT = 2

# Solaris
# IPC_CREAT = 512
# IPC_PRIVATE = 0
# IPC_RMID = 10
# IPC_STAT = 12

sub IPC_PRIVATE { 0 };
sub IPC_CREAT { 512 };
sub IPC_RMID { $^O eq "solaris" ? 10 : 0  };
sub IPC_STAT { $^O eq "solaris" ? 12 : 2  };

my $SIZE = 2 * 1024;

my $packTemplate = "L";
my $SIZEOFLONG = length(pack($packTemplate));

my $debug = 0;

sub new {
	my $class = shift;
	my $shareKey = shift || IPC_PRIVATE();
	my $size = shift;
	my $offset = 0;

	my $self = {};

	bless($self, $class);

	$shareKey = unpack('i', pack('A4', Digest::MD5::md5_hex($shareKey) ))
			unless ($shareKey =~ /^\d+$/);

	$self->{'shareKey'} = $shareKey;
	$self->_setSize($size);

	return $self;
}

sub attach {
	my $self = shift;

	my $shareKey = $self->key();

	#
	# with IPC_PRIVATE as shareKey shmget will end up creating a 
	# new segment which is not what we want. Disallow such a use of the
	# API
	#
	if ($shareKey == IPC_PRIVATE()) {
		return undef;	
	}

	my $flags = 0600;

	#
	# attach to an existing segment
	#
	my $id = shmget($shareKey, 0, $flags);

	$self->_setId($id);

	return $id;
}

sub create {
	my $self = shift;

	my $shareKey = $self->key();

	my $flags = 0600;
	$flags |= IPC_CREAT();

	#
	# create a new segment
	#
	my $id = shmget($shareKey, $self->_size(), $flags);

	# Caller should check/handle $!
	if ($! && $debug) {
	    print STDERR "ERROR: $!\n";
	}

	$self->_setId($id);

	return $id;
}

sub key {

	my $self = shift;

	return $self->{'shareKey'};
}

sub _setId {

	my $self = shift;
	my $id = shift;

	$self->{'shareId'} = $id;
}

sub id {

	my $self = shift;

	return $self->{'shareId'};
}

sub _setSize {
	my $self = shift;
	my $size = shift;

	if ($size) {
		$size += $SIZEOFLONG;
	} else {
		$size = $SIZE;
	}

	$self->{'size'} = $size;
}

sub _size {

	my $self = shift;

	return $self->{'size'};
}

sub read {
	my $self = shift;

	my $shareId = $self->id();
	return undef unless (defined($shareId));
	my $value;
	my $packedLength = 0;
	my $length;

	# get our data length from the segment, then read that much data

	shmread($shareId, $packedLength, 0, $SIZEOFLONG);

	$length = unpack($packTemplate, $packedLength);

	return undef if(!defined($length) || $length == 0);

	$value = "";
	shmread($shareId, $value, $SIZEOFLONG, $length);

	#
	# display error only when debug is enabled.
	# so that users who cannot read the shared memory
	# due to permissions can handle it themseleves.
	#
	if ($! && $debug) {
		print STDERR "ERROR: $!\n";
	}

	return $value;
}



sub write {
	my $self = shift;
	my $data = shift;

	my $shareId = $self->id();
	return undef unless (defined($shareId));

	my $dataLen = length($data);

	if ( $dataLen > $self->_size() - $SIZEOFLONG ) {
		$data = substr($data, 0, $self->_size() - $SIZEOFLONG);
		$dataLen = length($data);
	}

	# first write the size of the data we are writing

	my $packedDataLen = pack($packTemplate, $dataLen);
	shmwrite( $shareId, $packedDataLen . $data, 0, $SIZEOFLONG + $dataLen) || 
			    die ("shmwrite($shareId) $!");

	return $dataLen;
}

sub exists {
	my $self = shift;

	my $shareId = $self->id();
	unless (defined($shareId)) {
		$self->attach();
		$shareId = $self->id();
		return undef unless (defined($shareId));
	}

	my $arg = 1;

	shmctl($shareId, IPC_STAT(), $arg) || return undef;

	return $arg;
}

sub destroy {
	my $self = shift;

	unless ($self->exists()) {
		return 0;
	}

	my $shareId = $self->id();

	my $arg = 1;

	shmctl($shareId, IPC_RMID(), $arg);
	#
	# display error only when debug is enabled.
	# so that users who cannot delete the shared memory
	# due to permissions can handle it themseleves.
	#
	if ($! && $debug) {
	    print STDERR "ERROR: $!\n";
	}

	return 1;
}

sub main {

	my $join = "!@#UNiQuEtRiNg-=!";
	my $skey = "1234";

	unless (@ARGV) {
		my $msg = "Hello world from ariba::util::SharedMemory::main()";
		my $shm = ariba::util::SharedMemory->new($skey);

		$shm->create();
		my $key = $shm->key();
		my $id = $shm->id();

		print "key = $key\n";
		print "id = $id\n";

		my $len = $shm->write($msg);

		print "wrote data of length $len\n";

		$msg = $shm->read();

		print "read = $msg\n";

		$shm->destroy();
	} elsif ($ARGV[0] eq "read") {
		my $shm = ariba::util::SharedMemory->new($skey);

		unless ($shm->exists()) {
		    print "bad shm key $skey\n";
		    return;
		}

		$shm->attach();
		my $msg = $shm->read();
		my %hash = split($join, $msg);

		print "id = ", $shm->id(), "\n";

		print "read =\n";
		for my $key (keys(%hash)) {
		    print "  $key = $hash{$key}\n";
		}
		$shm->destroy();

	} elsif ($ARGV[0] eq "write") {
		my $msg;
		my %hash = (
			    'dubey', 'manish',
			    'grillo', 'dan'
			    );

		my $shm = ariba::util::SharedMemory->new($skey);
		$shm->create();

		my $key = $shm->key();
		print "key = $key\n";

		$msg = join($join, %hash);
		my $len = $shm->write($msg);

		print "wrote data of length $len\n";

	}
}

#main();

1;
