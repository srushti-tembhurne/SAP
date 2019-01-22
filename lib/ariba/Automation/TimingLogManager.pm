package ariba::Automation::TimingLogManager;

#
# Class to load timing data from robot logs dir:  
#
# - Specify logs to load by robot instance name
# - Skip incomplete timing logs
# - Subtract time waiting for new checkins
# - Convert elapsed time into seconds
# - Pretty-print data in Excel-friendly form
# - Optional: Load only the first N logfiles encountered
#

use strict 'vars';
use warnings;
use vars qw ($AUTOLOAD);
use Carp;
use Data::Dumper;
use Sort::Versions;
use ariba::Automation::Utils;

{
    my $DRAW = 300; # in seconds
    my $WIDTH = "12%";
    my $COLS = 3;

    #
    # Constructor
    #
    sub new
    {
        my ($class, $robotName, $limit) = @_;

        $robotName = $robotName || "";
        $limit = $limit || 0;

        my $self = 
        {
            'robotName' => $robotName,
            'limit' => $limit, 
            'max_time' => 60 * 60 * 9,
            'load_failed_runs' => 0, 
        };

        bless ($self,$class);

        return $self;
    }

    #
    # Accessors
    #
    sub AUTOLOAD
    {
        no strict "refs";
        my ($self, $newval) = @_;

        my @classes = split /::/, $AUTOLOAD;
        my $accessor = $classes[$#classes];

        if (exists $self->{$accessor})
        {
            if (defined ($newval))
            {
                $self->{$accessor} = $newval;
            }
            return $self->{$accessor};
        }
        carp "Unknown method: $accessor\n";
    }

    #
    # Destructor
    #
    sub DESTROY
    {
        my ($self) = @_;
        delete $self->{'dbh'};
        $self->{'_initialized'} = 0;
    }

    #
    # Generate HTML report showing timing for individual actions
    # across robot runs. 
    #
    sub print_action_report
    {
        my ($self, $report, $actions0, $actions1, $urls0, $urls1, $data0, $data1) = @_;

        if (! open REPORT, ">$report")
        {
            croak "Can't write to $report, $!\n";
        }

        my $url0 = shift @$urls0;
        my $url1 = shift @$urls1;
        my $robota = $$actions0[0][0];
        my $robotb = $$actions1[0][0];
        my (@average0, @average1);
        my $foo = shift @$data0;
        my $datex = $$foo[1];
        my $bar = shift @$data1;
        my $datey = $$bar[1];

    print REPORT <<FIN;
<html>
<head>
<title>Compare $robota to $robotb</title>
<style type="text/css">
body { font-family: sans-serif; }
.winner { background-color: #89A54E; color: #fff; }
.loser { background-color: #aa4643; color: #fff; }
.draw { background-color: #fff; color: #a0a0a0; }
</style>
</head>
<body vLink=#000000 aLink=#000000 link=#000000>
<table id="robots" border=0 width="100%">
<tr>
<td colspan=$COLS><a href="$url0">$datex</a></td><td colspan=$COLS><a href="$url1">$datey</a></td>
</tr>
FIN

        my ($k, $total0, $total1) = (0, 0, 0);
    
        foreach my $i (0 .. $#$actions0)
        {
            my ($robot0, $action0, $runtime0) = @{$$actions0[$i]};
            my ($robot1, $action1, $runtime1) = @{$$actions1[$i]};
            
            my ($color0, $color1) = ("loser", "loser");

            if ($runtime0 > $runtime1)
            {
                $color1 = 'winner';
    
                if ($runtime0 - $runtime1 < $DRAW)
                {
                    $color0 = $color1 = "draw";
                }
            }
            elsif ($runtime0 == $runtime1)
            {
                $color0 = $color1 = "draw";
            }
            else
            {
                $color0 = 'winner';
                if ($runtime1 - $runtime0 < $DRAW)
                {
                    $color0 = $color1 = "draw";
                }
            }

            if ($runtime0 < $DRAW && $runtime1 < $DRAW)
            {
                $color0 = $color1 = "draw";
            }

            # TODO: add stripes later
            if ($k)
            {
                print REPORT "<tr>";
            }
            else
            {
                print REPORT "<tr>";
            }
            $k = ! $k;

            my $e0 = ariba::Automation::Utils::elapsedTime ($runtime0);
            $e0 = "0s" if $e0 eq "n/a";
            my $e1 = ariba::Automation::Utils::elapsedTime ($runtime1);
            $e1 = "0s" if $e1 eq "n/a";

            print REPORT <<FIN;
<td width="$WIDTH" align=center valign=middle class="$color0">$robot0</td>
<td nowrap width="$WIDTH" align=center valign=middle>$action0</td>
<td width="$WIDTH" align=center valign=middle>$e0</td>
<td width="$WIDTH" align=center valign=middle class="$color1">$robot1</td>
<td nowrap width="$WIDTH" align=center valign=middle>$action1</td>
<td width="$WIDTH" align=center valign=middle>$e1</td>
</tr>
FIN

            $total0 += $runtime0;
            $total1 += $runtime1;

            if ($action0 eq "wait-for-target-BQ")
            {
                my ($elapsed0, $elapsed1) = 
                (
                    ariba::Automation::Utils::elapsedTime ($total0), 
                    ariba::Automation::Utils::elapsedTime ($total1), 
                );
                $url0 = shift @$urls0 || "";
                $url1 = shift @$urls1 || "";

                my $diff0 = ariba::Automation::Utils::elapsedTime ($total1 - $total0);
                my $diff1 = ariba::Automation::Utils::elapsedTime ($total0 - $total1);

                if ($total0 > $total1)
                {
                    $diff0 = "n/a";
                    $diff1 = "<b><font color='#ff0000'>$diff1</font></b>";
                }
                else
                {
                    $diff1 = "n/a";
                    $diff0 = "<b><font color='#ff0000'>$diff0</font></b>";
                }
                print REPORT <<FIN;
<tr>
<td width="$WIDTH" align=center valign=middle>$robot0</td>
<td width="$WIDTH" align=center valign=middle>Total</td>
<td width="$WIDTH" align=center valign=middle>$elapsed0</td>
<td width="$WIDTH" align=center valign=middle>$robot1</td>
<td width="$WIDTH" align=center valign=middle>Total</td>
<td width="$WIDTH" align=center valign=middle>$elapsed1</td>
</tr>
<tr>
<td width="$WIDTH" align=center valign=middle>&nbsp;</td>
<td width="$WIDTH" align=center valign=middle>Diff</td>
<td width="$WIDTH" align=center valign=middle>$diff0</td>
<td width="$WIDTH" align=center valign=middle>&nbsp;</td>
<td width="$WIDTH" align=center valign=middle>Diff</td>
<td width="$WIDTH" align=center valign=middle>$diff1</td>
</tr>
</table>
<br>
<hr>
<br>
FIN
                if ($url0 && $url1)
                {
                    my $foo = shift @$data0;
                    my $date0 = $$foo[1];
                    my $bar = shift @$data1;
                    my $date1 = $$bar[1];

                    print REPORT <<FIN;
<table id="robots" border=0 width="100%">
<tr>
<td colspan=$COLS><a href="$url0">$date0</a></td><td colspan=$COLS><a href="$url1">$date1</a></td>
</tr>
FIN
                }

                push @average0, ($total1 - $total0);
                push @average1, ($total0 - $total1);
                ($k, $total0, $total1) = (0, 0, 0);
            }
        }

        print REPORT <<FIN;
</table>
<br>
FIN
    
        print REPORT print_average ($robota, \@average0);
        print REPORT print_average ($robotb, \@average1);
        
        close REPORT;
    }

    sub print_average
    {
        my ($robot, $raw) = @_;

        my @cooked;
        my $total = 0;

        foreach my $i (0 .. $#$raw)
        {
            if ($$raw[$i] >= 0)
            {
                push @cooked, $$raw[$i];
                $total += $$raw[$i];
            }
        }

        if ($total)
        {
            return "Average runtime for $robot: " . ariba::Automation::Utils::elapsedTime ($total / ($#cooked+1)) . " across " . ($#cooked+1) . " run(s)<br>\n";
        }
        return "";
    }

    #
    # Returns an arrayref of arrayrefs representing robot timing log data.
    #
    sub read_logs
    {
        my ($self) = @_;
        
        if ($self->{'robotName'})
        {
            return $self->get_timing_files ();
        }

        carp "Class requires robotName property to be set\n";
        return 0;
    }

    #
    # Pretty-print log data
    # 
    sub print_logs
    {
        my ($self, $data) = @_;
        $data = $data || "";
        if (! $data)
        {
            carp "print_logs method wants data structure generated from read_logs method\n";
            return 0;
        }
        my $kount = $#$data + 1;
        my ($total, $min, $max) = (0, 0, 0);
        my (@rows, @final, @individual_actions, @urls);

        foreach my $i (0 .. $#$data)
        {
            my ($logfile, $runtime, $date, $actions, $actions_order) = @{$$data[$i]};

            # determine fastest runtime
            if (! $min)
            {
                $min = $runtime;
            }
            elsif ($min && $runtime < $min)
            {
                $min = $runtime;
            }
    
            # determine slowest runtime
            if (! $max)
            {
                $max = $runtime;
            }
            elsif ($max && $runtime > $max)
            {
                $max = $runtime;
            }

            $total += $runtime;

            # generate URL to timing log file from path:
            # /home/robot6/public_doc/logs/20100414-132303/timing_23.log
            my $url = $logfile;

            # break path into chunks
            my @chunks = split /\//, $url;

            # remove junk
            shift @chunks;

            # remove /home
            shift @chunks;

            # get robot name
            my $robot = shift @chunks;

            # remove public_doc
            shift @chunks;

            # generate URL
            $url = "http://nashome/~$robot/" . (join "/", @chunks);

            # generate list of lists  
            push @final, [ $robot, $date, $runtime, ariba::Automation::Utils::elapsedTime ($runtime) ];

            foreach my $action (@$actions_order)
            {
                push @individual_actions, [ $robot, $action, $actions->{$action} ];
            }

            push @urls, $url;
        }

        my $secs = int ($total / $kount);
        my $elapsed = ariba::Automation::Utils::elapsedTime ($secs);

        my $robot = $self->{'robotName'};
        push @final, [ "$robot average time", $elapsed, "", "" ];
        push @final, [ "$robot fastest runtime" , ariba::Automation::Utils::elapsedTime ($min), "", "" ];
        push @final, [ "$robot slowest runtime" , ariba::Automation::Utils::elapsedTime ($max), "", "" ];

        return (\@final, \@individual_actions, \@urls, $secs);
    }

    #
    # Get information from timing_x.log file
    #
    sub load_timing_file 
    {
        my ($self, $file) = @_;

        my (@chunks, @lines, %actions, @action_order);

        if (! open FILE, $file)
        {
            return 0;
        }

        while (<FILE>)
        {
            chomp;
            push @lines, $_;
        }

        close FILE;

        # ignore incomplete logfiles
        return 0 unless $#lines > 0;

        my $wait = 0;

        # subtract time spent waiting for new checkins
        if ($lines[1] =~ m#wait-for-new-checkin#)
        {
            (@chunks) = split / \| /, $lines[1];
            $wait = ariba::Automation::Utils::parseRuntime ($chunks[$#chunks]);
        }

        # break logging data into parts:
        # wait-for-target-BQ | 2010-04-20 09:23:53 | 2010-04-20 11:29:44 | 2 hrs 5 mins 51 secs 
        @chunks = split / \| /, $lines[$#lines-1];

        # pull elapsed time from end of array ("2 hrs 5 mins 51 secs")
        my $date = $chunks[$#chunks-1];

        # return false if logfile is incomplete
        if ($lines[$#lines] =~ m#Total #)
        {
            # skip header + wait-for-new-checking action + Total line

            foreach my $i (1 .. $#lines - 1)
            {
                my (@data) = split / \| /, $lines[$i];
                
                # strip whitespace
                foreach my $i (0 .. $#data)
                {
                    $data[$i] =~ s/^\s+//;
                    $data[$i] =~ s/\s+$//;
                }
                next if 
                    $data[0] eq "wait-for-new-checkin" || 
                    $data[0] eq "ssws-buildname-from-label";

                # keep list of actions by order
                push @action_order, $data[0];

                # keep hash of action name => runtime in seconds
                $actions{$data[0]} = ariba::Automation::Utils::parseRuntime ($data[3]);
            }

            (@chunks) = split / \| /, $lines[$#lines];
            
            my $total_runtime = ariba::Automation::Utils::parseRuntime ($chunks[$#chunks]) - $wait;

            # disregard build times in excess of max_time value 
            if ($self->{'max_time'} && ($total_runtime > $self->{'max_time'}))
            {
                return 0;
            }

            return 
            (
                1, 
                $total_runtime,
                $date, 
                \%actions, 
                \@action_order
            );
        }

        return 0;
    }

    #
    # Get all timing files in a dir
    #
    sub get_timing_files
    {
        my ($self) = @_;

        # read all directories in logs dir
        my $path = "/home/" . $self->{'robotName'} . "/public_doc/logs";
        my $dirs = $self->read_dir ($path);
        my @timing;

        # iterate over contents of logs dir
        foreach my $dir (reverse sort @$dirs)
        {
            my $logdir = join "/", $path, $dir;
            my $files = $self->read_dir ($logdir);

            # skip empty dirs
            next unless $#$files != -1;

            # get a list of files in ascending order
            my @files = reverse sort { versioncmp($a, $b) } @$files;

            # examine all timing_XXX.log files
            foreach my $file (@files)
            {
                if (substr ($file, 0, 6) eq "timing")
                {
                    my ($ok, $data, $date, $actions, $action_order) = $self->load_timing_file ("$logdir/$file");
                    if ($ok || $self->{'load_failed_runs'})
                    {
                        push @timing, [ "$logdir/$file", $data, $date, $actions, $action_order ];
                        return \@timing if $self->{'limit'} && ($#timing+1) >= $self->{'limit'};
                    }
                }
            }
        }

        return \@timing;
    }

    #
    # Read contents of directory minus files starting with dot
    #
    sub read_dir
    {
        my ($self, $dir) = @_;
        my @files;
        if (opendir DIR, $dir)
        {
            # load all files in dir skipping dot-files
            @files = grep (!/^\./o, readdir (DIR));
            closedir (DIR);
            return \@files;
        }
        return \@files;
    }

    #
    # Load timing logfile + return most recent date from bottom of file
    #
    sub extract_newest_date_from_timing_log
    {
        my ($self, $logfile) = @_;

        my $date = "";

        if (open LOGFILE, $logfile)
        {
            while (<LOGFILE>)
            {
                chomp;
                my @chunks = split / \| /, $_;
                next unless $#chunks == 3;
                $date = $chunks[2];
            }
            close LOGFILE;
        }

        if ($date)
        {
            my $mm = substr ($date, 5, 2);
            $mm = substr ($mm, 1) if substr ($mm, 0, 1) eq '0';
            my $dd = substr ($date, 8, 2);
            $dd = substr ($dd, 1) if substr ($dd, 0, 1) eq '0';
            $date = join "/", $mm, $dd;
        }
    
        return $date;
    }
}

1;
