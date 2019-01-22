package ariba::monitor::QueryBehaviorHistory;

# $Id: //ariba/services/monitor/lib/ariba/monitor/QueryBehaviorHistory.pm#1 $

use strict;

use ariba::monitor::misc;
use ariba::monitor::StatusPage;

use base qw(ariba::Ops::PersistantObject);

sub dir {
	return( ariba::monitor::misc::queryBehaviorHistoryStorageDir() );
}

sub displayHistory {
	my $self = shift;
	my @results;
	my $ct = 0;
	my $white = ariba::monitor::StatusPage::colorToRGB("white");
	my $gray = ariba::monitor::StatusPage::colorToRGB("gray");

	push (@results, "<table cellspacing=0 width=100%>");
	push (@results, "<tr><th bgcolor=\"$white\">Downgrade History for " . $self->instance() . "</th></tr>");
	foreach my $id (sort $self->attributes()) {
		my $color = ($ct % 2) ? $white : $gray;
		push(@results, "<tr><td bgcolor=\"$color\">" . $self->attribute($id) . "</td></tr>");
		$ct++;
	}
	push(@results, "</table>");

	return(@results);
}

1;
