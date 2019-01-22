package ariba::Ops::PropertyList;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/PropertyList.pm#8 $

use strict;

# Match the key, can be any of these values.
#
# example:
# Authentication = { PasswordAdapter = PasswordAdapter1; };
my $lineMatch = '^\s*("([^"]*)"|[^\s,=;\(\)\{\}]+)';

=head1 DESCRIPTION

This module parses NeXT/Apple plist format files into a datastructure, which
allows key access to each element. 

=over

=item new()

	Create a new dictionary from a PropertyList string

=back

=cut


# Class methods
sub new {
	my $class  = shift;
	my $string = shift;

	# Strip out all the comments - this handles multiline
	$string =~ s|/\*([^\*]*)\*/| |g;

	# C++ style // comments
	$string =~ s|\s+//.+?\n| |g;
	
	my $flatKeysHashRef = {};
	my $allKeysRef = [];

	# Start the parsing at the top level
	my $dict = _parseDictionaryContents(\$string, $flatKeysHashRef, $allKeysRef);

	if (scalar keys %$dict <= 0) {
		$dict = _parseValue(\$string, $flatKeysHashRef, $allKeysRef);
	}

	my $self = {
		'_dictionary' => $dict,
		'_flatKeys' => $flatKeysHashRef,  # lower cased keys -> keys
	};

	bless $self, $class;
}

=over

=item newFromFile ( file )

	Create a new dictionary from a file.

=back

=cut

sub newFromFile {
	my $class = shift;
	my $file  = shift;

	open(FH, $file) or die "Can't open file: [$file] - $!";
	local $/ = undef;
	my $string = <FH>;
	$string .= ';';
	close(FH);

	return $class->new($string);
}

=over

=item writeToFile ( file )

	Flush the in memory copy to disk.

=back

=cut

sub writeToFile {
	my $self = shift;
	my $file = shift;

	open(FH, ">$file") or die "Can't write to file: [$file] - $!";
	print FH $self->toString() . "\n";
	close(FH);

	return 1;
}

# instance methods

=over

=item listKeys

	Retrieve a sorted, flattened list of all loaded keys.

=back

=cut

sub listKeys {
	my $self = shift;

	my $flatKeys = $self->{'_flatKeys'};
	my @keys = values(%$flatKeys);
	return @keys;
}

=over

=item valueForKeyPath ( path )

	Retrieve the value for a given keypath. This can be a complex return type.

=back

=cut

sub valueForKeyPath {
	my $self = shift;
	my $path = shift;

	my $dict = $self->{'_dictionary'};
	my $flatKeys = $self->{'_flatKeys'};

	# Empty means return the top level
	return $dict unless $path;

	#
	# Allow for case insensitive lookup. Lookup actual case using the
	# lookup key of all lowercase name.
	#
	my $lcPath = lc($path);
	my $actualPath = $flatKeys->{$lcPath};

	return undef unless $actualPath;
	
	for my $key (split /\./, $actualPath) {

		if (exists $dict->{$key}) {
			$dict = $dict->{$key};
		} else {
			return undef;
		}
	}

	return $dict;
}

=over

=item setValueForKeyPath ( path, value )

	Set the value for a given keypath. This can be a complex return type.

=back

=cut

sub setValueForKeyPath {
	my $self  = shift;
	my $path  = shift;
	my $value = shift;

	my $dict  = $self->{'_dictionary'};
	my $flatKeys = $self->{'_flatKeys'};

	my $lcPath = lc($path);
	my $actualPath = $flatKeys->{$lcPath};

	#
	# We could be setting value for an existing key, in which case
	# allow it to be set using case insensitive key. If it is a new
	# key, preserve the case as supplied.
	#
	my @key;
	if ($actualPath) {
		@key = (split /\./, $actualPath);
	} else {
		@key = (split /\./, $path);
		$flatKeys->{$lcPath} = $path; # adding a new key/value pair
	}

	# path can be "", which means, replace the top level
	if (defined $path && $path =~ /^\s*$/) {
		$self->{'_dictionary'} = $value;
		return;
	}

	while (@key > 1) {
		my $key = shift @key;

		# create a path along the way if it doesn't exist.
		$dict->{$key} = {} unless exists $dict->{$key};

		$dict = $dict->{$key};
	}

	$dict->{shift @key} = $value;
}

=over

=item deleteKeyPath ( path )

	Remove the value for a given keypath.

=back

=cut

sub deleteKeyPath {
	my $self  = shift;
	my $path  = shift;

	my $dict  = $self->{'_dictionary'};
	my $flatKeys = $self->{'_flatKeys'};

	my $lcPath = lc($path);
	my $actualPath = $flatKeys->{$lcPath};

	return unless $actualPath;

	my @key   = (split /\./, $actualPath);
	while (@key > 1) {
		my $key = shift @key;

		# bail if the path doesn't exist in the first place.
		return unless exists $dict->{$key};

		$dict = $dict->{$key};
	}

	delete $dict->{shift @key};
	delete $flatKeys->{$lcPath};
}

=over

=item toString ( dictionary, indent )

	Turn a dictionary into a string suitable for saving to a file.

=back

=cut

sub toString {
	my $self   = shift;
	my $object = shift;
	my $indent = shift || 1;

	my $string;

	# We store the dictionary internally
	# This must check for defined, as values can be 0
	unless (defined $object) {
		$object = $self->{'_dictionary'};
	}

	if (ref($object) eq 'ARRAY') {

		my $t    = '';
		$string	.= '( ';

		foreach my $value (@$object) {

			$string .= $t . $self->toString($value, $indent + 1);
			$t = ', ';
		}

		$string	.= " )";

	} elsif (ref($object) eq 'HASH') {

		my $prefix = "    " x $indent;
		$string	.= "{\n";

		for my $key (sort keys %$object) {

			my $value = $object->{$key};

			$string .= $prefix . _quoteString($key);
			$string .= ' = ' . $self->toString($value, $indent + 1) if defined $value;
			$string .= ";\n";
		}

		$string	.= "    " x ($indent - 1) . '}';

	} else {

		return _quoteString($object, $indent + 1);
	}

	return $string;
}

sub _quoteString {
	my $string = shift;

	return '""' if $string eq '';
	return 0    if $string eq 0;

	my $s = $string;
	$s =~ s/[A-Za-z_0-9\.]*//;

	return $string if $s eq '';

	$string	=~ s/\\/\\\\/go;
	$string	=~ s/\"/\\\"/go;
	$string =~ s/\r/\\r/go;
	$string =~ s/\n/\\n/go;
	$string =~ s/\t/\\t/go;
	$string =~ s/\f/\\f/go;

	return "\"$string\"";
}

sub _parseString {
	my $string = shift;

	$string =~ s/\\n/\n/go;
	$string =~ s/\\r/\r/go;
	$string =~ s/\\t/\t/go;
	$string =~ s/\\f/\f/go;
	$string =~ s/\\([0-7]{3})/chr(oct($+))/geo;
	$string =~ s/\\(.)/$1/go;
	$string =~ s/^"(.*)"$/$1/go;

	return $string;
}

# 

sub _parseDictionaryContents {
	my $string = shift;
	my $flatKeysHashRef = shift;
	my $allKeysRef = shift;

	my %dictionary = ();

	while ($$string =~ s/$lineMatch//o) {

		# Is this a key or value? If it's a value, send it through _parseString()
		my $name  = defined $2 ? _parseString($2) : $1;
		my $value = undef;

		push(@$allKeysRef, $name);

		if ($$string =~ s/^\s*=\s*//o) {

			# Recursively match on subkeys with values.
			if ($$string =~ s/^\{\s*//o) {

				$value = _parseDictionaryContents($string, $flatKeysHashRef, $allKeysRef);

			} elsif ($$string =~ s/^\(\s*//o) {

				$value = _parseArrayContents($string);
				my $saveKey = join('.', @$allKeysRef);
				my $lcKey = lc($saveKey);
				$flatKeysHashRef->{$lcKey} = $saveKey;

			} elsif ($$string =~ s/$lineMatch//o) {

				$value  = defined $2 ? _parseString($2) : _parseString($1);
				my $saveKey = join('.', @$allKeysRef);
				my $lcKey = lc($saveKey);
				$flatKeysHashRef->{$lcKey} = $saveKey;
			}
		}

		if ($$string =~ s/^\s*;\s*//o) {

			$dictionary{$name} = $value;

		} else {

			# A plist value wasn't properly terminated with a trailing ;
			printf(STDERR "missing ; [%20s]\n", $name);
		}

		pop(@$allKeysRef);
	}

	$$string =~ s/^\s*\}\s*//o;

	return \%dictionary;
}

# Put each array element into a reference
sub _parseArrayContents {
	my $string = shift;

	my @array  = ();

	return \@array if $$string =~ s/^\s*\)\s*//o;

	my $value = _parseValue($string);

	push @array, $value;

	while ($$string =~ s/^\s*,\s*//o) {

		$value = _parseValue($string);

		push @array, $value;
	}

	$$string =~ s/^\s*\)\s*//o;

	return \@array;
}

sub _parseValue {
	my $string = shift;
	my $flatKeysHashRef = shift;
	my $allKeysRef = shift;

	my $value;

	# Recursively match on subkeys with values.
	if ($$string =~ s/$lineMatch//o) {

		return defined $2 ? _parseString($2) : _parseString($1);
	}

	# For every sub-structure we find, recurse into the tree.
	if ($$string =~ s/^\s*\(//o) {

		return (_parseArrayContents($string));

	}

	if ($$string =~ s/^\s*\{//o) {

		return (_parseDictionaryContents($string, $flatKeysHashRef, $allKeysRef));

	}


	return undef;
}

1;

__END__

=head1 AUTHORS

Adapted by: Dan Sully E<lt>dsully@ariba.comE<gt>

Original: Markus Felten E<lt>markus@arlac.rhein-main.deE<gt>

=head1 LICENSE

Copyright (c) 1995  Markus Felten E<lt>markus@arlac.rhein-main.deE<gt>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
