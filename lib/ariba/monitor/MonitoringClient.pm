#
# $Id: //ariba/services/monitor/lib/ariba/monitor/MonitoringClient.pm#27 $

package ariba::monitor::MonitoringClient;

use strict;
use ariba::monitor::misc;
use ariba::rc::Utils;
use ariba::Ops::Utils;
use IO::Socket;
use Socket;
use Errno;

my $defaultPort = ariba::monitor::misc::querydPort();

sub new {
    my $class = shift;
    my $server = shift || die "need hostname in ${class}->new()\n";
    my $port = shift || $defaultPort;

    my $self = {
        'server' => $server,
        'port' => $port,
        'serverSocket' => undef,
    };

    bless($self, $class);

    return $self;   
}

sub server {
    my $self = shift;
    return $self->{'server'};
}

sub port {
    my $self = shift;
    return $self->{'port'};
}

sub serverSocket {
    my $self = shift;
    return $self->{'serverSocket'};
}

sub setServerSocket {
    my $self = shift;
    $self->{'serverSocket'} = shift;
}

sub error {
    my $self = shift;
    return $self->{'error'};
}

sub setError {
    my $self = shift;
    $self->{'error'} = shift;
}

sub connect {
    my $self = shift;

    my $server = $self->server();
    my $port = $self->port();

    my $socket = IO::Socket::INET->new(
        PeerAddr => $server,
        PeerPort => $port,
        Timeout  => 60
    ) || do {

        my $errno = $! + 0;

        if ($!{ENOTCONN} || $!{ECONNREFUSED} || ($^O eq 'hpux' && $errno == 22)) {
            $self->setError("connection to $server:$port is unavailable.");

            return(main::EX_UNAVAILABLE());
        } else {
            $self->setError("can't connect to $server:$port $! {errno=$errno}");
            return -1;
        }
    };
                
    $socket->autoflush(1);

    $self->setServerSocket($socket);

    # read the welcome banner
    $self->_checkResult();

    #tell queryd our name
    $self->_sendCommand("setClientName", $0);
    return $self->_checkResult();
}

sub disconnect {
    my $self = shift;

    my $server = $self->serverSocket();
    
    $self->_sendCommand("quit");
    close($server);
    $self->setServerSocket(undef);
}

sub readAppendQueryManager {
    my $self = shift;
    my $queryManager = shift;

    die "queryManager is wrong type" unless $queryManager->isa("ariba::monitor::QueryManager");

    my $server = $self->serverSocket();
    my $command = "readAppendQueryManager";
    print $server $command,"\n";

    $queryManager->saveToStream($server, 1);
    print $server ".\n";

    return $self->_checkResult();
}

sub readQueryManager {
    my $self = shift;
    my $queryManager = shift;

    die "queryManager is wrong type" unless $queryManager->isa("ariba::monitor::QueryManager");

    my $server = $self->serverSocket();
    my $command = "readQueryManager";
    print $server $command,"\n";

    $queryManager->saveToStream($server, 1);
    print $server ".\n";

    return $self->_checkResult();
}

sub notifyForStatuses {
    my $self = shift;
    my $notifyEmailAddress = shift;
    my $notifyForWarns = shift || 0;
    my $notifyForCrits = shift || 0;

    if (defined($notifyEmailAddress)) {
        $notifyEmailAddress =~ s/\s+//g;
    } else {
        $notifyEmailAddress = '';
    }


    $self->_sendCommand("notifyForStatuses", $notifyEmailAddress, $notifyForWarns, $notifyForCrits);
    return $self->_checkResult();
}

sub notifyAboutStatus {
    my $self = shift;
    my $warnEmailAddress = shift;
    my $critEmailAddress = shift;
    
    # Do not use this any more
    # use notifyForStatuses

    # short circuit no-ops

    if ( !defined($warnEmailAddress)  && !defined($critEmailAddress) ) {
        return 0;
    }

    if (defined($warnEmailAddress)) {
        $warnEmailAddress =~ s/\s+//g;
    } else {
        $warnEmailAddress = '';
    }

    if (defined($critEmailAddress)) {
        $critEmailAddress =~ s/\s+//g;
    } else {
        $critEmailAddress = '';
    }

    $self->_sendCommand("notifyAboutStatus", $warnEmailAddress, $critEmailAddress);
    return $self->_checkResult();
}

sub archiveResults {
    my $self = shift;

    $self->_sendCommand("archiveResults");
    return $self->_checkResult();
}

sub _sendCommand {
    my $self = shift;
    my @command = @_;

    my $server = $self->serverSocket();
    my $command = join(" ", @command);
    print $server $command,"\n";
}

sub _checkResult {
    my $self = shift;
    my $timeout = shift || 3600;    # 1 hour to be lax / no need for lower right now.

    local $/ = "\n"; # It needs to be \n otherwise getline would stuck waiting for more deata. Sometimes it gets changed by timeout code when running external command. TMID: 81203. 

    my $server = $self->serverSocket();

    my $result; 
    
    my $codeRef = sub { $result = $server->getline(); }; 

    unless ( ariba::Ops::Utils::runWithTimeout($timeout, $codeRef) ) {
        $self->setError("error: timed out after $timeout sec(s) while waiting for mon server to respond"); 
        return -1;
    }

    if  ( defined($result)) {
        chomp($result);
        $result =~ s|\cM||o;

        if ( $result =~ /^ok/ ) {
            return 0;
        } else {
            return $result;
        }
    }

    # create a queryd-style error message 
    $self->setError("error: got undef command result from server, did server die mid stream?");
    return -1;
}

1;
