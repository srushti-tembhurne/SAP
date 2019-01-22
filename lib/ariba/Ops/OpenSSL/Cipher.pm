package ariba::Ops::OpenSSL::Cipher;
use Moose;
use namespace::autoclean;

=head1 NAME

ariba::Ops::OpenSSL::Cipher

=head1 SYNOPSIS

 use ariba::Ops::OpenSSL::Cipher;
 my $obj = ariba::Ops::OpenSSL::Cipher->new(
	name           => $name,
	protocol       => $protocol,
	key_exchange   => $kx,
	authentication => $au,
	encryption     => $enc,
	mac_algorithm  => $mac,
 );

=head1 DESCRIPTION

Holds data for a single line of the openssl ciphers command.

=cut



=head1 ATTRIBUTES

=head2 logger | Log::Log4perl::Logger

Returns the logger object.

=head2 name | Str

Returns the cipher name. This is a required constructor parameter.

=head2 protocol | Str

Returns the protocol. This is a required constructor parameter.

=head2 key_exchange | Str

Returns the key_exchange. This is a required constructor parameter.

=head2 authentication | Str

Returns the authentication. This is a required constructor parameter.

=head2 encryption | Str

Returns the encryption. This is a required constructor parameter.

=head2 mac_algorithm | Str

Returns the mac_algorithm. This is a required constructor parameter.

=head2 key_size | Int

Returns the key_size.

=head2 encryption_size | Int

Returns the encryption_size.

=head2 export | Bool

Returns TRUE when export is present.
Otherwise returns FALSE.

=cut

has logger          => ( is => 'ro', isa => 'Log::Log4perl::Logger', lazy => 1, builder => '_build_logger' );
has name            => ( is => 'ro', isa => 'Str', required => 1 );
has protocol        => ( is => 'ro', isa => 'Str', required => 1 );
has key_exchange    => ( is => 'ro', isa => 'Str', required => 1 );
has authentication  => ( is => 'ro', isa => 'Str', required => 1 );
has encryption      => ( is => 'ro', isa => 'Str', required => 1 );
has mac_algorithm   => ( is => 'ro', isa => 'Str', required => 1 );
has key_size        => ( is => 'ro', isa => 'Int' );
has encryption_size => ( is => 'ro', isa => 'Int' );
has export          => ( is => 'ro', isa => 'Bool', default => 0 );



__PACKAGE__->meta->make_immutable;

1;


__END__

=head1 AUTHOR

Written by David Laulusa.

=head1 COPYRIGHT

Copyright (c), SAP AG, 2015

=cut
