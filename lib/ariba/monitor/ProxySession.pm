package ariba::monitor::ProxySession;

# $Id: //ariba/services/monitor/lib/ariba/monitor/ProxySession.pm#4 $

use strict;
use CGI;
use ariba::Ops::Constants;
use ariba::Ops::Utils;
use ariba::monitor::ProxySessionProfile;
use ariba::monitor::OpsSWAuth;
use ariba::monitor::AuthenticationSession;

use base qw(ariba::monitor::AuthenticationSession);

INIT {
	__PACKAGE__->setAuthenticationModule("ariba::monitor::OpsSWAuth");
};

my $COOKIENAME = 'proxySession';
my $COOKIEPOSTFIX = '';

# class methods
#sub newFromCookie {
# replaced with check($cgi)

sub createSessionForName {
	my $class = shift;
	my $name = shift;

	my $self = undef;
	my $userObject = ariba::monitor::ProxySessionProfile->new($name);

	if ($userObject && $userObject->username()) {

		$self = $class->SUPER::createUnauthedSession($name);

		$self->setUserProfile($userObject);
		$self->setCount(1);
		$self->save();

	}

	return $self;
}

sub authenticate {
	my $self = shift;
	my $password = shift;

	my $class = ref($self);
	my $username = $self->userProfile()->username();

	my $isAuth = $class->SUPER::authenticate($username, $password);
	if ($isAuth) {
		$self->setIsAuthenticated(1);
		$self->save;
	}

	return $isAuth;
}


sub objectLoadMap {
	my $class = shift;

	my %map = (
			'userProfile', 'ariba::monitor::ProxySessionProfile',
	);

	return \%map;
}

sub dir { return ariba::Ops::Constants->monitorDir() . "/_proxySessions"; }

sub setCookiePostfix { my $class = shift; $COOKIEPOSTFIX = shift || ""; }
sub cookieName { return $COOKIENAME . $COOKIEPOSTFIX; }

sub sendPassword {
	my $self = shift;

	my $username = $self->userProfile()->username();
	my $to = $self->userProfile()->passwordAddress();

	my $from = ariba::Ops::Constants->nullReplyTo();
	my $subject = "Ariba Inspector Proxy password";
	my $body = ariba::monitor::OpsSWAuth::generatePasswordForUser($username);

	eval {
		ariba::Ops::Utils::email($to, $subject, $body, undef, $from);
	};

	if ($@) {
		warn "sendPassword: could not send pass to $to: $@";
		return "System Error: Failed to send password.  Please try again.  If this problem persists, please
			contact ask_ops\@ariba.com.";
	} 

	return 0;
}

1;
