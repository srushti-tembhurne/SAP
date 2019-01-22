#!/usr/local/bin/perl

package ariba::Ops::TCP::Server;
use strict;
use IO::Socket::INET;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use ariba::Ops::TCP::Socket;
use ariba::Ops::PersistantObject;

use base qw ( ariba::Ops::PersistantObject );

sub objectLoadMap {
	my $class = shift;

	my %map = (
		'connections' => '@ariba::Ops::TCP::Socket',
	);

	return(\%map);
}

sub new {
	my $class = shift;
	my $port = shift;
	my $self = $class->SUPER::new($port);
	my $sock;

	# setup a socket, and bind to a port
	$sock = IO::Socket::INET->new(Listen => 5,
				      LocalPort => $port,
				      Proto => 'tcp',
				      ReuseAddr => 1,
				      Blocking => 0);
	return undef unless $sock;

	print STDERR scalar(localtime()), ": Started server on port $port.\n" if($main::debug);

	$self->setCounter(1);
	$self->setSocket($sock);

	return $self;
}

sub removeFromConnections {
	my $self = shift;
	my $conn = shift;
	my @list;

	foreach my $c ($self->connections()) {
		next if($c == $conn);
		push(@list, $c);
	}

	$self->setConnections(@list);
}

sub incrementCounter {
	my $self = shift;
	$self->setCounter($self->counter()+1);
}

sub accept {
	my $self = shift;
	my $sock = $self->socket();
	my $fh;
	my $flags;

	#
	# call accept and if we get a connection, create a descriptor, and
	# add it to our list
	#
	$fh = $sock->accept();
	return undef unless $fh;

	my $ipdata = $fh->peername();
	my ($jnk, $ipaddr) = unpack_sockaddr_in($ipdata);
	$ipaddr = inet_ntoa($ipaddr);
	
	my $counter = $self->counter();
	$self->incrementCounter();
	print STDERR scalar(localtime()), ": New connection ($counter) from [$ipaddr]\n" if($main::debug);

	$flags = fcntl($fh, F_GETFL, 0);
	unless($flags = fcntl($fh, F_SETFL, $flags | O_NONBLOCK)) { 
		$fh->shutdown(2);
		return undef;
	}

	my $conn = ariba::Ops::TCP::Socket->newFromServer($fh,$self,$counter);
	$conn->setIpAddress($ipaddr);

	$self->appendToConnections($conn);
	return($conn); # returns the descriptor
}

sub dir {
	return "/dev/null";
}

sub save {
	return undef;
}

sub recursiveSave {
	return undef;
}

1;
