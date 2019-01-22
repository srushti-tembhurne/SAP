package ariba::rc::events::Schedule;

#
# Static methods related to RSS e-mail schedules
#
# Reference:
# http://www.timeanddate.com/worldclock/
#

use warnings;
use strict;
use Data::Dumper;
use DateTime;
use DateTime::TimeZone;
use Time::Local;

{
    my $DEBUG = 0;
    my $THIS_TIMEZONE = 'PST8PDT';
    my $DEFAULT_TIMEZONE = 'US/Califorina';

    #
    # List of timezones we like
    #
    my %TIMEZONES_PREFERRED =
    (
        'PST8PDT' => 1,
        'Asia/Kolkata' => 1,
    );

    #
    # Timezone Aliases
    #
    my %TIMEZONES_ALIASES =
    (
        'Asia/Kolkata' => 'IST',
        'PST8PDT' => 'US/California', 
    );

    #
    # Reverse mapping
    #
    my %TIMEZONES_REVERSE_ALIASES;
    foreach my $alias (keys %TIMEZONES_ALIASES)
    {
        $TIMEZONES_REVERSE_ALIASES{$TIMEZONES_ALIASES{$alias}} = $alias;
    }

    #
    # Defaults for HTML form
    #
    my %SCHEDULE_DEFAULTS =
    (
        # Default timezone
        'tz' => $DEFAULT_TIMEZONE,

        # Yes/No
        'enabled' => "0",
        
        # start/end times named for day of week
        "1" => { "start_hour" => "9", "start_min" => "0", "end_hour" => "17", "end_min" => "0", },
        "2" => { "start_hour" => "9", "start_min" => "0", "end_hour" => "17", "end_min" => "0", },
        "3" => { "start_hour" => "9", "start_min" => "0", "end_hour" => "17", "end_min" => "0", },
        "4" => { "start_hour" => "9", "start_min" => "0", "end_hour" => "17", "end_min" => "0", },
        "5" => { "start_hour" => "9", "start_min" => "0", "end_hour" => "17", "end_min" => "0", },
    );

    sub get_default_timezone
    {
        return $DEFAULT_TIMEZONE;
    }

    #
    # Default for no scheduled time
    #
    sub get_null_time
    {
        return "--";
    }

    #
    # Default for day-of-week
    #
    sub get_dow_default
    {
        my ($dow, $name) = @_;
        return exists $SCHEDULE_DEFAULTS{$dow . $name} ? $SCHEDULE_DEFAULTS{$dow . $name} : get_null_time();
    }

    #
    # Given a hashref, apply default unless values already exist
    #
    sub apply_defaults
    {
        my ($defaults) = @_;

        foreach my $key (keys %SCHEDULE_DEFAULTS)
        {
            next if exists $defaults->{$key};

            if (ref ($SCHEDULE_DEFAULTS{$key}))
            {
                foreach my $key2 (keys %{$SCHEDULE_DEFAULTS{$key}})
                {
                    $defaults->{$key}->{$key2} = $SCHEDULE_DEFAULTS{$key}->{$key2};
                }
            }
            else
            {
                $defaults->{$key} = $SCHEDULE_DEFAULTS{$key};
            }
        }
        return $defaults;
    }

    #
    # Get list of timezones
    #
    sub get_timezones
    {
        return rewrite_timezones (DateTime::TimeZone->all_names);
    }

    #
    # Move preferred timezones to top of list
    #
    sub rewrite_timezones
    {
        my (@raw) = @_;
        my ($ok, @preferred, @cooked, %dupes);

        foreach my $raw (@raw)
        {
            # 
            # Avoid duplicate entries
            #
            next if exists $dupes{$raw};
            $dupes{$raw} = 1;
            $ok = 0;
            
            foreach my $zone (keys %TIMEZONES_PREFERRED)
            {
                if ($raw =~ m#$zone#)
                {
                    push @preferred, exists $TIMEZONES_ALIASES{$raw} ? $TIMEZONES_ALIASES{$raw} : $raw;
                    $ok = 1;
                    last;
                }
            }
            push @cooked, $raw unless $ok;
        }
    
        unshift @cooked, @preferred;
        return @cooked;
    }

    #
    # Facade: Fetch reverse aliases defined for timezones
    #
    sub get_tzname
    {
        my ($tzname) = @_;
        return exists $TIMEZONES_REVERSE_ALIASES{$tzname} 
            ? $TIMEZONES_REVERSE_ALIASES{$tzname}
            : $tzname;
    }

    #
    # True if current time is outside of specified schedule
    #
    sub can_email_now
    {
        my (@args) = @_;
        my $res = _can_email_now (@args);
        return $res;
    }

    sub _can_email_now
    {
        my ($schedules, $timezone) = @_;
        $timezone = $timezone || "";

        #
        # Fail early if user has no schedule defined
        #
        if (! exists $schedules->{'tz'} && ! $timezone)
        {
            return 1;
        }

        #
        # Get user-specified timezone offset
        #
        my $tzname = $timezone ? get_tzname ($timezone) : get_tzname ($schedules->{'tz'});
        my $tz = DateTime::TimeZone->new (name => $tzname);
        my $dt = DateTime->now();
        my $offset = $tz->offset_for_datetime($dt);

        #
        # Get GMT offset
        #
        my @t = localtime(time());
        my $gmt_offset_in_seconds = timegm(@t) - timelocal(@t);

        #
        # Get current time in user-specified timezone from local time
        #
        my $now = time() - $gmt_offset_in_seconds + $offset;
        my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime ($now);

        #
        # Fail early unless schedule is defined for day of week
        #
        my $schedule = $schedules->{$wday} || "";
        return 0 unless $schedule;

        if ($DEBUG)
        {
            print "Time in $tzname: " . localtime ($now) . "\n";
            printf "Schedule: %02d:%02d to %02d:%02d\n", 
                $$schedule{'start_hour'}, $$schedule{'start_min'},
                $$schedule{'end_hour'}, $$schedule{'end_min'};
            printf "Now: %02d:%02d\n", $hour, $min;
        }

        if ($hour < $schedule->{'start_hour'})
        {
            return 1;
        }
        elsif ($hour == $schedule->{'start_hour'} && $schedule->{'start_min'} > $min)
        {
            return 1;
        }
        elsif ($hour > $schedule->{'end_hour'})
        {
            return 1;
        }
        elsif ($hour == $schedule->{'end_hour'} && $schedule->{'end_min'} < $min)
        {
            return 1;
        }

        return 0;
    }
}

1;
