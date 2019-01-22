package ariba::monitor::AuthenticationSession;

# $Id: //ariba/services/monitor/lib/ariba/monitor/AuthenticationSession.pm#13 $

use strict;
use CGI;
use ariba::Ops::Machine;
use ariba::Ops::NetworkUtils;
use ariba::Ops::DatacenterController;

use base qw(ariba::Ops::InstanceTTLPersistantObject);

# use SWAuth auth module by default
INIT {
	__PACKAGE__->setAuthenticationModule("ariba::monitor::SWAuth");
};

my $backingStoreDir = ariba::Ops::Constants->monitorDir() . "/_sessions";
my $COOKIENAME = 'session';
my $TTL = 20 * 60;
my $authenticationModule;

=pod

=head1 NAME

ariba::monitor::AuthenticationSession - Two-factor authentication

=head1 SYNOPSIS FOR COMMANDLINE & "SUB" CGI PROGRAMS

 #
 # Use this for command line programs, or for cgi
 # programs that do not display a log in form
 #

 use ariba::monitor::AuthenticationSession;

 if ( my $auth = ariba::monitor::AuthenticationSession->check() ) {
 	print "You are authenticated as ", $auth->username(), "\n";

 	my @others = $auth->otherUsers();
 	print join(", ", @others), " are also on.\n" if @others;
 } else {
 	print "You are not authenticated\n";
 }

=head1 SYNOPSIS FOR "MAIN" CGI UI PROGRAMS

 #
 # Use this for the main CGI program that will display the log in form
 #

 use ariba::monitor::AuthenticationSession;

 my $cgi = CGI->new();

 my $auth = ariba::monitor::AuthenticationSession->check($cgi);

 if ( !$auth && $username && $password )  {
 	$auth = ariba::monitor::AuthenticationSession->createSession($username, $password);
 }

 if ( $auth && $auth->isAuthenticated() ) {
 	$username = $auth->username();
 }

 push(@header, "Status: 200\n");
 push(@header, "Content-Type: text/html\n");
 push(@header, $auth->uiAuthenticationCookie() ) if $auth;
 push(@header, "\n");
        

=head1 DESCRIPTION


Text goes here.



=head1 PUBLIC CLASS METHODS

=over 4

=item * check([$cgi])

Checks if if you are authenticated.  UI programs can optionally pass in
a CGI instance if they have one.   Returns a session instance if there is one.

=cut

# class methods

sub check {
	my $class = shift;
	my $cgi = shift;

	my $session = $class->checkNoAuth();
	return $session if ($session && $session->isAuthenticated());
	return undef;
}

sub checkNoAuth {
	my $class = shift;
	my $cgi = shift;

	#
	# we'd like to use $cgi->https() or $cgi->http() here, but
	# it complains with errors like
	#
	# Use of uninitialized value in pattern match (m//) at (eval 63) line 3.
	# Use of uninitialized value in transliteration (tr///) at (eval 63) line 4.
	#
	# Use the force instead.
	#

	if ( $ENV{'REQUEST_METHOD'} ) {
		$cgi = CGI->new() unless ( $cgi );
		return $class->_validateHTTPAuthentication($cgi);
	} else {
		return $class->_validateCommandlineAuthentication();
	}
}

sub dir {
	my $class = shift;

	return $backingStoreDir;
}

=item * createSession($user, $password)

Create a new session.

=cut

sub createSession {
	my $class = shift;
	my $user = shift;
	my $password = shift;
	my $forcedInstanceName = shift;

	if ( $class->authenticate($user, $password) ) {
		my $self = $class->createUnauthedSession($user, $forcedInstanceName);
		$self->setUsername($user);
		$self->setIsAuthenticated(1);
		$self->save();

		return $self;
	}

	return undef;

}

sub createUnauthedSession {
	my $class = shift;
	my $user = shift;
	my $forcedInstanceName = shift;

	my $time = time();
	my $pid  = $$;

		my $instanceName = $forcedInstanceName || rand(999) . "-" . $pid . "-" . $time;

		my $self = $class->SUPER::new($instanceName);

		$self->setCreationTime($time);
		$self->setTtl($TTL);

		$self->setClientIpAddress( $self->_sourceIpAddress() );

		# set a cookie so this session could be used online

		my $httpClient = $ENV{'HTTP_X_FORWARDED_HOST'} || $ENV{'SERVER_NAME'};

		if ( $httpClient ) {
			my $domain = ariba::Ops::NetworkUtils::domainForHost($httpClient);

			my $cookie = CGI::cookie(-name=>$class->cookieName(),
							-value=>$instanceName,
							-domain=>$domain,
							-expires=>'+8h',
							-secure=>1);
			$self->setCookie($cookie);
		}

		return $self;
}

sub _sourceIpAddress {
	my $self = shift;

	my $sourceIpAddr = $ENV{'HTTP_X_FORWARDED_FOR'} || 
				$ENV{'REMOTE_ADDR'} || 
				ariba::Ops::Machine->new()->ipAddr();
	
	return $sourceIpAddr;
}

=item * users()

Current authenticated users.

=cut

sub users {
	my $class = shift;

	return $class->_users();
}

sub _findAndRefreshSession {
	my $class = shift;
	my $sessionInstance = shift;
	
	if ( $class->objectWithNameExists($sessionInstance) ) {
		my $session = $class->new($sessionInstance);

		# don't return a session that was created from a different IP

		# Instance TTL Persistant Objects can return undef from a call to new()
		# if the object has expired, so watch for that.
		if($session) {
			my $source = $session->_sourceIpAddress();
			my $recordedSource = $session->clientIpAddress();
			$session = undef unless ($source eq $recordedSource);
		}

		# this is just to double-check the expire logic
		if (defined($session) && $session->isAuthenticated()) {
			# extend our session by $TTL
			$session->setCreationTime(time());
			$session->save();
		}
		return $session;
	} 
	# there's no session for the given instance

	return undef;
}

sub cookieName { return $COOKIENAME; }

sub _validateHTTPAuthentication {
	my $class = shift;
	my $cgi = shift;

	my $cname = $class->cookieName();
	my $sessionInstance = $cgi->cookie($class->cookieName());

	# use the cookie to possibly find our session
	return $class->_findAndRefreshSession($sessionInstance);
}

sub _validateCommandlineAuthentication {
	my $class = shift;

	# hack, for now!  use things we can get from our
	# "env", since we can't set a cookie
	# there's no ttyname() in perl
	my $ttyname = `tty`;
	chop($ttyname);
	$ttyname =~ s|/dev/||;
	$ttyname =~ s|/||g;

	my $sessionInstance	 = getppid() . "-" . $ttyname;

	my $session = $class->_findAndRefreshSession($sessionInstance);

	if ( $session ) {
		return $session;
	} else {
		my ($username, $password) = ariba::monitor::AuthenticationSession->_loginPrompt();
		return ariba::monitor::AuthenticationSession->createSession($username, $password, $sessionInstance);
	}
}

sub _loginPrompt {
	my $class = shift;

	my $username;
	my $password;

	print "Username: ";
	chop($username = <STDIN>);

	print "Two-factor password: ";
	system("stty -echo");
	chop($password = <STDIN>);
	system("stty echo");
	print "\n";

	return ($username, $password);
}

sub authenticate {
	my $class = shift;
	my $username = shift;
	my $password = shift;

	my $isAuth = 0;
	my $authMod = $class->authenticationModule();

	$password = quotemeta($password);
	
	if ($username && $password && $authMod && 
		eval($authMod."::authenticateUsernameAndPassword(\"$username\", \"$password\")")) {
		$isAuth = 1;
	}

	# hack for development because we don't always have Radius servers to talk to
	if (
		ariba::Ops::DatacenterController::isDevlabDatacenters(ariba::Ops::Machine->new()->datacenter()) ||
		ariba::Ops::Machine->new()->datacenter() eq "beta"   ||
		ariba::Ops::Machine->new()->datacenter() eq "demo"   ||
		ariba::Ops::Machine->new()->datacenter() eq "sales" 
	) {
		$isAuth = 1;
	}

	return $isAuth;
}


=pod

=head1 PUBLIC INSTANCE METHODS

=cut


=item * uiAuthenticationCookie()

Call this method in your UI programs to get the
session cookie in proper HTTP Set-Cookie form.

=cut

sub uiAuthenticationCookie {
	my $self = shift;

	if ( $self->isAuthenticated() && $self->cookie() ) {
		my $cookie = $self->cookie() || '';

		return "Set-Cookie: $cookie\n";
	}

	return undef;
}

=item * otherUsers()

Other users besides the current session that are authenticated.

=cut

sub otherUsers {
	my $self = shift;

	my $class = ref($self);
	return $class->_users($self->username());
}

sub _users {
	my $class = shift;
	my $usernameToSkip = shift;

	my @sessions = ariba::monitor::AuthenticationSession->listObjects();

	my %users;

	for my $session ( @sessions ) {
		my $user = $session->username();

		next if ($usernameToSkip && $user eq $usernameToSkip);
		$users{$user} = $session->creationTime();
	}

	return sort keys %users;
}

=item * isAuthenticated()

Returns true if the current session is authenticated.

=cut

sub isAuthenticated {
	my $self = shift;

	my $source = $self->_sourceIpAddress();
	my $recordedSource = $self->clientIpAddress();

	my $isAuth = $self->attribute('isAuthenticated');

	return ($isAuth && $source eq $recordedSource);
}

sub setAuthenticationModule {
	my $class = shift;
	my $module = shift;

	eval "use $module";
	if ($@) {
		return 0 
	}

	$authenticationModule = $module;
	return 1;
}

sub authenticationModule { return $authenticationModule; }

1;
