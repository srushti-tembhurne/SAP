package ariba::Automation::RobotScheduler;

# RobotScheduler will parse a series of upcoming scheduled builds and
# return the number of seconds until the most recent upcoming build.
# The caller can determine if the wait time is too long or nap accordingly. 
#
# Callers should use the nap subroutine which takes 2 arguments:
# - Last elapsed runtime (in seconds)
# - Build schedule ("Mon@22:00;Thu@12:30;Fri,Sat,Sun@6:29")

use warnings;
use strict;
use Carp;
use Data::Dumper;
use DateTime;
use DateTime::TimeZone;
use ariba::Automation::Utils;

{
my $VERSION = "1.10";
my $MINIMUM_RUNTIME = 60 * 60 * 10; # as per Ravi
my $DEBUG = 0;
my $TIMEZONE = "US/Pacific";
my $NAPTIME = 11; # time between override check

my @DAYS = qw (Sun Mon Tue Wed Thu Fri Sat);
my %DAYS;
foreach my $i (0 .. $#DAYS)
  {
  $DAYS{$DAYS[$i]} = $i;
  }

my @OFFSETS = generate_offsets();

my $logger = ariba::Ops::Logger->logger();

sub nap
  {
  my ($lastElapsedRuntime, $schedule) = @_;

  # choose reasonable defaults
  $lastElapsedRuntime = $lastElapsedRuntime || 0;
  $schedule = $schedule || "";

  # bail early if robot has no schedule assigned
  return unless $schedule;

  # this needs to be changed when lastElapsedRuntime can be depended
  # upon for correct values. right now lastElapsedRuntime is incorrect
  # because it includes time taken while waiting for new checkins. 
  # -- Harrison & Ravi
  # determine window between now and next build
  # my $window = $lastElapsedRuntime >= $MINIMUM_RUNTIME 
    # ? ($lastElapsedRuntime/2) 
    # : ($MINIMUM_RUNTIME/2);

  my $window = 60 * 60 * 5;
  my $now = time();

  # get upcoming scheduled build
  my $dates = parse_schedule ($schedule, $now);
  my $future = $now + $$dates{'naptime'};
  
  # don't nap if build time is right now
  if ($$dates{'naptime'} == 0)
    {
    return 1;
    }

  # nap if next build is happening sooner than later
  if ($$dates{'naptime'} <= $window) 
    {
    my $naptime = $$dates{'naptime'} - 59;
    if ($naptime > 0)
      {
      my $zzz = ariba::Automation::Utils::elapsedTime ($$dates{'naptime'});
      $logger->info ("RobotScheduler/$VERSION: Napping for $zzz until " . localtime ($future));
      _nap ($$dates{'naptime'} - 59, $future);
      }
    $logger->info ("RobotScheduler/$VERSION: Waking up");
    return 1;
    }
  else
    {
	if (-e ariba::Automation::Constants::buildNowFile())
	  {
      $logger->info ("Ignoring schedule, building now...");
	  return 1;
	  }
	}

  0;
  }

sub _nap
  {
  my ($seconds, $future) = @_;

  my $remaining = $seconds;
  my $flag = ariba::Automation::Constants::buildNowFile();

  while ($remaining > 0)
    {
    if (-e $flag)
      {
      $logger->info ("Ignoring schedule, building now...");
      return;
      }
    $remaining -= $NAPTIME;
    sleep ($NAPTIME);
    }

  return;
  }

# given a date format ("Mon@18:29"), turn it into something machine-parsable
sub parse_date
  {
  my ($date) = @_;

  # remove all whitespace
  $date =~ s/ //g;

  # parse these date formats:
  # Mon@18:29
  # Mon,Wed@16:20
  my ($days, $time) = split /\@/, $date;

  # parse days of week: Mon,Wed,Fri
  my @dow;
  my @days = split /,/, $days; 
  foreach my $day (@days)
    {
    return unless exists $DAYS{$day};
    push @dow, $DAYS{$day};
    }
  my $dow = join ",", @dow;

  # parse times
  my ($h, $m) = split /:/, $time;
  # remove padded zeros
  $h =~ s/^0//;
  $m =~ s/^0//;

  return ($m, $h, $dow);
  }

# The parse_schedule subroutine will parse a cron-like date string 
# used to specify future build times by minute, hour and day of week. 
# The second, optional argument is the time in seconds since epoch. 
# It defaults to the current time. 

sub parse_schedule
  {
  my ($value, $now, $verbose) = @_;
  $verbose = $verbose || 0;
  $now = $now || time();

  # date formats are separated by semicolons
  my @raw = split /;/, $value;

  # temporary variables
  my ($m, $h, $dow, $diff, %cooked, $dt, @dows, @hours, $offset);
  my ($epoch, $dd, $hh, $date);

  # current time
  my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime ($now);

  # iterate over dates wanted
  foreach $date (@raw)
    {
    # strip whitespace
    $date =~ s/^\s+//;
    $date =~ s/\s+$//;

    # break month/hour/day-of-week out 
    ($m, $h, $dow) = parse_date ($date);

    # check for invalid date format
    if (! length ($m) || ! length ($h) || ! length ($dow))
      {
      carp "Can't parse date: \"$date\"\n"; 
      return;
      }

    # break out individual days-of-week, hours
    @dows = split /,/, $dow;

    # this may not be necessary if multiple hours per date aren't supported
    @hours = split /,/, $h;

    # generate date info for each unique date
    foreach $dd (@dows)
      {
      foreach $hh (@hours)
        {
        # check for invalid formats
        if ($dd < 0 || $dd > 6 || $m < 0 || $m > 59 || $hh < 0 || $hh > 23)
          {
          carp "Can't parse invalid date format: \"$date\"\n"; 
          return;
          }

        # create DateTime object using current time augmented with 
        # date from schedule string. we need $TIMEZONE because DateTime
        # returns UTC dates by default. 
        $dt = DateTime->from_epoch (epoch => $now, time_zone => $TIMEZONE);
        $dt->set_hour ($hh);
        $dt->set_minute ($m);
        $offset = $OFFSETS[$wday][$dd]; 

        # determine if date is in the past or future
        if ($offset != 0)
          {
          $dt->add (days => $offset);
          }
        elsif ($hh < $hour)
          {
          $offset = 7;
          $dt->add (days => $offset);
          }
        elsif ($hh == $hour && $m < $min)
          {
          $offset = 7;
          $dt->add (days => $offset);
          }

        # convert DateTime to time since epoch
        $epoch = $dt->strftime ("%s");

        print "  DEBUG: [$hh:$m on $DAYS[$dd]] offset=$offset now=" . 
          localtime($now) . " then=" . localtime ($epoch) . "\n"
          if $DEBUG;
        
        # subtract future date from current date
        $diff = $epoch - $now;

        # add date information to a list of hashrefs
        push @{$cooked{$diff}},
          {
          'naptime' => $diff,
          'pretty' => prettyprint ($dd, $hh, $m),  # for debugging
          };
        }
      }
    }

  if ($verbose)
    {
    return \%cooked;
    }

  # sort dates by time remaining, return first value in the list
  foreach my $wait (sort { $a <=> $b } keys %cooked)
    {
    return $cooked{$wait}[0];
    }
  }
  
# generate day-of-week offsets
sub generate_offsets
  {
  my @offsets;
  my $k = 0;
  foreach my $i (0 .. 6)
    {
    foreach my $j (0 .. 6)
      {
      $k = 0 if $k > 6;
      $k = 6 if $k < 0;
      $offsets[$i][$j] = $k++;
      }
    $k--;
    }
  return @offsets;
  }

sub prettyprint
  {
  my ($day, $hour, $min) = @_;
  return sprintf "%s %02d:%02d", $DAYS[$day], $hour, $min;
  }

sub version
  {
  return $VERSION;
  }

}

1;
