#
# A Library to handle SSLCert check
#
# $Id: //ariba/services/tools/lib/perl/ariba/Ops/SSLCert.pm#4 $
#

package ariba::Ops::SSLCert;

use strict;
use vars qw(@ISA);
use ariba::Ops::TTLPersistantObject;

@ISA = qw(ariba::Ops::TTLPersistantObject);

use Date::Parse;
use IO::Socket;
use Net::SSLeay;
use ariba::rc::Utils;
use ariba::Ops::Utils;
use File::Basename;

my $aDay  = 60 * 60 * 24;
my $retry = 5;
my $debug = 0;
my $initialized = 0;

my %invalidHosts = ();

sub initializeNetSSLeay {
	my $class = shift;

	unless ($initialized) {
		Net::SSLeay::load_error_strings();
		Net::SSLeay::SSLeay_add_ssl_algorithms();
		$initialized++;
	}
}

sub dir {
	my $class = shift;

	return "/tmp/ssl-cert-check-cache";
}

# never write out the clientcertkey password
sub save {
	my $self = shift;
	
	my $password = $self->clientCertKeyPassword();
	$self->setClientCertKeyPassword("<skipped for security reasons>") if ($password);
	$self->SUPER::save();
	$self->setClientCertKeyPassword($password) if ($password);
}

sub recursiveSave {
	my $self = shift;
	
	my $password = $self->clientCertKeyPassword();
	$self->setClientCertKeyPassword("<skipped for security reasons>") if ($password);
	$self->SUPER::recursiveSave();
	$self->setClientCertKeyPassword($password) if ($password);
}

sub ttl {
	my $class = shift;

	return (6 * 60 * 60); # 6 hours
}

sub newWithHostAndPort {
	my $class = shift;
	my $host  = shift || return undef;
	my $port  = shift || 443;

	my $instanceName = "sslcert-$host-$port";

	# TTLObject can return undef if the object is expired.
	my $self = $class->SUPER::new($instanceName) || $class->SUPER::new($instanceName);

	unless ($self->host()) {
		$self->setHost($host);
		$self->setPort($port);
	}

	return $self;
}

sub validUntil {
	my $self = shift;

	my $validUntil = $self->validUntilTime();

	unless ($validUntil) {
		$validUntil = $self->connectAndCheckCertificate();
	}

	return $validUntil;
}

# return client cert (PEM) file location
sub clientCertFile {
	my $self = shift;

	$self->_clientPkcs12ToPem();
	return $self->SUPER::clientCertFile();
}

# return client Key (PEM) file location
sub clientCertKeyFile {
	my $self = shift;

	$self->_clientPkcs12ToPem();
	return $self->SUPER::clientCertKeyFile();
}

sub _clientPkcs12ToPem {
	my $self = shift;

	my $pkcs12CertFile = $self->clientCertPkcs12File();

	return unless $pkcs12CertFile;

	#
	# if we are trying to load this, but have the password as loaded from disk,
	# as "< skipped for security reasons >", as happens when we expire and
	# call _destroy(), then this code will not work (and we prolly don't
	# care anyway), so just return to avoid the spew that accompanies not
	# working, and ends up in cron emails.
	#
	return if($self->clientCertKeyPassword() =~ /skipped for security reasons/);

	my $certFile    = $self->SUPER::clientCertFile();
	my $certKeyFile = $self->SUPER::clientCertKeyFile();

	my $pemDir = "/tmp";

	my $pemCertFile = "$pemDir/" . basename($pkcs12CertFile);
	my $pemCertKeyFile = "$pemDir/" . basename($pkcs12CertFile);
	$pemCertFile =~ s/p12$/cert/;
	$pemCertKeyFile =~ s/p12$/key/;

	my $result;
	for my $cmdSuffix ("$pemCertFile -nokeys -clcerts", "$pemCertKeyFile -nocerts") {
		my $cmd = "openssl pkcs12 -in $pkcs12CertFile -passin stdin -passout stdin -nomacver -out $cmdSuffix";

		open(CMD, "|$cmd");
		my $password = $self->clientCertKeyPassword();
		print CMD $password, "\n";
		print CMD $password, "\n";
		unless (close CMD) {
			my $errorMsg = ($! ?  "Error closing $cmd pipe: $!" : "Error: $cmd returned $?");
			$self->setErrors($errorMsg);
			last;
		}
	}

	unless ($self->errors()) {
		$self->SUPER::setClientCertFile($pemCertFile);
		$self->SUPER::setClientCertKeyFile($pemCertKeyFile);
		$self->setShouldPurgeTempCertFiles(1);
	}
}

sub validForDays {
	my $self = shift;

	# Don't continue to try this host more than once if it's unavailable.
	if ($invalidHosts{$self->instance()}) {
		return;
	}

	my $time = time();
	my $validUntil = $self->validUntil();

	my $daysToExpire;
	if ($validUntil) {
		$daysToExpire = int(($validUntil - $time)/ $aDay) || 0;
	}

	return $daysToExpire;
}

sub connectAndCheckCertificate {
	my $self = shift;

	my $host = $self->host();
	my $port = $self->port();

	return undef unless($host);

	my $class = ref($self);

	$class->initializeNetSSLeay();

	my $validUntil = 0;

	# start the timeout loop
	my $rt = ariba::Ops::Utils::runWithTimeout($self->timeout() || 30, sub {

		for (my $i = 0; $i < $retry; $i++) {

			print "Try $i for $host\n" if $debug;

			my $s = IO::Socket::INET->new(
				PeerAddr => $host,
				PeerPort => $port,
				Proto    => 'tcp',
			);

			# TMID: 11644 - IO::Socket::INET::_error() set $@ in
			# case of error, but doesn't actually die/croak. So
			# set $@ to nothing for runWithTimeout to be happy.
			if (!$s || $@) {

				warn "DEBUG: Couldn't connect to [$host:$port] - [$!] \$\@: [$@]\n" if $debug;

				# Don't check again if we're in the DB
				# multiple times.
				$invalidHosts{$self->instance()} = 1;

				# Allow the caller to get this.
				$self->setErrors($!);

				$@ = '';
				last;
			}

			# The network connection is now open, lets fire up SSL    
			my $ctx = Net::SSLeay::CTX_new() or next;

			if (defined $self->clientCertFile()) {
				Net::SSLeay::CTX_set_default_passwd_cb($ctx, sub { return $self->clientCertKeyPassword() }) 
					if (defined $self->clientCertKeyPassword());
				Net::SSLeay::set_cert_and_key($ctx, $self->clientCertFile(), $self->clientCertKeyFile());
				Net::SSLeay::CTX_set_default_passwd_cb($ctx, undef) 
					if (defined $self->clientCertKeyPassword());
			}

			my $ssl = Net::SSLeay::new($ctx) or next;

			Net::SSLeay::set_fd($ssl, fileno($s));
			my $res = Net::SSLeay::connect($ssl) or do {
				warn "Couldn't upgrade connection to SSL!: $!\n" if $debug;
				next;
			};

			# grab the certificate, parse out the 'not after' date
			my $cert     = Net::SSLeay::get_peer_certificate($ssl) or next;
			my $notafter = Net::SSLeay::X509_get_notAfter($cert) or next;
			my $expire   = Net::SSLeay::P_ASN1_UTCTIME_put2string($notafter) or next;

			# Tear down connection
			Net::SSLeay::free($ssl);
			Net::SSLeay::CTX_free($ctx);
			$s->close();

			$validUntil = str2time($expire);

			last if $validUntil;
		}
	});

	if ($rt && $validUntil) {
		$self->setValidUntilTime($validUntil);
		$self->setErrors('');
		$self->save();
		return $validUntil;
	}

	return undef;
}

sub _destroy {
	my $self = shift;

	if ($self->shouldPurgeTempCertFiles()) {
		# purge any clientCert temp files
		my $file;
		for $file ($self->clientCertFile(), $self->clientCertKeyFile()) {
			unlink($file) if -e $file;
		}
	}

	$self->SUPER::_destroy();
}

1;
