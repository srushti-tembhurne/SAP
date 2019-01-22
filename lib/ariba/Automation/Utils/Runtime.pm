package ariba::Automation::Utils::Runtime;

use warnings;
use strict;

my %timeIncrements =
  (
  "secs" => 1,
  "mins" => 60,
  "hrs" => 60 * 60,
  "days" => 60 * 60 * 24,
  "seconds" => 1,
  "minutes" => 60,
  "hours" => 60 * 60,
  "days" => 60 * 60 * 24
  );

#
# Convert human-readable elapsed time to seconds.
# input: 1 hours 14 minutes 40 seconds
# output: 940
#
sub parseRuntime
  {
  my ($runtime) = @_;

  # strip commas 
  $runtime =~ s/,/ /gm;

  # convert multiple spaces into single space
  $runtime =~ s/\s+/ /gm;

  # break runtime string into words
  my @chunks = split / /, $runtime;
  my $seconds = 0;

  # iterate over chunks of human-readable times
  while ($#chunks != -1)
    {
    my $value = shift @chunks;
    my $increment = shift @chunks;

    # fail silently if parsing fails
    next unless length ($value) && length ($increment);

    # add up elapsed time
    $seconds += _parseTime ($value, $increment);
    }

  return $seconds;
  }

sub _parseTime
  {
  my ($value, $increment) = @_;
  return exists $timeIncrements{$increment} ? $value * $timeIncrements{$increment} : 0;
  }

# display elapsed time in small footprint: 10d,18h or 8m,59s
sub elapsedTime
  {
  my ($elapsed, $maxChunks) = @_;
  $maxChunks = $maxChunks || 0;

  # bail early to avoid divide by zero
  return "n/a" unless $elapsed;

  # divide seconds into minutes, hours, days
  my $min = int ($elapsed / 60);
  my $sec = $elapsed % 60;
  my $hour = int ($min / 60);
  $min = $min % 60;
  my $day = int ($hour / 24);
  $hour = $hour % 24;

  # pretty-print elapsed time
  my @times;
  push @times, $day . "d" if ($day);
  push @times, $hour . "h" if ($hour);
  push @times, $min . "m" if ($min);
  push @times, $sec . "s" if ($sec);

  # specify maximum number of time chunks
  if ($maxChunks)
    {
    while ($#times > ($maxChunks-1))
      {
      pop @times;
      }
    }

  # remove seconds/minutes if difference has hours/days
  elsif ($#times >= 3)
    {
    pop @times;
    pop @times;
    }

  return join ",", @times;
  }

1;
