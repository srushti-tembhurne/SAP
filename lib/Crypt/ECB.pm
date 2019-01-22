package Crypt::ECB;

# Copyright (C) 2000  Christoph Appel, cappel@debis.com
#  see documentation for details


########################################
# general module startup things
########################################

use strict;
use vars qw(@ISA @EXPORT @EXPORT_OK $VERSION);

require Exporter;

@ISA       = qw(Exporter);
@EXPORT    = qw(PADDING_NONE PADDING_AUTO);
@EXPORT_OK = qw(encrypt decrypt encrypt_hex decrypt_hex);
$VERSION   = 1.10;

use constant PADDING_NONE => 0;
use constant PADDING_AUTO => 1;


########################################
# basic methods
########################################

#
# constructor, initialization of vars
#
sub new ($;$$$)
{
    my $class = shift;
    my $crypt =
    {
	# the following could be read by another program
	Caching   => '1', # caching is on by default
	Padding   => '0', # padding off by default
	Mode      => '',
	Key       => '',
	Cipher    => '',
	Module    => '',
	Keysize   => '',
	Blocksize => '',
	Errstring => '',

	# the following should not be read by someone else
	buffer    => '', # internal buffer used by crypt() and finish()

	# only used by _getcipher
	cipherobj => '', # contains the cipher object if caching
	oldKey    => '',
	oldCipher => '',
    };

    bless $crypt, $class;

    # the following is for compatibility with Crypt::CBC
    if (@_) {
	$crypt->key(shift);
	$crypt->cipher(shift || 'DES');
    }

    return $crypt;
}

#
# sets key if argument given
# returns key
#
sub key (\$;$)
{
    my $crypt = shift;
    $crypt->{Key} = shift if @_;
    return $crypt->{Key};
}

#
# sets caching, returns caching mode
#
sub caching (\$;$)
{
    my $crypt = shift;
    $crypt->{Caching} = shift if @_;
    return $crypt->{Caching};
}

#
# sets padding mode, returns mode
#
sub padding (\$;$)
{
    my $crypt = shift;
    $crypt->{Padding} = shift if @_;
    return $crypt->{Padding};
}

#
# sets and loads crypting module if argument given
# returns module name
#
sub cipher (\$;$)
{
    my $crypt = shift;

    if (my $cipher = shift)
    {
	# for compatibility with Crypt::CBC cipher modules
	# can be specified with the 'Crypt::' in front
	my $module = $cipher=~/^Crypt/ ?
	    $cipher : "Crypt::$cipher";

	eval "require $module";
	if ($@)
	{
	    $crypt->{Errstring} = "Couldn't load $module: $@"
		. "Are you sure '$cipher' is correct? If so,"
		. " install $module in the proper path or"
		. " choose some other cipher.\n";
	    return 0;
	}

	# some packages like Crypt::DES and Crypt::IDEA behave
	# strange in the way that their methods do not belong to
	# Crypt::DES or Crypt::IDEA but only DES or IDEA instead
	unless ($module->can('blocksize')) { $module=$cipher }

	unless ($module->can('blocksize'))
	{
	    $crypt->{Errstring} =
		"Can't work because Crypt::$cipher doesn't report"
		    . " blocksize. Are you sure $cipher is a valid"
		    . " crypting module?\n";
	    return 0;
	}

	$crypt->{Blocksize} = $module->blocksize;

	# In opposition to the blocksize, the keysize need not be
	# known by me, but by the one who provides the key. This
	# is because some modules (Crypt::Blowfish) report keysize
	# is 0, in other cases several keysizes are admitted, so
	# reporting just one number would anyway be to narrow
	$crypt->{Keysize} =
	    $module->can('keysize') ? 
	    $module->keysize : '';

	$crypt->{Cipher} = $cipher;
	$crypt->{Module} = $module;
    }

    $crypt->{Errstring} = '';
    return $crypt->{Cipher};
}

#
# sets mode if argument given, either en- or decrypt
# checks, whether all required vars are set
# returns mode
#
sub start (\$$)
{
    my $crypt = shift;
    my $mode  = shift;

    unless ($mode=~/^[de]/i)
    {
	$crypt->{Errstring} = 
	    "Mode has to be either (e)ncrypt or (d)ecrypt.\n";
	return 0;
    }

    $crypt->{Mode} = ($mode=~/^d/i) ? "decrypt" : "encrypt";
        # checks whether $mode starts with either d or e,
        # only first character matters, rest of $mode is ignored

    unless ($crypt->{Key}) {
	$crypt->{Errstring} = "Key not set. Use '\$your_obj->key"
	    . "('some_key'). The key length is probably specified"
	    . " by the algorithm (for example the Crypt::Blowfish"
            . " module needs an eight byte key).\n";
	return 0;
    }

    unless ($crypt->{Module}) {
	$crypt->{Errstring} = "Cipher not set."
	    . " Use '\$your_obj->cipher(\$cipher)', \$cipher being"
	    . " some algorithm like for example 'DES', 'IDEA' or"
	    . " 'Blowfish'. The corresponding module 'Crypt::"
	    . "\$cipher' has to be installed.\n";
	return 0;
    }

    if ($crypt->{buffer}) {
	$crypt->{Errstring} = "Not yet finished existing crypting"
	    . " process. Call finish() before calling start() anew.\n";
	return 0;
    }

    $crypt->{Errstring} = '';
    return $crypt->{Mode};
}

#
# returns mode
#
sub mode (\$)
{
    my $crypt = shift;
    return $crypt->{Mode};
}

#
# calls the crypting module
# returns the en-/decrypted data
#
sub crypt (\$;$)
{
    my $crypt = shift;
    my $data  = shift || $_ || '';

    my $errmsg = $crypt->{Errstring};
    my $bs     = $crypt->{Blocksize};
    my $mode   = $crypt->{Mode};

    die $errmsg if $errmsg;

    unless ($mode)
    {
	die "You tried to use crypt() without calling start()"
	  . " before. Use '\$your_obj->start(\$mode)' first,"
	  . " \$mode being one of 'decrypt' or 'encrypt'.\n";
    }

    $data = $crypt->{buffer}.$data;

    # data is split into blocks of proper size which is reported
    # by the cipher module
    my @blocks = $data=~/(.{1,$bs})/gs;

    $crypt->{buffer} = pop @blocks;

    my $cipher = $crypt->_getcipher;
    my $text = '';
    foreach my $block (@blocks) {
	$text .= $cipher->$mode($block);
    }
    return $text;
}

#
#
#
sub finish (\$)
{
    my $crypt = shift;

    my $errmsg = $crypt->{Errstring};
    my $bs     = $crypt->{Blocksize};
    my $mode   = $crypt->{Mode};
    my $data   = $crypt->{buffer};
    my $result = '';

    die $errmsg if $errmsg;

    unless ($mode)
    {
	die "You tried to use crypt() without calling start()"
	  . " before. Use '\$your_obj->start(\$mode)' first,"
	  . " \$mode being one of 'decrypt' or 'encrypt'.\n";
    }

    $crypt->{Mode}   = '';
    $crypt->{buffer} = '';

    return '' unless $data;

    my $cipher = $crypt->_getcipher;

    # now we have to distinguish between en- and decrypting
    # when decrypting, data has to be truncated to correct size
    # when encrypting, data has to be padded up to blocksize
    if ($mode =~ /^d/i)
    {
	# pad data with binary 0 up to blocksize
	# in fact, this should not be necessary because correctly
	# encrypted data is always a multiple of the blocksize
	$data = pack("a$bs",$data);

	$result = $cipher->$mode($data);
	$result = $crypt->_truncate($result);
    }
    else
    {
	# if length is smaller than blocksize, just pad the block
	if (length($data) < $bs)
	{
	    $data = $crypt->_pad($data);
	    $result = $cipher->$mode($data);
	}
	# else append (if necessary) a full block
	else
	{
	    $result = $cipher->$mode($data);
	    $crypt->_pad('') &&
		($result .= $cipher->$mode($crypt->_pad('')));
	}
    }

    return $result;
}

#
# truncates result to correct length
#
sub _truncate (\$$)
{
    my $crypt  = shift;
    my $result = shift;

    my $padstyle = $crypt->{Padding};

    if ($padstyle == PADDING_NONE)
    {
	# no action
    }
    # PADDING_AUTO means padding as in Crypt::CBC
    elsif ($padstyle == PADDING_AUTO)
    {
	substr($result,-unpack("C",substr($result,-1))) = '';	
    }
    else
    {
	die "Padding style '$padstyle' not defined.\n";
    }

    return $result;
}

#
# pad block to blocksize
#
sub _pad (\$$)
{
    my $crypt = shift;
    my $data  = shift;

    my $bs       = $crypt->{Blocksize};
    my $padstyle = $crypt->{Padding};

    if ($padstyle == PADDING_NONE)
    {
	if (length($data) % $bs)
	{
	    die "Your message length is not a multiple of"
              . " $crypt->{Cipher}'s blocksize ($bs bytes)."
	      . " Correct this by hand or tell me to handle"
	      . " padding.\n";
	}
    }
    elsif ($padstyle == PADDING_AUTO)
    {
	$data .= pack("C*",($bs-length($data))x($bs-length($data)));
    }
    else
    {
	die "Padding style '$padstyle' not defined.\n";
    }

    return $data;
}

#
# returns a cipher object, handles caching
#
sub _getcipher (\$)
{
    my $crypt = shift;

    if ($crypt->{Caching})
    {
	# create a new cipher object is necessary
	unless ($crypt->{cipherobj} &&
		$crypt->{oldKey}    eq $crypt->{Key} &&
		$crypt->{oldCipher} eq $crypt->{Cipher})
	{
	    $crypt->{cipherobj} = $crypt->{Module}->new($crypt->{Key});
	    $crypt->{oldKey}    = $crypt->{Key};
	    $crypt->{oldCipher} = $crypt->{Cipher};
	}
	return $crypt->{cipherobj};
    }
    else
    {
	$crypt->{cipherobj} = '';
	return $crypt->{Module}->new($crypt->{Key});
    }
}

#
# returns errstring
#
sub errstring (\$)
{
    my $crypt = shift;
    return $crypt->{Errstring};
}


########################################
# convenience functions/methods
########################################

#
# magic convenience encrypt function/method
#
sub encrypt ($$;$$)
{
    if (ref($_[0]) =~ /^Crypt/)
    {
	my $crypt = shift;

	$crypt->start('encrypt') || die $crypt->errstring;

	my $text = $crypt->crypt(shift)
	         . $crypt->finish;

	return $text;
    }
    else
    {
	my ($key, $cipher, $data, $padstyle) = @_;

	my $crypt = Crypt::ECB->new($key);

	$crypt->padding($padstyle || 0);
	$crypt->cipher($cipher)  || die $crypt->errstring;
	$crypt->start('encrypt') || die $crypt->errstring;

	my $text = $crypt->crypt($data || $_)
	         . $crypt->finish;

	return $text;
    }
}

#
# magic convenience decrypt function/method
#
sub decrypt ($$;$$)
{
    if (ref($_[0]) =~ /^Crypt/)
    {
	my $crypt = shift;

	$crypt->start('decrypt') || die $crypt->errstring;

	my $text = $crypt->crypt(shift)
	         . $crypt->finish;

	return $text;
    }
    else
    {
	my ($key, $cipher, $data, $padstyle) = @_;

	my $crypt = Crypt::ECB->new($key);

	$crypt->padding($padstyle || 0);
	$crypt->cipher($cipher)  || die $crypt->errstring;
	$crypt->start('decrypt') || die $crypt->errstring;

	my $text = $crypt->crypt($data || $_)
	         . $crypt->finish;

	return $text;
    }
}

#
# calls encrypt, returns hex packed data
#
sub encrypt_hex ($$;$$)
{
    if (ref($_[0]) =~ /^Crypt/)
    {
	my $crypt = shift;
	join('',unpack('H*',$crypt->encrypt(shift)));
    }
    else
    {
	join('',unpack('H*',encrypt($_[0], $_[1], $_[2], $_[3])));
    }
}

#
# calls decrypt, expected input is hex packed
#
sub decrypt_hex ($$;$$)
{
    if (ref($_[0]) =~ /^Crypt/)
    {
	my $crypt = shift;
	$crypt->decrypt(pack('H*',shift));
    }
    else
    {
	decrypt($_[0], $_[1], pack('H*',$_[2]), $_[3]);
    }
}


########################################
# finally, to satisfy require
########################################

1;
__END__


=head1 NAME

Crypt::ECB - Encrypt Data using ECB Mode

=head1 SYNOPSIS

Use Crypt::ECB OO style

  use Crypt::ECB;

  $crypt = Crypt::ECB->new;
  $crypt->padding(PADDING_AUTO);
  $crypt->cipher("Blowfish") || die $crypt->errstring;
  $crypt->key("some_key"); 

  $enc = $crypt->encrypt("Some data.");
  print $crypt->decrypt($enc);

or use the function style interface

  use Crypt::ECB qw(encrypt decrypt encrypt_hex decrypt_hex);

  $ciphertext = encrypt($key2, "Blowfish", "Some data", PADDING_AUTO);
  $plaintext  = decrypt($key2, "Blowfish", $ciphertext, PADDING_AUTO);

  $hexcode = encrypt_hex("foo_key", "IDEA", $plaintext);
  $plain   = decrypt_hex("foo_key", "IDEA", "A01B45BC");

=head1 DESCRIPTION

This module is a Perl-only implementation of the ECB mode.  In
combination with a block cipher such as DES, IDEA or Blowfish, you can
encrypt and decrypt messages of arbitrarily long length.  Though for
security reasons other modes than ECB such as CBC should be preferred.
See textbooks on cryptography if you want to know why.

The functionality of the module can be accessed via OO methods or via
standard function calls.  Remember that some crypting module like for
example Blowfish has to be installed.  The syntax follows that of
Crypt::CBC meaning you can access Crypt::ECB exactly like Crypt::CBC,
though Crypt::ECB is more flexible.  For example you can change the key
or the cipher without having to create a new crypt object.

=head1 METHODS

=head2 new(), key(), cipher(), padding()

  $crypt = Crypt::ECB->new;
  $crypt->key("Some_key");
  $crypt->cipher("Blowfish") || die $crypt->errstring;
  $crypt->padding(PADDING_AUTO);

  print $crypt->key;
  print $crypt->cipher;
  print $crypt->padding;

  $crypt = Crypt::ECB->new("Some_key","Blowfish");
  $crypt->cipher || die "'Blowfish' wasn't loaded for some reason.";

B<new()> initializes the variables it uses.  Optional parameters are
key and cipher.  If called without parameters you have to call B<key()>
and B<cipher()> before you can start crypting.  If called with key but
without cipher, for compatibility with Crypt::CBC 'DES' is assumed.

B<key()> sets the key if given a parameter.  It always returns the
key.  Note that some crypting modules require keys of definite length.
For example the Crypt::Blowfish module expects an eight byte key.

B<cipher()> sets the block cipher to be used if given a parameter.
It tries to load the corresponding module.  If an error occurs, it
returns 0 and sets $crypt->{Errstring}.  Otherwise it returns the
cipher name.  Free packages available for Perl are for example
Blowfish, DES or IDEA. If called without parameter it just returns
the name of the cipher.

B<padding()> sets the way how data is padded up to a multiple of the
cipher's blocksize.  Until now two ways are implemented: When set to
PADDING_NONE, no padding is done.  You then have to take
care of correct padding (and truncating) yourself. When set to
PADDING_AUTO, the ECB module handles padding (and truncating
when decrypting) the same way Crypt::CBC does.

By default the padding style is set to PADDING_NONE.  This means if you
don't bother and your data has not the correct length, the module will
complain and therefore force you to think about what you really want.

=head2 start(), mode(), crypt(), finish()

  $crypt->start('encrypt') || die $crypt->errstring;
  $enc  = $crypt->crypt($data1)
       . $crypt->crypt($data2)
       . $crypt->finish;

  $crypt->start('decrypt');
  print $crypt->mode;

B<start()> sets the crypting mode and checks if all required variables
like key and cipher are set.  Allowed parameters are any words
starting either with 'e' or 'd'.  The Method returns the mode which is
set or 0 if an error occurred.

B<mode()> is called without parameters and just returns the mode which
is set.

B<crypt()> processes the data given as argument.  If called without
argument $_ is processed.  The method returns the processed data.
Cipher and key have to be set in order to be able to process data.
If some of these are missing or B<start()> was not called before,
the method dies.

After having sent all data to be processed to B<crypt()> you have to
call B<finish()> in order to flush data that's left in the buffer.

=head2 caching()

  $crypt->caching(1); # caching on
  $crypt->caching(0); # caching off

  print $crypt->caching;

The caching mode is returned.  If given an argument caching mode is set.
Caching is on if B<caching()> evaluates true, otherwise caching is off.
By default caching is on.

What is this caching?  The Crypt::ECB module communicates with the
cipher module via some object.  Creating the cipher object takes some time
for the cipher module has to do some initialization.  Now caching means
that the same cipher object is used until caching is turned off or the
key or the cipher module are changed.  If caching is off, a new cipher
object is created is created each time B<crypt()> or B<finish()> are
called and destroyed at the end of these methods.  Crypting using
caching is B<much> faster than without caching.

=head2 encrypt(), decrypt(), encrypt_hex(), decrypt_hex()

  $enc = $crypt->encrypt($data);
  print $crypt->decrypt($enc);

  $hexenc = $crypt->encrypt_hex($data);
  print $crypt->decrypt_hex($hexenc);

B<encrypt()> and B<decrypt()> are convenience methods which call
B<start()>, B<crypt()> and B<finish()> for you.

B<encrypt_hex()> and B<decrypt_hex()> are convenience functions
that operate on ciphertext in a hexadecimal representation.  They are
exactly equivalent to

  $hexenc = join('',unpack('H*',$crypt->encrypt($data)));
  print $crypt->decrypt(pack('H*',$hexenc));

These functions can be useful if, for example, you wish to place
the encrypted information into an e-mail message, Web page or URL.

=head2 errstring()

  print $crypt->errstring;

Some methods like B<cipher()> or B<start()> return 0 if an error
occurs.  You can then retrieve a more detailed error message by
calling $crypt->errstring.

=head1 VARIABLES

Variables which could be of interest to the outside world are:

  $crypt->{Key},
  $crypt->{Cipher},
  $crypt->{Module},
  $crypt->{Keysize},
  $crypt->{Blocksize},
  $crypt->{Mode},
  $crypt->{Caching},
  $crypt->{Padding},
  $crypt->{Errstring}.

The variables should not be set directly, use instead the above
described methods.  Reading should not pose a problem, but is also
provided by the above methods.

=head1 CONSTANTS

The two constants naming the padding styles are exported by default:

  PADDING_NONE => 0
  PADDING_AUTO => 1

=head1 FUNCTIONS

For convenience en- or decrypting can also be done by calling ordinary
functions.  The functions are: B<encrypt()>, B<decrypt()>,
B<encrypt_hex>, B<decrypt_hex>.  The module is smart enough to
recognize whether these functions are called in an OO context or not.

=head2 encrypt(), decrypt(), encrypt_hex(), decrypt_hex()

  $ciphertext = encrypt($key, $cipher, $plaintext, PADDING_AUTO);
  $plaintext  = decrypt($key, $cipher, $ciphertext, PADDING_AUTO);

  $ciphertext = encrypt_hex($key, $cipher, $plaintext, PADDING_AUTO);
  $plaintext  = decrypt_hex($key, $cipher, $ciphertext, PADDING_AUTO);

B<encrypt()> and B<decrypt()> process the provided text and return either the
corresponding ciphertext (encrypt) or plaintext (decrypt).  Data
and padstyle are optional, but remember that by default no padding
is done.  If data is omitted, $_ is assumed.

B<encrypt_hex()> and B<decrypt_hex()> operate on ciphertext in a
hexadecimal representation. Otherwise usage is the same as for
B<encrypt()> and B<decrypt()>.

=head1 BUGS

None that I know of.

=head1 TODO

The other block cipher modes CBC, CFB and OFB could be implemented.

Convenience encrypt and decrypt functions utilizing base64 encoding
could be added.

=head1 COPYING

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.

=head1 AUTHOR

Christoph Appel, cappel@debis.com

=head1 SEE ALSO

perl(1), Crypt::DES(3), Crypt::IDEA(3), Crypt::CBC(3)

=cut
