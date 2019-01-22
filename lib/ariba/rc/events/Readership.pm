package ariba::rc::events::Readership;

#
# Parse Apache access log to determine RSS feed readership counts
#

use strict;
use warnings;
use vars qw ($AUTOLOAD);
use Carp;
use Data::Dumper;
use File::Copy;
use Net::DNS;
use ariba::rc::events::Constants;
use ariba::util::ApacheAccessLog;
use ariba::util::HTMLTable;

{
    #
    # Constructor
    #

    sub new
    {
        my ($class, $options) = @_;
        my $self = $options ? $options : {};
        bless $self, ref ($class) || $class;
        $self->{'res'} = Net::DNS::Resolver->new;
        return $self;
    }

	sub report
	{
		my ($self, $agents, $readers) = @_;

		my $file = $self->{'output'};
		my $tmpfile = $self->{'output'} . ".tmp";

		if (! open FILE, ">" . $tmpfile)
		{
			carp "Can't write $tmpfile: $!\n";
			return;
		}
		print FILE <<FIN;
<html><head>
<title>RC Events: Readership Report</title>
<style type="text/css">
* { font-family: Verdana, sans-serif; }
</style>
</head>
<body bgcolor="#ffffff" vLink="#000000" aLink="#000000" link="#000000">
FIN

		print FILE ariba::util::HTMLTable::table_start();
		print FILE ariba::util::HTMLTable::table_row_header ( [ "User Agents" ], [ "left" ] );

		foreach my $agent (reverse sort { $$agents{$a} <=> $$agents{$b} } keys %$agents)
		{
			print FILE ariba::util::HTMLTable::table_row 
			(
				[ $agent ],
				[ "left" ],
			);
		}

		print FILE ariba::util::HTMLTable::table_end();
		print FILE "<p/>";
		print FILE ariba::util::HTMLTable::table_start();
		print FILE ariba::util::HTMLTable::table_row_header ( ["Channel", "Host" ], ["left", "left"] );

		my $last_channel = "";
		foreach my $channel (sort keys %$readers)
		{
			foreach my $host (reverse sort {$readers->{$channel}->{$a} <=> $readers->{$channel}->{$b}} keys %{$readers->{$channel}})
			{
				my $label = $last_channel eq $channel ? "&nbsp;" : $channel;
				print FILE ariba::util::HTMLTable::table_row
				(
					[ $label, $host ],
					[ "left", "left" ],
				);
				$last_channel = $channel;
			}
		}
		print FILE ariba::util::HTMLTable::table_end();
	
		print FILE "<p>Generated: " . localtime (time()) . "</p></body></html>\n";

		if (! close FILE)
		{
			carp "Couldn't close $tmpfile: $!\n";
			unlink $tmpfile;
		}

		if (! move ($tmpfile, $file))
		{
			carp "Couldn't mv $tmpfile to $file: $!\n";
			unlink $tmpfile;
		}
	}

	sub run
	{
		my ($self) = @_;

		my $logfile = $self->{'logfile'};

		# This is test code for now
		my $out = `tail -10000 $logfile`;
		my @out = split /\n/, $out;

		# locals
		my ($logdata, $line, $channel_name, $whom, %agents, %unique_agents,  %readers, %clients);

		# parse each line
		foreach $line (@out)
		{
			# extract logdata from line
			$logdata = ariba::util::ApacheAccessLog::parse_line ($line);

			# skip line unless it is a request for an rss feed
			next unless $logdata->{'resource'} =~ m#\.rss$#;

			# make an index of readers => channels
			$channel_name = $self->parse_channel ($logdata->{'resource'});
			$whom = $self->nslookup ($logdata->{'ip_addr'});

			# count unique user agents
			if (! exists ($unique_agents{$logdata->{'client'} . $whom}))
			{
				$agents{$logdata->{'client'}}++;
				$unique_agents{$logdata->{'client'} . $whom} = 1;
			}

			if (! exists $clients{$whom})
			{
				$clients{$whom} = 1;
			}
			$readers{$channel_name}{$whom}++;
		}

		$self->report (\%agents, \%readers);
	}

	#
	# Extract channel name from resource
	#
	sub parse_channel
	{
		my ($self, $resource) = @_;
		my @chunks = split /\//, $resource;
		my $channel_name = $chunks[$#chunks];

		# strip the .rss from end of line
		$channel_name = substr ($channel_name, 0, length ($channel_name) - 4);
		return $channel_name;
	}

	#
	# Get hostname for IP address
	#
	sub nslookup
	{
		my ($self, $ip_addr) = @_;

		# Check cache contents first
		if (exists $self->{'cache'}->{$ip_addr})
		{
			return $self->{'cache'}->{$ip_addr};
		}

		# nslookup against ip address
        my $query = $self->{'res'}->search ($ip_addr);

		# find PTR record in reply
        if ($query) 
		{
            foreach my $rr ($query->answer) 
			{
				next unless $rr->type eq "PTR";
                my $host = $rr->ptrdname;
				$self->{'cache'}->{$ip_addr} = $host;
				return $host;
			}
         }
		 return $ip_addr;
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
        carp "Unknown method: $accessor\n";
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

1;
