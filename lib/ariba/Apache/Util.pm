package ariba::Apache::Util;

# $Id: //ariba/services/tools/lib/perl/ariba/Apache/Util.pm#3 $

use strict;
use Apache2;
use Apache::Const -compile => ':common';
use Apache::Cookie;
use Apache::Request;
use Apache::RequestRec;
use Apache::SessionManager;

sub redirect {
	my ($class,$value) = @_;

	my $apr = $class->getRequest();

	$apr->headers_out()->set('Location' => $value);
	$apr->status(Apache::HTTP_MOVED_TEMPORARILY());

	return Apache::HTTP_MOVED_TEMPORARILY();
}

sub getRequest {
	my $class = shift;

	return Apache::Request->new( Apache->request() );
}

sub getSession {
	my $class = shift;

	return Apache::SessionManager::get_session( $class->getRequest() );
}

sub setSession {
	my ($class,$value) = @_;
	my $session = Apache::SessionManager::get_session( $class->getRequest() );

	while (my ($key,$value) = each %$value) {
		$session->{$key} = $value;
	}
}

sub removeSession {
	my $class = shift;

	Apache::SessionManager::destroy_session( $class->getRequest() );
}

sub getCookie {
	my $class = shift;

	return Apache::Cookie->new( $class->getRequest() )->parse();
}

sub setCookie {
	my $class   = shift;
	my $name    = shift || 'session';
	my $value   = shift;
	my $path    = shift || '/';
	my $domain  = shift || 'ariba.com';
	my $expires = shift || '+3M';

	my $cookie = Apache::Cookie->new(
		$class->getRequest(),
		-name	=> $name,
		-value	=> $value,
		-path	=> $path,
		-domain => $domain,
		-expires=> $expires,
	);

	$cookie->bake();

	return 1;
}

1;

__END__
