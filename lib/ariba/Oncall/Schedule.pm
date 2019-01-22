package ariba::Oncall::Schedule;

# $Id: //ariba/services/monitor/lib/ariba/Oncall/Schedule.pm#26 $

use strict;
use ariba::Ops::Constants;
use Date::Parse;
use Time::Local;
use Date::Calc;

## These constants are used below, be careful if you change the values
## math in inSnvTime(), inEuropeTime(), and inBlrTime() might break
my $switchHour       = 10;
my $europeSwitchHour = 18;
my $blrSwitchHour    = 2;

my %scheduleCache    = ();
my $eightHours = 8 * 60 * 60;

## "Enumeration" for shift names:
my $SHIFT_ONE     = 'shift1';
my $SHIFT_TWO     = 'shift2';
my $SHIFT_THREE   = 'shift3';
my $BACKUP_ONE    = 'backup';
my $BACKUP_TWO    = 'backup2';
my $BACKUP_THREE  = 'backup3';

my @months = qw(jan feb mar apr may jun jul aug sep oct nov dec);

my @methods = qw(fileName year monthName days switchTime);

# create autoloaded methods
for my $datum (@methods) {
    no strict 'refs';
    *$datum = sub { return shift->{$datum} }
}

sub eightHours {
    return $eightHours;
}

sub switchHour() {
    return $switchHour;
}

sub shift1Name() {
    return $SHIFT_ONE;
}

sub shift2Name() {
    return $SHIFT_TWO;
}

sub shift3Name() {
    return $SHIFT_THREE;
}

sub backup1Name() {
    return $BACKUP_ONE;
}

sub backup2Name() {
    return $BACKUP_TWO;
}

sub backup3Name() {
    return $BACKUP_THREE;
}

## europe (EMEA) code has not been used recently, looks like the code is here for
## legacy reasons.  In order to implement 3 SRE shifts I will be using the europe*
## methods for shift2.  blr* will be shift3.
sub europeSwitchHour() {
    return $europeSwitchHour;
}

sub blrSwitchHour() {
    return $blrSwitchHour;
}

sub _keyForDay {
    my $self = shift;
    my $key = shift;
    my $day = shift;

    return ${$self->{sched}}[$day]->{$key};
}

## Generic method to return which shift we are currently in
sub inShiftPrimary {
    my $self = shift;

    if ( $self->inShift3Time() ){
        return $SHIFT_THREE;
    } elsif ( $self->inShift2Time() ){
        return $SHIFT_TWO;
    } else {
        return $SHIFT_ONE;
    }
}

sub inShiftBackup {
    my $self = shift;

    if ( $self->inShift3Time() ){
        return backup3Name();
    } elsif ( $self->inShift2Time() ){
        return backup2Name();
    } else {
        return backup1Name();
    }
}

sub currShiftStartTime {
    my $self = shift;

    if ( $self->inShift3Time() ){
        return $blrSwitchHour;
    } elsif ( $self->inShift2Time() ){
        return $europeSwitchHour;
    } else {
        return $switchHour;
    }
}

sub prevShiftStartTime {
    my $self = shift;

    if ( $self->inShift3Time() ){
        return $europeSwitchHour;
    } elsif ( $self->inShift2Time() ){
        return $switchHour;
    } else {
        return $blrSwitchHour;
    }
}

sub primaryForNow {
    my $self  = shift;
	my $specifiedTime = shift || time();
	my $old = shift;

	#
	# XXX -- this should fail if time is not in the loaded object --
	# actually, this should prolly be a class method that loads the right
	# month.
	#

    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($specifiedTime);
    $mday-- if $self->stillYesterday($specifiedTime);

	if($mday < 1) {
		#
		# bleh -- on the first of each month this breaks since this object has
		# the schedule for the shifts that start at 10am, but from midnight
		# to 9:59:59am, we need LAST MONTH's schedule
		#
		my ($lyear, $lmon);
		($lyear, $lmon, $mday) = (localtime($specifiedTime-86400))[5,4,3];
		$lyear+=1900;
		$lmon++;
		my $lsched = ref($self)->new($lmon, $lyear);
		return($lsched->primaryForShiftAndDay($self->inShiftPrimary(),$mday));
	}

    return $self->primaryForShiftAndDay( $self->inShiftPrimary(), $mday );
}

sub backupForNow {
    my $self  = shift;
	my $specifiedTime = shift || time();
    my $backup;

	#
	# XXX -- this should fail if time is not in the loaded object --
	# actually, this should prolly be a class method that loads the right
	# month.
	#

    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($specifiedTime);
    $mday-- if $self->stillYesterday($specifiedTime);

	if($mday < 1) {
		#
		# bleh -- on the first of each month this breaks since this object has
		# the schedule for the shifts that start at 10am, but from midnight
		# to 9:59:59am, we need LAST MONTH's schedule
		#
		my ($lyear, $lmon);
		($lyear, $lmon, $mday) = (localtime($specifiedTime-86400))[5,4,3];
		$lyear+=1900;
		$lmon++;
		my $lsched = ref($self)->new($lmon, $lyear);
		$backup = $lsched->backupForShiftAndDay($self->inShiftBackup(),$mday);
    	if ( !$backup ){
        	$backup = $lsched->backupForShiftAndDay($self->backup1Name(), $mday);
    	}
	} else {

    	$backup = $self->backupForShiftAndDay( $self->inShiftBackup(), $mday );
    	if ( !$backup ){
        	$backup = $self->backupForShiftAndDay($self->backup1Name(), $mday);
    	}
	}

    return ( $backup ? $backup : 'Unknown' );
}

## Generic primaryForShiftAndDay()
sub primaryForShiftAndDay {
    my $self  = shift;
    my $shift = shift;
    my $day   = shift;

    return $self->_keyForDay( $shift, $day );
}

## Generic backupForShiftAndDay()
sub backupForShiftAndDay {
    my $self  = shift;
    my $shift = shift;
    my $day   = shift;

    return $self->_keyForDay( $shift, $day );
}

## shift1
sub primaryForDay {
    my $self = shift;
    my $day = shift;

    return $self->_keyForDay("shift1", $day);
}

## shift2
sub europePrimaryForDay {
    my $self = shift;
    my $day = shift;

    return $self->_keyForDay("shift2", $day);
}

## shift3
sub blrPrimaryForDay {
    my $self = shift;
    my $day = shift;

    return $self->_keyForDay("shift3", $day);
}

sub backupForDay {
    my $self = shift;
    my $day = shift;

    return $self->_keyForDay("backup", $day);
}

sub backup2ForDay {
    my $self = shift;
    my $day = shift;

    return $self->_keyForDay("backup2", $day);
}

sub backup3ForDay {
    my $self = shift;
    my $day = shift;

    return $self->_keyForDay("backup3", $day);
}

sub sysadminForDay {
    my $self = shift;
    my $day = shift;

    return $self->_keyForDay("sysadmin", $day);
}

sub netadminForDay {
    my $self = shift;
    my $day = shift;

    return $self->_keyForDay("netadmin", $day);
}

sub dbaForDay {
    my $self = shift;
    my $day = shift;

    return $self->_keyForDay("dba", $day);
}

sub toolsForDay {
    my $self = shift;
    my $day = shift;

    return $self->_keyForDay("tools", $day);
}

sub deploymentForDay {
    my $self = shift;
    my $day = shift;

    return $self->_keyForDay("deployment", $day);
}

sub primaryDeveloperForDay {
    my $self = shift;
    my $day = shift;

    return $self->_keyForDay("primaryDeveloper", $day);
}

sub backupDeveloperForDay {
    my $self = shift;
    my $day = shift;

    return $self->_keyForDay("backupDeveloper", $day);
}

sub commentForDay {
    my $self = shift;
    my $day = shift;

    return $self->_keyForDay("comment", $day);
}

sub pageStatusURLForDay {
    my $self = shift;
    my $day = shift;

    my ($startUnixTime, $endUnixTime) = $self->shiftTimeRangeForDay($day);

    my $pageStatusLink  = '';
    $pageStatusLink    .= ariba::Ops::Constants->pageStatusPath();
    $pageStatusLink    .= "?startUnixTime=$startUnixTime";
    $pageStatusLink    .= "&endUnixTime=$endUnixTime";

    return $pageStatusLink;
}

# on-call shift, not perl array shift :)
sub shiftTimeRangeForDay {
    my $self = shift;
    my $day = shift;

    return ref($self)->shiftTimeRangeForUnixTime(
        $self->unixTimeForDay($day)
    );
}

sub inShift1Time {
    my $self = shift;

    return (!$self->inShift2Time() && !$self->inShift3Time()) ? 1 : 0;
}

sub inShift2Time {
    my $self = shift;

    return $self->inEuropeTime();
}

sub inShift3Time {
    my $self = shift;

    return $self->inBlrTime();
}

sub inSnvTime {
    # 1000 - 1800
    my $class = shift;
    my $unixtime = shift || time();

    my $hour = (localtime($unixtime))[2];


    return($hour >= $switchHour && $hour < $europeSwitchHour);
}

sub inEuropeTime {
    ## This is the shift that wraps around midnight, this is the easiest
    ##  way to handle that.
    return ( !__PACKAGE__->inSnvTime() && !__PACKAGE__->inBlrTime() );
}

sub inBlrTime {
    # 0200 - 1000
    my $class = shift;
    my $unixtime = shift || time();

    my $hour = (localtime($unixtime))[2];

    return( $hour >= $blrSwitchHour && $hour < $switchHour );
}

sub unixTimeForDay {
    my $self = shift;
    my $day = shift;

    my $yy  = $self->{'year'};
    my $mm  = $self->{'monthName'};

    str2time("$day $mm $yy 00:00");
}

#
# Return the array of abbreviations we use for months
#
sub months {
    my $class = shift;

    return @months;
}

#--------------------------------------------------------------------------------

sub _switchingKeyForUnixTime {
    my $class = shift;
    my $key = shift;
    my $unixtime = shift;

    # compute the exact primary oncall at time unixtime
    # deal with month/year wraps, before, after switchTime(), etc.

    my $uhour = (localtime($unixtime))[2];

    # fix switchTime() do it's usable 
    if ( $uhour < $switchHour ) {
        $unixtime -= 24 * 3600;
        #
        # XXX -- in spring DST, now minus 24 hours can be 2 days ago
        # so we have to normalize for it
        #
        $unixtime = $class->_fixForDST($unixtime, $uhour);
    }

    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($unixtime);
    my $schedule = $class->new(++$mon, $year+1900);

    #
    # XXX -- this is somewhat of a hack.  If we have a europen primary
    # then european primary oncall is from european switch time on the
    # scheduled day, until shift change time on the next day.
    #
    # here we make requests for primary return the europe primary
    # if we are in the european shift window and we have a european on-call
    # person.
    #
    if($key eq "primary" && $schedule->_keyForDay("europePrimary", $mday) &&
        $class->inEuropeTime()) {
            $key = "europePrimary";
    }


    # here we make requests for primary return the blr primary
    # if we are in the BLR shift window and we have a BLR on-call
    # person.
    if($key eq "primary" && $schedule->_keyForDay("blrPrimary", $mday) &&
        $class->inBlrTime()) {
            $key = "blrPrimary";
    }

    return $schedule->_keyForDay($key, $mday);
}

sub primaryForUnixTime {
    my $class = shift;
    my $unixtime = shift;

    return $class->_switchingKeyForUnixTime("primary", $unixtime);
}

sub backupForUnixTime {
    my $class = shift;
    my $unixtime = shift;

    return $class->_switchingKeyForUnixTime("backup", $unixtime);
}

sub developerForUnixTime {
    my $class = shift;
    my $unixtime = shift;

    return $class->_switchingKeyForUnixTime("developer", $unixtime);
}

sub commentForUnixTime {
    my $class = shift;
    my $unixtime = shift;

    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($unixtime);
    my $schedule = $class->new(++$mon, $year+1900);

    return $schedule->_keyForDay("comment", $mday);
}

sub shiftTimeRangeForUnixTime {
    my $class = shift;
    my $unixTime = shift;

    # Because we don't know for sure that shiftHour is 12, and our time 
    # range is actually centered around midnight of the following day:
    my $startUnixTime = $unixTime + (60*60*24) - (60*60*(24-$switchHour));
    my $endUnixTime   = $unixTime + (60*60*24) + (60*60*($switchHour));

    #
    # fix for DST -- some shifts are 23 hours, some are 25.
    #
    $startUnixTime = $class->_fixForDST($startUnixTime);
    $endUnixTime = $class->_fixForDST($endUnixTime);

    $endUnixTime--; # subtract a second now that we've normalized

    return ($startUnixTime, $endUnixTime);
}

sub shiftTimeRangeForDayAndNumber {
    my $self = shift;
    my $dayCheck = shift;
    my $shift = shift;
    my ($startTime, $endTime);

    my $time = $self->unixTimeForDay($dayCheck);

    my ($mday, $month, $year) = (localtime($time))[3, 4, 5];

    my ($year2, $month2, $day2, $hour2, $min2, $sec2);
    my $Dh = 8;
    my $Dd = 1;

    #
    # Time::Local index starts at 0 for month
    # Date::Calc index starts at 1 for month
    # Need to add / subtract 1 from $month accordingly
    #
    if ( $shift == 1 ) {
        $startTime = timelocal(0, 0, $switchHour, $mday, $month, $year);
        ($year2, $month2, $day2, $hour2, $min2, $sec2) = Date::Calc::Add_Delta_DHMS(
            $year, $month+1, $mday, $switchHour, 0, 0, 0, $Dh, 0, 0);
    } elsif ( $shift == 2 ) {
        $startTime = timelocal(0, 0, $europeSwitchHour, $mday, $month, $year);
        ($year2, $month2, $day2, $hour2, $min2, $sec2) = Date::Calc::Add_Delta_DHMS(
            $year, $month+1, $mday, $europeSwitchHour, 0, 0, 0, $Dh, 0, 0);
    } elsif ( $shift == 3 ) { 
        ## add 1 day to shift#3 since it starts 2am the next day
        ($year, $month, $mday) = Date::Calc::Add_Delta_Days(
            $year, $month+1, $mday, $Dd);

        $startTime = timelocal(0, 0, $blrSwitchHour, $mday, $month-1, $year);

        ($year2, $month2, $day2, $hour2, $min2, $sec2) = Date::Calc::Add_Delta_DHMS(
        $year, $month, $mday, $blrSwitchHour, 0, 0, 0, $Dh, 0, 0);
    }
 
    ## endTime is 1sec before the end of the shift time
    ($year2, $month2, $day2, $hour2, $min2, $sec2) = Date::Calc::Add_Delta_DHMS(
        $year2, $month2, $day2, $hour2, $min2, $sec2,
        0, -1, 59, 59);

    $endTime = timelocal($sec2, $min2, $hour2, $day2, $month2-1, $year2);

    return ($startTime, $endTime);
}

sub _fixForDST {
    my $class = shift;
    my $unixTime = shift;
    my $refHour = shift || $switchHour;

    my $hour = (localtime($unixTime))[2];

    #
    # if hour is the same, we have a normal 24 hour window
    #
    return($unixTime) if($hour == $refHour);
    
    #
    # if hour is 23 [meaning refHour is 0] or hour is less than refHour, we
    # have a spring forward DST to adjust for.  This means a 23 hour day, so
    # we add an hour back to our offset.
    #
    if($hour == 23 || $hour < $refHour) {
        return($unixTime + 3600);
    }

    #
    # otherwise we have a fall back DST to adjust for.  This would be
    # if($hour == 0 || $hour > $refHour), but checking it is redundant
    # this case is a 25 hour day, so we subtract an hour back out.
    #
    return($unixTime - 3600);
}

sub new {
    my $class = shift;
    my $month = shift; 
    my $year = shift;
    my $scheduleDir = shift;

    # allow month to be 1-12 or  month format

    my ($sec,$min,$hour,$mday,$currentMonth,$currentYear,$wday,$yday,$isdst) = localtime(time);
    $currentYear+=1900;

    my $myYear = $year || $currentYear;

    my $myMonthName;
    if (defined $month) {
        $myMonthName = $months[$month - 1] || $month;
    } else {
        $myMonthName = $months[$currentMonth];
    }

    my $cacheKey = $myYear . "/" . $myMonthName;

    if ( $scheduleCache{$cacheKey} ) {
    
        return $scheduleCache{$cacheKey};

    } else {

        my $self = {
            'fileName'       => undef,
            'sched'          => [],
            'monthName'      => $myMonthName,
            'year'           => $myYear,
            'switchTime'     => $switchHour . "00",
        };
        bless($self, $class);

        $scheduleDir = ariba::Ops::Constants->oncallscheduledir() unless($scheduleDir);

        return undef unless (-d $scheduleDir); 
        $self->{'fileName'} = $scheduleDir . '/'.$self->{'year'}.'/'.$self->{'monthName'};

        open(SCHED,$self->fileName()) || do {
                warn "can't open ".$self->fileName()." $!\n";
                return undef;
        };

        my @sched = ();
        my $lastDay = 0;

        while (<SCHED>) {
            next if /^#/o;
            next if /^;/o;
            chomp;
            next if /^\s*$/o;
            next unless /^\d+/o;

            $_ =~ /^(\d+):?([^#]*)(?:#(.+))?$/;
            my ($day, $peopleString, $comment) = ($1, $2, $3);

              my @people =
                grep { $_ =~ s/^\s*(\S+)\s*$/$1/gm } split( ",", $peopleString);

            # Figure out who person[1|2|3|4|5|6] are and assign to appropriate roles.
            # This is a hacky way to add sysadmins|dbas|netadmin to the schedule and maintain
            # backwards compatibility with existing schedules.
            my ($primaryDeveloper,$backupDeveloper,$sysadmin,$dba,$netadmin,$tools,$deployment,
                $shift1,$shift2,$shift3,$backup,$backup2,$backup3);

            # Sysadmins listed in the schedule file will look like 's=dhicks'
            # DBA's listed in the schedule file will look like 'd=jchiang'
            # Netadmins listed in the schedule file will look like 'n=ckirkman'
            # Tools: t=jmcminn
            # ProdOps (3 shifts, primary and backup):
            #    Backups:   a=, b=, c=
            #    Primaries: 1=, 2=, 3=
            foreach my $person ( @people ){

                next unless defined ($person);

                if ($person =~ /^s=(.*)$/) {
                    $sysadmin = $1;
                } elsif ($person =~ /^d=(.*)$/) {
                    $dba = $1;
                } elsif ($person =~ /^n=(.*)$/) {
                    $netadmin = $1;
                } elsif ($person =~ /^a=(.*)$/) {
                    ## backup shift1
                    $backup = $1;
                } elsif ($person =~ /^b=(.*)$/) {
                    ## backup shift2
                    $backup2 = $1;
                } elsif ($person =~ /^c=(.*)$/) {
                    ## backup shift3
                    $backup3 = $1;
                } elsif ($person =~ /^1=(.*)$/) {
                    ## primary shift1
                    $shift1 = $1;
                } elsif ($person =~ /^2=(.*)$/) {
                    ## primary shift2
                    $shift2 = $1;
                } elsif ($person =~ /^3=(.*)$/) {
                    ## primary shift3
                    $shift3 = $1;
                } elsif ($person =~ /^t=(.*)$/) {
                    $tools = $1;
                } elsif ($person =~ /^z=(.*)$/)  {
                    $deployment = $1;
                } else {
                    if ( defined($primaryDeveloper) ) {
                        $backupDeveloper = $person;
                    } else {
                        $primaryDeveloper = $person;
                    }
                }
            }

            $sched[$day] = {
                'shift1'           => $shift1,
                'shift2'           => $shift2,
                'shift3'           => $shift3,
                'backup'           => $backup,
                'backup2'          => $backup2,
                'backup3'          => $backup3,
                'sysadmin'         => $sysadmin,
                'dba'              => $dba,
                'netadmin'         => $netadmin,
                'tools'            => $tools,
                'deployment'       => $deployment,
                'primaryDeveloper' => $primaryDeveloper,
                'backupDeveloper'  => $backupDeveloper,
                'comment'          => $comment,
                'day'              => $day,
            };
            $lastDay = $day if $day > $lastDay;
        }
        close(SCHED);

        $self->{'days'}  = $lastDay;
        $self->{'sched'} = [@sched];

        $scheduleCache{$cacheKey} = $self;

        return $self;
    }
}

sub _removeSchedulesFromCache {
    my $class = shift;
    
    %scheduleCache = ();    
    return 1;
}

sub stillYesterday{
	my $specifiedTime = shift;
	$specifiedTime = shift if(ref($specifiedTime));

    my $hour = ( localtime($specifiedTime) )[ 2 ];

    return $hour < $switchHour ? 1 : 0;
}

1;
