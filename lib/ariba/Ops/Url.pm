package ariba::Ops::Url;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Url.pm#6 $

use strict;
use Time::HiRes;
use vars qw(@ISA);
use ariba::Ops::PersistantObject;
use ariba::Ops::SSLCert;

use URI;
use URI::Escape;

@ISA = qw(ariba::Ops::PersistantObject);

require "geturl";

# class methods
sub dir {
	my $class = shift;

	# don't have a backing store

	return undef;
}

sub listObjects {
	my $class = shift;

	return $class->SUPER::_listObjectsInCache();
}

# instance methods

sub save {
	return undef;
}

sub recursiveSave {
	return undef;
}

sub remove {
	return undef;
}

# cache the URI object
sub _uriObject {
	my $self = shift;

	unless (ref($self->uri()) eq 'URI') {
		$self->setUri( URI->new($self->instance()) );
	}

	return $self->uri();
}

sub isHTTPS {
	my $self = shift;

	my $uri  = $self->_uriObject();

	if (defined $uri && defined $uri->scheme() && $uri->scheme() eq 'https') {
		return 1;
	}

	return 0;
}

sub host {
	my $self = shift;

	my $uri  = $self->_uriObject();

	return $uri->host();
}

sub port {
	my $self = shift;

	my $uri  = $self->_uriObject();

	return $uri->port();
}

sub request {
	my $self = shift;

	my $timeout = shift || $self->timeout() || 15;

	my $url = shift || $self->instance();

	my @output  = ();
	my @errors  = ();
	my $finalurl;
	my $requestString;
	my $stopFollowingPatternFound;

	my @geturlArgs = ("-e","-q","-timeout",$timeout,"-results",\@output);

	if ($self->useOutOfBandErrors()) {
		push(@geturlArgs, "-errors",\@errors);
	}

	if ($self->followRedirects()) {
		push(@geturlArgs, "-followRedirects");
	}

	if ($self->useCookies()) {
		push(@geturlArgs, "-cookies");
	}

	if ($self->incHeaders()) {
		push(@geturlArgs, "-incheaders");
	}

	if ($self->printURL()) {
		push(@geturlArgs, "-printurl", \$finalurl);
	}

	if ($self->saveRequest()) {
		push(@geturlArgs, "-saveRequest", \$requestString);
	}

	if ($self->referrer()) {
		push(@geturlArgs, "-referrer", $self->referrer());
	}

	if ($self->stopFollowingOnPattern()) {
		push(@geturlArgs, "-stopFollowingOnPattern", $self->stopFollowingOnPattern(), \$stopFollowingPatternFound);
	}

	if ( defined($self->username())  && defined($self->password() ) ) {
		push(@geturlArgs, "-username", $self->username(), "-password", $self->password() );
	}

	if (defined($self->clientCertPkcs12File())) {
		my $cert = $self->sslCertificate();
		$self->setClientCertFile( $cert->clientCertFile() );
		$self->setClientCertKeyFile( $cert->clientCertKeyFile() );
	}

	push(@geturlArgs, "-clientcert", $self->clientCertFile()) if defined($self->clientCertFile());
	push(@geturlArgs, "-clientcertkey", $self->clientCertKeyFile()) if defined($self->clientCertKeyFile());
	push(@geturlArgs, "-clientcertkeypassword", $self->clientCertKeyPassword()) if defined($self->clientCertKeyPassword());

	if (defined $self->postBody()) {

		my @post        = $self->postBody();
		my $contentType = $self->contentType();

		push(@geturlArgs, "-contenttype", $contentType, "-postmemory", \@post);
	}

	foreach my $header ($self->httpHeaders()) {
		next unless($header && $header=~/^[^\s:]+:/);
		push(@geturlArgs, "-header", $header);
	}

	my $tryCount = 1;
	if ($self->tryCount()) {
		$tryCount = $self->tryCount();
	}

	my $errorString;
	my $responseTime;
	while($tryCount--) {
		$errorString = "";
		my $start = [ Time::HiRes::gettimeofday() ];
		eval 'main::geturl(@geturlArgs, $url);';
		$responseTime = Time::HiRes::tv_interval($start, [ Time::HiRes::gettimeofday() ]);

		if ($self->useOutOfBandErrors()) {
			if (scalar(@errors)) {
				$errorString = join('', @errors);
			}
		} else {
			if (defined($output[0]) && $output[0] =~ /connection refused|timed out/i) {
				$errorString = $output[0];
			}
		}
		last if $errorString eq "";
	}
	$self->setError($errorString) if $errorString ne "";
	$self->setResponseTime($responseTime);

	if ($self->printURL()) {
		$self->setFinalURL($finalurl);
	}

	if ($self->saveRequest()) {
		$self->setRequestString($requestString);
	}

	if ($stopFollowingPatternFound) {
		$self->setStopFollowingOnPatternFound(1);
	}


	if (wantarray()) {
		return @output;
	} else {
		return join("", @output);
	}
}

sub sslCertificate {
	my $self = shift;

	return unless $self->isHTTPS();

	my $host = $self->host();
	my $port = $self->port();

	return unless defined $host;
	return unless $host =~ /^\S+$/;

	my $cert = ariba::Ops::SSLCert->newWithHostAndPort($host, $port);
	$cert->setClientCertFile($self->clientCertFile()) if ($self->clientCertFile());
	$cert->setClientCertKeyFile($self->clientCertKeyFile()) if ($self->clientCertKeyFile());
	$cert->setClientCertPkcs12File($self->clientCertPkcs12File()) 
		if defined($self->clientCertPkcs12File());
	$cert->setClientCertKeyPassword($self->clientCertKeyPassword()) 
		if defined($self->clientCertKeyPassword());

	return $cert;
}

sub setupFormPost {
	my $self = shift;
	my $postDataHashRef = shift;

    my @postData = ();
    for my $param (keys %$postDataHashRef) {
        my $value = $postDataHashRef->{$param};

        push @postData, uri_escape($param) . "=" . uri_escape($value);
    }

    my $postString = (join("&", @postData));

    $self->setContentType("application/x-www-form-urlencoded");
    $self->setPostBody([$postString]);
}

1;
