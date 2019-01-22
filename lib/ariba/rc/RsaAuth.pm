package ariba::rc::RsaAuth;

use strict;
use warnings;

use LWP::UserAgent;
use Data::Dumper;
use FindBin;

my $vers = "1.0";

# turn off output buffering
$|=1;

# Configure this RsaAuth object
#   This object is used to connect to safeguard (cerberus) webserver cgi to authenticate RSA user.
sub new {
    my $class = shift;
    my $options = shift;
    
    my $self = {};
    bless ($self, $class);
    
    # Defaults
    $self->{'host'} = 'cerberus';
    $self->{'domain'} = 'lab1.ariba.com';
    $self->{'script'} = '/cgi-bin/rsaauth.cgi';
    $self->{'url'} = 'https://' . $self->{'host'} . '.' . $self->{'domain'} .
                     $self->{script};
    $self->{'timeout'} = 10;
    $self->{'verify_hostname'} = 0;
    $self->{'debug'} = 0;
    
    if ($options) {
        for my $k (keys %$options) {
            my $val = $options->{$k};
            $self->{$k} = $val if (defined $val); # defend against undef overrides
        }
    }

    return $self;
}

# authenticate - authenticate via HTTPS cgi, return 1 for authenticated, 0 for not authenticated
sub authenticate {
    my $self  = shift;
    my $args = shift; 
    
    my $username = $args->{'username'} || '';
    my $token    = $args->{'token'} || '';

    return 0 unless ($username && $token);
  
    # setup user agent 
    my $ua = LWP::UserAgent->new();
    $ua->timeout($self->{'timeout'});
    $ua->ssl_opts( verify_hostname => $self->{'verify_hostname'} );
    
    # post to the url
    my $response = $ua->post( $self->{'url'} , { 'username' => $username, 'token' => $token } );

    if ($response->is_success) {
        my $content  = $response->decoded_content();
        print "success=$content\n" if $args->{'debug'};
        # return 0 or 1
        return $content;
    }
    else {
        my $msg = $response->status_line;
        print "\nfailure=$msg\n" if $args->{'debug'};
        # no response, return auth failure
        return 0;
    }
}

1;
