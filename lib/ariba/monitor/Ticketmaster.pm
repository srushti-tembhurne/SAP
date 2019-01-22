#!/usr/local/bin/perl -w

#
# $Id: //ariba/services/monitor/lib/ariba/monitor/Ticketmaster.pm#7 $
#
# Functions for mon to talk to ticketmaster
#
use strict;

package ariba::monitor::Ticketmaster;

use URI::Escape;
use ariba::monitor::Url;

#
# XXX - This SUCKS, but currently prod does not have an A record for
# ticketmaster
#
sub ticketmasterUrl {
	return "https://10.163.2.39/ticketmaster/query";
}

sub remoteRequest {
	my $arg = shift;
	my $post = shift;

	$post = uri_escape($post);
	$post = "${arg}=$post";
	my $uri = ticketmasterUrl();

	my $url = ariba::monitor::Url->new( $uri );
	$url->setFollowRedirects(1);
	$url->setPostBody($post);
	$url->setContentType('application/x-www-form-urlencoded');

	my $response = $url->request();
	$url->setOutOfBandErrors(1);

	if( $url->errors() ) {
		return(undef);
	}

	return( $response );
}

sub statusForTicket {
	my $tmid = shift;

	return(remoteRequest('status',$tmid));
}

sub newTicket {
	my $subject = shift;
	my $note = shift;
	my $submitter = shift || 'dept_an_ops_prod@ariba.com';
	my $owner = shift || "unassigned-sre";

    my $jiraAddress = ariba::Ops::Constants->jiraEmailAddress();
	my $email = "From: $submitter\nTo: $jiraAddress\n";
	$email .= "Date: " . scalar localtime() . "\n";
	$email .= "Subject: $subject\n";
	$email .= "\n$note\n";
	$email .= "\ntm-owner: $owner\n";

	return(ariba::Ops::Utils::email($jiraAddress, $subject, $email));
}

sub updateTicket {
	my $tmid = shift;
	my $note = shift;
	my $submitter = shift || 'dept_an_ops_prod@ariba.com';
	my $owner = shift;

	my $email = "From: $submitter\nTo: ticketmaster\@ariba.com\n";
	$email .= "Date: " . scalar localtime() . "\n";
	$email .= "Subject: Re: TMID:$tmid\n";
	$email .= "\n$note\n";
	if($owner) {
		$email .= "\ntm-owner: $owner\n";
	}

	return(sendTicket($email));
}

sub sendTicket {
	my $email = shift;

	return(remoteRequest('email',$email));
}

1;
