package ariba::Automation::EventAggregator;

#
# Base class for EventAggregators involving robots
#
# Features:
#
# - Load ~rc/etc/releases.conf via ariba::Automation::Releases2
# - Keep a list of robots in releases.conf
# - Fetch robot + global state 
# - Convert robot name to hostname
#
# Children for this class live here: ariba::Automation::EventAggregator 
#

$|++;

use strict 'vars';
use warnings;
use vars qw ($AUTOLOAD);
use Carp;
use Data::Dumper;
use ariba::rc::events::AbstractEventTrigger;
use base ("ariba::rc::events::AbstractEventTrigger");
use ariba::rc::events::Constants;
use ariba::rc::events::client::Event;
use ariba::Automation::Constants;
use ariba::Automation::Releases2;
use ariba::Automation::BuildInfo;
use ariba::Automation::Remote::Robot;
use ariba::rc::Utils;

{
    #
    # Constructor
    #
    sub new
    {
        my ($class) = @_;
        my $self = $class->SUPER::new();

		#
		# Releases class reads ~rc/etc/releases.conf to determine which robots have
		# which responsibilities such as mainline and qual
		#
		$self->{'releases'} = new ariba::Automation::Releases2 (ariba::Automation::Constants::releasesConfigFile2());

		#
		# Fetches list of all robots in release.conf indexed by hostname
		#
		$self->{'robots'} = $self->{'releases'}->get_all_robots();
 
		return $self;
    }

	#
	# TODO: Remove the need for this function
	#
	sub host_to_instance
	{
		my ($self, $hostname) = @_;

		if ($hostname =~ m#^(idc|)buildbox(\d+)\.ariba.com$#)
		{
			my ($is_idc, $robotNumber) = ($1, $2);
			return $is_idc . "robot" . $robotNumber;
		}

		return 0;
	}

	#
	# TODO: Remove the need for this function
	#
	sub instance_to_host
	{
		my ($self, $robotName) = @_;

		if ($robotName =~ m#^(robot|idcrobot)(\d+)$#)
		{
			my ($prefix, $robotNumber) = ($1, $2);
			my $host_prefix = $prefix eq "idcrobot" ? "idc" : "";
			return $host_prefix . "buildbox" . $robotNumber . ".ariba.com";
		}

		return 0;
	}

	#
	# Get Robot + GlobalState from robot name (e.g. robot57)
	#
	sub fetch_robot
	{
		my ($self, $robotName) = @_;
		# 
		# Required by ariba::Automation::Remote::Robot to properly
		# load robot state data from /home/rc/robots ... Too late to
		# run INIT block ... 
		#
		my $rootDir = ariba::Automation::Constants->serverRootDir();
		ariba::Automation::Constants->setBaseRootDirectory($rootDir);

		#
		# Load robot from robot.conf
		#
		my $robot = ariba::Automation::Remote::Robot->newFromNameNoInit ($robotName);

		#
		# Load state from robot state file
		#
		my $globalState = ariba::Automation::GlobalState->newFromName($robot->instance());

		return ($robot, $globalState);
	}

    #
    # Public method generates feeds
    #
    sub execute
    {
	}
}

1;
