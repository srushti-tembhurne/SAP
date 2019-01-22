# $Id: Conf.pm,v 1.1 1999/12/07 04:58:08 dsully Exp dsully $

package ariba::WebStats::Analog::Config;

use strict;
use Data::Dumper;

sub new ($%) {
	my $proto = shift;
	my %args  = @_;

	bless my $self = { 'config' => \%args }, (ref $proto || $proto);

	$self->{'config_file'} = "/tmp/analog.cfg.$$";
	return $self;
}

sub write ($) {
	my $self = shift;
	my %args = @_;

	while(my($k,$v) = each %{$self->{'config'}}) {
		print uc($k), " $v\n";
	}

	return;
	open CFG, ">$self->{'config_file'}" or do {
		warn "Can't write to config file: [$self->{'config_file'}] : $!\n";
		return 0;
	};

	while(my($k,$v) = each %{$self->{'config'}}) {

		print uc($k), " $v\n";
		print CFG uc($k), " $v\n";
	}

	close CFG;
}

sub remove ($) {
	my $self = shift;
	return (unlink $self->{'config_file'} ? 1 : 0);
}

1;

__END__
