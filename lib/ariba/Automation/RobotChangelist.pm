package ariba::Automation::RobotChangelist;

use strict;
use warnings;
use vars qw ($AUTOLOAD);
use Carp;
use Data::Dumper;
use ariba::Automation::Remote::Robot;
use ariba::Automation::Constants;
use ariba::Automation::Releases2;

## TODO: Change this to path provided by Constants
my $config_file = "/home/rc/etc/releases2.xml";

{
    #
    # Constructor
    #
    sub new
    {
        my ($class) = @_;
        my $self = 
        {
            'release_manager' => new ariba::Automation::Releases2 ($config_file),
            'success' => 0, 
            'last_error' => "", 
        };
        bless ($self,$class);
        return $self;
    }
    
    #
    # Accessors
    #
    sub AUTOLOAD
    {
        no strict "refs";
        my ($self, $newval) = @_;

        my @classes = split /::/, $AUTOLOAD;
        my $accessor = $classes[$#classes];

        if (exists $self->{$accessor})
        {
            if (defined ($newval))
            {
                $self->{$accessor} = $newval;
            }
            return $self->{$accessor};
        }
        carp ref ($self) . " Unknown method: $accessor\n";
    }

    #
    # Destructor
    #
    sub DESTROY
    {
        my ($self) = @_;
    }

    #
    # Static method: Backward compatibility with cron-build logging format
    #
    sub info
    {
        my ($format, @args) = @_;
        my $time = POSIX::strftime("%H:%M:%S", localtime);
        printf "cron-build %s: $format\n", $time, @args;
    }

    #
    # True if getLastGood() returned valid data during last call
    #
    sub is_success
    {
        my ($self) = @_;
        return $self->{'success'};
    }

    sub get_last_error
    {
        my ($self) = @_;
        return $self->{'last_error'};
    }

    #
    # Code to reset internals
    #
    sub reset
    {
        my ($self) = @_;
        $self->{'success'} = 0;
        $self->{'last_error'} = "";
    }

    #
    # Facade for _getLastGood method to iterate over groups:
    #
    sub getLastGood
    {
        my ($self, $branch, $cutOff, $product, $release) = @_;

        $self->reset();
        my $goodChange = 0;
        my @groups = $self->{'release_manager'}->get_groups ($release, $product, "mainline");

        foreach my $group (@groups)
        {
	    info ("[Robot] Checking the robot group #$group");
            $goodChange = $self->_getLastGood ($branch, $cutOff, $product, $release, $group);
            if (! $goodChange)
            {
                info ("No good change for group #$group: [" . $self->{'last_error'} . "] ... Trying next group...");
                next;
            }
	    else
	    {
		info ("[Robot] Robot group #$group has a good changelist, $goodChange");
		last;
	    }
        }

        return $goodChange;
    }

    #
    # Private
    #
    # Get last good changelist from a set of robots given the 
    # branch + cutOff time + product + release
    #
    sub _getLastGood
    {
        my ($self, $branch, $cutOff, $product, $release, $group) = @_;

        # Read the list of robots that we'll need to check
        my ($myProduct, $otherProduct, @myRobots, @otherRobots);

        $myProduct = $product;
        $myProduct = "asm" if (lc($myProduct) eq "s4");
        $otherProduct = "asm" if (lc($myProduct) eq "buyer");
        $otherProduct = "buyer" if (lc($myProduct) eq "asm");   # Hard coding a few values related to product names

        my %mainline = $self->{'release_manager'}->get_mainline_robots ($group);

        foreach my $robot (keys %mainline)
        {
            my $roleinfo = $self->{'release_manager'}->get_robot_role ($robot);
            my ($robotRelease, $robotProduct, $robotPurpose, $robotRole) = @$roleinfo;

            if ($robotRelease eq $release && $robotProduct eq $myProduct)
            {
                my $instance = $self->{'release_manager'}->get_instance_by_host($robot);
                push (@myRobots,$instance);
            }

            if ($robotRelease eq $release && $robotProduct eq $otherProduct)
            {
                my $instance = $self->{'release_manager'}->get_instance_by_host($robot);
                push (@otherRobots,$instance);
            }
        }

        my @robots = (@myRobots,@otherRobots);

        info ("[Robot] Checking if the mainline robots @robots are green");

        my $highestGoodChange = 0;

        foreach my $robotName (@robots)
        {
            info ("  [Robot] Reading info about the robot $robotName");

            # The following needed to have the remote robot modules function
            # properly
            my $rootDir = ariba::Automation::Constants->serverRootDir();
            ariba::Automation::Constants->setBaseRootDirectory($rootDir);

            my $lastRunTime;
            my $robot = ariba::Automation::Remote::Robot->newFromNameNoInit($robotName);
            my $lastGoodChange = $robot->lastGoodChange();
            my $lastGoodChangeTime = $robot->lastGoodChangeTime();
            my $currentStatus = $robot->status;
            my $currentState = $robot->state;

            # Check if you have received the values
            if (! ($lastGoodChange && $lastGoodChangeTime))
            {
                $self->{'last_error'} = "Unable to find out the lastGoodChangelist for the robot $robotName";
                return 0;
            }

            if ($currentStatus =~ /FAILURE/i)
            {
                $self->{'last_error'} = "Your robot, $robotName, is currently failing. We'll not initiate the build now.";
                return 0;
            }

            # Use robots only belonging to myProduct to calculate the
            # highest lastGoodChange
            if (grep {$_ eq $robotName} @myRobots)
            {
                info (  "  [Robot] Last good change of $robotName is $lastGoodChange");
                # We'll pick the highest lastGoodChange
                $highestGoodChange = $lastGoodChange if ($lastGoodChange > $highestGoodChange);
            }
        }

        info ("[Robot] Highest good change is $highestGoodChange");
        return ($highestGoodChange);
    }
}

1;
