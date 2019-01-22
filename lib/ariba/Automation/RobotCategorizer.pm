package ariba::Automation::RobotCategorizer;

# Determine categories and sort order for robots

use strict 'vars';
use vars qw ($AUTOLOAD);
use Carp;
use Data::Dumper;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../lib/perl";
use lib "$FindBin::Bin/../../bin";
use lib "/home/rc/bin/admin/bin";

use ariba::Ops::Url;
use ariba::Ops::DateTime;
use ariba::Automation::Remote::Robot;
use ariba::Automation::Constants;
use ariba::rc::Utils;
use File::Basename;

{
my %_validSortFields =
  (
  "Name" => 1,
  "Team" => 1,
  "Dept" => 1,
  "Host" => 1,
  "State" => 1,
  "Status" => 1,
  "Responsibility" => 1,
  "Build" => 1,
  );

my %_attr_data =
  (
  _robotsByInstance => [ undef, "rw" ],
  _robotsByName => [ undef, "rw" ],
  _robotsByHost => [ undef, "rw" ],

  _sortedByName => [ undef, "rw" ],
  _sortedByTeam => [ undef, "rw" ],
  _sortedByDept => [ undef, "rw" ],
  _sortedByHost => [ undef, "rw" ],
  _sortedByState => [ undef, "rw" ],
  _sortedByStatus => [ undef, "rw" ],
  _sortedByResponsibility => [ undef, "rw" ],
  _sortedByBuild => [ undef, "rw" ],

  _buildTypes => [ undef, "rw" ],
  _builds => [ undef, "rw" ],

  _teams => [ undef, "rw" ],
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

  $self->generateCategories();
  return $self;
  }

# loop over all robots, pre-generate sorted lists
sub generateCategories
  {
  my ($self) = @_;

  my (%robotsByName, %teamsByName, %robotsByHost, %robotsByInstance);
  my (%names, %teams, %depts, %hosts, %state, %status);
  my (%responsibility, %builds);

  my $robots = $self->getRobots();

  # iterate over robots, sort them
  foreach my $robot (@$robots)
    {
    my $team              = $robot->team();
    my $dept              = $robot->dept();
    my $instance          = $robot->instance();
    my $name              = $robot->name() || $instance;
    my $hostname          = $robot->hostname();
    my $responsible       = $robot->responsible() || "";
    my $branch            = $robot->targetBranchname();
    my $status            = $robot->status();
    my $state             = $robot->state();
    my $configFile        = $robot->configFile();

    push @{$names{$self->fix($name)}}, $robot;
    push @{$teams{$self->fix($team)}}, $robot;
    push @{$depts{$self->fix($dept)}}, $robot;
    push @{$hosts{$self->fix($hostname)}}, $robot;
    push @{$state{$self->fix($state)}}, $robot;
    push @{$status{$self->fix($status)}}, $robot;
    push @{$responsibility{$self->fix($responsible)}}, $robot;

    my $buildType = $self->determineCategory ($branch, $robot->productName());

    push @{$builds{$self->fix($buildType)}}, $robot;

    $robotsByName{$name} = $robot;
    $robotsByHost{$hostname} = $robot;
  $robotsByInstance{$instance} = $robot;
    $teamsByName{$self->determineTeam ($branch, $team)} = $team;
    }

  $self->set_sortedByName ($self->sort_by (\%names));
  $self->set_sortedByTeam ($self->sort_by (\%teams));
  $self->set_sortedByDept ($self->sort_by (\%depts));
  $self->set_sortedByHost ($self->sort_by (\%hosts));
  $self->set_sortedByState ($self->sort_by (\%state));
  $self->set_sortedByStatus ($self->sort_by (\%status));
  $self->set_sortedByResponsibility ($self->sort_by (\%responsibility));
  $self->set_sortedByBuild ($self->sort_by (\%builds));
  $self->set_robotsByName (\%robotsByName);
  $self->set_robotsByHost (\%robotsByHost);
  $self->set_robotsByInstance (\%robotsByInstance);

  # generate sorted list of build types
  my %buildTypes;
  foreach my $buildType (sort keys %builds)
    {
    push @{$buildTypes{$buildType}}, @{$builds{$buildType}};
    }
  my @bt = sort keys %buildTypes;
  $self->set_buildTypes (\@bt);
  $self->set_builds (\%buildTypes);

  # generate sorted list of teams
  my @teams;
  foreach my $team (sort keys %teamsByName)
    {
    push @teams, $teamsByName{$team};
    }
  $self->set_teams (\@teams);
  }

# examine branch path to determine team name,
# otherwise default to team name found on robot.conf

sub determineTeam {
    my ($self, $branch, $team) = @_;
    # //ariba/sandbox/build/analysis/s4

    my $teamName = $team;

    # As of 28 Feb 2013, disabling the way Sandbox Team
    # name is determinded. From now, we will rely on
    # robot.conf entry for sandbox team owners
    
    #if ($branch =~ m#//ariba/sandbox/build/([^/]+)#) {
    #    $teamName = $1;
    #    $teamName =~ s#\..*$##;
    #}

    return lc($teamName);
}

# get robot by instance name i.e. robot57
sub fetchRobotByInstance
  {
  my ($self, $robotName) = @_;
  my $robots = $self->get_robotsByInstance();
  return $robots->{$robotName};
  }

# get robot by name (as specified in robot's conf file)
sub fetchRobot
  {
  my ($self, $robotName) = @_;
  my $robots = $self->get_robotsByName();
  return $robots->{$robotName};
  }

# get robot by hostname (i.e. buildbox20.ariba.com)
sub fetchRobotByHost
  {
  my ($self, $hostname) = @_;
  my $robots = $self->get_robotsByHost();
  return $robots->{$hostname};
  }

# attempt to categorize robots by build type. this should
# be generic enough for future builds. second argument
# (product name) is optional.

sub determineCategory
  {
  my ($self, $branch, $productName) = @_;
  $productName = $productName || "";

  my $buildType = "unknown";

  if ($branch =~ m#//ariba/sandbox#)
    {
    $buildType = "sandbox";
    }
  elsif ($branch =~ m#//ariba/([^/]+)/build/(.*)#)
    {
    my ($product, $release) = ($1, $2);
    if ($product && $release)
      {
      $buildType = "$release-$product";
      }
    }
  elsif ($branch eq "//ariba" && $productName eq "an")
    {
    $buildType = "an-mainline";
    }

  return $buildType;
  }

# attempt sub-sorting bots on the fly
sub buildsByType
  {
  my ($self, $type, $sortField) = @_;
  $sortField = $sortField || "Name";
  $sortField = ucfirst ($sortField);

  if (! exists $_validSortFields{$sortField})
    {
    carp "Invalid sort field: $sortField. Valid sort fields are: " . (scalar keys %_validSortFields) . "\n";
    return;
    }

  my $methodName = "get_sortedBy" . $sortField;
  my $robots = $self->$methodName();
  my $category;
  my @robots;

  foreach my $robot (@$robots)
    {
    $category = lc($self->determineCategory ($robot->targetBranchname(), $robot->productName()));
    next unless $category eq $type;
    push @robots, $robot;
    }

  return \@robots;
  }

# clean up sort keys:
# strip unwanted characters, combine whitespace.
sub fix
  {
  my ($self, $buf, $hostName) =@_;
  $hostName = $hostName || "";
  $buf =~ s/["<>]//g;
  $buf =~ s/\s+/ /g;
  return lc ($buf . $hostName);
  }

# generate a sorted list where:
# - key is a sortable string
# - value is a reference to a robot
sub sort_by
  {
  my ($self, $hashref) = @_;
  my @bots;
  foreach my $key (sort keys %$hashref)
    {
    push @bots, @{$hashref->{$key}};
    }
  return \@bots;
  }

# facade in front of listRobots(): someday it will handle robots
# with broken config files.
sub getRobots
  {
  my ($self) = @_;
  my @robots = ariba::Automation::Remote::Robot->listRobots();
  return (\@robots);
  }

# auto-generate class getters/setters
sub AUTOLOAD
  {
  no strict "refs";
  my ($self, $newval) = @_;

  if ($AUTOLOAD =~ /.*::get(_\w+)/ && $self->_accessible($1,'r'))
    {
    my $attr_name = $1;
    *{$AUTOLOAD} = sub { return $_[0]->{$attr_name} };
    return $self->{$attr_name}
    }

  if ($AUTOLOAD =~ /.*::set(_\w+)/ && $self->_accessible($1,'rw'))
    {
    my $attr_name = $1;
    *{$AUTOLOAD} = sub { $_[0]->{$attr_name} = $_[1] };
    $self->{$1} = $newval;
    return
    }

  carp "no such method: $AUTOLOAD";
  }

sub DESTROY
  {
  my ($self) = @_;
  }
}

1;
