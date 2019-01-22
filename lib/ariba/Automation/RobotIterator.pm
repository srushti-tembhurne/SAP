package ariba::Automation::RobotIterator;

use strict 'vars';
use warnings;
use vars qw ($AUTOLOAD);
use Carp;
use ariba::Automation::RobotCategorizer;
use ariba::rc::Utils;

{
my %_attr_data =
    (
    _counter => [ 0, "rw" ],
    _robots => [ undef, "rw" ],
    _types => [ undef, "rw" ],
    _teams => [ undef, "rw" ], 
    _debug => [ 0, "rw" ],
    _naptime => [ 1, "rw" ],
    _ssh => [ "/usr/local/bin/ssh", "r" ],
    );

sub _accessible
    {
    my ($self, $attr, $mode) = @_;
    $_attr_data{$attr}[1] =~ /$mode/
    }

sub _default_for
    {
    my ($self, $attr) = @_;
    $_attr_data{$attr}[0];
    }

sub _standard_keys
    {
    keys %_attr_data;
    }

# constructor
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

    my $rc = new ariba::Automation::RobotCategorizer();
    my $buildTypes = $rc->get_buildTypes();
    my (@robots, @robotTypes, @robotTeams, %robotTeams, %robotTypes);

    foreach my $buildType (@$buildTypes)
        {
        my $robots = $rc->buildsByType ($buildType);
        foreach my $i (0 .. $#$robots)
            {
            my $robot = $$robots[$i];
            next unless $robot; 

            $robotTeams{$robot->instance()} = 
                $rc->determineTeam ($robot->targetBranchname(), $robot->team());
            
            $robotTypes{$robot->instance()} = $buildType;

            push @robots, $robot;
            }
        }

    $self->set_robots (\@robots);
    $self->set_teams (\%robotTeams);
    $self->set_types (\%robotTypes);
    return $self;
    }

sub team_by_robot_name
    {
    my ($self, $robotName) = @_;
    my $teams = $self->get_teams();
    return $$teams{$robotName};
    }

sub type_by_robot_name
    {
    my ($self, $robotName) = @_;
    my $types = $self->get_types();
    return $$types{$robotName};
    }

sub next_robot
    {
    my ($self) = @_;

    my $counter = $self->get_counter();
    my $robots = $self->get_robots();
    my $robot = $$robots[$counter];

    if (++$counter >= $#$robots)
        {
        $counter = 0;
        $robot = undef;
        }

    $self->set_counter ($counter);
    return $robot;
    }

sub reset
    {
    my ($self) = @_;
    $self->set_counter (0);
    }

# execute a command against a robot
sub run
    {
    my ($self, $robot, $prog) = @_;
    $prog = $prog || "";

    # fail if caller didn't specify a program to run
    if (! length ($prog))
        {
        carp "Can't run, requires remote program to run...\n";
        return -1;
        }

    # mark start time for debug mode
    my $start = time();

    # get robot info
    my $instance = $robot->instance();
    my $hostname = $robot->hostname();

    # password matches hostname
    my $passwd = $instance;

    # path to ssh binary
    my $ssh = $self->get_ssh();

    # number of seconds to nap between runs
    my $naptime = $self->get_naptime();

    # command to execute
    my $cmd = qq!$ssh -n $hostname -l $instance "$prog && sleep $naptime"!;

    # run it
    ariba::rc::Utils::executeRemoteCommand ($cmd, $passwd);

    # optionally print debug output
    if ($self->get_debug() == 1)
        {
        my $diff = time() - $start;
        my $increment = "s";
        if ($diff > 60)
            {
            $diff = int ($diff / 60);
            $increment = "m";
            }
        }

    0;
    }

# auto-generate class getters/setters
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

sub DESTROY
    {
    my ($self) = @_;
    }
}

1;
