# $Id: //ariba/services/monitor/lib/ariba/monitor/Query.pm#148 $
#
# Following keys can be set in a query object:
#
# type of query: snmp|perl|sql|aql|extractRecorded
#         perl: any perl expr
#         sql: a sql query
#         aql: an aql query
#         snmp: "host, oid-expr"
#         snmpArgs: "community, version, port"
#         extractRecorded: function("circular-dbname", num-vals)
#               function: average|min|max|sum
#               num-vals: +n for last n vals, -n for first n vals
#
# record results in circular db:
#        recordMaxResults: save atmost n records in db
#        recordDataType: gauge|counter
#        recordDataUnits: units of the quantity
#        recordItem: answer|numRows|statement
#        recordTime: cdb record id to insert/update, in seconds since epoch
#        recordOnError: cdb updated with results even if error is set on query
#        graphRecorded: graphs to generate
#                                all|daily|weekly|monthly|quarterly|yearly
#
# other fields:
#   info
#   warn
#   crit
#       these are perl, and can contain the pseudo variables
#           numrows, answer, previousNumrows, previousAnswer, or var<variable>
#
# <varible>  this is sql that defines a variable
#
# note          a string
# skip          1 means skip this query
# skipNotifications 1 means do not notify about warn/crit levels
# hasErraticSchedule    1 means that job does not run at regular freq and therefore cannot be monitored for stale data
# staleInterval         number of seconds that the query should consider when checking for stale data -- useful for regular queries that are somewhat erratic in completion time.
# openTicketInServices  use "all" or a list of non-prod services to open tickets in.
# pageInServices        use "all" or a list of non-prod services to send pages for.
# critOnWarnAfterMinutes    number of minutes after which the query becomes crit if warn
#                           persists.
# ticketOnWarnOpenAfterMinutes  number of minutes after which a ticket will be
#               opened if warn status presists.
# ticketSubmitter           specify who a ticket on warn originates from, and
#                           thus, who gets the email saying a ticket was opened.
# ticketOwner               specifies who owns a ticket created for this query.
# ticketDueInDays           specifies a due date for ticket.  today, or an
#                           integer specifying a number of days.
# alwaysAppendToTicket      Set to 1 to always append results from subsequent runs to the
#                           to the same ticket opened by ToW if it is still open.
# format        a printf style format
# noRowCount        1 means don't print row count
# rowCountLimit     max number of rows in the result (default is 500)
# timeout       max number of seconds for this query to run
#
# levelNotification 1 means notify if condition is true
#                       undef or 0 means notify if status has changed
#                       and condition is true.
#
# processAnswer     A coderef to post-process $query->results()
#
# useFormatOnError  The caller may still want to parse the format if error() is set.
#
# url
# logURL
# adminURL
# inspectorURL      Used for display in vm
#
# uiHint        Create a sub-expando. A query won't be displayed in vm (but will be in powergraph) if it is set to 'ignore',
#
# bindVariables     A coderef that should return an array of variables to be binded to sql
#
# Format Variables: These will expand to their corresponding variable
#
# answer
# previousAnswer
# numrows
# previousnumrows
# queryError
# statusChangeTime
# scaledStatusChangeTime
# localtime

package ariba::monitor::Query;

use strict;
use File::Basename;
use IO::Scalar;
use POSIX qw(strftime);

use vars qw(@ISA);
use ariba::monitor::misc;
use ariba::Ops::DateTime;
use ariba::Ops::PersistantObject;
use ariba::Ops::Utils;
use ariba::Ops::NetworkUtils;
use ariba::Ops::Constants;
use ariba::monitor::CircularDB;
use ariba::monitor::CircularDBGraph;
use ariba::monitor::QueryBehaviorRequest;
use ariba::monitor::QueryBehaviorHistory;

use ariba::Ops::NotificationRequest;
use ariba::util::PerlRuntime;

use ariba::rc::Globals;
use JSON;

@ISA = qw(ariba::Ops::PersistantObject);

my $colsep = "\t";
my $hostname = ariba::Ops::NetworkUtils::hostname();
my $queryExtension = ".query";

#
# monitor directory should always have group as ariba.
#
my $monitorDirGroup = getgrnam("ariba");
my $monitorDir = ariba::monitor::misc::monitorDir();


#
# sub new comes directly from PersistantObjects and nothing special
# needs to be done
#
sub newFromHash {
    my $class = shift;
    my $queryName = shift;
    my $productName = shift;
    my $service = shift;
    my $customer = shift;
    my $cluster = shift;
    my $qhash = shift;
    my $subDir = shift;
    my $queryManager = shift;

    # Maintain backward compatibility for existing datastore without cluster concept
    undef($cluster) unless (ariba::rc::Globals::isActiveActiveProduct($productName));

    my $queryId = $class->generateInstanceName($queryName, $productName, $customer, $cluster, $subDir);
    my $self = $class->SUPER::new($queryId);
    bless($self, $class);

    if ( $productName && $service ) {
        $self->setQueryName($queryName);
        $self->setProductName($productName);
        $self->setService($service);
        $self->setCustomer($customer);
        $self->setCluster($cluster);
        $self->setParentQueryManager($queryManager);
    }

    $self->_initializeAttrsFromHash($qhash, $subDir);

    return $self;
}

sub generateInstanceName {
    my $class = shift;
    my $queryName = shift;
    my $productName = shift;
    my $customer = shift;
    my $cluster = shift;
    my $subDir = shift;

    # Maintain backward compatibility for existing datastore without cluster concept
    undef($cluster) unless (ariba::rc::Globals::isActiveActiveProduct($productName));

    my $queryId = ariba::Ops::Utils::stripHTML($queryName);
    $queryId =~ s/\s/_/go;
    $queryId =~ s#[^\w\d_:\.-]#_#go;

    #
    # replace all but the first slash with underscores
    #
    $queryId =~ s#/#<slash>#o;
    $queryId =~ s#/#_#go;
    $queryId =~ s#<slash>#/#o;

    my $querySubDir = $productName;

    if ( defined($customer) ) {
        $querySubDir .= "/$customer";
    }

    if ( defined($cluster) ) {
        $querySubDir .= "/$cluster";
    }

    if ( defined($subDir) ) {
        $querySubDir .= "/$subDir";
    }

    $queryId = "$querySubDir/$queryId";

    return $queryId;
}

sub objectLoadMap {
    my $class = shift;

    my %map = (
        'details', '@ariba::monitor::Query',
        'results', '@SCALAR',
        'previousResults', '@SCALAR',
        'correctiveActions', '@SCALAR',
        'parentQueryManager', 'ariba::monitor::QueryManager',
    );

    return \%map;
}

sub dir {
    my $class = shift;

    return ariba::monitor::misc::queryStorageDir();
}

sub _computeBackingStoreForInstanceName {
    my $class = shift;
    my $instanceName = shift;

    # this takes the instance name as an arg
    # so that the class method objectExists() can call it

    my $file = $class->dir() . "/" . $instanceName;

    if ($instanceName !~ m|$queryExtension$|) {
        $file .= $queryExtension;
    }

    $file =~ s/\.\.//o;
    $file =~ s|//|/|go;

    return $file;
}

sub _saveStateToFile {
    my $self = shift;
    my $recursive = shift;

    my $prevUmask = umask 000;

    my $ret = $self->SUPER::_saveStateToFile($recursive);

    #
    # fix up directory group ownership if we are root
    #
    if ($< == 0) {
        #
        # now that the directory is created make sure that
        # it has the right group
        #
        my @dirs = split(/\//, $self->_backingStore());
        pop(@dirs);

        while ( my $dir = "/" . join('/',@dirs) ) {

            my $dirGroup = (stat($dir))[5];

            if ($dirGroup != $monitorDirGroup) {
                chown($>, $monitorDirGroup, $dir);
            }

            last if ($dir eq $monitorDir);
            pop(@dirs);
            last unless(@dirs);
        }
    }

    umask $prevUmask;

    return $ret;
}

sub _initializeAttrsFromHash {
    my $self = shift;
    my $qhash = shift;
    my $subDir = shift;

    my @attrs = sort(keys(%$qhash));

    #
    # check to see if query has changed significantly.
    # discard old copy, if so.
    #
    my $queryName = $self->queryName();
    my $newFingerPrint = lc(join('',@attrs));
    my $fingerPrint = $self->fingerPrint();
    if ($fingerPrint && $fingerPrint ne $newFingerPrint) {
        $self->deleteAttributes();
    }
    $self->setFingerPrint($newFingerPrint);
    $self->setQueryName($queryName);


    for my $attr (@attrs) {

        if ( $attr ne "details" ) {
            $self->setAttribute($attr, $qhash->{$attr});

            # if the 'error' attribute is present in the attribute
            # hash it should be treated as a valid error and
            # not as an old error that was read-in from when this
            # query was previously run.
            #
            # This is used where a query is constructed from
            # sql or snmp data that is run outside of the query,
            # for example in dataguard-status.
            $self->setNoErrorReset(1) if ($attr eq "error");
            next;
        }

        my @details = ();
        my $detailHashRef = $qhash->{$attr};

        for my $dquery ( sort keys %{$detailHashRef} ) {

            my $dqhash = $detailHashRef->{$dquery};
            $dqhash->{"uiHint"} = $self->uiHint();

            my $dq = ariba::monitor::Query->newFromHash(
                $dquery,
                $self->productName(),
                $self->service(),
                $self->customer(),
                $self->cluster(),
                $dqhash,
                $subDir
            );

            push(@details, $dq);
        }
        $self->setAttribute($attr, @details);
    }

    return $self;
}

sub displayResultsToString {
    my $self = shift;

    return $self->_displayMethodToString('displayResults');
}

sub displayResults {
    my $self = shift;
    my $FD   = shift;

    my @results          = $self->results();
    my @previousResults  = $self->previousResults();
    my $header           = $self->header();
    my $format           = $self->format();
    my $noRowCount       = $self->noRowCount();

    my $previousRows     = $self->previousRowCount() || scalar(@previousResults);

    my $statusChangeTime = $self->statusChangeTime();
    my $checkTime        = $self->checkTime();
    my $queryError       = $self->error();

    my $rows             = $self->rowCount() || scalar(@results);
    my $displayRows       = scalar(@results);
    my $now          = time();

    my $queryName        = ariba::Ops::Utils::stripHTML($self->queryName());

    # Don't output html if it's in the format itself.
    $self->setFormat( ariba::Ops::Utils::stripHTML($format) . "\n") if $format;

    my $multiRow = 1 if ($rows > 1 || $self->multiRow());

    if ($rows < 1) {
        print $FD "$queryName: none\n\n";
        print $FD $self->pauseComment()  if $self->isPaused($now);
        print $FD $self->annotateComment()  if $self->isAnnotated($now);
        print $FD $self->downgradeComment() if $self->isDowngraded($now);
        return;
    }

    # Output our instance, dependent on if the caller wants rows or not.
    if ($multiRow && $noRowCount) {

        print $FD "$queryName:\n";

    } elsif ($multiRow && !$noRowCount){

        my $rowCountString = "$rows";
        if ($rows > $displayRows) {
            $rowCountString .= " (truncated to $displayRows)";
        }
        print $FD "$rowCountString $queryName:\n";

    } else {
        print $FD "$queryName: ";
    }

    print $FD $header if defined($header);

    if ( $multiRow ) {
        # Handle the different types of QueryBehaviorRequests.
        print $FD $self->pauseComment()  if $self->isPaused($now);
        print $FD $self->annotateComment()  if $self->isAnnotated($now);
        print $FD $self->downgradeComment() if $self->isDowngraded($now);
    }

    for (my $i = 0; $i < @results; $i++) {

        my $r = $results[$i];

        if ($format && ($self->useFormatOnError() || !$self->error())) {

            my $pr = $previousResults[$i];

            $format = $self->expandFormat($r, $pr, $rows, $previousRows, $statusChangeTime, $checkTime, $queryError);

            printf($FD $format,map { ariba::Ops::Utils::stripHTML($_) } split(/$colsep/o,$r) );

        } else {

            print $FD ariba::Ops::Utils::stripHTML($r), "\n";
        }
    }

    if ( ! $multiRow ) {
        # Handle the different types of QueryBehaviorRequests.
        print $FD $self->pauseComment()  if $self->isPaused($now);
        print $FD $self->annotateComment()  if $self->isAnnotated($now);
        print $FD $self->downgradeComment() if $self->isDowngraded($now);
    }

    print $FD ariba::Ops::Utils::stripHTML($self->note()) if $self->note();
    print $FD "\n";
}

#
# Returns this query's current downgrade QueryBehaviourRequest, or
# undef if one does not exist.  This is neccessary because the new() method
# on QueryBehaviourRequest will return a new QueryBehaviourRequest if one
# does not already exist.
sub downgradeBehaviorRequest {
    my $self = shift;

    my $qbrName = ariba::monitor::QueryBehaviorRequest->instanceNameForAction($self, 'downgrade');
    return undef unless ariba::monitor::QueryBehaviorRequest->objectWithNameExists($qbrName);

    my $qbr = ariba::monitor::QueryBehaviorRequest->new($qbrName);

    #
    # these are expiring objects;  we might have a pointer to them
    # that is no longer valid!
    #

    if ( $qbr && !$qbr->ttl() ) {
        $qbr->remove();
        return undef;
    } else {
        return $qbr;
    }
}

sub setDowngradeBehaviorRequest {
    my $self = shift;
    return undef;
}

sub annotateBehaviorRequest {
    my $self = shift;

    my $qbrName = ariba::monitor::QueryBehaviorRequest->instanceNameForAction($self, 'annotate');
    return undef unless ariba::monitor::QueryBehaviorRequest->objectWithNameExists($qbrName);

    my $qbr = ariba::monitor::QueryBehaviorRequest->new($qbrName);

    if ( $qbr && !$qbr->ttl() ) {
        $qbr->remove();
        return undef;
    } else {
        return $qbr;
    }
}

sub setAnnotateBehaviorRequest {
    my $self = shift;
    return undef;
}

sub pauseBehaviorRequest {
    my $self = shift;

    my $qbrName = ariba::monitor::QueryBehaviorRequest->instanceNameForAction($self, 'pause');
    return undef unless ariba::monitor::QueryBehaviorRequest->objectWithNameExists($qbrName);

    my $qbr = ariba::monitor::QueryBehaviorRequest->new($qbrName);

    if ( $qbr && !$qbr->ttl() ) {
        $qbr->remove();
        return undef;
    } else {
        return $qbr;
    }
}

sub setPauseBehaviorRequest {
    my $self = shift;
    return undef;
}

sub setCachedResultsForVM {
    my $self = shift;
    my $html = shift;

    if ($html &&
        ! $self->isPaused()  &&
        ! $self->isAnnotated()  &&
        ! $self->isDowngraded()
    ) {
        $self->SUPER::setCachedResultsForVM($html);
    }
}

sub displayResultsForVM {
    my $self = shift;
    my $indent = shift;
    my $cgiBinURLBase = shift;

    my $cachedHTML = $self->cachedResultsForVM();
    if (
        $cachedHTML &&
        ! $self->isPaused()  &&
        ! $self->isAnnotated()  &&
        ! $self->isDowngraded()
    ) {
        return $cachedHTML;
    }


    my @output = ();

    my @results          = $self->results();
    my @previousResults  = $self->previousResults();
    my $header           = $self->header();
    my $format           = $self->format();
    my $note             = $self->note();
    my $noRowCount       = $self->noRowCount();
    my $statusChangeTime = $self->statusChangeTime();
    my $checkTime        = $self->checkTime();
    my $queryError       = $self->error();
    my $status           = $self->status();
    my $severity         = $self->severity();
    my $description      = $self->description();
    my %correctiveActions= $self->correctiveActions();
    my $now              = time();

    # this will set the color to be grey via css class
    if ($self->isStale()) {
        $status = 'unknown';
    }

    my $rows = $self->rowCount() || scalar(@results);
    my $displayRows = scalar(@results);

    my $previousRows = $self->previousRowCount() || scalar(@previousResults);

    my $queryName = $self->queryName();

    # Convert html to entities if we have it. Also drop in links if we have those.
    # We assume that if the $queryName is HTML, they'll do their own linking.
    unless ( $queryName =~ s|</?html>||go ) {
        $queryName =~ s/</&lt;/go;
        $queryName =~ s/>/&gt;/go;
        $queryName =~ s/ {2,}/&nbsp;/go;

        if ($self->url()) {
            $queryName = sprintf('<a href="%s">%s</a>', $self->url(), $queryName);
        }

        if ($self->logURL()) {
            $queryName .= sprintf('&nbsp;<font size=-4><a href="%s">log</a></font>', $self->logURL());
        }

        if ($self->inspectorURL()) {
            $queryName .= sprintf('&nbsp;<font size=-4><a href="%s">ins</a></font>', $self->inspectorURL());
        }

        if ($self->adminURL()) {
            $queryName .= sprintf('&nbsp;<font size=-4><a href="%s">admin</a></font>', $self->adminURL());
        }
    }

    # Cleanup the note as well
    if ( $note && $note !~ s|</?html>||go ) {
        $note =~ s/</&lt;/go;
        $note =~ s/>/&gt;/go;
        $note =~ s/ {2,}/&nbsp;/go;
    }

    #
    my $displayStatus = $status;

    $displayStatus .= "-forced" if ( $self->isPaused($now) || $self->isDowngraded($now) || $self->isAnnotated() );

    my $tr = "<tr class=\"$displayStatus\" cellpadding=\"2\">\n";
    my $subTr = $tr;

    for (my $i = 0; $i < $indent; $i++) {
        $tr .= "<td width=\"2%\" bgcolor=\"white\">&nbsp;</td>\n";
        $subTr .= "<td width=\"2%\">&nbsp;</td>\n";
    }

    my $metaLinks = "<font size=-1><sup><i>";

    if ( my $graphName = $self->_relatedCDBFilename() ) {

        my @graphs = split(",", $graphName);
        $graphName = join("&devices=", @graphs);
        $metaLinks .= "<a target=\"_powergraph\" href=\"$cgiBinURLBase/powergraph?deviceSelection=1&devices=$graphName\">g</a> ";

    } else {
        $metaLinks .= "&nbsp;&nbsp;&nbsp;";
    }

    my %tips;
    $tips{Severity} = $severity if (defined($severity));
    $tips{Description} = $description if ($description);
    if (%correctiveActions) {
        $tips{'Corrective Actions'} = '<br>';
        for my $dept (sort keys %correctiveActions) {
            $tips{'Corrective Actions'} .= "<b>$dept</b> - $correctiveActions{$dept}<br>";
        }
    }

    my $tips = '';
    if (%tips) {
        foreach my $field (sort keys(%tips)) {
            my $value = $tips{$field};
            $value =~ s/"/'/g;  # Prevent breaking title html below
            $tips .= "<p class='indentSecondLine'><b>$field</b>: $value</p>";
        }
        $tips = "title=\"$tips\"";
    }

    $metaLinks .= "<a target=\"_queryInspector\" href=\"$cgiBinURLBase/queryInspector?" . $self->instance() . "\" $tips>i</a> ";
    $metaLinks .= "</i></sup></font> ";

    # Bounce out early if there's nothing to do.
    if ( $rows < 1 ) {
        push(@output, "$tr<td>$metaLinks$queryName: none</td></tr>\n");
        push(@output, "$tr<td colspan=5>", $self->pauseComment(), "</td></tr>\n") if $self->isPaused($now);
        push(@output, "$tr<td colspan=5>", $self->annotateComment(), "</td></tr>\n") if $self->isAnnotated($now);
        push(@output, "$tr<td colspan=5>", $self->downgradeComment(), "</td></tr>\n") if $self->isDowngraded($now);
        return join("", @output);
    }

    my $multiRow = 1 if ($rows > 1 || $self->multiRow());

    if ($multiRow && $noRowCount) {
        push(@output, "$tr<td>$metaLinks$queryName:</td></tr>\n");

    } elsif ($multiRow && !$noRowCount){
        my $rowCountString = "$rows";
        if ($rows > $displayRows) {
            $rowCountString .= " (truncated to $displayRows)";
        }
        push(@output, "$tr<td>$metaLinks$rowCountString $queryName:</td></tr>\n");

    } else {
        push(@output, "$tr<td>$metaLinks$queryName: ");
    }


    if ($multiRow) {
        # Handle the different types of QueryBehaviorRequests.
        push(@output, "$tr<td colspan=5>", $self->pauseComment(), "</td></tr>\n") if $self->isPaused($now);
        push(@output, "$tr<td colspan=5>", $self->annotateComment(), "</td></tr>\n") if $self->isAnnotated($now);
        push(@output, "$tr<td colspan=5>", $self->downgradeComment(), "</td></tr>\n") if $self->isDowngraded($now);
        push(@output, "$tr<td>", '<table width="97%" align=right>');
    }


    # run through each line in the results.
    for (my $i = 0; $i < @results; $i++) {

        my $r = $results[$i];

        push(@output, $subTr) if $multiRow;

        unless ($r =~ s|</?html>||go) {
            $r =~ s/</&lt;/go;
            $r =~ s/>/&gt;/go;
            $r =~ s/ {2,}/&nbsp;/go;
        }

        my $line = $r;

        if ($format && ($self->useFormatOnError() || !$self->error())) {

            my $pr = $previousResults[$i];
            $format = $self->expandFormat($r, $pr, $rows, $previousRows, $statusChangeTime, $checkTime, $queryError);
            $line = sprintf($format, split(/$colsep/o,$r));
        }

        if ($multiRow) {

            push(@output, map { "<td>$_</td>" } split(/$colsep/o, $line));

        } else {

            push(@output, "$line</td>");
        }

        push(@output, "</tr>\n");
    }

    if ( !$multiRow ) {
        # Handle the different types of QueryBehaviorRequests.
        push(@output, "$tr<td colspan=5>", $self->pauseComment(), "</td></tr>\n") if $self->isPaused($now);
        push(@output, "$tr<td colspan=5>", $self->annotateComment(), "</td></tr>\n") if $self->isAnnotated($now);
        push(@output, "$tr<td colspan=5>", $self->downgradeComment(), "</td></tr>\n") if $self->isDowngraded($now);
    }

    push(@output, "</table></td></tr>\n") if $multiRow;

    push(@output, "$tr<td>$note</td></tr>\n") if $note;

    return join("", @output);
}

sub displayDetailsForVM {
    my $self = shift;
    my $indent = shift;
    my $cgiBinURLBase = shift;

    my @output;

    #
    # we're getting called to display details that may not exist
    # 1. there may not be any detail queries for this query
    # 2. if there are any, they may not be evaled, because this query
    #       has an OK status.
    #    Ideally we'd check for defined values for detail query results before
    #    recursing, but that's hard, so we check parent's status as a proxy.
    # we check for both before calling display() methods
    #

    my $status = $self->status();

    if ( !defined($status) || $status eq "info" ) {
        return;
    }

    if ( defined( $self->details() ) ) {

        for my $detail ( $self->details() )  {

            # this should be indented in. But we cannot figure it out yet.
            push(@output, $detail->displayResultsForVM($indent, $cgiBinURLBase));
        }
    }

    return return("", @output);
}

sub expandFormat {
    my $self = shift;

    return $self->expandTokensInString($self->format(), @_);
}

sub expandTokensInStringFromSelf {
    my $self = shift;
    my $string = shift;

    return $self->expandTokensInString(
        $string,
        $self->results(),
        $self->previousResults(),
        scalar($self->results()),
        scalar($self->previousResults()),
        $self->statusChangeTime(),
        $self->checkTime(),
        $self->queryError(),
    );
}

sub expandTokensInString {
    my $self = shift;
    my $string = shift;
    my $result = shift;
    my $previousResult = shift;
    my $numrows = shift;
    my $previousNumrows = shift;
    my $statusChangeTime = shift;
    my $checkTime = shift;
    my $queryError = shift || '';

    if ($string =~ m/\banswer\b/) {
        $string =~ s/\banswer\b/$result/g;
    }

    if ($string =~ m/\bpreviousAnswer\b/i) {
        $string =~ s/\bpreviousAnswer\b/$previousResult/gi;
    }

    if ($string =~ m/\bnumrows\b/i) {
        $string =~ s/\bnumrows\b/$numrows/gi;
    }

    if ($string =~ m/\bpreviousNumrows\b/i) {
        $string =~ s/\bpreviousNumrows\b/$previousNumrows/gi;
    }

    if ($string =~ m/\bqueryError\b/i) {
        $string =~ s/\bqueryError\b/$queryError/gi;
    }

    # This prints something like "3 wks 6 days 2 hrs ..."
    if ($string =~ m/\bscaledStatusChangeTime\b/i) {
        $string =~ s/\bscaledStatusChangeTime/ariba::Ops::DateTime::scaleTime($checkTime - $statusChangeTime)/egi;
    }

    if ($string =~ m/\bstatusChangeTime\b/i) {
        $string =~ s/\bstatusChangeTime/ariba::Ops::DateTime::prettyTime($statusChangeTime)/egi;
    }

    # sub localtime as a special case.
    # XXX - must *NEVER* use eval here. it's a security hole.
    if ($string =~ m/\blocaltime\([\d\.]+\)/) {
        $string =~ s/\blocaltime\(([\d\.]+)\)/localtime($1)/eg;
    }

    if ($string =~ m/\bscaleTime\([\d\.]+\)/i) {
        $string =~ s/\bscaleTime\(([\d\.]+)\)/ariba::Ops::DateTime::scaleTime($1)/egi;
    }

    return $string;
}

sub printAsHTML {
    my $self = shift;
    my $fd = shift || *STDOUT;

    my $now = time();

    my @bgcolors = ("#FFFFFF", "#EEEFEE");
    my $i = 0;

    print $fd "<h3>Query " . $self->instance() . "</h3>\n";
    print $fd "<table cellspacing=0>\n";
    for my $attribute ( sort $self->attributes() ) {
        my $rawValue = $self->attribute($attribute);
        my $value = join("<br>", $rawValue || '' );

        # query perl attribute can contain passwords as function args.
        # hide them.

        if ($attribute eq 'perl' || $attribute eq 'snmp') {
            $value = '<i>skipped for security reasons</i>';
        }

        if ($attribute eq "docURL") {
            $value = "<a href='$value'>$value</a>";
        }

        print $fd "<tr bgcolor=\"", $bgcolors[$i++%2], "\">";

        print $fd "<td valign=\"top\"><b>$attribute</b></td>";
        if ( $value =~ /<html>/ ) {
            $value =~ s/>/&gt;/g;
            $value =~ s/</&lt;/g;
            print $fd "<td><pre>$value</pre></td>";

        } elsif ( $value && $attribute eq "runTime" ) {
            print $fd "<td>" . ariba::Ops::DateTime::scaleTime($value) . " ($value)</td>";

        } elsif ( $value && $attribute =~ /time$/i ) {
            print $fd "<td>" . localtime($value) . " ($value, " .
                    ariba::Ops::DateTime::scaleTime($now - $value) . " ago)</td>";
        } else {
            print $fd "<td>" . $value . "</td>";
        }

        print $fd "</tr>\n";
    }
    print $fd "</table>\n";

    print "<hr>\n";

    my $br;

    if ( $self->isPaused($now) ) {
        print "<b>", $self->pauseComment(), "</b><p>";
    }

    $br = $self->pauseBehaviorRequest();

    if ( $br ) {
        print $fd "<pre>\n";
        $br->print($fd);
        print $fd "</pre>\n";
    }

    if ( $self->isAnnotated($now) ) {
        print "<b>", $self->annotateComment(), "</b><p>";
    }

    $br = $self->annotateBehaviorRequest();

    if ( $br ) {
        print $fd "<pre>\n";
        $br->print($fd);
        print $fd "</pre>\n";
    }

    if ( $self->isDowngraded($now) ) {
        print "<b>", $self->downgradeComment(), "</b><p>";
    }

    $br = $self->downgradeBehaviorRequest();

    if ( $br ) {
        print $fd "<pre>\n";
        $br->print($fd);
        print $fd "</pre>\n";
    }

    if(ariba::monitor::QueryBehaviorHistory->objectWithNameExists( $self->instance() )) {
        my $qbh = ariba::monitor::QueryBehaviorHistory->new($self->instance());
        print $fd join("\n", $qbh->displayHistory() );
    }
}

sub displayDetailsToString {
    my $self = shift;

    return $self->_displayMethodToString('displayDetails');
}

sub displayDetails {
    my $self = shift;
    my $fd = shift;

    #
    # we're getting called to display details that may not exist
    # 1. there may not be any detail queries for this query
    # 2. if there are any, they may not be evaled, because this query
    #       has an OK status.
    #    Ideally we'd check for defined values for detail query results before
    #    recursing, but that's hard, so we check parent's status as a proxy.
    # we check for both before calling display() methods
    #

    my $status = $self->status();

    if ( !defined($status) || $status eq "info" ) {
        return;
    }

    if ( defined( $self->details() ) ) {
        print $fd "----details\n";

        for my $detail ( $self->details() )  {
            $detail->displayResults($fd);
        }
        print $fd "----end details\n";
    }
}

sub loadRecordDB {
    my $self = shift;

    my $maxResults = $self->recordMaxResults() || return undef;

    # this is a hack around writing N items to a CDB in the case of an
    # aggregateQuery, when we only want the summed value.
    #
    # [jarek] I don't think this is entirely necessary, seems like having
    # AggregateQuery set recordDBFileName on itself would suffice.
    #
    my $dbFileName = $self->recordAggregateDBFileName() || $self->recordDBFileName() || $self->instance();

    # load an existing circularDB or create a new one
    my $recordDB = ariba::monitor::CircularDB->new(
        $dbFileName,
        $self->queryName(),
        $maxResults,
        $self->recordDataType(),
        $self->recordDataUnits(),
        $self->cdbDescription()
    );

    return($recordDB);
}

sub isGraphable {
    my $self = shift;

    # this needs to be defined() rather than just the value,
    # because queryd does a $child->setRecordMaxResults(0); when
    # doing the qm/query merge.  See queryd command_readAppendQueryManager()

    return( defined($self->recordMaxResults()) );
}

sub cdb {
    my $self = shift;

    return ($self->loadRecordDB());
}

sub recordResults {
    my $self = shift;

    my $recordDB = $self->loadRecordDB();
    my $timeout = $self->timeout() || 30;

    return undef unless($recordDB);

    my $sample;

    my $presetRecordTime = $self->recordTime();
    my $sampleTime = $presetRecordTime || $self->checkTime() || time();

    if (!$self->error() || $self->recordOnError()) {

        my @r = $self->results();
        my $item = $self->recordItem();

        # defaults to "answer" if empty
        if (!defined($item) || $item eq "answer") {
            $sample = $r[0];
        } elsif (defined($item) && $item =~ /numrows/i) {
            $sample = $self->rowCount() || scalar(@r);
        } else {
            my $expandedItem = $self->expandTokensInStringFromSelf($item);

            my $coderef = sub { $sample = eval $expandedItem; };

            my $start = time();
            $sampleTime = $start unless $presetRecordTime;

            if (! ariba::Ops::Utils::runWithTimeout($timeout,$coderef) ) {
                my $end = time();

                my $duration = "start=" . strftime("%H:%M:%S", localtime($start)) .
                    " end=" . strftime("%H:%M:%S", localtime($end));

                if ( ref($item) ) {
                    my $codeBody = ariba::util::PerlRuntime::deparseCoderef($item) || 'code';
                    $self->setError("recordResults() timed out running code:\n$codeBody\nduration: $duration");
                } else {
                    $self->setError("recordResults() timed out running \"$item\" $duration");
                }
            }
        }
    }

    if ($presetRecordTime && $recordDB->readRecords($sampleTime, $sampleTime)) {

        $recordDB->updateRecord($sampleTime, $sample);
    } else {
        $recordDB->writeRecord($sampleTime, $sample);
    }

    return $sample;
}

sub graphResults {
    my $self = shift;
    my @graphTypes = @_;

    return undef unless($self->isGraphable());

    unless (@graphTypes) {

        my $graphType = $self->graphRecorded();

        return unless ($graphType);

        if ($graphType eq "all") {
        push(@graphTypes, "daily", "weekly",
                  "monthly", "quarterly", "yearly");
        } else {
        push(@graphTypes, split(/\s*,\s*/, $graphType));
        }
    }

    return unless (@graphTypes);

    my $oneHour = 3600;

    my $productName = $self->productName();
    my $queryName = $self->queryName();
    my $recordDB = $self->loadRecordDB();
    my $lastUpdated = $recordDB->lastUpdated();

    for my $type (@graphTypes) {

        my $delta;
        if ($type eq "daily") {
            $delta = 25 * $oneHour;
        } elsif ($type eq "weekly") {
            $delta = 8 * 24 * $oneHour;
        } elsif ($type eq "monthly") {
            $delta = 31 * 24 * $oneHour;
        } elsif ($type eq "quarterly") {
            $delta = 3 * 31 * 24 * $oneHour;
        } elsif ($type eq "yearly") {
            $delta = undef;
        } else {
            next;
        }

        my ($begin, $finish);

        if ($delta) {
            $begin = $lastUpdated - $delta;
            #$finish = $lastUpdated;
        }

        my $filename = ariba::monitor::misc::imageFileForQueryNameAndFrequency(
            $productName,
            $queryName,
            $type
        );

        my $g = ariba::monitor::CircularDBGraph->new(
            $filename,
            $begin,
            $finish,
            $recordDB
        );

        $g->graph();
    }
}

sub printDB {
    my $self = shift;

    my $recordDB = $self->loadRecordDB();

    return unless($recordDB);

    $recordDB->print();
}

sub setOracleClient {
    my $self = shift;
    $self->{'oracleClient'} = shift;
}

sub oracleClient {
    my $self = shift;
    return $self->{'oracleClient'};
}

sub setHanaClient {
    my $self = shift;
    $self->{'hanaClient'} = shift;
}

sub hanaClient {
    my $self = shift;
    return $self->{'hanaClient'};
}

sub setMySQLClient {
    my $self = shift;
    $self->{'mySQLClient'} = shift;
}

sub mySQLClient {
    my $self = shift;
    return $self->{'mySQLClient'};
}

sub setAQLClient {
    my $self = shift;
    $self->{'aqlClient'} = shift;
}

sub AQLClient {
    my $self = shift;
    return $self->{'aqlClient'};
}

sub isPaused {
    my $self = shift;
    my $time = shift || time();

    my $qbr  = $self->pauseBehaviorRequest();

    if (defined $qbr && $qbr->until() && $qbr->until() > $time) {
        return 1;
    }

    return 0;
}

#
# QueryManager has an "advisory" in progress system in addition
# to qm->lock(), qm->unlock().   Pausing and Downgrading use this
# advisory system to avoid lock contention with queryd.
#

sub _waitUntilQueryManagerIdle {
    my $self = shift;

    my $parent = $self->parentQueryManager();

    my $parentIsIdle = 0;

    my $displayUi = ( -t STDOUT );

    my $select = select(STDOUT);

    if ( $displayUi ) {
        $| = 1;
    }

    #XXX these should be methods on QueryManager
    my $parentRunTime = $parent->runTime() || "60";
    my $maxWaitTime = $parentRunTime + 20;

    my $start = time();
    my $c = 0;
    while ( time() < $start + $maxWaitTime ) {

        unless ( $parent->isInProgress() ) {
            $parentIsIdle = 1;
            last;
        }
        sleep 1;
        ++$c;

        if ( $displayUi ) {
            print "\rQueryManager ", $parent->instance(), " is busy, waited $c secs up to max $maxWaitTime secs...";
        }
    }

    print "\n" if $displayUi;

    select($select);

    return $parentIsIdle;
}

sub annotate {
    my ($self, $comment, $ticketId, $requestor) = @_;

    my $qbr;
    my $now = time();
    my $ttl = 315360000; # 10 years

    unless ( $qbr = $self->annotateBehaviorRequest() ) {
        $qbr = ariba::monitor::QueryBehaviorRequest->newFromQuery($self, "annotate");
    }

    $qbr->setQuery($self);
    $qbr->setTtl($ttl);
    $qbr->setUntil($now + $ttl);
    $qbr->setComment($comment);
    $qbr->setRequestor($requestor);
    $qbr->setTicketId($ticketId);
    $qbr->setTimeRequested($now);

    return $qbr->save();
}

sub pause {
    my ($self, $ttl, $pauseComment, $ticketId, $requestor) = @_;

    my $qbr;
    my $now = time();

    unless ( $qbr = $self->pauseBehaviorRequest() ) {
        $qbr = ariba::monitor::QueryBehaviorRequest->newFromQuery($self, "pause");
    }

    $qbr->setQuery($self);
    $qbr->setUntil($now + $ttl);
    $qbr->setComment($pauseComment);
    $qbr->setTicketId($ticketId);
    $qbr->setRequestor($requestor);
    $qbr->setTimeRequested($now);

    $qbr->setTtl($ttl);

    return $qbr->save();
}

sub annotateComment {
    my $self = shift;

    my $qbr  = $self->annotateBehaviorRequest();

    return "" unless $qbr;

    unless($qbr->comment()) {
        return sprintf("A JIRA issue has been opened by %s for this query.",
            $qbr->requestor() || 'Unknown'
        );
    }

    my $comment = sprintf("This query is annotated by %s with comment: %s.",
        $qbr->requestor() || 'Unknown',
        $qbr->comment() || 'Unknown'
    );
    $comment .= "See TMID/CR#/SR#: " . $qbr->ticketId() if($qbr->ticketId());

    return($comment);
}

sub isAnnotated {
    my $self = shift;
    my $time = shift || time();

    my $qbr  = $self->annotateBehaviorRequest();

    if (defined $qbr && $qbr->until() && $qbr->until() > $time) {
        return 1;
    }

    return 0;
}

sub downgrade {
    my ($self, $downgradeStatus, $ttl, $downgradeComment, $ticketId, $requestor) = @_;

    my $qbr;
    my $now = time();

    # make sure to overwrite any existing QueryBehaviorRequest
    if ( $qbr = $self->downgradeBehaviorRequest() ) {
        $qbr->remove();
    }

    $qbr = ariba::monitor::QueryBehaviorRequest->newFromQuery($self, "downgrade");

    $qbr->setQuery($self);
    $qbr->setStatus($downgradeStatus);
    $qbr->setUntil($now + $ttl);
    $qbr->setComment($downgradeComment);
    $qbr->setTicketId($ticketId);
    $qbr->setRequestor($requestor);
    $qbr->setTimeRequested($now);

    $qbr->setTtl($ttl);

    my $return = $qbr->save();

    #
    # We've just changed our status, but our parent QM's status
    # is only recomputed when monitoring runs.   calling qm->checkStatus()
    # is the key method.  We're calling qm->displayToLog() instead of qm->save()
    # because displayToLog does the proper QM locking
    #
    #XXXX Does this save need to go via queryd for the qms that are normally
    #XXXX saved that way???
    #
    #

    my $parent = $self->parentQueryManager();

    if ( $parent ) {
        # call recomputeStatus instead of checkStatus since we only need to
        # re-read the statuses of the parent QueryManager's queries;
        # i.e. we want to avoid any side-effects that checkStatus causes
        $parent->recomputeStatus();
        $parent->displayToLog();
    }

    return $return;
}

sub pauseComment {
    my $self = shift;

    my $qbr  = $self->pauseBehaviorRequest();

    return "" unless $qbr;

    return sprintf("This query is paused for %s by %s with comment: %s.  See TMID/CR#/SR# %s.\n",
        ariba::Ops::DateTime::scaleTime($qbr->until() - time()),
        $qbr->requestor() || 'Unknown',
        $qbr->comment() || 'Unknown',
        $qbr->ticketId() || 0,
    );
}

sub isDowngraded {
    my $self = shift;
    my $time = shift || time();

    my $qbr  = $self->downgradeBehaviorRequest();

    if (defined $qbr && $qbr->until() && $qbr->until() > $time) {
        return 1;
    }

    return 0;
}


sub downgradeStatus {
    my $self = shift;
    my $time = shift;

    my $qbr  = $self->downgradeBehaviorRequest();

    return $qbr->status() || 'unknown';
}

sub downgradeComment {
    my $self = shift;

    my $qbr  = $self->downgradeBehaviorRequest();

    return "" unless $qbr;

    return sprintf('This query is downgraded to status %s for %s by %s with comment: %s. See TMID/CR#/SR# %s.',
        $self->status(),
        ariba::Ops::DateTime::scaleTime($qbr->until() - time()),
        $qbr->requestor() || 'Unknown',
        $qbr->comment() || 'Unknown',
        $qbr->ticketId() || 0,
    );
}

sub status {
    my $self = shift;

    my $now  = time();

    if ( $self->isDowngraded($now) ) {
        return $self->downgradeStatus();
    }

    return $self->SUPER::status();
}

sub checkThresholds {
    my $self = shift;
    my $possibleStatus = shift;

    my ($numrows, $answer, $previousAnswer, $previousNumrows);

    my @r         = $self->results();
    my @pr        = $self->previousResults();
    my $action    = $self->attribute($possibleStatus);
    my $noCritOnError    = $self->noCritOnError();
    my $returnVal = 0;
    my $startTime = time();

    if (defined $action) {

        # error() is currently only used for propagating SNMP & Oracle/DB errors
        if ( $self->error() ) {

            unless ($noCritOnError && $possibleStatus eq 'crit') {
                $self->setStatus($possibleStatus);
                $returnVal = 1;
            }

        } else {

            my $actionsub = $action;

            while( $actionsub =~ m/var(\w+)/ ) {
                my $varname = $1;

                my $sql = $self->attribute($varname);
                my $value = join("", $self->_runSql($sql));

                $actionsub =~ s/var$varname/$value/g;
            }

            if ($actionsub =~ m/\banswer\b/) {
                $answer = join("", @r);
                $actionsub =~ s/\banswer\b/\$answer/g;
            }

            if ($actionsub =~ m/\bpreviousAnswer\b/i) {
                $previousAnswer = join("", @pr);
                $actionsub =~ s/\bpreviousanswer\b/\$previousAnswer/ig;
            }

            if ($actionsub =~ m/\bnumrows\b/) {
                $numrows = $self->rowCount() || scalar(@r);
                $actionsub =~ s/\bnumrows\b/\$numrows/g;
            }

            if ($actionsub =~ m/\bpreviousNumrows\b/) {
                $previousNumrows = $self->previousRowCount() || scalar(@pr);
                $actionsub =~ s/\bpreviousNumrows\b/\$previousNumrows/g;
            }

            if (eval($actionsub)) {

                $returnVal = 1;
                $self->setStatus($possibleStatus);
                $self->runDetails() if defined $self->details();
            }
        }
    }

    my $runTime = time() - $startTime;

    # add time for checking to each query to total
    $self->setRunTime( $self->runTime() + $runTime );

    return $returnVal;
}

sub runInterval {
    my $self = shift;

    my $interval;

    if($self->staleInterval()) {
        return($self->staleInterval());
    }

    my $checkTime = $self->checkTime();
    my $previousCheckTime = $self->previousCheckTime();

    if ($checkTime && $previousCheckTime) {
        $interval = $checkTime - $previousCheckTime;
    }

    return $interval;
}

sub checkAndSetStaleStatus {
    my $self = shift;
    my $currentTime = shift || time();

    my $wasStale = $self->isStale() || 0;
    $self->setIsStale(0);

    #
    # Dont do staleness check for something that has irregular schedule
    #
    return if ($self->hasErraticSchedule());

    my $checkTime = $self->checkTime();
    my $interval = $self->runInterval();

    if ($checkTime && defined($interval)) {
        my $timeSinceLastCheck = $currentTime - $checkTime;

        if ($timeSinceLastCheck >= 1.8 * $interval) {
            $self->setIsStale(1);
            # record the time when this query is becoming stale *now*
            # and it wasnt stale before
            unless ($wasStale) {
                $self->setLastBecameStaleTime(time());
            }
        }
    }

    #
    # clear out last became stale time data if the query is not currently
    # stale and if it was last stale a month ago.
    #
    unless ($self->isStale()) {
        my $lastBecameStaleTime = $self->lastBecameStaleTime();
        if ($lastBecameStaleTime && time() - $lastBecameStaleTime > 30 * 24 * 3600) {
            $self->setLastBecameStaleTime(undef);
        }
    }


    return $self->isStale();
}

sub notifyForStatuses {
    my $self = shift;
    my $notifyEmailAddress = shift;
    my $notifyForWarns = shift || 0;    # 0|1
    my $notifyForCrits = shift || 0;    # 0|1

    return 0 if ($self->skip() || $self->skipNotifications());

    # We might be in a scheduled outage. Don't notify.
    if ($self->outageSchedule()) {

        return 0 if defined $self->outageSchedule()->isInScheduledOutage();
    }

    # if something's bad, send email

    my @r = $self->results();
    my $status = $self->status();
    my $prevStatus = $self->previousStatus();
    my $conditionNowTrue = $self->attribute($status);

    my $service = $self->service();
    my $productName = $self->productName();
    my $customer = $self->customer();
    my $cluster = $self->cluster();

    my $willPage = 0;

    #
    # do edge based notification if level paging is not
    # requested. edge based notification will dispatch a
    # notification iff the status has not changed
    # since last time, no notification is needed.
    #
    #
    my ($s1, $body1) = split(/\n/, $self->displayResultsToString(), 2);
    $body1 = $0;
    chomp($body1);

    if ($status && $prevStatus &&
        $status eq $prevStatus &&
        ! $self->levelNotification()) {
           #if(&allowPage($s1,$body1)==0){  # Disabled by agi as the page suppression fails in snv
            return 0;
           #}
    }

    unless ( $status eq "warn" || $status eq "crit" ) {
        return 0;
    }

    if ( !$notifyForWarns && !$notifyForCrits ) {
        return 0;
    }

    if ( $status eq "crit" ) {
        $willPage = 1;
    }

    my $severity = '';
    $severity = ' s' . $self->severity() if (defined($self->severity()));

    my ($s, $body) = split(/\n/, $self->displayResultsToString(), 2);
    my $subject = "$status$severity: $s";

    $body .= "$conditionNowTrue\n";
    $body .= $self->displayDetailsToString() || '';

    my $error = $self->error();
    if ($error) {
        $body .= "-- QueryError --\n$error\n-- QueryError --\n";
    }

    unless ( $willPage ) {
        $body .= "\n";
        $body .= "customer: $customer\n" if $customer;
        $body .= "product: $productName\n";
        $body .= "service: $service\n";
        $body .= "cluster: $cluster\n" if $cluster;
        $body .= "sent by: $0\n";
    }

    if (defined($self->pageInServices()) &&
        ($self->pageInServices() eq "all" || $self->pageInServices() =~ m/\b$service\b/i)) {
        $notifyEmailAddress .= "," . ariba::Ops::Constants->operationsPagerAddress();
    }

    my $queryObjectFile = $self->instance();
    my $notificationRequest = ariba::Ops::NotificationRequest->newMessageHashArgs(
        severity => $status,
        sendingProgram => $0,
        product => $productName,
        service => $service,
        customer => $customer,
        cluster => $cluster,
        subject => $subject,
        body => $body,
        requestedTo => $notifyEmailAddress,
        queryObjectFile => $queryObjectFile
    );

    $notificationRequest->setTreatCritAsWarn(1) unless $notifyForCrits;

    return $notificationRequest->send();
}

sub run {
    my $self = shift;

    return if $self->skip();

    my $startTime = time();

    my $checkTime = $startTime;
    my @results   = ();

    # This allows 'perl' functions to access the current query object.
    $ariba::monitor::Query::_ourGlobalQuerySelf = $self;

    # Only run this if we're not paused.
    if ($self->isPaused($startTime)) {

        # Use the previous results here (this is before
        # the results->previousResults copy) and stuff a note onto the query.

        push(@results, $self->results());

    } else {

        # if the noErrorReset flag is set, it means 'error' was
        # set on this query object on purpose and it's value should be honored
        # otherwise, 'error' is leftover from a previous run and needs to be
        # cleared

        if ($self->noErrorReset()) {
            $self->setNoErrorReset(0);
        } else {
            $self->setError(0);
        }

        # reset any previously existing rowCount
        $self->deleteRowCount();

        if (defined( $self->sql() )) {
            push(@results, $self->_runSql());
        } elsif (defined( $self->aql() )) {
            push(@results, $self->_runAQL());
        } elsif (defined( $self->perl() )) {
            push(@results, $self->_runPerl());
        } elsif (defined( $self->snmp() )) {
            push(@results, $self->_runSnmp());
        } elsif (defined( $self->extractRecorded() )) {
            push(@results, $self->_runExtractRecorded());
        }
    }

    my $runTime = time() - $startTime;

    $self->_setRunStatsAndResults($checkTime, $runTime, @results);

    return ($checkTime, $runTime, @results);
}

sub _setRunStatsAndResults {
    my $self = shift;
    my ($checkTime, $runTime, @results) = @_;

    # if the query was skipped, this might get called with no data.
    return unless ($checkTime);

    $self->setPreviousCheckTime($self->checkTime()) if defined($self->checkTime());
    $self->setPreviousResults( $self->results() );
    $self->setPreviousRowCount( $self->rowCount() || scalar($self->results()) );

    $self->setCheckTime($checkTime);
    $self->setRunTime($runTime);
    $self->setResults(@results);
    $self->setRanOnHost($hostname);
    $self->setRanAsUser((getpwuid($>))[0]);
    $self->setRanByProgram($0);
    $self->setIsStale(0);

    return ($checkTime, $runTime, @results);
}

sub runDetails {
    my $self = shift;

    for my $query ($self->details()) {
        $query->setOracleClient($self->oracleClient()) if defined($self->oracleClient());
        $query->setMySQLClient($self->mySQLClient()) if defined($self->mySQLClient());
        $query->setHanaClient($self->hanaClient()) if defined($self->hanaClient());
        $query->run();
    }
}

# This is a post-process method for working on the data we get back from run()
sub runProcessAnswer {
    my $self = shift;

    my $processAnswer = $self->processAnswer();
    if ($processAnswer) {

        return if $self->isPaused();

        my $startTime     = time();
        my @results       = $self->_runPerl($self->processAnswer());
        $self->setResults(@results);

        # Add this to the time from run()
        $self->setRunTime( $self->runTime() + (time() - $startTime));

    }

    # apply any result limits here
    # queries that are aggregated have to deffer this until
    # after the AggregatedQuery runs, see
    # AggregatedQuery::_limitResults()
    $self->_limitResults() unless $self->isPartOfAggregate();
}

sub _limitResults {
    my $self = shift;

    my @results = $self->results();

    my $limit = $self->rowCountLimit() || 500;
    my $rowCount = scalar(@results);
    $rowCount = 0 if ($rowCount == 1 && !defined($results[0]));

    if ($limit && $rowCount > $limit) {
        splice(@results, $limit);
        $self->setRowCount($rowCount);
        $self->setResults(@results);
    }
}

sub _runSql {
    my $self = shift;
    my $sql = shift || $self->sql();

    my $timeout  = $self->timeout() || 2 * 60;
    my @codeOutput = ();
    my $start    = time();
    my @bindVariables;

    if (my $codeRef = $self->bindVariables()) {
        @bindVariables = &$codeRef();
    }

    if( $self->oracleClient() ) {
        my $oracleClient = $self->oracleClient();

        my $timeoutOccured = !$oracleClient->executeSqlWithTimeout($sql, $timeout, \@codeOutput, \@bindVariables);

        if ( $oracleClient->error() ) {
            $self->setError($oracleClient->error());
            @codeOutput = ($oracleClient->error());
        }

        #
        # Seems that something happens to OracleClient after a timeout occurs
        # that causes future SQL to not be able to run, and doing a
        # disconnect()/connect() doesn't fix it.  Instead, create a new
        # OracleClient object via the QueryManager.

        if ($timeoutOccured) {
            $self->parentQueryManager()->setSQLConnectInfo(
                $oracleClient->user(),
                $oracleClient->password(),
                $oracleClient->sid(),
                $oracleClient->host() || $oracleClient->tnsAdminDir(),
                $self->communityId() || $self->schemaId()
                                       );
        }
    } elsif ( $self->hanaClient() ) {
        my $hanaClient = $self->hanaClient();

        my $timeoutOccured = !$hanaClient->executeSqlWithTimeout($sql, $timeout, \@codeOutput, \@bindVariables, 1);

        if ( $hanaClient->error() ) {
            $self->setError($hanaClient->error());
            @codeOutput = ($hanaClient->error());
        }

        #
        # Creating a new connection after time out.
        #

        if ($timeoutOccured) {
            $self->parentQueryManager()->setSQLConnectInfoForHana(
                $hanaClient->user(),
                $hanaClient->password(),
                $hanaClient->host(),
                $hanaClient->port(),
                $hanaClient->database()
            );
        }
    } elsif ( $self->mySQLClient() ) {
        my $mySQLClient = $self->mySQLClient();

        my $timeoutOccured = !$mySQLClient->executeSqlWithTimeout($sql, $timeout, \@codeOutput);

        if ( $mySQLClient->error() ) {
            $self->setError($mySQLClient->error());
            @codeOutput = ($mySQLClient->error());
        }

        #
        # Creating a new connection after time out.
        #

        if ($timeoutOccured) {
            $self->parentQueryManager()->setSQLConnectInfoForMySQL(
                $mySQLClient->user(),
                $mySQLClient->password(),
                $mySQLClient->host(),
                $mySQLClient->port(),
                $mySQLClient->database()
            );
        }
    }

    return @codeOutput;
}

sub _runAQL {
    my $self = shift;
    my $aql = shift || $self->aql();

    my $timeout  = $self->timeout() || 60;
    my @codeOutput   = ();
    my $start    = time();

    my $aqlClient = $self->AQLClient();

    $aqlClient->executeAQLWithTimeout($aql, $timeout, \@codeOutput);

    if ( $aqlClient->error() ) {
        $self->setError($aqlClient->error());
        @codeOutput = ($aqlClient->error());
    }

    return @codeOutput;
}

# This can take a passed in value, for runProcessAnswer
sub _runPerl {
    my $self = shift;
    my $code = shift || $self->perl();

    my $timeout = $self->timeout() || 180;
    my $retVal  = 0;

    my $codeOutput;
    my $coderef;

    if ( ref($code) ) {
        $coderef = sub { package main; $codeOutput = &$code; };
    } else {
        $coderef = sub { package main; $codeOutput = eval $code; };
    }

    my $start = time();

    # There are some cases (http-watcher) where a different piece of code
    # (geturl) takes care of the timeout, not us. Use a -1 to get that behavior.
    if ($timeout >= 0) {
            $retVal = ariba::Ops::Utils::runWithTimeout($timeout, $coderef);
    } else {
            $retVal = ariba::Ops::Utils::runWithoutTimeout($coderef);
    }

    unless ($retVal) {

        my $end = time();
        my $error;

        my $duration = "start=" . strftime("%H:%M:%S", localtime($start)) .
                " end=" . strftime("%H:%M:%S", localtime($end));


        if ($timeout >= 0) {
            if ( ref($code) ) {
                my $codeBody = ariba::util::PerlRuntime::deparseCoderef($code) || 'code';
                $error = "timed out running code:\n$codeBody\nduration: $duration";
            } else {
                $error = "timed out running \"$code\" $duration";
            }
        } else {
                $error = "error during query execution : \"$@\"\n";
        }

        # Set an error for the caller; it is cleared in the run() method
        if (defined $error) {
            $self->setError($error);
        }

        $codeOutput = $error;
    }

    if (defined $codeOutput) {
        if( ref($codeOutput) eq 'ARRAY' or ref($codeOutput) eq 'HASH'){
            return $codeOutput;
        }
        return split(/\n/o, $codeOutput);
    }

    return undef;
}

sub _runSnmp {
    my $self  = shift;
    my $retry = shift || 5;

    my $args    = $self->snmp();
    my $optArgs = $self->snmpArgs();
    my $timeout = $self->timeout() || 2;

    # oidString can have commas in it and always has to be at the end.
    my ($hostname, $oidString) = split(/,\s*/, $args, 2);
    my ($community, $version, $port);
    ($community, $version, $port) = split(/,\s*/, $optArgs) if $optArgs;

    eval "use ariba::SNMP::Session; use ariba::SNMP::ConfigManager;";

    die "Eval Error: $@\n" if ($@);

    my ($result, $hostIsDown);

    my $machine = ariba::Ops::Machine->new($hostname);
    my $snmp    = ariba::SNMP::Session->newFromMachine($machine);

    unless($snmp->hostIsDown()) {

        $snmp->setCommunity($community) if $community;
        $snmp->setVersion($version)     if $version;
        $snmp->setPort($port)           if $port;

        # oidString may have our custom machine DB object references which
        # need to be resolved (such as cpuCount).
        $oidString = ariba::SNMP::ConfigManager::_cleanupOidExpr($oidString, $machine);

        $result = $snmp->valueForOidExpr($oidString);

        if ($snmp->hostIsDown()) {
            $result = "$hostname is down";
            $self->setError("Error: $result");
        }

        # HACK: sometime snmp queries can return error strings.
        #       make sure we do not try to store that in cdb
        if ($self->recordMaxResults()) {
            if ( $result && $result !~ /^[\d\.]*$/ ) {
                $self->setError("Error: $result");
            }
        }
    }

    return ($result);
}

sub _runExtractRecorded {
    my $self = shift;
    my $args = $self->extractRecorded();

    my ($function,$queryName,$numRecords) = _splitExtractRecordedString($args);

    my $dbFileName = $self->recordDBFileName() || $queryName;

    my $recordDB = ariba::monitor::CircularDB->new($dbFileName);

    if ( defined($recordDB) ) {
        my $value = $recordDB->aggregateUsingFunctionForRecords($function, $numRecords);
        return ($value);
    } else {
        return undef;
    }
}

#
#  This query might have a CDB that's 'related',
#  either directly capturing this query's data, or this query
#  was against some cdb via extractRecorded
#

sub _relatedCDBFilename {
    my $self = shift;

    if ( $self->showGraphLink() ) {
        return ( $self->showGraphLink() ) ;
    }

    if ($self->isGraphable() ) {
        return "file://" . $self->instance();
    }

    if ( my $string = $self->extractRecorded() ) {
        return "file://" . (_splitExtractRecordedString($string))[1];
    }

    return undef;
}

# ---- helper functions

sub _splitExtractRecordedString {
    my $string = shift;

    # average(queryName, using relative path, <numRecords>)
    my ($function,$queryName,$numRecords) = ($string =~ m|(\w*)\s*\(\s*([^,]*)\s*,\s*([^\)]*)\)|);

    return ($function,$queryName,$numRecords);
}

sub _displayMethodToString {
    my $self   = shift;
    my $method = shift;

    my $string;

    my $FH = IO::Scalar->new(\$string);
    $self->$method($FH);
    close $FH;

    return $string;
}

sub combineStatusOfQueries {
    my @queries = @_;

    my %status  = ();
    my $combinedStatus;

    my @statuses = qw(crit crit-forced warn warn-forced info-forced info);

    my $startTime = time();

    for my $query ( @queries ) {
        next if $query->skip();

        my $status = $query->status();

        if ( $status ) {
            $status .= '-forced' if ( $query->isPaused($startTime) || $query->isDowngraded($startTime) || $query->isAnnotated() );
            $status{$status}++;
        }
    }

    for my $s ( reverse(@statuses) ) {
        $combinedStatus = $s if ( $status{$s} );
    }

    return $combinedStatus;
}

sub allowPage{
        my ($subject,$body) = @_;
        my @splitList = split(':',$subject);
        #return 0 if($splitList =~ //);
        my $sub = $splitList[0];
        my $fh;
        my $timeDiff = 0;
        my $retVal = 0;
        my $fdb;
        my $pageTimeDB;


        if((($sub =~ /used/) && ($body =~ /\/disk-usage$/)) ||
           (($sub =~ /uniform\s+tablespace/) && ($body =~ /\/oracle-status/))) {
                unless(-e '/var/tmp/pages.db'){
                        open($fdb,'>','/var/tmp/pages.db');
                        print $fdb "{}";
                        close $fdb;
                }
                open($fdb,'<','/var/tmp/pages.db');
                local $/;
                my $jsonData = <$fdb>;
                close $fdb;
                $pageTimeDB = from_json($jsonData);

                my $newTime = time();
                if(exists $pageTimeDB->{$sub}){
                        $timeDiff = $newTime - $pageTimeDB->{$sub};
                        if($timeDiff >= 1800){
                                $pageTimeDB->{$sub} = $newTime;
                                $retVal = 1;
                        }else{
                                $retVal = 0;
                        }
                }else{
                        $pageTimeDB->{$sub} = $newTime;
                        $retVal = 1;
                }
        }else{
                $retVal = 0;
        }
        if($retVal){
                open($fh,'>','/var/tmp/pages.db');
                print $fh to_json($pageTimeDB,{utf8 => 1, pretty => 1});
                close $fh;
        }
        return $retVal;
}

1;
