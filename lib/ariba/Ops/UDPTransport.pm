package ariba::Ops::UDPTransport;

use IO::Socket;
use ariba::Ops::Utils;

my $serverDefaultPort = 61504;
my $multicastAddr = "239.253.10.20";

my $maxMessageSize = 32000;  # use UDPTransport->maxMessageSize() to access
my $ACK = 'ack';


sub new {
	my $class = shift;

	my $self = { };
	bless($self, $class);

	return $self;
}

sub setDebug {
	my $self = shift;
	my $debug = shift;

	$self->{'debug'} = $debug;
}

sub debug {
	my $self = shift;

	return $self->{'debug'};
}

sub maxMessageSize {
	my $class = shift;

	return $maxMessageSize;
}

sub initAsClient {
	my $self = shift;
	my $serverHost = shift;
	my $serverPort = shift || $serverDefaultPort;

	print "DEBUG: initAsClient(serverHost = $serverHost, serverPort = $serverPort)\n" if $self->debug();

	my $proto = getprotobyname('udp');
	socket(*clientSocket, PF_INET, SOCK_DGRAM, $proto);	

	my $serverAddr = gethostbyname($serverHost);
	my $sin = sockaddr_in($serverPort, $serverAddr);

	$self->{'clientSocket'} = \*clientSocket;
	$self->{'server'} = $sin;

	$self->{'serverHost'} = $serverHost;
	$self->{'serverPort'} = $serverPort;

	return $self;
}

sub initAsServer {
	my $self = shift;
	my $serverPort = shift || $serverDefaultPort;
	
	my $proto = getprotobyname('udp');
	socket(*serverSocket, PF_INET, SOCK_DGRAM, $proto);	

	my $sin = sockaddr_in($serverPort, INADDR_ANY);

	bind(*serverSocket, $sin);

	$self->{'serverSocket'} = \*serverSocket;

	$self->{'serverHost'} = "localhost";
	$self->{'serverPort'} = $serverPort;

	return $self;	
}

sub serverSocket {
	my $self = shift;
	return $self->{'serverSocket'};
}

sub clientSocket {
	my $self = shift;
	return $self->{'clientSocket'};
}

sub server {
	my $self = shift;
	return $self->{'server'};
}


sub sendMessageToServer {
	my $self = shift;
	my $message = shift;

	my $try = 0;

	resend: while( $try++ <= 3 ) {

		my $clientSocket = $self->clientSocket();
		my $server = $self->server();

		print "DEBUG: clientSocket = $clientSocket\n" if $self->debug();

		send($clientSocket, $message, 0, $server);

		print "DEBUG: send message, waiting for transport ack\n" if $self->debug();

		my $codeRef = sub { 
			recv($clientSocket, $reply, $maxMessageSize, 0);
		};


		# try sending message a few times
		
		unless(ariba::Ops::Utils::runWithTimeout(6, $codeRef)) {
			#time out
			print "DEBUG: timed out getting ack from server\n" if $self->debug();
			next resend;
		}

		unless ($reply && $reply eq $ACK) {
			$reply = 'undef' unless defined($reply);
			print "DEBUG: received '$reply' instead of '$ACK'\n" if $self->debug();
			next resend;
		}

		print "DEBUG: got transport ack: $reply\n" if $self->debug();
		return 1;
	}

	print "DEBUG: failed to get transport ack from server, message not delivered\n" if $self->debug();
	return undef;
}

sub receiveMessageFromClient {
	my $self = shift;
	my $timeout = shift || "60";

	my $message;

	my $serverSocket = $self->serverSocket();

	my $sin;

	my $codeRef = sub { 
		$sin = recv($serverSocket, $message, $maxMessageSize, 0);
	};

	unless(ariba::Ops::Utils::runWithTimeout($timeout, $codeRef)) {
		#time out
		print "DEBUG: receiveMessageFromClient is idle\n" if $self->debug();
		return (undef, undef, undef);
	}

	my ($clientPort, $clientAddrN) = unpack_sockaddr_in($sin);

	send($serverSocket, $ACK, 0, $sin);

	my $clientAddr = inet_ntoa($clientAddrN);

	return ($clientAddr, $clientPort, $message);
}


1;
