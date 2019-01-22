package ariba::Ops::MailIndexer;

use strict;
use base qw(ariba::Ops::TextIndexer);
use ariba::Ops::Utils;

my $DEBUG = 0;

sub convertFileToText {
	my ($self,$document) = @_;

	my $contentType = '';

	open FH, $document or do {
		print "Can't open document [$document]: $!\n";
		return undef;
	};

	local $/ = "\n\n";
	my $headers = <FH>;

	if ($headers =~ /\bContent-Type:\s+(\w+\/\w+)/io) {
		$contentType = $1;
	} else {
		$contentType = 'text/plain';
	}

	if ($contentType !~ m!text/plain!io) {
		print "skipping document [$document] contentType: [$contentType]\n" if $DEBUG;
		return undef;
	}

	local $/ = undef;
	my $text = <FH>;
	close FH;

	return ariba::Ops::Utils::stripHTML($text);
}

1;

__END__
