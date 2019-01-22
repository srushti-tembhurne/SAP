package ariba::Ops::InstanceTTLPersistantObject;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/InstanceTTLPersistantObject.pm#3 $

use strict;

use ariba::Ops::DateTime;
use ariba::Ops::TTLPersistantObject;

use base qw(ariba::Ops::TTLPersistantObject);

my $oneHour = 60 * 60;

# Class methods

sub _isTimeToPurgeClass {
        my $class = shift;

        my $lastPurgedTime = $class->_lastPurgedTimeForClass();

        if ( $lastPurgedTime && ( time() > $lastPurgedTime + $oneHour ) ) {
                return 1;
        } else {
                return undef;
        }
}

# Instance Methods

sub ttl {
	my $self = shift;

	# our superclass has a class method of TTL
	# we need to provide a real method because the runtime will
	# find that before it will find our autoloaded instance methods
	return $self->attribute('ttl');
}

sub timeUntilExpires {
	my $self = shift;

	return ( $self->creationTime() + $self->ttl() ) - time();
}

sub print {
        my $self = shift;
        my $ds   = shift || *STDOUT;

        print $ds $self->instance(),"\n";

	my $indent = "    ";

	for my $attribute ( $self->attributes() ) {

		next if $attribute eq 'creationTime' || $attribute eq 'ttl';

		print $ds $indent . $attribute . ": ";
		
		my $value = $self->attribute($attribute);

		print $ds $value . "\n";

	}

	print $ds $indent . "Starts on " . scalar(localtime($self->creationTime()));
	print $ds " with TTL of " . ariba::Ops::DateTime::scaleTime($self->ttl()) . "\n";
	print $ds "Expires in ". ariba::Ops::DateTime::scaleTime($self->timeUntilExpires())."\n";
}

sub _isExpired {
        my $self = shift;

	my $ttl = $self->ttl();
	my $creationTime = $self->creationTime();

        if ( $ttl && $creationTime && time() > $creationTime + $ttl ) {
                return 1;
        } else { 
                return undef;
        }
}

=pod

=head1 FORCING PER INSTANCE TTL

It is possible to use TTLPersistantObject has the superclass for
a subclass that has a per-instance TTL.   This was not the goal
of TTLPersistantObject, but it works.  This API will change
when this becomes a first-class feature!

Recipe for creating a per-instance TTL subclass.

1. Implement the PersistantObject standard $class->dir() method.

2. In your subclass implement $class->_isTimeToPurgeClass() like so:

=over 4

sub _isTimeToPurgeClass {
        my $class = shift;

	my $lastPurgedTime = $class->_lastPurgedTimeForClass();

        if ( $lastPurgedTime && (  time() > $lastPurgedTime + $oneHour ) ) {
                return 1;
        } else {
                return undef;       
        }
}

=back

3.  In your subclass implement $instance->ttl() like so:

=over 4

sub ttl {
        my $self = shift;

        # our superclass has a class method of TTL
        # we need to provide a real method because the runtime will
        # find that before it will find our autoloaded instance methods

        return $self->attribute("ttl");
}

=back

4.  In your subclass implement $instance->timeUntilExpires()

=over 4

sub timeUntilExpires {
        my $self = shift;

        my $ttl = $self->ttl();
        my $creationTime = $self->creationTime();

        return ( $creationTime + $ttl ) - time();
}

=back

5.  In your subclass implement $class->newWithDetails() and make sure it calls:

=over 4

        $self->setCreationTime($time);
        $self->setTtl($ttl);     

=back

6. In your subclass implement $class->_isExpired() like:

=over 4

sub _isExpired {
        my $self = shift;

        my $ttl = $self->ttl();
        my $creationTime = $self->creationTime();

        if ( $ttl && $creationTime && time() > $creationTime + $ttl ) {
                return 1;
        } else {
                return undef;
        }
}

=back

The class ariba::Ops::PageFilter is an example of a subclass of
TTLPersistantObject with per-instance TTLs.

=cut

1;
