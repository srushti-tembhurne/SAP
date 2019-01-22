package ariba::Ops::OpenSSL::Ciphers;
use Moose;
use Moose::Util::TypeConstraints;
use namespace::autoclean;

extends 'ariba::Ops::OpenSSL';

=head1 NAME

ariba::Ops::OpenSSL::Ciphers

=head1 SYNOPSIS

 use ariba::Ops::OpenSSL::Ciphers;
 my $obj = ariba::Ops::OpenSSL::Ciphers->new;
 my @ciphers = $obj->get_ciphers();

=head1 DESCRIPTION

This class takes the output of OpenSSL ciphers command and populates the object.

=cut


use ariba::Ops::OpenSSL::Cipher;

my $LOG_CATEGORY = 'ariba::Ops::OpenSSL';
my $ALL          = 'all';
my $SUITE        = 'suite';
my $ALL_CIPHERS  = 'ALL:eNULL';
my $CIPHER_SUITE = 'HIGH:MEDIUM:!SSLv2:!aNULL:!aDSS:@STRENGTH:+kEDH:!EXP';

=head1 ATTRIBUTES

=head2 cipher_list_type | Enum

This can either be 'suite' or 'all'. It defaults to 'suite'.

=head2 cipher_parameter | Str

The cipher parameter is used to create the cipher command and it depends upon the cipher_list_type.

=head2 ciphers_cmd | Str

The cipher command executed to get all the info.

=head2 ciphers | HashRef[ariba::Ops::OpenSSL::Cipher]

Here's where we store all the objects.
This handles get_cipher() which returns one ariba::Ops::OpenSSL::Cipher,
cipher_obj_list() which returns all ariba::Ops::OpenSSL::Cipher objects,
and cipher_list() which returns all the ciphers.

=cut

has cipher_parameter => ( is => 'ro', isa => 'Str', lazy => 1, builder => '_build_ciphers_parameter' );
has ciphers_cmd      => ( is => 'ro', isa => 'Str', lazy => 1, builder => '_build_ciphers_cmd' );
has cipher_list_type => ( is => 'rw', isa => enum([$ALL,$SUITE]), default => $SUITE, writer => '_set_cipher_list_type' );

# If this is set, then you don't need to re-run the command
has _has_run          => ( is => 'rw', isa => 'Bool', default => 0 );


has ciphers => (
    traits    => ['Hash'],
    is        => 'rw',
    isa       => 'HashRef[ariba::Ops::OpenSSL::Cipher]',
    default   => sub { {} },
    handles   => {
        add_cipher      => 'set',
        get_cipher      => 'get',
        cipher_list     => 'keys',
        cipher_obj_list => 'values',
    },
);

=head1 METHODS

=head2 get_ciphers( $refresh | Bool ) | Array[Str]

If the command hasn't run or you pass in $refresh,
then runs the OpenSSL ciphers command and populates the object.
Then it returns an array of all the ciphers.

=cut

sub get_ciphers {
	my $self = shift;
	my $refresh = shift;
	$self->_process_ciphers if (!$self->_has_run || $refresh);
	return $self->cipher_list;
}


# ----
# private methods
# ----

# _process_ciphers() | undef
# Execute the OpenSSL cipher command, parse each line,
# populate objects and set _has_run(1).

sub _process_ciphers {
	my $self = shift;
	foreach my $line ($self->execute_openssl_cmd($self->ciphers_cmd())) {
		$self->_parse_line($line);
	}
	$self->_has_run(1);
}


# _parse_line( $line | Str ) | undef
# Parses the line, creates a ariba::Ops::OpenSSL::Cipher object,
# and saves it

sub _parse_line {
	my $self = shift;
	my $line = shift;
	if ($line =~ /
			^\s*(?<name>\S+)\s+
			(?<protocol>\S+)\s+
			Kx=(?<kx>\S+)\s+
			Au=(?<au>\S+)\s+
			Enc=(?<enc>\S+)\s+
			Mac=(?<mac>\S+)\s*
		/x) {
		my $name           = $+{name};
		my $protocol       = $+{protocol};
		my $authentication = $+{au};
		my $mac_algorithm  = $+{mac};

		my $kx             = $+{kx};
		my $enc            = $+{enc};

		my $key_exchange;
		my $key_size;
		if ($kx =~ /^(?<key_exchange>\S+)\((?<key_size>\d+)\)$/) {
			$key_exchange = $+{key_exchange};
			$key_size     = $+{key_size};
		}
		else {
			$key_exchange = $kx;
		}

		my $encryption;
		my $encryption_size;
		if ($enc =~ /^(?<encryption>\S+)\((?<encryption_size>\d+)\)$/) {
			$encryption      = $+{encryption};
			$encryption_size = $+{encryption_size};
		}
		else {
			$encryption = $enc;
		}

		my %args = (
			name           => $name,
			protocol       => $protocol,
			authentication => $authentication,
			mac_algorithm  => $mac_algorithm,
			key_exchange   => $key_exchange,
			encryption     => $encryption,
		);
		$args{key_size} = $key_size               if $key_size;
		$args{encryption_size} = $encryption_size if $encryption_size;
		$args{export} = 1                         if $line =~ /export/;
		my $obj = ariba::Ops::OpenSSL::Cipher->new(%args);
		$self->add_cipher($obj->name => $obj);

	}
	else {
		$self->logger()->logdie("don't know how to parse this line: $line");
	}

}



# ----
# moose builders
# ----

sub _build_ciphers_parameter {
	my $self = shift;
	return $self->cipher_list_type eq $SUITE ? $CIPHER_SUITE : $ALL_CIPHERS;
}

sub _build_ciphers_cmd {
	my $self = shift;
	return sprintf("%s ciphers -v '%s'", $self->openssl_cmd, $self->cipher_parameter);
}


__PACKAGE__->meta->make_immutable;

1;


__END__

=head1 AUTHOR

Written by David Laulusa.

=head1 COPYRIGHT

Copyright (c), SAP AG, 2015

=cut

