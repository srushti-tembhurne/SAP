#!/usr/local/bin/perl

package ariba::Ops::MCL::Helpers::SnapMirror;

use ariba::Ops::MCL;
use ariba::Ops::Logger;
use ariba::rc::InstalledProduct;
my $logger = ariba::Ops::Logger->logger();

use ariba::Ops::NetworkDeviceManager;
use FindBin;
use lib "$FindBin::Bin/../lib/Netapp";
use lib "$FindBin::Bin/../../lib/perl/Netapp";
use lib "$FindBin::Bin/../../../lib/perl/Netapp";
use lib "$FindBin::Bin/../../../../Netapp";
# use NaServer;

use Data::Dumper;

my $debug = 0;

#
# This is called in an MCL like this:
#
# SnapMirror::checkSyncStatus('lab','anlab,archive,buyerlab,catlab','opslabdr','123456','failover')
#
# It takes a service (lab or prod typically for DR failover)
# a list of NFS volume names (from snapmirror.cfg)
# and a datacenter -- the datacenter that you are failing TO
#
# It then queries the status and state of the volume, and looks for Idle status,
# and snapmirrored state.
#
sub checkSyncStatus {
    my $service = shift;
    my $volList = shift;
    my $datacenter = shift;
    my $tmid = shift;
    my $type = shift;

    my $snapToFind = "$type-TMID$tmid";

    my @vols = split(/,/, $volList);

    my %statusForVol;
    foreach my $v (@vols) {
        next if($v =~ /^mon/); # we specifically are NOT waiting for this
        $statusForVol{$v} = "NOSNAP";
    }

    my %match = (
        'os' => 'ontap',
        'datacenter' => $datacenter,
    );

    my @netapps = ariba::Ops::Machine->machinesWithProperties(%match);

    foreach my $n (@netapps) {
        my $nm = ariba::Ops::NetworkDeviceManager->newFromMachine($n);
        my @results = $nm->_sendCommandLocal("snap list");      
        $nm->disconnect();

        my $volume;
        foreach my $line (@results) {
            chomp $line;
            $logger->info("'$line'");
            if($line =~ /^Volume\s+(.*)$/) {
                $volume = $1;
            }

            next unless($statusForVol{$volume});

            if($line =~ /$snapToFind/) {
                $statusForVol{$volume} = "OK";
            }
        }
    }

    foreach my $v (keys %statusForVol) {
        unless($statusForVol{$v} eq 'OK') {
            return("ERROR: $snapToFind not yet replicated for $v.");
        }
    }

    return("OK: all volumes are in sync.");
}

#
# This is called in an MCL like this:
#
# SnapMirror::checkBreakStatus('lab','anlab,archive,buyerlab,catlab','opslabdr')
#
# It takes a service (lab or prod typically for DR failover)
# a list of NFS volume names (from snapmirror.cfg)
# and a datacenter -- the datacenter that you are failing TO
#
# It then queries the status of the volumes on the netapps, and checks to see
# if all of them are in a Broken-off state.
#
sub checkBreakStatus {
    my $service = shift;
    my $volList = shift;
    my $datacenter = shift;

    my @vols = split(/,/, $volList);

    my %statusForVol;
    foreach my $v (@vols) {
        $statusForVol{$v} = "UNKNOWN";
    }

    my %match = (
        'os' => 'ontap',
        'datacenter' => $datacenter,
    );

    my @netapps = ariba::Ops::Machine->machinesWithProperties(%match);

    foreach my $n (@netapps) {
        my $nm = ariba::Ops::NetworkDeviceManager->newFromMachine($n);
        my @results = $nm->_sendCommandLocal("snapmirror status -l");       
        $nm->disconnect();

        my $volume;
        foreach my $line (@results) {
            chomp $line;
            $logger->info("'$line'");
            if($line =~ /^Source:.*:([^:]+)$/) {
                $volume = $1;
            }

            next unless($statusForVol{$volume});

            if($line =~ /^State:\s+(.*)$/) {
                my $state = $1;
                if($state ne 'Broken-off') {
                    return("ERROR: $volume [$state] is not broken yet");
                } else {
                    $statusForVol{$volume} = "OK";
                }
            }
        }
    }

    foreach my $v (keys %statusForVol) {
        unless($statusForVol{$v} eq 'OK') {
            return("ERROR: $v was not found on the netapps.");
        }
    }

    return("OK: all volumes are in broken-off state.");
}

## Per NetApp docs:
##
##    Example: $myserver->invoke("snapshot-create",
##                 "snapshot", "mysnapshot",
##                 "volume", "vol0");
##

sub create{
    ## snapshot-create
    my ( $filer, $volume, $snapshot ) = @_;
    my $sess = connectToFiler( $filer );

    my $res = $sess->invoke(
        'snapshot-create',
        'volume', $volume,
        'snapshot', $snapshot,
        'async', 0,
    );

    if ( $res->results_status() eq 'failed' ){
        $res =  "Error: Snapshot '$snapshot' create for volume '$volume' failed: " . $res->results_reason() . "\n";
    }
    return $res;
}

sub update{
    ## snapmirror-update
    my ( $filer, $srcVolume, $dstVolume ) = @_;
    my $sess = connectToFiler( $filer );

    my $res = $sess->invoke(
        'snapmirror-update',
        'source-location',      $srcVolume,
        'destination-location', $dstVolume,
    );

    if ( $res->results_status() eq 'failed' ){
        $res =  "Error: Snapmirror update of '$src' => '$dst' failed: " . $res->results_reason() . "\n";
    }
    return $res;
}

sub break{
    ## snapmirror-break
    my ( $filer, $volume ) = @_;
    my $sess = connectToFiler( $filer );

    my $res = $sess->invoke(
        'snapmirror-break',
        'destination-location', $volume,
    );

    return $res;
}

sub resync{
    ## snapmirror-resync
    my ( $filer, $srcVolume, $dstVolume ) = @_;
    my $sess = connectToFiler( $filer );

    my $res = $sess->invoke(
        'snapmirror-resync',
        'source-location',      $srcVolume,
        'destination-location', $dstVolume,
    );

    if ( $res->results_status() eq 'failed' ){
        $res =  "Error: Snapmirror resync of '$src' => '$dst' failed: " . $res->results_reason() . "\n";
    }
    return $res;
}

sub list{
    ## snapshot-list-info
    my ( $filer, $volume ) = @_;
    my $session = connectToFiler( $filer );

    my @results = $session->invoke('snapshot-list-info',
                                    'target-name', $volume,
                                    'target-type', 'volume',
    );

    my $res;
    
    if ( $debug ){
        foreach $res ( @results ){
            print Dumper $res;
        }
    }

    return $res;
}

sub status{
    ## snapmirror-get-status
    my ( $filer, $volume ) = @_;
    my $sess = connectToFiler( $filer );

    my $res = $sess->invoke(
        'snapmirror-get-status',
    );

    if ( $res->results_status() eq 'failed' ){
        return "Error: Retrieving status for volume '$volume' failed: " . $res->results_reason() . "\n";
    }

    STATUS:
    foreach my $status ( ($res->child_get( 'snapmirror-status' ))->children_get() ){
        my $srcLoc = $status->child_get( 'source-location' );
        next STATUS unless $srcLoc->{'content'} =~ /$volume/;

        my $idle = $status->child_get( 'status' );
        print Dumper $idle if $debug;
        $res = $idle->{'content'};
        print "$volume:\t$res\n" if $debug;
    }
    return $res;
}

sub waitForIdle{
    ## Wait for update to complete
    my ( $filer, $volume ) = @_;
    sleep 5; ## Give the netapp a few seconds to start transferring
    my $result = "transferring";
    while ( $result =~ /transferring/ ){
        print "** Status for '$volume': '$result' **\n" if $debug;
        $result = status( $filer, $volume );
        sleep 1; ## Wait a second
    }
    print "** Status for '$volume': '$result' **\n" if $debug;
    if ( $result ne 'idle' ){
        $result =  "Error: Unknown volume status '$result'\n";
    }
    return $result;
}

sub connectToFiler {
    my $filer = shift;

    my $mcl = ariba::Ops::MCL->currentMclObject();
    my $me = ariba::rc::InstalledProduct->new( 'mon', $mcl->service() );

    my $s = NaServer->new($filer, 1, 1);

    my $username = $me->default('Ops.Netapp.username');
    my $password = $me->default('Ops.Netapp.password');
    $s->set_admin_user($username, $password);
    return $s;
}

1;
