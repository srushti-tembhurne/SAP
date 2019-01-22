#
# $Id: //ariba/services/tools/lib/perl/ariba/util/XMLWrapper.pm#6 $
#
package ariba::util::XMLWrapper;

use strict;
use XML::Parser;

my $in_cdata = 0;
my %xmlParsed;
my @keys;
my @chars;
my $debug = 0;

sub parse
{
	my $file = shift;
	my $defsRef = shift;

	%xmlParsed = ();
	@keys = ();

	return unless (-f $file);

	my $parser = XML::Parser->new(ErrorContext => 2);
	$parser->setHandlers(
				    Comment => \&comments,
				    Start => \&start_handler,
				    End   => \&end_handler,
				    Char       => \&char_handler,
				    CdataStart => \&cdata_start,
				    CdataEnd   => \&cdata_end,
			    );
	$parser->parsefile($file);

	if ($defsRef) {
		for my $key (keys(%xmlParsed)) {
		    $defsRef->{$key} = $xmlParsed{$key};
		}
	}

	return %xmlParsed;
}

sub comments
{
	my ($p, $data) = @_;

	my $line = $p->current_line;
	$data =~ s/\n/\n\t/g;
	#print "comment() $line:\t<!--$data-->\n";

}  # End comments

sub start_handler
{
	my $xp = shift;
	my $el = shift;

	if ($el eq "XML") {
		return;
	}

	#print "start() [$el]\n";

	push(@keys, $el);

	push(@chars, undef);

	my $key;

	if (@_) {
		while (@_) {
			my $id = shift;
			my $val = shift;

			$val = $xp->xml_escape($val, "'");

			$key = join('.', @keys) . ".$id";
			$xmlParsed{$key} = $val;

			#print " $id='[$val]'";
		}
	} else {
		$key = join('.', @keys);
		$xmlParsed{$key} = "";
	}
}

sub end_handler
{
	my $xp = shift;
	my $el = shift;

	if ($el eq "XML") {
		return;
	}

	#print "end() [$el]\n";

	my $ch = pop(@chars);
	if (defined $ch) {
		$ch =~ s/^\s*//;
		$ch =~ s/\s*$//;
		if (length($ch) > 0) {
			my $key = join('.', @keys);
			$xmlParsed{$key} = $ch;
		}
	}

	pop(@keys);

}

sub char_handler
{
	my ($xp, $text) = @_;

	if (length($text) > 0) {

	  $text = $xp->xml_escape($text, '>') unless $in_cdata;

	}

	if (scalar(@chars) > 0) {
		if (defined $chars[$#chars]) {
			$chars[$#chars] .= $text;
		} else {
			$chars[$#chars] = $text;
		}

	  #print "char() [$text]\n";
	}
}

sub cdata_start 
{
  my $xp = shift;

  #print '<![CDATA[';
  $in_cdata = 1;
}

sub cdata_end 
{
  my $xp = shift;

  #print ']]>';
  $in_cdata = 0;
}


sub indentNode
{
	my $node = shift;
	my $topNode = shift;
	my $indentSpace = "    ";
	my @dummy = split(/\./, $node);
	my $countDots = $#dummy - 1;
	@dummy = split(/\./, $topNode);
	my $countTopDots = $#dummy - 1;
	my $indent = $indentSpace x ($countDots-$countTopDots);
	return $indent;
}

sub beginXmlNode
{
	my ($written, $topNode, $node, $val) = @_;
	my $xmlString = "";
	my $indent = indentNode($node,$topNode);

	print "opening node :$node\n" if ($debug);
	if ($node =~ m/(.*)\.(.*)/) {
		my ($head, $tail) = ($1, $2);

		#
		# if defining new node, close out the one currently working open
		#
		if (!defined($written->{$node})) {
		    for my $key (reverse(sort(keys(%$written)))) {
			if ($key =~ /^$head\./) {
			    $xmlString .= endXmlNode($written,$topNode,$key,$xmlString);
			}
		    }
		}

		#
		# recursively open the current nodes parent
		#
		if (lc($node) ne $topNode) {
		    $xmlString .= beginXmlNode($written, $topNode, $head, undef);
		}

		#
		# open this node, and insert it's value
		#
		if (!defined($written->{$node})) {
		    $xmlString .= "$indent<$tail>";
		    if (defined ($val)) {
			$xmlString .= $val;
		    } else {
		    	$xmlString .= "\n";
		    }
		    $written->{$node} = 1;
		}
	#
	# handle the root node, which does not have head and tail parts
	#
	} elsif (!defined $written->{$node}) {
		    $xmlString .= "$indent<$node>\n";
		    $written->{$node} = 1;
	}
	print "$xmlString\n" if ($debug);

	return $xmlString;

}

sub endXmlNode
{
	my ($written, $topNode, $node, $indentIt) = @_;

	my $indent = "";
	if (defined($indentIt) && $indentIt) {
		$indent = indentNode($node,$topNode);
	}
	print "closing node: $node\n" if ($debug);
	my $xmlString = "";
	if (defined ($node) && $node =~ m/(.*)\.(.*)/) {
		my ($head, $tail) = ($1, $2);

		#
		# close the current node.
		#
		if (defined($written->{$node})) {
		    $xmlString .= "$indent</$tail>\n";
		    delete $written->{$node};
		}
	} elsif (defined ($node)) {
		#
		# close root node
		#
		$xmlString .= "$indent</$node>\n";
		delete $written->{$node};
	} else {
		#
		# if no node provided, close all of them
		#
		for my $key(reverse(sort(keys(%$written)))) {
		    $xmlString .= endXmlNode($written, $topNode, $key, $xmlString);
		}
	}
	print "$xmlString\n" if ($debug);

	return $xmlString;

}

sub createXMLString
{
	my ($xmlTable, $node) = @_;
	my (%written);

	my $xmlString = "";
	for my $key (sort(keys(%$xmlTable))) {
		if ($key =~ m/^$node\b/i) {
		    $xmlString .= beginXmlNode(\%written, lc($node), 
					       $key, $xmlTable->{$key});
		}
	}
	$xmlString .= endXmlNode(\%written,lc($node),undef);
	return $xmlString;
}

return 1;
