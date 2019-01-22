package ariba::Ops::OpenSSL;
use Moose;
use Moose::Util::TypeConstraints;
use namespace::autoclean;

=head1 NAME

ariba::Ops::OpenSSL

=head1 SYNOPSIS

 use Moose;
 extends 'ariba::Ops::OpenSSL';

=head1 DESCRIPTION

Base class for all the OpenSSL classes.
Right now all it does is version.

=cut

use Log::Log4perl;

my $LOG_CATEGORY = 'ariba::Ops::OpenSSL';
my $OPENSSL_OLD  = '/usr/bin/openssl';
my $OPENSSL_NEW  = '/usr/local/tools/bin/openssl';
my $OLD          = 'old';
my $NEW          = 'new';

=head1 ATTRIBUTES

=head2 openssl_version | Enum

There are two openssl versions that we care about, 0.9.8 (old) and 1.0.1 (new).
And, of course, their outputs are different. So, old and new are the two possible values.
The default is new.

=head2 openssl_cmd | Str

The OpenSSL command. This depends on the value of openssl_version.

=head2 logger | Log::Log4perl::Logger

Returns the logger object

=cut

has openssl_version => ( is => 'ro', isa => enum([$OLD,$NEW]), default => $NEW );
has openssl_cmd     => ( is => 'ro', isa => 'Str', lazy => 1, builder => '_build_openssl_cmd' );
has logger          => ( is => 'ro', isa => 'Log::Log4perl::Logger', lazy => 1, builder => '_build_logger' );

=head1 METHODS

=head2 version() | Str

Returns the openssl version.

=cut


sub version {
	my $self = shift;
	my $cmd = sprintf("%s version", $self->openssl_cmd);
	my($output) = $self->execute_openssl_cmd($cmd);
	$output =~ s/\s*$//;
	return $output;
}

=head2 execute_openssl_cmd($cmd | Str) | Array[Str]

Executes an openssl command and returns the output from both STDOUT and STDERR.

=cut

sub execute_openssl_cmd {
	my $self = shift;
	my $cmd  = shift;
	my @output = `$cmd 2>&1`;
	return @output;
}
# ----
# moose builders
# ----

sub _build_logger {
	my $self = shift;
	return Log::Log4perl->get_logger($LOG_CATEGORY);
}

sub _build_openssl_cmd {
	my $self = shift;
	return $self->openssl_version eq $NEW ? $OPENSSL_NEW : $OPENSSL_OLD;
}

__PACKAGE__->meta->make_immutable;

1;


__END__

=head1 AUTHOR

Written by David Laulusa.

=head1 COPYRIGHT

Copyright (c), SAP AG, 2015

=cut

