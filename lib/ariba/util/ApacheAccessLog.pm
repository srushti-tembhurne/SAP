package ariba::util::ApacheAccessLog;

#
# Parse an Apache httpd access logfile 
#

use strict;
use warnings;

#
# 10.12.1.220 - - [28/May/2010:12:33:19 -0700] "GET /rss/robot_status.rss HTTP/1.1" 304 - "-" "Mozilla/2.0"
#
sub parse_line
{
	my ($line) = @_;
	
	my ($ip_addr, $ident, $userid, $date, $offset, $method, $resource, $protocol, $status_code, $size, $referrer, $client) = split / /, $line, 12;

	# clean up
	$date = $date || "";
	if (substr ($date, 0, 1) eq '[')
	{
		$date = substr ($date, 1);
	}
	
	$offset = $offset || "";
	if (substr ($offset, -1) eq ']')
	{
		$offset = substr ($offset, 0, length ($offset)-1);
	}

	$referrer = $referrer || "";
	if ($referrer eq '"-"')
	{
		$referrer = "";
	}

	$client = $client || "";
	if (substr ($client, 0, 1) eq '"')
	{
		$client = substr ($client, 1);
	}

	if (substr ($client, -1) eq '"')
	{
		$client = substr ($client, 0, length ($client) - 1);
	}

	return 
	{
		'ip_addr' => $ip_addr,
		'ident' => $ident,
		'userid' => $userid, 
		'date' => $date,
		'offset' => $offset,
		'method' => $method,
		'resource' => $resource,
		'protocol' => $protocol,
		'status_code' => $status_code,
		'size' => $size,
		'referrer' => $referrer,
		'client' => $client,
	};
}

1;
