package ariba::Ops::MIMEHelper;

use strict;
use MIME::Parser;

my $DEBUG  = 0;
my $INDENT = 0;

my $defaultAlternativeWeighting = {

	'text/enriched'						=> 165,
	'text/html'							=> 171,
	'text/plain'						=> 170,

	'image/jpeg'						=> 151,
	'image/gif',						=> 150,
	'image/tiff'						=> 149,

	'application/rtf'					=> 160,
	'application/octet-stream'			=> 105,
	'application/postscript'			=> 80,

	'multipart/mixed	'				=> 202,
	'multipart/related'					=> 201,
	'multipart/alternative'				=> 7,

	'message/external-body'				=> 21,
	'message/external-body:local-file'	=> 20,
	'message/external-body:x-url'		=> 19,
	'message/external-body:mail-server'	=> 18,
	'message/external-body:anon-ftp'	=> 17,
};

sub new {

	my $class = shift;
	my $weightHashRef = shift;

	my $self = {};
	bless($self, $class);
	$self->setParserWeighting($defaultAlternativeWeighting);

	if (defined($weightHashRef)) {
		$self ->modifyParserWeighting($weightHashRef);
	}
	return $self;
}

sub modifyParserWeighting {
	my $self = shift;
	my $newWeightHashRef = shift;

	my $currentWeightingHashRef = $self->parserWeighting();

	foreach my $key (keys %{$newWeightHashRef}) {
		$currentWeightingHashRef->{$key} = $newWeightHashRef->{$key};
	}

	$self->setParserWeighting($currentWeightingHashRef);
}

sub setParserWeighting {
	my $self = shift;
	my $weightingRef = shift;

	$self->{'weightingRef'} = $weightingRef;
}

sub parserWeighting {
	my $self = shift;
	return $self->{'weightingRef'};
}

sub parseMultipart {
	my ($class, $parser, $entity, $display) = @_;
	
	my $alternativeWeighting;

	# instance method uses its private parser weighting,
	# class method uses the class-wide default
	if (ref($class)) {
		$alternativeWeighting = $class->parserWeighting();
	}
	else {
		$alternativeWeighting = $defaultAlternativeWeighting;
	}

	$INDENT += 2;

	# if we are recursing, create a new entity object.
	unless (ref($entity)) {
		$entity = $parser->parse_data($entity);
	}

	# build our parts array.
	my @parts = map { $_ } $entity->parts();
	
	# weigh alternatives according to the table.
	if ($entity->mime_type() eq 'multipart/alternative') {

		@parts = sort { 
			$alternativeWeighting->{$b->mime_type()} <=>
				$alternativeWeighting->{$a->mime_type()}
		} @parts;

		print ' ' x $INDENT, "Found a multipart/alternative - picking last part.\n\n" 
			if $DEBUG;
                @parts = shift @parts;
	}

	for my $part ( @parts ) {

		if ($DEBUG) {
			printf ' ' x $INDENT;
			$class->printMIME($part);
		}

		# recurse
		if ($part->mime_type() =~ /multipart/) {
			$INDENT += 2;
			$class->parseMultipart($parser,$part,$display);
			$INDENT -= 2;
		} else {
			push @{$display}, $part;
		}
	}
}

sub printMIME {
	my ($class, $entity) = @_;

	printf "MIME Type: [%s] Filename: [%s] Disposition: [%s] Encoding: [%s]\n", 
		$entity->mime_type(),
		$entity->head()->recommended_filename() || 'unknown-filename.bin',
		$entity->head()->mime_attr('Content-Disposition') || 'inline',
		$entity->head()->mime_attr('Content-Transfer-Encoding') || '7bit';
}
	
1;

__END__
