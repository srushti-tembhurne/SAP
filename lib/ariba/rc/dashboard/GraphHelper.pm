package ariba::rc::dashboard::GraphHelper;

# Helper Class for fetching values for Graph
#
# $Id:
#
# Responsible: Raghuveer Phull
#
# $Author:
#

use strict;
use warnings;
use Data::Dumper;
use POSIX;
use JSON;
use LWP::Simple;

# Global hash for determining the order on which graph should be grouped
my %order = (
    'compile'             => 1,
    'archive'             => 2,
    'rsync-archive-wait'  => 3,
    'rsync'               => 4,
    'mkconfig'            => 5,
    'rsync-2'             => 6,
    'install-rsync2-wait' => 7,
    'restart'             => 8,
    'restoreonly'         => 9,
    'restore'             => 9,
    'migrate'             => 10,
    'App-Start'           => 11,
    'install'             => 11,
    'prequal-start-wait'  => 12,
    'PreQual-LQ'          => 13,
    'PreQual-Delay-LQ'    => 14,
    'Qualification-LQ'    => 15,
);

my %color = (
    'compile'             => '#408BBF',
    'archive'             => '#AEC7E8',
    'rsync-archive-wait'  => '#FF7F0E',
    'rsync'               => '#FFBB78',
    'mkconfig'            => '#3AA63A',
    'rsync-2'             => '#A1E194',
    'install-rsync2-wait' => '#D72F30',
    'restart'             => '#A57EC7',
    'restoreonly'         => '#CAB7D9',
    'restore'             => '#946157',
    'migrate'             => '#CEAEA7',
    'App-Start'           => '#E47BC4',
    'prequal-start-wait'  => '#F9C3DA',
    'PreQual-LQ'          => '#8D8D8D',
    'PreQual-Delay-LQ'    => '#D1D1D1',
    'Qualification-LQ'    => '#4C4646',
);

my @desired = (
    'mkconfig',         'compile',            'rsync',               'restore', 'migrate',
    'App-Start',   'Qualification-LQ', 'PreQual-LQ',         'rsync-2',             'restart', 'PreQual-Delay-LQ',
    'restoreonly', 'archive',          'rsync-archive-wait', 'install-rsync2-wait', 'prequal-start-wait'
);

# Returns unique elements of an array
sub unique {
    return keys %{ { map { $_ => 1 } @_ } };
}

# Returns all the milestones for given build.
sub getMilestonesForBuild {
    my $refData = shift;
    my @data;

    foreach my $build ( keys %$refData ) {
        push ( @data, keys %{ $refData->{ $build } } );
    }

    return sortMilestones( unique( @data ) );
}

# Returns all the milestones and sort them based on global order hash
sub getMilestones {
    my $refData = shift;
    my @data    = getKeys( $refData );

    return sortMilestones( unique( @data ) );
}

sub getAllUniqueMilestones {
    my $rhBuilds = shift;
    my @milestones;

    foreach my $build ( keys %$rhBuilds ) {
        foreach my $service ( keys %{ $rhBuilds->{ $build } } ) {
            push ( @milestones, keys %{ $rhBuilds->{ $build }->{ $service } } );
        }
    }

    return sortMilestones( unique( @milestones ) );
}

# returns keys to any hash input
sub getKeys {
    my $refData = shift;
    return keys %$refData;
}

# Subroutine to validate start time and end time
# Returns 0: if no problem
# Returns 1: if Problem
# Returns 2: If in progress
sub isUndesiredDate {
    my $start = shift;
    my $end   = shift;

    return 2 if $end == 0;
    return 0 if ( $start == $end );
    return ( $start > $end ) ? 1 : 0;
}

# Google charst expects date in certain format. This will convert the epoch value of DB into google
# Expected format for date
sub changeDateFormat {
    my $input = shift;
    my ( $sec, $min, $hour, $day, $month, $year ) = ( localtime ( $input ) )[ 0, 1, 2, 3, 4, 5 ];
    $year += 1900;

    return "$year, $month, $day, $hour, $min, $sec";
}

# Filtering out only necessary milestones for plotting graph. Anything outside @desired is discarded
sub isDesiredMilestone {
    my $milestone = shift;
    return ( grep { /^$milestone$/ } @desired ) ? 1 : 0;
}

# Sorts all the input milestones based on global order hash
sub sortMilestones {
    my @milestones = @_;
    @milestones = grep { isDesiredMilestone( $_ ) } @milestones;
    my @sort = ();

    for ( my $i = 0; $i <= $#milestones; $i++ ) {
        my $key = $order{ $milestones[ $i ] };
        $sort[ $key ] = $milestones[ $i ];
    }

    @sort = grep { $_ ne '' || $_ ne undef } @sort;

    return @sort;
}

# Gets 1st order of groups for plotting timeline graph
sub getGroups {
    my $milestone = shift;
    my $service   = shift;
    my $product   = shift;

    my %grouping = (
    	'mkconfig'         => 'Push',
        'compile'          => 'Build',
        'archive-rc'       => 'Build',
        'archive'          => 'Build',
        'rsync'            => 'Push',
        'restore'          => 'Install',
        'migrate'          => 'Install',
        'App-Start'        => 'Install',
        'Qualification-LQ' => 'Qualification',
        'PreQual-LQ'       => 'Qualification',
        'rsync-2'          => 'Push',
        'restart'          => 'Install',
        'PreQual-Delay-LQ' => 'Qualification',
        'restoreonly'      => 'Install',
    );

    return 'Unknown' if ( !grep { /$milestone/ } keys %grouping );
    return ( $service && $service ne 'Build' )
      ? ucfirst ( $product ) . " " . $grouping{ $milestone } . " " . uc ( $service )
      : ucfirst ( $product ) . " " . $grouping{ $milestone };
}

# Gets 2nd order of groups for plotting timeline graph
sub getSubGroup {
    my $milestone = shift;
    my $status    = shift;

    $milestone =~ s/archive-rc/archive/g if ( $milestone =~ /archive-rc/ );

    return ucfirst ( $milestone ) . " : " . ucfirst ( $status );
}

# Populating Compile info for all the graphs because the Servicename for compile and archive is
# stored in DB as Build and things will not work if somebody specifies servicename as input
sub getCompileInfo {
    my $rhService = shift;

    my @rows;
    my ( $start_date, $end_date, $status, $product );

    if ( exists $rhService->{ 'Build' }->{ 'compile' } ) {
        $start_date = changeDateFormat( $rhService->{ 'Build' }->{ 'compile' }->{ 'start_date' } );
        $end_date   = changeDateFormat( $rhService->{ 'Build' }->{ 'compile' }->{ 'end_date' } );
        $product    = $rhService->{ 'Build' }->{ 'compile' }->{ 'productname' };
        $status     = $rhService->{ 'Build' }->{ 'compile' }->{ 'status' };

        my $group = getGroups( 'compile', 'Build', $product );
        my $subgroup = getSubGroup( 'compile', $status );
        push ( @rows, qq [ \[ '$group' , '$subgroup', new Date \($start_date\), new Date\( $end_date\) \], \n ] ) ;# if (($fullbuild eq 'true' ) || ($mfullbuild eq 'true') );
    }

    if ( exists $rhService->{ 'Build' }->{ 'archive' } ) {
        $start_date = changeDateFormat( $rhService->{ 'Build' }->{ 'archive' }->{ 'start_date' } );
        $end_date   = changeDateFormat( $rhService->{ 'Build' }->{ 'archive' }->{ 'end_date' } );
        $product    = $rhService->{ 'Build' }->{ 'archive' }->{ 'productname' };
        $status     = $rhService->{ 'Build' }->{ 'archive' }->{ 'status' };

        my $group = getGroups( 'archive', 'Build', $product );
        my $subgroup = getSubGroup( 'archive', $status );

        push ( @rows, qq [ \[ '$group' , '$subgroup', new Date \($start_date\), new Date\( $end_date\) \], \n ] ) ;# if (($fullbuild eq 'true' ) || ($mfullbuild eq 'true') );
    }

    return \@rows;
}

# Public method which is used by caller to plot the DB. Input is Hash return by DB.PM for some query
sub getGraphRows {
    my $refData     = shift;
    my $buildname   = shift;
    my $servicename = shift;
    my $robotflag   = shift;
    my $fullbuild   = shift;    

    my $showBuildInfo=0;
    $showBuildInfo = 1 if ( $fullbuild eq 'true'); 
    my @rows =();
    if ($showBuildInfo){
        push( @rows , @{ getCompileInfo( $refData->{ $buildname })});
    }
    my @milestones;

    if ( defined ( $servicename ) ) {
        @milestones = getMilestones( $refData->{ $buildname }->{ $servicename } );
        push ( @rows, @{ populateRows( $refData->{ $buildname }, \@milestones, $servicename ) } );
        push ( @rows, getOverallRow( $refData->{ $buildname }, $servicename, $showBuildInfo ) );
    } else {
        my @services = getKeys( $refData->{ $buildname } );
        foreach my $service ( sort @services ) {
            next if $service eq 'Build';
            my @milestones = getMilestones( $refData->{ $buildname }->{ $service } );
            push ( @rows, @{ populateRows( $refData->{ $buildname }, \@milestones, $service ) } );
        }
    }

    return \@rows;
}

# Since start time is not coming, we calculate it here
# [ Rule ] Start time = Install End Time - RestoreMigrate End Time
sub calculateInstallInfo {
    my $rhMilestones = shift;

    my $start_date  = $rhMilestones->{ 'restoremigrate' }->{ 'end_date' };
    my $end_date    = $rhMilestones->{ 'install' }->{ 'end_date' };
    my $servicename = $rhMilestones->{ 'install' }->{ 'servicename' };
    my $status      = $rhMilestones->{ 'install' }->{ 'status' };
    my $product     = $rhMilestones->{ 'install' }->{ 'productname' };

    my $date_check = isUndesiredDate( $start_date, $end_date );
    $start_date = changeDateFormat( $start_date );
    $end_date   = changeDateFormat( $end_date );

    my $group = getGroups( 'App-Start', $servicename, $product );
    my $subgroup = getSubGroup( 'App-Start', $status );

    unless ( $date_check == 2 ) {
        return qq [ \[ '$group' , '$subgroup', new Date \($start_date\), new Date\( $end_date\) \], \n ];
    }

    return;
}

# Returns productname, branch name and log file for given ref build hash
sub getDisplayInfo {
    my $rhBuild = shift;
    my $return;

    my @services = keys %$rhBuild;
    my $product = $rhBuild->{ 'Build' }->{ 'compile' }->{ 'productname' };
    $product =~ s/an/AN/g if ( $product eq 'an' );

    my $log = $rhBuild->{ 'Build' }->{ 'compile' }->{ 'logfile' };
    $log =~ s#\/home\/rc#https\:\/\/rc\.ariba\.com#g;
    my $branch = $rhBuild->{ 'Build' }->{ 'compile' }->{ 'branchname' };
    my $date   = $rhBuild->{ 'Build' }->{ 'compile' }->{ 'start_date' };
    my $time   = strftime "%a %b %e, %H:%M:%S  %Z %Y", localtime($date);

    $return->{'product'} = ucfirst ( $product );
    $return->{'branch'} = $branch;
    $return->{'log'} = $log;
    $return->{'time'} = $time;
    push @{$return->{'services'}}, @services;

    return $return;
}

# The subroutine which forms all the data for plotting graph. Main method in whole module
sub populateRows {
    my $rhService    = shift;
    my $raMilestones = shift;
    my $service      = shift;
    my $robotflag    = shift;
    my $fullbuild    = shift; 
    my $mfullbuild   = shift;
    my @rows;

    foreach my $milestone ( @$raMilestones ) {
        if ( exists $rhService->{ $service }->{ $milestone } ) {
            my $start_date  = $rhService->{ $service }->{ $milestone }->{ 'start_date' };
            my $end_date    = $rhService->{ $service }->{ $milestone }->{ 'end_date' };
            my $product     = $rhService->{ $service }->{ $milestone }->{ 'productname' };
            my $servicename = $rhService->{ $service }->{ $milestone }->{ 'servicename' };
            my $status      = $rhService->{ $service }->{ $milestone }->{ 'status' };

            my $date_check = isUndesiredDate( $start_date, $end_date );

            next if ( !$robotflag && ( $servicename =~ /personal_/ ) );
            next if ( $date_check == 1 );

            if ( $date_check == 2 ) {
                $end_date = $start_date + 500 + int ( rand ( 50 ) );
                $status   = 'In Progress';
            }

            $start_date = changeDateFormat( $start_date );
            $end_date   = changeDateFormat( $end_date );

            my $group = getGroups( $milestone, $servicename, $product );
            my $subgroup = getSubGroup( $milestone, $status );

            push ( @rows, qq [ \[ '$group' , '$subgroup', new Date \($start_date\), new Date\( $end_date\) \], \n ] );

        }
    }

    if ( exists $rhService->{ $service }->{ 'restoremigrate' } && exists $rhService->{ $service }->{ 'install' } ) {
        push ( @rows, calculateInstallInfo( $rhService->{ $service } ) );
    }

    return \@rows;
}

sub getFirstAndLastAction {
    my $refData    = shift;
    my @milestones = sortMilestones( keys %$refData );
    return $milestones[ 0 ], $milestones[ -1 ];
}

# Determining first and last action for plotting overall graph
sub getFirstAndLastActionForBuild {
    my $refData  = shift;
    my $showBuildInfo   = shift;
    my @services = getKeys( $refData );
    my %reverseHash;
    my @milestones;
    
	foreach my $service ( sort @services ) {
         @milestones = getMilestones( $refData->{ $service } );
         foreach my $milestone ( @milestones ) {
            my $start = $refData->{ $service }->{ $milestone }->{ 'start_date' };
            $reverseHash{ $start } = $milestone;
        }
    }
    
	my @temp = ( sort ( keys %reverseHash ) );
    if ($showBuildInfo){
        return  $reverseHash{$temp[ 0 ]} , $reverseHash{ $temp[ -1 ]} ;
    }
    else{
        $temp[ 0 ]  = $milestones[0];
        return  $temp[ 0 ] , $reverseHash{ $temp[ -1 ]};
    }
}

# Plotting overall line in graph. This will be plot only where service name is input
sub getOverallRow {
    my $rhService = shift;
    my $service   = shift;
    my $showBuildInfo   = shift;
	my $raw = shift || 0;
    my $row       = '';

    my ( $first, $last ) = getFirstAndLastActionForBuild( $rhService , $showBuildInfo );
    my $start_time;
    $start_time =  $rhService->{ $service }->{ $first }->{ 'start_date' };

    my $end_time = $rhService->{ $service }->{ $last }->{ 'end_date' };

	if ($raw) {
		return ($end_time - $start_time);
	}

    my $product = ucfirst ( $rhService->{ 'Build' }->{ 'compile' }->{ 'productname' } )
      || ucfirst ( $rhService->{ $service }->{ $first }->{ 'productname' } );

    my $date_check = isUndesiredDate( $start_time, $end_time );

    $start_time = changeDateFormat( $start_time );
    $end_time   = changeDateFormat( $end_time );

    $first = ucfirst ( $first );
    $last  = ucfirst ( $last );

    unless ( $date_check == 2 ) {
        $row = qq [\[ '$product Overall' , 'Overall $product: From $first to $last', new Date \($start_time\), new Date\( $end_time\) \], \n ];
    }

    return $row;
}

# Just retuns list of all the builds for a given product.
sub getBuildsForProduct {
    my $refData = shift;
    my $product = shift;

    my @builds;

    foreach my $build ( getKeys( $refData ) ) {
        my $refProd = $refData->{ $build }->{ 'compile' }->{ 'productname' };
        if ( $refProd eq $product ) {
            push ( @builds, $build );
        }
    }

    return unique( @builds );
}

sub unifyHash {
    my $rhbuild = shift;

    my @milestones;

    foreach my $build ( keys %$rhbuild ) {
        push ( @milestones, keys %{ $rhbuild->{ $build } } );
    }

    @milestones = sortMilestones( unique( @milestones ) );

    #print Dumper @milestones;

    my $unified;
    foreach my $milestone ( @milestones ) {
        foreach my $bld ( sort { $a cmp $b } keys %$rhbuild ) {
            push @{ $unified->{ $milestone } }, ( ( exists ( $rhbuild->{ $bld }->{ $milestone } ) && $rhbuild->{ $bld }->{ $milestone } > 0 ) ? $rhbuild->{ $bld }->{ $milestone } : 0 );
        }
    }

    return $unified;
}

sub getJSON {
    my $rhBuild = shift;

    my $rhUnified = unifyHash( $rhBuild );
    my $something;
    my @big = ();

    foreach my $key ( sortMilestones( keys %$rhUnified ) ) {
        my $counter = 0;
        my @array   = ();
        foreach my $element ( @{ $rhUnified->{ $key } } ) {
            push ( @array, { 'x' => $counter, 'y' => ceil( $element ) } );
            $counter++;
        }
        push ( @big, { 'values' => \@array, 'key' => ucfirst $key, 'color' => $color{ $key } } );
    }

    my $json = JSON::to_json( \@big, { ascii => 1, pretty => 1 } );
    return $json;
}

sub getBuildAssociationFromJenkins {
    my $servicename = shift;

    return unless $servicename;
    my %association;
    my $jenkinsurl = "http://jenkins.ariba.com:8080/api/json?pretty=true&depth=1&tree=jobs[name,builds[fullDisplayName,number]]";

    my $json = get( $jenkinsurl );
    die "Could not get $jenkinsurl!" unless defined $json;

    $json = decode_json ( $json );

    foreach my $set ( @{$json->{'jobs'}}) {
        next unless ($set->{'name'} =~ /autolq/i);
        my (undef, $service) = split ('-', $set->{'name'} );
        if ($service eq $servicename ) {
            foreach my $line ( @{$set->{'builds'}}) {
                chomp($line);
                next if ($line->{'fullDisplayName' } =~ /#/);
                $line->{'fullDisplayName' } =~ s/\[//g;
                $line->{'fullDisplayName' } =~ s/\]//g;
                my (undef, $build1, $build2, $build3) = split (' ', $line->{'fullDisplayName' } );
                my @tmpArray=($build1, $build2, $build3);
                my @finalArray;
                foreach my $tmp(@tmpArray)
                {
                    push @finalArray, $tmp if ($tmp !~ /Arches/);
                }
                my ($firstBuild,$secondBuild)=@finalArray;
                $association{$service}{$firstBuild} = $secondBuild;
                $association{$service}{$secondBuild} = $firstBuild;

            }
        }
    }

    return \%association;
}

sub getWaitURL {
    my $cgi = shift;

    my $url = $cgi->url();
    my $action      = $cgi->param( 'action' );
    my $product = $cgi->param( 'product' ) || "";
    my $service = $cgi->param( 'service' ) || undef;
    my $buildarray  = $cgi->param( 'buildarray' ) || $cgi->param( 'builds' ) || "";
    my $json = $cgi->param( 'json' );

    $url .= "?action=$action";

    if ( $service ){
        $url .= "&service=$service";
    }

    if ( $product ) {
        $url .= "&product=$product";
    } elsif ( $buildarray ) {
        $url .= "&builds=$buildarray";
    } elsif ( $json ) {
        $url .= "&json=$json";
    }

    return $url;
}

1;
