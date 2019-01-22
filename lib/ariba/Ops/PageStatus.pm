package ariba::Ops::PageStatus;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/PageStatus.pm#13 $

use strict;
use ariba::Ops::Constants;
use ariba::Ops::PageFilter;
use ariba::Ops::PageRequest;
use ariba::Ops::PageAck;
use ariba::Ops::Page;

use ariba::Oncall::Schedule;
use ariba::Oncall::OperationsEngineer;

use ariba::rc::InstalledProduct;

use HTML::Entities;

my $shortFormat;
my $html = 0;
my $tabs = '&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;';

sub displayCurrentPageFilters {
    my $class   = shift;

    my @filters = ariba::Ops::PageFilter->listObjects();

    my $count   = scalar(@filters);

    my @display = ();
    my $title = "$count page filters currently exist.";
    $title .= "</b></td><td align='right'><b><a href='page-filters' target='manage-page-filters'>[Manage Page Filters]</a>" if ($html);
    push @display, $class->printSection($title);
    push @display, "<br>\n" if ($html && !$count);
    push @display, "<p><b>Note:</b>&nbsp;Page Filters not yet started are displayed in grey.</p>\n" if ( $html && $count );

    for my $filter (@filters) {
        push @display, $class->printFilter($filter);
    }

    return @display;
}

sub displayRecentPageRequestsAsHTML {
    my $class = shift;

    $class->setHTML(1);

    return $class->displayRecentPageRequests(@_);
}

sub displayRecentPageRequests {
    my $class = shift;
    my $showPageFilters = shift;
    my $startTime = shift;
    my $endTime = shift;

    my @pageRequests = ();

    if ( !defined($startTime) || !defined($endTime) ) {
        @pageRequests = ariba::Ops::PageRequest->recentPageRequests();
    } else {
        @pageRequests = ariba::Ops::PageRequest->pageRequestsForDateRange($startTime, $endTime);
    }

    # which ones are unacked
    my (@unacked, @acked, @throttled, @display) = ();

    for my $pageRequest ( reverse sort oldestFirst @pageRequests ) {

        if ( $pageRequest->pages() && ! $pageRequest->pageAck() ) {

            push @unacked, $pageRequest;

        } elsif ( $pageRequest->pages() && $pageRequest->pageAck() ) {

            push @acked, $pageRequest;

        } else {

            push @throttled, $pageRequest;
        }
    }

    my $timeString = '';

    if ( !defined($startTime) || !defined($endTime) ) {
    
        push @display, $class->printOncallInfo();

        $timeString = "in the last 24 hours";
	
    } else {

        push @display, $class->printOncallInfo($startTime);

        $timeString = "between " . localtime($startTime) . " and ". localtime($endTime);
    }

    # actually this program doesn't know that PageRequest->recentPageRequests()
    # works on 24 hours but everyone keeps asking anyway

    push @display, $class->printStatus("There were ". @pageRequests . " page requests $timeString.");

    push @display, $class->displayCurrentPageFilters() if $showPageFilters;

    push @display, $class->printSection(@unacked . " page requests were sent as pages and remained unacked.");

    push @display, "<table><tr><td width=20>&nbsp;</td><td>\n" if $html;

    for my $pageRequest (@unacked) {

        push @display, "<font size=-2>\n" if $html;

        push @display, $class->printPageRequest($pageRequest);

        my $resent = 0;

        for my $page ( $pageRequest->pages() ) {

            push @display, $class->printPage($page, $resent++);
        }

        push @display, "\n";
        push @display, "</font><br>" if $html;
    }

    push @display, "</td></tr></table>" if $html;

    push @display, $class->printSection(scalar(@acked). " page requests were sent as pages and acked.");

    push @display, "<table><tr><td width=20>&nbsp;</td><td>\n" if $html;

    for my $pageRequest ( @acked ) {

        push @display, "<font size=-2>\n" if $html;
        push @display, $class->printPageRequest($pageRequest);
        
        my @pages = $pageRequest->pages();  

        my $resent = 0;

        for my $page ( @pages ) {

            push @display, $class->printPage($page, $resent++);

            if ( $page->pageAck() ) {
                push(@display, $class->printPageAck($page->pageAck()));
            }
        }

        push @display, "\n";
        push @display, "</font><br>" if $html;
    }

    push(@display, "</td></tr></table>") if $html;

    push(@display, $class->printSection(scalar(@throttled). " page requests were squelched and not sent as pages."));

    push(@display, "<table><tr><td width=20>&nbsp;</td><td>\n") if $html;

    for (my $x = 0; $x < scalar(@throttled) ; $x++ ) {

        last unless defined($throttled[$x]);

        push(@display, "<font size=-2>") if $html;

        push(@display, $class->printPageRequest($throttled[$x]));

        push(@display, "\n");
        push(@display, "</font><br>") if $html;
    }

    push(@display, "</td></tr></table>") if $html;


    return join('', @display);
}

sub oldestFirst {
    $a->creationTime() <=> $b->creationTime();
}

sub printOncallInfo {
    my $class = shift;
    my $time  = shift;

    my $current = '';
    my @display = ();
    my $timeWasPassed = 1;

    unless (defined $time) {
        $time = time();
        $timeWasPassed = 0;
        $current = "Current ";
    }

    my $me = ariba::rc::InstalledProduct->new();
    my @escalation = ariba::Ops::Constants::pagerEscalationForService($me->service());

    my $sched = ariba::Oncall::Schedule->new();
    return unless(defined($sched));
    
    my ($primary, $primary2, $primary3, $primaryName, $primaryAll);
    my ($backup, $backup2, $backup3, $backupName, $backupAll);
    my (@primaryAll, @backupAll);

    if ( $timeWasPassed == 0 ){
        ## We were not passed a time
        $primary = $sched->primaryForNow();
        $backup  = $sched->backupForNow();
    } else {
        ## We were passed a time, fallback to the old way ...
        my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime( $time );

        my $shift  = ''; ## primary shift name
        my $bshift = ''; ## backup shift name
        my $shift1 = $sched->switchHour();       ## 10
        my $shift2 = $sched->europeSwitchHour(); ## 18
        my $shift3 = $sched->blrSwitchHour();    ## 02

        if ( $hour > $shift1 && $hour <= $shift2 ){
            ## In shift 1
            $shift  = $sched->shift1Name();
            $bshift = $sched->backup1Name();
        } elsif ( $hour > $shift3 && $hour <= $shift1 ){
            ## In shift 3
            $shift  = $sched->shift3Name();
            $bshift = $sched->backup3Name();
        } else {
            ## In shift 2 which wraps over midnight
            $shift  = $sched->shift2Name();
            $bshift = $sched->backup2Name();
            ## Also need "yesterday's" people, we switch day at shift1 start
            $mday -= 1;
        }

        $primary  = $sched->primaryForDay( $mday );
        $primary2 = $sched->europePrimaryForDay( $mday );
        $primary3 = $sched->blrPrimaryForDay( $mday );
        $backup   = $sched->backupForDay( $mday );
        $backup2  = $sched->backup2ForDay( $mday );
        $backup3  = $sched->backup3ForDay( $mday );
    }

    if ($primary) {
        my $person = ariba::Oncall::OperationsEngineer->new($primary);
        $primaryName = defined( $person->fullname() ) ? $person->fullname() : $primary;
        push(@primaryAll, $primaryName);
    }

    if ($primary2) {
        my $person = ariba::Oncall::OperationsEngineer->new($primary2);
        $primaryName = defined( $person->fullname() ) ? $person->fullname() : $primary2;
        push(@primaryAll, $primaryName);
    }

    if ($primary3) {
        my $person = ariba::Oncall::OperationsEngineer->new($primary3);
        $primaryName = defined( $person->fullname() ) ? $person->fullname() : $primary3;
        push(@primaryAll, $primaryName);

    }

    if ($backup) {
        my $person = ariba::Oncall::OperationsEngineer->new($backup);
        $backupName = defined( $person->fullname() ) ? $person->fullname() : $backup;
        push(@backupAll, $backupName);
    }

    if ($backup2) {
        my $person = ariba::Oncall::OperationsEngineer->new($backup2);
        $backupName = defined( $person->fullname() ) ? $person->fullname() : $backup2;
        push(@backupAll, $backupName);
    }

    if ($backup3) {
        my $person = ariba::Oncall::OperationsEngineer->new($backup3);
        $backupName = defined( $person->fullname() ) ? $person->fullname() : $backup3;
        push(@backupAll, $backupName);
    }

    $primaryAll = join("/", @primaryAll);
    $backupAll = join("/", @backupAll);

    if ($html) {
        push(@display,
             "<font size=-1>\n",
            "<b>".$current."Primary:</b> $primaryAll<br>\n",
            "<b>".$current."Backup:</b> $backupAll<br>\n",
        );

        push(@display, "<b>Escalation: </b>", join(", ", @escalation), "<br>\n") if @escalation && $current ne '';
        push(@display, "</font><br>\n");

    } else {

        push(@display,
            $current."Primary: $primaryAll\n",
            $current."Backup: $backupAll\n",
        );

        push(@display, "Escalation: ", join(", ", @escalation), "\n") if @escalation && $current eq '';
    }

    return @display;
}

sub printStatus {
    my $class  = shift;
    my $status = shift;

    if ($html) {
        return "<b>$status</b><p>\n";
    } else {
        return "\n$status\n\n";
    }
}

sub printSection {
    my $class  = shift;
    my $title  = shift;

    if ($html) {

        return (
            "<table bgcolor='#CCCCCC' width=100%><tr><td>",
            "<b>$title</b>\n",
            "</td></tr></table>\n",
            "<p>",
        );

    } else {

        return (
            "\n",
            "_____________________________________________________________________\n\n",
            "$title\n",
            "_____________________________________________________________________\n\n",
        );
    }
}

sub printFilter {
    my $class = shift;
    my $pageFilter = shift;

    my $filterHasStarted = $pageFilter->hasFilterStarted();
    my $fontColor = "grey";
    my @display = ();

    if ( $html ) {
        if ( !$filterHasStarted ) {
            push @display, "<pre><font size=-1 color=\"$fontColor\">Future Filter:\n";
        }
        else {
            push @display, "<pre><font size=-1>\n";
        }

        push @display, $pageFilter->printToString();
        push @display, "</font></pre>\n"
    }
    else {
        push @display, $pageFilter->printToString();
        push @display, "\n";
    }

    return @display;
}

sub printPage {
    my $class = shift;
    my $page = shift;   
    my $resent = shift;

    return '' if defined $shortFormat;

    my @display = ();

    push @display, "\t";

    push @display, $tabs if $html;

    if ( $resent ) {
        push @display, "Resent";
    } else {
        push @display, "  Sent";
    }

    my $to = $page->sentTo();

    $to = HTML::Entities::encode_entities($to) if $html;

    push @display, " to ", $to;
    push @display, " at ",scalar(localtime($page->creationTime()));
    push @display, ", id ";

    push @display, "<b>" if $html;
    push @display, $page->pageId();
    push @display, "</b>" if $html;
    push @display, "\n";

    push @display, "<br>" if $html;

    return @display;
}

sub printPageRequest {
    my $class = shift;
    my $pageRequest = shift;

    my @display = ();

    push @display, "<font color=#777777>" if $html;
    push @display, scalar(localtime($pageRequest->creationTime())),"  ";
    push @display, "</font>" if $html;

    my $customer = '';

    if ( $pageRequest->customer() ) {
        $customer = $pageRequest->customer() . " ";
    }

    push @display, $customer . $pageRequest->product(). " ". $pageRequest->service().", ";

    my $subject = $pageRequest->subject();

    if ( length($pageRequest->subject()) > 95 ) {
        $subject = substr($subject, 0, 95) . "...";
    }

    push @display, $subject,"\n";

    push @display, "<br>" if $html;

    unless ($shortFormat) {

        push @display, "\t\t";
        push @display, $tabs x 2 if $html;

        my $program = $pageRequest->sendingProgram();
        $program = HTML::Entities::encode_entities($program) if $html;

        if ($program =~ /\@/) {
            push @display, "from $program\n";
        } else {
            push @display, "from program $program\n";
        }

        push @display, '<br>' if $html;

        if ( $pageRequest->squelchReason() ) {
            push @display, "\t\t";
            push @display, $tabs x 2 if $html;
            push @display, "squelched because ", $pageRequest->squelchReason(),"\n";
            push @display, "<br>" if $html;
        }
    }

    return @display;
}

sub printPageAck {
    my $class = shift;
    my $ack   = shift;

    return '' if (defined($shortFormat));

    my $from = $ack->from();

    $from = HTML::Entities::encode_entities($from) if $html;

    my @display = ();

    push @display, "\t\t";
    push @display, $tabs x 2 if $html;

    push @display, "Acked by $from at ";
    push @display, scalar(localtime($ack->time()));
    push @display, " via ", ariba::Ops::PageAck->viaToString($ack->via());
    push @display, "\n";
    
    push @display, "<br>" if $html;

    return @display;
}

sub setShortFormat {
    my $class = shift;

    $shortFormat = shift;
}

sub setHTML {
    my $class = shift;

    $html = shift;
}

1;
