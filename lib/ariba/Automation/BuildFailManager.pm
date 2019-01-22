package ariba::Automation::BuildFailManager;

#
# Determine why a build failed using fail.conf as a guide
# 

use strict 'vars';
use warnings;
use vars qw ($AUTOLOAD);
use Carp;
use Data::Dumper;
use LWP::Simple;
use XML::Simple;
use FindBin;
use lib "$FindBin::Bin/../../../shared/bin";
use lib "$FindBin::Bin/../../lib/perl";
use ariba::Automation::Constants;
use ariba::Automation::RobotCategorizer;
use ariba::Automation::BuildInfo;
use ariba::Automation::Releases2;
use ariba::Automation::BuildResult;
use ariba::Automation::BuildFailDB;

{
    my $STATUS_FAILURE = "FAILURE";

    my %REWRITE =
    (
        'asm' => 's4',
        'buyer' => 'ssp',
    );

    #
    # Constructor
    #
    sub new
    {
        my ($class, $hashref) = @_;

        $hashref = {} unless $hashref;

        $hashref->{'conf_file'} = $hashref->{'conf_file'} || "/home/rc/etc/fail.xml";
        $hashref->{'verbose'} = $hashref->{'verbose'} || 0;
        $hashref->{'debug'} = $hashref->{'debug'} || 0;
        $hashref->{'lines'} = $hashref->{'lines'} || 1024;

        my $self = 
        {
            'conf_file' => $hashref->{'conf_file'},
            'verbose' => $hashref->{'verbose'},
            'debug' => $hashref->{'debug'},
            'lines' => $hashref->{'lines'},
            'counter' => 0,
            'tmpfiles' => [],
            'nashome' => "http://nashome/",
        };
        bless ($self,$class);

		eval
		{
			$self->parse_fail_conf ($self->{'conf_file'});
		};

		if ($@)
		{
			carp "Warning: " . ref ($self) . " failed to parse " . $self->{'conf_file'} . ", $@\n";
		}

        return $self;
    }

    sub parse_fail_conf
    {
        my ($self, $file) = @_;

        print "" . localtime (time()) . " Parsing $file\n" if $self->{'verbose'};
        my $xs = new XML::Simple();
        my $tree = $xs->XMLin ($file);
		my $types = $tree->{'failure'};
		my $complete = 0;
        my %tmp;

		foreach my $type (@$types)
		{
			my $data = $self->_parse_type ($type);
			push @{$tmp{$$data[4]}}, $data;
		}

		my @failures;
		foreach my $score (sort { $a <=> $b } keys %tmp)
		{
			foreach my $fail (@{$tmp{$score}})
			{
				push @failures, $fail;
			}
		}

        print "" . localtime (time()) . " Loaded " . ($#failures+1) . " failures\n" if $self->{'verbose'};
        $self->{'failures'} = \@failures;
    }

	sub _parse_type
	{
		my ($self, $type) = @_;
		return 
		[ 
			$type->{'fragment'}, 
			$type->{'brief'}, 
			$type->{'verbose'}, 
			$type->{'responsible'}, 
			$type->{'order'}, 
		];
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
    }

    sub add_tempfile
    {
        my ($self, $file) = @_;

        if ( ! $self->{'tmpfiles'})
        {
            $self->{'tmpfiles'} = [ $file ];
        }
        else
        {
            push @{$self->{'tmpfiles'}}, $file;
        }
    }

    sub cleanup
    {
        my ($self) = @_;

        return unless $self->{'tmpfiles'};

        while (my $tmpfile = shift @{$self->{'tmpfiles'}})
        {
            if (-e $tmpfile)
            {
                unlink $tmpfile;
            }
        }
    }

    #
    # Public method: Iterates over all mainline robots and examines
    # the 4 most recent build histories for failures
    #
    sub examine_builds
    {
        my ($self, $db) = @_;

        print "" . localtime (time()) . " Reading robots...\n" if $self->{'verbose'};
        my $rc = new ariba::Automation::RobotCategorizer();
        my $releases = new ariba::Automation::Releases2 (ariba::Automation::Constants::releasesConfigFile2());
		my $robots = $releases->get_all_robots();
        my @broken;

		my $robot_count = keys %$robots;
        print "" . localtime (time()) . " Examining $robot_count robots...\n" if $self->{'verbose'};

		foreach my $host (keys %$robots)
		{
			my $listref = $robots->{$host};
			my ($release, $product, $purpose, $role, $order) = @$listref;
			my $robot = $rc->fetchRobotByHost ($host);
			$robot = $robot || "";
			next unless $robot;
			my $productname = $self->_rewrite_productname ($product);
            my $results = $self->_examine_robot ($db, $robot, $release, $productname);
            if ($#$results != -1)
            {
                push @broken, @$results;
            }
		}

		return \@broken;
	}

    #
    # Examine robot history
    #
    sub _examine_robot
    {
        my ($self, $db, $robot, $release, $productname) = @_;

        my $host = $robot->hostname();
        my $instance = $robot->instance();
        print "" . localtime (time()) . " $instance release=$release product=$productname\n" if $self->{'verbose'};

        my @buildInfos = $robot->buildInfo();
        my @results;

        return \@results unless $#buildInfos >= 0;

        foreach my $rawBuildInfo (reverse @buildInfos)
        {
            # make BuildInfo object from raw data
            my $buildInfo = new ariba::Automation::BuildInfo();
            $buildInfo->unpack ($rawBuildInfo);

            my $status = $buildInfo->get_qualStatus();
            my $key = join "/", $buildInfo->get_logDir(), $buildInfo->get_logFile();

            if (! $db->exists ($key))
            {
                my $result = $self->_determine_build_result ($robot, $status, $buildInfo, $release, $productname);
                push @results, $result if $result;
            }
        }

        return \@results;
    }

    sub unique_filename
    {
        my ($self, $prefix) = @_;
        $self->{'counter'} ++;
        return join ".", $prefix, $$, $self->{'counter'};
    }

    #
    # Determine why a build failed using BuildFail class family
    #
    sub _determine_build_result
    {
        my ($self, $robot, $status, $buildInfo, $release, $productname) = @_;
        my $instance = $robot->instance();
        my $dir = $buildInfo->get_logDir();
        my $file = $buildInfo->get_logFile();
        my $qualId = $buildInfo->get_qualTestId();
        my $where = $qualId ? "build" : "qual";
        my $product = $buildInfo->get_productName();
        my $logfile = "/home/$instance/public_doc/logs/$dir/$file";
        my $runtests = join "/",
            "/home/$instance/public_doc",
            "testReports-" . $product,
            $qualId,
            "runtests.output.all.xml";

        if ($self->{'verbose'})
        {
            print "" . localtime (time()) . " $logfile\n  status: $status\n";
        }

        if ($status ne $STATUS_FAILURE)
        {
            return new ariba::Automation::BuildResult
            (
                {
                    'product' => $productname,
                    'release' => $release,
                    'robot' => $instance,
                    'status' => $status,
                    'hostname' => $robot->hostname(),
                    'where' => "",
                    'fail_type' => "",
                    'pretty_print' => "",
                    'responsible' => "",
                    'runtests' => $qualId ? $runtests : "",
                    'logfile' => $logfile,
                    'buildTime' => $buildInfo->get_buildTime(),
                    'dir' => $dir,
                    'file' => $file,
                }
            );
        }

        my $tmpfile = "/tmp/" . $self->unique_filename ($instance . $dir . $file);
        my $url = $self->{'nashome'} . "~$instance/logs/$dir/$file";

        $self->add_tempfile ($tmpfile);

        getstore ($url, $tmpfile);

        if (! -e $tmpfile)
        {
            carp "Failed to download $url to $tmpfile, $!\n";
            return;
        }

        my ($fail_type, $pretty_print, $responsible) = $self->_examine_build_log ($tmpfile);

        unlink $tmpfile || carp "Warning: Couldn't unlink $tmpfile, $!\n";

        if (! $fail_type)
        {
            $fail_type = "unknown error";
            $pretty_print = "n/a";
            $responsible = "n/a";
        }
        print "" . localtime (time()) . " Failure: $fail_type ($pretty_print)\n" if $self->{'verbose'};

        my $result = new ariba::Automation::BuildResult
        (
            {
                'product' => $productname,
                'release' => $release,
                'robot' => $instance,
                'status' => $status,
                'hostname' => $robot->hostname(),
                'where' => $where,
                'fail_type' => $fail_type,
                'pretty_print' => $pretty_print,
                'responsible' => $responsible,
                'runtests' => $qualId ? $runtests : "",
                'logfile' => $logfile,
                'buildTime' => $buildInfo->get_buildTime(),
                'dir' => $dir,
                'file' => $file,
            }
        );

    return $result;
    }


    # 
    # Examine build log for failures
    #
    sub _examine_build_log
    {
        my ($self, $logfile) = @_;
        my ($found, $fail_type, $pretty_print, $responsible, $order) = (0, "", "", "", "");
		my (%caught);

        open LOGFILE, "tail -" . $self->{'lines'} . " $logfile |";

        while (<LOGFILE>)
        {
            chomp;
            ($fail_type, $pretty_print, $responsible, $order) = $self->_examine_line ($_);

			if ($fail_type)
			{
				push @{$caught{$order}}, [ $fail_type, $pretty_print, $responsible, $order ];
				$found = 1;
			}
        }

        close LOGFILE;

		if ($found)
		{
			foreach my $c (sort { $a <=> $b } keys %caught)
			{
				my $faildata = shift @{$caught{$c}};
				($fail_type, $pretty_print, $responsible, $order) = @$faildata;
				return ($fail_type, $pretty_print, $responsible);
			}
		}

		return ($fail_type, $pretty_print, $responsible);
    }

    #
    # Examine a single line in logfile
    #
    sub _examine_line
    {
        my ($self, $line) = @_;

        foreach my $failure (@{$self->{'failures'}})
        {
            my ($failure, $reason, $pretty_print, $responsible, $order) = @{$failure};
            
            if ($line =~ m#$failure#)
            {    
                return ($reason, $pretty_print, $responsible, $order);
            }
        }

        return (0);
    }

    #
    # pretty-print product name to hide deprecated names
    #
    sub _rewrite_productname
    {
        my ($self, $productname) = @_;

        foreach my $key (keys %REWRITE)
        {
            my $val = $REWRITE{$key};
            $productname =~ s/$key/$val/gm;
        }

    return $productname;
    }
}

1;
