package ariba::Automation::EventAggregator::RobotEventAggregator;

#
# Publish robot events to various channels:
#
# - Mainline robots
# - Qual robots
#
# The channel name is generated based on the robot's product i.e.
# 10s2mainline, 10s1qual, etc. 
#

$|++;

use strict 'vars';
use warnings;
use vars qw ($AUTOLOAD);
use Carp;
use Data::Dumper;
use ariba::Automation::EventAggregator;
use base ("ariba::Automation::EventAggregator");
use ariba::rc::events::Constants;
use ariba::rc::events::client::Event;
use ariba::rc::Utils;

{
	# 
	# Constants
	#
	my $MAINLINE_FEED_NAME = "mainline";
	my $QUAL_FEED_NAME = "qual";
	my $FAIL_FEED_NAME = "fail";

    #
    # Constructor
    #
    sub new
    {
        my ($self, $event, $channel) = @_;
        return $self->SUPER::new ($event, $channel);
    }

    #
    # Public method generates feeds
    #
    sub execute
    {
        my ($self, $event, $channel) = @_;

		#
		# Get robot data from RobotCategorizer by instance name (i.e. robot57)
		#
		my $robot = $self->fetch_robot ($channel->name());
		return unless $robot;

		# 
		# Extract hostname from Robot object: releases.conf uses hostname to 
		# map roles to robot
		#
		my $hostname = $robot->hostname();
		return unless exists $self->{'robots'}->{$hostname};
		
		#
		# Get list of mainline robots
		#
		my %mainline = $self->{'releases'}->get_mainline_robots();

		#
		# Republish mainline robot data to feeds named for product
		#
		if (exists $mainline{$hostname})
		{
			return $self->publish (\%mainline, $event, $robot, $hostname, $MAINLINE_FEED_NAME);
		}

		#
		# Get list of qual robots
		#
		my %qual = $self->{'releases'}->get_rc_buildqual_robots();
		
		#
		# Republish qual robot data to feeds named for product
		#
		if (exists $qual{$hostname})
		{
			return $self->publish (\%qual, $event, $robot, $hostname, $QUAL_FEED_NAME);
		}

		return 0;
	}

	#
	# Determine if we should repackage an event
	#
	sub publish
	{
		my ($self, $category, $event, $robot, $hostname, $fragment) = @_;
		
		#
		# Robot role info returned in array form like so:
		# release, product, role, purpose
		# 
		# Example:
		# 10s2, buyer, initdb, qual
		#
		my $roleinfo = $self->{'releases'}->get_robot_role ($hostname);

		#
		# No roles for this host
		#
		if ($#$roleinfo != -1)
		{
			return $self->publish_event ($event, $fragment, @$roleinfo);
		}

		return 0;
	}

	#
	# Re-publish Event 
	#
	sub publish_event
	{
		my ($self, $event, $type, $release, $product, $role, $purpose) = @_;

		#
		# Rewrite channel name
		#

		my $channel_name = $release . $type;
		my $original_channel = $event->channel();

		$event->channel ($channel_name);
		$event->republished (1);
	
		#
		# Send event to server
		#
		my $ok = $event->publish();

		if (! $ok)
		{
			carp "Failed to publish event to $channel_name via RobotEventTrigger\n";
		}

		# 
		# Write event to release channels based on purpose. Channels are 
		# named like so:
		#
		# RELEASE_PURPOSE
		# e.g.
		# 10s2_qual.rss, R1_qual.rss, etc. 
		#
		# For now we only want to write to qual channel
		#
		if ($purpose eq $QUAL_FEED_NAME)
		{	
			my $release_channel = join "_", $release, "bq";
			$event->channel ($release_channel);
			if (! $event->publish())
			{
				carp "Failed to publish event to $release_channel via RobotEventTrigger\n";
			}

			#
			# Also write to fail feed
			#
			if ($event->title() =~ m#ended with FAILURE#)
			{
				my $fail_channel = join "_", $release, $FAIL_FEED_NAME;
				$event->channel ($fail_channel);
				if (! $event->publish())
				{
					carp "Failed to publish event to $fail_channel via RobotEventTrigger\n";
				}
			}
		}

		#
		# Reset channel name + republished flag: We receive
		# event as a reference and don't want to taint it for
		# other interested parties...
		#
		$event->channel ($original_channel);
		$event->republished (0);

		return $ok;
	}
}

1;
