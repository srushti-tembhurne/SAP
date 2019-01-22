# RobotTimingGraph:
# iterates over robot log directories to generate timing graphs. 
# fails silently if logfiles aren't available.
# finished result is uploaded to mars via HTTP POST. 
# subtracts time waiting for new checkins or scheduled builds.
#
# usage:
#
# import ariba::Automation::RobotTimingGraph;
# ariba::Automation::RobotTimingGraph::makeTimingOverview();
# 
# TODO: 
# - add a force-flag which resets cdb/cache files.
# - complain via carp when something goes wrong

package ariba::Automation::RobotTimingGraph;

use strict;
use Date::Parse;
use Data::Dumper;
use LWP::UserAgent;
use HTTP::Request::Common;
use ariba::monitor::CircularDB;
use ariba::monitor::CircularDBGraph;
use ariba::monitor::AggregateCDB;
use ariba::Automation::Utils;

{
my $MINIMUM_RUNTIME = 180; # specified in minutes

# public method, start here to generate graphs on a per-robot basis.
# first argument is optional: name of the robot ("robot20")
# returns undef if something failed and no data is available.

sub makeTimingOverview
  {
  my ($robotName) = @_;
  $robotName = $robotName || $ENV{'USER'};

  my $logDir = "/home/$robotName/public_doc/logs";
  return unless -e $logDir;

  # skip logfile dirs we've already seen
  my $cacheDir = "/home/$robotName/etc";
  system ("mkdir", "-p", $cacheDir) unless -d $cacheDir;

  # text file, one directory name per line, contains a list of 
  # logfiles we've already processed. this allows the cdb file
  # to hold cumulative data without worrying about expired 
  # logfiles. 
  my $cacheFile = join "/", $cacheDir, "timing.cache";
  my $cached = read_cache ($cacheFile);

  # fetch list of available log directories
  my $logDirs = getTimingDirs ($logDir);
  
  # bail early if no logs available or there's nothing new to log
  return if $#$logDirs == -1;

  my ($path, $timingInfo, @times);

  foreach my $dirName (@$logDirs)
    {
    my $path = join "/", $logDir, $dirName;
    $timingInfo = getTimingInfo ($path);
    foreach my $info (@$timingInfo)
      {
      push @times, $info;
      }
    }
  
  my $result = makeGraph ($robotName, \@times, $cached);
  write_cache ($cacheFile, $cached);
  return $result;
  }

sub read_cache
  {
  my ($cache) = @_;

  # read cache from disk, store in hash for easy lookup
  my %cache;
  if (open CACHE, $cache)
    {
    while (<CACHE>)
      {
      chomp;
      $cache{$_}=1;
      }
    close CACHE;
    }

  return \%cache;
  }

sub write_cache
  {
  my ($cache, $cached) = @_;

  # write cache back to disk with new entries
  if (open CACHE, ">$cache")
    {
    foreach (keys %$cached)
      {
      print CACHE "$_\n";
      }
    close CACHE;
    }
  }

# generate image given an arrayref of hashrefs:
#
# $VAR1 = {
#           'date' => 1259509733,
#           'elapsed' => 34,
#           'logfile' => '/home/robot20/public_doc/logs/20091125-151232/timing_38.log'
#         };
# 
# required: date (time since epoch), elapsed (runtime in seconds)
# nice for debugging but optional: logfile

sub makeGraph
  {
  my ($robotName, $times, $cached) = @_;

  # make directory for datafile 
  my $datadir = "/home/$robotName/etc";
  system ("mkdir", "-p", $datadir) unless -d $datadir;

  my $datafile = join "/", $datadir, "runtimes.cdb";

  # make directory for image 
  my $imageDir = "/home/$robotName/public_doc/reports";
  system ("mkdir", "-p", $imageDir) unless -d $imageDir;
  
  # path to image containing graph
  my $image = join "/", $imageDir, "runtimes.png";
  
  my $html = join "/", $imageDir, "runtimes.html";
  my $ok_html = 0;

  if (open HTML, ">$html")
    {
    $ok_html = 1;
    print HTML <<FIN;
<html>
<head>
<style><!--
.pretty { font-family: Verdana, sans-serif; }
//--></style>
<title>$robotName</title>
</head>
<body bgcolor="#ffffff" class="pretty">
<center>
<h1>$robotName</h1>
FIN
    }

  my $cdb = ariba::monitor::CircularDB->new
    (
    $datafile,
    "Runtime",
    500,
    "gauge",
    "Minutes",
    $robotName,
    );

  my ($time, $mins);
  my $sum = 0;
  my $failed = 0;

  foreach $time (@$times)
    {
    $mins = $time->{'elapsed'} ? int ($time->{'elapsed'} / 60) : 0;
    $sum += $mins;
    }

  if (! $sum || $#$times == -1)
    {
    print HTML <<FIN;
<p>No data.</p>
FIN
    close HTML;
    return "http://nashome/~$robotName/reports/runtimes.html";
    }

  my $runCounts = $#$times + 1;
  my $avg = int ($sum / $runCounts);

  if ($ok_html)
    {
    my $when = localtime (time());
    print HTML <<FIN;
<img src="runtimes.png"><br clear=left>
<br>
<table border=1 cellpadding=4 cellspacing=4>
<tr>
<td align=center valign=middle colspan=2>
<table border=0 cellpadding=3 cellspacing=3>
<tr>
<td align=right><b>Built:</b></td>
<td align=left>$when</td>
</tr> <tr>
<td align=right><b>Average Runtime:</b></td>
<td align=left>$avg mins</td>
</tr> <tr>
<td align=right><b>Runs:</b></td>
<td align=left>$runCounts</td>
</tr> </table> </td> </tr> <tr>
<td align=center valign=middle><b>Date</b></td>
<td align=center valign=middle><b>Runtime</b></td>
</tr>
FIN
    }

  foreach $time (reverse @$times)
    {
    $mins = $time->{'elapsed'} ? int ($time->{'elapsed'} / 60) : 0;

	# skip times below minimum runtime 
	next if $mins < $MINIMUM_RUNTIME;

    if ($ok_html)
      {
      my $color = "#FFFFFF";
	  if ($mins < 30) 
		{
		$color = "#d9d9d9";
		}
	  elsif ($mins > 500)
		{
		$color = "#FFFF00";
		}
      my $pretty = localtime ($$time{'date'});
      print HTML <<FIN;
<tr>
<td align=left valign=middle>$pretty</td>
<td bgcolor="$color" align=left valign=middle>$mins</td>
</tr>
FIN
      }
    }

  foreach $time (@$times)
    {
    $mins = $time->{'elapsed'} ? int ($time->{'elapsed'} / 60) : 0;

	# skip times below minimum runtime 
	next if $mins < $MINIMUM_RUNTIME;

    if (! exists $cached->{$time->{'date'}})
      {
      $cdb->writeRecord ($time->{'date'}, $mins);
      }
    $cached->{$time->{'date'}} = 1;
    }

  if ($ok_html)
    {
    print HTML <<FIN;
</table>
FIN
    close HTML;
    }

  my $now = time();
  my $startTime = $now - (60*60*24*365); # go back 1 year
  my $endTime = $now;

  my $cdbgraph = ariba::monitor::CircularDBGraph->new
    (
    $image,
    $startTime,
    $endTime,
    $cdb
    );

  $cdbgraph->setGraphSize("medium");
  $cdbgraph->graph();

  # attempt to upload image to mars
  if (-e $image)
    {
    my $ua = LWP::UserAgent->new;

    my $req = POST 'http://rc.ariba.com:8080/cgi-bin/robot-server',
      Content_Type  => 'form-data',
      Content =>
        [
        action => 'robotTimingReport',
        upload => [ $image ],
        robotName => $robotName,
        ];

    $ua->request($req);
    }

  return "http://nashome/~$robotName/reports/runtimes.html";
  }

# given a log directory, iterate over dirs and find all 
# timing_n.log files where n increments forward. each log
# is named for the date and represents a robot being started.

sub getTimingInfo
  {
  my ($dir) = @_;
  my (@timingFiles, @timingInfo);

  # read timing_n.log files from logdir
  return unless opendir DIR, $dir;
  my @files = readdir (DIR);
  closedir (DIR);

  # temporary hash to keep track of logfiles we've seen
  my %corpus;

  foreach my $file (@files)
    {
    if ($file =~ m#^timing_\d+\.log$#)
      {
      $corpus{$file} = 1;
      }
    }
  
  # force logfiles to appear in @timingFiles in numeric order.
  # simply calling sort on the list won't do.

  my $done = 0;
  my $kount = 0;
  while (! $done)
    {
    my $logfile = "timing_" . $kount . ".log";
    if (exists $corpus{$logfile})
      {
      push @timingFiles, $logfile;
      ++$kount;
      }
    else
      {
      $done = 1;
      }
    }

  # fail silently if no logfiles found
  return if $#timingFiles == -1;

  my ($file, $info, $path);

  # iterate over logfiles, parse them. 
  # return listref of hashrefs containing logfile info to caller.
  foreach $file (@timingFiles)
    {
    $path = join "/", $dir, $file;
    $info = parseTimingFile ($path);
    if ($info)
      {
      push @timingInfo, $info;
      }
    }
  return \@timingInfo;
  }

# read timing logfile and:
# - transform dates into time since epoch
# - transform runtimes from prettyprinted output to seconds
# - detect partially written logfiles, skip them

sub parseTimingFile
  {
  my ($file) = @_;

  return unless open FILE, $file;

  my $elapsed; # time to run in seconds
  my $rundate; # date run completed in time-since-epoch form i.e. 1259113422
  my $endtime; # date run completed i.e. 2009-11-24 17:43:42
  my @chunks;  # temporary variable for parsing report columns
  my $waited;  # time in seconds that we waited for a new build

  # typical format:
  # start-target | 2009-11-24 16:29:02 | 2009-11-24 17:43:42 | 1 hrs 14 mins 40 secs 

  while (<FILE>)
    {
    chomp; 
    s/^\s+//; # strip leading whitespace

    # get total runtime
    if ($_ =~ m#^Total \| (.*)$#)
      {
      $elapsed = ariba::Automation::Utils::parseRuntime ($1);
      }
    elsif ($_ =~ m#wait-for-new-checkin#)
	  {
      @chunks = split / \| /, $_;
	  if ($chunks[$#chunks])
	    {
        $waited = ariba::Automation::Utils::parseRuntime ($chunks[$#chunks]);
		}
	  }
    # use start time
    elsif (! $rundate)
      {
      @chunks = split / \| /, $_;
      $endtime = $chunks[2];

      # 2009-11-24 17:43:42
      if ($endtime =~ m#^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})$#)
        {
        $rundate = str2time ($1);
        }
      }
    }

  close FILE;

  # fail silently if we encounter a partially-written logfile
  if (! $elapsed || ! $rundate)
    {
    return;
    }
 
  # subtract time spent hanging around for a new build
  $waited = $waited || 0;
  $elapsed -= $waited;

  return { 'logfile' => $file, 'elapsed' => $elapsed, 'date' => $rundate };
  }

# given a directory, return a sorted list of directories inside that 
# contain timing logfiles. 

sub getTimingDirs
  {
  my ($dir) = @_;

  # count of files processed during this run
  my $processed = 0;

  # list of log directories
  my @logDirs;

  # fail silently if we can't read directory
  if (opendir DIR, $dir)
    {
    my @files = readdir (DIR);
    closedir (DIR);

    # directory names can be sorted since they are padded with 0's
    foreach my $file (sort @files)
      {
      # extract directories formatted like so: 20091207-103849
      if ($file =~ m#^\d{4}\d{2}\d{2}-(\d+)$#)
        {
        ++$processed;
        push @logDirs, $file;
        }
      }
    }

  @logDirs = sort @logDirs; 
  return \@logDirs;
  }
}

1;
