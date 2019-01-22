package ariba::Automation::EventAggregator::RobotStatus;

# 
# Generates the robot_status.rss feed: status of all mainline
# robots in Vidya's Robot Status format. 
#
# This class is instantiated and the execute() method is called
# for each event received by the server for robots. See events.xml 
# where this class is named. 
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
use ariba::Automation::Constants;
use ariba::Automation::Releases2;
use ariba::Automation::BuildInfo;
use ariba::Automation::Remote::Robot;
use ariba::rc::Utils;

{
	#
	# Constants
	#
	my $STATUS_UNKNOWN = "unknown";

	my %COLORS = 
	( 
		"FAILURE" => "FF0000",  # red
		"success" => "00FF00",  # green
		$STATUS_UNKNOWN => "FFFFFF",  # white
	);

    #
    # Constructor
    #
    sub new
    {
        my ($self, $event, $channel) = @_;
        return $self->SUPER::new ($event, $channel);
    }

	#
	# Return true if the channel_name matches
	#
	sub is_robot
	{
		my ($self, $channel_name) = @_;
		return $channel_name =~ m#^(idc|)robot\d+$# ? 1 : 0;
	}

    #
    # Public method generates feeds
    #
    sub execute
    {
        my ($self, $event) = @_;
        
		#
		# This check is not strictly required and can be removed.
		# But it is a good sanity check since this code should only
		# be fired off when a robot event arrives.
		#
		if (! $self->is_robot ($event->channel()))
		{
			return;
		}

        #
        # Get robot data from RobotCategorizer by instance name (i.e. robot57)
        #
        my $robot = $self->fetch_robot ($event->channel());
        return unless $robot;

        #
        # Extract hostname from Robot object: releases.conf uses hostname to
        # map roles to robot
        #
        my $hostname = $robot->hostname();
		return $self->robot_status ($hostname);
	}

	#
	# Generate robot status
	#
	sub robot_status
	{
		my ($self, $hostname) = @_;

		my %mainline = $self->{'releases'}->get_mainline_robots();
		
		# 
		# Don't continue unless we have a mainline robot
		#
		if (! exists $mainline{$hostname})
		{
			return;
		}

		#
		# Generate model holding robot status info
		#
		my %robot_status;

		foreach my $host (keys %mainline)
		{
			my $instance = $self->host_to_instance ($host);

			if (! $instance)
			{
				carp ref ($self) . " failed to convert $host to instance name\n";
				next;
			}

			my $robot = $self->fetch_robot ($instance);

			if (! $robot)
			{
				carp ref ($self) . " failed to load robot by host $host instance $instance\n";
				next;
			}

			# Newly-instantiated robots don't have a status
			my $status = $robot->status() || $STATUS_UNKNOWN;

			#
			# Get role info from ariba::Automation::Releases2
			#
			my $roleinfo = $self->{'releases'}->get_robot_role ($host);

			if ($#$roleinfo == -1)
			{
				next;
			}
			#
			# Role info is an arrayref containing:
			# release (10s2, hawk, hawk)rel)
			# product (asm, buyer)
			# purpose (initdb, migration)
			# role (mainline, qual)
			#
			my ($release, $product, $purpose, $role) = @$roleinfo;

			#
			# Add role info to model
			#
			push @{$robot_status{$product}{$release}{$purpose}}, [ $host, $instance, $status ];
		}

		#
		# Hand model off to view
		#
		$self->publish_status (\%robot_status);

		return 0;
	}

	#
	# Takes model + generates pleasant-looking HTML table
	#
	sub publish_status
	{
		my ($self, $status) = @_;

		my @products = keys %$status;
		my $buf = "";

		#
		# Create one table for each product: s4, buyer
		#
		foreach my $product (sort @products)
		{
			my $productname = ariba::rc::Utils::rewrite_productname ($product);
			$buf .= $self->make_product_table ($productname, $status->{$product});
		}

		#
		# Write to named channel 
		#
        my $channel = ariba::rc::events::Constants::channel_robot_status();

		#
		# Generate robot status event
		#
        my $event = new ariba::rc::events::client::Event
        (
            {
                channel => $channel,
                title => "Robot Status",
                description => $buf,
				republished => 1,
            }
        );

		#
		# Complain if publish fails
		#
        if (! $event->publish())
        {
            carp "Failed to publish robot status to $channel\n";
            return 0;
        }
	}

	#
	# Make HTML table for a product
	#
	sub make_product_table
	{
		my ($self, $productname, $status) = @_;

		# determine row 0: 10s2, hawk, hawk_rel, ...
		my @keys = sort keys %{$status};
		
		# split model into columns/rows
		my (@purposes, @rows);

		# determine column 0: initdb, migration, ...
		foreach my $key (@keys)
		{
			push @purposes, sort keys %{$status->{$key}};

			foreach my $i (0 .. $#purposes)
			{
				$rows[$i] = [ $purposes[$i] ];
			}
			last;
		}

		# 
		# generate rows
		#
		foreach my $key (@keys)
		{
			my $i = 0;
			foreach my $purpose (@purposes)
			{
				push @{$rows[$i++]}, $status->{$key}->{$purpose};
			}
		}
	
		#
		# generate HTML/CSS
		#
		my $buf = <<FIN;
<style>
.pretty { font-family: Verdana, sans-serif; }
</style>
FIN

		$buf .= $self->make_table (\@keys, $productname, \@rows);
		return $buf;
	}

	#
	# Make a table for a product given release, product name and raw rows
	#
	sub make_table
	{
		my ($self, $releases, $productname, $rows) = @_;

		my $buf = <<FIN;
<h1 class="pretty">$productname</h1>
<table class="pretty" border=1 width="100%" cellpadding=2 cellspacing=1>
<tr><td></td>
FIN

		#
		# Make table header
		#
		foreach my $release (@$releases)
		{
			$buf .= "<td><b>$release</b></td>";
		}
		$buf .= "</tr>";

		# 
		# Make table rows
		#
		foreach my $i (0 .. $#$rows)
		{
			$buf .= "<tr>";
			my $printed_row_header = 0;

			foreach my $row (@{$$rows[$i]})
			{
				#
				# Only print row headers once
				#
				if (! $printed_row_header)
				{
					$buf .= "<td><b>$row</b></td>";
					$printed_row_header = 1;
				}

				foreach my $wot (@$row)
				{
					my ($host, $instance, $status) = @$wot;

					my $color = $COLORS{$status};

					# 
					# Link to Robot King
					#
					my $link = <<FIN;
<a href="http://rc.ariba.com:8080/cgi-bin/robot-status?robot=$host">$instance</a>
FIN

					$buf .= "<td bgcolor=#$color>$link</td>";
				}
			}
			$buf .= "</tr>";
		}

		$buf .= <<FIN;
</table>
<br>
FIN
		return $buf;
	}

	#
	# for debugging 
	#
	sub send_test_event
	{
		my ($self, $hostname) = @_;

		my $instance = $self->host_to_instance ($hostname);
		my $robot = $self->fetch_robot ($instance);
        my $event = new ariba::rc::events::client::Event
        (
            {
                channel => 'debug',
                title => "Debugging Robot Status problem",
                description => "instance=$instance hostname=$hostname status=" . $robot->status(),
            }
        );

        #
        # Complain if publish fails
        #
        if (! $event->publish())
        {
            carp "Failed to publish test event to debug channel\n";
            return 0;
        }
	}

}

1;
