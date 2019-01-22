package ariba::monitor::OpsSWAuth;

use ariba::Ops::InstanceTTLPersistantObject;
use base qw(ariba::Ops::InstanceTTLPersistantObject);

=pod

=head1 NAME

ariba::monitor::OpsSWAuth

=head1 VERSION

 $Id: //ariba/services/monitor/lib/ariba/monitor/OpsSWAuth.pm#2 $
 Last modified by: $Author: jarek $
 Last modified on: $Date: 2007/08/30 $

=head1 SYNOPSIS

 use ariba::monitor::OpsSWAuth;

 my $result = ariba::monitor::OpsSWAuth::authenticateUsernameAndPassword(
	 $username,
	 $password
 );

 if ($result) {
	 print "Safeword auth was successful.\n";
 } else {
	 print "Safeword auth FAILED!\n";
 }

=head1 DESCRIPTION

ariba::monitor::OpsSWAuth is a drop-in replacement for ariba::monitor::SWAuth,
authenticating via Ops' home-brew two-factor.

Do not use this directly.  Use ariba::monitor::AuthenticationSession instead.

=head1 FUNCTIONS

=over 4

=item * authenticateUsernameAndPassword($username, $password, [$radius])

Check the received username/password for validity. 
Returns 1 if valid, undef if not. 

Creates a session on disk to track validity.

=cut

sub dir { return ariba::Ops::Constants->monitorDir() . "/_OpsSWAuth"; }

sub authenticateUsernameAndPassword {
	my $username = shift;
	my $password = shift;

	if ( __PACKAGE__->objectWithNameExists($username) ) {
		my $session = __PACKAGE__->new($username);
		if ($session->password() eq $password) {
			$session->remove();
			return 1;
		}
	}

	return undef;
}

sub generatePasswordForUser {
	my $username = shift;

	my $sw = __PACKAGE__->new($username);
	$sw->setTTL(20*60);

	my $length = hex("ffffff");
	my $num = int(rand($length));
	my $pass = sprintf("\%06lx", $num);

	$sw->setPassword($pass);
	$sw->save();

	return $pass;
}

1;
