package ariba::Ops::TTLPersistantObject;

use strict;
use vars qw(@ISA);
use ariba::Ops::PersistantObject;

use File::Path;
use File::Basename;

@ISA = qw(ariba::Ops::PersistantObject);

=pod

=head1 NAME

ariba::Ops::TTLPersistantObject

=head1 VERSION

$Id: //ariba/services/tools/lib/perl/ariba/Ops/TTLPersistantObject.pm#8 $

=head1 SYNOPSIS

 package ariba::Ops::ExpiringObject;

 use strict;
 use vars qw(@ISA);
 use ariba::Ops::TTLPersistantObject;

 @ISA = qw(ariba::Ops::TTLPersistantObject);

 sub dir {
	my $class = shift;
	return '/tmp/foo'; # physical path to data objects
 }

 # Time To Live, in seconds
 sub ttl {
	my $class = shift;
	return 60 * 60 * 24; # one day
 }

=head1 DESCRIPTION

TTLPersistantObject subclasses PersistantObject, and adds methods for 
removing objects after a set amount of time (time to live). It should 
be subclassed to handle the specific requirements of a given 
application.

Use this class if you want a common TTL per *class*, not per instance.
Please see ariba::Ops::InstanceTTLPersistantObject for per-instance TTLs.

Upon initialization of a TTLPersistantObject, the following things 
happen:

1) A PersistantObject is created

2) If the object which has been initialized has expired, it will 
be as if you are creating a new object from scratch.

3) The creation time of the '.lastPurged' file in the current 
backing store directory is checked, and:

4) If the creation time of '.lastPurged' is less than the current
time minus the TTL for the subclass, then any objects who have exceeded
their TTL will be removed.

Refer to the PersistantObject documentation for more information.

=head1 PUBLIC CLASS METHODS

=over 4

=item * new($id)

Initialize a new TTLPersistantObject.

=cut

sub new {
	my $class = shift;
	my $id = shift;

	# house keeping
	# this isn't really needed, but keeps
	# our backingstore clean, at some cost

	if ($class->_isTimeToPurgeClass()){
		$class->_removeExpiredObjectsInClass();
	}

	unless (defined($id)) {
		return undef;
	}

	my $self = $class->SUPER::new($id);
        bless($self, $class);

	if ($self->_isExpired()){
		$self->_destroy();
		return undef;
	}

	return $self;
}

=pod

=item * ttl()

The TTL (Time To Live) for objects of the current class. The unit of 
measurement is seconds. Subclasses may wish to override this method 
with a more appropriate value for the given task. Unless overridden,
this returns 60*60*24 (one day).

=cut

sub ttl {
	my $class = shift;

	return 60 * 60 * 24; # one day
}

sub dir {
	my $class = shift;

	die $class . " is an abstract class, you must subclass this and implement dir() class method to use.\n";
}

=pod

=item * listObjects()

List all objects in the current class which are not expired.

=cut

sub listObjects {
	my $class = shift;

	# allocate all the objects in the backing store
	# some will be expired, so fix that up

	my @objs = $class->SUPER::listObjects();
	my @newObjs;

	for my $obj ( @objs ) {
		if ( $obj ) {
			push(@newObjs, $obj);
		}
	}

	return @newObjs;
}

=pod

=back

=head1 PROTECTED INSTANCE METHODS

=over 4

=item * _ctime()

Return the creation time of this object, in Unix epoch seconds.

=cut

sub _ctime {
	my $self = shift;

	my $path = $self->_backingStore();

	my @stat = stat($path);

	my $ctime = $stat[10];

	return $ctime;
}

=pod

=item * _mtime()

Return the last modified time of this object, in Unix epoch seconds.

Not used by TTLPersistantObject, but exists in case it is needed by a subclass.

=cut

sub _mtime {
	my $self = shift;

	my $path = $self->_backingStore();

	my @stat = stat($path);

	my $ctime = $stat[9];

	return $ctime;
}

=pod

=item * _isExpired()

Determine if this object has expired or not

=cut

sub _isExpired {
	my $self = shift;

	unless ( -e $self->_backingStore() ){
		return undef;
	}

	my $class = ref($self);

	if (($self->_ctime() + $class->ttl()) < time()) {
		return 1;
	} else {
		return undef;
	}
}

=pod

=item * _destroy

Remove the object from disk and cache. Wipe the attributes.

=cut

sub _destroy {	
	my $self = shift;

	$self->expirationAction();
	$self->remove();
	$self->deleteAttributes();
}

=pod

=item * expirationAction()

This hook is called when an object expires.  The default is an empty
method, but your subclass can override it.

=cut

sub expirationAction {
	my $self = shift;
	return(1);
}

=pod

=head1 PROTECTED CLASS METHODS

=over 4

=item * _isTimeToPurgeClass()

Determine if it is time to purge expired objects

=cut

sub _isTimeToPurgeClass {
	my $class = shift;

	my $lastPurgedTime = $class->_lastPurgedTimeForClass();

	if ($lastPurgedTime && ( $lastPurgedTime + $class->ttl() < time() ) ) {
		return 1;
	} else {
		return undef;
	}
}

=pod

=item * _lastPurgedTimeForClass()

Return the time, in Unix epoch seconds, indicating when objects of this class were last purged.

=cut

sub _lastPurgedTimeForClass {
	my $class = shift;

	my $path = $class->_pathToLastPurgedTimeFile();

	# Touch the lastPurged file if it does not exist yet
	unless ( -e $path ) {

		my $dir = dirname($path);
		mkpath($dir) unless (-d $dir);

		open(DATEFILE,">$path");
		close(DATEFILE);
	}

	my @stat = stat($path);
	my $purgeTime = $stat[9];

	return $purgeTime;
}

=pod

=item * _removeExpiredObjectsInClass()

Purge out all objects which have expired

=cut

sub _removeExpiredObjectsInClass {
	my $class = shift;

	$class->_updateLastPurgedTimeFile();

	# simply calling listObjects() will do the work
	$class->listObjects();

	return 1;
}

=pod

=item * _pathToLastPurgedTimeFile()

Return the path to the file indicating the time that objects were last purged

=cut

sub _pathToLastPurgedTimeFile {
	my $class = shift;

	return $class->dir().'/.lastPurged';
}

=pod

=item * _updateLastPurgedTimeFile()

Update the file which indicates the time that objects were last purged

=back

=cut

sub _updateLastPurgedTimeFile {
	my $class = shift;
	my $path = $class->_pathToLastPurgedTimeFile();

	# Touch the file
	open(DATEFILE,">$path");
	close(DATEFILE);
}

=pod

=head1 AUTHORS

Alex Sandbak <asandbak@ariba.com>, Dan Grillo <grio@ariba.com>

=cut

1;
