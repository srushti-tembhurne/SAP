package ariba::rc::Passwords;
use strict;

use Digest::MD5;
use Digest::SHA1;

use ariba::util::Encryption;
use ariba::rc::Globals;
use ariba::Ops::ServiceController;
use FindBin;
use File::Basename;
use ariba::Ops::VaultAccess;

my $debug;
my $vaultAccess;
my %PasswordInfo;
my $initialized = 0;
my %PlaintextOverride;
my %blowfishForService;
my %ede3ForService;
my %cbcForService;
my $initializedService = "";
my $passwordDir;
my %masterPasswords;
my $masterfingerprint;
my $pcifingerprint;
my $masterBlowfish;
my $masterDES3;
my $pciBlowfish;
my $pciDES3;
my $pbe;

sub reset {
    $initialized = 0;
}

sub initialized
{
    return $initialized;
}

sub service {
    return $initializedService;
}

#
# get plain text  password from encrypted list
#
# Input key to lookup value from
# Input considervault - read from vault (fallback to grandfather behavior if not found)
# Input rootkey - whether the key is to be looked up in the root area of vault (not scoped inder app;mp is an example)
sub lookup
{
    my ($key, $considervault, $rootkey) = @_;

    if($key =~ /^robot\d+$/) {
        return($key);
    }

    if (!$initialized) {
        return "";
    }

    my $plainText;

    if ($considervault) {
        my $plaintext = _readSecretFromVaultAccess(service(), $key, $rootkey);
        if ($plaintext) {
            return $plaintext;
        }
    }

    my $encodedPassword = $PasswordInfo{$key};

    return $encodedPassword unless($encodedPassword);

    unless (isEncrypted($key)) {
        $plainText = $encodedPassword;
    } else {
        $plainText = decryptBruteForce(
            $encodedPassword, $PasswordInfo{'encoding'});
    }

    return $plainText;
}

sub decryptLoopDES3 {
    my $cipher = shift;

    my $cleartext;

    foreach my $des3 ( $masterDES3, $pciDES3 ) {
        if ( $des3 ) {
            $cleartext = ariba::util::Encryption::des3DecryptBase64( $des3, $cipher );
            if ( $cleartext && isAsciiPasswordString( $cleartext ) ) {
                my $password = $des3 eq $masterDES3 ? 'master' : 'pci';
                return ( $cleartext, $password, 'des3' );
            }
        }
    }

    return $cleartext;
}

sub decryptLoopBlowfish {
    my $cipher = shift;
    my $encoding = shift;

    my $cleartext;

    foreach my $blowfish ( $masterBlowfish, $pciBlowfish ) {
        if ( $blowfish ) {
            $cleartext = ariba::util::Encryption::decrypt( $blowfish, $cipher, $encoding );
            if ( $cleartext && isAsciiPasswordString( $cleartext ) ) {
                my $password = $blowfish eq $masterBlowfish ? 'master' : 'pci';
                return $cleartext, $password, 'blowfish';
            }
        }
    }

    return $cleartext;
}

#
# decrypt any random string that might have been encrypted using the
# same passphrase and pbe encryption.  Only supports master password as a cipher
#
sub decryptUsingPassphrase
{
    my $cipher = shift;

    my $plainText =  ariba::util::Encryption::pbeDecryptBase64( $pbe, $cipher );

    return $plainText;
}

# try all combinations of master/pci and blowfish/des3/passphrase to decrypt a string
sub decryptBruteForce {
    my $cipher   = shift;
    my $encoding = shift;

    my $cleartext;
    my $password;
    my $encryption;

    # first try des3 decryption
    if ( ariba::util::Encryption::isDES3Encrypted( $cipher ) ) {
        ( $cleartext, $password, $encryption ) = decryptLoopDES3( $cipher );
    }
    else {
        # if that didn't work try standard master password (blowfish)
        ( $cleartext, $password, $encryption ) = decryptLoopBlowfish( $cipher );

        # finally, try passphrase descryption.  This is only supported with master password
        unless ( $password ) {
            $cleartext = decryptUsingPassphrase( $cipher, $encoding );
            if ( $cleartext && isAsciiPasswordString( $cleartext ) ) {
                $password = 'master';
                $encryption = 'passphrase';
            }
        }
    }

    if ( $debug ) {
        if ( $password ) {
            print "Decrypted using $password password and $encryption encryption.\n";
        } else {
            print "Could not decrypt string: $cipher\n";
        }
    }

    # If the clear text is garbage it doesn't matter which decryption result we have.
    # Bottom line, all possible decryption combinations failed.
    if ( wantarray ) {
        return ( $cleartext, $password, $encryption );
    } else {
        return $cleartext;
    }
}

sub secureCheck {
    my $bin = "$FindBin::Bin/" . basename($0);
    my $script = "";
    my $perforce = "";
    my $testlib = 0;

    open(F, "$bin");
    while(my $line = <F>) {
        $testlib = 1 if(
            $line &&
            $line =~ /sub woConfTest/ ||
            $line =~ /sub prodApiTest/ ||
            $line =~ /Enter cipher string to decrypt using/ ||
            $line =~ /sub passwordApiTest/ ||
            $line =~ /sub cipherTest/
        );
        $script .= $line;
    }
    close(F);

    return unless($testlib);

    open(F, "/usr/local/bin/p4 print //ariba/services/tools/lib/perl/test-lib |");
    my $p4header = <F>;
    while(my $line = <F>) { $perforce .= $line; }
    close(F);

    if($script ne $perforce) {
        print "Failed to get information from perforce.\n";
        exit;
    }
}

#
# prompt user for key to initialize encryption
#
sub readMasterPasswordFromStdin
{
    my $oldState = $|;
    $| = 1;
    print "Enter Master Password: ";
    $| = $oldState;

    if ($vaultAccess) {
        my $mp = _readSecretFromVaultAccess(service(), "master", 1);
        if ($mp) {
            print "\n";
            return $mp;
        }
    }

    if (-t STDIN) {
        system("stty -echo");
    }

    my $key = <STDIN>;
    chop($key);

    if (-t STDIN) {
        system("stty echo");
        print "\n";
    }

    return $key;
}

sub readPasswordsFromFile
{
    my $file = shift;

    open(FL, $file) || return 0;
    while(<FL>) {
        s/^\s*//go;
        s/^\s*#.*//go; # Inline '#' not allowed, encrypted string may have '#'
        s/\s*$//go;
        next if ($_ eq "");
        my ($key, $value) = split(/\s+/, $_, 2);

        $PasswordInfo{$key} = $value;
    }
    close(FL);

    #
    # For backword compatibility assume passwords to be uuencoded
    #
    unless ($PasswordInfo{'encoding'}) {
        $PasswordInfo{'encoding'} = ariba::util::Encryption::encodingUuencoded();
    }

    return 1;
}

sub reinitialize
{
    $initialized = 0;
    %PasswordInfo = ();

    $masterfingerprint = undef; # Attempt to clear some prior state
    $pcifingerprint = undef;

    return initialize(@_);
}

sub decryptValueForSubService {
    my $value = shift;
    my $service = shift;

    my $plaintext  = '';

    if (ariba::util::Encryption::isDES3Encrypted($value)) {
        $value =~ s/^\{DESede\}//;
        my $decrypt = MIME::Base64::decode_base64($value);

        my $ede3 = $ede3ForService{$service};
        my $bs  = $ede3->blocksize();
        my $len = length($decrypt);
        my $template = "a$bs " x (int($len/$bs));
        my @blocks = unpack($template, $decrypt);
        for my $block (@blocks) {
            $plaintext .= $ede3->decrypt($block);
        }
        my $lastChar = substr($plaintext, -1);
        my $padLength = ord($lastChar);
        substr($plaintext, -$padLength) = '';

        return($plaintext);
    }
    else {
        my $blowfish = $blowfishForService{$service};

        return(undef) unless($blowfish);

        my $ciphertext = MIME::Base64::decode_base64($value);
        my $blocksize = Crypt::Blowfish->blocksize();
        my $block;
        while( ($block = substr($ciphertext, 0, $blocksize, '')) ne "" ) {
            $block .= "\0" x ($blocksize - length($block)) if length($block) < $blocksize;
            $plaintext .= $blowfish->decrypt($block);
        }
        $plaintext =~ s|\000*$|| if $plaintext;
    }

    return($plaintext);
}

sub parseSubFile {
    my $file = shift;
    my $service = shift;
    my $master = shift;

    my %input;

    my $IN;
    open($IN, $file);
    while(my $line = <$IN>) {
        $line =~ s/^\s*//go;
        $line =~ s/^\s*#.*//go; # Inline '#' not allowed, encrypted string may have '#'
        $line =~ s/\s*$//go;
        next if ($line eq "");
        my ($key, $value) = split(/\s+/, $line, 2);

        $input{$key} = $value;
    }

    my $md5salt = $input{'md5salt'};

    my $key = $master . $md5salt;

    my $md5 = Digest::MD5->new();
    $md5->add($key);
    my $digest = $md5->hexdigest();
    my $blowfish = Crypt::Blowfish->new($digest);

    $blowfishForService{$service} = $blowfish;

    my $pbekey = $master;
    my $ede3key = $master;
    foreach my $k (keys(%input)) {
        if($k eq 'pbepassphrase') {
            $pbekey = decryptValueForSubService($input{$k}, $service);
        }
        next unless($k =~ /(.*)$service$/);

        my $plaintext = decryptValueForSubService($input{$k}, $service);

        $PasswordInfo{$k} = $plaintext;
        $PlaintextOverride{$k} = 1;
    }

    #
    # create EDE3 for service
    #
    my $keysize = Crypt::DES_EDE3->keysize();
    $ede3key .= "\0" x ($keysize - length($ede3key)) if length($ede3key) < $keysize;
    my $ede3 = Crypt::DES_EDE3->new($ede3key);
    $ede3ForService{$service} = $ede3;

    #
    # create PBE for service
    #
    my ($newDesKey, $iv) = ariba::util::Encryption::desKeyAndInitializationVectorFromPassphraseAndSalt($pbekey, $pbekey, 1);
    my $cbc = Crypt::CBC->new ({
        'key'       => $newDesKey,
        'cipher'    => 'Crypt::DES',
        'regenerate_key'=> 0,
        'prepend_iv'    => 0,
        'iv'        => $iv,
    });
    $cbcForService{$service} = $cbc;
}

sub validatePassword {
    my $passwordName = shift;
    my $key = shift;
    my $fingerprint = shift;
    my $providedMaster = shift;

    my $valid = 0;

    my $sha1 = Digest::SHA1->new;
    $sha1->add($key);
    my $digest = $sha1->hexdigest();

    # validate the password.
    if ($digest eq $fingerprint) {
        $valid = 1;
        print "$passwordName Password is good.\n" unless $providedMaster;
    }
    else {
        print "$passwordName Password Incorrect.\n" unless $providedMaster;
    }

    return $valid;
}

sub _initVaultAccess
{
    $vaultAccess = ariba::Ops::VaultAccess::connectLocalhost();
}

sub _readSecretFromVaultAccess
{
    my ($service, $name, $rootkey) = @_;

    if ($vaultAccess) {
        my $key;
        if ($name =~ /$service/) {
            $key = $name;
        } else {
            $key = "$service.$name";
        }
        # We always need unqique keys in Vault as it stores keys for all services
        # Here we massage the key to be what we require in vault

        my $value = $vaultAccess->readSecret($key, $rootkey);
        if ($value) {
            print "got value for $name (translated to $key) from vault.\n" if ($debug);
            return $value;
        }
    }
    return undef;
}

sub initBlowfish {
    my $passwordName = shift;

    my $password = $PasswordInfo{ $passwordName };
    my $key = $password . $PasswordInfo{'md5salt'};

    my $md5 = Digest::MD5->new;
    $md5->add( $key );
    my $digest = $md5->hexdigest();

    return( ariba::util::Encryption::init( $digest ));
}

#
# read in the master password and initialize encryption accordingly.
# return 1 if initialized; 0 otherwise
# NOTE: There is exit logic in here that should be handled at application layer use the tewsting flag to work around this
#
sub initialize
{
    my ($service, $providedMaster, $skipVault, $testing) = @_;
    my ($sha1fingerprint);
    my $file;

    $debug = $ENV{DEBUG};

    _initVaultAccess() unless ($skipVault);

    if(!$providedMaster && $ENV{'STY'} && $ENV{'ARIBA_MCL_PPID'}) {
        unless ($skipVault) {
            $providedMaster = _readSecretFromVaultAccess($service, "master");
        }
        unless ($providedMaster) {
            my $hackFile = "/tmp/.screen-password-info." . $ENV{'ARIBA_MCL_PPID'} . '.' . $ENV{'STY'};
            if( -r $hackFile ) {
                my $INFH;
                open($INFH, $hackFile);
                while(my $line = <$INFH>) {
                    chomp $line;
                    if($line =~ s/^master:\s+//) {
                        $providedMaster = $line;
                    }
                }
                close($INFH);
                unlink($hackFile);
            }
        }
    }

    $initializedService = $service;

    if(ariba::Ops::ServiceController::isProductionServicesOnly($service)) {
        secureCheck();
    }

    if( defined ( $passwordDir ) ) {
        $file="$passwordDir"."/"."$service";
    } else {
        $file = ariba::rc::Globals::passwordFile($service);
    }

	my $master = $providedMaster;
    my $pci;

    if ( ariba::rc::Globals::isPersonalService($service) && $ENV{'ARIBA_BYPASS_PASSWORD'} ) {
        $PasswordInfo{'master'} = "personal";
        $PasswordInfo{'pci'} = "personal";
        $PasswordInfo{'md5salt'} = "personal";
        $PasswordInfo{'pbepassphrase'} = "personal";
        $PlaintextOverride{'pbepassphrase'} = 1;

        my $user = $ENV{'USER'};
        $PasswordInfo{"$user"} = "$user";
        $PlaintextOverride{"$user"} = 1;

    } elsif (!readPasswordsFromFile($file)) {
        unless ($testing) {
            print "****** ERROR ******\n";
            print "Password initialization from $file failed!\n";

            exit 1; # VERY BAD TO HAVE A SUBROUTINE EXIT - Motivates the testing flag as a work around
        }
    }

    my @masterKeys = grep { $_ =~ /Master$/ } keys(%PasswordInfo);

    if ($initialized) {
        return $initialized;
    }

    $initialized = 1;

	$masterfingerprint = $PasswordInfo{'masterfingerprint'};
    $pcifingerprint    = $PasswordInfo{'pcifingerprint'};

    if (defined($masterfingerprint)) {
        my $valid = 0;
        my $retryCount = 3;

        if (! -t STDIN || defined($providedMaster)) {
            $retryCount = 1;
        }

        for (my $i = 0 ; $i < $retryCount && !$valid; $i++) {

            unless (defined($providedMaster)) {
                $master = readMasterPasswordFromStdin();
            }

            $pci = undef;
            if ( $master =~ /split/ ) {
                ($master, $pci) = ($master =~ /(^.*)split(.+)/ );
            }

            my $masterValid = validatePassword( "Master", $master.$PasswordInfo{'sha1salt'}, $masterfingerprint, $providedMaster );
            my $pciValid = 1;
            if ( $pci ) {
                if ( $pcifingerprint ) {
                    $pciValid = validatePassword( "PCI", $pci.$PasswordInfo{'sha1salt'}, $pcifingerprint, $providedMaster );
                }
                else {
                    print "Error: PCI password supplied but 'pcifingerprint' not found in $file\n";
                    exit 1;
                }
            }
            $valid = $masterValid && $pciValid ? 1 : 0;
        }

        if (!$valid) {

            print "****** ERROR ******\n";
            if (defined($providedMaster)) {
                print "Invalid Master Password provided for service $service.  Exiting...\n";
            } else {
                print "Exceeded $retryCount attempt(s) for getting Master Password. Exiting...\n";
            }
            if ($testing) {
                return 0;
            }
            exit 1; # VERY BAD TO HAVE A SUBROUTINE EXIT - Motivates the testing flag as a work around
        }

        $PasswordInfo{'master'} = $master;
        $PasswordInfo{'pci'} = $pci if $pci;
    }

    $masterBlowfish = initBlowfish( 'master' );
    $pciBlowfish = initBlowfish( 'pci' ) if $pci;
    
    #
    # use stored passpharse to initialize PBE, if no passphrase
    # default to master password as passphrase for PBE.
    #
    my $pbePassphrase = lookup('pbepassphrase') || $master;
    $pbe = ariba::util::Encryption::pbeInit( $pbePassphrase );

    # use the master password to initialize DES-EDE3.
    $masterDES3 = ariba::util::Encryption::ede3Init( $master );
    $pciDES3 = ariba::util::Encryption::ede3Init( $pci ) if $pci;

    foreach my $k (@masterKeys) {
        if($k =~ /(.*)Master$/) {
            my $subService = $1;
            my $subFile = ariba::rc::Globals::passwordFile($subService);
            parseSubFile($subFile, $subService, lookup($k));
        }
    }

    return 1;
}

sub initPasswordsforService {
    my $service = shift;

    my $master = masterPasswordForService( $service );
    reinitialize( $service, $master ) if $master;
}
 
sub masterPasswordForService {
    my $service = shift;

    return $masterPasswords{ $service };
}

# Create a hash of master passwords.  The first use case is to allow a JMCL script
# to manage steps targeted at multiple services controlled by different master passwords.
# Think prod, prodeu, prodru, etc
#
# Input: $services - a scalar list of services either space or comma separated
# Imput: $masterPW - a single master password.  This is for backwards compatibility and only in the case where
#                    these is a single service in play.
# Output: a hash of master passwords
sub readMasterPasswords {
    my $services = shift;
    my $masterPW = shift;

    if ( $services =~ /\s+/ ) {
        # multiple master passwords detected.  Read each individually and store them in a separate hash.
        foreach my $service ( split /\s+/, $services ) {
            print "Enter the master password for service: $service\n";
            reinitialize( $service, $masterPW );
            $masterPasswords{ $service } = lookup( 'master' );
        }
    }
    else {
        # We only have a single service in play.  Just past this to the standard initalize script
        initialize( $services, $masterPW );
    }
}
    
sub _dumpContents
{
    my ($returnOnly) = @_;

    my %kv = ();

    for my $pass (sort(keys(%PasswordInfo))) {
      if ($pass eq "encoding" ||
        $pass =~ /^master/ ||
        $pass =~ /salt$/) {
        $kv{$pass} = $PasswordInfo{$pass};
        print "$pass = $PasswordInfo{$pass}\n" unless ($returnOnly);
      } else {
        my $value = lookup($pass);
        $kv{$pass} = $value;
        print "$pass = $value\n" unless ($returnOnly);
      }
    }
    return %kv;
}

sub encryptedPasswords
{
    return (keys(%PasswordInfo));
}

sub isEncrypted
{
    my $key = shift;

	if ($key eq "master" || 
		$key eq "masterfingerprint" || 
		$key eq "pcifingerprint" || 
		$key eq "encoding" || 
		$key eq "sha1salt" || 
		$key eq "md5salt" ||
        $key eq "pci") {

        return 0;

    } elsif ( $PlaintextOverride{$key} ) {
        return 0;

    } else {
        return 1;
    }
}

# function to test a string if it is a valid (decrypted) value
# or garbage;  just checks for characters outside of ascii 32-127 inclusive
# range.
sub isAsciiPasswordString {
    my $string = shift;

    my $isValid = 1;
    my @asciiValues = unpack("C*", $string);
    foreach my $value (@asciiValues) {
        if ($value < 32 || $value > 127) {
            $isValid = 0;
            last;
        }
    }

    return $isValid;
}

sub setPasswordDir {
    $passwordDir= shift;
}

sub lookupMasterPci {
    my $product = shift;
    my $force = shift;

    my $master = ariba::rc::Passwords::lookup( 'master' );
    if ( $force || $product && $product->default( 'Ops.UsesPciPassword' ) eq "true" ) {
        my $pci = ariba::rc::Passwords::lookup( 'pci' );
        if ( $pci ) {
            $master = "${master}split${pci}";
        }
        else {
            unless ( $force ) {
                die "ERROR: Concatenated <master>split<pci> password required.  Can not determine PCI password from the password enetered.\n";
            }
        }
    }

    return $master;
}

1;
