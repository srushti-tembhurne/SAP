package ariba::Ops::OpsWebsiteIndexer;

use strict;
use base qw(ariba::Ops::TextIndexer);
use ariba::Ops::Utils;

sub convertFileToText {
	my $self = shift;
	my $document = shift;

	return undef unless -T $document;

	open(FH, $document) or do {
		print "Can't open document [$document]: $!\n";
		return undef;
	};

	local $/ = undef;
	my $text = <FH>;
	close(FH);

	# Strip out all high-bit chars, we can't handle that yet.
	$text =~ tr/\200-\377/\000-\177/;

	return ariba::Ops::Utils::stripHTML($text);
}

sub primaryDir {
	my $class = shift;

	return "/var/tmp/opswebsiteindex/data";
}

1;
