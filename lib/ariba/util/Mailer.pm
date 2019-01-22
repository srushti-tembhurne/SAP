package ariba::util::Mailer;

use strict;
use warnings;
use Carp;
use Data::Dumper;
use MIME::Lite;

#
# public static method takes:
#
# $file = path to template
# $vars = hashref containing variables to substitute 
# $debug = true to print e-mail message instead of sending
#
sub send_mail
{
	my ($file, $vars, $debug) = @_;
	$debug = $debug || 0;
	my %msg = _parse_template ($file, $vars);
	return _send_mail ($debug, %msg);
}

# 
# Send message using contents of %msg hash
# named for RFC 822 headers
#
sub _send_mail
{
    my ($debug, %msg) = @_;

    my $msg = MIME::Lite->new (%msg);

    if ($debug)
    {
        print $msg->as_string() . "\n";
        return;
    }
    
    eval { $msg->send() };
    if ($@) 
    {
        carp "Fatal: Couldn't send mail from $0: $@\n";
    }
}

#
# Parse template by replacing variables with values
#
sub _parse_template
{
    my ($file, $vars) = @_;

	# message headers stored in key named for header:
	# 
	#   Subject => Make money fast ask me how
	#
	# message body kept in key named: Data
	my %msg;

	# true if we are parsing message header,
	# false if we're parsing message body
	my $headers = 1;

	if (! open FILE, $file)
	{
		carp "Fatal: Template not found: $file, $!\n";
		return "";
	}

	# load headers + data into hash
	while (<FILE>)
	{
		chomp;

		# first blank line detected: reading message
		# body instead of headers
		if ($headers && ! length ($_))
		{
			$headers = 0;
			next;
		}
		
		# headers must be in RFC-822 format:
		# Key: Value
		elsif ($headers)
		{
			my ($key, $value) = $_ =~ m#^([^:]+):\s+(.*)$#;
			$msg{$key} = $value;
		}

		# message body
		else
		{
			$msg{'Data'} .= "$_\n";
		}
	}

	close FILE;

	# parse template replacing variables
	foreach my $data (keys %msg)
		{
		foreach my $var (keys %$vars)
			{
			my $value = $vars->{$var};
			$msg{$data} =~ s|\$$var|$value|eg;
			}
		}

	return %msg;
}

1;
