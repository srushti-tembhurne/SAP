package ariba::Automation::RobotServiceURLDelivery;

# This module will generate links from Robot King to personal
# services. It is a mini-me version of Jarek's update-anrc
# script which is specific to robots. 
#
# Output is delivered to mars via HTTP POST. 
# This avoids mounting robot home directories on mars.
#
# Call class->verbose(1) to display errors encountered to STDERR
# via Carp class. Otherwise you can ask for class->get_last_error()
# for more information about the most recent failure.

use strict;
use warnings;
use vars qw ($AUTOLOAD);
use Carp;
use Data::Dumper;
use LWP::Simple;
use HTTP::Request;
use HTTP::Request::Common;
use LWP::UserAgent;
use ariba::Automation::Constants;
use ariba::rc::InstalledProduct;
use ariba::rc::ParserUtils;

{
	#
	# Constants
	#
	my $LOG_VIEWER_PORT = 61502;
	my $DEFAULT_VERBOSITY = 0;

    #
    # Constructor
    #
    sub new
    {
        my ($class) = @_;
        my $self = 
		{
			'server' => ariba::Automation::Constants::serverFrontdoor() . ariba::Automation::Constants::serverRobotStatusUri(),
			'template_url' => ariba::Automation::Constants::robotTemplatesUrl(), 
			'verbose' => $DEFAULT_VERBOSITY,
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
        carp "Unknown method: $accessor\n";
    }

    #
    # Destructor
    #
    sub DESTROY
    {
        my ($self) = @_;
		$self->{'last_error'} = "";
    }

	#
	# Public
	#
	
	#
	# Return string with last error encountered
	#
	sub get_last_error
	{
		my ($self) = @_;
		return $self->{'last_error'};
	}

	#
	# Given a product name and optional bool to indicate verbosity,
	# generate + send template output to Robot King.
	#
	sub send_update
    {
		my ($self, $productname, $_verbose) = @_;
    
		# enable noisy debugging messages
		$_verbose = $_verbose || 0;
		if ($_verbose)
        {
			$self->{'verbose'} = 1;
        }

		# find template that matches product
		my $template_file = join "/", $self->{'template_url'}, $productname . ".html";

		# fetch template from mars
		my $template = get ($template_file);

		# mars down?
		if (! $template)
        {
			$self->{'last_error'} = "Couldn't fetch $template_file from Robot King";
			if ($self->{'verbose'})
			{
				carp "RobotServiceURLDelivery: " . $self->{'last_error'} . "\n";
			}
			return 0;
        }

		my $service = "personal_" . (exists $ENV{'USER'} ? $ENV{'USER'} : "");

		# get product info
		my $product = ariba::rc::InstalledProduct->new ($productname, $service);

		# fail if product isn't installed
		if (! $product->isInstalled ($product->name(), $product->service(), $product->buildName(), $product->customer()))
        {
			$self->{'last_error'} = "Product $productname/$service not installed";
			if ($self->{'verbose'})
			{
				carp "RobotServiceURLDelivery: " . $self->{'last_error'} . "\n";
			}
			return 0;
        }

		# get service links
		my $status = $self->_parse_template ($template, $product);
		if (! $status)
        {
			$self->{'last_error'} = "Parse template failed for $template_file on $service";
			if ($self->{'verbose'})
			{
				carp "RobotServiceURLDelivery: " . $self->{'last_error'} . "\n";
			}
			return 0;
        }

		my ($ok, $error) = $self->_deliver_status ($ENV{'USER'}, $productname, $status);

		# send output to mars
		if (! $ok)
        {
			$self->{'last_error'} = $error;
			if ($self->{'verbose'})
			{
				carp "RobotServiceURLDelivery: " . $self->{'last_error'} . "\n";
			}
			return 0;
        }

		return 1;
    }

	#
	# Privates
	#

	#
	# Deliver parsed templates via HTTP POST to mars
	#
	sub _deliver_status
    {
		my ($self, $robotName, $productname, $status) = @_;

		my $ua = LWP::UserAgent->new;

		my $req = POST $self->{'server'},
			Content_Type  => 'form-data',
			Content =>
			[
				robotName => $robotName,
				robotStatus => $status,
				robotProduct => $productname,
			];

		my $response = $ua->request($req);

		if (! $response->is_success)
        {
			return (0, $response->status_line);
        }

		return (1, "");
    }

	#
	# Given a template and product info, replace tokens and 
	# return completed template.
	#
	sub _parse_template
    {
		my ($self, $buf, $product) = @_;

		# name of robot
		my $hostName = $ENV{'HOSTNAME'} || "";

		# Guarding against this problem: 
		# perl warning: Use of uninitialized value in substitution iterator
		# reported against the HOSTNAME substitution below
		if (! $hostName)
        {
			$hostName = `hostname`;
			chomp $hostName;
        }

		$buf =~ s|\*HOSTNAME\*|$hostName|eg;

		# port number to log-viewer
		$buf =~ s|\*LOGVIEWERPORT\*|$LOG_VIEWER_PORT|eg;

		# methods against product object
		$buf =~ s|\*([^*]*)\*|evalToken($product, $1)|eg;

		return $buf;
    }

	#
	# Static method: Wrapper around evalToken tool below. Handy to have
	# as facade for testing.
	#
	sub evalToken
    {
		my ($me, $preProcessorString) = @_;
		return ariba::rc::ParserUtils::evalToken ($me, $preProcessorString);
    }
}

1;
