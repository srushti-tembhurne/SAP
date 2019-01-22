#
# $Id: //ariba/services/tools/lib/perl/ariba/rc/CipherStore.pm#19 $
#
package ariba::rc::CipherStore;

use ariba::util::SharedMemory;
use ariba::util::Encryption;
use ariba::Ops::VaultAccess;

my $debug = $ENV{DEBUG};
my $joinString = "!@#UNiQuEtRiNg-=!";
my $encryptionInitialized = 0;
my $encryptionKey = "hhjhtrihioghjhdskwadrdsartddft98995fdsfdsft";

sub new
{
    my $class = shift();
    my $service = shift();
    my $skipVault = shift();

    my $self = {};

    bless($self, $class);

    my $cachedValues = {};

    $self->{'sharedMemoryKey'} = $service;
    $self->{service} = $service;
    $self->{'cachedValues'} = $cachedValues;
    $self->_setReadFromSharedMemory(0);

    $skipVault = 1; # Use vault with CipherStore later - as part of mp elimination story
    unless ($skipVault) {
        $self->{vaultAccess} = ariba::Ops::VaultAccess::connectLocalhost();
    }

    return ($self);
}

sub _cachedValues
{
    my $self = shift();

    return ($self->{'cachedValues'});
}

sub _sharedMemoryKey
{
    my $self = shift();

    return ($self->{'sharedMemoryKey'});
}

sub _readFromSharedMemory
{
    my $self = shift();

    return ($self->{'readFromSharedMemory'});
}


sub _setReadFromSharedMemory
{
    my $self = shift();

    $self->{'readFromSharedMemory'} = shift();
}

# function to test a string if it is a valid (decrypted) value
# or garbage;  just checks for characters outside of ascii 32-127 inclusive
# range.

sub _isStringValidValue {
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

# returns keys not stored after a call to storeHash
sub keysNotStored {
    my $self = shift;
    my @keysNotStored = ();

    @keysNotStored = @{$self->{'keysNotStored'}} if exists($self->{'keysNotStored'});

    return @keysNotStored;
}

sub _addKeyToNotStored {
    my $self = shift;
    my $key = shift;

    push(@{$self->{'keysNotStored'}}, $key);
}

sub _clearKeysNotStored {
    my $self = shift;

    $self->{'keysNotStored'} = ();
}

sub storeHash
{
    my $self = shift();
    my $hashRef = shift();

    my $cachedValues = $self->_cachedValues();
    my $sharedMemoryKey = $self->_sharedMemoryKey();

    $self->_clearKeysNotStored();

    for my $key (keys(%$hashRef)) {
        my $skey = lc($key);
        my $value = $hashRef->{$key};

        if (_isStringValidValue($value)) {
            $cachedValues->{$skey} = $value;
        }
        else {
            #print "DEBUG: Invalid value :$value: for key $skey, not storing\n";
            $self->_addKeyToNotStored($key);
        }
    }

    my $blowfish = ariba::util::Encryption::init($encryptionKey)
                        unless($encryptionInitialized);

    my $store = join($joinString, %$cachedValues);
    $store = ariba::util::Encryption::encrypt($blowfish, $store);

    #print "DEBUG: wrote $store\n";
    my $size = length($store);

    my $shm = ariba::util::SharedMemory->new($sharedMemoryKey, $size);

    if ($shm->create() < 0) {
        print "\nERROR - CipherStore:Failed to create SharedMemory\n";
        return 0; # Caller should check $! for error
    } elsif ($size != $shm->write($store)) {
        print "\nERROR - CipherStore:Created SharedMemory has incorrect size\n";
        return 0;
    } else {
        return 1;
    }

}

sub storeNameValue
{
    my $self = shift();
    my $name = shift;
    my $value = shift;

    return $self->storeHash({$name => $value});
}

sub valueForName
{
    my $self = shift();
    my $name = shift;

    my $origname = $name;

    $name = lc($name);

    if (defined $self->{vaultAccess}) {
        my $key;
        if ($name =~ /$self->{service}/) {
            $key = $name;
        } else {
            $key = "$self->{service}.$name";
        }
        # We always need unqique keys in Vault as it stores keys for all services
        # Here we massage the key to be what we require in vault

        my $value = $self->{vaultAccess}->readSecret($key);
        if ($value) {
            print "got the value for $origname from vault.\n" if ($debug);
            return $value;
        } else {
            print "did not get the value for $origname from vault.\n" if ($debug);
        }
    }

    my $cachedValues = $self->_cachedValues();
    my $sharedMemoryKey = $self->_sharedMemoryKey();
    my $readFromSharedMemory = $self->_readFromSharedMemory();

    if ($readFromSharedMemory) {
       return $cachedValues->{$name};
    }

    my $blowfish = ariba::util::Encryption::init($encryptionKey)
                        unless($encryptionInitialized);

    my $shm = ariba::util::SharedMemory->new($sharedMemoryKey);

    unless( defined($shm->attach()) ) {
        return undef;
    }

    my $stored = $shm->read();

    #print "DEBUG: read $stored\n";

    if ($stored) {
        $stored = ariba::util::Encryption::decrypt($blowfish, $stored);
        my %tmpHash = split($joinString, $stored);
        for my $key (keys(%tmpHash)) {
            $cachedValues->{$key} = $tmpHash{$key};
        }
    }

    #print "DEBUG: value for $name = ", $cachedValues->{$name}, "\n";

    $self->_setReadFromSharedMemory(1);

    return $cachedValues->{$name};
}

sub delete
{
    my $self = shift();
    my $sharedMemoryKey = $self->_sharedMemoryKey();

    my $shm = ariba::util::SharedMemory->new($sharedMemoryKey);

    $shm->destroy();
}

sub _dumpContents
{
    my $self = shift();
    my $cachedValues = $self->_cachedValues();

    $self->valueForName('fakename');

    for my $key (sort(keys(%$cachedValues))) {
        print "$key = ", $cachedValues->{$key}, "\n";
    }
}

1;
