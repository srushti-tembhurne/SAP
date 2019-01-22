#
# A base class to help render arbitrary object as a web component
#

package ariba::Ops::OW::Component;
use strict;

use ariba::util::PerlRuntime;
use ariba::Ops::PersistantObject;
use vars qw(@ISA);

@ISA = qw(ariba::Ops::PersistantObject);

my $autoInstanceName = 0;

sub dir {
	my $class = shift;

	# don't have a backing store
	return undef;
}

sub save {
	my $self = shift;

	return 1;
}

# class methods
sub objectLoadMap {
	my $class = shift;

	my $map = $class->SUPER::objectLoadMap();

	$map->{'components'} = '@ariba::Ops::OW::Component',

	return $map;
}

sub newFromHtmlFile {
	my $class = shift;
	my $file = shift;

	my $instance = $file;

	unless (-f $file) {
		return undef;
	}

	open(FL, "$file") || return undef;
	my @htmlLines = <FL>;
	close(FL);

	unshift(@htmlLines, "<OWComponent>");
	push(@htmlLines, "</OWComponent>");
	my ($i, $self) = $class->parseAndBuildTree(0, \@htmlLines);

	return $self;
}

sub newFromHtmlString {
	my $class = shift;
	my $string = shift;

	my @htmlLines = ($string);

	unshift(@htmlLines, "<OWComponent>");
	push(@htmlLines, "</OWComponent>");
	my ($i, $self) = $class->parseAndBuildTree(0, \@htmlLines);

	return $self;
}

sub newWithArgString {
	my $class = shift;
	my $argString = shift;

	my $instance = $class . "-" . $autoInstanceName++;

	my %attributes;

	if ($argString) {
		#
		# list="ariba::monitor::CircularDB->new("foo")
		# value="hello world" id=2
		#
		while ($argString =~ m|(\w+)\s*=\s*([^=]+)(=?)|) {
			my $key = $1;
			my $value = $2;

			if ($3) {
				$value =~ s|(.*)\b(\w+)|$1|;
				my $nextKey = $2;
				$argString =~ s|\w+\s*=\s*[^=]+|$nextKey|;
			} else {
				$argString =~ s|\w+\s*=\s*[^=]+||;
			}
			$value =~ s|^\s*||;
			$value =~ s|\s*$||;

			if ($key eq "id") {
				$instance = $value;
			} else {
				$attributes{$key} = $value;
			}
		}
	}

	my $self = $class->SUPER::new($instance);
	bless($self, $class);

	for my $key (keys(%attributes)) {
		$self->setAttribute("_unevaled_ " . $key, $attributes{$key});
	}
	$self->setAttributeList(keys(%attributes));

	$self->evalAttributes();

	# always use the local setting of nodisplay, not
	# the real ivar
	#$self->setAttribute('nodisplay', $attributes{'nodisplay'} || 0);

	if ( $self->template() ) {
	        my ($i, $component) = $class->parseAndBuildTree(0, $self->template() );
		$self->setComponents($component);
	}

	return $self;
}

sub evalAttributes {
	my $self = shift;
	my @currentItems = @_;

	my $class = ref($self);

	for my $key ( $self->attributeList() ) {
		next unless $key;

		my $value = $self->attribute("_unevaled_ " . $key);

		next unless $value;

		if ( !@currentItems && $value =~ /\$currentItem/ ) {
			$self->setAttribute($key, $value);
		} else {
			my $line;
			my $resultsRef = ($class->evalTokensInLine($value, \$line, @currentItems))[0];

			if ( ref($resultsRef) eq "ARRAY" ) {
				$self->setAttribute($key, @$resultsRef);
			} else {
				$self->setAttribute($key, $$resultsRef);
			}
		}
	}

	return $self;
}

#
# take a line of input and expand all the tokens
# set modified copy of the line as a ref 
# returns an array of arrays of expansions
#
sub evalTokensInLine {
	my $class = shift;
	my $line = shift;
	my $newlineRef = shift || \$line;
	my @currentItems = @_;

	# set up our "eval env", a hack for now

	my $currentItem = $currentItems[0];
	my $currentItem0 = $currentItems[0];

	my $currentItem1 = $currentItems[1];
	my $currentItem2 = $currentItems[2];
	my $currentItem3 = $currentItems[3];
	my $currentItem4 = $currentItems[4];
	my $currentItem5 = $currentItems[5];
	my $currentItem6 = $currentItems[6];
	my $currentItem7 = $currentItems[7];
	my $currentItem8 = $currentItems[8];
	my $currentItem9 = $currentItems[9];

	my $currentItem10 = $currentItems[10];
	my $currentItem11 = $currentItems[11];
	my $currentItem12 = $currentItems[12];
	my $currentItem13 = $currentItems[13];
	my $currentItem14 = $currentItems[14];
	my $currentItem15 = $currentItems[15];
	my $currentItem16 = $currentItems[16];
	my $currentItem17 = $currentItems[17];
	my $currentItem18 = $currentItems[18];
	my $currentItem19 = $currentItems[19];

	$$newlineRef = $line;


	my @resultsArray;

	# handle the case where the input has no tokens to expand
	unless ( $$newlineRef =~ m|\*([^*]+)\*| ) {
		push(@resultsArray, $newlineRef);
		return @resultsArray;
	}

	# handle the case where the input has tokens to expand

	while( $$newlineRef =~ m|\*([^*\n]+)\*| ) {
		my $match = $1;
		my $result;
		my @result;

		#
		# dynamically do use of classes we need.
		#
		my $useClasses = $match;
		while ($useClasses =~ s|\b([\w:>-]+)\b||) {
			my $useClass = $1;

			next if ($useClass !~ m|::|);

			if ($useClass =~ s|\->\w+||) {
				eval "use $useClass";
			} elsif ($useClass =~ s|::\w+||) {
				eval "use $useClass";
			}
		}

		@result = eval($match);
		my $quotedMatch = quotemeta($match);

		if ( defined($result[1]) ) {
			push(@resultsArray, \@result);

			my $replaceString = join(", ", @result);
			$$newlineRef =~ s|\*$quotedMatch\*|$replaceString|g;

		} else {
			$result = $result[0] || "";
			$$newlineRef =~ s|\*$quotedMatch\*|$result|g;

			push(@resultsArray, \$result);
		}
	}

	return @resultsArray;
}

sub _allocateSubComponent {
	my $class = shift;
	my $name = shift;
	my $argString = shift;

	my $newClass = "ariba::Ops::OW::$name";

	eval "use $newClass";

	my $component = $newClass->newWithArgString($argString);

	return $component;
}

sub parseAndBuildTree {
	my $class = shift;
	my $startIndex = shift;
	my $lines = shift;

	my $self;

	my $currentComponent;
	my $argString;
	my $continueArgString;
	my @rawHtmlLines;
	my @subComponents;

	my $i;
	my $numLines =  @$lines;

	#
	# Handle component defining tags of following formats:
	#
	#	<OWVar id=foo value=bar />
	#
	#	<OWHtmlString>
	#		blah
	#	</OWHtmlString>
	#
	#
	#	<OWRepetition list=*("red","yellow","green")*>
	#		color=*$currentItem*
	#	</OWRepetition>
	#
	#	<OWParallelRepetition list0=*("red","yellow","green")*
	#                         list1=*("toy1", "toy2", "toy3")*>
	#		color=*$currentItem0* name=*$currentItem1*
	#	</OWParallelRepetition>
	#
	#

	for ($i = $startIndex; $i < $numLines; $i++) {
		my $line = $lines->[$i];

		next unless ($line);

		#
		# recursively parse a component block, allocate self, and return
		# as soon as we see end of this component block.
		#
		if ( $line =~ m|^\s*<OW(\w+)| ) {
			my $startComponent = $1;

			#
			# we're starting a new component, we might have 
			# already accumulated some stuff
			# save this one aside.
			#
			if ( @rawHtmlLines ) {
				my $subComponent = $class->_allocateSubComponent("HtmlString", undef);
				$subComponent->setValue(join("", @rawHtmlLines));

				push(@subComponents, $subComponent);

				@rawHtmlLines = ();
			}

			#
			# starting a new subcomponent. recursively parse it out
			#
			if ($currentComponent) {
				my ($incr, $subComponent) = $class->parseAndBuildTree($i,$lines);
				$i = $incr;
				push(@subComponents, $subComponent);
				next;
			}

			$currentComponent = $startComponent;

			#
			# get components arg string
			#
			$line =~ m|^\s*<OW$currentComponent\s*(.*)|;

			$argString = $1;
			$argString =~ s|^\s*||;
			$argString =~ s|\s*$||;
			$argString =~ s|\s*/?\s*(>)$||;

			#
			# arg string continues on next line, if we didnt see '>' tag
			#
			unless ($1) {
				$continueArgString = 1;
			}

			#
			# was the component fully specified on one line
			#
			if ($line =~ m|^\s*<OW$currentComponent\s+.*(/\s*>)|) {
				$self = $class->_allocateSubComponent($currentComponent, $argString);
				my ($incr, $subComponent) = $class->parseAndBuildTree(0, \@rawHtmlLines);
				push(@subComponents, $subComponent);

				last;
			}


		} elsif ( $currentComponent && 
				  $line =~ m|^\s*</OW$currentComponent\b| ) {

				$self = $class->_allocateSubComponent($currentComponent, $argString);
				my ($incr, $subComponent) = $class->parseAndBuildTree(0, \@rawHtmlLines);
				push(@subComponents, $subComponent);

				last;

		} else {
			if ($continueArgString) {
				if ( defined($argString) ) {
					$argString .= " $line";
				} else {
					$argString = $line;
				}
				$argString =~ s|^\s*||;
				$argString =~ s|\s*$||;
				$argString =~ s|\s*/?\s*(>)$||;

				if ($1) {
					$continueArgString = 0;
				}

				# was the component fully specified on one line
				if ($line =~ m|(/\s*>)|) {
					$self = $class->_allocateSubComponent($currentComponent, $argString);
					my ($incr, $subComponent) = $class->parseAndBuildTree(0, \@rawHtmlLines);
					push(@subComponents, $subComponent);

					last;
				}

			} else {
				push(@rawHtmlLines, $line);
			}
		}
	}

	#
	# if the component was made purley of html string and no other
	# subcomponents, handle it here
	# 
	unless ($self) {
		$self = $class->_allocateSubComponent("HtmlString", undef);

		if ( @rawHtmlLines ) {
			$self->setValue(join("", @rawHtmlLines));
			@rawHtmlLines = ();
		}
	}

	if (@subComponents) {
		if ( $self->components() ) {
			$self->appendToComponents(@subComponents);
		} else {
			$self->setComponents(@subComponents);
		}
	}

	return ($i, $self);
}


sub displayToString {
	my $self = shift;
	my $noExpandTokens = shift;

	my $string = "";

	if ( $self->nodisplay() ) {
		return $string;
	}

	if ( $self->value() ) {
		$string = join(", ", $self->value());
	}

	if ( $self->components() ) {
		for my $component ( $self->components() ) {
			$string .= $component->displayToString($noExpandTokens);
		}
	} 

	my $returnString = $string;

	unless ( $noExpandTokens ) {
		my $class = ref($self);
		my @discard = $class->evalTokensInLine($string, \$returnString);
	}

	return $returnString;
}

sub displayToStream {
	my $self = shift;
	my $stream = shift || \*STDOUT;

	print $stream $self->displayToString(@_);
}

1;
