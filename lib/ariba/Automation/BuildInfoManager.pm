package ariba::Automation::BuildInfoManager;

# 
# Manage BuildInfo instances:
#
# - Add BuildInfo object to manager
# - Provide iterator in get_next method
# - Manage index of run log paths to BuildInfo objects
#

use strict 'vars';
use warnings;
use vars qw ($AUTOLOAD);
use Carp;

{
#
# Build Info defaults
#
my %_attr_data =
    (
	  _current => [ 0, "rw" ], 
	  _buildInfos => [ "", "rw" ],
	  _runLogIndex => [ "", "rw" ],
    );

#
# Private method to manage attribute access
#
sub _accessible
    {
    my ($self, $attr, $mode) = @_;
    $_attr_data{$attr}[1] =~ /$mode/
    }

#
# Private method to get default for attributes
#
sub _default_for
    {
    my ($self, $attr) = @_;
    $_attr_data{$attr}[0];
    }

#
# Private method gives access to attributes
#
sub _standard_keys
    {
    keys %_attr_data;
    }

#
# Constructor
#
sub new
    {
    my ($caller, %arg) = @_;
    my $caller_is_obj = ref($caller);
    my $class = $caller_is_obj || $caller;
    my $self = bless {}, $class;
    foreach my $membername ( $self->_standard_keys() )
        {
        my ($argname) = ($membername =~ /^_(.*)/);
        if (exists $arg{$argname})
            { $self->{$membername} = $arg{$argname} }
        elsif ($caller_is_obj)
            { $self->{$membername} = $caller->{$membername} }
        else
            { $self->{$membername} = $self->_default_for($membername) }
        }

    return $self;
    }

#
# Tell BuildInfoManager about BuildInfo class
#
sub add
	{
	my ($self, $buildInfo) = @_;

	#
	# Add to list of BuildInfo classes
	#
	my $buildInfos = $self->get_buildInfos();
	push @$buildInfos, $buildInfo;
	$self->set_buildInfos ($buildInfos);

	# 
	# Add to map of run log path => BuildInfo class
	#
	my $runLogIndex = $self->get_runLogIndex();
	my $runLogPath = join "/", $buildInfo->get_logDir(), $buildInfo->get_logFile();
	$runLogIndex->{$runLogPath} = $buildInfo;
	}

#
# Get next BuildInfo class
#
sub get_next
    {
    my ($self) = @_;

    my $current = $self->get_current();
    my $buildInfoList = $self->get_buildInfos();

	if ($current > $#$buildInfoList)
		{
		$current = 0;
		return;
		}

	my $buildInfo = $$buildInfoList[$current];

	$self->set_current (++$current);

	return $buildInfo;
	}

#
# Get all build info as a list
#
sub getBuildInfoList
	{
	my ($self) = @_;
	return $self->get_buildInfos();
	}

#
# Accessor to fetch BuildInfo class from map of run logs
#
sub getBuildInfoByRunLog
	{
	my ($self, $runLog) = @_;
	my $runLogIndex = $self->get_runLogIndex();
	return $runLogIndex->{$runLog};
	}

#
# Auto-generate class accessors
#
sub AUTOLOAD
    {
    no strict "refs";
    my ($self, $newval) = @_;

    # getter
    if ($AUTOLOAD =~ /.*::get(_\w+)/ && $self->_accessible($1,'r'))
        {
        my $attr_name = $1;
        *{$AUTOLOAD} = sub { return $_[0]->{$attr_name} };
        return $self->{$attr_name}
        }

    # setter
    if ($AUTOLOAD =~ /.*::set(_\w+)/ && $self->_accessible($1,'rw'))
        {
        my $attr_name = $1;
        *{$AUTOLOAD} = sub { $_[0]->{$attr_name} = $_[1] };
        $self->{$1} = $newval;
        return
        }

    # complain if we couldn't find a matching method
    carp "no such method: $AUTOLOAD";
    }

#
# Destructor
#
sub DESTROY
    {
    my ($self) = @_;
    }
}

1;
