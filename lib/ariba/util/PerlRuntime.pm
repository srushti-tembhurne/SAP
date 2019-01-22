#
# $Id: //ariba/services/tools/lib/perl/ariba/util/PerlRuntime.pm#6 $
#
# Code to manage the Perl runtime

package ariba::util::PerlRuntime;

use strict;

sub deparseCoderef {
	my $coderef = shift;

	# the B::* utils that work with 5.005_03 don't support programatic
	# calls to B::Deparse.
	if ($] <= 5.00503) {
		print "deparseCoderef() returning as your version of perl is too old: $]\n" if -t STDOUT;
		return undef;
	}

	eval "use B::Deparse ()";
	my $deparse = B::Deparse->new('-si8T') unless $@ =~ /Can't locate/;

	eval "use Devel::Peek ()";
	my $peek = 1 unless $@ =~ /Can't locate/;

	return 0 unless $deparse;
		
	my $body = $deparse->coderef2text($coderef) || return 0;
	my $name;

	if ($peek) {
		my $gv = Devel::Peek::CvGV($coderef);
		$name  = join('::', *$gv{'PACKAGE'}, *$gv{'NAME'});
	}

	$name ||= 'ANON';

	return "sub $name $body";
}

# Use this method to extend a class at runtime
# Assumes there's a RealClass.pm
# and another file that's RandomCategory.pm (just a bunch of functions written as
# if there was a class)
# do
# ariba::util::PerlRuntime::addCategoryToClass(RandomCategory, RealClass);

sub addCategoryToClass {
	my $category = shift;
	my $class = shift;

	no strict 'refs';

	my $classIsaRef = "${class}::ISA";

	unshift(@$classIsaRef, $category);

	return 1;
}

sub dumpStack {
	my $error;
	my $frame = 1;

	print STDERR "Stack trace ----\n";

	while( my ($filename, $line, $subroutine) = (caller($frame++))[1,2,3] ) {

		$error .= "   frame ". ($frame - 2) . ": $subroutine ($filename line $line)\n";
	}

	print STDERR $error;

	return $error;
}

1;
