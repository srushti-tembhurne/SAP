package ariba::Ops::VaultAccess;

# This module is used to access Vault secrets

use strict;
use warnings;

use ariba::Ops::Constants;
use IO::Socket::INET;
use LWP::UserAgent;
use HTTP::Request::Common;
use HTTP::Headers;
use File::Slurp;
use JSON;

my $vers = "2.0";

sub new {
    my ($class, $options) = @_;

    my $self = {};
    bless ($self, $class);

    $self->{debug} = 0;
    $self->{vaultProtocol} = "https";
    $self->{vaultPort} = 8200;
    $self->{connectTimeoutSecs} = 10;

    if ($options) {
        for my $k (keys %$options) {
            my $val = $options->{$k};
            $self->{$k} = $val if (defined $val); # defend against undef overrides
        }
    }

    return $self;
}

# Input: ref to hash of options to override the default settings
# Return: ref to instance of this class to invoke for subsequent read access if vault connection could be established, else undef
sub connect {
    my ($options) = @_;

    my $token = _fetchToken();
    unless ($token) {
        return undef;
    }

    my $va = ariba::Ops::VaultAccess->new($options);
    my $vaultServers = ariba::Ops::Constants->cobaltVaultServers();
    my @vaultServerList = split / /, $vaultServers;
    for my $s (@vaultServerList) {
        $va->{ua} = _serverConnect($va->{vaultProtocol}, $s, $va->{vaultPort}, $va->{connectTimeoutSecs});
        if ($va->{ua}) {
            $va->{vaultServer} = $s;
            return $va;
        }
    }
    return undef;
}

# deprecated - use connect instead
# Input: ref to hash of options to override the default settings
# Return: ref to instance of this class to invoke for subsequent read access
sub connectLocalhost {
    my ($options) = @_;

    return ariba::Ops::VaultAccess::connect($options);
}

# Return string vault token if the environment supports TLS handshaking with vault and there is a vault env variable or token file in scope, else undef
sub _fetchToken {
    if ( $^V lt 'v5.22.1' ) {
        return undef;
    }

    my $token = $ENV{'VAULT_TOKEN'};
    unless ($token) {
        my $file = "$ENV{HOME}/.vault-token";
        $token = read_file($file) if (-f $file);
    }
    return $token;
}

# Input arg: key can be / or . delimited, but . will get translated to /
# It must be the case that the secret value be a k/v tuple like "value":"bar"
# Return secret or undef if a problem or Perl is too ancient to speak TLS1.2
sub readSecret {
    my ($self, $key) = @_;

    my $token = _fetchToken();
    unless ($token) {
        return undef;
    }

    my $h = HTTP::Headers->new;
    $h->header('X-Vault-Token' => $token);

    $key =~ tr/./\//;

    my $url = $self->{vaultProtocol} . "://" . $self->{vaultServer} . ":" . $self->{vaultPort} . "/v1/secret/" . $key;
    my $req = HTTP::Request->new(GET => $url, $h);
    my $resp = $self->{ua}->request($req);

    unless ($resp->is_success) {
        return undef;
    }
    my $json = $resp->content;

    my $cfg = eval { return JSON::decode_json($json) };
    if ($@) {
        return undef;
    }
    my $val = $cfg->{data}->{value};

    return $val;
}

# Return the UserAgent if the vault connection was established; undef otherwise
sub _serverConnect {
    my ($protocol, $serverName, $port, $connectTimeoutSecs) = @_;

    unless (_canResolveServer($serverName, $port, $connectTimeoutSecs)) {
        return undef;
    }

    my $timeoutHeader = "Connection timed out\n";
    my $userAgent = eval {
        local $SIG{ALRM} = sub { die $timeoutHeader; };
        alarm $connectTimeoutSecs;
        my $ua;

        if ($protocol eq "https") {
            $ua = LWP::UserAgent->new(ssl_opts => { verify_hostname => 0, SSL_verify_mode => 'SSL_VERIFY_NONE' });
        } else {
            $ua = LWP::UserAgent->new();
        }
        return $ua;
    };
    alarm 0;

    my $exception = $@;
    if ($exception) {
        return undef;
    }
    return $userAgent;
}

# Return 1 if can connect; 0 otherwise
sub _canResolveServer {
    my ($serverName, $port, $connectTimeoutSecs) = @_;

    my $timeoutHeader = "Socket creation timed out\n";
    my $socket = eval {
        local $SIG{ALRM} = sub { die $timeoutHeader; };
        alarm $connectTimeoutSecs;
        my $s = new IO::Socket::INET (
            PeerHost => $serverName,
            PeerPort => $port,
            Proto => 'tcp'
        );
        return $s;
    };
    alarm 0;

    my $exception = $@;
    if ($exception) {
        return 0; # Can't connect
    }
    if ($socket) {
        $socket->close();
        return 1;
    }
    return 0;
}

sub _logError {
    my ($msg) = @_;

    print STDERR "$msg\n";
}

1;
