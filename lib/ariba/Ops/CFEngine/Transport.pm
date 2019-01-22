package ariba::Ops::CFEngine::Transport;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/CFEngine/Transport.pm#3 $
# cfengine client
# XXX - quick hack - dsully

use strict;
use lib qw(/usr/local/ariba/lib);
use Digest::MD5;
use IO::Socket;
use ariba::Ops::NetworkUtils;

my $peeraddr = 'cfd';
my $peerport = '5308';
my $version = 1.4; # 1.5
my $debug   = 0;

sub new {
	my $class = shift;
	bless my $self = {}, $class;

	$self->{'hostname'} = ariba::Ops::NetworkUtils::hostname();
	$self->{'ip'}	    = join '.', (unpack'C4',(gethostbyname($self->{'hostname'}))[4]);
	$self->{'reconnect'}= 0;

	print "\tcfengine: using hostname: $self->{'hostname'}\n" if $debug > 2;

	return $self;
}

sub setDebug {
	my $class = shift;

	$debug = shift;
}

sub DESTROY {
	my $self = shift;
	$self->disconnect() unless $self->{'reconnect'};
}

# low level

# TMID: 44544 - Unable to stat files on cfd Server
# On hosts with multiple interfaces socket could have been created on any local interface with INADDR_ANY
# The fix is to create the socket with the local IP address found in the constructor. 
# This is the same IP we use to authenticate with cfd server

sub connect {
	my $self = shift;
        $self->{'sock'} = IO::Socket::INET->new(PeerAddr => $peeraddr,
                                                PeerPort => $peerport,
                                                LocalAddr => $self->{'ip'}) or
                                                die "cfengine: Couldn't connect to server: [$peeraddr:$peerport]: $!";
}

sub auth {
	my $self = shift;

	$self->{'reconnect'} = 0;

	if ($version == 1.4) {

		print qq!\tcfengine: v1.4 send("AUTH $self->{'ip'} $self->{'hostname'}")\n! if $debug > 2;

		$self->send("AUTH $self->{'ip'} $self->{'hostname'}");

	} elsif ($version == 1.5) {

		print qq!\tcfengine: v1.5 send("AUTH $self->{'ip'} $self->{'hostname'} $ENV{'USER'} 0")\n! if $debug > 2;

		$self->send("AUTH $self->{'ip'} $self->{'hostname'} $ENV{'USER'} 0");
	}

	$self->{'reconnect'} = 0;
}

sub disconnect {
	my $self = shift;
	$self->{'sock'}->close() if defined $self->{'sock'};
}

sub get_file {
	my ($self,$file,$dest) = @_;

	print qq!\tcfengine: send("GET $file")\n! if $debug > 2;

	my $sock = $self->send("GET $file");

	open(DEST, ">$dest") or die "cfengine: couldn't write out dest file: [$dest]: $!";

	my $buf = '';
	while (1) {
		my $read = $sock->sysread($buf,16384);
		print DEST $buf;
		last unless $read;
	}

	close(DEST);
}

sub md5_file {
	my ($self,$sfile,$lfile) = @_;

	my $md5 = Digest::MD5->new();
	open F, $lfile or die $!;
	$md5->addfile(\*F);
	my @hash = unpack 'C16', $md5->digest();
	close F;

	print qq!\tcfengine: send("MD5 $sfile @hash")\n! if $debug > 2;
	my $sock = $self->send("MD5 $sfile @hash");
	chomp(my $buf = <$sock>);

	# backwards - CFD_FALSE means the md5 was ok.
	return 1 if $buf =~ /CFD_FALSE/;
	return 0;
}

# OK: $type $mode $lmode $uid $gid $size $atime $mtime $ctime $makeholes $ino $cf_nlink
sub stat_file {
	my ($self,$file) = @_;

	my $time = time();

	print qq!\tcfengine: send("SYNCH $time STAT $file")\n! if $debug > 2;
	my $sock = $self->send("SYNCH $time STAT $file");

	my @buf = ();
	if ($version == 1.4) {
		while(<$sock>) {
			print "\tcfengine: stat_file: $_" if $debug > 2;
			chomp;
			push @buf, (split /\s+/);
		}
	}

	my $return = shift @buf;

	return 1 if $return =~ /OK/;
	return 0 if $return =~ /BAD/;
	
	#pop @buf;
	#return \@buf;
}

sub send {
	my ($self,$data) = @_;

	# 1.4 client problem.
	if ($self->{'reconnect'}) {
		$self->connect();
		$self->auth();
	}

	my $sock = $self->{'sock'};
	
	# lame cfengine protocol - pad the string we send.
	print $sock $data . "\0" x (4096 - (length $data));

	$self->{'reconnect'} = 1 if $version == 1.4;
	return $sock;
}

# These are higher level functions.

sub getFile {
	my ($self, $remoteFile,$localFile) = @_;

	print "\tcfengine: stating [$remoteFile] on cfd server.\n" if $debug;
	unless ($self->stat_file($remoteFile)) {
		print "Couldn't stat package: [$remoteFile] on cfd server.\n";
		return;
	}

	print "\tcfengine: Getting [$remoteFile] from cfd server.\n" if $debug;
	$self->get_file($remoteFile, $localFile);

	print "\tcfengine: Checking MD5 for [$remoteFile] on cfd server.\n" if $debug;
	unless ($self->md5_file($remoteFile, $localFile)) {
		print "\tcfengine: MD5 for [$remoteFile] != [$localFile] on cfd server.\n";
		return;
	}

	return 1;
}

1;

__END__
