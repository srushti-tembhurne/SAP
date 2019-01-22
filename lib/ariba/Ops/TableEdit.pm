package ariba::Ops::TableEdit;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/TableEdit.pm#2 $

use strict;
use vars qw($text $string);

use Parse::RecDescent;
use Text::Balanced;
use ariba::Ops::PropertyList;

my $EOL;

# Ugh - println wants native line endings.
{
	if ($^O =~ /win32/i) {
		$EOL = "\015\012";
	} elsif ($^O =~ /macos/i || $^O =~ /darwin/) {
		$EOL = "\015";
	} else {
		$EOL = "\012";
	}
}

my %tables = ();

#$::RD_HINT  = 1;
#$::RD_TRACE = 1;

# AUTOACTION simplifies the creation of a parse tree by specifying an action 
# for each production (ie action is { [@item] })
$::RD_AUTOACTION = q{ [@item] };

my %handlers = (
	load                => \&handle_load,
	save                => \&handle_save,
	set                 => \&handle_set,
	print               => \&handle_print,
	println             => \&handle_print,
	printkeys           => \&handle_print,
	delete              => \&handle_delete,
	append              => \&handle_vector,
	prepend             => \&handle_vector,
	decode              => \&handle_encryption,
	encode              => \&handle_encryption,
	removeFromVector    => \&handle_vector,
	setIfEqual          => \&handle_setIfEqual,
	addToStringIfAbsent => \&handle_addToStringIfAbsent,
	removeFromString    => \&handle_removeFromString,
);

my $grammar = <<'EOGRAMMAR';

	command : 'load'                table value
		| 'save'                table value
		| 'set'                 table path 'value' data
		| 'println'             table path
		| 'printkeys'           table path
		| 'print'               table path
		| 'delete'              table path
		| 'append'              table path value vector_string
		| 'prepend'             table path value vector_string
		| 'removeFromVector'    table path value vector_string
		| 'decode'              table path
		| 'encode'              table path
		| 'setIfEqual'          table path 'original' value 'value' value
		| 'addToStringIfAbsent' table path 'value' value 'delimiter' value
		| 'removeFromString'    table path 'value' value 'delimiter' value
		| '__END__'

	table : string
	path  : string
	value : string
	data  : /.+/

	string: quoted_string
	      | bareword

	vector_string:
		{ my $string = Text::Balanced::extract_multiple($text, [
			\&extract_bracketed,
			\&extract_quotelike,
		  ], 1, 1);

		  substr $string, 2, length($string)-4 if $string;
		}

	quoted_string:
		{ my $string = extract_delimited($text,q{'"}); #'
		  substr $string, 1, length($string)-2 if $string;
		}

	bareword: /[\w_:\.-]+/

EOGRAMMAR

# Only parse the grammar once.
my $parser   = Parse::RecDescent->new($grammar) or die "Can't create new grammar: $!";

=head1 DESCRIPTION

Parser for the 'table edit' format.

The commands are made in this format:

command table path valuetype value

Where command is the verb that is to be executed, table is the current
hashtable that is being operated upon, path describes the part of the table or
where the table is. Valuetype and value are special extra arguments used by
the append and set commands, and describe the new data being put into the table.

Dotted field notation is used to refer to parts of the hashtable. This
works in the obvious way, descending through the hashtable as a tree. The only
subtlety is that vector elements are referred to by using an integer index (0
based) as the element key.

Here is an example script:

	load params RequisitionRules.rul
	println params Simples.0.Name
	set params Constraint.Name value MyNewName
	save params RequisitionRules.rul

Example API usage:

	ariba::Ops::TableEdit->processScript( $scriptFile )

The available commands are:

=cut

sub processScript {
	my $class = shift;
	my $file  = shift;

	my @commands = ();

	open(SCRIPT, $file) or die $!;

	while (my $line = <SCRIPT>) {
		push @commands, $parser->command($line);
	}

	close(SCRIPT);

	for my $command (@commands) {

		processCommand(@$command);
	}

	return 1;
}

sub processCommand {
	my @elems = @_;

	return unless @elems;
	return unless defined $elems[0];

	if (ref $elems[1]) {

		return processCommand(@{$elems[1]});

	} elsif (exists($handlers{$elems[1]})) {

		return $handlers{$elems[1]}->(@elems);
	}
}

sub _valueFromTree {
	my $tree = shift;

	# Recurse through the parse tree till we get a string value
	return $tree unless ref $tree;

	if (ref($tree->[1])) {
		return _valueFromTree($tree->[1]);
	} else {
		return $tree->[1];
	}
}

=over

=item load 

	load a table. The path argument is a relative path giving the
	location of the file that should be loaded. The table argument is the name of
	the loaded table (used in subsequent commands).

=back

=cut

sub handle_load {
	my ($nodeType, $command, $tableArray, $fileArray) = @_;

	# It'd be nice to simplify this - but it makes the grammar much more clutered
	my $table = _valueFromTree($tableArray);
	my $file  = _valueFromTree($fileArray);

	$tables{$table} = ariba::Ops::PropertyList->newFromFile($file);
}

=over

=item save

	save a table. The table argument is the name of the table to
	save, the path argument is a relative path giving the location of a file to
	write. Important: if the table file contains secure parameters, you will need
	to call encode before calling save.

=back

=cut

sub handle_save {
	my ($nodeType, $command, $tableArray, $fileArray) = @_;

	my $table = _valueFromTree($tableArray);
	my $file  = _valueFromTree($fileArray);
	
	# just call the PropertyList method to save
	$tables{$table}->writeToFile($file);
}

=over

=item print

	print some element of the table. The table argument is which
	table, the path argument gives the part of the table using dotted field
	notation (see below). This command can be used to print out a single element,
	a vector, or a hashtable.


=item println 

	print some element of the table, followed by a newline (properly interpreted for the platform).


=item printkeys 

	print the keys of some part of the table. The table argument
	is which table, the path gives the part of the table using dotted field
	notation. This command prints out the keys at the top level for the indicated
	part of the table, expected to be a hashtable or vector. If the part is a
	vector, the "keys" are simply the indices which are available.

=back

=cut

sub handle_print {
	my ($nodeType, $command, $tableArray, $pathArray) = @_;

	my $table = _valueFromTree($tableArray);
	my $path  = _valueFromTree($pathArray);

	my $value = $tables{$table}->valueForKeyPath($path);
	my $eol   = $command eq 'println' ? $EOL : '';

	# print & println are almost identical
	if ($command eq 'print' || $command eq 'println') {

		print $tables{$table}->toString($value) . $eol;
		return;
	}

	# and now the printkeys case
	if (ref($value) eq 'ARRAY') {

		for (my $i = 0; $i < scalar @$value; $i++) {
			print "$i ";
		}

		print $EOL;

	} elsif (ref($value) eq 'HASH') {

		for my $key (sort keys %$value) {
			print $key . $EOL;
		}
	}
}

=over

=item set

	set a value. The table argument is which table, the path argument
	is which part of the table, using dotted field notation. This command also
	takes the valuetype and value arguments. The valuetype argument can be either
	"value" or "table". If the valuetype is "value", then a single string value is
	expected. If it is "table" then the value is the name of a previously loaded
	table followed by the path which gives the part of the table to be used.

=back

=cut

sub handle_set {
	my ($nodeType, $command, $tableArray, $pathArray, $type, $valueArray) = @_;

	my $table = _valueFromTree($tableArray);
	my $path  = _valueFromTree($pathArray);
	my $value = _valueFromTree($valueArray);

	# Pull the value from another table
	if ($type ne 'value') {
		$value = $tables{$type}->valueForKeyPath($value)
	}

	# Value can be a complex type like: { Foo = Bar; }
	if ($value =~ /^\s*[\{\(]/) {
		my $parsedValue = ariba::Ops::PropertyList->new($value);

		$tables{$table}->setValueForKeyPath($path, $parsedValue->valueForKeyPath());

	} else {
		$tables{$table}->setValueForKeyPath($path, $value);
	}
}

=over

=item append

	add values to a vector in the table. The table argument is
	which table, the path indicates what vector should be added to. This command
	takes a valuetype argument of either "value" or "table". If valuetype is
	"value", then value is a simple string. If it is "table", then value is the
	name of a previously loaded table followed by the path which gives the part of
	the table to be used.


=item prepend

	append values to a vector in the table. The table argument is
	which table, the path indicates what vector should be added to. This command
	takes a valuetype argument of either "value" or "table". If valuetype is
	"value", then value is a simple string. If it is "table", then value is the
	name of a previously loaded table followed by the path which gives the part of
	the table to be used.

=item removeFromVector 

	removes a value from a vector. The table argument is
	which table, the path indicates what vector should be added to. This command
	only takes a valuetype argument of either "value".

	Example: removeFromVector params Simples.0.Name value ("value")
	  (Removes String "value" from the list, which is the value of the key Simples.0.Name)

=back

=cut

sub handle_vector {
	my ($nodeType, $command, $tableArray, $pathArray, $valueOrTable, $valueArray) = @_;

	my $table = _valueFromTree($tableArray);
	my $path  = _valueFromTree($pathArray);
	my $type  = _valueFromTree($valueOrTable);
	my $value = _valueFromTree($valueArray);

	if ($type eq 'value') {

		# This is just a simple string value here.
		my $vector = $tables{$table}->valueForKeyPath($path) || [];

		if ($command eq 'append') {

			push(@$vector, $value);

		} elsif ($command eq 'prepend') {

			unshift(@$vector, $value);

		} elsif ($command eq 'removeFromVector') {

			# weed out the value
			@$vector = grep { ! /^$value$/ } @$vector;
		}

		$tables{$table}->setValueForKeyPath($path, $vector);

		return;
	}

	# The is really pointing to another table.
	# So $type is that tablename, and $value is the path
	my $foreign = $tables{$type}->valueForKeyPath($value);

	my $vector  = $tables{$table}->valueForKeyPath($path) || [];

	if ($command eq 'append') {

		push(@$vector, $foreign);

	} elsif ($command eq 'prepend') {

		unshift(@$vector, $foreign);
	}

	$tables{$table}->setValueForKeyPath($path, $vector);
}

=over

=item delete 

	delete a value, or branch of the hashtable. The table argument
	is which table, the path is which part of the table to be deleted, using
	dotted field notation.

=back

=cut

sub handle_delete {
	my ($nodeType, $command, $tableArray, $pathArray) = @_;

	my $table = _valueFromTree($tableArray);
	my $path  = _valueFromTree($pathArray);

	$tables{$table}->deleteKeyPath($path);
}

=over

=item decode 

	decode the secure elements of a table. The table argument
	specifies which table, the path argument specifies an element of the table
	that contains a list of secure elements. The path argument is specified using
	dotted field notation.

=item encode

	encode the secure elements in memory. This should be called
	prior to saving the parameters to file so that the values are encrypted.

        Syntax: encode , where table specifies the table, secureParamKey is a
	key whose value is a list of keys whose values are to be encrypted.

        Example: encode params "System.Base.SecureParameters" 

=back

=cut

sub handle_encryption {
	my ($nodeType, $command, $tableArray, $pathArray) = @_;

	warn "$command not yet implemented!";
}

=over

=item setIfEqual - set a value if the existing value is same specified in the command.

      Example: setIfEqual params Simples.0.Name original oldValue value newValue

      (Set Simples.0.Name to "NewValue" if Simples.0.Name is equals
	"OldValue") This command also takes the valuetype and value arguments. The
	valuetype argument can only be "value".

=back

=cut

sub handle_setIfEqual {
	my ($nodeType, $command, $tableArray, $pathArray, undef, $oldValueArray, undef, $newValueArray) = @_;

	my $table  = _valueFromTree($tableArray);
	my $path   = _valueFromTree($pathArray);
	my $oldVal = _valueFromTree($oldValueArray);
	my $newVal = _valueFromTree($newValueArray);

	my $curVal = $tables{$table}->valueForKeyPath($path);

	if ($curVal eq $oldVal) {
		
		$tables{$table}->setValueForKeyPath($path, $newVal);
	}
}

=over

=item addToStringIfAbsent

	add a string to a list of strings separated by a specified delimiter.

	Example: addToStringIfAbsent params Simples.1.Name value "TestValue" delimiter ":" 

	(Appends the String "TestValue" to the value of the key Simples.1.Name
		if it is not in the list using the separator ":")

=back

=cut

sub handle_addToStringIfAbsent {
	my ($nodeType, $command, $tableArray, $pathArray, undef, $valueArray, undef, $delimArray) = @_;

	my $table = _valueFromTree($tableArray);
	my $path  = _valueFromTree($pathArray);
	my $value = _valueFromTree($valueArray);
	my $delim = _valueFromTree($delimArray);

	# 
	my @parts = ();
	my $found = 0;

	for my $part (split(/$delim/, $tables{$table}->valueForKeyPath($path))) {

		# The value already exists in the path.
		# Bail, but don't add it.
		if ($part eq $value) {
			$found = 1;
			last;
		}

		push @parts, $part;
	}

	# Save the newly appended string
	unless ($found) {

		push @parts, $value;

		$tables{$table}->setValueForKeyPath($path, join($delim, @parts));
	}
}

=over

=item removeFromString

	remove a string from a list of strings separated by a specified delimiter.

	Example: removeFromString params Simples.2.Name value "Value2" delimiter "."

	(Removes the element "Value2" from a list defined in a String. The elements are separated by ".")

=back

=cut

sub handle_removeFromString {
	my ($nodeType, $command, $tableArray, $pathArray, undef, $valueArray, undef, $delimArray) = @_;

	my $table = _valueFromTree($tableArray);
	my $path  = _valueFromTree($pathArray);
	my $value = _valueFromTree($valueArray);
	my $delim = _valueFromTree($delimArray);

	#
	my @parts = ();

	for my $part (split(/$delim/, $tables{$table}->valueForKeyPath($path))) {

		# The value already exists in the path.
		# Bail, but don't add it.
		next if $part eq $value;

		push @parts, $part;
	}

	$tables{$table}->setValueForKeyPath($path, join($delim, @parts));
}

1;

__END__
