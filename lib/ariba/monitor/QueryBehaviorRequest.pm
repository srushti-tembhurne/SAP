package ariba::monitor::QueryBehaviorRequest;

# $Id: //ariba/services/monitor/lib/ariba/monitor/QueryBehaviorRequest.pm#9 $

use strict;

use base qw(ariba::Ops::InstanceTTLPersistantObject);

use ariba::monitor::misc;
use ariba::Ops::NetworkUtils;
use ariba::rc::CipherStore;
use ariba::rc::Utils;
use ariba::monitor::Query;

=pod

=head1 NAME

ariba::monitor::QueryBehaviorRequest

=head1 METHODS

=over 4

=cut

# Class methods:
sub validAccessorMethods {
	my $class = shift;

	my %methods = map { $_, undef } qw(
		ttl creationTime requestor timeRequested ticketId 
		comment until status action
	);

	return \%methods;
}

sub dir {
	my $class = shift;

	return ariba::monitor::misc::queryBehaviorStorageDir();
}

sub instanceNameForAction {
	my $class = shift;
	my $query = shift;
	my $action = shift;

	my $instanceName = $query->instance() . "-" . $action;

	return $instanceName;
}

sub newFromQuery {
	my $class = shift;
	my $query = shift;
	my $action = shift || "unknown";

	my $tempTtl = 321; # temp value, in case the caller misuses us
	my $now = time();

	# Always return a new request - even if the previous one has expired.
	# the first request might return undef if it caused an expiration

	my $instanceId = $class->instanceNameForAction($query, $action);
	
	my $self = $class->new($instanceId) || $class->new($instanceId);

	$self->setCreationTime($now);
	$self->setAction($action);

	$self->setTtl($tempTtl);

	$self->setQuery($query);

	return $self;
}


# Instance methods

sub setQuery {
	my $self = shift;
	my $query = shift;

	# Stick the query in an instance variable, but don't write it to
	# disk, as that would create a loop.
	$self->{'query'} = $query;
}

sub query {
	my $self = shift;

	return $self->{'query'};
}

=pod

=item * requestor()

User requesting the change in behavior.

=item * timeRequested()

Time when was the request made

=item * ticketId()

Ticketmaster ID associated with behavior.

=item * comment()

why? what? when? etc.

=item * until()

time when this action expires, but dont let it go stale

=item * action()

string that denotes the action this QBR causes

=item * status()

Force query to the status specified

=back

=cut

sub prettyUntil {
	my $self = shift;

	return scalar localtime($self->pauseUntil());
}

sub setUntil {
	my $self  = shift;
	my $until = shift;

	unless ($until =~ /^\d+$/) {
		warn __PACKAGE__ . " until must be specified in seconds!\n\n";
		return;
	}

	$self->SUPER::setUntil($until);
}

sub setStatus {
	my $self   = shift;
	my $status = shift;

	unless ($status =~ /^(?:crit|warn|info)$/) {
		warn __PACKAGE__ . " downgradeStatus must be set to one of: crit, warn or info!\n\n";
		return;
	}

	$self->SUPER::setStatus($status);
}

sub recursiveSave {
	my $self = shift;

	return $self->save();
}

# Here's where the magic happens, and we might login to another machine to set
# our QBR/Query pair.

sub save {
	my $self = shift;

	# remember we're dirty because SUPER::save() will clear it
	my $isDirty = $self->_isDirty();

	# Always save locally.
	$self->SUPER::save();

	#
	# Notify Ticketmaster
	#
	if($self->action ne 'annotate' && $self->ticketId()) {
		if (eval "use ariba::monitor::Ticketmaster") {
			my $status = ariba::monitor::Ticketmaster::statusForTicket($self->ticketId());
			if($status && ($status eq 'open' || $status eq 'waiting')) {
				my $note = "A " . $self->action() . " action has been registered for " . $self->query()->instance(); 
				$note .= " by " . $self->requestor() if($self->requestor());
				$note .= ".";

				ariba::monitor::Ticketmaster::updateTicket(
						$self->ticketId(),
						$note
						);
			}
		}
	}

	# Pull the ivar back out.
	# lie if we don't have it.
	my $query = $self->query() || return 1;
	my $host  = ariba::Ops::NetworkUtils::hostname();
	my $remoteHost = $query->ranOnHost();

	# The query ran on a different host - login to it, and run ourselves.
	if ( $isDirty && $self->action() eq "pause" && $remoteHost && ($remoteHost ne $host) ) {

		my $QBRProgram = "/home/monload/bin/everywhere/read-qbr-stdin";

		my $service     = $query->service();
		my $cipherStore = ariba::rc::CipherStore->new($service);
		my $ssh         = ariba::rc::Utils::sshCmd();

		# We need to login to a remote machine.
		my $username = $query->ranAsUser() || "mon$service";

		# this is to work around a bug that was introduced around Underworld-195
		# and distributed via /usr/local/ariba/lib...
		$username =~ s/,.*//g;

		my $password = $cipherStore->valueForName($username) || do {

			warn __PACKAGE__ .  " Couldn't load password for $username to logon to $remoteHost!\n" if ( -t STDOUT);
			return 0;
		};

		my $input = $self->saveToString(0);
		$input .= "\cD";
		
		my @output = ();

		my $command = sprintf('%s %s@%s %s %s', $ssh, $username, $remoteHost, $QBRProgram);

		print "Executing command on $username\@$remoteHost :\n$command\n\n" if $query->debug();

		ariba::rc::Utils::sshCover($command, $password, undef, 30, \@output, "qbr", $input);

		if ( $query->debug() ) {
			for my $line (@output) {
				print "Output from $remoteHost: [$line]\n";
			}
		}
	}
	return 1;
}

sub expirationAction {
	my $self = shift;
	my $inst = $self->instance();
	my $now = $self->until();

	unless($self->comment() =~ /downgrade expired/) {
		$inst =~ s/-*([a-zA-Z]+)$//;
		my $expiredAction = $1;
		my $qHist = ariba::monitor::QueryBehaviorHistory->new( $inst );
		my $record = "$expiredAction set by " . $self->requestor() . " at " . scalar(localtime($self->timeRequested())) . " expired at " . scalar(localtime($now)) . " : " . $self->comment() . " (see TMID:" . $self->ticketId() . ")";
		$qHist->setAttribute($now, $record);
		$qHist->save();
	}

	return(1) unless($self->action() && $self->action() eq 'downgrade');

	#
	# annotate the query for a few days
	#
	$inst = $self->instance();
	$inst =~ s/downgrade$/annotate/;
	my $qbr = ariba::monitor::QueryBehaviorRequest->new( $inst ) ||
		ariba::monitor::QueryBehaviorRequest->new( $inst );

	$qbr->setTtl(86400); # 3 days
	$qbr->setUntil($now + 86400);
	$qbr->setComment("downgrade expired at " . scalar(localtime($now)) . ": " . $self->comment() . "(see TMID:" . $self->ticketId() . ")");
	$qbr->setRequestor( $self->requestor() );
	$qbr->setTicketId( undef );
	$qbr->setTimeRequested( $now );
	$qbr->setCreationTime( $now );
	$qbr->save();

	return(1);
}

sub displayQueryBehaviors {
	my $class = shift;


	my @listObjs = ariba::monitor::QueryBehaviorRequest->listObjectsRecursively();

	my @result;

	return @result unless(scalar (@listObjs));

	push @result,	"<table bgcolor='#CCCCCC' width=100%><tr><td>",
						"<b>Query behaviors :</b>\n",
						"</td></tr></table>\n",
						"<p>";

	push @result, "<table><tr><td width=20>&nbsp;</td><td>\n";


	foreach my $obj (@listObjs) {

		my $queryName = $obj->queryName();
		my $query = ariba::monitor::Query->new($queryName);
		my $qm = $query->parentQueryManager();

		my $queryIdentifier = "";

		if ($qm) {
			$queryName = $query->queryName();
			my $productName = $query->productName();
			my $uiHint = $query->uiHint() || "";

			my $customer = $query->customer() || "";
			$customer = "/$customer" if ($customer);

			my $qmName = $qm->name();
			$qmName =~ s/\-/ /g;
			my $hierarchy = $qmName;
			$hierarchy .= "/$uiHint" if ($uiHint);

			$queryIdentifier = $productName . "$customer - $hierarchy/$queryName  - "  . $obj->action();
		} else {
			$queryIdentifier = "$queryName - " . $obj->action() . " [Warning: query does not exist in backing store]";
		}

		push @result, "$queryIdentifier<br/>";
		push @result, "<font size=-2>\n";
		push @result, $obj->display();
		push @result, "<br/>\n";
		push @result, "</font>\n";
	}

	push @result, "</td></tr></table> </p>";

	return @result;
}


sub queryName {
	my $self = shift;

	my $instance = $self->instance();
	my $action = $self->action();
	$instance =~ s/-$action$//g;

	return $instance;
}


sub display {
	my $self = shift;

	my @result;
	my $now = time();
	my $remainingTime = ariba::Ops::DateTime::scaleTime($self->until() - $now);
	my $status = $self->action();
	my $requestor = $self->requestor() || "Unknown";
	my $comment = $self->comment() || '';
	my $tmid = $self->ticketId() || "Unknown";
	push @result, "This query is downgraded to status $status for $remainingTime by $requestor with comment: $comment. See TMID $tmid.";
	push @result, "<br/>";

	return @result;
}





1;

__END__
