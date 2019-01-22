# $Id: //ariba/services/tools/lib/perl/ariba/Ops/NetworkDevice/inserv.pm#35 $
package ariba::Ops::NetworkDevice::inserv;

use strict;
use Date::Parse;
use Data::Dumper;
use Expect 1.11;
use ariba::Ops::NetworkDevice::BaseDevice;
use ariba::Ops::Startup::Common;
use ariba::Ops::Inserv::VolumeLun;

use base qw(ariba::Ops::NetworkDevice::BaseDevice);

=pod

=head1 NAME

ariba::Ops::NetworkDevice::inserv - manage 3Par storage array

=head1 DESCRIPTION

inserv handles all communication with the 3par storage array and
offers an API to query the information from the array. Some API
calls let users initiate a snap and/or physical copy for backups.

You can use the API provided by this class to do things like:

=over 4

=item * how much free space is available

=item * get details of a virtual volume

=item * initiate a backup (using snap copy or physical copy)

=back

=cut

#
# in seconds, this timeout gets handed to Expect eventually to have
# it wait longer for some commands to complete
# see ariba::Ops::NetworkDevice::BaseDevice::sendCommand
#
my $DEFAULT_TIMEOUT = 90;
my $LONG_TIMEOUT = 10 * 60;
my $SAMPLE_TIME = 60;
my $HOST = "host";
my $FREE = "free";
my $DISK = "disk";
my $FRONT = "front";
my $BACK = "back";
my $READ = "read";
my $WRITE = "write";
my $IOPS = "IOPS";
my $BITSPS = "BitsPS";
my $READY = "ready";

# These values are from 3par.  See TMID:70707
my $S_SERIES_MAX_READ_MBITSPS = 350 * 8;
my $S_SERIES_MAX_WRITE_MBITSPS = 250 * 8;
my $T_SERIES_MAX_READ_MBITSPS = 800 * 8;
my $T_SERIES_MAX_WRITE_MBITSPS = 400 * 8;

my $S_SERIES_MAX_READ_IOPSPS = 20000;
my $S_SERIES_MAX_WRITE_IOPSPS = 20000;
my $T_SERIES_MAX_READ_IOPSPS = 32000;
my $T_SERIES_MAX_WRITE_IOPSPS = 32000;

my $physicalCopyPrefix = "pc";
my $snapCopyPrefix = "sc";
my $snapROCopyPrefix = "${snapCopyPrefix}ro";
my $snapRWCopyPrefix = "${snapCopyPrefix}rw";

$ENV{'PATH'} = '/usr/local/bin:' . $ENV{'PATH'};

sub volumeTagsForDevices {
    my @ret = ();
    return @ret;
}

=pod

=item ioPerSecond()

Calculates the maximum and current IOps from the 3par

=cut

#
# From TMID:36992
#
# Michael Spitz from 3PAR gave me the following to get this info:
# 
# To get the max IOps for each drive type, multiply the drive count for each
# type by 85 for NL or 150 for FC.  So in devlab, we have 80 NL and 80 FC
# drives, the total IOps by type of drive would be:
# 
# 80 x 85 = 6800 (NL)
# 80 x 150 = 12000 (FC)
# 
# There is no single command to get the current IOps, so you have to do it in
# 2 steps.  To find out whether a disk is FC or NL, use:
# 
# inserv.opslab.ariba.com cli% showpd -i
#  Id Cage_Pos Device_id   Vendor  FW_Revision Serial_number FW_status Dev_Type
#   0   0:0:0  ST3146707FC SEAGATE E204        3KS1NZN0      current   FC      
#   1   0:0:1  ST3146707FC SEAGATE E204        3KS293EP      current   FC      
#   2   0:0:2  ST3146707FC SEAGATE E204        3KS291V8      current   FC      
# ...
# 
# If you only wanted to see NL disk, you can use:
# inserv.opslab.ariba.com cli% showpd -i -p -devtype NL
# 
# Then, to get the current IOps by disk Id: 
# 
# inserv.opslab.ariba.com cli% statpd -iter 1
# 15:11:38 05/18/07 r/w I/O per second     KBytes per sec      Svt ms     IOSz KB     
#     Pdid     Port      Cur  Avg  Max    Cur    Avg  Max   Cur   Avg   Cur   Avg Qlen
#        0    2:0:4   t   11   11   11    113    113  113  20.5  20.5  10.3  10.3    1
#        1    3:0:4   t    5    5    5    484    484  484  31.2  31.2  92.3  92.3    0
#        2    2:0:4   t   11   11   11    189    189  189  28.1  28.1  16.6  16.6    1
# ...
# 
# Pdid in this command lines up with Id in the previous command.
#
sub cmdShowpd {
    my $self = shift;
    my $isSet = $self->showpd();

    unless($isSet) {
        my $arg = '-showcols Id,CagePos,Model,Manuf,FW_Rev,Serial,FW_Status,Type';
        $arg = '-i' if ($self->cmdInservVersion() eq '2.2.4');

        my @showpd = $self->_sendCommandLocal("showpd $arg");
        $self->setShowpd(@showpd);
    }

    return($self->showpd());
}

sub cmdShowpdFailed {
    my $self = shift;
    my $isSet = $self->showpdFailed();

    unless($isSet) {
        my $arg = '-failed';

        my @showpdfailed = $self->_sendCommandLocal("showpd $arg");
        $self->setShowpdFailed(@showpdfailed);
    }

    return($self->showpdFailed());
}

sub cmdStatpd {
    my $self = shift;
    my $isSet = $self->statpd();

    unless($isSet) {
        my @statpd = $self->_sendCommandLocal("statpd -iter 2");
        $self->setStatpd(@statpd);
    }

    return($self->statpd());
}

sub cmdStatPort {
    my $self = shift;
    my $isSet = $self->statPort();
    
    unless($isSet) {
        my @stat = $self->sendCommandUsingInform("statport -rw -d $SAMPLE_TIME -iter 1", $LONG_TIMEOUT);
        $self->setStatPort(@stat);
    }

    return($self->statPort());
}

sub cmdStatCmpVv {
    my $self = shift;
    my $isSet = $self->statCmpVv();
    
    unless($isSet) {
        my @stat = $self->sendCommandUsingInform("statcmp -v -iter 1 -d $SAMPLE_TIME", $LONG_TIMEOUT);
        $self->setStatCmpVv(@stat);
    }

    return($self->statCmpVv());
}

sub cmdStatCmp {
    my $self = shift;
    my $isSet = $self->statCmp();
    
    unless($isSet) {
        my @stat = $self->sendCommandUsingInform("statcmp -iter 1 -d $SAMPLE_TIME", $LONG_TIMEOUT);
        $self->setStatCmp(@stat);
    }

    return($self->statCmp());
}

sub ioPerSecond {
    my $self = shift;
    my $type = shift;
    my %diskIds;

    my ($iops, $maxIops) = ( 0, 0 );

    foreach my $line ($self->cmdShowpd()) {
        $line =~ s/^\s+//;
        my ($id, $devtype) = (split(/\s+/,$line))[0,7];
        next if($id !~ /^\d+$/);
        if($type) {
            next if(!$devtype || $devtype !~ /^$type/i);
        }

        $diskIds{$id} = 1;

        $maxIops += 150 if($devtype =~ /^fc/i);
        $maxIops += 85 if($devtype =~ /^nl/i);
    }

    #
    # we are going to throw away the first set of data -- "top syndrome"
    #
    foreach my $line ($self->cmdStatpd()) {
        $line =~ s/^\s+//;
        my ( $id, $currentIops ) = (split(/\s+/,$line))[0,3];
        next unless($id && $id =~ /^\d+$/);
        $diskIds{$id}++;
        #
        # this will only get to 3 for marked disks during the second
        # iteration -- remember we throw the first away
        #
        next unless($diskIds{$id} == 3);
        $iops += $currentIops;
    }

    return ( $iops, $maxIops );

}

sub failedDisk {
    my $self = shift;

    foreach my $line ($self->cmdShowpdFailed()) {
        # 'No PDs listed' is the returned results if there are no failed disks
        if ($line =~ /^No PDs listed$/) {
            return 0;
        }
    }

    return 1;
}

sub nodeFeReadIOPerSec  {
    my $self = shift;
    my $node = shift;
    
    return $self->nodeIOPerformance($node, $READ, $FRONT, $IOPS);
}

sub nodeBeReadIOPerSec  {
    my $self = shift;
    my $node = shift;
    
    return $self->nodeIOPerformance($node, $READ, $BACK, $IOPS);
}

sub nodeFeWriteIOPerSec  {
    my $self = shift;
    my $node = shift;
    
    return $self->nodeIOPerformance($node, $WRITE, $FRONT, $IOPS);
}

sub nodeBeWriteIOPerSec  {
    my $self = shift;
    my $node = shift;
    
    return $self->nodeIOPerformance($node, $WRITE, $BACK, $IOPS);
}

sub nodeFeReadMBitsPerSec  {
    my $self = shift;
    my $node = shift;
    
        return sprintf("%.3f", $self->nodeIOPerformance($node, $READ, $FRONT, $BITSPS) / 1000 / 1000);

}

sub nodeBeReadMBitsPerSec {
    my $self = shift;
    my $node = shift;
    
        return sprintf("%.3f", $self->nodeIOPerformance($node, $READ, $BACK, $BITSPS) / 1000 / 1000);
}

sub nodeFeWriteMBitsPerSec  {
    my $self = shift;
    my $node = shift;
    
        return sprintf("%.3f", $self->nodeIOPerformance($node, $WRITE, $FRONT, $BITSPS) / 1000 / 1000);
}

sub nodeBeWriteMBitsPerSec {
    my $self = shift;
    my $node = shift;
    
        return sprintf("%.3f", $self->nodeIOPerformance($node, $WRITE, $BACK, $BITSPS) / 1000 / 1000);
}

sub nodeIOPerformance {
    my $self = shift;
    my $node = shift;
    my $readOrWrite = shift;
    my $frontOrBackEnd = shift;
    my $bitsPSOrIOPS = shift;

    my $attribute = $readOrWrite . $bitsPSOrIOPS;
    my $value;

    for my $portIdentifier (sort(keys %{$self->portStats()})) {
        my $portParameters = $self->portParameters()->{$portIdentifier};
        my $portStats = $self->portStats()->{$portIdentifier};

        next unless $portParameters->state() eq $READY and 
                $portParameters->node() eq $node;

        if ( $frontOrBackEnd eq $FRONT ) {
            next unless $portParameters->type() eq $HOST;
        } elsif ( $frontOrBackEnd eq $BACK ) {
            next unless $portParameters->type() eq $DISK;
        } else {
            print "ERROR - $frontOrBackEnd is not '$FRONT' or '$BACK'\n";
            return;
        }

        print "DEBUG - $frontOrBackEnd end port $portIdentifier $readOrWrite IOPS: ",  
              $portStats->$attribute(), "\n" if $self->debug();
        $value += $portStats->$attribute();

    }

    return 0 if !defined $value;
    return $value;
}

sub nodeMaxReadMBitsPerSec {
    my $self = shift;

    if ($self->machine->hardwareType() =~ /^s/i ) {
        return $S_SERIES_MAX_READ_MBITSPS;
    } elsif ($self->machine->hardwareType() =~ /^t/i ) {
        return $T_SERIES_MAX_READ_MBITSPS;
    }

    return;
}

sub nodeMaxWriteMBitsPerSec {
    my $self = shift;

    if ($self->machine->hardwareType() =~ /^s/i ) {
        return $S_SERIES_MAX_WRITE_MBITSPS;
    } elsif ($self->machine->hardwareType() =~ /^t/i ) {
        return $T_SERIES_MAX_WRITE_MBITSPS;
    }

    return;
}

sub nodeMaxReadIOPsPerSec {
    my $self = shift;

    if ($self->machine->hardwareType() =~ /^s/i ) {
        return $S_SERIES_MAX_READ_IOPSPS;
    } elsif ($self->machine->hardwareType() =~ /^t/i ) {
        return $T_SERIES_MAX_READ_IOPSPS;
    }

    return;
}

sub nodeMaxWriteIOPsPerSec {
    my $self = shift;

    if ($self->machine->hardwareType() =~ /^s/i ) {
        return $S_SERIES_MAX_WRITE_IOPSPS;
    } elsif ($self->machine->hardwareType() =~ /^t/i ) {
        return $T_SERIES_MAX_WRITE_IOPSPS;
    }

    return;
}

sub nodeBeReadRatio {
    my $self = shift;
    my $node = shift;

    my $readBitsPS = $self->nodeIOPerformance($node, $READ, $BACK, $BITSPS);
    my $totalBitsPS = $readBitsPS + $self->nodeIOPerformance($node, $WRITE, $BACK, $BITSPS);
    my $readRatio = $totalBitsPS ? ($readBitsPS / $totalBitsPS) : 0;

    return $readRatio;
}

sub nodeBeWriteRatio {
    my $self = shift;
    my $node = shift;

    return 1 - $self->nodeBeReadRatio($node);
}

sub nodeList {
    my $self = shift;

    return $self->SUPER::nodeList() if $self->SUPER::nodeList();
    my @nodes;

    my @output = $self->sendCommandUsingInform("shownode");
    for my $line (@output) {
        chomp $line;
        next unless $line =~ /\s(\d+)\s/;
        my $node = $1;
        print "DEBUG - Adding $node to nodelist attribute\n" if $self->debug();
        push(@nodes, $node);
    }

    $self->SUPER::setNodeList(@nodes);
    
    return @nodes;

}

sub portList {
    my $self = shift;

    return sort(keys %{$self->portParameters()});
}

sub frontEndPortList {
    my $self = shift;

    my @portList;
    for my $portIdentifier ($self->portList()) {
        push (@portList, $portIdentifier) 
            if $self->isFrontEndPort($portIdentifier);
    }

    return sort(@portList);
}

sub isFrontEndPort {
    my $self = shift;
    my $portIdentifier = shift;

    return 1 if $self->portParameters()->{$portIdentifier}->type() eq $HOST;

    return;
}

sub isFreePort {
    my $self = shift;
    my $portIdentifier = shift;

    return 1 if $self->portParameters()->{$portIdentifier}->type() eq $FREE;

    return;
}

sub backEndPortList {
    my $self = shift;

    my @portList;
    for my $portIdentifier ($self->portList()) {
        push (@portList, $portIdentifier) 
            if $self->isBackEndPort($portIdentifier);
    }

    return sort(@portList);
}

sub isBackEndPort {
    my $self = shift;
    my $portIdentifier = shift;

    return 1 if $self->portParameters()->{$portIdentifier}->type() eq $DISK;

    return;

}

sub portStats {
    my $self = shift;

    return $self->SUPER::portStats() if $self->SUPER::portStats();

    my @output = $self->cmdStatPort();
    # 19:55:25 09/15/09 r/w  I/O per second      KBytes per sec    Svt ms     IOSz KB       Idle %
    #     Port      D/C       Cur   Avg Max    Cur    Avg   Max  Cur  Avg   Cur   Avg Qlen Cur Avg
    #    0:0:1     Data   r   142   142 142   2966   2966  2966 18.5 18.5  20.8  20.8    -   -   -
    #    0:0:1     Data   w   115   115 115   2402   2402  2402 23.4 23.4  21.0  21.0    -   -   -
    #    0:0:1     Data   t   257   257 257   5367   5367  5367 20.7 20.7  20.9  20.9    0  64  64
    #    0:0:2     Data   r   145   145 145   3109   3109  3109 18.9 18.9  21.4  21.4    -   -   -
    #    0:0:2     Data   w   116   116 116   2241   2241  2241 24.0 24.0  19.3  19.3    -   -   -
    #    0:0:2     Data   t   261   261 261   5350   5350  5350 21.2 21.2  20.5  20.5    0  61  61
    #    0:0:3     Data   r   134   134 134   2798   2798  2798 25.2 25.2  20.9  20.9    -   -   -
    #    0:0:3     Data   w   113   113 113   2164   2164  2164 26.0 26.0  19.1  19.1    -   -   -
    #    0:0:3     Data   t   247   247 247   4961   4961  4961 25.6 25.6  20.1  20.1    0  68  68
    #    0:0:4     Data   r   139   139 139   2895   2895  2895 24.7 24.7  20.8  20.8    -   -   -
    #    0:0:4     Data   w   115   115 115   2244   2244  2244 26.4 26.4  19.5  19.5    -   -   -
    #    0:0:4     Data   t   254   254 254   5138   5138  5138 25.4 25.4  20.2  20.2    0  67  67

    my $ports = {};
    for my $line (@output) {
        chomp $line;
        # skip the header lines
        $line =~ s/^\s*//g;
        next unless $line =~ /\d:\d:\d.*Data/;
        my ($portName, $ioType, $iops, $kBps, $svcTime, $ioSize, $queueLength) = (split(/\s+/, $line))[0,2,3,6,9,11,13];

        my $portIdentifier = $self->hostname() . '=' . $portName;

        unless ( $ports->{$portIdentifier} ) {
            my $port = ariba::Ops::NetworkDevice::inserv::Container::PortStats->new($portIdentifier);
            $port->setName($portName);
            $ports->{$portIdentifier} = $port;
        }
        $ports->{$portIdentifier}->setIoType($ioType);

        if ( $ioType eq "r" ) {
            $ports->{$portIdentifier}->setReadIOPS($iops);
            $ports->{$portIdentifier}->setReadBitsPS($kBps * 1000 * 8);
            $ports->{$portIdentifier}->setReadSvcTimeMS($svcTime);
            $ports->{$portIdentifier}->setReadIOSizeBytes($ioSize * 1000);
        } elsif ( $ioType eq "w" ) {
            $ports->{$portIdentifier}->setWriteIOPS($iops);
            $ports->{$portIdentifier}->setWriteBitsPS($kBps * 1000 * 8);
            $ports->{$portIdentifier}->setWriteSvcTimeMS($svcTime);
            $ports->{$portIdentifier}->setWriteIOSizeBytes($ioSize * 1000);
        } elsif ( $ioType eq "t" ) {
            $ports->{$portIdentifier}->setQueueLength($queueLength);
        }

    }

    return unless $ports;

    $self->SUPER::setPortStats($ports);

    return $ports;
}
sub totalNumVv {
    my $self = shift;
    my @output = $self->sendCommandUsingInform("showvv", $LONG_TIMEOUT);
    my $total = undef;

    if (@output) {
        my $totalVv= pop(@output);
        if ($totalVv =~ /(\d+)\s+total/i) {
            $total = $1;
        }
    }
    return $total;
}

sub vvCacheStats {
    my $self = shift;

    return $self->SUPER::vvCacheStats() if $self->SUPER::vvCacheStats();

    my @output = $self->cmdStatCmpVv();
    # 20:47:27 09/16/09       ---- Current ----- ----- Total ------
    #   VVid VVname     Type  Accesses Hits Hit% Accesses Hits Hit%
    #    175 0009-11    Read         0    0    0        0    0    0
    #    175 0009-11    Write        0    0    0        0    0    0
    #    176 0009-12    Read         0    0    0        0    0    0

    my $vvCacheStats = {};
    for my $line (@output) {
        chomp $line;
        $line =~ s/^\s*//g;
        next unless $line =~ /(Read|Write)/;
        my ($vvName, $type, $accesses, $hits) = (split(/\s+/, $line))[1,2,3,4];

        my $vvIdentifier = $self->hostname() . '-' . $vvName;

        unless ( $vvCacheStats->{$vvIdentifier} ) {
            my $vv = ariba::Ops::NetworkDevice::inserv::Container::VVCacheStats->new($vvIdentifier);
            $vv->setName($vvName);
            $vvCacheStats->{$vvIdentifier} = $vv;
        }

        my $accessAttribute = lcfirst($type) . "Accesses";
        my $hitAttribute = lcfirst($type) . "Hits";
        $vvCacheStats->{$vvIdentifier}->setType($type);
        $vvCacheStats->{$vvIdentifier}->setAttribute($accessAttribute, $accesses);
        $vvCacheStats->{$vvIdentifier}->setAttribute($hitAttribute, $hits);
    }

    return unless $vvCacheStats;

    $self->SUPER::setVvCacheStats($vvCacheStats);

    return $vvCacheStats;
}

sub nodeCacheStats {
    my $self = shift;

    return $self->SUPER::nodeCacheStats() if $self->SUPER::nodeCacheStats();

    my @output = $self->cmdStatCmp();
    # 08:50:54 09/23/09 ---- Current ----- ----- Total ------
    #    Node Type      Accesses Hits Hit% Accesses Hits Hit%
    #       0 Read          1217  916   75     1217  916   75
    #       0 Write          418  179   43      418  179   43
    #       1 Read          1410  859   61     1410  859   61
    #       1 Write          982  196   20      982  196   20
    

    my $nodeCacheStats = {};
    for my $line (@output) {
        chomp $line;
        $line =~ s/^\s*//g;
        next unless $line =~ /^\s*\d+\s+(Read|Write)/;
        my ($nodeName, $type, $accesses, $hits) = (split(/\s+/, $line))[0,1,2,3];

        my $nodeIdentifier = $self->hostname() . '-' . $nodeName;

        unless ( $nodeCacheStats->{$nodeIdentifier} ) {
            my $node = ariba::Ops::NetworkDevice::inserv::Container::NodeCacheStats->new($nodeIdentifier);
            $node->setName("Node $nodeName");
            $nodeCacheStats->{$nodeIdentifier} = $node;
        }

        my $accessAttribute = lcfirst($type) . "Accesses";
        my $hitAttribute = lcfirst($type) . "Hits";
        $nodeCacheStats->{$nodeIdentifier}->setType($type);
        $nodeCacheStats->{$nodeIdentifier}->setAttribute($accessAttribute, $accesses);
        $nodeCacheStats->{$nodeIdentifier}->setAttribute($hitAttribute, $hits);
    }

    return unless $nodeCacheStats;

    $self->SUPER::setNodeCacheStats($nodeCacheStats);

    return $nodeCacheStats;
}


sub checkConnectivity {
    my $self = shift;
    my $trycount = 3;
    my $status = 0;
    while($trycount--) {
        $status = $self->connect();
        last if $status;
        sleep(3);
    }
    return $status;
}

my $logfh;

sub disconnect {
    my $self = shift;

    if ($self->handle()) {
        $self->sendCommand('exit');
    }

    $self->SUPER::disconnect();
}

sub connect {
    my $self = shift;
    my $ret;

    if($self->proxyHost() && $self->proxyPort()) {
        return 1 if($self->handle());
        eval {
            $ret = $self->telnetToDevice();
        };
        return($ret) if($ret);
    }

    #
    # if proxy fails, use direct connect
    #
    return( $self->SUPER::connect() );
}

sub loginName {
    my $self = shift;

    #username: 3paradm
    return '3paradm';
}

sub accessPassword {
    my $self = shift;

    #XXXXXX
    #XXXXXX FIX THIS
    #XXXXXX
    return '3pardata';
}

sub commandPrompt {
    my $self = shift;

    my $hostname = $self->hostname();
    $hostname =~ s|\.ariba\.com||;
    $hostname = $self->promptName() if ($self->promptName());

    return "$hostname(\.ariba\.com)? cli% ";
}

sub convertDateToTime {
    my $self = shift;
    my $string = shift;

    return 0 unless($string);

    my $utime;
    if($string =~ m/MSK$/) {
       $string =~ s/MSK/UTC/;
       $utime = str2time($string);
       $utime = $utime + (3*3600); #str2time doesn't handle MSK so do this for UTC  and add three hours
    } else {
    $utime = str2time($string);
    }

    return $utime;
}

#
# A helper to run a given command and cleanup its output
#
sub _sendCommandLocal {
    my $self = shift;
    my $commandString = shift;
    my $timeout = shift || $DEFAULT_TIMEOUT;

    if($main::useInformFor3par) {
        my $logger = ariba::Ops::Logger->logger();
        $logger->info("Override: Using Inform for $commandString");

        return($self->sendCommandUsingInform($commandString, $timeout));
    }

    #
    # allow more time for proxied command... if the proxy times out and
    # has to reconnect, this will always timeout too if the timeout is the
    # same.  The longer timeout gives the proxy a chance to recover, and
    # possibly work transparently to the client.
    #
    if($self->proxyHost()) {
        $timeout *= 8;
    }

    #
    # long held connections get stuck.  We'll occasionally reconnect
    #
    if(
        $self->lastCommandTime() &&
        (time() - $self->lastCommandTime()) > 30
    ) {
        $self->disconnect();
        if($self->handle() && !$self->handle()->exitstatus()) {
            my $pid = $self->handle()->pid();
            kill(9, $pid) if($pid);
        }
        $self->setHandle(undef);
        $self->connect();
    }
    $self->setLastCommandTime(time()) unless($self->lastCommandTime());

    my @output;

    return @output unless($commandString);

    return @output unless ($self->connect());
    my $commandStringForMatch = quotemeta($commandString);

    $self->logMessage($commandString);

    $self->setError("");
    my $outputText = $self->sendCommand($commandString, undef, undef, $timeout);
    if($self->error()) {
        return(@output);
    }

    for my $line (split(/\r?\n/, $outputText )) {
        #
        # our command gets echoed back to us
        # and sometimes it gets split over 2 lines.
        #
        $line =~ s|\r*$||;
        next if ($line =~ /$commandStringForMatch/);
        my $lineToMatch = quotemeta($line);
        next if ($commandString =~ /$lineToMatch/);

        push(@output, $line);

        if ($self->debug() && $self->debug() >= 2) {
            print "[$line]\n";
        }

        $self->logMessage($line);
    }

    if(scalar(@output)) {
        $self->setLastCommandTime(time());
    }
    return @output;
}

=pod 

=item sendCommandUsingInform() 

Sends the command using the InForm Tool library instead of via ssh. 

=cut

sub sendCommandUsingInform { 
    my $self = shift; 
    my $commandString = shift; 
    my $timeout = shift || $DEFAULT_TIMEOUT; 
    my @output; 
    
    return @output unless($commandString);

    $commandString = "/usr/local/bin/$commandString"; 
    $self->logMessage($commandString);

    my $inform = Expect->spawn($commandString) || do {
            $self->setError("Failed to spawn command: $commandString"); 
            warn $self->error() if ($self->debug()); 
            return @output; 
        }; 
    $inform->log_stdout(0); 

    $inform->expect($timeout, 
        '-re', 'system', sub { 
            $inform->send($self->hostname() . "\r"); 
            exp_continue(); 
        }, 
        '-re', 'user', sub { 
            $inform->send($self->loginName() . "\r"); 
            exp_continue(); 
        }, 
        '-re', 'password', sub { 
            my $expInternal = $inform->exp_internal(); 
            $inform->clear_accum(); 
            $inform->exp_internal(0); 
            $inform->send($self->accessPassword() . "\r"); 
            $inform->exp_internal($expInternal); 
            exp_continue(); 
        }); 
    my $result = $inform->exp_before(); 
    my $status = $inform->exitstatus(); 
    if (!defined($status) || $status) { 
        if ($status) { 
            $self->setError("Received exit status of $status for $commandString");
        } else { 
            $self->setError("Timed out after $timeout seconds for $commandString"); 
        }
        warn $self->error() if ($self->debug()); 
        return @output; 
    }
    
    for my $line (split(/\r?\n/, $result)) {
        $line =~ s|\r*$||;
        next if ($line eq ''); # clear any blanks 
        push(@output, $line);
    
        if ($self->debug() && $self->debug() >= 2) {
            print "[$line]\n";
        }

        $self->logMessage($line);
    }

    return @output;
} 

=pod

=item clearCachedResults()

Clears local caches that the class maintains to get frequently asked
for data quickly without querying the storage again.

=cut
sub clearCachedResults {
    my $self = shift;

    my @emptyList = ();

    $self->setCpgs(@emptyList);
    $self->setTemplates(@emptyList);
    $self->setAlerts(@emptyList);
    $self->setEvents(@emptyList);
    $self->setShowpd(@emptyList);
    $self->setShowpdFailed(@emptyList);
    $self->setStatpd(@emptyList);
    $self->setStatPort(@emptyList); 
    $self->setStatCmpVv(@emptyList);
    $self->setStatCmp(@emptyList);
    $self->setSummaryForNL(@emptyList);
    $self->setSummaryForFC(@emptyList);
}

=pod

=item vvCount()

Gets the number of VVs allocated on the 3par

=cut

sub vvCount {
    my $self = shift;
    my $tries = 5;

    while($tries) {
        my @output = $self->_sendCommandLocal("showvv");
        foreach my $line (@output) {
            if($line =~ /(\d+)\s+total/) {
                my $ret = $1;
                return($ret);
            }
        }
        $tries--;
        sleep 15;
    }

    return(undef);
}

=pod

=item cmdShowTemplate()

Gets a lists of templates defined on the storage and returns it as list
of template objects.

This command caches its results.

=cut

sub cmdShowTemplate {
    my $self = shift;

    # get the cache value if possible
    my $isSet = $self->templates();

    my $inservHostname = $self->hostname();

    unless ($isSet) {
        #
        #        Name Type Other Options
        #    fc_small   VV  -nro -ro -t r5 -ssz 4 -rs 4 -size 49156 -desc "Small Volume Template for FC drives"
        #    fc_large   VV  -nro -ro -t r5 -ssz 4 -rs 4 -size 251928 -desc "Large Volume Template for FC drives"
        #     bcv_cpg  CPG  -nro -ro -t r5 -ssz 6 -rs 2 -p -devtype NL -ha mag -sdgs 256000 -sdgl 256000 -desc "CPG dedicated to BCV snapshots"
        #     nl_tiny   VV  -nro -ro -t r5 -ssz 8 -rs 2 -size 14337 -p -devtype NL -ha mag -desc "Tiny Volume Template for NL drives"
        #    nl_small   VV  -nro -ro -t r5 -ssz 8 -rs 2 -size 57349 -p -devtype NL -ha mag -desc "Small Volume Template for NL drives"
        #     fc_tiny   VV  -nro -ro -t r5 -ssz 4 -rs 4 -size 12289 -desc "TIny Volume Template for FC drives"
        #B_ArchiveLog_Small   VV  -nro -ro -p -pn 0,2 -t r5 -ssz 4 -rs 4 -size 12289 -desc "Small Volume Template for B Filesystem Oracle Archive Logs"
        #C_ArchiveLog_Small   VV  -nro -ro -p -pn 1,3 -t r5 -ssz 4 -rs 4 -size 12289 -desc "Small Volume Template for B Filesystem Oracle Archive Logs"
        #B_ArchiveLog_Large   VV  -nro -ro -p -pn 0,2 -t r5 -ssz 4 -rs 4 -size 49156 -desc "Small Volume Template for B Filesystem Oracle Archive Logs"
        #C_ArchiveLog_Large   VV  -nro -ro -p -pn 1,3 -t r5 -ssz 4 -rs 4 -size 49156 -desc "Small Volume Template for B Filesystem Oracle Archive Logs"
        #    nl_large   VV  -nro -ro -t r5 -ssz 8 -rs 2 -size 258072 -p -devtype NL -ha mag -desc "Large Volume Template for NL drives"

        #
        my @output = $self->_sendCommandLocal("showtemplate");

        my @readTemplates;

        for my $line (@output) {
            $line =~ s|^\s*||;
            $line =~ s|\s*$||;

            # skip header
            next if ($line =~ m/^Name\s+/i);

            my ($name, $type, $options) = split(/\s+/, $line, 3);

            # Skip non VV type templates.  In inserv version 2.2.4, the vv type changed from upper case to lower
            next unless $type =~ m/^vv$/i;

            my $template = ariba::Ops::NetworkDevice::inserv::Container::Template->new("template-$inservHostname-$name");
            $template->setName($name);
            $template->setOptions($options);

            push(@readTemplates, $template);
        }
        # make sure you add this to clearCachedResults() too
        $self->setTemplates(@readTemplates);
    }

    my @templates = $self->templates();
    @templates = () unless (@templates && $templates[0]);

    return(@templates);
}

#
# return available (raw and usable) space in KB
#
=pod

=item showSpace(nearLine, raw)

Find out how much space is available. nearLine flag tells it if the caller
wants Fibre Channel (default) based space or Near Line (SATA) based space.

raw flag controls usable versus raw space

=cut
sub showSpace {
    my $self = shift;
    my $nearLine = shift;
    my $raw = shift;

    my @templates = $self->cmdShowTemplate();

    #
    # find the options used in templates
    #
    my $options;
    for my $template (@templates) {
        my $name = $template->name();
        if ($nearLine && $name =~ /^nl/i) {
            $options = $template->options();
            last;
        } elsif (!$nearLine && $name =~ /^fc/i) {
            $options = $template->options();
            last;
        }
    }

    #
    # form options for showspace command
    #
    $options = '' unless defined($options);
    $options =~ s|\s*-nro\s*||g;
    $options =~ s|\s*-ro\s*||g;
    $options =~ s|\s*-size\s+\d+||g;
    $options =~ s|\s*-ssz\s+\d+||g;
    $options =~ s|\s*-desc.*$||g;

    #
    #--Estimated(MB)---
    #RawFree UsableFree
    #1868800     934400
    #
    my @output = $self->_sendCommandLocal("showspace $options");

    my $factor = 1;
    my @freeSpaceTypes;
    my %freeSpace;

    for my $line (@output) {
        $line =~ s|^\s*||;
        #
        # we return space in GB, compute the factor to
        # convert reported space to GB
        #
        #--Estimated(MB)---
        if ($line =~ /^-*Estimated\((.*)\)/) {
            my $unit = $1;
            if ($unit eq "TB") {
                $factor = 1024;
            }
            if ($unit eq "GB") {
                $factor = 1;
            }
            if ($unit eq "MB") {
                $factor = 1/1024;
            }
            next;
        }

        if ($line =~ /^\d+/) {
            #1868800     934400
            my @space = split(/\s+/, $line);
            for (my $i = 0; $i < @freeSpaceTypes; $i++) {
                $freeSpace{$freeSpaceTypes[$i]} = $space[$i]*$factor;
            }
        } else {
            #RawFree UsableFree
            @freeSpaceTypes = split(/\s+/, $line);
        }

    }

    if ($raw) {
        return($freeSpace{'RawFree'});
    } else {
        return($freeSpace{'UsableFree'});
    }
}

=pod

=item rawFree(nearLine)

How much raw space is available on the array. Supply nearLine flag as
1, if SATA storage, not Fibre Channel storage, is desired.

=cut
sub rawFree {
    my $self = shift;
    my $nearLine = shift;

    return ($self->showSpace($nearLine, 1));
}

=pod

=item usableFree(nearLine)

How much usable space is available on the array. Supply nearLine flag as
1, if SATA storage, not Fibre Channel storage, is desired.

=cut
sub usableFree {
    my $self = shift;
    my $nearLine = shift;

    return ($self->showSpace($nearLine, 0));
}

sub usableFreeNew {
    my $self = shift;
    my $nearLine = shift;

    return ($self->showSpaceNew($nearLine, 0));
}

sub showSpaceNew {
    my $self = shift;
    my $nearLine = shift;
    my $raw = shift;

    ### This is done in 2 steps
    ### showcpg -sdg will show all the options like below, we'll get FC and NL options dynamically 
    ### and call 2nd api showspace <with options> 
    
    ### Sample output
    ###                 -------(MB)-------                                      
    ### Id Name          Warn   Limit  Grow Args                                 
    ### 16 auc_cpg          -  204800 65536 -t r6 -ha mag -p -devtype FC         
    ### 6 buyer_cpg        - 3072000 65536 -ssz 8 -ha cage -t r6 -p -devtype FC  
    ### 0 FC_r1            -       - 65536 -ssz 2 -ha cage -t r1 -p -devtype FC 
    ### 1 FC_r5            -       - 65536 -ssz 4 -ha cage -t r5 -p -devtype FC 
    ### 2 FC_r6            -       - 65536 -ssz 8 -ha cage -t r6 -p -devtype FC 
    ### 11 moncpg           -       - 65536 -ssz 8 -ha cage -t r6 -p -devtype FC 
    ### 3 NL_r6            -       - 65536 -ssz 6 -ha mag -t r6 -p -devtype NL  
    ### 19 rda_cpg          -  102400 65536 -t r6 -ha mag -p -devtype FC       

    my @output1 =  $self->_sendCommandLocal("showcpg -sdg");
    my $options = $self->parseShowCPGOutput(\@output1,$nearLine);
    return unless ($options);

    my $factor = 1;
    my @freeSpaceTypes;
    my %freeSpace;
    my $unit;

    my $cmd = qq(showspace $options);
    my @output = $self->_sendCommandLocal($cmd);

    ### Sample output of above command:
    ### CMD: showspace -ssz 8 -ha cage -t r6 -p -devtype FC 
    ### 
    ### --Estimated(MB)---
    ### RawFree UsableFree
    ### 3620864    2715648

    for my $line (@output) {
        $line =~ s|^\s*||;
        #
        # we return space in GB, compute the factor to
        # convert reported space to GB
        #
        #--Estimated(MB)---
        if ($line =~ /^-*Estimated\((.*)\)/) {

            $unit = $1;
            if ($unit eq "TB") {
                $factor = 1024;
            } elsif ($unit eq "GB") {
                $factor = 1;
            } elsif ($unit eq "MB") {
                $factor = 1/1024;
            }

        } elsif ($line =~ /^\d+/) {
            #1868800     934400
            my @space = split(/\s+/, $line);
            for (my $i = 0; $i < @freeSpaceTypes; $i++) {
                $freeSpace{$freeSpaceTypes[$i]} = $space[$i]*$factor . qq( $unit);
            }
        } else {
            #RawFree UsableFree
            @freeSpaceTypes = split(/\s+/, $line);
        }

    }

    if ($raw) {
        return($freeSpace{'RawFree'});
    } else {
        return($freeSpace{'UsableFree'});
    }
}

sub parseShowCPGOutput {
    my $self     = shift;
    my $output   = shift;
    my $nearLine = shift;

    ### Skip first 2 lines, just header
    my $len = @{$output};
    my %options;
    for ( my $line = 2; $line < $len; $line++ )
    {
    ### Remove leading space if any
    $output->[$line] =~ s/^\s+//g;

    my @line = split(/\s+/,$output->[$line]);
        if ( $line[1] =~ m/(FC_r6|NL_r6)/i )
    { 
            my $device_type = $line[-1];
        $options{$device_type} = join(" ", splice(@line, 5));
    }

    }
    ( $nearLine ) ? return $options{NL} : return $options{FC};
}

=pod

=item rawSpaceSummary(nearLine)

Get the summary line from showpd for a drivetype and return the interesting
values.  This command caches it's results

=cut
sub rawSpaceSummary {
    my $self = shift;
    my $nearLine = shift;

    my $drivetype = $nearLine ? "NL" : "FC";
    my $attribute = "summaryFor" . $drivetype;

    my $isSet = $self->$attribute();
    unless ($isSet) {
        my $command = "showpd -p -devtype $drivetype -space";
        my @output = $self->_sendCommandLocal($command);
        # The last line is the summary
        my $summaryLine = pop(@output);
        $summaryLine =~ s/^\s*//;
        $summaryLine =~ s/\s*$//;
        $summaryLine =~ s/\btotal\b//;  # 2.3.1 added this
        my $attribute = "setSummaryFor" . $drivetype;
        $self->$attribute($summaryLine);
    }

    return $self->$attribute(),  if($self->$attribute() =~ /No PDs listed/i); 
    my @vals = split(/\s+/, $self->$attribute());
    #       total,    used,     spare,    free  
    my $key = shift @vals;
    return @vals;

}

=pod

=item totalRawSpace(nearLine)

How much total raw disk space is on the array.  This includes spare, used 
and free chunklets.  Supply nearLine flag as 1, if SATA storage, not Fibre
Channel storage is desired.

=cut
sub totalRawSpace {
    my $self = shift;
    my $nearLine = shift;

    my @vals = $self->rawSpaceSummary($nearLine);
    my $rawInTB ;

    if (defined $vals[0] && $vals[0] =~ /\d+/){
        $rawInTB = sprintf ("%4.2f", $vals[0] / 1024 / 1024); 
    }
    else {
        $rawInTB = "Error:" . join (" ", @vals); 
    }

    return $rawInTB;
}

=pod

=item usedRawSpace(nearLine)

How much raw disk space is consumed by volumes on the array.   This includes
cpg, raid parity and volume public space.  Supply nearLine flag as 1, if SATA 
storage, not Fibre Channel storage is desired.

=cut
sub usedRawSpace {
    my $self = shift;
    my $nearLine = shift;

    my @vals = $self->rawSpaceSummary($nearLine);
    my $rawInTB ; 

    if (defined $vals[1] && $vals[1] =~ /\d+/){
        $rawInTB = sprintf ("%4.2f", $vals[1] / 1024 / 1024); 
    }
    else {
        $rawInTB = "Error:" . join (" ", @vals); 
    }

    return $rawInTB;
}

=pod

=item spareSpace(nearLine)

How much space is allocated for spares o the array.  Supply nearLine flag as 1, 
if SATA storage, not Fibre Channel storage is desired.

=cut
sub spareSpace {
    my $self = shift;
    my $nearLine = shift;

    my @vals = $self->rawSpaceSummary($nearLine);
    my $rawInTB ;

    if (defined $vals[2] && $vals[2] =~ /\d+/){
        $rawInTB = sprintf ("%4.2f", $vals[2] / 1024 / 1024); 
    }
    else {
        $rawInTB = "Error:" . join (" ", @vals); 
    }

    return $rawInTB;
}

=pod

=item cmdShowCpg()

Figure out how CPG (Common Provisioning Group) space has defined and
available on the array.

This command caches its results.

=cut
sub cmdShowCpg {
    my $self = shift;
    
    #                                     ------ SA------ ------ SD ------
    #  Id          Name Warn% TPVVs TSVVs LDs TotMB UseMB LDs  TotMB UseMB
    #   0       bcv-cpg     -     0     6   4  8192   640   2 256000 11264
    #---------------------------------------------------------------------
    #   1         total           0     6   4  8192   640   2 256000 11264

    # get the cache value if possible
    my $isSet = $self->cpgs();
    my @cpgs;
    my %cpgs;

    my $inservHostname = $self->hostname();

    unless ($isSet) {
        my @output = $self->_sendCommandLocal("showcpg");

        my $factor;
        my $sai = 6; 
        my $sdi = 9;
        for my $line (@output) {
            $line =~ s|^\s*||;
            $line =~ s|\s*$||;

            next if ($line =~ /(SA|SD|Snp|Adm)/);
            last if ($line =~ /^-+$/);

            if ($line =~ /^(?:Id\s+Name\s+Warn%\s+TPVVs\s+TDVVs\s+CPVVs\s+LDs\s+Tot\w+\s+Use\w+\s+LDs\s+Tot(\w+)\s+Use\w+)|---\((\w+)\)---/o) {
                $factor = $self->_factorForString($1 || $2);
                if ($2) {
                    $sai = 12;
                    $sdi = 10;
                }
                next;
            }
            elsif ($line =~ /^(?:Id\s+Name\s+Warn%\s+TPVVs\s+CPVVs\s+LDs\s+Tot\w+\s+Use\w+\s+LDs\s+Tot(\w+)\s+Use\w+)|---\((\w+)\)---/o) {
                $factor = $self->_factorForString($1 || $2);
                if ($2) {
                    $sai = 11;
                    $sdi = 9;
                }
                next;
            }

            next unless ($factor);

            my @vals = split(/\s+/, $line);
            next unless ($vals[0] =~ /^\d/o);

            my $name = $vals[1];
            # skip cpgs that have no allocated space 
            if ( defined($vals[$sai]) && $vals[$sai] == 0 || 
                 defined($vals[$sdi]) && $vals[$sdi] == 0 ) {
                print "'$name' cpg has no allocated SA or SD space, skipping.\n" if $self->debug();
                next;
            }
            
            my $readCpg = ariba::Ops::NetworkDevice::inserv::Container::Cpg->new("cpg-$inservHostname-$name");

            $readCpg->setName($name);
            if ( defined $vals[$sai+1] ) {
                my $percentUsedSA = $vals[$sai] ? ($vals[$sai+1]/$vals[$sai])*100 : 0; 
                $readCpg->setSATotal($vals[$sai] ? $vals[$sai]*$factor  : 0);
                $readCpg->setSAUsed($vals[$sai+1]  ? $vals[$sai+1]*$factor  : 0);
                $readCpg->setPercentUsedSA($percentUsedSA);
            }

            if ( defined $vals[$sdi+1] ){
                my $percentUsedSD = $vals[$sdi] ? ($vals[$sdi+1]/$vals[$sdi])*100 : 0; 
                $readCpg->setSDTotal($vals[$sdi] ? $vals[$sdi]*$factor  : 0);
                $readCpg->setSDUsed($vals[$sdi+1] ? $vals[$sdi+1]*$factor : 0);
                $readCpg->setPercentUsedSD($percentUsedSD);
            }


            push(@cpgs, $readCpg);
            $cpgs{$name} = $readCpg;
        }
        
        for my $type ('a', 'd') {
            @output = $self->_sendCommandLocal("showcpg -s${type}g");

            undef($factor);
            for my $line (@output) {
                $line =~ s|^\s*||;
                $line =~ s|\s*$||;

                if ($line =~ /^Id\s+Name\s+Warn\w+\s+Limit\w+\s+Grow(\w+)\s+Args|--\((\w+)\)--/) {
                    $factor = $self->_factorForString($1 || $2);
                    next;
                }
                next unless ($factor);

                my @vals = split(/\s+/, $line);
                next unless ($vals[0] =~ /^\d/o);

                # don't worry about cpgs that haven't been defined.
                next unless $cpgs{$vals[1]};

                if ($type eq 'a') {
                    $cpgs{$vals[1]}->setAdminIncrement($vals[4] ? $vals[4]*$factor : 0);
                } elsif ($type eq 'd') {
                    $cpgs{$vals[1]}->setDataIncrement($vals[4] ? $vals[4]*$factor : 0);
                }
            }
        }

        @output = $self->_sendCommandLocal("showcpg -alert");

        undef($factor);
        my $dgi;
        for my $line (@output) {
            $line =~ s|^\s*||;
            $line =~ s|\s*$||;

            if ($line =~ /^Id\s+Name\s+Warn%\s+Tot\w+\s+Warn\w+\s+Limit\w+\s+W%\s+W\s+L\s+F\s+Tot\w+\s+Warn\w+\s+Limit(\w+)|Setting\((\w+)\)/) {
                $factor = $self->_factorForString($1 || $2);
                $dgi = 5 if ($2);
                next;
            }
            next unless ($factor);

            my @vals = split(/\s+/, $line);
            next unless ($vals[0] =~ /^\d/o);

            # don't worry about cpgs that haven't been defined.
            next unless $cpgs{$vals[1]};

            if (!$dgi && defined($vals[5]) && $vals[5] ne '-') {
                $cpgs{$vals[1]}->setAdminGrowthLimit($vals[5]*$factor);
            }

            if (defined($vals[$dgi || 12]) && $vals[$dgi || 12] ne '-') {
                $cpgs{$vals[1]}->setDataGrowthLimit($vals[$dgi || 12]*$factor);
            }
        }

        # make sure you add this to clearCachedResults() too
        $self->setCpgs(@cpgs);
    }

    @cpgs = $self->cpgs();
    @cpgs = () unless (@cpgs && $cpgs[0]);

    return @cpgs;
}

sub _factorForString {
    my $self = shift;
    my $unit = shift;

    my $factor;
    #
    # we return space in GB, compute the factor to
    # convert reported space to GB
    #
    if ($unit eq "TB") {
        $factor = 1024;
    }
    if ($unit eq "GB") {
        $factor = 1;
    }
    if ($unit eq "MB") {
        $factor = 1/1024;
    }
    return $factor;
}

=pod

=item cpgNames

Get a list of all cpg spaces defined on the device

=cut

sub cpgNames {
    my $self = shift;

    my @names;

    my @cpgs = $self->cmdShowCpg();

    for my $cpg (@cpgs) {
        push (@names, $cpg->name());
    }

    return @names;
}
=pod

=item cpgPercentUsedSnapAdmin(name)

For a given CPG how much space is used in Snap Admin part of CPG space

=cut

sub cpgPercentUsedSnapAdmin {
    my $self = shift;
    my $name = shift;

    my @cpgs = $self->cmdShowCpg();

    for my $cpg (@cpgs) {
        if ($cpg->name() eq $name) {
            return $cpg->percentUsedSA();
        }
    }

    return undef;
}

=pod

=item cpgPercentUsedSnapData(name)

For a given CPG how much space is used in Snap Data part of CPG spac for a giv

=cut

sub cpgPercentUsedSnapData {
    my $self = shift;
    my $name = shift;

    my @cpgs = $self->cmdShowCpg();

    for my $cpg (@cpgs) {
        return $cpg->percentUsedSD() if $cpg->name() eq $name;
    }

    return undef;
}

=pod

=item cpgTotalIncrementSize

Calculate total space needed to increment all CPGs

=cut

sub cpgTotalIncrementSize {
    my $self = shift;

    my $totalIncrementSize = 0;
    
    for my $cpg ($self->cmdShowCpg()) {
        $totalIncrementSize += $cpg->adminIncrement() + $cpg->dataIncrement();
    }

    return $totalIncrementSize;
}

=pod

=item cpgAdminIncrementSize(name)

Size of admin increment for given CPG

=cut

sub cpgAdminIncrementSize {
    my $self = shift;
    my $name = shift;

    for my $cpg ($self->cmdShowCpg()) {
        return $cpg->adminIncrement() if $cpg->name() eq $name;
    }
    return undef;
}

=pod

=item cpgDataIncrementSize(name)

Size of data increment for given CPG

=cut

sub cpgDataIncrementSize {
    my $self = shift;
    my $name = shift;

    for my $cpg ($self->cmdShowCpg()) {
        return $cpg->dataIncrement() if $cpg->name() eq $name;
    }
    return undef;
}

=pod

=item cpgFreeDataSnapSpace(name)

Size of free data snap space

=cut

sub cpgFreeDataSnapSpace {
    my $self = shift;
    my $name = shift;

    for my $cpg ($self->cmdShowCpg()) {
        return $cpg->sDTotal() - $cpg->sDUsed() if $cpg->name() eq $name;
    }
    return undef;
}

=pod

=item cpgFreeAdminSnapSpace(name)

Size of free admin snap space

=cut

sub cpgFreeAdminSnapSpace {
    my $self = shift;
    my $name = shift;

    for my $cpg ($self->cmdShowCpg()) {
        return $cpg->sATotal() - $cpg->sAUsed() if $cpg->name() eq $name;
    }
    return undef;
}

=pod

=item cpgAllocatedAdminSnapSpace(name)

Total allocated space to admin snap

=cut

sub cpgAllocatedAdminSnapSpace {
    my $self = shift;
    my $name = shift;

    for my $cpg ($self->cmdShowCpg()){
        return $cpg->sATotal() if $cpg->name() eq $name;
    }
    return undef;
}

=pod

=item cpgAllocatedDataSnapSpace(name)

Total allocated space to data snap

=cut

sub cpgAllocatedDataSnapSpace {
    my $self = shift;
    my $name = shift;

    for my $cpg ($self->cmdShowCpg()){
        return $cpg->sDTotal() if $cpg->name() eq $name;
    }
    return undef;
}

=pod

=item cpgUsedDataSnapSpace(name)

Amount of used data snap space

=cut

sub cpgUsedDataSnapSpace {
    my $self = shift;
    my $name = shift;

    for my $cpg ($self->cmdShowCpg()){
        return $cpg->sDUsed() if $cpg->name() eq $name;
    }
    return undef;
}

=pod

=item cpgDataGrowthLimit(name)

=cut

sub cpgDataGrowthLimit {
    my $self = shift;
    my $name = shift;

    for my $cpg ($self->cmdShowCpg()){
        return $cpg->dataGrowthLimit() if $cpg->name() eq $name;
    }
    return undef;
}

=pod

=item cpgAdminGrowthLimit(name)

=cut

sub cpgAdminGrowthLimit {
    my $self = shift;
    my $name = shift;

    for my $cpg ($self->cmdShowCpg()){
        return $cpg->adminGrowthLimit() if $cpg->name() eq $name;
    }
    return undef;
}

=item cmdInservVersion

Get the inserv version number

=cut

sub cmdInservVersion {
    my $self = shift;
    
    unless ($self->version()) {
        my @output = $self->_sendCommandLocal("showversion -s");
        $self->setVersion(shift @output);
    }

    return $self->version();
}

=item cmdShowEventLog_221(duration)

Fetch all enteries in event log for the specified duration for version 2.2.1.

This command caches its results.

=cut
sub cmdShowEventLog_221 {
    my $self = shift;
    my $duration = shift || 30; # 30 mins by default

    # get the cache value if possible
    my $isSet = $self->events();
    my $inservHostname = $self->hostname();

    unless ($isSet) {
        #
        #
        #Fri Jan 27 06:56:45 PST 2006
        #Node: 3, Seq: 241811, Class: Debug, Severity: Informational, Type: CLI server process event
        #User disconnected Id:28862 User:3paradm Addr:127.0.0.1 connected since:Fri Jan 27 06:55:19 PST 2006
        #Fri Jan 27 06:56:45 PST 2006
        #Node: 3, Seq: 241812, Class: Debug, Severity: Informational, Type: CLI server process event
        #User logged in Id:28871 User:3paradm Addr:127.0.0.1

        my @output = $self->_sendCommandLocal("showeventlog -min $duration");
        my %eventlog;
        my $i = 0;
        my $j = 0;
        my $numlinesPerRecord = 3;

        my @readEvents;

        for my $line (@output) {
            #Time
            #Severity
            #Details Message (may be over 1 line)
            if ($j % $numlinesPerRecord == 0) {
                my $time = $self->convertDateToTime($line);
                if ($time) {
                    $readEvents[$i] = ariba::Ops::NetworkDevice::inserv::Container::Event->new("event-$inservHostname-$i");
                    $readEvents[$i]->setTime($time);
                } else { 
                    # line was a continuation of a details message
                    # get the previous event, tack on the message,
                    $i--; 
                    my $msg = $readEvents[$i]->message();
                    $msg .= $line;
                    $readEvents[$i]->setMessage($msg);
                    $i++;
                    $j = 2; # expect next event to be a timestamp (new event).
                }
            } elsif ($j % $numlinesPerRecord == 1) {
                my($node, $seq, $class, $severity, $type) = split(/,\s+/, $line, 5);
                $readEvents[$i]->setSeverity($severity);
                $readEvents[$i]->setDetails($line);
            } elsif ($j % $numlinesPerRecord == 2) {
                $readEvents[$i]->setMessage($line);
                $i++;
            } else {
                # unknown line, ignore
            }
            $j++;
        }
        # make sure you add this to clearCachedResults() too
        $self->setEvents(@readEvents);
    }
    my @events = $self->events();
    @events = () unless (@events && $events[0]);

    return (@events);
}

=item cmdShowEventLog_222(duration)

Fetch all enteries in event log for the specified duration for version 2.2.2*.

This command caches its results.

=cut
sub cmdShowEventLog_222 {
    my $self = shift;
    my $duration = shift || 30; # 30 mins by default

    # get the cache value if possible
    my $isSet = $self->events();
    my $inservHostname = $self->hostname();

    unless ($isSet) {
        # Inserv version 2.2.2.158 output looks like:
        # Time     : Wed Jan 16 14:54:42 PST 2008
        # Severity : Informational
        # Type     : CLI command executed
        # Message  : {3parsvc super all 172.22.1.234 11699} {filesend 3 22 /root/temp-cli-pwfile} {}

        my @output = $self->_sendCommandLocal("showeventlog -min $duration");
        my %eventlog;
        my $i = -1;
        my @readEvents;

        for my $line (@output) {
            if ($line =~ /Time\s+:\s(.*)/) {
                my $time = $self->convertDateToTime($1);
                die "Can't convert $1 to a time value: $!" if (not $time);
                $i++;
                $readEvents[$i] = ariba::Ops::NetworkDevice::inserv::Container::Event->new("event-$inservHostname-$i");
                $readEvents[$i]->setTime($time);
            } elsif ($line =~ /Severity\s+:\s(.*)/) {
                $readEvents[$i]->setSeverity("Severity: $1");
            } elsif ($line =~ /Type\s+:\s(.*)/) {
                $readEvents[$i]->setType("$1");
            } elsif ($line =~ /Message\s+:\s(.*)/) {
                $readEvents[$i]->setMessage("$1");
            } elsif ($line =~ /^\s*:(.*)/) {
                my $message = $readEvents[$i]->message() || "";
                $message .= "; " . "$1";
                $readEvents[$i]->setMessage($message);
            }
        }
        # make sure you add this to clearCachedResults() too
        $self->setEvents(@readEvents);
    }
    my @events = $self->events();
    @events = () unless (@events && $events[0]);

    return (@events);
}

sub checkVlun {
    my $self = shift;
    my $vvName = shift;
    my $host = shift;
    my $lun = shift;

    $host =~ s/\.ariba\.com$//;
    my $command = "showvlun -a -v $vvName -l $lun -host $host";
    my @output = $self->_sendCommandLocal($command);

    unless (@output) {
        print "DEBUG - checkVlun returned no output!\n" if($self->debug());
        $self->setError("Running $command on " . $self->hostname() . "failed");
        return;
    }

    if(grep(/no vluns listed/, @output)) {
        print "DEBUG - output says no vluns listed\n" if($self->debug());
        print "=======\n", join("\n", @output), "\n========\n" if($self->debug());
        return(0);
    }

    return 1;
}

sub createVlun {
    my $self = shift;
    my $vvName = shift;
    my $host = shift;
    my $lun = shift;

    $host =~ s/\.ariba\.com$//;

    # this call silently succeeds if the vlun you are asking for already
    # exists -- but if you're asking for host:vv:lun, and exactly that already
    # exists, that is probably success as far as the caller is concerned.

    my $attempts = 0;
    while($attempts < 5) {
        my @output = $self->_sendCommandLocal("createvlun -f $vvName $lun $host");
        #
        # we would check the output, but this sometimes fails in intermittent
        # transient fashion, or outright lies:
        #
        # inserv2.opslab.ariba.com cli% createvlun 0758-0 26 tansy
        # Warning: Host tansy has no active paths.  Template may be created but no active VLUNs will be created.
        # inserv2.opslab.ariba.com cli% showvlun -host tansy
        # [snip]
        # 26 0758-0 tansy 5001438006361844      1:3:1 host
        # [snip]
        #
        # instead we'll do a retry loop, and check to see if the command worked
        #
        
        ## We'll checkVlun() before checking @output text to avoid inadvertantly
        ## re-running createvlun when the first try really succeeded
        if ( $self->checkVlun($vvName, $host, $lun) ) {
            return(1);
        }

        ## Test for failure create LUN due to LUN already taken message:
        my $outputText = join ' ', @output;
        ## Error: LUN 100 is already taken
        if ( $outputText =~ m/Error: LUN (\d+) is already taken/ ){
            my $badLun = $1;
            use Carp;
            croak "LUN '$badLun' already taken";
        }

        print "DEBUG: retry create vlun....\n" if($self->debug());
        sleep(2);
        $attempts++;
    }

    return 0;
}

sub renameVV {
    my $self = shift;
    my $src = shift;
    my $dst = shift;

    if(scalar($self->cmdShowvv($dst))) {
        $self->setError("$dst already exists.");
        return;
    }

    my $command = "setvv -name $dst $src";
    my @output = $self->_sendCommandLocal($command);

    #
    # unfortunately, setvv does not provide output, so we have to just
    # check to see if the renamed vv exists
    #

    unless(scalar($self->cmdShowvv($dst))) {
        $self->setError(join("; ", "Failed to rename VV", @output));
        return;
    }

    return 1;
}

sub createSnapCopy {
    my $self = shift;
    my $src = shift;
    my $dst = shift;
    my $readOnly = shift || "";

    $readOnly = "-ro " if($readOnly);

    if(scalar($self->cmdShowvv($dst))) {
        $self->setError("$dst already exists.");
        return;
    }

    my $command = "creategroupsv ${readOnly}${src}:$dst";
    my @output = $self->_sendCommandLocal($command);

    unless (@output) {
        $self->setError("Running $command on " . $self->hostname() . "failed");
        return;
    }

    unless(scalar($self->cmdShowvv($dst))) {
        $self->setError(join("; ", @output));
        return;
    }

    return 1;
}

sub removeVV {
    my $self = shift;
    my $vvName = shift;
    
    my $command = "removevv -f $vvName";
    my @output = $self->_sendCommandLocal($command);

    unless (@output) {
        $self->setError("Running $command on " . $self->hostname() . "failed");
        return;
    }

    if(scalar($self->cmdShowvv($vvName))) {
        $self->setError(join("; ", @output));
        return;
    }

    return 1;
}

sub removeVlun {
    my $self = shift;
    my $vvName = shift;
    my $host = shift;
    my $lun = shift;

    $host =~ s/\.ariba\.com$//;
    my $command = "removevlun -f $vvName $lun $host";
    my @output = $self->_sendCommandLocal($command);

    unless (@output) {
        $self->setError("Running $command on " . $self->hostname() . "failed");
        return;
    }

    if ( $self->checkVlun($vvName, $host, $lun) ) {
        $self->setError(join("; ", @output));
        return;
    }

    return 1;
}

sub filterEventTypeFromEvents {
    my $self = shift;
    my $events = shift;
    my $filter = shift;
    
    my @filteredEvents = ();
    
    foreach my $event (@$events) {
        my $eventType = $event->type();
        push ( @filteredEvents, $event ) unless ( $eventType =~ /^${filter}$/ );
    }

    return @filteredEvents;
}

sub _eventsOfSeverity {
    my $self = shift;
    my $duration = shift;
    my $requestedSeverity = shift;

    #Time
    #Severity
    #Details
    #Message
    my $inservVersion = $self->cmdInservVersion();
    print "Inserv version: $inservVersion\n" if ($self->debug());

    # The output of showeventlog changed in from inserv version 2.2.1 to 2.2.2.
    my @events;
    if ( $inservVersion =~ /^2\.2\.1/ ) {
        @events = $self->cmdShowEventLog_221($duration);
    } else {
        @events = $self->cmdShowEventLog_222($duration);
    }

    #
    # go through all the events and pick out time and message of
    # events that match the severity level requested
    #
    my @matchedEvents;
    my $totalNumEvents = scalar(@events);

    for my $event (@events) {
        if ($event->severity() eq "Severity: $requestedSeverity") {
            push(@matchedEvents, $event);
        }
    }
    return (@matchedEvents);
}

=pod

=item majorEvents()

Get all the major events that got logged in the array event log.

=cut
sub majorEvents {
    my $self = shift;
    my $duration = shift;

    return ($self->_eventsOfSeverity($duration, 'Major'));
}

=pod

=item minorAndDegradedEvents()

Get all the minor and degraded events that got logged in the array event log.

=cut
sub minorAndDegradedEvents {
    my $self = shift;
    my $duration = shift;

    return ($self->_eventsOfSeverity($duration, 'Minor'), $self->_eventsOfSeverity($duration, 'Degraded'));
}

=pod

=item informationalEvents()

Get all the informational events that got logged in the array event log.

=cut

sub informationalEvents {
    my $self = shift;
    my $duration = shift;

    return ($self->_eventsOfSeverity($duration, 'Informational'));
}

=pod

=item cmdShowAlert_221()

Gets all the alerts that have been logged by the array for Inserv version 2.2.1.

This command caches its results.

=cut

sub cmdShowAlert_221 {
    my $self = shift;

    # get the cache value if possible
    my $isSet = $self->alerts();
    my $inservHostname = $self->hostname();

    unless ($isSet) {
        #
        #
        # Id 76 - New
        #  Message code: 0x1e0001 (1966081)
        #  Mon Jan 23 15:08:51 PST 2006
        #  Node: 2 Severity: Major
        #  Cage log event
        #  cage3, port 2:0:1 - 3:0:1 -, cage time Mon Jan 23 15:07:19 2006. Fan at position 1 has failed. Internal parameters: 0x0003 0x0142 01 02 00 00 00 00 00 00 00 00 00 00.
        # 
        # Id 77 - New
        #  Message code: 0x1e0001 (1966081)
        #  Mon Jan 23 15:08:51 PST 2006
        #  Node: 2 Severity: Degraded
        #  Cage log event
        #  cage3, port 2:0:1 - 3:0:1 -, cage time Mon Jan 23 15:07:19 2006. Power supply at position 1 voltage/temperature over limit. Internal parameters: 0x0004 0x0141 00 01 0E 00 00 00 00 00 00 00 00 00.
        #
        # Id 87 - New
        #  Message code: 0x270006 (2555910)
        #  Thu Jan 26 16:58:07 PST 2006
        #  Node: 2 Severity: Critical
        #  CPG growth limit
        #  CPG bcv-cpg SD space has reached allocation limit of 250G
        #
        # 
        # Id 89 - New
        #  Message code: 0xe000a (917514)
        #  Thu Jan 26 21:47:16 PST 2006
        #  Node: 2 Severity: Minor
        #  Task failed
        #  Task 12 (type 'vv_copy', name 'linux-ora14a-2->linux-ora14a-2-bcv') has failed with a failure code of 1. Please see task status for details.
        #
        #

        my @output = $self->_sendCommandLocal("showalert -n");
        my %alertlog;
        my $i = 0;
        my $j = 0;
        my $numlinesPerRecord = 6;
        my @readAlerts;
        for my $line (@output) {

            $line =~ s|^\s*||;
            $line =~ s|\s*$||;

            #
            # sometimes we get a record like this (note the 2nd line)
            # Id 55 - New
            #  Occurred 3 times, last at Mon Jan 23 15:04:50 PST 2006
            #  Message code: 0x1e0001 (1966081)
            #  Mon Jan 23 14:54:50 PST 2006
            #  Node: 2 Severity: Major
            #  Cage log event
            #  cage0, port 2:0:4 - 3:0:4 -, cage time Mon Jan 23 15:03:45 2006. Power supply at position 1 has failed. Internal parameters: 0x0004 0x0142 00 01 03 00 00 00 00 00 00 00 00 00.
            # 

            unless($line) {
                # Blank line signals the end of an alert -- use this method
                # because sometimes details are more than one line

                # sometimes there is more than one blank line -- only
                # increment $i on the first blank line to avoid undefs in the
                # alerts array
                ++$i unless $j == 0;
                $j = 0;
                next;
            }

            #Id
            #MessageCode
            #Time
            #Node
            #Severity
            #Summary
            #Details

            if ($j % $numlinesPerRecord == 0) {
                # someties there is a summary line, e.g. '7 alerts' at the end
                # of all the alerts. This line is separated from the rest by a
                # blank line, so it looks like the start of another alert.
                # Assume here that if a line does not begin with 'Id' it is
                # not a valid alert and should be skipped.
                if ($line =~ m|^\s*Id|) {
                    $readAlerts[$i] = ariba::Ops::NetworkDevice::inserv::Container::Alert->new("alerts-$inservHostname-$i");
                    $readAlerts[$i]->setId($line);
                } else {
                    $j = 0;
                    next;
                }
            } elsif ($j % $numlinesPerRecord == 1) {
                next if ($line =~ m|^Occurred \d+ times|);
                $readAlerts[$i]->setMessageCode($line);
            } elsif ($j % $numlinesPerRecord == 2) {
                $readAlerts[$i]->setTime($self->convertDateToTime($line));
            } elsif ($j % $numlinesPerRecord == 3) {
                $line =~ m|(Node: \d+) (Severity: \w+)|;
                my ($node, $severity) = ($1, $2);
                $readAlerts[$i]->setNode($node);
                $readAlerts[$i]->setSeverity($severity);
            } elsif ($j % $numlinesPerRecord == 4) {
                $readAlerts[$i]->setSummary($line);
            } else { # 6th line and on until next blank are details
                my $details = $readAlerts[$i]->details() || "";
                $details .= $line;
                $readAlerts[$i]->setDetails($line);
            }
            $j++;
        }
        $self->setAlerts(@readAlerts);
    }
    my @alerts = $self->alerts();
    @alerts = () unless (@alerts && $alerts[0]);

    return (@alerts);
}

=item cmdShowAlert_222()

Gets all the alerts that have been logged by the array for Inserv version 2.2.2.

This command caches its results.

=cut

sub cmdShowAlert_222 {
    my $self = shift;

    # get the cache value if possible
    my $isSet = $self->alerts();

    my $inservHostname = $self->hostname();

    unless ($isSet) {
        #
        #
        # Id          : 237
        # State       : New
        # Time        : Mon Sep 24 11:19:56 PDT 2007
        # Severity    : Critical
        # Type        : CPG growth limit
        # Message     : CPG log_cpg SD space has reached allocation limit of 128G
        #
        # Id          : 259
        # State       : New
        # Time        : Fri Oct 12 22:01:23 PDT 2007
        # Severity    : Informational
        # Type        : Eagle HW event
        # Message     : Correctable cluster memory error, need to replace DIMM
        #             : posted by node 3
        #             : MEM error reg [0x00080038] [Bnk11 SYND5 SYND4 SYND3]MEM ADDR 0x00000000754ddec0 - DIMM 2
        #             : Link 0 config reg [0x5375f2ad] [ST_BD RL_EN LN_EN LN_RS Bit22 Bit21 Bit20
        #             : Bit18 Bit16 Bit15 Bit14 Bit13 Bit12 Bit_9
        #             : Bit_7 Bit_5 Bit_3 PW_OV TR_DS]Link 0 status reg [0x5589c1e2] [Bit30 Bit28 Soft_WD_ACK Prot_Err_ACK
        #             : Parity_Err_ACK Bit19 HW_ERR SYNC_ERR
        # 
        #
        # Neither node nor MessageCode are reported in 2.2.2 output.   

        my @output = $self->_sendCommandLocal("showalert -n");
        my %alertlog;
        my $i = -1;
        my @readAlerts;
        for my $line (@output) {

            # trim off leading and trailing whitespace
            $line =~ s|^\s*||;
            $line =~ s|\s*$||;

            if ($line =~ /Id\s+:\s(.*)/) {
                $i++;
                $readAlerts[$i] = ariba::Ops::NetworkDevice::inserv::Container::Alert->new("alerts-$inservHostname-$i");
                $readAlerts[$i]->setId("$1");
            } elsif ($line =~ /^State\s+:\s(.*)/) {
                # the showalert command just grabs new alerts so this field is a noop.
            } elsif ($line =~ /^Time\s+:\s(.*)/) {
                $readAlerts[$i]->setTime($self->convertDateToTime($1));
            } elsif ($line =~ /^Severity\s+:\s(.*)/) {
                $readAlerts[$i]->setSeverity("Severity: $1");
            } elsif ($line =~ /^Type\s+:\s(.*)/) {
                # 2.2.1 didn't have headings and we labelled these messages
                # as summary, but 3par calls them type.
                $readAlerts[$i]->setSummary("$1");
            } elsif ($line =~ /^Message\s+:\s(.*)/) {
                # in 2.2.2, the first line of details is always a summary but
                # there are more lines of information in some events.  
                $readAlerts[$i]->setDetails("$1");
            } elsif ($line =~ /^\s*:\s(.*)/) {
                my $details = $readAlerts[$i]->details() || "";
                $details .= "; " . "$1";
                $readAlerts[$i]->setDetails($details);
            }
        }
        $self->setAlerts(@readAlerts);
    }
    my @alerts = $self->alerts();
    @alerts = () unless (@alerts && $alerts[0]);

    return (@alerts);
}

sub _alertsOfSeverity {
    my $self = shift;
    my $requestedSeverity = shift;

    my $inservVersion = $self->cmdInservVersion();
    print "Inserv version: $inservVersion\n" if ($self->debug());

    # The output of showalert changed in from inserv version 2.2.1 to 2.2.2.
    my @alerts;
    if ( $inservVersion =~ /^2\.2\.1/ ) {
        @alerts = $self->cmdShowAlert_221();
    } else {
        @alerts = $self->cmdShowAlert_222();
    }

    #
    # go through all the alerts and pick out id, time and details of
    # alerts that match the severity level requested
    #
    my @matchedAlerts;
    for my $alert (@alerts) {
        if ($alert->severity() eq "Severity: $requestedSeverity") {
            push(@matchedAlerts, $alert);
        }
    }
    return (@matchedAlerts);
}

=pod

=item majorAlerts()

Get all the major alerts that got logged in the array alert log.

=cut

sub majorAlerts {
    my $self = shift;

    return ($self->_alertsOfSeverity('Major'));
}

=pod

=item degradedAlerts()

Get all the degraded alerts that got logged in the array alert log.

=cut
sub degradedAlerts {
    my $self = shift;

    return ($self->_alertsOfSeverity('Degraded'));
}

=pod

=item criticalAlerts()

Get all the critical alerts that got logged in the array alert log.

=cut
sub criticalAlerts {
    my $self = shift;

    return ($self->_alertsOfSeverity('Critical'));
}

=pod

=item minorAlerts()

Get all the minor alerts that got logged in the array alert log.

=cut
sub minorAlerts {
    my $self = shift;

    return ($self->_alertsOfSeverity('Minor'));
}

=pod

=item informationalAlerts()

Get all the informational alerts that got logged in the array alert log.

=cut
sub informationalAlerts {
    my $self = shift;

    return ($self->_alertsOfSeverity('Informational'));
}

sub portParameters {
    my $self = shift;

    return $self->SUPER::portParameters() if $self->SUPER::portParameters();

    my @portCommandsToRun = ("showport", "showport -par", "showport -i");
    # showport
    # N:S:P      Mode     State ----Node_WWN---- -Port_WWN/HW_Addr- Type
    # 0:0:1 initiator     ready 2FF70002AC00031F   20010002AC00031F disk
    # 0:0:2 initiator     ready 2FF70002AC00031F   20020002AC00031F disk
    # 0:0:3 initiator     ready 2FF70002AC00031F   20030002AC00031F disk
    # 0:0:4 initiator     ready 2FF70002AC00031F   20040002AC00031F disk
    # 0:2:1    target     ready 2FF70002AC00031F   20210002AC00031F host
    # 0:2:2    target     ready 2FF70002AC00031F   20220002AC00031F host
    # 0:2:3    target loss_sync 2FF70002AC00031F   20230002AC00031F free
    # 0:2:4    target     ready 2FF70002AC00031F   20240002AC00031F host
    # showport -par
    # N:S:P ConnType CfgRate MaxRate  Class2     VCN -----------Persona------------ IntCoal
    # 0:0:1     loop    auto   2Gbps disable enabled  (0) disk, DC                  enabled
    # 0:0:2     loop    auto   2Gbps disable enabled  (0) disk, DC                  enabled
    # 0:0:3     loop    auto   2Gbps disable enabled  (0) disk, DC                  enabled
    # 0:0:4     loop    auto   2Gbps disable enabled  (0) disk, DC                  enabled
    # 0:2:1     loop    auto   4Gbps disable enabled  (1) g_ven, g_hba, g_os, 0, DC enabled
    # 0:2:2     loop    auto   4Gbps disable enabled  (1) g_ven, g_hba, g_os, 0, DC enabled
    # 0:2:3     loop    auto   4Gbps disable enabled  (1) g_ven, g_hba, g_os, 0, DC enabled
    # 0:2:4     loop    auto   4Gbps disable enabled  (1) g_ven, g_hba, g_os, 0, DC enabled
    # showport -i
    # N:S:P Brand Model  Rev Firmware   Serial          
    # 0:0:1 LSI   7004G2 02  2.00.21.00 P003360807      
    # 0:0:2 LSI   7004G2 02  2.00.21.00 P003360807      
    # 0:0:3 LSI   7004G2 02  2.00.21.00 P003360807      
    # 0:0:4 LSI   7004G2 02  2.00.21.00 P003360807      
    # 0:2:1 3PAR  FC044X 09  1.31.A.1   086988e8000d72ce
    # 0:2:2 3PAR  FC044X 09  1.31.A.1   086988e8000d72ce
    # 0:2:3 3PAR  FC044X 09  1.31.A.1   086988e8000d72ce
    # 0:2:4 3PAR  FC044X 09  1.31.A.1   086988e8000d72ce

    my $ports = {};
    for my $command (@portCommandsToRun) {
        my @output = $self->sendCommandUsingInform($command, 120);

        my @fields = ();

        for (my $i = 0; $i < @output; $i++) {

            my $line = $output[$i];

            $line =~ s|^\s*||;
            $line =~ s|\s*$||;

            if ($i == 0) {
                $line =~ s/[_:-]//g;  # get rid of the funky characters in NSP and Persona field names
                $line =~ s%/[\S]+\s% %;  # drop the /HW_Addr from showport header Port_WWN/HW_Addr
                @fields = split(/\s+/, $line);
                shift(@fields);
                next;
            }

            # match any one-or-more whitespace characters that are not immediately preceded by a ")" or a ","
            my @values = split(/(?<![),])\s+/, $line);
            my $portName = shift(@values);
            next unless ($portName =~ /^\d+:\d+:\d+$/);
            
            my $portIdentifier = $self->hostname() . '=' . $portName;

            unless ( $ports->{$portIdentifier} ) {
                my $port = ariba::Ops::NetworkDevice::inserv::Container::PortParameters->new($portIdentifier);
                $port->setName($portName);
                $ports->{$portIdentifier} = $port;
            }

            my ($node) = $portIdentifier =~ /(\d+):\d+:\d+/;
            $ports->{$portIdentifier}->setNode($node);
            
            for (my $j = 0; $j < @values; $j++) {
                $ports->{$portIdentifier}->setAttribute(lc($fields[$j]), $values[$j]);
            }
        }
    }

    my @output = $self->sendCommandUsingInform("showhost -d");
    # Id Name              -WWN/iSCSI_Name- Port  IP_addr
    #  8 chicken           210000E08B8078E3 3:4:4 n/a    
    #  8 chicken           210000E08B80BDFD 2:5:1 n/a    
    #  9 quail             210000E08B840E57 3:3:1 n/a    
    #  9 quail             210000E08B1EDD7D 2:3:1 n/a    

    for my $line (@output) {
        chomp $line;
        next unless $line =~ /^\s*\d+\s+(\S+).*\s*(\d+:\d+:\d+).*/;
        my $host = $1;
        my $portName = $2;
        my $portIdentifier = $self->hostname() . '=' . $portName;

        $ports->{$portIdentifier}->setConnectedHost($host);

    }

    return unless $ports;

    $self->SUPER::setPortParameters($ports);

    return $ports;
}

=pod

=item cmdShowVV(vvname)

Gets all the details of specified virtual volume(s). Returns a list
of objects containing those details. You can specify vvName pattern
in form of a glob experssion.

=cut
sub cmdShowvv {
    my $self = shift;
    my $vvName = shift;

    my $inservHostname = $self->hostname();
    my @vvs;
    my @output = $self->_sendCommandLocal("showvv ${vvName}", $LONG_TIMEOUT);

    # Id               Name      Type      CopyOf BsId Rd   State AdmMB SnapMB  userMB
    # 384              0001-0 Base    ---  384 RW started     0      0   51456
    # 385              0002-0 Base    ---  385 RW started     0      0   51456
    # 390              0003-0 Base    ---  390 RW started     0      0   10240
    # 391              0004-0 Base    ---  391 RW started     0      0   10240
    # ----------------------------------------------------------------------
    #   6      total LD                                      0      0 308736
    #     total virtual                                      -      - 308736


    my @fields;

    my $kAdjustment = 1;
    for (my $i = 0; $i < @output; $i++) {
        my $line = $output[$i];

        $line =~ s|^\s*||;
        $line =~ s|\s*$||;

        #
        # Return right away if we dont find the specified vv
        #
        if ( $line =~ /no vv listed/ ) {
            return @vvs;
        }

        next if ($line =~ /\bRsvd\b/o);
        last if ($line =~ /^---/);

        # header
        #
        # Id
        # Name
        # Type
        # CopyOf
        # BsId
        # Rd
        # State
        # AdmMB
        # SnapMB
        # userMB
        #

        unless (@fields) {
            # Rename 2.3.1 names to be the same as 2.2.4
            $line =~ s/-+Policies-+/Policies/;
            if ($i == 1) {
                my %newNames = (
                    '-Detailed_State-'  => 'State',
                    'Adm'               => 'AdmMB',
                    'Snp'               => 'SnapMB',
                    'Usr'               => 'UserMB', 
                );
                foreach my $oldName (keys %newNames) {
                    my $newName = $newNames{$oldName}; 
                    $line =~ s/$oldName/$newName/;
                }
                $kAdjustment = 2;
            }
            @fields = split(/\s+/, $line);
            next;
        }

        my @values = split(/\s+/, $line);
        my $k = $i - $kAdjustment;
        my $vv = ariba::Ops::NetworkDevice::inserv::Container::VirtualVolume->new("VV-$inservHostname-$vvName-$k");
        $vvs[$k] = $vv;

        for (my $j = 0; $j < @values; $j++) {
            $vv->setAttribute(lcfirst($fields[$j]), $values[$j]);
        }
    }

    return @vvs;
}

sub cmdShowVvPd {
    my $self = shift;
    my $vvName = shift;

    my $inservHostname = $self->hostname();
    my @vvpds;
    my @output = $self->_sendCommandLocal("showvvpd ${vvName}");

    # inserv.opslab.ariba.com cli% showvvpd 0091-10
    #  Id Cage_Pos SA  SD  usr total
    #   0    0:0:0  0   0    0     0
    #   1    0:0:1  0   0    0     0
    # ...
    # 319    7:9:3  0   0    0     0
    # 320    0:7:2  0   0    0     0
    # ------------------------------
    # 320    total 12 440 1348  1800

    my @fields;

    for (my $i = 0; $i < @output; $i++) {

        my $line = $output[$i];

        $line =~ s|^\s*||;
        $line =~ s|\s*$||;

        #
        # Return right away if we dont find the specified vv
        #
        if ( $line =~ /no volumes matching/ ) {
            return @vvpds;
        }

        last if ($line =~ /^---/);

        # header
        #
        # Id
        # Cage_Pos
        # SA
        # SD
        # usr
        # total
        #
        if ($i == 0) {
            @fields = split(/\s+/, $line);
            next;
        }

        my @values = split(/\s+/, $line);
        my $k = $i - 1;
        my $vvpd = ariba::Ops::NetworkDevice::inserv::Container::VvPds->new("vvpds-$inservHostname-$k");
        $vvpds[$k] = $vvpd;

        for (my $j = 0; $j < @values; $j++) {
            $vvpd->setAttribute(lc($fields[$j]), $values[$j]);
        }
    }

    return @vvpds;
}

sub cmdShowVvsForPolicy {
    my $self = shift;
    my $policy = shift;

    my @vvsWithPolicy = ();

    # grab policy information for all VV's
    my @vvs = $self->cmdShowPolicyForVv('*');

    # check each VV to see if it matches the policy of interest
    foreach my $vv (@vvs) {
        my @vvPolicies = split(',', $vv->policies());

        foreach my $vvPolicy (@vvPolicies) {

            if ($vvPolicy eq $policy) {
                push(@vvsWithPolicy, $vv->name());
                last;
            }
        }
    }

    # return a list of VV names that have a particular policy set
    return @vvsWithPolicy;
}

sub cmdShowPolicyForVv {
    my $self = shift;
    my $vv = shift;
    
    my $policyFlag = ($self->cmdInservVersion() eq '2.2.4') ?  '-p' : '-pol';
    my @vvs = $self->cmdShowvv("$policyFlag $vv");

    return @vvs;
}

sub cmdSetPolicyForVv {
    my $self = shift;
    my $vv = shift;
    my $policy = shift;

    my @output = $self->_sendCommandLocal("setvv -pol $policy $vv");

    return @output;
}

sub cmdShowBasevvForCpg {
    my $self = shift;
    my $cpgName = shift;

    my @vvs = $self->cmdShowvv("-cpg $cpgName");
    my @baseVvs = ();

    for my $vv (@vvs) {
        next unless $vv->type() =~ /base/i;
        push(@baseVvs, $vv);
    }

    return @baseVvs;
}

=pod

=item cmdShowLd(vvname)

Get logical disks details for a specified virtual volume. Returns a list
of objects containing those details. You can specify vvName pattern
in form of a glob experssion.

=cut
sub cmdShowLd {
    my $self = shift;
    my $vvName = shift;

    my $inservHostname = $self->hostname();
    my @lds;
    my @output = $self->_sendCommandLocal("showld -vv ${vvName}");

    # showld -vv 0094-*
    #  Id         Name RAID  State Own SizeMB UsedMB Use Lgct LgId WThru MapV
    # 524 0094-0.usr.0    5 normal 2/3  28672  28672   V    0  ---     N    Y
    # 525 0094-0.usr.1    5 normal 3/2  28672  28672   V    0  ---     N    Y
    # 526 0094-0.usr.2    5 normal 3/2   1792    256   V    0  ---     N    Y
    # 527 0094-1.usr.0    5 normal 2/3  28672  28672   V    0  ---     N    Y
    # 528 0094-1.usr.1    5 normal 2/3   1792    256   V    0  ---     N    Y
    # 529 0094-1.usr.2    5 normal 3/2  28672  28672   V    0  ---     N    Y
    # 530 0094-2.usr.0    5 normal 2/3  28672  28672   V    0  ---     N    Y
    # 531 0094-2.usr.1    5 normal 3/2  28672  28672   V    0  ---     N    Y
    # 532 0094-2.usr.2    5 normal 3/2   1792    256   V    0  ---     N    Y
    # 871 0094-3.usr.0    5 normal 2/3  28672  28672   V    0  ---     N    Y
    # 872 0094-3.usr.1    5 normal 2/3   1792    256   V    0  ---     N    Y
    # 873 0094-3.usr.2    5 normal 3/2  28672  28672   V    0  ---     N    Y
    # 874 0094-4.usr.0    5 normal 2/3  28672  28672   V    0  ---     N    Y
    # 875 0094-4.usr.1    5 normal 3/2  28672  28672   V    0  ---     N    Y
    # 876 0094-4.usr.2    5 normal 3/2   1792    256   V    0  ---     N    Y
    # 877 0094-5.usr.0    5 normal 2/3  28672  28672   V    0  ---     N    Y
    # 878 0094-5.usr.1    5 normal 3/2  28672  28672   V    0  ---     N    Y
    # 879 0094-5.usr.2    5 normal 3/2   1792    256   V    0  ---     N    Y
    # 880 0094-6.usr.0    5 normal 2/3  28672  28672   V    0  ---     N    Y
    # 881 0094-6.usr.1    5 normal 2/3   1792    256   V    0  ---     N    Y
    # 882 0094-6.usr.2    5 normal 3/2  28672  28672   V    0  ---     N    Y
    # 883 0094-7.usr.0    5 normal 2/3  28672  28672   V    0  ---     N    Y
    # 884 0094-7.usr.1    5 normal 2/3   1792    256   V    0  ---     N    Y
    # 885 0094-7.usr.2    5 normal 3/2  28672  28672   V    0  ---     N    Y
    # -----------------------------------------------------------------------
    # 24                              473088 460800                         




    my @fields;

    for (my $i = 0; $i < @output; $i++) {

        my $line = $output[$i];

        $line =~ s|^\s*||;
        $line =~ s|\s*$||;

        #
        # Return right away if we dont find the specified vv
        #
        if ( $line =~ /no lds listed/ ) {
            return @lds;
        }

        last if ($line =~ /^---/);

        # header
        #
        # Id
        # Name
        # RAID
        # State
        # Own
        # SizeMB
        # UsedMB
        # Use
        # Lgct
        # LgId
        # WThru
        # MapV
        #
        if ($i == 0) {
            $line =~ s|RAID|raid|;
            $line =~ s/-Detailed_State-/State/; # 2.3.1

            @fields = split(/\s+/, $line);
            next;
        }

        my @values = split(/\s+/, $line);
        my $k = $i - 1;
        my $id = $values[0];
        my $ld = ariba::Ops::NetworkDevice::inserv::Container::LogicalDisk->new("$inservHostname-$id");
        $lds[$k] = $ld;

        for (my $j = 0; $j < @values; $j++) {
            $ld->setAttribute(lcfirst($fields[$j]), $values[$j]);
        }
    }

    return @lds;
}

=pod

=item cmdShowLdch(vvname)

Get chunklet mapping for a logical disk.

=cut
sub cmdShowLdch {
    my $self = shift;
    my $ldName = shift;

    my @chunklets;
    my @output = $self->_sendCommandLocal("showldch  ${ldName}");

    my $inservHostname = $self->hostname();

    # showldch 0094-5.usr.0
    # Ldch Row Set PdPos Pdid Pdch  State Usage Media Sp From  To
    #    0   0   0 0:8:2   58 1003 normal    ld valid  N  --- ---
    #    1   0   0 1:8:2   62 1003 normal    ld valid  N  --- ---
    #    2   0   0 2:8:0   32  470 normal    ld valid  N  --- ---
    #    3   0   0 3:8:0   48  470 normal    ld valid  N  --- ---
    #    4   0   0 2:9:0   36  472 normal    ld valid  N  --- ---
    #    5   0   0 3:9:0   52  470 normal    ld valid  N  --- ---
    #    6   0   0 0:9:2   10  470 normal    ld valid  N  --- ---
    #    7   0   0 1:9:2   22  470 normal    ld valid  N  --- ---
    #    8   0   1 0:8:0   56 1003 normal    ld valid  N  --- ---

    my @fields;

    for (my $i = 0; $i < @output; $i++) {

        my $line = $output[$i];

        $line =~ s|^\s*||;
        $line =~ s|\s*$||;

        #
        # Return right away if we dont find the specified vv
        #
        if ( $line =~ /Invalid ld name/ ) {
            return @chunklets;
        }

        # header
        #
        # Ldch
        # Row
        # Set
        # PdPos
        # Pdid
        # Pdch
        # State
        # Usage
        # Media
        # Sp
        # From
        # To
        #
        if ($i == 0) {
            @fields = split(/\s+/, $line);
            next;
        }

        my @values = split(/\s+/, $line);
        my $k = $i - 1;
        my $chid = $values[0];
        my $chunklet = ariba::Ops::NetworkDevice::inserv::Container::Chunklet->new("$inservHostname-$chid-$ldName");
        $chunklets[$k] = $chunklet;

        for (my $j = 0; $j < @values; $j++) {
            $chunklet->setAttribute(lcfirst($fields[$j]), $values[$j]);
        }
    }

    return @chunklets;
}

=pod

=item isVirtualVolume(vvName)

Does a virtual volume with specified name exist on the array?

=cut
sub isVirtualVolume {
    my $self   = shift;
    my $vvName = shift;

    return($self->cmdShowvv($vvName));
}

#
# return all virtual volumes
#
=pod

=item virtualVolumesPrefix(vvNamePrefix)

Return a list of details of virtual volumes that match the
specified prefix.

=cut
sub virtualVolumesWithPrefix {
    my $self = shift;
    my $vvNamePrefix = shift;

    my @matchedVvs;

    #
    # Id
    # Name
    # Type
    # CopyOf
    # BsId
    # Rd
    # State
    # AdmMB
    # SnapMB
    # userMB
    #
    my @vvs = $self->cmdShowvv("${vvNamePrefix}*");

    return @matchedVvs unless(@vvs);

    my $numVvs = scalar(@vvs);

    for my $vv (@vvs) {
        my $name = $vv->name();

        if ($name =~ /^${vvNamePrefix}-\d+$/) {
            push(@matchedVvs, $vv);
        }
    }

    return @matchedVvs;
}

=pod

=item virtualVolumesByName(vvName)

Return a list of details of virtual volumes that match a specified name

=cut

sub virtualVolumesByName {
    my $self = shift;
    my $vvName = shift;

    my @matchedVvs;

    #
    # Id
    # Name
    # Type
    # CopyOf
    # BsId
    # Rd
    # State
    # AdmMB
    # SnapMB
    # userMB
    #
    my @vvs = $self->cmdShowvv("${vvName}");

    return @matchedVvs unless(@vvs);

    my $numVvs = scalar(@vvs);

    for my $vv (@vvs) {
        my $name = $vv->name();

        if ($name eq $vvName) {
            push(@matchedVvs, $vv);
        }
    }

    return @matchedVvs;
}

sub _physicalCopyVolumeNameForId {
    my $self = shift;
    my $vvName   = shift;
    my $physicalCopyId = shift;

    #
    # If the name is that of a snap copy volume, get the name of
    # the real volume
    #
    if ($vvName =~ m|^$snapCopyPrefix|) {
        my ($scName, $newVvName) = split(/\-/, $vvName, 2);
        $vvName = $newVvName;
    }

    #
    # pc#-xxxx
    #
    my $physicalCopyVv = "${physicalCopyPrefix}${physicalCopyId}-${vvName}";

    return $physicalCopyVv;
}

sub _snapRWCopyVolumeNameForId {
    my $self = shift;
    my $vvName   = shift;
    my $snapCopyId = shift;

    return ($self->_snapCopyVolumeNameForId($vvName, $snapCopyId));
}

sub _snapROCopyVolumeNameForId {
    my $self = shift;
    my $vvName   = shift;
    my $snapCopyId = shift;

    return ($self->_snapCopyVolumeNameForId($vvName, $snapCopyId, 1));
}

sub _snapCopyVolumeNameForId {
    my $self = shift;
    my $vvName   = shift;
    my $snapCopyId = shift;
    my $readOnly = shift;

    #
    # If the name is that of a snap copy volume, get the name of
    # the real volume
    #
    if ($vvName =~ m|^$snapCopyPrefix|) {
        my ($scName, $newVvName) = split(/\-/, $vvName, 2);
        $vvName = $newVvName;
    }

    #
    # scro#-xxxx or scrw#-xxxx
    #
    my $snapCopyVv;
    if ($readOnly) {
        $snapCopyVv = "${snapROCopyPrefix}${snapCopyId}-${vvName}";
    } else {
        $snapCopyVv = "${snapRWCopyPrefix}${snapCopyId}-${vvName}";
    }

    return $snapCopyVv;
}

sub _isEqualVirutalVolumeCountForPrimayAndCopyVolume {
    my $self = shift;
    my $vvName   = shift;
    my $copyId = shift || 1; # Assume atleast one physical copy
    my $physicalCopy = shift || 1; # Assume physical copy
    my $readOnly = shift || 1; # Needed only for snap copy volumes

    my $copyVv;

    if ($physicalCopy) {
        $copyVv = $self->_physicalCopyVolumeNameForId($vvName, $copyId);
    } else {
        $copyVv = $self->_snapCopyVolumeNameForId($vvName, $copyId, $readOnly);
    }

    my @primaryVvs = $self->virtualVolumesWithPrefix($vvName);
    my @copyVvs = $self->virtualVolumesWithPrefix($copyVv);

    return (scalar(@primaryVvs) == scalar(@copyVvs));
}

=pod

=item isEqualVirutalVolumeCountForPrimayAndPhysicalCopy(vvName, copyId)

Are number of luns specified for source and physcial copy volumes equal?

=cut
sub isEqualVirutalVolumeCountForPrimayAndPhysicalCopy {
    my $self = shift;
    my $vvName   = shift;
    my $physicalCopyId = shift || 1; # Assume atleast one physical copy

    return ($self->_isEqualVirutalVolumeCountForPrimayAndCopyVolume($vvName, $physicalCopyId));

}

=pod

=item isEqualVirutalVolumeCountForPrimayAndSnapROCopy(vvName, copyId)

Are number of luns specified for source and snap readonly copy
volumes equal?

=cut
sub isEqualVirutalVolumeCountForPrimayAndSnapROCopy {
    my $self = shift;
    my $vvName   = shift;
    my $snapCopyId = shift || 1; # Assume atleast one physical copy

    return ($self->_isEqualVirutalVolumeCountForPrimayAndCopyVolume($vvName, $snapCopyId, 0, 1));

}

=pod

=item isEqualVirutalVolumeCountForPrimayAndSnapRWCopy(vvName, copyId)

Are number of luns specified for source and snap read-write copy
volumes equal?

=cut
sub isEqualVirutalVolumeCountForPrimayAndSnapRWCopy {
    my $self = shift;
    my $vvName   = shift;
    my $snapCopyId = shift || 1; # Assume atleast one physical copy

    return ($self->_isEqualVirutalVolumeCountForPrimayAndCopyVolume($vvName, $snapCopyId, 0, 0));

}

=pod

=item chunkletsForVirtualVolume(vvName)

Get a list of chunklets that a virtual volume lives on

=cut
sub chunkletsForVirtualVolume {
    my $self = shift;
    my $vvName   = shift;

    my @chunklets;

    my @lds = $self->cmdShowLd($vvName);

    for my $ld (@lds) {
        my $ldName = $ld->name();
        next unless ($ldName =~ m|\.usr\.|);
        push(@chunklets, $self->cmdShowLdch($ldName));
    }

    return (@chunklets);
}

=pod

=item virtualVolumesSharedPhysicalDisks(vvArrayRef1, vvArrayRef2)

Given two sets of virtual volumes find out which virtual volumes share
a common disk.

=cut
sub virtualVolumesSharedPhysicalDisks {
    my $self = shift;
    my $vvArrayRef1   = shift;
    my $vvArrayRef2   = shift;

    my $inservHostname = $self->hostname();
    #
    # Get physical disk position for both set of chunklets
    #
    my %phyDiskPos1;
    for my $vvName (@$vvArrayRef1) {
        for my $chunklet ($self->chunkletsForVirtualVolume($vvName)) {
            $phyDiskPos1{$chunklet->pdPos()} = $vvName;
        }
    }
    my %phyDiskPos2;
    for my $vvName (@$vvArrayRef2) {
        for my $chunklet ($self->chunkletsForVirtualVolume($vvName)) {
            $phyDiskPos2{$chunklet->pdPos()} = $vvName;
        }
    }

    #
    # make sure there are no common physical disk position. If a common
    # disk is found record the name of the two volumes that share
    # the disk.
    #
    my @sharedPds;
    for my $pdpos (keys(%phyDiskPos1)) {
        if ($phyDiskPos2{$pdpos}) {
            my $vv1 = $phyDiskPos1{$pdpos};
            my $vv2 = $phyDiskPos2{$pdpos};
            my $sharedPd = ariba::Ops::NetworkDevice::inserv::Container->new("shared-$inservHostname-$vv1-$vv2-$pdpos");

            $sharedPd->setVirtualVolume1($vv1);
            $sharedPd->setVirtualVolume2($vv2);
            $sharedPd->setPhysicalPosition($pdpos);

            push(@sharedPds, $sharedPd);
        }
    }

    return @sharedPds;
}

sub cpgMapForVVPattern {
    my $self = shift;
    my $pattern = shift || '';
    my $returnAll = shift;
    my $ret = {};

    my $cmd = "showvv -cpgalloc $pattern";
    my @output = $self->_sendCommandLocal($cmd, $LONG_TIMEOUT);

    #  Id Name                                             Prov Type  UsrCPG                    SnpCPG           
    #3428 0002-0                                           full base  --                        --               
    #3456 0004-0                                           full base  --                        --               
    #3464 0004-1                                           full base  --                        --               
    # 776 0005-0                                           cpvv base  --                        opslab_cpg       
        
    foreach my $line (@output) {
        if($line =~ /^\s*(\d+)\s+([^\s]+)\s+([^\s]+)\s+([^\s]+)\s+([^\s]+)\s+([^\s]+)/) {
            my $id = $1;
            my $vvname = $2;
            my $type = $3;
            my $prov = $4;
            my $usrCpg = $5;
            my $snpCpg = $6;

            $ret->{$vvname}->{'snpCpg'} = $snpCpg if ( $snpCpg ne '--' || $returnAll );
            $ret->{$vvname}->{'usrCpg'} = $usrCpg if ( $usrCpg ne '--' || $returnAll );
        }
    }

    return($ret);
}

sub createThinProvisionedVVFromCPGs {
    my $self = shift;
    my $vvname = shift;
    my $usrCpg = shift;

    if(scalar($self->cmdShowvv($vvname))) {
        $self->setError("$vvname already exists.");
        return(0);
    }

    my $cmd = "createvv -tpvv $usrCpg $vvname 2000g";
    my @output = $self->_sendCommandLocal($cmd, $LONG_TIMEOUT);

    unless(scalar($self->cmdShowvv($vvname))) {
        $self->setError(join("; ", @output));
        return(0);
    }

    return(1);
}

sub physicalCopyForVirtualVolumes {
    my $self = shift;
    my $cpRef = shift;
    my $logger = shift;

    my @taskIds = ();
    my $returnCode = 1;

    foreach my $src (sort(keys(%$cpRef))) {
        my $dst = $cpRef->{$src};
        my $cmd = "createvvcopy -p $src $dst";

        my @output = $self->_sendCommandLocal($cmd, $LONG_TIMEOUT);

        # inserv2.opslab.ariba.com cli% createvvcopy -p 0758-0 jbm-cptest-vv
        # Copy was started. child = jbm-cptest-vv, parent = 0758-0, task ID = 7191
        # inserv2.opslab.ariba.com cli%

        foreach my $line (@output) {
            if ($line =~ /Error/) {
                $returnCode = 0;
                last;
            }
            if ($line =~ /^Copy was \w+. child.*task ID = (\d+)/) {
                my $taskId = $1;
                push(@taskIds, $taskId);
            }
        }
    }

    #
    # make sure we got one task per copy
    #
    if(scalar(@taskIds) != scalar(keys(%$cpRef))) {
        $returnCode = 0;
    }

    my $successfulTaskIdsRef = $self->_waitForTasksToComplete(\@taskIds, $logger);

    #
    # and make sure all requested tasks are successful
    #
    if (scalar(@$successfulTaskIdsRef) != scalar(@taskIds)) {
        $returnCode = 0;
    }

    return $returnCode;
}

sub promoteSnapCopyForVirtualVolumes {
    my $self = shift;
    my $vvsRef = shift;
    my $vcId = shift;
    my $logger = shift;

    my @vvs = @$vvsRef;
    my @taskIds = ();
    my $returnCode = 1;

    my @output = ();
    for my $vv (@vvs) {
        my $vvName = $vv->name();
        my $scROVvName = $self->_snapROCopyVolumeNameForId($vvName, $vcId);
        @output = $self->_sendCommandLocal("promotesv -target $vvName $scROVvName", $LONG_TIMEOUT);

        # Task 778 has been started to promote virtual copy scro0-rich-test-0
        foreach my $line (@output) {
            if ($line =~ /Error/) {
                $returnCode = 0;
                last;
            }
            if ($line =~ /^Task (\d+) has been started/) {
                my $taskId = $1;
                push(@taskIds, $taskId);
            }
        }
    }

    my $successfulTaskIdsRef = $self->_waitForTasksToComplete(\@taskIds, $logger);

    if (scalar(@$successfulTaskIdsRef) != scalar(@taskIds)) {
        $returnCode = 0;
    }

    return $returnCode;
}

=pod

=item makeSnapCopyForVirtualVolumes(vvs, copyId, readonly)

Makes a snap copy of specified virtual volume(s) (passed as array ref).
Id is the copy# and readonly flag specifies if a readonly or read-write
copy is desired.

It deletes existing snap copy with the same #, before creating a new
one.

=cut
sub makeSnapCopyForVirtualVolumes {
    my $self = shift;
    my $vvsRef  = shift;
    my $vcId = shift;
    my $readOnly = shift;

    my $returnCode = 1;

    my %snapROVvs;
    my %snapRWVvs;

    my @vvs = @$vvsRef;

    for my $vv (@vvs) {

        my $vvName = $vv->name();
        my $scROVvName = $self->_snapROCopyVolumeNameForId($vvName, $vcId);
        my $scRWVvName = $self->_snapRWCopyVolumeNameForId($vvName, $vcId);
        $snapROVvs{$scROVvName} = "$vvName:$scROVvName";
        $snapRWVvs{$scRWVvName} = "$scROVvName:$scRWVvName";
    }


    #
    # First make a RO copy, then RW copy of that RO copy, if requested
    # Need to delete any existing snap copy first
    #
    unless($self->removeSnapCopyForVirtualVolumes($vvsRef, $vcId)) {
        return 0;
    }

    my @output = ();

    foreach my $vv (keys %snapROVvs) {
        $snapROVvs{$vv} =~ s/(.*)\:(.*)/$2 $1/;
        @output = $self->_sendCommandLocal("createsv -ro $snapROVvs{$vv}", $LONG_TIMEOUT);
        $returnCode = scalar(@output) > 0 ? 0 : 1;
        last unless $returnCode;
    }

    unless ($readOnly) {
        my $snapROVvToSnapRWVv = join(" ", values(%snapRWVvs));
        foreach my $vv (keys %snapRWVvs) {
            $snapRWVvs{$vv} =~ s/(.*)\:(.*)/$2 $1/;
            @output = $self->_sendCommandLocal("createsv $snapRWVvs{$vv}", $LONG_TIMEOUT);
            $returnCode = scalar(@output) > 0 ? 0 : 1;
            last unless $returnCode;
        }
    }

    return $returnCode;
}

=pod

=item removeSnapCopyForVirtualVolumes(vvs, copyId)

Delete a snap copy of specified virtual volume(s) (passed as array ref).
Id is the copy#

returns 1 on success, 0 on failure

=cut

sub removeSnapCopyForVirtualVolumes
{
    my $self = shift;
    my $vvsRef  = shift;
    my $vcId = shift;

    my @vvs = @$vvsRef;
    my %snapROVvs;
    my %snapRWVvs;

    for my $vv (@vvs) {

        my $vvName = $vv->name();
        my $scROVvName = $self->_snapROCopyVolumeNameForId($vvName, $vcId);
        my $scRWVvName = $self->_snapRWCopyVolumeNameForId($vvName, $vcId);
        $snapROVvs{$scROVvName} = "$vvName:$scROVvName";
        $snapRWVvs{$scRWVvName} = "$scROVvName:$scRWVvName";
    }

    # delete any existing snap copy first
    my @output = ();

    #
    # remove RW snap copy (if any) before removing the RO snap
    #
    for my $snapVv (keys(%snapRWVvs), keys(%snapROVvs)) {
        if ($self->isVirtualVolume($snapVv)) {
            @output = $self->_sendCommandLocal("removevv -f $snapVv", $LONG_TIMEOUT);
        }
    }

    my $success = 1;
    for my $line (@output) {
        if ($line =~ /Attempt to delete (rw|ro) vol/) {
            $success = 0;
            last;
        }
    }

    return $success;
}

#
# copy virtual volumes to their corresponding bcv virtual volumes
#
=pod

=item makePhysicalCopyForVirtualVolumes(vvs, copyId, full, fromSnap)

Makes a physical copy of specified virtual volume(s) (passed as array ref).
Id is the copy#. Full means do a full copy, as opposed to incremental.
FromSnap means use a previous snapcopy as the source, instead of the real
virtual volume. With the existing 3par firmware, we can only get consitent
physical copy from a snapcopy. Future versions of the firmware will fix
that.

=cut
sub makePhysicalCopyForVirtualVolumes {
    my $self = shift;
    my $vvsRef  = shift;
    my $copyId = shift;
    my $incremental = shift;   # true for an incremental copy, false for a full physical copy

    my @output = ();
    my @taskIds = ();
    my $returnCode = 1;
    my @vvNames =  map($_->name(), @$vvsRef);

    if ($incremental) {
        my @pcVvsWithResyncSnapshot = ();
        my @vvs = $self->cmdShowvv("@vvNames");

        #
        # We need to verify there is resync snapshot associated with each VV:PCVV relationship.
        # Resync snapshots have the form of 'vvcp.{VV_Id}.{PCVV_Id}'. If any resync snapshots
        # are missing we cannot do an incremental physical copy.
        #
        for my $vv (@vvs) {
            my $vvName = $vv->name();
            my $vvId = $vv->id();
            my $pcVvName = $self->_physicalCopyVolumeNameForId($vvName, $copyId);
            my @pcVv = $self->cmdShowvv($pcVvName);
            
            unless (@pcVv && scalar(@pcVv)) {
                my $msg = "Can't find physical copy (pc) volume for $vvName\n";
                print $msg if $self->debug();
                $self->setError($msg);
                $returnCode = 0;
                last;
            }

            my $pcVvId = $pcVv[0]->id();
            print "VV: [$vvName]  VVID: [$vvId]  PCVV: [$pcVvName]  PCVVID: [$pcVvId]\n" if ($self->debug());

            # Resync snapshots have the form of "vvcp.{sourceVvID}.{targetVvID}":
            # % showvv vvcp*
            #   Id           Name Type CopyOf BsId Rd   State AdmMB SnapMB userMB
            #   3755 vvcp.5759.5749 SnCp 0238-0 5759 RO started     -      -  12544
            #   3756 vvcp.5760.5750 SnCp 0238-1 5760 RO started     -      -  12544

            my $vvcp = "vvcp.${vvId}.${pcVvId}";
            my @vvcps = $self->cmdShowvv("${vvcp}*");

            if (@vvcps > 0) {
                my $vvcpName = $vvcps[0]->name();
                my $vvcpBsId = $vvcps[0]->bsId();
                print "VVCP [$vvcp]  VVCPNAME [$vvcpName]  VVCPBSID [$vvcpBsId]\n" if ($self->debug());

                # Resync snapshot names will alternate and have a '.2' appended to them half the time.
                if ($vvcpName =~ /vvcp\.${vvId}\.(${pcVvId})(\.2)?/) {
                    my $vvcpTarget = $1;

                    if ( ($vvcps[0]->bsId() eq $vvId) && ($vvcpTarget eq $pcVvId) ) {

                        if ($self->debug()) {
                            print "Found resync snapshot [$vvcpName] for source [$vvName]($vvId) ",
                                      "and target [$pcVvName]($pcVvId).\n";
                        }

                        push( @pcVvsWithResyncSnapshot, $pcVvName);
                    }
                }
            }
        }

        my $vvsCount = scalar(@vvs);
        my $pcVvsCount = scalar(@pcVvsWithResyncSnapshot);
        if ( $vvsCount != $pcVvsCount ) {
            my $msg = "Error: pcVvsWithResyncSnapshot count does not match vvs count. # of VVs is $vvsCount and # of pc1-Vvs With Resync Snapshot is $pcVvsCount"; 
            print "$msg\n" if ($self->debug());
            $self->setError($msg) unless ($self->error());
            $returnCode = 0;
        } else {
            @output = $self->_sendCommandLocal("creategroupvvcopy -r @pcVvsWithResyncSnapshot", $LONG_TIMEOUT);
        }
    }
    else { # full physical copy
        my $vvsToPcs = '';

        # run physical copy using "creategroupvvcopy -p -s vv1:pc1 vv2:pc2 vv3:pc3 ..."
        for my $vvName (@vvNames) {
            my $pcVvName = $self->_physicalCopyVolumeNameForId($vvName, $copyId);
            $vvsToPcs .= "${vvName}:${pcVvName} ";
        }

        chop($vvsToPcs);
        @output = $self->_sendCommandLocal("creategroupvvcopy -p -s $vvsToPcs", $LONG_TIMEOUT);
    }

    # output:
    #
    # Physical copy:
    # % creategroupvvcopy -p -s 0238-0:pc1-0238-0 0238-1:pc1-0238-1
    #     Child Parent Status TaskID
    # pc1-0238-0 0238-0 queued   7899
    # pc1-0238-1 0238-1 queued   7900
    #
    ####### pc-* volume is missing error
    #inserv3.us1.ariba.com cli% creategroupvvcopy -p -s 2166-0:pc1-2166-0
    # VV pc1-2166-0 not found
    #
    # Incremental physical copy:
    # % creategroupvvcopy -r pc1-0238-0 pc1-0238-1
    #      Child Parent  Status TaskID
    # pc1-0238-0        started   7901
    # pc1-0238-1        started   7902

    foreach my $line (@output) {
        if ($line =~ /Error|not found/) {
            print "creategroupvvcopy: $line\n" if ($self->debug()); 
            $self->setError("creategroupvvcopy: $line") unless ($self->error());
            $returnCode = 0;
            last;
        } elsif ($line  =~ /^pc.*\s+(\d+)$/i) {
            my $taskId = $1;
            push (@taskIds, $taskId);
        }
    }

    if (@taskIds) {

        for my $task (@taskIds) {
            print "Task: [$task]\n" if ($self->debug());
        }

        my $intermediateSnapshotsTaken = $self->_waitForIntermediateSnapshotsToComplete(\@taskIds);
        if (scalar(@$intermediateSnapshotsTaken) != scalar(@taskIds)) {
            my $msg = "Intermediate snapshot was not taken for all tasks.";
            print "$msg\n" if ($self->debug()); 
            $self->setError($msg) unless ($self->error());
            $returnCode = 0;
        } else {
            print "Intermediate snapshot taken for all tasks.\n" if ($self->debug());
        }
    }

    return ($returnCode, \@taskIds);
}

#
# check the status of a task passed in
#
=pod

=item cmdShowTask(taskId)

Check status of the given task ID.

=cut
sub cmdShowTask {
    my $self = shift;
    my $taskId = shift;

    my $task;
    my $detailedStatus = 0;
    my @details = ();
    my $inservHostname = $self->hostname();

    my @output = $self->_sendCommandLocal("showtask -d $taskId");
    # % showtask -d 61
    # Id    Type              Name Status Phase Step ----------StartTime--------- ---------FinishTime---------
    # 61 vv_copy 0003-0->pc-0003-0 Active   1/1 8/10 Tue Feb 21 15:45:53 PST 2006                            -
    # 
    # Detailed status:
    # {Tue Feb 21 15:45:53 PST 2006} Created     task.
    # {Tue Feb 21 15:45:54 PST 2006} Starting    copy from VV 0003-0 to VV pc-0003-0 (10240MB) using source snapshot vvcp.390.402.
    
    foreach my $line (@output) {

        $line =~ s/^\s*//;

        if ($line =~ /^$taskId/) {
            my ($id, $type, $name, $status, $phase, $step, $rest) = split(/\s+/, $line, 7);

            my ($startTime, $endTime);
            if ($rest =~ m|(.{23})\s?(.{23})?|) {
                $startTime = $1;
                $endTime = $2;
            }

            $task = ariba::Ops::NetworkDevice::inserv::Container::Task->new("task-$inservHostname-$taskId");
            $task->setId($id);
            $task->setType($type);
            $task->setName($name);
            $task->setStatus(lc($status));
            $task->setPhase($phase);
            $task->setStep($step);
            $task->setStartTime($self->convertDateToTime($startTime));
            $task->setFinishTime($self->convertDateToTime($endTime));
        } elsif ($line =~ /^Detailed status:/) {
            $detailedStatus = 1;
        } elsif ($detailedStatus) {
            # inserv.opslab.ariba.com cli% showtask -d 7916
            #   Id    Type               Name Status Phase Step -------StartTime------- ------FinishTime-------
            # 7916 vv_copy 0096-3->pc1-0096-3   done   ---  --- 2009-10-07 13:06:06 PDT 2009-10-07 13:15:37 PDT
            # 
            # Detailed status:
            # 2009-10-07 13:06:06 PDT Created     task.
            # 2009-10-07 13:06:08 PDT Starting    copy from VV 0096-3 to VV pc1-0096-3 (12544MB) using source snapshot vvcp.629.3417.
            # 2009-10-07 13:14:44 PDT Update      completed 10238MB of 12544MB (81.62%) from VV 0096-3 to VV pc1-0096-3.
            # 2009-10-07 13:15:37 PDT Completed   copy from VV 0096-3 to VV pc1-0096-3.
            push( @details, $line );
        }
    }

    $task->setDetailedStatus(\@details) if ( @details > 0 );

    return $task;
}

sub taskQueueInfo {
    my $self = shift;
    my $ret = {};

    my $cmd = "showtask -active";
    my @output = $self->_sendCommandLocal($cmd);

    #
    # 7192 compact_cpg                           tp_fpc_cpg active   1/1 1351/9445 2012-01-18 14:48:04 PST
    #
    foreach my $line (@output) {
        if($line =~ /^\s*(\d+)\s+([^\s]+)\s+([^\s]+)\s+([^\s]+)\s+([^\s]+)\s+([^\s]+)/) {
            my $id = $1;
            my $type = $2;
            my $name = $3;
            my $status = $4;
            my $phase = $5;
            my $step = $6;
            if($status eq 'active') {
                my ($n, $d) = split(/\//, $step);
                if($d) {
                    my $pct = sprintf("%2.1f", ($n/$d)*100);
                    push(@{$ret->{'running'}}, "$id:$step ($pct\%)");
                } else {
                    push(@{$ret->{'queued'}}, $id);
                }
            }
        }
    }

    push(@{$ret->{'running'}}, "none") unless ($ret->{'running'});
    push(@{$ret->{'queued'}}, "none") unless ($ret->{'queued'});

    return($ret);
}

#
# block until all tasks passed in have finished
#
sub _waitForTasksToComplete {
    my $self = shift;
    my $taskIdsRef = shift;
    my $logger = shift;
    my $count = 0;

    my $duration = 20; # seconds
    my $numTasks = scalar(@$taskIdsRef);

    # initialize each task as not done
    my %tasksStatus = map { $_ => "unknown"; } @$taskIdsRef;
    my %tasksStep;
    my %tasksName;
    
    # % showtask -d 7911
    #   Id    Type               Name Status Phase Step -------StartTime------- ------FinishTime-------
    # 7911 vv_copy 0238-0->pc1-0238-0   done   ---  --- 2009-10-07 12:27:22 PDT 2009-10-07 12:32:48 PDT
    #
    # Detailed status:
    # 2009-10-07 12:27:22 PDT Created     task.
    # 2009-10-07 12:27:26 PDT Starting    copy from VV 0238-0 to VV pc1-0238-0 (12544MB) using source snapshot vvcp.5759.5749.
    # 2009-10-07 12:31:35 PDT Update      completed 10238MB of 12544MB (81.62%) from VV 0238-0 to VV pc1-0238-0.
    # 2009-10-07 12:32:48 PDT Completed   copy from VV 0238-0 to VV pc1-0238-0.

    while(1) {

        # first get the latest status
        for my $taskId (@$taskIdsRef) {
            my $oldStatus = $tasksStatus{$taskId};

            #
            # if we dont know the current status, or if the
            # task was active last we checked, check its
            # current status
            #
            if ($oldStatus eq "unknown" ||
                $oldStatus eq "active") {

                my $task = $self->cmdShowTask($taskId);
                #
                # Sometimes showtask on an taskid returns no
                # results. Leave the status same as before,
                # It will be retried automatically next
                # time through the loop.
                #
                if ($task) {
                    $tasksStatus{$taskId} = $task->status();
                    $tasksStep{$taskId} = $task->step();
                    $tasksName{$taskId} = $task->name();
                }
            }
        }

        # see if any task is still not completed
        my $keepWaiting = 0;
        my $queued = 0;
        my $running = 0;
        for my $taskId (@$taskIdsRef) {
            my $status = $tasksStatus{$taskId};
            $count++;

            if ($status eq "active" || $status eq "unknown") {
                $keepWaiting = 1;   
            }

            if((($count % 3) == 0) && $logger) {
                my $name = $tasksName{$taskId};
                my $step = $tasksStep{$taskId};
                my ($n, $d) = split (/\//, $step);
                my $pct;
                if($d) {
                    $pct = sprintf("%2.1f", ($n/$d)*100);
                    $pct .= "%";
                    $running = 1;
                } else {
                    $pct = "queued";
                    $queued = 1;
                }
                $logger->info("$taskId $name on step $step ($pct)");
            } else {
                last if($keepWaiting);
            }
        }

        if($queued && !$running && $logger) {
            my $queue = $self->taskQueueInfo();
            my $numRunning = scalar(@{$queue->{'running'}});
            my $numQueued = scalar(@{$queue->{'queued'}});

            $logger->info("All tasks are queued on the 3par.");
            $running = join(', ',@{$queue->{'running'}});
            $logger->info("Currently $numRunning running tasks:\n\t$running");
            $queued = join(', ',@{$queue->{'queued'}});
            $logger->info("Currently $numQueued queued tasks:\n\t$queued");
        }

        last unless ($keepWaiting);

        sleep($duration);
    }

    my @tasksFinishedSuccessfully = ();
    # check tasks with bad finish status
    for my $taskId (@$taskIdsRef) {
        my $status = $tasksStatus{$taskId};

        if ($status eq "done") {
            push(@tasksFinishedSuccessfully, $taskId);
        }
    }

    return \@tasksFinishedSuccessfully;
}

sub _waitForIntermediateSnapshotsToComplete {
    my $self = shift;
    my $taskIdsRef = shift;

    #
    # before we start, sleep a random amount to "scatter" concurrent
    # tasks
    #
    srand(time ^ ($$ + ($$ << 15)));
    my $duration = 300+(int(rand(90))*10);
    $self->disconnect();
    sleep($duration);
    $self->connect();

    $duration = 900; # 15 minutes -- no need to spam this more often
    my $numTasks = scalar(@$taskIdsRef);

    # initialize each task as not done
    my %tasksStatus = map { $_ => "unknown"; } @$taskIdsRef;
    
    while(1) {

        # first get the latest status
        for my $taskId (@$taskIdsRef) {
            my $oldStatus = $tasksStatus{$taskId};
            #
            # if we dont know the current status, or if the
            # task was active last we checked, check its
            # current status
            #
            if ($oldStatus eq "unknown") {

                my $task = $self->cmdShowTask($taskId);
                #
                # Sometimes showtask on an taskid returns no
                # results. Leave the status same as before,
                # It will be retried automatically next
                # time through the loop.
                #
                if ($task) {
                    my @detailedStatus = $task->detailedStatus();
                            foreach my $line (@detailedStatus) {
                        # 2009-10-07 14:46:00 PDT Starting    copy from VV 0238-0 to VV pc1-0238-0 (12544MB) using source snapshot vvcp.5759.5749.
                        if ($line =~ /Starting.*using source snapshot vvcp/) {
                            print "Intermediate snapshot done:\n[$line]\n" if ($self->debug());
                            $tasksStatus{$taskId} = "intermediate snapshot done";
                        }
                                }
                }
            }
        }

        # see if any task is still not completed
        my $keepWaiting = 0;
        for my $taskId (@$taskIdsRef) {
            my $status = $tasksStatus{$taskId};

            if ($status eq "unknown") {
                $keepWaiting = 1;   
                last;
            }
        }

        last unless ($keepWaiting);

        $self->disconnect();
        sleep($duration);
        $self->connect();
    }

    my @tasksFinishedSuccessfully = ();
    # check tasks with bad finish status
    for my $taskId (@$taskIdsRef) {
        my $status = $tasksStatus{$taskId};

        if ($status eq "intermediate snapshot done") {
            push(@tasksFinishedSuccessfully, $taskId);
        }
    }

    return \@tasksFinishedSuccessfully;
}


=pod

=item virtualVolumesForLunsOnHost(luns, host)

For the specified list of luns (passed as an array ref) on a host,
return a list of virtual volume(s) on the array that correspond to
that lun.

=cut
sub virtualVolumesForLunsOnHost {
    my $self = shift;
    my $lunsRef = shift;
    my $host = shift;

    my $shortHost = $host;
    $shortHost =~ s/\.ariba\.com$//;
    my $inservHostname = $self->hostname();
    my $lunsString = join(",", @$lunsRef);
    my @output = $self->_sendCommandLocal("showvlun -a -host $shortHost -l $lunsString");

    return ariba::Ops::Inserv::VolumeLun->vlunsFromCmdOutput(\@output, $inservHostname);
}

sub lunsOnHost {
    my $self = shift;
    my $host = shift;
    my $debug = 0;
    my $shortHost = $host;
    $shortHost =~ s/\.ariba\.com$//;
    my $inservHostname = $self->hostname();
    my @output = $self->_sendCommandLocal("showvlun -a -host $shortHost");

    my $vvlist;
    foreach my $out (@output){
        chomp($out);
        $out =~ s/^\s+//g;
        next if ($out =~ /total|^---|VVName/i);
        my ($lun, $vvName, $string) = split /\s+/, $out;
        $vvName =~ s/^\s+|\s+$//g;
        print "Coming here for $vvName & $out\n", if ($debug > 1);
        $vvlist->{$vvName} = 1;
        print "VVNAME : $vvName \n", if ($debug > 1) ;

    }
    my @luns = keys %{$vvlist} ;
    print "List of VV Founds \n", Dumper(\@luns), "\n", if ($debug);
    return \@luns;
}

sub nextAvailableLun {
    my $self = shift;
    my $host = shift;
    my $maxLun = 0;

    my $shortHost = $host;
    $shortHost =~ s/\.ariba\.com$//;
    my @output = $self->_sendCommandLocal("showvlun -a -host $shortHost");

    foreach my $line (@output) {
        last if($line =~ /^------/);
        if($line =~ /^\s*(\d+)/) {
            my $lun = $1;
            $maxLun = $lun if($lun > $maxLun);
        }
    }

    return($maxLun+1);
}

sub vLunsforVirtualVolumesOfFilesystem {
    my $self = shift;
    my $optionsRef = shift;

    my $instanceName = $self->hostname();
    $instanceName = $optionsRef->{'instancePrefix'} . "_" . $instanceName if $optionsRef->{'instancePrefix'};

    my $vvsString = join(",", @{$optionsRef->{'vvlist'}});
    my @output = $self->_sendCommandLocal("showvlun -a -v $vvsString");

    return ariba::Ops::Inserv::VolumeLun->vlunsFromCmdOutput(\@output, $instanceName, $optionsRef->{'fs'});
}

sub logMessage {
    my $self = shift;
    my $logMsg = shift;

    if ($self->logResponses()) {
        my @time = localtime();
        my $date = sprintf("%d-%02d-%02d %02d:%02d",
                $time[5]+1900, $time[4]+1, $time[3], $time[2], $time[1]);

        unless (defined($logfh) && print($logfh $date," : ",$logMsg,"\n")) {
            print($logfh $date," : ",$logMsg,"\n") if $self->_reopenLogfile();
        }
    }
}

sub _reopenLogfile {
    my $self = shift;

    close ($logfh) if defined($logfh);

    my $logDir = $ENV{'LOGSDIR'};
    return 0 unless $logDir;

    my $DATE_FORMAT = "%Y%m%d";
    my $dateString = POSIX::strftime($DATE_FORMAT, localtime());

    open($logfh, ">>$logDir/inserv-$dateString.log") || do {
        warn "Cannot open '$logDir/inserv-$dateString.log' for writing: $!";
        return 0;
    };
    return 1;
}

sub setLogResponses {
    my $self = shift;

    if ($_[0]) {
        $self->_reopenLogfile();
    }

    $self->SUPER::setLogResponses(@_);
}

=pod

=item portWwns()

Returns a list of non-offline wwns.

=cut

sub portWwns {
    my $self = shift; 

    my @output = $self->sendCommandUsingInform("showport");
    my @wwns; 

    for my $line (@output) { 
        next if ($line =~ /\soffline\s/); 

        my @columns = split(/\s+/, $line); 
        push(@wwns, lc($columns[4])) if ($columns[4] && $columns[4] =~ /^[[:xdigit:]]+$/);
    }

    return @wwns;
}

package ariba::Ops::NetworkDevice::inserv::Container;
use base qw(ariba::Ops::PersistantObject);
        
sub dir {
        my $class = shift;
        return undef;
}

package ariba::Ops::NetworkDevice::inserv::Container::Node;
use base qw(ariba::Ops::NetworkDevice::inserv::Container);

sub validAccessorMethods {
        my $class = shift;

    my $methodsRef = $class->SUPER::validAccessorMethods();

        $methodsRef->{'node'} = undef;
        $methodsRef->{'name'} = undef;
        $methodsRef->{'master'} = undef;

        return $methodsRef;
}

package ariba::Ops::NetworkDevice::inserv::Container::Template;
use base qw(ariba::Ops::NetworkDevice::inserv::Container);

sub validAccessorMethods {
        my $class = shift;

    my $methodsRef = $class->SUPER::validAccessorMethods();

        $methodsRef->{'name'} = undef;
        $methodsRef->{'options'} = undef;

        return $methodsRef;
}

package ariba::Ops::NetworkDevice::inserv::Container::Cpg;
use base qw(ariba::Ops::NetworkDevice::inserv::Container);

sub validAccessorMethods {
        my $class = shift;

    my $methodsRef = $class->SUPER::validAccessorMethods();

        $methodsRef->{'name'} = undef;
        $methodsRef->{'sATotal'} = undef;
        $methodsRef->{'sAUsed'} = undef;
        $methodsRef->{'sDTotal'} = undef;
        $methodsRef->{'sDUsed'} = undef;
        $methodsRef->{'percentUsedSA'} = undef;
        $methodsRef->{'percentUsedSD'} = undef;
        $methodsRef->{'dataIncrement'} = undef;
        $methodsRef->{'adminIncrement'} = undef;
        $methodsRef->{'dataGrowthLimit'} = undef;
        $methodsRef->{'adminGrowthLimit'} = undef;

        return $methodsRef;
}

package ariba::Ops::NetworkDevice::inserv::Container::Event;
use base qw(ariba::Ops::NetworkDevice::inserv::Container);

sub validAccessorMethods {
        my $class = shift;

    my $methodsRef = $class->SUPER::validAccessorMethods();

        $methodsRef->{'time'} = undef;
        $methodsRef->{'severity'} = undef;
        $methodsRef->{'type'} = undef;
        $methodsRef->{'details'} = undef;
        $methodsRef->{'message'} = undef;

        return $methodsRef;
}

package ariba::Ops::NetworkDevice::inserv::Container::Alert;
use base qw(ariba::Ops::NetworkDevice::inserv::Container);

sub validAccessorMethods {
        my $class = shift;

    my $methodsRef = $class->SUPER::validAccessorMethods();

        $methodsRef->{'id'} = undef;
        $methodsRef->{'time'} = undef;
        $methodsRef->{'messageCode'} = undef;
        $methodsRef->{'node'} = undef;
        $methodsRef->{'severity'} = undef;
        $methodsRef->{'summary'} = undef;
        $methodsRef->{'details'} = undef;

        return $methodsRef;
}

package ariba::Ops::NetworkDevice::inserv::Container::VirtualVolume;
use base qw(ariba::Ops::NetworkDevice::inserv::Container);

sub validAccessorMethods {
        my $class = shift;

    my $methodsRef = $class->SUPER::validAccessorMethods();

    # Id
    # Name
    # Type
    # CopyOf
    # BsId
    # Rd
    # State
    # AdmMB
    # SnapMB
    # userMB

        $methodsRef->{'id'} = undef;
        $methodsRef->{'name'} = undef;
        $methodsRef->{'type'} = undef;
        $methodsRef->{'copyOf'} = undef;
        $methodsRef->{'bsId'} = undef;
        $methodsRef->{'rd'} = undef;
        $methodsRef->{'state'} = undef;
        $methodsRef->{'admMB'} = undef;
        $methodsRef->{'snapMB'} = undef;
        $methodsRef->{'userMB'} = undef;
        $methodsRef->{'policies'} = undef;
        $methodsRef->{'prov'} = undef;      # 2.3.1
        $methodsRef->{'vSize'} = undef;     # 2.3.1

        return $methodsRef;
}

package ariba::Ops::NetworkDevice::inserv::Container::PortParameters;
use base qw(ariba::Ops::NetworkDevice::inserv::Container);

sub validAccessorMethods {
        my $class = shift;

    my $methodsRef = $class->SUPER::validAccessorMethods();

        $methodsRef->{'name'} = undef;
        $methodsRef->{'nsp'} = undef;
        $methodsRef->{'conntype'} = undef;
        $methodsRef->{'cfgrate'} = undef;
        $methodsRef->{'maxrate'} = undef;
        $methodsRef->{'class2'} = undef;
        $methodsRef->{'vcn'} = undef;
        $methodsRef->{'persona'} = undef;
        $methodsRef->{'intcoal'} = undef;
        $methodsRef->{'brand'} = undef;
        $methodsRef->{'model'} = undef;
        $methodsRef->{'rev'} = undef;
        $methodsRef->{'firmware'} = undef;
        $methodsRef->{'serial'} = undef;
        $methodsRef->{'mode'} = undef;
        $methodsRef->{'state'} = undef;
        $methodsRef->{'nodewwn'} = undef;
        $methodsRef->{'portwwn'} = undef;
        $methodsRef->{'type'} = undef;
        $methodsRef->{'node'} = undef;
        $methodsRef->{'connectedHost'} = undef;

        return $methodsRef;
}

package ariba::Ops::NetworkDevice::inserv::Container::PortStats;
use base qw(ariba::Ops::NetworkDevice::inserv::Container);

sub validAccessorMethods {
        my $class = shift;

    my $methodsRef = $class->SUPER::validAccessorMethods();

        $methodsRef->{'name'} = undef;
        $methodsRef->{'nsp'} = undef;
        $methodsRef->{'ioType'} = undef;
        $methodsRef->{'readIOPS'} = undef;
        $methodsRef->{'readBitsPS'} = undef;
        $methodsRef->{'readSvcTimeMS'} = undef;
        $methodsRef->{'readIOSizeBytes'} = undef;
        $methodsRef->{'writeIOPS'} = undef;
        $methodsRef->{'writeBitsPS'} = undef;
        $methodsRef->{'writeSvcTimeMS'} = undef;
    $methodsRef->{'writeIOSizeBytes'} = undef;
    $methodsRef->{'queueLength'} = undef;

        return $methodsRef;
}

package ariba::Ops::NetworkDevice::inserv::Container::VVCacheStats;
use base qw(ariba::Ops::NetworkDevice::inserv::Container);

sub validAccessorMethods {
    my $class = shift;

    my $methodsRef = $class->SUPER::validAccessorMethods();

    $methodsRef->{'name'} = undef;
    $methodsRef->{'type'} = undef;
    $methodsRef->{'readAccesses'} = undef;
    $methodsRef->{'readHits'} = undef;
    $methodsRef->{'writeAccesses'} = undef;
    $methodsRef->{'writeHits'} = undef;

}

package ariba::Ops::NetworkDevice::inserv::Container::NodeCacheStats;
use base qw(ariba::Ops::NetworkDevice::inserv::Container);

sub validAccessorMethods {
        my $class = shift;

    my $methodsRef = $class->SUPER::validAccessorMethods();

        $methodsRef->{'name'} = undef;
        $methodsRef->{'type'} = undef;
        $methodsRef->{'readAccesses'} = undef;
        $methodsRef->{'readHits'} = undef;
        $methodsRef->{'writeAccesses'} = undef;
        $methodsRef->{'writeHits'} = undef;

}

package ariba::Ops::NetworkDevice::inserv::Container::VvPds;
use base qw(ariba::Ops::NetworkDevice::inserv::Container);

sub validAccessorMethods {
    my $class = shift;

    my $methodsRef = $class->SUPER::validAccessorMethods();

    #  Id Cage_Pos SA  SD  usr total
    $methodsRef->{'id'} = undef;
    $methodsRef->{'cage_pos'} = undef;
    $methodsRef->{'sa'} = undef;
    $methodsRef->{'sd'} = undef;
    $methodsRef->{'usr'} = undef;
    $methodsRef->{'total'} = undef;

    return $methodsRef;
}

package ariba::Ops::NetworkDevice::inserv::Container::LogicalDisk;
use base qw(ariba::Ops::NetworkDevice::inserv::Container);

sub validAccessorMethods {
        my $class = shift;

    my $methodsRef = $class->SUPER::validAccessorMethods();

    # Id
    # Name
    # RAID
    # State
    # Own
    # SizeMB
    # UsedMB
    # Use
    # Lgct
    # LgId
    # WThru
    # MapV
        $methodsRef->{'id'} = undef;
        $methodsRef->{'name'} = undef;
        $methodsRef->{'raid'} = undef;
        $methodsRef->{'state'} = undef;
        $methodsRef->{'own'} = undef;
        $methodsRef->{'sizeMB'} = undef;
        $methodsRef->{'usedMB'} = undef;
        $methodsRef->{'use'} = undef;
        $methodsRef->{'lgct'} = undef;
    $methodsRef->{'wThru'} = undef;
    $methodsRef->{'mapV'} = undef;

    return $methodsRef;
}

package ariba::Ops::NetworkDevice::inserv::Container::PhysicalDisk;
use base qw(ariba::Ops::NetworkDevice::inserv::Container);

sub validAccessorMethods {
    my $class = shift;

    my $methodsRef = $class->SUPER::validAccessorMethods();

    $methodsRef->{'id'} = undef;
    $methodsRef->{'name'} = undef;

    return $methodsRef;
}

package ariba::Ops::NetworkDevice::inserv::Container::Chunklet;
use base qw(ariba::Ops::NetworkDevice::inserv::Container);

sub validAccessorMethods {
    my $class = shift;

    my $methodsRef = $class->SUPER::validAccessorMethods();

    # Ldch
    # Row
    # Set
    # PdPos
    # Pdid
    # Pdch
    # State
    # Usage
    # Media
    # Sp
    # From
    # To
        $methodsRef->{'ldch'} = undef;
        $methodsRef->{'row'} = undef;
        $methodsRef->{'set'} = undef;
        $methodsRef->{'pdPos'} = undef;
        $methodsRef->{'pdid'} = undef;
        $methodsRef->{'pdch'} = undef;
        $methodsRef->{'state'} = undef;
        $methodsRef->{'usage'} = undef;
        $methodsRef->{'media'} = undef;
        $methodsRef->{'sp'} = undef;
        $methodsRef->{'from'} = undef;
        $methodsRef->{'to'} = undef;

        return $methodsRef;
}

package ariba::Ops::NetworkDevice::inserv::Container::Task;
use base qw(ariba::Ops::NetworkDevice::inserv::Container);

sub validAccessorMethods {
        my $class = shift;

    my $methodsRef = $class->SUPER::validAccessorMethods();

        $methodsRef->{'id'} = undef;
        $methodsRef->{'type'} = undef;
        $methodsRef->{'name'} = undef;
        $methodsRef->{'status'} = undef;
        $methodsRef->{'phase'} = undef;
        $methodsRef->{'step'} = undef;
        $methodsRef->{'startTime'} = undef;
        $methodsRef->{'finishTime'} = undef;
    $methodsRef->{'detailedStatus'} = undef;

        return $methodsRef;
}

1;

__END__

=pod

=head1 AUTHOR

Manish Dubey <mdubey@ariba.com>

=head1 SEE ALSO

    ariba::Ops::NetworkDeviceManager

    ariba::Ops::NetworkDevice::BaseDevice

=cut

