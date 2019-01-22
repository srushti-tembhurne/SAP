#
#
#
package ariba::monitor::AggregateQuery;

use strict;
use vars qw(@ISA);

use ariba::monitor::Query;

@ISA = qw(ariba::monitor::Query);

sub newWithSubQueries {
    my $class = shift;
    my $queryName = shift;
    my $productName = shift;
    my $service = shift;
    my $customer = shift;
    my $cluster = shift;
    my $subDir = shift;
    my $aggregationMethod = shift;
    my $recordAggregateDBFileName = shift;
    my $queryManager = shift;
    my @queries = @_;

    my %qhash;

    $qhash{"aggregationMethod"} = $aggregationMethod;
    $qhash{"skipNotifications"} = 1; # to prevent duplicate notification
    if( $queries[0]->uiHint() eq "ignore" ) {
        $qhash{"uiHint"} = "ignore";
    } else {
        $qhash{"uiHint"} = "Aggregated";
    }

    # we can muck with the format in a processAnswer - don't do it again.
    $qhash{"format"} = $queries[0]->format() unless $queries[0]->noFormat();

    $qhash{"skip"} = $queries[0]->skip();
    $qhash{"noRowCount"} = $queries[0]->noRowCount();
    $qhash{"recordMaxResults"} = $queries[0]->recordMaxResults();
    $qhash{"recordDataType"} = $queries[0]->recordDataType();
    $qhash{"recordDataUnits"} = $queries[0]->recordDataUnits();
    $qhash{"recordItem"} = $queries[0]->recordItem();

    $qhash{"recordAggregateDBFileName"} = $recordAggregateDBFileName;

    my $self = $class->SUPER::newFromHash(
        $queryName,
        $productName,
        $service,
        $customer,
        $cluster,
        \%qhash,
        $subDir,
        $queryManager
    );

    bless($self, $class);

    $self->setAggregateQueries(@queries);

    return $self;
}

sub objectLoadMap {
    my $class = shift;

    my $mapRef = $class->SUPER::objectLoadMap();

    $$mapRef{'aggregateQueries'} =  '@ariba::monitor::Query';

    return $mapRef;
}

sub run {
    my $self = shift;

    return if $self->skip();

    my $startTime = time();

    my $checkTime = $startTime;
    my @results = $self->_combineQueriesResults();

    my $runTime = time() - $startTime;

    $self->_setRunStatsAndResults($checkTime, $runTime, @results);

    return ($checkTime, $runTime, @results);
}

sub _limitResults {
    my $self = shift;

    for my $query ($self->aggregateQueries()) {
        $query->_limitResults();
    }

    $self->SUPER::_limitResults();
}

sub _combineQueriesResults {
    my $self = shift;

    my $aggregationMethod = $self->aggregationMethod();
    my @results;
    my $uniqueResults = {};

    for my $query ($self->aggregateQueries()) {

        my @queryResults = $query->results();

        if ($aggregationMethod eq "rows") {

            @results = sort(@results, @queryResults);

        } elsif ($aggregationMethod eq "counts") {

            # assumes each row of query result has just one number.
            # if there are multiple columns that contain numbers, split
            # on colsep, add them up and join on colsep for each row
            # of final results.
            for (my $i = 0; $i < @queryResults; $i++) {

                $results[$i] = 0  unless (defined $results[$i]);

                #
                # if the result contains an string (such as
                # a database error), don't attempt math op.
                #
                if ( $queryResults[$i] =~ /^[\d\.]+$/ ) {
                    $results[$i] += $queryResults[$i];
                }
            }

        } elsif ($aggregationMethod eq "uniqueCounts") {

            for ( my $i = 0; $i < scalar(@queryResults); $i++ ) {

                if ( $queryResults[$i] =~ /^([\d\.]+)\s+(.*)$/ ) {
                    $uniqueResults->{$2} += $1;

                }
            }
        }
    }

    if ( $aggregationMethod eq "uniqueCounts") { 
        foreach my $result (keys %$uniqueResults) {
            push(@results, $uniqueResults->{$result} . "\t" . $result);
        }

        @results = sort { $b <=> $a } @results;
    }

    return (@results);
}

sub checkThresholds {
    my $self = shift;
    my $possibleStatus = shift;

    my $status = ariba::monitor::Query::combineStatusOfQueries($self->aggregateQueries());

    if ($status) {
        if ( defined($self->status()) ) {
            $self->setPreviousStatus($self->status());
        }
        $self->setStatus($status);

        if ( ! defined($self->previousStatus()) ||
            ( defined($self->previousStatus()) && 
            $self->status() ne $self->previousStatus() ) ) {

            $self->setStatusChangeTime( $self->checkTime() );
        }

        if( $self->status() eq 'info' || !$self->lastInfoResultTime() ) {
            $self->setLastInfoResultTime( $self->checkTime() ) ;
        }
    }

    return $status;
}

1;
