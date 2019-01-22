package ariba::Ops::OpenSSL::SClient;
use Moose;
use namespace::autoclean;

extends 'ariba::Ops::OpenSSL';

=head1 NAME

ariba::Ops::OpenSSL::SClient

=head1 SYNOPSIS

 use ariba::Ops::OpenSSL::SClient;
 my $obj = ariba::Ops::OpenSSL::SClient->new;

=head1 DESCRIPTION

This class takes output the openssl s_client command and parses it.
It only uses one part of the output.
There are two versions of the openssl command and, of course,
the output is different.

=cut



my $CERTS_DIR = '/usr/local/ariba/lib/certs';

=head1 ATTRIBUTES

=head2 host | Str

The host parameter is required in the constructor.

=head2 port | Str

The port parameter is required in the constructor.

=head2 cipher | Str

The cipher. You can specify multiple -cipher options.
Defaults to all ciphers.

=head2 certs_dir | Str

The certs directory. Defaults to /usr/local/ariba/lib/certs.

=head2 sclient_cmd | Str

The openssl s_client command.

=head2 protocol | Str

The protocol. Gets populated by the openssl s_client command.

=head2 session_id | Str

The session_id. Gets populated by the openssl s_client command.

=head2 master_key | Str

The master_key. Gets populated by the openssl s_client command.

=head2 key_arg | Str

The key_arg. Gets populated by the openssl s_client command.

=head2 psk_identity | Str

The psk_identity. Gets populated by the openssl s_client command.

=head2 psk_identity_hint | Str

The psk_identity_hint. Gets populated by the openssl s_client command.

=head2 srp_username | Str

The srp_username. Gets populated by the openssl s_client command.

=head2 start_time | Str

The start_time. Gets populated by the openssl s_client command.

=head2 timeout | Str

The timeout. Gets populated by the openssl s_client command.

=head2 return_code

The return_code. Gets populated by the openssl s_client command.
0 is successful. Anything else is a failure.

=head2 accepted

If the return_code is 0, this gets set to TRUE.
Otherwise it'll get set to FALSE.

=head2 error

If there is an error in the openssl s_client command, the text gets stuffed here.

=cut

has host              => ( is => 'ro', isa => 'Str', required => 1 );
has port              => ( is => 'ro', isa => 'Int', required => 1 );
has cipher            => ( is => 'ro', isa => 'Str', required => 1 );
has certs_dir         => ( is => 'ro', isa => 'Str', default => $CERTS_DIR );
has sclient_cmd       => ( is => 'ro', isa => 'Str', lazy => 1, builder => '_build_sclient_cmd' );
has protocol          => ( is => 'rw', isa => 'Str' );
has session_id        => ( is => 'rw', isa => 'Str' );
has master_key        => ( is => 'rw', isa => 'Str' );
has key_arg           => ( is => 'rw', isa => 'Str' );
has psk_identity      => ( is => 'rw', isa => 'Str' );
has psk_identity_hint => ( is => 'rw', isa => 'Str' );
has srp_username      => ( is => 'rw', isa => 'Str' );
has start_time        => ( is => 'rw', isa => 'Int' );
has timeout           => ( is => 'rw', isa => 'Int' );
has return_code       => ( is => 'rw', isa => 'Str', trigger => \&_return_code_set );
has accepted          => ( is => 'rw', isa => 'Bool', default => 0 );
has error             => ( is => 'rw', isa => 'Maybe[Str]' );
has text              => ( is => 'rw', isa => 'ArrayRef' );

# If this is set, then you don't re-run the command
has _has_run          => ( is => 'rw', isa => 'Bool', default => 0 );

=head1 METHODS

=head2 output_line() | Str

Returns a csv line that contains the cipher, protocol and then accepted|rejected.

=cut

sub output_line {
	my $self = shift;
	$self->_populate_object if ! $self->_has_run;
	return sprintf("%s, %s, %s", $self->cipher, $self->protocol || '', $self->accepted ? 'accepted' : 'rejected');
}


# ----
# private methods
# ----

# _populate_object( $refresh | Bool ) | undef
# If openssl s_client has not been run, then execute the command,
# parse the output, populate the object
# and set _has_run().
# You can also force execution of the command if you send in $refresh.

sub _populate_object {
	my $self = shift;
	my $refresh = shift;
	if (!$self->_has_run || $refresh) {
		my @output = $self->execute_openssl_cmd($self->sclient_cmd);
		$self->text(\@output);
		$self->_parse(\@output);
		$self->_has_run(1);
	}
}

# _parse($output | ArrayRef) | undef
# Parses the text in the array ref and populates the object.
# It only looks at a few of the fields.


# Krb5 Principal: None

sub _parse {
	my $self = shift;
	my $output = shift;
	if (my($error_line) = grep /:error:/, @$output) {
		# 47478002726544:error:14077410:SSL routines:SSL23_GET_SERVER_HELLO:sslv3 alert handshake failure:s23_clnt.c:762:
		$error_line =~ /^\d+:error:(?<code>\w+):(?<text>.+)$/;
		$self->return_code($+{code});
		$self->error($+{text});
	}
	else {
		my @fields = (
			'Protocol',
			'Session-ID',
			'Master-Key',
			'Key-Arg',
			'PSK identity',
			'PSK identity hint',
			'SRP username',
			'Start Time',
			'Timeout',
			'Verify return code',
		);
		foreach my $field (@fields) {
			my($line) = grep /^\s+$field/, @$output;
			next if ! $line;
			my($value) = $line =~ /:\s*(.+)\s*$/;
			my $normalized_field = $self->_normalize_field($field);
			if ($normalized_field eq 'timeout') {
				my($num) = $value =~ /(\d+)/;
				$value = $num;
			}
			elsif ($normalized_field eq 'verify_return_code') {
				my($num) = $value =~ /(\d+)/;
				$value = $num;
				$normalized_field = 'return_code';
			}
			$self->$normalized_field($value) if defined $value;
		}
	}
}

# _normalize_field( $str | Str ) | Str
# Normalizes the input string by lower casing all letters
# and substituting underscores (_) for dashes (-) and spaces ( ).

sub _normalize_field {
	my $self = shift;
	my $field = shift;
	my $normalized_field = lc($field);
	$normalized_field =~ s/-+/_/g;
	$normalized_field =~ s/\s+/_/g;
	return $normalized_field;
}


# ----
# moose triggers
# ----

sub _return_code_set {
	my ($self, $new_value, $old_value) = @_;
	if ($new_value eq 0) {
		$self->accepted(1);
	}
	else {
		$self->accepted(0);
	}
}


# ----
# moose builders
# ----

sub _build_sclient_cmd {
	my $self = shift;
	return sprintf("echo 'x' | %s s_client -connect %s:%i -CApath %s -cipher %s", $self->openssl_cmd, $self->host, $self->port, $self->certs_dir, $self->cipher);
}


__PACKAGE__->meta->make_immutable;

1;


__END__

=head1 AUTHOR

Written by David Laulusa.

=head1 COPYRIGHT

Copyright (c), SAP AG, 2015

=cut

