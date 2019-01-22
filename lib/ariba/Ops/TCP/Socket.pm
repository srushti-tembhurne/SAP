#!/usr/local/bin/perl

package ariba::Ops::TCP::Socket;
use strict;
use IO::Socket::INET;
use Errno qw(EAGAIN EWOULDBLOCK);
use ariba::Ops::PersistantObject;

use base qw ( ariba::Ops::PersistantObject );

sub objectLoadMap {
	my $class = shift;

	my %map = (
		'manager' => 'ariba::Ops::TCP::Server',
	);

	return(\%map);
}

sub new {
	my $class = shift;
	my $host = shift;
	my $port = shift;
	my $instance = shift || time();
	my $fh;

	my $self = $class->SUPER::new($instance);

	#
	# create a socket here
	#
	$fh = IO::Socket::INET->new(PeerAddr => $host,
				    PeerPort => $port,
				    Proto => 'tcp',
				    Blocking => 0);
	return undef unless $fh;
	$self->setSocket($fh);

	return $self;
}

sub newFromServer {
	my $class = shift;
	my $sock = shift;
	my $mgr = shift;
	my $instance = shift;

	my $self = $class->SUPER::new($instance);

	$self->setSocket($sock);
	$self->setManager($mgr);
	
	return $self;
}

sub appendToReadBuffer {
	my $self = shift;
	my $str = shift;

	$self->setReadBuffer( $self->readBuffer() . $str );
}

sub read {
	my $self = shift;

	return undef if($self->closed());

	my $input = $self->checkSocketForData();
	if(!$input && length($self->readBuffer()) == 0) {
		return undef;
	}

	$self->appendToReadBuffer($input) if($input);

	if($self->readBuffer() =~ /[\r\n]/) {
		my $str = $self->readBuffer();
		$str =~ s/^([^\r\n]*)[\r\n]//;
		my $line = $1;
		$str =~ s/^[\r\n]+//;
		$self->setReadBuffer($str);
		return $line;
	}

	return undef;
}

sub checkSocketForData {
	my $self = shift;
	my $buf;
	my $ret;

	# return "" for no data, undef for EOF
	my $socket = $self->socket();
	$ret = $self->socket()->recv($buf, 512, 0);
	unless (defined($ret)) {
		if($!{EAGAIN} || $!{EWOULDBLOCK}) {
			return "";
		} else {
			$self->close();
			return "";
		}
	}

	unless($buf) {
		# EOF
		$self->close();
		return undef;
	}

	$buf =~ s/\r//g; # CR is evil

	return $buf;
}

sub appendToWriteBuffer {
	my $self = shift;
	my $str = shift;

	$self->setWriteBuffer( $self->writeBuffer() . $str );
}

sub write {
	my $self = shift;
	my $str = shift;
	my $ret;

	return(0) if ($self->closed());

	$self->appendToWriteBuffer($str);
	$str = $self->writeBuffer();

	# write to the socket
	#
	# we wrap this in eval since IO::Socket::INET can die here
	#
	eval {
		$ret = $self->socket()->send($str, 0);
	};

	#
	# and if IO::Socket::INET dies, we treat it like an EOF
	#
	if($@) {
		$self->close();
		return 0;
	}

	unless (defined($ret)) {
		if($!{EAGAIN} || $!{EWOULDBLOCK}) {
			return 1;
		} else {
			# close the socket and return
			$self->close();
			return 0;
		}
	} else {
		$self->setWriteBuffer(substr($str, $ret));
	}

	return 1;
}

sub close {
	my $self = shift;

	return if($self->closed());

	my $id = $self->instance();
	my $ip = $self->ipAddress();
	print STDERR scalar(localtime()), ": EOF encountered for socket #$id [$ip]\n" if($main::debug);

	$self->manager()->removeFromConnections($self) if ($self->manager());
	$self->socket()->shutdown(2);
	$self->setClosed(1);
	ariba::Ops::TCP::Socket->_removeObjectFromCache($self);
}

1;
