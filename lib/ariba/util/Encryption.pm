#
# Cover for perl based Blowfish, allowing use of any size plaintext input, and
# returning uuencoded ciphers for easy storage inside of variables, etc.
#
#
# $Id: //ariba/services/tools/lib/perl/ariba/util/Encryption.pm#20 $
#
# API:
#
# Following API calls implement blowfish with md5 based salt for
# encryption. This is used by all network products:
# AN, AMNE, FX, EDI, PERF etc. 
#-----------------------------------------------------------------------
# 
# init()
# encodingBase64(): returns string to indicate encoding type of base64
# encodingUuencoded(): returns string to indicate encoding type of uuencoded
# allEncodings(): returns an array of all available encoding types
# 
# encryptToBinary($plain): returns binary cipher string
# encryptToUU($plain): returns uuencoded cipher string
# encryptToBase64($plain): return base64 encoded cipher string
# encrypt($plain, $encoding): returns cipher string encoded using 
#                         $encoding (default base64)
# 
# decryptBinary($cipher): decrypts binary cipher to plain text
# decryptUU($cipher): decrypts uuencoded cipher to plain text
# decryptBase64($cipher): decrypts base64 encoded cipher to plain text
# decrypt($cipher, $encoding): decrypts $encoding (default base64) encoded 
#                          cipher to plain text
# 
#
# Following API calls implement PBE (DES-MD5/CBC/PKCS5) for
# encryption. This is used by sourcing product prior to 4.1.0 release:
#-----------------------------------------------------------------------
# pbeInit ($key $salt $iteration)
# pbeEncryptToBinary ($plaintext)
# pbeEncryptToBase64 ($plaintext)
# pbeDecryptBinary ($ciphertext)
# pbeDecryptBase64 ($b64Ciphertext)
#
#
# Following API calls implement DES-EDE3 mode for
# encryption. This is used by all products that use 
# platform code for encryption:
# Sourcing >= 5.0
#-----------------------------------------------------------------------
# ede3Init ($key)
# isDES3Encrypted ($cipherText)
# des3EncryptToBinary ($plaintext)
# des3EncryptToBase64 ($plaintext)
# des3DecryptBinary ($ciphertext)
# des3DecryptBase64 ($b64Ciphertext)

package ariba::util::Encryption;

use strict;
use Crypt::Blowfish;
use Crypt::CBC;
use Crypt::DES;
use Crypt::DES_EDE3;
use Crypt::ECB;
use Crypt::Rijndael;
use Digest::MD5;
use MIME::Base64 ();

#use constant PADDING_AUTO => 1;  #Perl5.22 comapatibilty for Crypt::ECB

my $base64     = "base64";
my $uuencoded  = "uuencoded";

my @encodings  = ($base64, $uuencoded);

my $des3Prefix = '{DESede}';

my $suppressWarning = 1;

sub init {
    my $key = shift;

    return( Crypt::Blowfish->new( $key ));
}

sub extractDesKeyFromOctets {
    my @octets = @_;

    my @keyOctets;

    #
    # take first 8 octets of the string
    # use LSB as Odd parity for each octet
    #
    for my $o (@octets[0..7]) {
        $o = (($o & 0xfe) |
        (((($o >> 1) ^
        ($o >> 2) ^
        ($o >> 3) ^
        ($o >> 4) ^
        ($o >> 5) ^
        ($o >> 6) ^
        ($o >> 7)) ^ 0x01) & 0x01));
        push(@keyOctets, $o);
    }

    my $desKey = pack('C*', @keyOctets);

    return ($desKey);
}

sub desKeyAndInitializationVectorFromPassphraseAndSalt {
    my ($passphrase, $salt, $iteration) = @_;

    my $digest = Digest::MD5::md5("$passphrase$salt");

    for (my $i = 1; $i < $iteration; $i++) {
        $digest = Digest::MD5::md5($digest);
    }

    my @octets = unpack('c*', $digest);

    my $desKey = extractDesKeyFromOctets(@octets);
    my $iv = pack('c*', @octets[8..15]);

    return ($desKey, $iv);
}

sub pbeInit {
    my $key = shift;
    my $salt = shift || $key;
    my $iteration = shift || 1;

    my ($desKey, $iv) = desKeyAndInitializationVectorFromPassphraseAndSalt($key,$salt,$iteration);

    return( Crypt::CBC->new ( {
                'key'       => $desKey,
                'cipher'    => 'Crypt::DES',
                'regenerate_key'=> 0,
                'prepend_iv'    => 0,
                'iv'        => $iv,
            })
    );
}

sub ede3Init {
    my $key = shift;

    # Pad the key in case it's too short.
    my $keysize = Crypt::DES_EDE3->keysize();
    $key .= "\0" x ($keysize - length($key)) if length($key) < $keysize;

    return( Crypt::DES_EDE3->new($key) );
}

sub encodingBase64 {
    return $base64;
}

sub encodingUuencoded {
    return $uuencoded;
}

sub allEncodings {
    return @encodings;
}

sub encryptToBinary {
    my $blowfish = shift;
    my $plaintext = shift;  

    my $ciphertext = '';
    my $blocksize  = Crypt::Blowfish->blocksize();

    my $block;
    while ( ($block = substr($plaintext, 0, $blocksize, '')) ne "" ) {
        # The Blowfish library doesn't pad out to 8 bytes for us.
        $block .= "\0" x ($blocksize - length($block)) if length($block) < $blocksize;
        $ciphertext .= $blowfish->encrypt($block);
    }

    return $ciphertext;
}

sub encryptToUU {
    my $blowfish = shift;
    my $plaintext = shift;  

    my $ciphertext = encryptToBinary($blowfish, $plaintext);

    chop(my $uu = pack("u",$ciphertext));

    return $uu;
}

sub encryptToBase64 {
    my $blowfish = shift;
    my $plaintext = shift;  

    my $ciphertext = encryptToBinary($blowfish, $plaintext);

    $^W = 0 if ($suppressWarning);

    my $b64 = MIME::Base64::encode_base64($ciphertext, '');

    return $b64;
}

sub encrypt {
    my $blowfish = shift;
    my $plaintext = shift;  
    my $encoding = shift;

    my $encrypted;
    if ( !$encoding || $encoding eq encodingBase64() ) {
        $encrypted = encryptToBase64( $blowfish, $plaintext );
    } elsif ( $encoding eq encodingUuencoded() ) {
        $encrypted = encryptToUU( $blowfish, $plaintext );
    } else {
        die "ariba::util::Encryption::encrypt - unknown encryption encoding: $encoding\n";
    }

    return $encrypted;
}

sub decryptBinary {
    my $blowfish   = shift;
    my $ciphertext = shift; 

    my $plaintext  = '';
    my $blocksize  = Crypt::Blowfish->blocksize();

    my $block;
    while ( ($block = substr($ciphertext, 0, $blocksize, '')) ne "" ) {
        $block .= "\0" x ($blocksize - length($block)) if length($block) < $blocksize;
        $plaintext .= $blowfish->decrypt($block);
    }

    $plaintext =~ s|\000*$|| if $plaintext;

    return $plaintext;
}

sub decryptUU {
    my $blowfish         = shift;
    my $packedCiphertext = shift;

    my $ciphertext = unpack("u", $packedCiphertext);

    return decryptBinary($blowfish, $ciphertext);
}

sub decryptBase64 {
    my $blowfish      = shift;
    my $b64Ciphertext = shift;

    $^W = 0 if ($suppressWarning);

    my $ciphertext = MIME::Base64::decode_base64($b64Ciphertext);

    return decryptBinary($blowfish, $ciphertext);
}

sub decrypt {
    my $blowfish   = shift;
    my $ciphertext = shift; 
    my $encoding   = shift;

    if ( !$encoding || $encoding eq encodingBase64() ) {
        return decryptBase64( $blowfish, $ciphertext );
    } elsif ( $encoding eq encodingUuencoded() ) {
        return decryptUU( $blowfish, $ciphertext );
    } else {
        die "ariba::util::Encryption::decrypt unknown encoding $encoding to decrypt\n";
    }
}

sub blowfishPKCS5Padding {
    my ($block, $decrypt) = @_;

    if ($decrypt) {
        my $lastChar = substr($block, -1);
        my $padLength = ord($lastChar);
        substr($block, -$padLength) = '';
        return $block;
    }

    my $blocksize = Crypt::Blowfish->blocksize();
    my $pad = $blocksize - length($block) % $blocksize;

    return $block . pack("C*", ($pad) x $pad);
}

#
# PBEWithMD5AndDes-CBC (PKCS5) encryption/decrption routines
#
sub pbeEncryptToBinary {
    my $cbc       = shift;
    my $plaintext = shift;

    my $ciphertext;

    $ciphertext = $cbc->encrypt($plaintext);

    return ($ciphertext);
}

sub pbeEncryptToBase64 {
    my $cbc       = shift;
    my $plaintext = shift;

    my $ciphertext = pbeEncryptToBinary( $cbc, $plaintext );

    $^W = 0 if ($suppressWarning);

    my $b64 = MIME::Base64::encode_base64($ciphertext, '');

    return $b64;
}

sub pbeDecryptBinary {
    my $cbc = shift;
    my $ciphertext = shift;

    return $cbc->decrypt($ciphertext);
}

sub pbeDecryptBase64 {
    my $cbc           = shift;
    my $b64Ciphertext = shift;

    $^W = 0 if ($suppressWarning);

    my $ciphertext = defined($b64Ciphertext) && MIME::Base64::decode_base64($b64Ciphertext) || '';

    return pbeDecryptBinary( $cbc, $ciphertext);
}

#
# DES-EDE3 with PKCS5 padding.
#

sub isDES3Encrypted {
    my $cipherText = shift;

    if ($cipherText && $cipherText =~ m|$des3Prefix|) {
        return 1;
    }

    return 0;
}

sub des3EncryptToBinary {
    my $ede3      = shift;
    my $plaintext = shift;

    my $ciphertext = '';

    my $bs  = $ede3->blocksize();
    my $len = length($plaintext);

    # The Crypt::DES_EDE3 library doesn't pad out to 8 bytes for us.
    # JCE defaults to PKCS5 padding.
    my $pad = $bs - ($len % $bs);
    $plaintext .= pack("C*", ($pad) x $pad);

    my $newLen = length($plaintext);
    my $template = "a$bs " x (int($newLen/$bs));
    my @blocks = unpack($template, $plaintext);

    for my $block (@blocks) {
        $ciphertext .= $ede3->encrypt($block);
    }

    return $ciphertext;
}

sub des3EncryptToBase64 {
    my $ede3      = shift;
    my $plaintext = shift;

    my $ciphertext = des3EncryptToBinary( $ede3, $plaintext );

    $^W = 0 if ($suppressWarning);

    my $b64 = $des3Prefix . MIME::Base64::encode_base64($ciphertext, '');

    return $b64;
}

sub des3DecryptBinary {
    my $ede3 = shift;
    my $ciphertext = shift;

    my $plaintext  = '';
    my $bs  = $ede3->blocksize();
    my $len = length($ciphertext);

    my $template = "a$bs " x (int($len/$bs));
    my @blocks = unpack($template, $ciphertext);

    for my $block (@blocks) {
        $plaintext .= $ede3->decrypt($block);
    }

    # JCE defaults to PKCS5 padding. Remove any extra padding it was added.
    my $lastChar = substr($plaintext, -1);
    my $padLength = ord($lastChar);
    substr($plaintext, -$padLength) = '';

    return $plaintext;
}

sub des3DecryptBase64 {
    my $ede3          = shift;
    my $b64Ciphertext = shift;

    $^W = 0 if ($suppressWarning);

    $b64Ciphertext =~ s|^$des3Prefix||;

    my $ciphertext = MIME::Base64::decode_base64($b64Ciphertext);

    return des3DecryptBinary( $ede3, $ciphertext );
}

sub setSuppressWarning { 
    $suppressWarning = shift;
}

sub suppressWarning { 
    return $suppressWarning;
}

1;
