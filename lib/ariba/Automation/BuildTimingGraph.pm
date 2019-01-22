# BuildTimingGraph 
#
# Iterates over build logfiles + generates graphs
# Logfiles live here: /home/rc/logs
# Requires: /usr/local/bin/gnuplot

package ariba::Automation::BuildTimingGraph;

use strict;
use warnings;
use Carp;
use Date::Parse;
use Data::Dumper;
use lib "/home/mondev/lib";
use ariba::monitor::CircularDB;
use ariba::monitor::CircularDBGraph;
use ariba::monitor::AggregateCDB;
use ariba::Automation::Utils;

{
my $lines_parsed = 0;
my $verbose = 1;

sub makeGraph
  {
  my ($url, $product, $datadir, $logdir_root, $outdir) = @_;
  
  # product = buyer, s4, ...
  # datadir = /home/robot20/etc
  # logdir = /home/rc/logs
  # outdir = /home/robot20/public_doc/buildtimes

  my $logdir = join "/", $logdir_root, $product;

  if (!opendir DIR, $logdir)
    {
    carp "Can't open directory $logdir, $!\n";
    return -1;
    }

  my @files = readdir (DIR);
  closedir (DIR);

  my @logfiles;

  foreach my $file (@files)
    {
    # build20091113-010801
    if ($file =~ m#^build\d+-\d+$#)
      {
      push @logfiles, $file;
      }
    }
  
  my ($logpath, $info, %runtimes);

  foreach my $logfile (sort @logfiles)
    {
    # parse log, get info about build
    $info = parseBuildLog ($logdir, $logfile);

    # skip broken builds
    next unless $info;
    
    # organize builds using hashref of listrefs:
    # 
    # buildName => [ runtimes ... ]
    push @{$runtimes{$info->{'build'}}}, $info;
    }

  my ($cache, @runtimes, $cacheFile, $image, $html, $filename, @reports);
  my ($cached, $graphed, @images, @pages, $statistics);

  foreach my $build (keys %runtimes)
    {
    @runtimes = @{$runtimes{$build}};
    next if $#runtimes < 1; # skip empty logs

    $filename = join "-", $product, $build;
    $image = join "/", $outdir, "$filename.png";
    $html = join "/", $outdir, "$filename.html";
    push @reports, $filename;
    push @images, "$filename.png";
    push @pages, "$filename.html";
    $cacheFile = join "/", $datadir, "$filename.cache";
    $cache = read_cache ($cacheFile);
    graph ($cache, $build, $datadir, $product, \@runtimes, $image, $html);
    write_cache ($cacheFile, $cache);

    $cached = keys %$cache;
    $graphed = $#runtimes + 1;

    if ($verbose)
      {
      print <<FIN;
Build: $build ($product)
  File: $filename
  Image: $image
  HTML: $html
  Cache: $cacheFile (items: $cached)
  Graphed: $graphed

FIN
      }
    }
  
  make_overview ($url, $product, $outdir, \@reports, \@images, \@pages);
  print "Lines parsed: $lines_parsed\n" if $verbose;
  0;
  }

sub make_overview
  {
  my ($url, $product, $dir, $reports, $images, $pages) = @_;

  my $html = join "/", $dir, "$product.html";
  
  if (! open FILE, ">$html")
    {
    carp "Can't write to $html: $!\n";
    return;
    }

  print FILE <<FIN;
<html>
<head>
<style><!--
.pretty { font-family: Verdana, sans-serif; }
//--></style>
<title>Build Times</title>
</head>
<body bgcolor="#ffffff" class="pretty">
<center>
<h1>Build Times</h1>
FIN
  
  my ($image, $page, $report);

  foreach my $i (0 .. $#$reports)
    {
    $page = $$pages[$i];
    $report= $$reports[$i];
    $image = $$images[$i];

    print FILE <<FIN;
<a href="$url/$page?$$">$report</a><br>
FIN
    }

  close FILE;
  0;
  }

# make graph with gnuplot

sub graph
  {
  my ($cache, $build, $datadir, $product, $times, $image, $html) = @_;

  # make data directory if it doesn't exist
  system ("mkdir", "-p", $datadir) if ! -d $datadir;

  my $datafile = join "/", $datadir, "$product-$build.cdb";

  # fetch filename from path to image
  my @chunks = split /\//, $image;
  my $imageFile = $chunks[$#chunks];
  
  # compute average build time
  my $sum = 0;
  foreach my $time (@$times)
    {
    $sum += $$time{'elapsed'};
    }
  my $avg = int ($sum / ($#$times+1));

  my $cdb = ariba::monitor::CircularDB->new
    (
    $datafile,
    "Time to build",
    500,
    "gauge",
    "Minutes",
    $product . " " . $build,
    );

  my $when = localtime (time());
  my $points = $#$times+1;

  open HTML, ">$html";
  print HTML <<FIN;
<html>
<head>
<style><!--
.pretty { font-family: Verdana, sans-serif; }
//--></style>
<title>$product: $build</title>
</head>
<body bgcolor="#ffffff" class="pretty">
<center>
<h1>$product: $build</h1>
<img src="$imageFile"><br clear=left>
<br>
<table border=1 cellpadding=4 cellspacing=4>
<tr>
<td align=center valign=middle colspan=4>
<table border=0 cellpadding=4 cellspacing=4>
<tr>
<td align=right><b>Report Generated:</b>
<td align=left>$when</td>
</tr>
<tr>
<td align=right><b>Points:</b>
<td align=left>$points</td>
</tr>
<tr>
<td align=right><b>Average Time to Build:</b>
<td align=left>$avg minutes</td>
</tr>
</table>
</td>
</tr>
<tr>
<td align=center><b>Number</b></td>
<td align=center><b>Date</b></td>
<td align=center><b>Elapsed Time</b></td>
<td align=center><b>Minutes</b></td>
</tr>
FIN
  
  foreach my $time (reverse @$times)
    {
    print HTML <<FIN;
<tr>
<td align=center>$$time{'buildnumber'}</td>
<td align=left>$$time{'timestr'}</td>
<td align=left>$$time{'raw'}</td>
<td align=center>$$time{'elapsed'}</td>
</tr>
FIN
    }

  foreach my $time (@$times)
    {
    next if exists $cache->{$time->{'timestr'}};
    $cache->{$time->{'timestr'}} = 1;
    $cdb->writeRecord ($time->{'date'}, $time->{'elapsed'});
    }

  print HTML <<FIN;
</table>
FIN
  
  close HTML;

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

  return -e $image;
  }

sub parseBuildLog
  {
  my ($logdir, $logfile) = @_;

  # extract date info from file name
  my ($year, $mo, $dom, $hh, $mm, $ss) = $logfile =~ 
    m#^build(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})$#;

  # str2time wants: 2009-11-24 17:43:42
  my $timestr = "$year-$mo-$dom $hh:$mm:$ss";

  # time since epoch
  my $rundate = str2time ($timestr);

  # path to logfile
  my $log = join "/", $logdir, $logfile;

  if (! open LOG, $log)
    {
    carp "Can't open logfile $log, $!\n";
    return;
    }

  my $raw = "";
  my $build = "";
  my $buildNumber = "";

  # search through logfile for "Time taken" and extract it
  while (<LOG>)
    {
    ++$lines_parsed;
    chomp;
    
    s/^\s+//; # strip whitespace
    s/\s+$//; # strip whitespace

    # ARIBA_BUILDNAME SSP10s2-36
    if ($_ =~ m#^ARIBA_BUILDNAME (.*)$#)
      {
      # sample input: SSPHawk-726
      ($build, $buildNumber) = split /-/, $1;
      }

    # cron-build 00:34:23: Time taken :  1 hours  8 minutes  18 seconds
    elsif ($_ =~ m#^cron-build \d+:\d+:\d+: Time taken :\s+(.*)$#)
      {
      $raw = $1;
      last;
      }
    }

  # build failed if "Time taken" string not found
  return unless length ($raw);

  my $seconds = ariba::Automation::Utils::parseRuntime ($raw);
  my $minutes = int ($seconds / 60);

  $buildNumber = $buildNumber || "?";

  return 
    {
    'buildnumber' => $buildNumber, 
    'build' => $build, 
    'logfile' => $log, 
    'elapsed' => $minutes,
    'date' => $rundate, 
    'timestr' => $timestr, 
    'raw' => $raw,
    };
  }

sub write_cache
  {
  my ($cacheFile, $cache) = @_;

  # write cache back to disk with new entries
  if (open CACHE, ">$cacheFile")
    {
    foreach (sort keys %$cache)
      {
      print CACHE "$_\n";
      }
    close CACHE;
    }
  }

sub read_cache
  {
  my ($cacheFile) = @_;

  # read cache from disk, store in hash for easy lookup
  my %cache;
  if (open CACHE, $cacheFile)
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

}

1;
