package ariba::Crypto::Certificate;

# $Id: //ariba/services/tools/lib/perl/ariba/Crypto/Certificate.pm#6 $

use strict;
use Date::Parse;
use File::Path;
use Net::SSLeay;
use Crypt::OpenSSL::X509 qw(FORMAT_PEM FORMAT_ASN1);
my $DAY	     = 60 * 60 * 24;

# if you are running < perl version 5.12, Date::Parse can not parse a date
# that is > 03:14:07 UTC on 19 January 2038.  See https://en.wikipedia.org/wiki/Year_2038_problem
# and http://search.cpan.org/~gbarr/TimeDate-2.30/lib/Date/Parse.pm (limitation section)
# To fix HOA-71851 (certs that exp after year 2038 show negative days), we will need to see what version of perl we are executing
# and if < than perl ver 5.12, we will set a boolean $year2038problem so when we encounter
# a cert that has an exp data > 03:14:07 UTC on 19 January 2038, we will use $timeMax to
# calc day to expire.  
# NOTE: this is a temp patch, when we upgrade to a new version of perl, this issue will go away.
#
my $year2038problem = ($] < 5.012000) ? 1 : 0;
my $timeMax = str2time("Jan 19 03:14:07 2038 GMT");

# class methods

# this can be overridden if the user so desires
sub new {
	my $class = shift;

	bless my $self = {}, $class;

	return $self;
}

# instance methods
sub certExpireTimeForPKCS12 {
	my $self = shift;
	my $file = shift;
	my $pass = shift;

	return 0 unless defined $file and $file !~ /^\s*$/;

	my ($pkcs12, $dummy);

	if (-r $file) {
		($dummy, $pkcs12) = Net::SSLeay::P_PKCS12_load_file($file, 0, $pass);
	}

	unless (defined $pkcs12) {
		warn "Couldn't check cert: [$file] - invalid?";
		return 0;
	}

	my $pemcert = Net::SSLeay::PEM_get_string_X509($pkcs12);

	return $self->certExpireTimeForX509($pemcert);
}

sub daysToCertExpireTimeForPKCS12 {
	my $self = shift;
	my $file = shift;
	my $pass = shift;

	my $timeToExpire = $self->certExpireTimeForPKCS12($file, $pass) - time();
	my $daysToExpire = int($timeToExpire / $DAY);

	return $daysToExpire;
}

sub certExpireTimeForX509 {
	my $self   = shift;
	my $cert   = shift;
	my $format = shift || FORMAT_PEM;

	return 0 unless defined $cert and $cert !~ /^\s*$/;

	my $x509;

	# we can take ourself
	if (ref($cert) && ref($cert) eq 'Crypt::OpenSSL::X509') {

		$x509 = $cert;

	} else {

		if (-r $cert) {
			$x509 = Crypt::OpenSSL::X509->new_from_file($cert, $format);
		} else {
			$x509 = Crypt::OpenSSL::X509->new_from_string($cert, $format);
		}
	}

	unless (defined $x509 and ref($x509)) {
		warn "Couldn't check cert: [$cert] - invalid?";
		return 0;
	}
        #
        # if we are on an old perl version with the year2038 problem and this
        # cert expires after the year 2037, just return $timeMax as that is the greatest
        # future time this version of perl can handle.  when we upgrade to
        # a new version of perl, this issue goes away!!
        my $year = ($x509->notAfter() =~ /[0-9]{4,4}(?=\sGMT$)/g)[0];
        if ( $year2038problem && $year > 2037 ) {
           return $timeMax;
        } 
	return str2time($x509->notAfter());
}

sub daysToCertExpireTimeForX509 {
	my $self   = shift;
	my $file   = shift;
	my $format = shift || FORMAT_PEM;
	my $timeToExpire = $self->certExpireTimeForX509($file, $format) - time();
	my $daysToExpire = int($timeToExpire / $DAY);

	return $daysToExpire;
}

sub commonNameForX509 {
	my $self = shift;
	my $x509 = shift;

	return unless defined $x509 and ref($x509);

	my %dnMap = ();
	my @parts = split /[\,\/]+/, $x509->subject();

	for my $part (@parts) {

		my ($key, $val) = ($part =~ /([\S]+?)=(.*)/);

		$key = uc $key;

		# skip crap CN's
		next if $key && $key eq 'CN' && $val && $val =~ /^http:/;

		# OU can be an array
		if ($key eq 'OU') {
			push @{$dnMap{$key}}, $val;
		} else {
			$dnMap{$key} = $val;
		}
	}

	if (exists $dnMap{'CN'}) {
		return $dnMap{'CN'};
	} elsif (exists $dnMap{'OU'}) {
		return $dnMap{'OU'}->[0];
	} elsif (exists $dnMap{'O'}) {
		return $dnMap{'O'};
	}
}

1;

__END__

