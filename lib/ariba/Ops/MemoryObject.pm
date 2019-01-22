package ariba::Ops::MemoryObject;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/MemoryObject.pm#3 $
#
# this module provides a way to have a generic non serializable object.
# It also provides a class method to get bunch of these setup in the
# cache from a stream. Following format are currently supported:
#
# ---- format 1
# key1: value1
# key2: value2
# # new rec seperated by new lines
#
# key1: value3
# key2: value4
# key3: <MULTILINE>
#  multiple line value
#  is added inside this
#  special tag
# </MULTILINE>
#
# ---- format 2
#
# TEMPLATE: key1, key2, key3
# # records fully specified on single line
# val1, val2, val3
# val4, val5, val6
#
# ---- format 3
#
# # record definition and records defined in multiline format
# BEGIN TEMPLATE
# key1
# key2
# key3
# END TEMPLATE
#
# val1
# val2
# val3 is long \
# contine here
#
# val1
# val5
# val6
#
#

use strict;
use vars qw(@ISA);
use ariba::Ops::PersistantObject;
use FileHandle;

@ISA = qw(ariba::Ops::PersistantObject);

my $objId = "000";
my $colSeparator = ",";
my $keyValSeparator = ":";
my $beginTemplate = "BEGIN TEMPLATE";
my $endTemplate = "END TEMPLATE";
my $template = "TEMPLATE:";

my $streamLineCallback = undef;

# class methods
sub dir 
{
	my $class = shift;

	# don't have a backing store
	return undef;
}


sub _createObject
{
    my $class = shift;
    my ($keys, $values) = @_;

    if ($#{$keys} != $#{$values}) {
	return undef;
    }

    my $name = $values->[0] . $objId;
    $objId++;

    my $obj = $class->SUPER::new($name);

    for (my $i = 0; $i <= $#{$keys}; $i++) {
	$obj->setAttribute($keys->[$i],$values->[$i]);
    }
    #$obj->print;

    return $obj;

}

sub setStreamLineCallback
{
    my $class = shift;
    $streamLineCallback = shift;
}

sub createObjectsFromStream
{
	my $class = shift;
        my $fh = shift;
	my $readUntil = shift;

	my @objectsCreated = ();

	my (@recordKeys, @recordValues, $keyId);
	my ($fileFormat, $line);

	while ( ($line = $fh->getline()) ) {
	    if (defined($readUntil) && $line =~ m|$readUntil|) {
		last;
	    }

	    #
	    # skip blank and comment lines
	    #
	    next if ( !$fileFormat && $line =~ /^\s*$/o );
	    next if ( $line =~ /^\s*#/o) ;

	    #
	    # cleanup and expand line
	    #
	    chomp($line);               # remove \n
	    $line =~ s/\r\n//g;         # remove ^M
	    $line =~ s/([^#]*)#.*/$1/g; # allow inline comments
	    $line =~ s/\s*$//g;         # remove trailing spaces
	    $line =~ s/^\s*//g;         # remove leading spaces

	    if (defined($streamLineCallback)) {
		$line = &$streamLineCallback($line);
		if (!defined($line)) {
		    next;
		}
	    }

	    #
	    # Figure out record definition format
	    #
	    if (!$fileFormat) {
		if ($line =~ /^\s*$beginTemplate/o) {
		    $fileFormat = "define-multiline-template";
		    @recordKeys = ();
		    next;
		} elsif ($line =~ /^\s*$template/o) {
		    $line =~ s|^\s*$template\s*||o;
		    @recordKeys = split(/\s*$colSeparator\s*/, $line);
		    $fileFormat = "define-singleline-record";
		    next;
		} elsif ($line =~ /\s*(\S*)\s*$keyValSeparator\s*(\S*)/o ) {
		    $fileFormat = "define-key-value-pairs";
		    $keyId = 0;
		}
	    }

	    if ($fileFormat && $fileFormat eq "define-multiline-template") {
		if ($line =~ /^\s*$endTemplate/o) {
		    $fileFormat = "define-multiline-record";
		    $keyId = 0;
		} elsif ($line !~ m|^\s*$|o) {
		    push (@recordKeys, $line);
		}
		next;
	    }

	    #
	    # for single line record, just process the line and move on
	    #
	    if ($fileFormat && $fileFormat eq "define-singleline-record") {
		# skip blank lines
		if ($line =~ m|^\s*$|o) {
		    next;
		}
		@recordValues = split(/\s*$colSeparator\s*/, $line);

		my $obj = $class->_createObject(\@recordKeys, \@recordValues);
		push(@objectsCreated, $obj);

		@recordValues = (); 
		next;
	    }

	    #
	    # for multiline records, wait for a new line
	    #
	    if ($line =~ m|^\s*$|o) {

		if ($keyId > 0 && $fileFormat && $fileFormat eq "define-key-value-pairs") {
		    my $obj = $class->_createObject(\@recordKeys, 
						    \@recordValues);
		    push(@objectsCreated, $obj);

		    @recordValues = ();
		    @recordKeys = ();
		    $keyId = 0;
		}

		next;
	    }

	    if ($fileFormat && $fileFormat eq "define-multiline-record") {

		$recordValues[$keyId] .= $line;

		if ($recordValues[$keyId] =~ m|\\\s*$|o) {
		    $recordValues[$keyId] =~ s|\\\s*$||o;
		} else {
		    $keyId++;
		}

		if( $keyId > $#recordKeys) {
		    my $obj = $class->_createObject(\@recordKeys, 
						    \@recordValues);
		    push(@objectsCreated, $obj);
		    @recordValues = ();
		    $keyId = 0;
		}

	    } elsif ($fileFormat && $fileFormat eq "define-key-value-pairs") {
		my ($key, $value) = split(/\s*$keyValSeparator\s*/, $line);
		# allow multiline values
		if ( $value eq "<MULTILINE>" ){
			my $readTo = $/;
			$/ = "</MULTILINE>\n";
			$value = $fh->getline();
			$/ = $readTo;
			$value =~ s|</MULTILINE>\n?$||o;
		}
		push(@recordKeys, $key);
		push(@recordValues, $value);
		$keyId++;
	    }

	}

	return \@objectsCreated;
}

1;
