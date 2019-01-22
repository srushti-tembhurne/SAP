package ariba::Ops::PasswordManager;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/PasswordManager.pm#1 $

use strict;

use ariba::Ops::Constants;
use ariba::Ops::PersistantObject;

use base qw(ariba::Ops::PersistantObject);

my $DEBUG	= 1;

###############
# class methods
sub listObjects {
	my $class = shift;
	my @list  = ();

	my @dirs = glob($class->dir() . "/*");
	for my $dir (@dirs) {
	    opendir(DIR, $dir) or die "Can't open $dir: $!\n";
	    my @files = grep($_ !~ /^\./o, readdir(DIR));
	    closedir(DIR);

	    foreach my $file (sort @files) {
		    push(@list, $class->new($file)) or warn "Can't create new $class: $!";
	    }	
	}
	
	return @list;
}

sub dir {
	my $class = shift;
	return ariba::Ops::Constants->PasswordManagerdir();
}

sub _computeBackingStoreForInstanceName {
	my $class = shift;
	my $instanceName = shift;

	# this takes the instance name as an arg
	# so that the class method objectExists() can call it

	# parse out the domain part
	my $domain = (split /\./, $instanceName, 2)[1] || '';

	my $file = join '/', ($class->dir(), $domain, $instanceName) ;

	map { $file =~ s/$_//go } qw(`"'>|;);

	$file =~ s/\.\.//o;
	$file =~ s|//|/|go;

	return $file;
}

1;

__END__

=head1 NAME

ariba::Ops::PasswordManager - manage the password database

=head1 SYNOPSIS

   use ariba::Ops::PasswordManager;

=head1 DESCRIPTION

Provides methods to manipulate the PasswordManager database

=head1 CLASS METHODS

=head1 INSTANCE METHODS
   
=head1 AUTHOR

Daniel Sully <dsully@ariba.com>

=head1 SEE ALSO

ariba::Ops::PersistantObject

=cut
 
