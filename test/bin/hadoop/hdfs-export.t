#!/usr/local/bin/perl 

# $Id: //ariba/services/monitor/bin/hadoop/hdfs-export#7 $

#
# Monitoring for Hadoop:
# * kick off hbase snaphots
# This script is a conversion of previous shell scripts:
#   - //ariba/cloudsvc/hadoop/build/R2/bin/run_ruby.sh
#

use strict;

use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib/perl";
use TestUtils;
use POSIX qw(strftime);
use Time::Local;
use Data::Dumper;
use Test::More tests => 1;

use ariba::monitor::Query;
use ariba::monitor::QueryManager;
use ariba::Ops::Constants;
use ariba::Ops::Startup::Hadoop;
use ariba::rc::InstalledProduct;

my $debug = 0;
my $firstExport = ariba::Ops::Constants::hdfsFirstExport();

sub usage {
    my $error = shift; 

    print <<USAGE;
Usage: $0 [-e|-p|-d|-h]
    -e    Enables sending of email for monitor query.
    -p    Enables sending of pages for monitor query.
    -d    Turns on debug mode. 
    -h    Shows this help.

USAGE

    print "(error) $error\n" if ($error);

    exit();
}

sub main {
    my $sendEmail = 0;
    my $sendPage = 0;

    while (my $arg = shift) {
        if ($arg =~ /^-h$/o) { usage();         next; }
        if ($arg =~ /^-d$/o) { $debug++;        next; }
        if ($arg =~ /^-e$/o) { $sendEmail = 1;  next; }
        if ($arg =~ /^-p$/o) { $sendPage = 1;   next; }

        usage("Invalid argument: $arg");
    }

    my $me = ariba::rc::InstalledProduct->new();
    exit unless (ariba::rc::InstalledProduct->isInstalled('hadoop', 'dev'));
    my $hadoop = ariba::rc::InstalledProduct->new('hadoop', 'dev');
    my $cluster = $hadoop->currentCluster();

    my ($virtualHost) = $hadoop->rolesManager()->virtualHostsForRoleInCluster('hbase-master', $cluster);
    if ($virtualHost) {
        my $activeHost = $hadoop->activeHostForVirtualHostInCluster($virtualHost, $cluster);
        my $host = ariba::Ops::NetworkUtils::hostname();
        debug("Current Host: $host / Active Host: $activeHost / Virtual Host: $virtualHost");
        if ($host ne $activeHost) {
            debug("Exiting as current host is not the active host");
            exit(0);
        }
    }

    ariba::Ops::Startup::Hadoop::setRuntimeEnv($hadoop);
    $ENV{'HADOOP_HOME'} = $ENV{'HADOOP_HOME'} . "/share/hadoop/mapreduce1";
    $ENV{'USER'} = ariba::rc::Globals::deploymentUser($hadoop->name(), $hadoop->service());
    debug("Using HADOOP_HOME=" . $ENV{'HADOOP_HOME'});

    my ($cmd, $lastExport);

    my %queries;

    my @tables = qw(
        buyer.ariba.arches.datastore.AtomicShardUpdates
        buyer.ariba.arches.datastore.AuxiliaryData
        buyer.ariba.arches.datastore.DocInfo
        buyer.ariba.arches.datastore.IndexAdapterInfo
        buyer.ariba.arches.datastore.IndexerJob
        buyer.ariba.arches.datastore.ShardDocDetails
        buyer.ariba.arches.datastore.ShardInfo
        buyer.ariba.arches.datastore.TenantInfo
        buyer.ariba.arches.datastore.TenantJobCounter
        buyer.ariba.arches.queue.QueueMessageStatus
        buyer.ariba.hbase.dao.impl.SystemCounters
        buyer.ariba.arches.datastore.PrimaryData
        buyer.ariba.arches.datastore.Schema
    );

    my $thisType;

    #
    # take snapshots 
    # 
    my $fullCommand;
    debug("Creating snapshots");
    for my $table (@tables) {
        my $ssString = "ss." . strftime("%Y.%m.%d.%H.%M.%S",localtime(time()));
        $ssString .= ".$table";
        $cmd = "snapshot '\"$table\"','\"$ssString\"'";
        $fullCommand .= $cmd . "\n"; 
    }
    my $now = time();
    $cmd = "echo \"$fullCommand\" | hbase shell";
    runCmd($cmd);

    ## get snapshot list
    ## i.e. list_snapshots 'buyer.ariba.arches.datastore.AtomicShardUpdates'
    debug("Getting list of all tables");
    $cmd = 'echo "list_snapshots" | hbase shell';
    my $tableInfo = runCmd($cmd);
    my @output = split("\n", $tableInfo);

    my ($warn, $results);

    my $snapshotsTimes = snapshotInfo(\@output, "times");

    foreach my $table (keys %$snapshotsTimes) {
        my $snaptime = $$snapshotsTimes{$table};

        my $prettyTime = strftime("%Y-%m-%d %H:%M:%S",localtime($snaptime));
        if ($now > $snaptime) {
            $warn = "answer =~ /^WARNING/";
            $results = "WARNING: not taken since $prettyTime";
        } else {
            $results = $prettyTime;
        }

        $queries{"snapshot for $table"} = {
            format => "</td><td>%s",
            warn => $warn,
            uiHint  => "snapshots",
            severity    => 2,
            perl => sub { return $results; },
            description => "Snapshots for $table",
            correctiveActions => [
                Ops => "Follow up with DBAs. If in warn state, no snapshot was taken in the last 6 hours",
            ],
            inf_field => "snapshot",
            inf_tags => qq|table="$table"|,
            inf_default => "none",
        };
    }
    my $email = $me->default('notify.email');
    $queries{influx_details} = {measurement => "hdfs_export"};

############# Test block #################
    my $t = TestUtils->new({queries => \%queries});
    my ($rc, $msg) = $t->validate_query_keys();
    is($rc, 1, $msg);
##########################################

    my $qm = ariba::monitor::QueryManager->newWithDetails('hbase', $hadoop->name(), $hadoop->service(), $hadoop->customer(), $hadoop->currentCluster(), \%queries);
    $qm->processQueries($debug, $email, $sendEmail, $sendPage);
}

sub snapshotInfo {
    my $output = shift;
    my $type = shift;
    my %snapshotsHash;

    #
    # sample out put that we care about
    # $VAR13 = ' ss.2013.12.11.14.41.51.buyer.ariba.arches.datastore.AtomicShardUpdates buyer.ariba.arches.datastore.AtomicShardUpdates (Wed Dec 11 14:41:52 -0800 2013)';
    #
    # only get actual snapshot information, store in hash with latest snapshot time per table
    # tablename => snapshot time (epoch)
    #
    push(my @snapshots, grep ( /ss\.\d{4}\.\d{2}\.\d{2}\.\d{2}\.\d{2}\.\d{2}.*\d{4}\s\d{4}\)$/, @$output) );

    for my $snapshot (@snapshots) {
        my ($timestamp, $table, $entry);
        $entry = (split(' ', $snapshot))[0];

        ## example timestamp: 2013.12.11.14.41.51, table: buyer.ariba.arches.datastore.AuxiliaryData
        ## timestamp: yyyy.mm.dd.hh.mm.ss
        ($timestamp, $table) = $entry =~ /ss\.(\d{4}\.\d{2}\.\d{2}\.\d{2}\.\d{2}\.\d{2})\.(.*)/;

        next unless($timestamp && $table);
        my ($year, $mon, $day, $hour, $min, $sec) = (split('\.', $timestamp))[0,1,2,3,4,5];
        my $time = timelocal($sec, $min, $hour, $day, $mon-1, $year); 

        ## get latest timestamp per table
        if ( (exists $snapshotsHash{$table} && $time > $snapshotsHash{$table}) || !exists $snapshotsHash{$table}) {
            $snapshotsHash{$table} = $time;
        } else {
            next;
        }
    }

    if ($type =~ /^tables$/) {
        return keys(%snapshotsHash);
    } elsif ($type =~ /^times$/) {
        return \%snapshotsHash;
    } else {
        print "ERROR: invalid snapshotInfo type.\n";
        return 0;
    }
}

sub runCmd {
    my $cmd = shift;

    my $output = `$cmd 2>&1`;

    if ($?) {
        return undef;
    } else {
        return $output;
    }
}

sub debug {
    my $msg = shift; 

    print "(debug) $msg\n" if ($debug);
}

main(@ARGV);

__END__
