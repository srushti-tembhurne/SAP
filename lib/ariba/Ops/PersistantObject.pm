package ariba::Ops::PersistantObject;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/PersistantObject.pm#77 $

use strict;
use vars qw($AUTOLOAD);
use File::Path;
use File::Basename;
use IO::Scalar;
use ariba::util::Simplefind;
use Encode;

#
# Nota bene:
# Be very careful with filehandle names.  my $FH = IO::Scalar(...)
# does not work, it subtly breaks *FH in _saveStateToFile().
# Workaround is to make all the FH be unique, like FH, FHA, FHB, etc.
# even for the my'ed vars.
#
#				--Dan
#

=pod

=head1 NAME

ariba::Ops::PersistantObject - Persistant Object Manager

=head1 SYNOPSIS

package ariba::Oncall::Person;

use base qw(ariba::Ops::PersistantObject);

 sub dir {
       my $class = shift;
       return '/path/to/peopleobjects'; 
 }

package main;

my $person = ariba::Oncall::Person->new('johndoe');

   $person->setFullName('John Doe');
   $person->setCellPhone('555-1212');

   $person->save();

   undef $person;

   $person = ariba::Oncall::Person->new('johndoe');

   my $fullname = $person->fullName();

   $person->print();

=head1 DESCRIPTION

ariba::Ops::PersistantObject is a general singleton based, persistent object
layer with cacheing capabilities.

Blame Dan Grillo for the class mis-spelling.

This API listing documents both public class and object methods, as well as
protected methods needed for subclasses, and private methods for complete
documentation.

=head1 Class Methods

=over 4

=cut

# so we can hand out unique instances 
my %_OBJECTS = ();

my %_LOCATIONS = ();

# cache the names of the loaded classes to miss an eval() 
my %_LOADED_CLASSES = ();

# Internal check to see if we've loaded all the objects in a class.
my %_hasLoadedAllObjects = ();

# control on our cache behavior
# smart cache means "reload if the backingstore is newer and object is not dirty"
my $_smartCache = 0;

my $_objectsLoadedFromDisk = 0;

# autoloaded methods, for automatic getters and setters
# subroutines are created as closures, then stuffed into the calling class's
# symbol table.

sub AUTOLOAD {
	my $self = $_[0];
	my $instanceVar = $AUTOLOAD;
	$instanceVar =~ s/.*://;

	# don't autoload class methods
	my $type = ref($self) or _mydie("$self is not an object, tried to call $instanceVar on it");

	# don't autoload DESTROY { }
	return if $instanceVar eq 'DESTROY';

	# create closures for our autoloaded methods.
	no strict 'refs';

	my $class = ref($self);

	# Skip if the subclass hasn't set any valid methods (IE: every method is ok)
	my $validMethods = $class->validAccessorMethods();

	if (keys %$validMethods > 0) {

		# Strip off the base method to check if it's valid.
		my $baseMethod = $instanceVar;
		$baseMethod =~ s/^(?:set|appendTo|delete)(.+)/$1/o;

		unless (exists $validMethods->{lcfirst($baseMethod)}) { 

			print "No such method: $instanceVar()\n";

			$self->__dumpStack();
		}
	}

	#
	if ($instanceVar =~ s/^set//) {

		$instanceVar = lcfirst($instanceVar);

		# setter
		*{$AUTOLOAD} = sub {
			my $self = shift;
			$self->setAttribute($instanceVar, @_);
		};

	} elsif ($instanceVar =~ s/^appendTo//) {

		$instanceVar = lcfirst($instanceVar);

		# append
		*{$AUTOLOAD} = sub {
			my $self = shift;
			$self->appendToAttribute($instanceVar, @_);
		};

	} elsif ($instanceVar =~ s/^delete//) {

		$instanceVar = lcfirst($instanceVar);

		# clear attribute
		*{$AUTOLOAD} = sub {
			my $self = shift;
			$self->deleteAttribute($instanceVar, @_);
		};

	} else { 

        no warnings 'redefine';
		# getter
		*{$AUTOLOAD} = sub {
			my $self = shift;
			return $self->attribute($instanceVar);
		};
	}

	&$AUTOLOAD;
}

# class methods

=pod

=item * listObjects()

Return an instantiated array of objects from directory specified by $class->dir()

If no dir() or equivalent is available, return from the object cache.

=cut

sub listObjects {
	my $class = shift;
	my @list  = ();

	my $dir = $class->dir();
	if ( defined($dir) ) {

		# not being able to read our backing store is not always a
		# problem, esp. if the read is happening before the directory is
		# created by a future save

		opendir(DIR, $dir) or return ();
		my @files = grep($_ !~ /^\./o && !-d "$dir/$_", readdir(DIR));
		closedir(DIR);

		foreach my $file (sort @files) {
			push(@list, $class->new($file)) or warn "Can't create new $class: $!";
		}	
	} else {
		@list = $class->_listObjectsInCache();
	}
	
	return @list;
}

# class methods

=pod

=item * listObjectsRecursively()

Return an instantiated array of all objects (including those in subdirectories) from directory specified by $class->dir()

If no dir() or equivalent is available, return from the object cache.

=cut

sub listObjectsRecursively {
	my $class = shift;
	my @list  = ();

	my $dir = $class->dir();
	if ( defined($dir) && -d $dir ) {

		# not being able to read our backing store is not always a
		# problem, esp. if the read is happening before the directory is
		# created by a future save
		my $sf = ariba::util::Simplefind->new($dir);
		my @files = $sf->find();

		foreach my $file (@files){
			$file =~ s/$dir\///;
		}
		@files = grep($_ !~ /^\./o, @files);

		foreach my $file (sort @files) {
			push(@list, $class->new($file)) or warn "Can't create new $class: $!";
		}	
	} else {
		@list = $class->_listObjectsInCache();
	}
	
	return @list;
}


=pod

=item * dir( $dir )

Returns directory name where objects live. Subclasses must override (or
specify as $dir argument) to point to their object on disk.

=cut

sub dir {
	my $class = shift;
	my $dir   = shift;

	$class::dir = $dir if defined $dir;
	return $class::dir;
}


=pod

=item * objectsLoadedFromDisk()

Number of objects loaded from disk (as opposed to returned from cached in some way)

=cut

sub objectsLoadedFromDisk {
	my $class = shift;

	return $_objectsLoadedFromDisk;
}

=pod

=item * enableSmartCache()

=item * disableSmartCache()

=item * isSmartCacheEnabled()

Enable/disable/test for smart cache -- cache objects but check their backing
store for changes.  The default caching is to always caching objects even if
the backingstore has changed.

=cut

sub enableSmartCache {
	my $class = shift;

	$_smartCache = 1;
	return $_smartCache;
}

sub disableSmartCache {
	my $class = shift;

	$_smartCache = 0;
	return $_smartCache;
}

sub isSmartCacheEnabled {
	my $class = shift;
	
	return $_smartCache;
}

=pod

=item * new( $instance )

Create a new object of the specified instance. If the object already exists in
the class's global cache, that will be returned instead of a new object.

=cut

sub new {
	my $class    = shift;
	my $instance = shift;

	if ( defined($instance) && $class->_objectWithNameExistsInCache($instance) ) {

		# we have two flavors of caching:
		# normal (the default) == always return the cached object
		# smart == use the cache only if the object is dirty or no older than backingstore, else reload

		my $objectFromCache = $class->_objectWithNameFromCache($instance);


		unless ( $class->isSmartCacheEnabled() ) {
			return $objectFromCache;

		} else {
			if ( $objectFromCache->_isDirty() || ! $objectFromCache->_backingStore() ) {
				return $objectFromCache;

			} elsif ( $objectFromCache->_lastStatTime() >= time() - 10 ) {
				return $objectFromCache;

			} elsif ( $objectFromCache->_faultedInTime() >= 
					$objectFromCache->_lastModifiedTimeInBackingStore() ) {
				return $objectFromCache;

			} else {
				# we have a clean, cached object that's older than the backing store
				# and smartcache is enabled.  Reload the object.
				$class->_removeObjectFromCache($objectFromCache);
		
			}
		}
	} 

	my $self = {
		'_lastStatTime' => 0,
		'_faultedInTime' => 0,
		'_faultedIn' => 0,
		'_readIn'    => 0,
		'_dirty'     => 0,
		'_builtForeignObjectsList' => 0,
		'_typemap'   => {},
		'_info'	     => {},
		'instance'   => $instance,
	};
	bless($self, $class);
	$self->_loadTypeMap();
	$self->_setBackingStore();

	# add new instance to the cache
	if ( defined($instance) ){
		$class->_addObjectToCache($self);
	}

	return $self;
}

=pod

=item * createObjectsFromStream( $stream, $ignorecase )

Takes a file descriptor of $stream, and attempts to create and return an array of objects.

The first two newline separated records in the stream should be:

_Instance: <instancename>

_Class: <classname>

the rest of the object is then read from the file descriptor.

=cut

sub createObjectsFromStream {
	my $class = shift;
	my $stream = shift;
	my $ignorecase = shift();

	my @objects = ();

	while(my $line = <$stream> ) {
		chomp($line);
		$line =~ s/\cM$//o;

		# this is to support streaming over network;
		# bogus that it's here
		last if $line eq ".";

		my ($key, $instance) = split(/\s/o, $line, 2);
		next unless ( $key eq "_Instance:" );

		# chomp needs to be on a separate line to 
		# work with IO::Scalar and in-core strings.
		$line = <$stream>;
		chomp($line);

		my ($tkey, $type) = split(/\s/o, $line, 2);
		next unless ( $tkey eq "_Class:" );
	
		# is this right??
		unless (exists $_LOADED_CLASSES{$type}) {
			eval("require $type") || _mydie("can't load $type $!");
		}
		my $object = $type->new($instance);
		$_LOADED_CLASSES{$type} = 1;

		$object->_unFaultIn();
		$object->_needsToBuildForeignObjectsList();
		$object->_readStateFromStream($stream, $ignorecase);
		$object->_faultInData() unless $object->{'_faultedIn'};
		$object->_dirty();
		push(@objects, $object);
	}
	return @objects;
}

=pod

=item * createObjectsFromString( $string, $ignorecase )

attempts to create and return an array of objects contained in $string.

See createObjectsFromStream()

=cut

sub createObjectsFromString {
	my $class = shift;
	my $string = shift;
	my $ignorecase = shift;

	# Create a reference for a string to be treated as a file.
	my $FHA = IO::Scalar->new(\$string);
	my @objects = $class->createObjectsFromStream($FHA, $ignorecase);
	close($FHA);

	return @objects;
}

=pod

=item * objectLoadMap()

-Subclasses should override-

The objectLoadMap defines a mapping of attribute names to foreign objects, in
order to instansiate those objects (by calling class->new) when the attribute
is accessed. The mapping is loaded during class->new. If a class name is prefixed 
with a '@', an array of objects in that class is returned. A special value of @SCALAR 
can also be used to return an array of (perl) scalar values. A corresponding %SCALAR
can be used for storing a hash. Example from a subclass:

sub objectLoadMap {
	my $class = shift;

	my $mapRef = $class->SUPER::objectLoadMap();

	$$mapRef{'query'} = 'ariba::monitor::Query';
	$$mapRef{'times'} = '@SCALAR';
	$$mapRef{'hash'} = '%SCALAR';

	return $mapRef;
}

=cut

sub objectLoadMap {
	my $class = shift;
	my %map = ();

	return \%map;
}

sub _loadTypeMap {
	my $self = shift; 

	my $class = ref($self);
	my $map = $class->objectLoadMap();	
	my @rules = keys(%$map);

	for my $rule (@rules) {
		$self->{'_typemap'}->{$rule} = $map->{$rule};
	}
}

=pod

=item * validAccessorMethods()

Return the list of valid accessor methods for this class.

=cut

sub validAccessorMethods {
	my $class   = shift;

	my %methods = ();

	return \%methods;
}

=pod

=item * objectWithNameExists( $instance )

Returns true if object exists in cache or in backing store. Otherwise returns undef.

=cut

sub objectWithNameExists {
	my $class = shift;
	my $instance = shift;

	if ( $class->_objectWithNameExistsInCache($instance) ) {
		return 1;
	}
	
	if ( $class->_objectWithNameExistsInBackingStore($instance) ) {
		return 1;
	}

	return undef;
}

=pod

=item * protected * _objectWithNameExistsInBackingStore( $instance )

Does a file-test check to see if the specified instance as called
from objectWithNameExists() is on-disk. Subclasses that do not use a
flat-file-on-filesystem backingstore will want to override. Such as a
subclass that used a relational database as it's backing store.

=cut

sub _objectWithNameExistsInBackingStore {
	my $class = shift;
	my $instance = shift;

	my $backingstore = $class->_computeBackingStoreForInstanceName($instance);

	if ( defined($backingstore) ) {
		if ( -f $backingstore ){
			return 1;
		}
	}
	
	return undef;
}

sub _lastModifiedTimeInBackingStore {
	my $self = shift;

	my $backingStore = $self->_backingStore();

	my $time = time();

	$self->{'_lastStatTime'} = $time;

	return ((stat($backingStore))[9] || $time);
}

=pod

=item * protected * _objectWithNameExistsInCache( $instance )

Returns true if the instance exists within the class' global cache.

Potential subclassing usage might be to put global object cache into shared memory.

=cut

sub _objectWithNameExistsInCache {
	my $class = shift;
	my $instance = shift;

	return defined($_OBJECTS{$class}{$instance});
}

=pod

=item * protected * _objectWithNameFromCache( $instance )

Returns the object from the class' global cache.

=cut

sub _objectWithNameFromCache {
	my $class = shift;
	my $instance = shift;

	return $_OBJECTS{$class}{$instance};
}

=pod

=item * protected * _addObjectToCache( $object )

=item * protected * _removeObjectFromCache( $object )

=item * protected * _listObjectsInCache( $object )

These do as they say.

_listObjectsInCache returns an array

=cut

sub _addObjectToCache {
	my $class = shift;
	my $object = shift;
	my $name = $object->instance();

	$object->{_location} = ++($_LOCATIONS{$class});

	$_OBJECTS{$class}{$name} = $object;
}

sub _removeObjectFromCache {
	my $class = shift;
	my $object = shift;

	delete($_OBJECTS{$class}{$object->instance()});
}

sub _removeAllObjectsFromCache {
	my $class = shift;

	my @instances = $class->_listObjectsInCache();

	for my $instance ( @instances ) {
		$class->_removeObjectFromCache($instance);
	}
}

sub _listObjectsInCache {
	my $class = shift;

	my @instances = sort { $a->{_location} <=> $b->{_location} } values %{$_OBJECTS{$class}};

	return @instances;
}

=pod

=item * protected * _computeBackingStoreForInstanceName( $instance )

When an object is fetched off (disk), this method is called to return it's
location. Subclasses may wish to override.

=cut

sub _computeBackingStoreForInstanceName {
	my $class = shift;
	my $instanceName = shift;

	# this takes the instance name as an arg
	# so that the class method objectExists() can call it
	# if dir() returns undef, this class has no backing
	# store, and will only be used as in-memory.  As
	# as a result, it can't be faulted in.
	my $dir = $class->dir();

	if (defined($dir)) {
		my $file = $dir . '/' . $instanceName;

		map { $file =~ s/$_//go } qw(`"'>|;);

		$file =~ s/\.\.//o;
		$file =~ s|//|/|go;

		return $file;
	} else {
		return undef;
	}
}

=back

=head1 Instance Methods

=over 4

=item * attribute( $attribute )

Returns the data contained within the specified attribute.

Example: my $foo = $object->attribute('foo');

Is the same as: my $foo = $object->foo();

=cut

sub attribute {
	my $self = shift;
	my $attribute = shift;

	return undef unless $self->{'instance'};

	$self->_faultInData() unless $self->{'_faultedIn'};

	# make sure foreign objects are loaded
	if (exists $self->{'_notFaultedIn'}->{$attribute}) {
		$self->_faultInForeignObjects($attribute);
	}
	
	my $value = $self->{'_info'}->{$attribute};

	if(!defined($value) || $value =~ /^(?:na|none)$/ || $value eq '') {
		my $wantarray = $self->{'_typemap'}->{$attribute};

		if ( defined($wantarray) && $wantarray =~ /^(?:@|%)/o ) {
			return ();
		} else {
			return undef;
		}
	}

	return @$value if (ref($value) eq "ARRAY");
	return $value;
}

=pod

=item * setAttribute( $attribute, $value, [ $value, $value ] )

Sets the data member of the specified attribute. $value may be a single scalar
value, or an array of values.

Example: my $foo = $object->attribute('foo');

Is the same as: my $foo = $object->foo();

=cut

sub setAttribute {
	my $self = shift;
	my $attribute = shift;
	my @value = @_;

	return undef unless $self->{'instance'};

	$self->_faultInData() unless $self->{'_faultedIn'};

	if (exists $self->{'_notFaultedIn'}->{$attribute}) {
		$self->_faultInForeignObjects($attribute);
	}

	if ( scalar(@value) > 1 ) {

		# default to magic SCALAR if there is no typemap for this attribute.
		if ( !defined($self->{'_typemap'}->{$attribute}) ) {
			$self->{'_typemap'}->{$attribute} = "SCALAR";
		}

		# prepend the magic @ symbol, as this is an array.
		unless ( $self->{'_typemap'}->{$attribute} =~ /^(?:@|%)/ ) {
			 $self->{'_typemap'}->{$attribute} = "@" .  $self->{'_typemap'}->{$attribute};
		}

		$self->{'_info'}->{$attribute} = [@value];
	} else {
		$self->{'_info'}->{$attribute} = $value[0];
	}
	$self->_dirty();
}

=pod

=item * appendToAttribute( $attribute, $value, [ $value, $value ] )

The same as attribute(), but appends the values to the existing values.

=cut

sub appendToAttribute {
	my $self = shift;
	my $attribute = shift;
	my @value = @_;

	my @origValue = $self->attribute($attribute);
	
	local $^W = 0;  # silence spurious -w undef complaints
	if ( @origValue == (undef) ) {
		$self->setAttribute($attribute, @value);
	} else {
		$self->setAttribute($attribute, @origValue, @value);
	}

}

=pod

=item * deleteAttribute( $attribute )

Removes the specified attribute from the object. Object is now dirty.

=cut

sub deleteAttribute {
	my $self = shift;
	my $attribute = shift;

	return unless($attribute);

	delete $self->{'_info'}->{$attribute};
	delete $self->{'_typemap'}->{$attribute};
	delete $self->{'_notFaultedIn'}->{$attribute};

	$self->_dirty();
}

=pod

=item * deleteAttributes()

Removes _all_ attributes of the object. Object is now dirty.

=cut

sub deleteAttributes {
	my $self = shift;

	for my $attribute ($self->attributes()) {
		$self->deleteAttribute($attribute);
	}
}

=pod

=item * attributes()

Returns an array of attribute names.

=cut

sub attributes {
	my $self = shift;

	$self->_faultInData() unless $self->{'_faultedIn'};

	return keys %{$self->{'_info'}};
}

=pod

=item * hasAttribute()

True if the attribute exists.

=cut

sub hasAttribute {
	my $self = shift;
	my $attr = shift;

	$self->_faultInData() unless $self->{'_faultedIn'};

	return exists( $self->{'_info'}->{$attr} );
}

=pod

=item * print( $descriptor )

Pretty-print the object to STDOUT or $descriptor.

=cut

sub print {
	my $self = shift;
	my $descriptor = shift || *STDOUT;

	print $descriptor $self->instance(),"\n";

	$self->_saveStateToStream($descriptor, 0, "    ");
}

=pod

=item * printToString()

Pretty-print the object to a string.

=cut

sub printToString {
	my $self = shift;

	my $string;

	my $FHB = IO::Scalar->new(\$string);
	$self->print($FHB);
	close $FHB;

	return $string;
}

=pod

=item * instance()

Return the object's name.

=cut

sub instance {
	my $self = shift;

	return $self->{'instance'};
}

=pod

=item * save(), recursiveSave()

Save the object's state to the backing store.

recursiveSave() saves foreign objects as well.

=cut

sub save {
	my $self = shift;

	if ( $self->_isDirty() ){
		return $self->_saveStateToFile(0);
	}
	return 1;
}

sub recursiveSave {
	my $self = shift;

	if ( $self->_isDirty() ){
		return $self->_saveStateToFile(1);
	}
	return 1;
}

=pod

=item * saveToStream(*STREAM, $recursive)

Archive object (possibly recursively) to an existing open filehandle.
See saveToString() and createObjectsFromStream().

=cut

sub saveToStream {
	my $self = shift;
	my $stream = shift;
	my $recursive = shift;

	my $haveSavedRef = shift;	# do not pass in

	my $class    = ref($self);
	my $instance = $self->instance();
	my @toSave   = ();

	unless (defined $haveSavedRef) {
		$haveSavedRef = {};
	}

	unless ($haveSavedRef->{$class}->{$instance}) {

		print $stream "_Instance: $instance\n";
		print $stream "_Class: $class\n";

		@toSave = $self->_saveStateToStream($stream, $recursive);

		$haveSavedRef->{$class}->{$instance}++;

		print $stream "\n";
	}

	if ($recursive) {

		for my $object (@toSave) {
			$object->saveToStream($stream, $recursive, $haveSavedRef);
		}
	}
}

=pod

=item * saveToString($recursive)

Archive object (possibly recursively), returning archive as a scalar.
See saveToStream() and createObjectsFromString().

=cut

sub saveToString {
	my $self = shift;
	my $recursive = shift;

	# Create a reference for a string to be treated as a file.
	my $string;

	my $FHC = IO::Scalar->new(\$string);
	$self->saveToStream($FHC, $recursive);
	close($FHC);

	return $string;
}

=pod

=item * remove()

Delete the object from the backingstore, remove it from the object cache.

=cut

sub remove {
	my $self = shift;

	$self->_removeState();

	my $class = ref($self);
	$class->_removeObjectFromCache($self);
}

=pod

=item * readFromBackingStore()

Call this method when you want to force the object to reread from the backing
store. Usage should be rare. 

=cut

sub readFromBackingStore {
	my $self = shift;

	$self->_unFaultIn();	
	$self->_unReadIn();

	my $class = ref($self);
	$class->_removeObjectFromCache($self);
}

=pod

item * hasLoadedAllObjects()

Returns a true/false if we've loaded all the objects

item * setHasLoadedAllObjects()

Tells the class we have loaded all the objects

=cut

sub hasLoadedAllObjects {
	my $class = shift;

	return $_hasLoadedAllObjects{$class};
}

sub setHasLoadedAllObjects {
	my $class = shift;

	return $_hasLoadedAllObjects{$class} = 1;
}

=pod 

=item * objectsWithProperties()

Passed in a hash, will return objects matching those parameters.

=cut

sub objectsWithProperties {
	my ($class, %fieldMatchMap) = @_;

	return ($class->_matchPropertiesInObjects(\%fieldMatchMap));
}

=pod

=item * matchField()

Test to see if an object has a key/value pair.

=cut

sub matchField {
	my ($self, $field, $value) = @_;

	my $inverse = ($field =~ s/^!//);
	# compare our stored value with the passed one.
	my @storedValues = $self->attribute($field);

	# DO NOT call matchFields, as it will return in endless
	# nested recursion, as matchFields->_matchPropertiesInObjects->matchField
	
	# return true if the search value is in the backing store or if the search value is NULL and the 
	# backing store is either not defined or NULL.  
	my $matched = (  (scalar @storedValues > 0 && defined $storedValues[0] && grep { /^$value$/ } @storedValues) ||
	                ((scalar @storedValues == 0 or !defined $storedValues[0]) && $value eq '') );
	$matched = !$matched if $inverse;

	return $matched;
}

###################
# private methods/functions

=pod

=item * private * _setBackingStore

Sets the per-instance backingstore, from _computeBackingStoreForInstanceName()

=cut

sub _setBackingStore {
	my $self = shift;

	my $class = ref($self);

	my $file = $class->_computeBackingStoreForInstanceName($self->{'instance'});

	# if we have no backing store, we can't be faulted in
	
	if ( defined($file) ) {
		$self->{'_backingStore'} = $file;
	} else {
		$self->{'_backingStore'} = undef;
		$self->_faultedIn();
	}
}

=pod

=item * private * _backingStore()

=item * private * _info()

=item * private * _faultedIn()

=item * private * _unFaultIn()

=item * private * _isFaultedIn()

=item * private * _faultedInTime()

=item * private * _lastStatTime()

=item * private * _readIn()

=item * private * _unReadIn()

=item * private * _isReadIn()

=item * private * _dirty()

=item * private * _clean()

=item * private * _isDirty()

These methods set and get internal instance variables.

=cut

sub _backingStore {
	my $self = shift;
	
	return $self->{'_backingStore'};
}

sub _info {
	my $self = shift;
	
	return $self->{'_info'};
}

sub _lastStatTime {
	my $self = shift;
	
	return $self->{'_lastStatTime'};

}

sub _faultedInTime {
	my $self = shift;

	return $self->{'_faultedInTime'};
}

sub _faultedIn {
	my $self = shift;

	$self->{'_faultedInTime'} = time();

	$self->{'_faultedIn'} = 1;
}

sub _unFaultIn {
	my $self = shift;

	$self->{'_faultedIn'} = 0;
}

sub _isFaultedIn {
	my $self = shift;

	return $self->{'_faultedIn'};
}

sub _readIn {
	my $self = shift;

	$self->{'_readIn'} = 1;
}

sub _unReadIn {
	my $self = shift;

	$self->{'_readIn'} = 0;
}

sub _isReadIn {
	my $self = shift;

	return $self->{'_readIn'};
}

sub _dirty {
	my $self = shift;

	$self->{'_dirty'} = 1;
}

sub _clean {
	my $self = shift;

	$self->{'_dirty'} = 0;
}

sub _isDirty {
	my $self = shift;

	return $self->{'_dirty'};
}

sub _builtForeignObjectsList {
	my $self = shift;

	$self->{'_builtForeignObjectsList'} = 1;
}

sub _needsToBuildForeignObjectsList {
	my $self = shift;

	$self->{'_builtForeignObjectsList'} = 0;
}

sub _hasBuiltForeignObjectsList {
	my $self = shift;

	return $self->{'_builtForeignObjectsList'};
}

=pod

=item * private * _faultInData()

_faultInData does most of the dirty-work of walking the objectMap, and
faulting in the foreign objects.

=cut

sub _faultInData {
	my $self = shift;
	my %data = ();

	return $self if $self->{'_faultedIn'};

	$self->_readStateFromFile(0) unless ($self->_isReadIn());

	$_objectsLoadedFromDisk++;

	$self->_faultedIn();

	# Now walk keys of %data, looking
	# for refs to other objects based on the objectLoadMap

	my $class = ref($self);
	my $map = $class->objectLoadMap();

	for my $attr ( $self->attributes() ) {

		if (defined $map->{$attr}) {
		
			my $refClass = $map->{$attr};
			my @values   = ();

			# See if the value is an ARRAY container
			# but don't parse arrays of objects.
			if ($refClass =~ s/^(?:@|%)//o) {

				# attribute can sometimes be a packed array,
				# and sometimes a real array
				# If we have foreign keys we pass through this
				# *twice*, first time we explode the
				# stringified array; second time it's already
				# exploded
			
				@values = $self->attribute($attr);	

				if ( defined($values[0]) && $values[0] =~ /<ARRAY>/ ) {
					@values = split(/<ARRAY>\s*/, $values[0]);	
				}

				#if ( defined(my $value = $self->attribute($attr) ) ) {
				#	@values = split(/<ARRAY>\s*/, $value);
				#}

			} else {
				push(@values, $self->attribute($attr));
			}

			# if the value is key to a foreign object,
			# lazy load those objects.
			if ( $refClass eq "SCALAR" ) {
				$self->setAttribute($attr, @values);

			} elsif (!$self->_hasBuiltForeignObjectsList()) {

				# set for debugging purposes.
				$self->setAttribute($attr, '_notFaultedIn');

				# a real class
				$self->{'_notFaultedIn'}->{$attr}->{'class'}  = $refClass;
				$self->{'_notFaultedIn'}->{$attr}->{'values'} = \@values;
			}

		} else {
			my $value = $self->attribute($attr);

			if ( defined($value) && $value =~ s/<ARRAY>/,/g ) {

				# force the typemap when this is really a scalar
				$self->{'_typemap'}->{$attr} = 'SCALAR';
				$self->setAttribute($attr, $value);
			}
		}
	}

	# we are calling setAttribute, which normally marks items as dirty.
	# However, for initial loading of objects, that's incorrect behavior.
	$self->_clean();

	return 1;
}

=pod

=item * private * _faultInForeignObjects( $attribute )

The other half of _faultInData. Called when a foreign object is actually
requested, and does the actual loading of the class and instansiation of the
new object.

=cut

sub _faultInForeignObjects {
	my $self = shift;
	my $attr = shift;

	my $refClass = $self->{'_notFaultedIn'}->{$attr}->{'class'};
	my $values   = $self->{'_notFaultedIn'}->{$attr}->{'values'};

	# eval and require are expensive - only do them if needed.
	unless (exists $_LOADED_CLASSES{$refClass}) {
		eval("require $refClass") || _mydie("can't load $refClass $!");
	}
	$_LOADED_CLASSES{$refClass} = 1;

	my @objects = ();
	for my $value (@{$values}) {
		next unless defined($value);
		my $refInstance = $refClass->new($value);
		push(@objects, $refInstance);
	}

	delete $self->{'_notFaultedIn'}->{$attr};

	$self->_builtForeignObjectsList();

	# find out the state before we set in case of clean.
	my $isDirty = $self->_isDirty();

	$self->setAttribute($attr, @objects);

	$self->_clean() unless $isDirty;
}

=pod

=item * _readStateFromFile( $ignorecase )

Opens the backingStore file, and passes it to the stream reader.

Those using a different storage mechanism will want to subclass.

=cut

sub _readStateFromFile {
	my $self = shift;
	my $ignorecase = shift;

	my $file = $self->_backingStore();  

	open(FHD, $file) || return undef;
	$self->_readStateFromStream(\*FHD, $ignorecase);
	close(FHD);

}

=pod

=item * _readStateFromStream( $ignorecase )

Parses of the on-disk data.

=cut

sub _readStateFromStream {
	my $self = shift;
	my $fh = shift;
	my $ignorecase = shift;

	my $assoc = $self->_info();
	my $readTo = $/;

	while( <$fh> ) {
		next if /^[;#]/o;
		chomp;
		last if /^$/o;
		next if /^\s*$/o;
		my ($field,$value) = split /:\s*/o,$_,2;
		$field =~ tr/A-Z/a-z/ if $ignorecase;

		if ($value) {

			# TMID 7712
			# trim trailing whitespaces
			$value =~ s/\s*$//;

			# array support
			$value =~ s/\\,/<COMMA>/go;
			$value =~ s/,/<ARRAY>/go;
			$value =~ s/<COMMA>/,/go;
		
			# multiline values
			if ($value eq '<MULTILINE>') {
				$/ = "</MULTILINE>\n";
				$value = <$fh>;
				$/ = $readTo;
				$value =~ s|</MULTILINE>\n?$||o;
			}
		}
		$assoc->{$field} = $value;
	}
	$self->_readIn();

}

=pod

=item * _saveStateToFile( $recursive )

Opposite of _readStateFromFile.

Those using a different storage mechanism will want to subclass.

=cut

sub _saveStateToFile {
	my $self = shift;
	my $recursive = shift;

	my $file = $self->_backingStore();  

	my ($tmpFileName, $tmpFileDir) = fileparse($file);
	my $tmpFile = "$tmpFileDir.$tmpFileName.$$";

	mkpath(dirname($tmpFile));
	open(FH, "> $tmpFile") || do {
		warn "can't _saveStateToFile to $file: $!";
		return 0;
	};

	my @toSave = $self->_saveStateToStream(\*FH, $recursive);

	close(FH) || do {
		warn "can't close file: [$tmpFile]: $!";
		return 0;
	};

	rename($tmpFile, $file) || do {
		 warn "_saveStateToFile: can't rename $tmpFile to $file: $!";
		 unlink($tmpFile);
		 return 0;
	};

	$self->_clean();

	if ( $recursive ) {
		for my $object (@toSave){
			return 0 unless $object->recursiveSave();
		}
	}

	return 1;
}

=pod

=item * _saveStateToStream( $fh, $recursive, $indent )

Bundles the object up into a format suited for saving on disk.

=cut

sub _saveStateToStream {
	my $self = shift;
	my $fh = shift;
	my $recursive = shift;
	my $indent = shift || "";

	my @toSave = ();

	for my $attribute ( sort $self->attributes() ){
		my @values = $self->attribute($attribute);
		my $value = $values[0];

		my $isArray = 0;
		if ( defined($self->{'_typemap'}->{$attribute}) &&
			$self->{'_typemap'}->{$attribute} =~ /@/) {
			$isArray = 1;
		}

		my $isHash = 0;
		if ( defined($self->{'_typemap'}->{$attribute}) &&
			$self->{'_typemap'}->{$attribute} =~ /%/) {
			$isHash = 1;
		}

		#
		# This is an ARRAY
		#
		if ( scalar(@values) > 1 || $isArray || $isHash) {
			my @toPrint;
			@values = %{$value} if ($isHash);
			for my $val (@values) {
				next if !defined($val);
				if( ref($val) ) {
					if ( $val->isa("ariba::Ops::PersistantObject") ){
						push(@toSave, $val) if ($recursive);
						$val = $val->instance();
					}
				} else {  # scalar array
					$val =~ s/,/\\,/go;
				}
			    push(@toPrint, $val);
			}
			print $fh $indent, $attribute, ": ", join(", ", @toPrint), "\n";
		} elsif ( defined($value) && ref($value) && ref($value) ne 'CODE' ) {
			if ( $value->isa("ariba::Ops::PersistantObject") ){
				push(@toSave, $value) if ($recursive);
				$value = $value->instance();
			}
			print $fh $indent, $attribute, ": ", $value, "\n";
		} elsif ( defined($value) && $value =~ m|\n| ){
			print $fh $indent, $attribute, ": <MULTILINE>\n", $value, "</MULTILINE>\n";
		} elsif (defined($value)) {
			print $fh $indent, $attribute, ": ", encode_utf8($value), "\n";
		} else {
			print $fh $indent, $attribute, ":\n";
		}
	}
	return @toSave;
}

=pod

=item * _removeState()

Physically removes the object from disk.

=cut

sub _removeState {
	my $self = shift;
	
	my $file = $self->_backingStore();  
	if (defined($file)) {
		unlink($file) || return 0;
	}

	return 1;
}

=pod

=item * _matchPropertiesInObjects()

Loop over all our objects, looking for potential matches.
This takes a mandatory hash ref of field=>value mappings to search
for, and an optional array ref pointing to the list of objects
to search.  If the second arg is undef this will attempt to
fault-in all PersistantObjects of this class type and search those.

The fields are ANDed together, i.e. all fields have to match.
If a field has multiple values, e.g.  
   providesServices => storage,bastion
then they are ORed together, so within a field only one value has
to match for that field to match.

If the value for a field is empty-string it will match PersistiontObjects 
that either do not have the field set or set to empty-string.

Preceding a field by a bang ( ! ) will invert the meaning, causing
a match to occur if the search field's value does not match any values in 
the object.  Please note that specifying multiple search values in the
inverted match case will cause a match to happen if any of the values
do not match.  That is, this

   !providesServices => storage,bastion

will match like 

    !storage || !bastion

returning false (no match) only if providesServices has both storage and
bastion.

This is somewhat counter-intuitive in that it would be more useful to 
match like
    ! ( storage || bastion )
or equivalently
    !storage && !bastion

=cut

sub _matchPropertiesInObjects {
	my ($class, $fieldMatchMapRef, $objectsRef) = @_;

	# create parallel arrays for multiple values
	my (@objects, @fieldKeys, @fieldValues, @intersection, %uniqueKeys);

	while (my ($field, $value) = each %$fieldMatchMapRef) {

		next unless defined $value;

		if ( $value eq '' ) {
			push @fieldKeys, $field;
			push @fieldValues, $value;
		} else { 
			for my $subValue ( split /,/, $value ) {

				$subValue =~ s/^\s*//g;
				$subValue =~ s/\s*$//g;

				push @fieldKeys, $field;
				push @fieldValues, $subValue;
			}
		}

		$uniqueKeys{$field} = 1;
	}

	# We need uniqueKeys, because when passed 3 match fields, but the value
	# is multiple like: datacenter => snv, bou - @fieldKeys becomes 4,
	# when we only need to match 3.
	my $neededKeys = scalar keys %uniqueKeys;

	unless ($objectsRef) {

		# SLUUUURP!
		if ($class->isSmartCacheEnabled() || !$class->hasLoadedAllObjects()) {
			$class->listObjects();
			$class->setHasLoadedAllObjects();
		} 

		@objects  = $class->_listObjectsInCache();

	} else {

		@objects  = @$objectsRef;
	}
	
	for my $object (@objects) {

		my %matchedKeys;

		# map key field to multiple value field
		for ( my $i = 0; $i <= $#fieldKeys; $i++ ) {

			if ( $object->matchField( $fieldKeys[$i], $fieldValues[$i] ) ) {
				$matchedKeys{$fieldKeys[$i]} = 1;
			}
		}

		if ($neededKeys == scalar(keys(%matchedKeys))) {
			push @intersection, $object;
		}
	}

	return @intersection;
}

sub _mydie {

	warn @_, "\n";
	__dumpStack();
	exit(1);
}

sub __dumpStack {
	my $frame = 1;

	print STDERR "Stack trace ----\n";

	while( my ($package, $filename, $line, $subroutine,
				$hasargs, $wantarray, $evaltext, $is_require)
				= caller($frame++) ){

		print STDERR "   frame ", $frame-2, ": $subroutine ($filename line $line)\n";
	}

	return 1;
}

sub __dumpCache {
	my $class  = shift;
	my $dumper = shift || 0;
	my $peek   = shift || 0;

	print STDERR "In __dumpCache for $class\n";

	if ($dumper && eval "use Data::Dumper" && $@ !~ /Can't/) {
		
		print STDERR "\%_OBJECTS cache:\n";
		print Dumper(\%_OBJECTS);

		print STDERR "\%_LOADED_CLASSES cache:\n";
		print Dumper(\%_LOADED_CLASSES);
	}

	if ($peek && eval "use Devel::Peek" && $@ !~ /Can't/) {

		$Devel::Peek::pv_limit = 0;

		Dump(%_OBJECTS);

		$Devel::Peek::pv_limit = 128;
	}

	eval "use Devel::Size qw(size total_size)";

	my @object_classes = keys %_OBJECTS;

	my $objCount = scalar(@object_classes);

	print STDERR "$objCount CLASSES\n";
	for my $c (@object_classes) {
		my $objLength = exists($_OBJECTS{$c}) ? scalar keys %{$_OBJECTS{$c}} : -1;
		my $obj_size = total_size($_OBJECTS{$c});
		my $loc_counter = $_LOCATIONS{$c} || 0;

		print STDERR "$c $objLength ($obj_size), _location counter = $loc_counter\n";
	}
	print STDERR "\n\n";
}

1;

__END__

=pod

=back

=head1 AUTHOR

Dan Grillo <grio@ariba.com>, Dan Sully <dsully@ariba.com>, Manish Dubey <mdubey@ariba.com>

=cut

