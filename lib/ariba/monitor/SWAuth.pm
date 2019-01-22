package ariba::monitor::SWAuth;

use Authen::Radius;
use ariba::Ops::Machine;
use ariba::Ops::NetworkUtils;
use ariba::Ops::DatacenterController;

=pod

=head1 NAME

ariba::monitor::SWAuth

=head1 VERSION

 $Id: //ariba/services/monitor/lib/ariba/monitor/SWAuth.pm#8 $

=head1 SYNOPSIS

 use ariba::monitor::SWAuth;

 my $result = ariba::monitor::SWAuth::authenticateUsernameAndPassword(
            $username,
            $password
 );

 if ($result) {
            print "RSA auth was successful.\n";
 } else {
            print "RSA auth FAILED!\n";
 }

=head1 DESCRIPTION

ariba::monitor::SWAuth is a simple library for connecting to an RSA 
RADIUS server and validating a received username/password.

Do not use this directly.  Use ariba::monitor::AuthenticationSession instead.

=head1 FUNCTIONS

=over 4

=item * create_radius_object

Create RADIUS object used to connect to SAP RSA appliance

=cut

sub create_radius_object {

    # get primary node
    my $primary_node = '216.109.110.137:1812';

    # get node list
    my $node_list = ['216.109.110.137:1812','216.109.110.138:1812'];

    # get shared secret
    my $shared_secret = getSharedSecret();

    my $radius = new Authen::Radius(Host => $primary_node,
                               NodeList => $node_list,
                               Secret => $shared_secret,
                               TimeOut => 10 ,
                               Debug => 0);

    return $radius;
}

=pod

=item * getSharedSecret()

Get shared secret from a file that is not code revisioned

=cut

# get the shared secret from a file
sub getSharedSecret {

    # file is intentionally in a location not under cfengine control, but shared
    my $sharedSecretFile = '/home/monprod/conf/shared_secret';

    # try opening the file
    open my $SEC, '<', $sharedSecretFile or return '';

    # get the secret from the file
    my $sharedSecret = <$SEC>;

    # remove the carriage return from the input
    chomp($sharedSecret);

    # close the open file
    close $SEC;

    # return the shared secret value
    if ($sharedSecret) {
        return $sharedSecret;
    }

    # no shared secret acquired
    return '';
}

=pod

=item * authenticateUsernameAndPassword($username, $password)

Check username and password for validity via Ariba RSA appliances.
Returns 1 if valid, undef if not.

=cut

sub authenticateUsernameAndPassword {
    my ($username, $password) = @_;

    # create RADIUS object
    my $radius = create_radius_object();

    # clear RADIUS attributes
    $radius->clear_attributes;

    # set RADIUS attributes for access request
    $radius->add_attributes (
        { Name => 1, Value => $username, Type => 'string' },
        { Name => 2, Value => $password, Type => 'string' }
    );

    # send packet for access request to RSA appliance
    $radius->send_packet(ACCESS_REQUEST);

    # receive response packet from RSA appliance
    my $rcv = $radius->recv_packet();

    # check if no response from primary node
    if (!defined($rcv)) {
        # no response, retransmit to all nodes in RSA farm
        $radius->send_packet(ACCESS_REQUEST,1);
        $rcv = $radius->recv_packet();

        # check if no RSA connection after retransmitting to other RSA nodes
        if (!defined($rcv)) {
            return undef;
        }
    }

    # check response from RSA appliance
    if ($rcv == ACCESS_ACCEPT) {
        return 1;
    }
    elsif ($rcv == ACCESS_REJECT) {
        return undef;
    }
    else {
       return undef;
    }

}

1;
