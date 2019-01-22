package ariba::Ops::ClassDBIBase;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/ClassDBIBase.pm#6 $

use strict;
use base qw(Class::DBI);
use Class::DBI::AbstractSearch;

my $debug = 0;

BEGIN {
	$ENV{'ORACLE_HOME'} = '/usr/local/oracle';
}

sub new {
	my $class = shift;
	my $instance = shift;

	my $primary = $class->columns('Primary');

	return $class->find_or_create({ $primary => $instance });
}

sub newWithDetails {
	my $class = shift;
	my $data  = shift;

	return $class->find_or_create($data);
}

sub listObjects {
	my $class = shift;

	return $class->retrieve_all();
}

sub _objectWithNameExistsInBackingStore {
	my $class  = shift;
	my $object = shift;

	if ($class->retrieve($object)) {
		return 1;
	}

	return undef;
}

# have persistantobject like setFoo mutators.
sub mutator_name {
	my ($class, $column) = @_;
	return "set\u$column";
}

sub debug {
	my $class = shift;
	return $debug;
}

sub setDebug {
	my $class = shift;
	$debug = shift;
}

# instance methods

# make this look more like PersistantObject

sub instance {
	my $self = shift;
	return $self->id();
}

sub attributes {
	my $self = shift;

	my $class = ref($self);

	return $class->columns();
}

sub attribute {
	my ($self,$attribute) = @_;
	return $self->get($attribute);
}

sub setAttribute {
	my ($self,$attribute,$value) = @_;
	return $self->set($attribute,$value);
}

sub hasAttribute {
	my ($self,$attribute) = @_;

	my $class = ref($self);

	return $class->has_column($attribute);
}

sub recursiveSave {
	my $self = shift;

	$self->save();
}

sub save {
	my $self = shift;

	$self->update();
}

sub remove {
	my $self = shift;
	return $self->delete();
}

sub print {
	my $self  = shift;

	my $class = ref($self);

	# array context lets us handle multi-column primary keys.
	print join('.', $self->id()) . "\n";

	for my $column ($class->columns('All')) {

		# this is needed if the accessor was mutated.
		$column = $class->accessor_name($column);

		print "\t$column: " . (defined($self->$column()) ? $self->$column() : '') . "\n";
	}
}

sub _isDirty {
	my $self = shift;
	return $self->is_changed();
}

1;

__END__
