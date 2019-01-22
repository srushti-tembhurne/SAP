package ariba::monitor::LogMiner::Plugin;

#
# Base class for all LogMiner plugins
#

=head1 NAME

ariba::monitor::LogMiner::Plugin - base class for LogMiner plugins

=head1 SYNOPSIS

Base class for LogMiner plugins.  To use, provide full implementations of the abstract methods in the the sub-class.

=cut

use ariba::Ops::PersistantObject;

use base qw(ariba::Ops::PersistantObject);

my $OVERRIDE_NOT_FOUND_MSG = "This needs to be overridden";

sub dir { return undef; }

sub newFromPluginClass {
	my $class  = shift;
	my $pluginClass = shift;
	my $argHashRef = shift;

	eval "use $pluginClass";

	if ($@) {
		die "Couldn't load class $pluginClass: $@";
	}

	my $plugin = $pluginClass->new();
	$plugin->initFromHashRef($argHashRef);

	return $plugin;
}

sub initFromHashRef {
	my $self = shift;
	my $argHashRef = shift;

	if ($argHashRef && keys %$argHashRef && ref($argHashRef) eq "HASH") {
		for my $key (keys %$argHashRef) {
			$self->setAttribute($key, $argHashRef->{$key});
		}
	}
}

=head1 ABSTRACT METHODS

These must be overriden.

=over 4

=cut


=item processFile ( FilePath ) 

Performs some operation/parsing on file given by FilePath

=cut 

sub processFile { die $OVERRIDE_NOT_FOUND_MSG; }

=item printReport ( FilePath ) 

Writes final report to file specified by FilePath.

=cut

sub printReport { die $OVERRIDE_NOT_FOUND_MSG; }

=item usage 

Prints available module options.

=cut

sub usage { die $OVERRIDE_NOT_FOUND_MSG; }

=item descriptionString

Returns a description of the module; used in determining report path

=back

=cut

sub descriptionString { return "plugin"; }

1;
