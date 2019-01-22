#
# Base class for cleansing S4 and SSP
#
use strict;

use FindBin;
use lib "/usr/local/ariba/lib";
use lib "$FindBin::Bin/../../lib/";
use lib "$FindBin::Bin/../../lib/perl";

package ariba::Ops::FPC::FpcSS;
use base qw(ariba::Ops::FPC::FpcBase);
use ariba::Ops::MCLGen;
use ariba::Ops::MCL;
use ariba::Ops::NetworkDeviceManager;
use ariba::rc::ArchivedProduct;
use ariba::Ops::Machine;
use List::Util qw(first);

use Data::Dumper;
local $Data::Dumper::Useqq  = 1;
local $Data::Dumper::Indent = 3;

my $backupCompleteDepends;
my $controlFileReadyDepends;
my $snapshotCompleteDepends;
my $dataCopyDepends;

sub steps {
    my ( $self, $rootService, $products, $baseSS ) = @_;
  
    my $string;
    my @productOrder = @$products;
    my $srcService = $self->srcService();
    my $tgtService = $self->tgtService();

    setStepName( 0, 0 );

    my $headerString = "S4 and Buyer $srcService->$tgtService migration.";
    $string .= $self->header( 'SS', $rootService, $headerString );
    $string .= $self->backup( 'main', '', 'stop' );
    $string .= $self->recreateDBVolumes();

    # $baseSS = true then take snapshot from the live DR base volume
    # $baseSS = false then take snapshot from the pc1 DR backup volume
    if ( $baseSS ) {
        $string .= $self->getTimeStamp( 'beforeTime' );
        $string .= $self->dbStandbyMode( 'stop' );
        $string .= $self->create3parSnapshots( 'main', $products, $baseSS );
        $string .= $self->dbStandbyMode( 'start' );
        $string .= $self->getTimeStamp( 'afterTime' );
        $backupCompleteDepends = depends();
    } else {
        $string .= $self->runBcvBackup();
        $string .= $self->getTimeStamp( 'beforeTime' );
        $string .= $self->runBcvBackup();
        $string .= $self->getTimeStamp( 'afterTime' );
        $backupCompleteDepends = depends();       
        $string .= $self->create3parSnapshots( 'main', $products, $baseSS );
    }
    $string .= $self->createControlFile( 'main' );
    $string .= $self->copyArchiveLogs( 'main' );
    $string .= $self->copyRealms( $products );

    foreach my $product ( @productOrder ) {
        my $index = first { $productOrder[$_] eq $product } 0..$#productOrder;
        $string .= $self->copyCleanseGroup( $product, $index, 'main', $baseSS );
    }

    return $string;
}

sub copyCleanseGroup {
    my ( $self, $product, $index, $schemaType, $baseSS ) = @_;

    my $string;
    my $depends;

    if ( $index == 0 ) {
        $depends = $snapshotCompleteDepends;
    } else {
        $depends = $dataCopyDepends;
    }

    $string .= $self->copyData( $product, $depends );
    $dataCopyDepends = depends();
    $string .= $self->applyControlFile( $product, $schemaType );
    $string .= $self->growTablespace( $product, $schemaType );
    $string .= $self->changeDbPasswords( $product );
    $string .= $self->dropDbLinks( $product, $schemaType );
    $string .= $self->backup( $schemaType, $product );
    $string .= $self->initSV() if ( $product eq 's4' );
    $string .= $self->cleanse( $schemaType, $product );

    #$string .= $self->backup( $schemaType, $product );
    #$string .= $self ->productAction( $product, 'install' );
        
    return $string;
}

sub cleansingScripts {
    my ( $self, $product ) = @_;
 
    my $return;
    my $domain = $self->emailDomain();

    if ( $product eq 'buyer' ) {
        $return->{'SQL1'} = "lib/sql/clean_all_masterdata_beta.sql";
        $return->{'SQL2'} = "lib/sql/clean_email_beta.sql $domain";
        $return->{'SQL3'} = "lib/sql/delete_transactions.sql";
    } elsif ( $product eq 's4' ) {
        $return->{'SQL1'} = "lib/sql/clean_all_masterdata_beta.sql";
        $return->{'SQL2'} = "lib/sql/clean_email_beta.sql $domain";
        $return->{'SQL3'} = "lib/sql/TransactionDataCleansing.sql";
        $return->{'SQL4'} = "lib/sql/TxCleansingValidation.sql";
        $return->{'SQL5'} = "lib/sql/TxCleansingTableDrops.sql";
        $return->{'SQL6'} = "lib/sql/TxCleansingAnalysisdbschematab.sql";
    } else {
        die "$!, Invalid product.  No cleasing scripts for: $product\n";
    }
    return $return;
}

sub dbStandbyMode {
    my ( $self, $mode ) = @_;

    nextStepBlock();

    my $string;
    my $stepName;
    my %sids = %{ $self->sids() };
    my $group = "GRP-" . stepName();
    my $expando = "EXP-" . stepName();
    my $srcService = $self->srcService();

    $string .= defineRunGroup( $group, 100 );
    $string .= defineExpando( $expando, stepName() . " Set source dbs to backup mode: $mode" );

    # set page filters
    if ( $mode eq 'stop' ) {
        my @commands;
        foreach my $sid ( sort( keys( %sids ))) {
            my $sid = $self->srcSid( $sid );
            push( @commands, "\$ /home/mon$srcService/bin/page/nopage -user fpcAutomation -note 'FPC snapshot creation causes lag' -program physical-dataguard-status -text " . uc( $sid ));
        }
        $string .= $self->pageFilter( \@commands, $group, $expando );
    }

    # The startup command is for TX only.  If we expand to do this for SV the startup extension is:
    #   "disconnect;"
    my $cmd = "\$ alter database recover managed standby database ";
    if ( $mode eq 'stop' ) {
        $cmd .= "cancel;";
    } else {
        $cmd .= "using current logfile disconnect;";
    }
    
    my @commands = (
        $cmd,
        'SuccessString: Database altered',
    );

    incrementStepName();
    foreach my $sid ( sort( keys( %sids ))) {
        my $host = $self->srcSecHost( $sid );
        my $sid = $self->srcSid( $sid );

        incrementStepName();
        $stepName = stepName() . ".$sid.backup.mode.$mode";
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= defineAction( "OracleScript", "$sid\@$host", @commands ) . "\n";
    }

    setDepends( "group:$group" );
    return $string;
}

sub recreateDBVolumes {
    my ( $self ) = @_;

    nextStepBlock();

    my $string;
    my $stepName;
    my %sids = %{ $self->sids() };
    my $group = "GRP-" . stepName();
    my $expando = "EXP-" . stepName();
    my $service = $self->tgtService();

    # Run sequentially as a precaution.  These commands run fast.
    $string .= defineRunGroup( $group, 1 );
    $string .= defineExpando( $expando, stepName() . " Delete old data from $service db/log volumes" );

    foreach my $sid ( sort( keys( %sids ))) {
        my $host = $self->tgtLiteralHost( $sid );
        my $volume = $self->tgtVolume( $sid );
        $volume =~ m/.+?(\d+)/;
        my $num = $1;

        # ??? hard coded for 1 db and 1 log volume per sid
        # First half of the array recreates the naked db/log volumes
        # Second half sets correct dir ownership and created required sub directories
        my @commands = (
            "\$ sudo umount /ora${num}data01",
            "\$ sudo umount /ora${num}log01",
            "\$ sudo /usr/lib/fs/vxfs/mkfs -t vxfs -o bsize=8192 /dev/vx/dsk/ora${num}dg/ora${num}data01",
            "\$ sudo /usr/lib/fs/vxfs/mkfs -t vxfs -o bsize=8192 /dev/vx/dsk/ora${num}logdg/ora${num}log01",
            "\$ sudo mount /ora${num}data01",
            "\$ sudo mount /ora${num}log01",
            "\$ sudo chown oracle:dba /ora${num}data01",
            "\$ sudo chown oracle:dba /ora${num}log01",
            "\$ sudo su oracle -c 'mkdir -p /ora${num}data01/oradata1/$sid'",
            "\$ sudo su oracle -c 'mkdir -p /ora${num}data01/oraredo1/$sid'",
            "\$ sudo su oracle -c 'mkdir -p /ora${num}log01/oraarch1/$sid'",
            "\$ sudo su oracle -c 'mkdir -p /ora${num}log01/oraredo1/$sid'",
        );

        incrementStepName();
        $stepName = stepName() . ".recreate.$sid.volumes";
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= defineAction( "Shell", "mon$service\@$host", @commands ) . "\n";
    }

    setDepends( "group:$group" );
    return $string;
}

sub runBcvBackup {
    my ( $self ) = @_;

    nextStepBlock();

    my $string;
    my $stepName;
    my %sids = %{ $self->sids() };
    my $group = "GRP-" . stepName();
    my $expando = "EXP-" . stepName();
    my $srcService = $self->srcService();
    my @commands;

    $string .= defineRunGroup( $group, 100 );
    $string .= defineExpando( $expando, stepName() . " Run BCV backup" );

    foreach my $sid ( sort( keys( %sids ))) {
        my $product = $sids{ $sid }->{ 'product' };
        my $srcSecHost = $sids{ $sid }->{ 'srcSecHost' };

        incrementStepName();
        @commands = ( 
            "\$ sudo bash -c '/usr/local/ariba/bin/bcv-backup -d -incrementalPhysical -bcv 1 $product $srcService'",
            "ErrorString: Sync Failed",
            "ErrorString: This BCV backup is disabled until",
        );
        $stepName = stepName() . ".BCV.backup.$srcSecHost";
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= defineAction( "Shell", "mon$srcService\@$srcSecHost", @commands ) . "\n";
    }

    setDepends( "group:$group" );
    return $string;
}

sub create3parSnapshots {
    my ( $self, $schemaType, $products, $baseSS ) = @_;

    nextStepBlock();

    my %sids = %{ $self->sids() };
    my $stepName;
    my $group = "GRP-" . stepName();
    my $expando = "EXP-" . stepName();
    my $srcService = $self->srcService();
    my $tmid = $self->tmid();
    my $string = "";
    my @commands;
    my $user = "mon" . $srcService;
    my $pass = ariba::rc::Passwords::lookup( $user );
    my $volPrefix = $baseSS ? "" : "pc1-";

    # if backupCompleteDepends is set then respect it, else wait on the previous step. 
    my $rootDepends = $backupCompleteDepends ? $backupCompleteDepends : depends();

    $string .= defineRunGroup( $group, 10 );
    $string .= defineExpando( $expando, stepName() . " Create RO/RW snapshots" );

    foreach my $sid ( sort( keys( %sids ))) {
        next if ( $schemaType && !$sids{ $sid }->{ 'types' }->{ $schemaType } );

        my $srcVolume = $sids{ $sid }->{ 'srcVolume' };
        my $tgtVolume = $sids{ $sid }->{ 'tgtVolume' };
        my $srcSecHost = $sids{ $sid }->{ 'srcSecHost' };
        my $tgtHost = $sids{ $sid }->{ 'tgtHost' };
        my $srcSid = $sids{ $sid }->{ 'srcSid' };
        my $literalHost = $sids{ $sid }->{ 'tgtLiteralHost' };
        my $inservHost = $sids{ $sid }->{ 'inservHost' };

        # create snapshot commands
        $stepName = stepName() . ".$sid.RWbcv";
        my @commands = ( "\$ creategroupsv -ro", "\$ creategroupsv" );
        my $VVs = $sids{ $sid }->{ 'VVs' };
        while ( my ( $vv, $lun ) = each %$VVs ) {
            $vv = $volPrefix . $vv;
            my $scro = "scro" . $tmid . "-" . $vv;
            my $scrw = "scrw" . $tmid . "-" . $vv;
            @commands[0] .= " $vv:$scro";
            @commands[1] .= " $scro:$scrw";
            push( @commands, "\$ createvlun $scrw $lun $literalHost" );

        }
        push( @commands, "ErrorString: Error:" );

        $string .= defineStep( $stepName, $stepName, $rootDepends, $expando, $group );
        $string .= defineAction( "NetworkDevice", "$inservHost", @commands ) . "\n";
        setDepends ( $stepName );

        # get the list of scsi hosts
        my @output;
        undef( @commands );
        my $cmd = "ssh -l $user $tgtHost ls /sys/class/scsi_host";
        my $ret = ariba::rc::Utils::executeRemoteCommand( $cmd, $pass, 0, undef, undef, \@output );
        foreach my $line ( @output ) {
           if ( $line =~ m/host/ ) {
               push( @commands, "\$ sudo bash -c 'echo \"- - -\" > /sys/class/scsi_host/$line/scan'" );
           }
        }

        $srcVolume =~ m/.+?(\d+)/;
        my $srcVolumeNum = $1;

        # mount the source snapshot on the target host
        incrementStepName();
        $stepName = stepName() . ".$sid.mount";
        push ( @commands, 
            "\$ sudo bash -c 'vxdisk scandisks'",
            "\$ sudo bash -c 'for n in /sys/block/sd*/queue/iosched/slice_idle ; do echo 0 > \$n ; done'",
            "\$ sudo bash -c 'vxdg -Cf import ora${srcVolumeNum}dg'",
            "\$ sudo bash -c 'vxedit -g ora${srcVolumeNum}dg rm -rf ora${srcVolumeNum}log01'",
            "\$ sudo bash -c 'vxedit -g ora${srcVolumeNum}dg rm -rf ora${srcVolumeNum}log02'",
            "\$ sudo bash -c 'mkdir -p $srcVolume'",
            "\$ sudo bash -c 'mount -t vxfs /dev/vx/dsk/ora${srcVolumeNum}dg$srcVolume $srcVolume'",
            "\$ sudo bash -c 'vxdisk list -o alldgs -e | grep ora${srcVolumeNum}dg | grep failed | awk {print\\ \\\$3} | xargs vxdg -g ora${srcVolumeNum}dg rmdisk'" );
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= defineAction( "Shell", "mon$srcService\@$tgtHost", @commands ) . "\n";
    }
   
    $snapshotCompleteDepends = "group:$group";
    setDepends( "group:$group" );
    return ( $string );
}

sub netappSnapshotAction {
    my ( $self, $products, $action ) = @_;

    nextStepBlock();

    my $stepName;
    my $expando = "EXP-" . stepName();
    my $group = "GRP-" . stepName();
    my $string = "";
    my @commands;

    $string .= defineRunGroup( $group, 1 );
    $string .= defineExpando( $expando, stepName() . " $action netapp snapshots" );

    # Create/Delete a snapshot of each product's realm dir on the source primary nfs host.
    foreach my $product ( @$products ) {
        my $nfs = $self->nfs();
        my $snapshotName = $nfs->{ $product }->{ 'snapshotName' };
        my $nfsVolume = $nfs->{ $product }->{ 'volume' };
        my $nfsHost = $nfs->{ $product }->{ 'host' };

        incrementStepName();
        $stepName = stepName() . ".$product.realms.snapshot.$action";
        @commands = (
            "\$ snap $action $nfsVolume $snapshotName",
            "ErrorString: Error:",
        );

        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= defineAction( "NetworkDevice", "$nfsHost", @commands ) . "\n";
        setDepends( $stepName );
    }

    setDepends( "group:$group" );
    return ( $string );
}

sub createControlFile {
    my ( $self, $schemaType ) = @_;

    nextStepBlock();

    my %sids = %{ $self->sids() };
    my $stepName;
    my $group = "GRP-" . stepName();
    my $expando = "EXP-" . stepName();
    my $tgtService = $self->tgtService();
    my $srcService = $self->srcService();
    my $rootDepends = $backupCompleteDepends;
    my $string = "";
    my @commands;

    $string .= defineRunGroup( $group, 100 );
    $string .= defineExpando( $expando, stepName() . " Create Control File" );

    foreach my $sid ( sort( keys( %sids ))) {
        next if ( $schemaType && !$sids{ $sid }->{ 'types' }->{ $schemaType } );

        my $srcSid = $sids{ $sid }->{ 'srcSid' };
        my $srcVolume = $sids{ $sid }->{ 'srcVolume' };
        my $tgtVolume = $sids{ $sid }->{ 'tgtVolume' };
        my $tgtHost = $sids{ $sid }->{ 'tgtHost' };
        my $srcSecHost = $sids{ $sid }->{ 'srcSecHost' };
        my $srcTmpDir = my $copyTarget = $self->rootTmpDir() . "/$srcSid";
        my $tgtTmpDir = my $copyTarget = $self->rootTmpDir() . "/$sid";
        my $controlFile = "$srcTmpDir/cr_ctl_$srcSid.sql";

        # delete previous control file
        incrementStepName();
        $stepName = stepName() . ".$sid.delete.control.file";
        @commands = (
            "\$ sudo su - oracle -c 'rm -f $controlFile'",
        );
        $string .= defineStep( $stepName, $stepName, $rootDepends, $expando, $group );
        $string .= defineAction( "Shell", "mon$srcService\@$srcSecHost", @commands ) . "\n";
        setDepends( $stepName );

        # generate a control file for the sid
        incrementStepName();
        $stepName = stepName() . ".$sid.create.control.file";
        @commands = (
            "\$ alter database backup controlfile to trace as '$controlFile';",
            "\$ archive log list;",
            "\$ alter session set nls_date_format='DD-MON-YYYY HH24:MI:SS';",
            "\$ select sysdate from dual;",
        );
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= defineAction( "OracleScript", "$srcSid\@$srcSecHost", @commands ) . "\n";
        setDepends( $stepName );

        # copy the control file to the target db host
        incrementStepName();
        $stepName = stepName() . ".$sid.copy.control.file";
        @commands = ( "\$ sudo su -c 'rsync -avP -e \"ssh -o StrictHostKeyChecking=no\" $controlFile monprod\@$tgtHost:$tgtTmpDir/'" );
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= "Retries: 2\n";
        $string .= "RetryInterval: 15\n";
        $string .= defineAction( "Shell", "mon$srcService\@$srcSecHost", @commands ) . "\n";
        setDepends( $stepName );

        # edit the db control file changing source parmeters to the corresponding target ones
        incrementStepName();
        $stepName = stepName() . ".$sid.edit.ctrlFile";
        @commands = ( 
            "\$ /usr/local/ariba/bin/alter-db-control-file -sourcesid $srcSid -targetsid $sid -sourcevol $srcVolume -targetvol $tgtVolume -file $tgtTmpDir/cr_ctl_$srcSid.sql -time \${afterTime}",
        );
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= "Retries: 2\n";
        $string .= "RetryInterval: 15\n";
        $string .= defineAction( "Shell", "mon$tgtService\@$tgtHost", @commands ) . "\n";
    }

    $controlFileReadyDepends .= "group:$group ";
    return ( $string );
}

sub copyArchiveLogs {
    my ( $self, $schemaType ) = @_;

    nextStepBlock();

    my %sids = %{ $self->sids() };
    my $stepName;
    my $group = "GRP-" . stepName();
    my $expando = "EXP-" . stepName();
    my $srcService = $self->srcService();
    my $rootDepends = $backupCompleteDepends;
    my $string = "";
    my @commands;

    $string .= defineRunGroup( $group, 100 );
    $string .= defineExpando( $expando, stepName() . " Copy Archive Logs" );

    foreach my $sid ( sort( keys( %sids ))) {
        next if ( $schemaType && !$sids{ $sid }->{ 'types' }->{ $schemaType } );

        my $srcSid = $sids{ $sid }->{ 'srcSid' };
        my $srcPriHost = $sids{ $sid }->{ 'srcPriHost' };
        my $srcSecHost = $sids{ $sid }->{ 'srcSecHost' };
        my $tgtHost = $sids{ $sid }->{ 'tgtHost' };
        my $srcVolume = $sids{ $sid }->{ 'srcVolume' };
        my $tgtVolume = $sids{ $sid }->{ 'tgtVolume' };
        my $list = $self->rootTmpDir() . "/$srcSid/copy_list_$sid.txt";
        my $copyTarget = $self->rootTmpDir() . "/$sid";
        $tgtVolume =~ m/.+?(\d+)/;
        my $tgtVolNum = $1;
        $srcVolume =~ m/.+?(\d+)/;
        my $srcVolNum = $1;

        # rotate the redo log on 'source primary db' to create a new archive log
        incrementStepName();
        $stepName = stepName() . ".$srcSid.rotate.logs";
        @commands = ( 
            "\$ alter system switch logfile;",
            "SuccessString: System altered" );
        $string .= defineStep( $stepName, $stepName, $rootDepends, $expando, $group );
        $string .= defineAction( "OracleScript", "$srcSid\@$srcPriHost", @commands ) . "\n";
        setDepends( $stepName );

        # create a list of archive logs to copy
        # this has to be done on the primary db as the sql looks at the literal archive log files.
        # it's not reliable that all logs have copied to the dr host.
        incrementStepName();
        $stepName = stepName() . ".$srcSid.create.log.list";
        @commands = (
            "\$ spool $list",
            "\$ select name from v\$archived_log where dest_id = 1 and sequence# between (select max(sequence#) from v\$archived_log where dest_id = 1 and completion_time < to_date('\${beforeTime}','YYYY-MM-DD:HH24:MI:SS')) and (select min(sequence#) from v\$archived_log where dest_id = 1 and completion_time > to_date('\${afterTime}','YYYY-MM-DD:HH24:MI:SS'));",
            "\$ spool off",
            "ErrorString: no rows selected",
        );
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= "Retries: 5\n";
        $string .= "RetryInterval: 15\n";
        $string .= defineAction( "OracleScript", "$srcSid\@$srcPriHost", @commands ) . "\n";
        setDepends( $stepName );

        # copy the log list to the dr db.  It's from the dr db that the archive logs will be synced to beta
        incrementStepName();
        $stepName = stepName() . ".$srcSid.copy.log.list";
        @commands = ( "\$ rsync -avP -e \"ssh -o StrictHostKeyChecking=no\" $list mon$srcService\@$srcSecHost:$list" );
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= defineAction( "Shell", "mon$srcService\@$srcPriHost", @commands ) . "\n";
        setDepends( $stepName );

        # call remote script to rsync the archive log files in $logList to the beta host
        incrementStepName();
        $stepName = stepName() . ".$srcSid.copy.archive.logs";
        @commands = ( 
            "\$ /usr/local/ariba/bin/copy-archive-logs -log $list -user mon$srcService -host $tgtHost -target $copyTarget -service $srcService",
            "SuccessString: All logs copied",
        );
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= "Retries: 5\n";
        $string .= "RetryInterval: 15\n";
        $string .= defineAction( "Shell", "mon$srcService\@$srcSecHost", @commands ) . "\n";
        setDepends( $stepName );

	    # rename the log files to match the target service
        incrementStepName();
        $stepName = stepName() . ".$srcSid.rename.archive.logs";
        @commands = ( 
            "\$ ls ${copyTarget}/*arc | perl -n -e 'm/${srcSid}_(.+)/ ; print \"\$1\\n\"' | while read i ; do mv ${copyTarget}/${srcSid}_\$i ${copyTarget}/${sid}_\$i ; done",
            "ErrorString:No such file or directory",
        );
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= defineAction( "Shell", "mon$srcService\@$tgtHost", @commands ) . "\n";
        setDepends( $stepName );

        # set the copied log file ownership to oracle:dba
        incrementStepName();
        $stepName = stepName() . ".$sid.chown.archive.logs";
        @commands = ( "\$ sudo chown oracle:dba $copyTarget/*.arc" );
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= defineAction( "Shell", "mon$srcService\@$tgtHost", @commands ) . "\n";
        setDepends( $stepName );

        # copy the archive logs from the target tmp dir to the target log volume
        incrementStepName();
        $stepName = stepName() . ".$sid.copy.logs.to.log.volume";
        @commands = (
            "\$ sudo su oracle -c 'rsync -avP $copyTarget/*.arc /ora${tgtVolNum}log01/oraarch1/$sid'",
        );
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= "Retries: 5\n";
        $string .= "RetryInterval: 15\n";
        $string .= defineAction( "Shell", "mon$srcService\@$tgtHost", @commands ) . "\n";
    }

    $controlFileReadyDepends .= "group:$group ";
    return $string;
}

# Much of this subroutine is hard coded because the current use of addschema to init SV
# is unreliable.  This subroutine will be rewritten when the process is fixed.
sub initSV() {
    my ( $self ) = @_;

    nextStepBlock();

    my $nfs = $self->nfs();
    my $rootDepends = depends();

    my %tables = (
        "app204.bou.ariba.com" => "AddSchemaSVEarlyAccess_Dedicated_Star1.table",
        "app205.bou.ariba.com" => "AddSchemaSVEarlyAccess_Dedicated_Star2.table",
        "app206.bou.ariba.com" => "AddSchemaSVEarlyAccess_Dedicated_Star3.table",
        "app207.bou.ariba.com" => "AddSchemaSVEarlyAccess_Dedicated_Star4.table",
        "app207.bou.ariba.com" => "AddSchemaSVEarlyAccess_Dedicated_Star6.table",
        "app208.bou.ariba.com" => "AddSchemaSVEarlyAccess_Shared.table",
    );

    my $group = "GRP-" . stepName();
    my $expando = "EXP-" . stepName();
    my $installDir = $self->tgtInstallDir( 's4' );
    my $tgtService = $self->tgtService();
    my $string = "";
    my @commands;

    $string .= defineRunGroup( $group, 100 );
    $string .= defineExpando( $expando, stepName() . " Init SV realms" );

    # Loop check that required config file exists (has been copied as part of realms copying)
    incrementStepName();
    my $tgtCopyhost = 'copyhost14.bou.ariba.com';
    my $nfsroot = $nfs->{ 's4' }->{ 'nfsroot' };
    my $stepName = stepName() . ".wait.for.variants.xml.to.be.copied";
    @commands = ( "\$ ls $nfsroot$tgtService/realms/config/variants.xml" );
    $string .= defineStep( $stepName, $stepName, depends(), $expando );
    $string .= "Retries: 1000\n";
    $string .= "RetryInterval: 15\n";
    $string .= defineAction( "Shell", "mon$tgtService\@$tgtCopyhost", @commands ) . "\n";
    setDepends( $stepName );

    foreach my $host ( sort ( keys ( %tables ))) {
        my $table = %tables->{ $host };
        incrementStepName();
        my @commands = ( 
            "\$ chmod 777 $installDir/lib/sql",
            "\$ cd $installDir ; bin/addschema -realmids 0 -inputTableFile config/$table -dropDb -reuseSchemas -debug -readMasterPassword",
        );
        my $stepName = stepName() . ".init.SV.$table";
        $string .= defineStep( $stepName, $stepName, depends(), $expando );
        $string .= "Options: optional\n";
        $string .= defineAction( "Shell", "svc$tgtService\@$host", @commands ) . "\n";
    }

    setDepends( $rootDepends );
    return $string;
}

sub copyRealms {
    my ( $self, $products ) = @_;

    setDepends( $backupCompleteDepends );
    my $string = $self->netappSnapshotAction( $products, 'create' );

    nextStepBlock();

    my %sids = %{ $self->sids() };
    my $stepName;
    my $group = "GRP-" . stepName();
    my $expando = "EXP-" . stepName();
    my $tgtService = $self->tgtService();
    my $srcService = $self->srcService();
    my $rootDepends = depends();
    my $nfs = $self->nfs();
    my @commands;
    my %copy;

    #??? FIX hardcoding;
    my $tgtCopyhost = 'copyhost14.bou.ariba.com';

    $string .= defineRunGroup( $group, 100 );
    $string .= defineExpando( $expando, stepName() . " realms copy" );

    foreach my $product ( @$products ) {
        my $snapshotName = $nfs->{ $product }->{ 'snapshotName' };
        my $snapshotDir = $nfs->{ $product }->{ 'snapshotDir' };
        my $nfsroot = $nfs->{ $product }->{ 'nfsroot' };

        my $rsync;
        if ( $product eq 'buyer' ) {
            $rsync = "rsync -a --exclude=\"transactionData/attachments/*\" --exclude=\"searchIndex/*\" --exclude=\"tempcatalogcontent/*\"";
        } else {
            $rsync = "rsync -a --exclude=\"analysisAppFiles/loadFiles/*\" --exclude=\"logs/*\" --exclude=\"dashboardcache/*\" --exclude=\"analysisAppFiles/adeExport/*\" --exclude=\"analysisAppFiles/starExport/*\"";
        }

        # get a list of dirs in the realms dir that don't start with 'realm'
        my @output;
        my $user = "mon" . $srcService;
        my $pass = ariba::rc::Passwords::lookup( $user );
        my $realmsDir = "/netapp/$product$srcService/.snapshot/$snapshotName/realms";
        my $cmd = "ssh -l $user $tgtCopyhost ls /netapp/$product$srcService/realms | grep -v realm | grep -v AODDataSync | grep -v SystemUsageReports";
        my $ret = ariba::rc::Utils::executeRemoteCommand( $cmd, $pass, 0, undef, undef, \@output );

        # For each non realm dir create an individual rsync command.
        # If we include them all in one command the resulting command is too long pass through ssh.
        my $cmd;
        foreach my $line ( @output ) {
            next if ( $line =~ m/^ / );
            $cmd = "\$ $rsync $realmsDir/$line /netapp/$product$tgtService/realms",
            $copy{ $cmd } = $product;
        }

        # Create rsync commands for the realms dirs
        for ( my $i = 1 ; $i <= 9 ; $i++ ) {
            $cmd = "\$ $rsync $realmsDir/realm_$i\* /netapp/$product$tgtService/realms",
            $copy{ $cmd } = $product;
        }

        # Wait until the snapshot is snapmirrored to the dr volume.
        incrementStepName();
        $stepName = stepName() . ".$product.realms.snapmirror.wait";
        @commands = ( "\$ ls -d $snapshotDir/$snapshotName" );
        $string .= defineStep( $stepName, $stepName, $rootDepends, $expando );
        $string .= "Retries: 10\n";
        $string .= "RetryInterval: 15\n";
        $string .= defineAction( "Shell", "mon$tgtService\@$tgtCopyhost", @commands ) . "\n";
        setDepends( $stepName );

        # move the previous target realms dir
        incrementStepName();
        $stepName = stepName() . ".$product.move.old.realms";
        @commands = ( "\$ if [ -d $nfsroot$tgtService/realms ]; then mv $nfsroot$tgtService/realms $nfsroot$tgtService/realms.old; fi" );
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= defineAction( "Shell", "svc$tgtService\@$tgtCopyhost", @commands ) . "\n";
        setDepends( $stepName );

        # delete the old realms dirs.  Do not make this part of the group so that supsequent steps do not wait on it
        incrementStepName();
        $stepName = stepName() . ".$product.delete.old.realms";
        @commands = ( 
            "\$ rm -rf $nfsroot$tgtService/realms.old",
            "IgnoreExitCode: yes",
            "\$ chmod -R 777 $nfsroot$tgtService/realms.old",
            "\$ rm -rf $nfsroot$tgtService/realms.old",
        );
        $string .= defineStep( $stepName, $stepName, depends(), $expando );
        $string .= defineAction( "Shell", "svc$tgtService\@$tgtCopyhost", @commands ) . "\n";
    }
    setDepends( "group:$group" );

    my $group = "GRP-" . stepName();
    $string .= defineRunGroup( $group, 6 );

    # Copy the realms from the snapshot to the target realms volume
    foreach my $cmd ( sort( keys( %copy ))) {
        incrementStepName();
        my $product = $copy{ $cmd };
        my $stepName = stepName() . ".$product.rsync.data";
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= "Retries: 2\n";
        $string .= "RetryInterval: 15\n";
        $string .= defineAction( "Shell", "svc$tgtService\@$tgtCopyhost", $cmd ) . "\n";
    }

    setDepends( "group:$group" );
    $string .= $self->netappSnapshotAction( $products, 'delete' );

    # realms copying is independent. Nothing should wait on it.  Set the depends value back to rootDepends.
    return ( $string );
}

sub copyData {
    my ( $self, $product, $depends ) = @_;

    nextStepBlock();

    my %sids = %{ $self->sids() };
    my $stepName;
    my $group = "GRP-" . stepName();
    my $expando = "EXP-" . stepName();
    my $tgtService = $self->tgtService();
    my $srcService = $self->srcService();
    my $string = "";
    my @commands;
    my %copy;

    $string .= defineRunGroup( $group, 100 );
    $string .= defineExpando( $expando, stepName() . " $product prep data copy" );

    foreach my $sid ( sort( keys( %sids ))) {
        next unless ( $sids{ $sid }->{ 'product' } eq $product );

        my $srcVolume = $sids{ $sid }->{ 'srcVolume' };
        my $tgtVolume = $sids{ $sid }->{ 'tgtVolume' };
        my $srcSid = $sids{ $sid }->{ 'srcSid' };
        my $tgtHost = $sids{ $sid }->{ 'tgtHost' };
        $tgtVolume =~ m/.+?(\d+)/;
        my $tgtVolNum = $1;

        my $from = "$srcVolume/oradata1/$srcSid";
        my $to = "$tgtVolume/oradata1/$sid";
        my $splitNum = 8;

        # Delete the old data from the target volume and split the source data into 4 directories for parallel copying.
        incrementStepName();
        $stepName = stepName() . ".$sid.prepare.data";
        @commands = ( "\$ sudo su oracle -c '/usr/local/ariba/bin/dirsplit -dir $from -num $splitNum -exclude ^temp'" );
        $string .= defineStep( $stepName, $stepName, $depends, $expando, $group );
        $string .= defineAction( "Shell", "mon$srcService\@$tgtHost", @commands ) . "\n";

        # Create rsync commands for the data copy
        my $cmd;
        for ( my $i = 1; $i <= $splitNum; $i++ ) {
            $cmd = "\$ sudo su oracle -c 'rsync -avP -e \"ssh -o StrictHostKeyChecking=no\" $from/$i/* $to'",
            $copy{ $cmd } = $tgtHost;
        }
        $copy{ $cmd } = $tgtHost;
    }
    setDepends( "group:$group" );
   
    nextStepBlock();

    $group = "GRP-" . stepName();
    $expando = "EXP-" . stepName();
    $string .= defineRunGroup( $group, 8 );
    $string .= defineExpando( $expando, stepName() . " $product data copy" );

    while ( ( my $cmd, my $host ) = each %copy ) {
        incrementStepName();
        $stepName = stepName() . ".rsync.data";
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= "Retries: 2\n";
        $string .= "RetryInterval: 15\n";
        $string .= defineAction( "Shell", "mon$srcService\@$host", $cmd ) . "\n";
    }

    setDepends( "group:$group" );
    return ( $string );
}

sub delete3parSnapshot {
    my ( $self, $product, $baseSS ) = @_;

    nextStepBlock();

    my %sids = %{ $self->sids() };
    my $stepName;
    my $group = "GRP-" . stepName();
    my $expando = "EXP-" . stepName();
    my $tgtService = $self->tgtService();
    my $srcService = $self->srcService();
    my $monHost = $self->monHost( $srcService );
    my $tmid = $self->tmid();
    my $string = "";
    my $lunString = "";
    my @commands;
    my $volPrefix = $baseSS ? "" : "pc1-";
    my $rootDepends = '';

    setDepends( '' );

    $string .= defineRunGroup( $group, 100 );
    $string .= defineExpando( $expando, stepName() . " $product delete db snapshots" );

    foreach my $sid ( sort( keys( %sids ))) {
        next unless ( $sids{ $sid }->{ 'product' } eq $product );
        my $srcVolume = $sids{ $sid }->{ 'srcVolume' };
        push( @commands, "\$ /home/mon$srcService/bin/page/nopage -user fpcAutomation -ttl 120 -note 'db snapshot cleanup' -text $srcVolume" );
    }
    $string .= $self->pageFilter( \@commands, $group, $expando );

    foreach my $sid ( sort( keys( %sids ))) {
        next unless ( $sids{ $sid }->{ 'product' } eq $product );

        my $srcVolume = $sids{ $sid }->{ 'srcVolume' };
        my $tgtHost = $sids{ $sid }->{ 'tgtHost' };
        $srcVolume =~ m/.+?(\d+)/;
        my $srcVolumeNum = $1;

        undef @commands;
        push( @commands, 
            "\$ sudo umount $srcVolume",
            "\$ sudo /usr/local/ariba/bin/filesystem-utility offlineremove -g ora${srcVolumeNum}dg",
        );
        my $VVs = $sids{ $sid }->{ 'VVs' };
        foreach my $lun ( values %$VVs ) {
            push( @commands, "\$ sudo /usr/local/ariba/bin/filesystem-utility removeluns -l $lun" );
        }

        incrementStepName();
        $stepName = stepName() . ".$sid.unmount.db.snapshot";
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= defineAction( "Shell", "mon$tgtService\@$tgtHost", @commands ) . "\n";
    }
    setDepends( "group:$group" );

    $group = "GRP-" . stepName();
    $string .= defineRunGroup( $group, 1 );

    foreach my $sid ( sort( keys( %sids ))) {
        next unless ( $sids{ $sid }->{ 'product' } eq $product );

        undef @commands;
        my $literalHost = $sids{ $sid }->{ 'tgtLiteralHost' };
        my $inservHost = $sids{ $sid }->{ 'inservHost' };

        # delete snapshots from the 3par/inserv host
        my $VVs = $sids{ $sid }->{ 'VVs' };
        while ( my ( $vv, $lun ) = each %$VVs ) {
            $vv = $volPrefix . $vv;
            my $scro = "scro" . $tmid . "-" . $vv;
            my $scrw = "scrw" . $tmid . "-" . $vv;
            push ( @commands,
                "\$ removevlun -f $scrw $lun $literalHost",
                "\$ removevv -f $scrw",
                "\$ removevv -f $scro",
            );
        }
        push( @commands, "ErrorString: Error:" );

        $stepName = stepName() . ".$sid.detete.3par.snapshot";
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= defineAction( "NetworkDevice", "$inservHost", @commands ) . "\n";
    }

    # nothing depends on this step so set the depends value to what it was when we started this subroutine
    setDepends( $rootDepends );
    return ( $string );
}

sub applyControlFile {
    my ( $self, $product, $schemaType ) = @_;

    nextStepBlock();

    my %sids = %{ $self->sids() };
    my $stepName;
    my $group = "GRP-" . stepName();
    my $expando = "EXP-" . stepName();
    my $string = "";
    my @commands;

    $string .= defineRunGroup( $group, 100 );
    $string .= defineExpando( $expando, stepName() . " $product apply control file" );

    my $rootDepends = $controlFileReadyDepends . $dataCopyDepends;

    foreach my $sid ( sort( keys( %sids ))) {
        next unless ( $sids{ $sid }->{ 'product' } eq $product );
        next if ( $schemaType && !$sids{ $sid }->{ 'types' }->{ $schemaType } );

        my $tgtHost = $sids{ $sid }->{ 'tgtHost' };
        my $srcSid = $sids{ $sid }->{ 'srcSid' };
        my $tgtVolume = $sids{ $sid }->{ 'tgtVolume' };
        my $tgtTmpDir = $self->rootTmpDir() . "/$sid";

        # Read the control file into the target db
        incrementStepName();
        $stepName = stepName() . ".$sid.read.ctrlFile";
        @commands = ( 
            "\$ @ $tgtTmpDir/cr_ctl_$sid.sql",
            "Timeout: undef"
         );
        $string .= defineStep( $stepName, $stepName, $rootDepends, $expando, $group );
        $string .= defineAction( "Oracle", "$sid\@$tgtHost", @commands ) . "\n";
        setDepends( $stepName );

        # Turn of archive logging
        incrementStepName();
        $stepName = stepName() . ".$sid.turn.off.archive.logging";
        @commands = (
            "\$ shutdown abort;",
            "\$ startup mount;",
            "\$ alter database noarchivelog;",
            "\$ alter database open;",
        );
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= defineAction( "OracleScript", "$sid\@$tgtHost", @commands ) . "\n";
    }

    setDepends( "group:$group" );
    return ( $string );
    # ??? cleanup src volume on tgt host? this will lead to fstab warnings in monitoring.
}

sub growTablespace {
    my ( $self, $product, $schemaType ) = @_;

    nextStepBlock();

    my %sids = %{ $self->sids() };
    my $stepName;
    my $group = "GRP-" . stepName();
    my $expando = "EXP-" . stepName();
    my $srcService = $self->srcService();
    my $rootDepends = depends();
    my $string = "";
    my @commands;
    my $spoolFile;

    $string .= defineExpando( $expando, stepName() . " $product grow tablespace" );
    $string .= defineRunGroup( $group, 100 );

    foreach my $sid ( sort( keys( %sids ))) {
        next unless ( $sids{ $sid }->{ 'product' } eq $product );
        next if ( $schemaType && !$sids{ $sid }->{ 'types' }->{ $schemaType } );

        my $tgtHost = $sids{ $sid }->{ 'tgtHost' };
        my $tgtTmpDir = $self->rootTmpDir() . "/$sid";

        my $like;
        if ( $product eq 's4' ) {
            $like = '%DATATX%';
        } else {
            $like = '%DATA%';
        }
    
        # Spool sql results to a file
        $spoolFile = "$tgtTmpDir/$sid.growTS";
        incrementStepName();
        @commands = (
            "\$ set linesize 180",
            "\$ set pagesize 5000",
            "\$ spool $spoolFile",
            "\$ select 'alter database datafile '||''''||file_name||''''||' autoextend on maxsize unlimited;' from dba_data_files where tablespace_name like '$like';",
            "\$ spool off",
        );
        $stepName = stepName() . ".spool.sql";
        $string .= defineStep( $stepName, "$sid:Create Sql Script", $rootDepends, $expando, $group );
        $string .= defineAction( "OracleScript", "$sid\@$tgtHost", @commands ) . "\n";
        setDepends( $stepName );

        # Parse out the desired results from the temp file to create an executable sql file
        incrementStepName();
        @commands = ( "\$ sudo su oracle -c 'grep oradata1 $spoolFile > $spoolFile.sql'" );
        $stepName = stepName() . ".grep.sql";
        $string .= defineStep( $stepName, "$sid:Strip out the chaff", depends(), $expando, $group );
        $string .= defineAction( "Shell", "mon$srcService\@$tgtHost", @commands ) . "\n";
        setDepends( $stepName );

        # Run the sql file to extend all tablespace
        incrementStepName();
        @commands = ( "\$ @ $spoolFile.sql" );
        $stepName = stepName() . ".run.sql";
        $string .= defineStep( $stepName, "$sid:Run the Script", depends(), $expando, $group );
        $string .= defineAction( "Oracle", "$sid\@$tgtHost", @commands ) . "\n";
        setDepends( $stepName );
    }

    setDepends( "group:$group" );
    return ( $string );
}

sub changeDbPasswords {
    my ( $self, $product ) = @_;

    nextStepBlock();

    my %sids = %{ $self->sids() };
    my $tgtService = $self->tgtService();
    my $expando = "EXP-" . stepName();
    my $rootDepends = depends();
    my $stepName;
    my $string = "";
    my $dependsGroup;

    $string .= defineExpando( $expando, stepName() . " $product change db passwords" );

    $self->initBetaPW();
    foreach my $sid ( sort( keys( %sids ))) {
        next unless ( $sids{ $sid }->{ 'product' } eq $product );

        my $tgtHost = $sids{ $sid }->{ 'tgtHost' };
        my $group = "GRP-" . stepName();
        $string .= defineRunGroup( $group, 1 );
        $dependsGroup .= "group:$group ";

        # Set the system password
        incrementStepName();
        my $syspass = $self->decryptedSystemPassword( $tgtService );
        my @commands = ( 
            "\$ alter user system identified by $syspass;",
            'SuccessString: User altered',
        );
        $stepName = stepName() . ".system.change.password";
        $string .= defineStep( $stepName, "$sid:system:change password", $rootDepends, $expando, $group );
        $string .= defineAction( "OracleScript", "$sid\@$tgtHost", @commands ) . "\n";

        my $types = $sids{ $sid }->{ 'types' };
        foreach my $type ( sort( keys( %$types ))) {
            my $schemas = $types->{ $type };
            foreach my $schema ( sort( keys( %$schemas ))) {

                my $schemaName = $schemas->{ $schema };
                my $password = ariba::rc::Passwords::decryptUsingDES3Key( $schemaName->{ 'password' } );

                # Set the schema passwords
                incrementStepName();
                @commands = ( 
                    "\$ alter user $schema identified by $password;",
                    'SuccessString: User altered',
                );
                $stepName = stepName() . ".$schema.change.password";
                $string .= defineStep( $stepName, "$sid:$schema:change password", $rootDepends, $expando, $group );
                $string .= defineAction( "OracleScript", "$sid\@$tgtHost", @commands ) . "\n";
            }
        }
    }
    $self->initSuitePW();

    setDepends( $dependsGroup );
    return ( $string );
}

sub dropDbLinks {
    my ( $self, $product, $schemaType ) = @_;

    nextStepBlock();

    my %sids = %{ $self->sids() };
    my $group = "GRP-" . stepName();
    my $expando = "EXP-" . stepName();
    my $string = "";

    $string .= defineExpando( $expando, stepName() . " $product drop db links" );
    $string .= defineRunGroup( $group, 100 );

    foreach my $sid ( sort( keys( %sids ))) {
        next unless ( $sids{ $sid }->{ 'product' } eq $product );
        next if ( $schemaType && !$sids{ $sid }->{ 'types' }->{ $schemaType } );

        my $tgtHost = $sids{ $sid }->{ 'tgtHost' };

        # Drop the db links for the sid
        incrementStepName();
        my @commands = ( "\$ drop public database link dg_standby" );
        my $stepName = stepName() . ".$sid.drop.db.links";
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= defineAction( "OracleScript", "$sid\@$tgtHost", @commands ) . "\n";
    }

    setDepends( "group:$group" );
    return ( $string );
}

sub cleanse {
    my ( $self, $schemaType, $product ) = @_;

    my %sids = %{ $self->sids() };
    my $srcService = $self->srcService();
    my $syspass = $self->decryptedSystemPassword( $srcService );
    my $string = "";
    my $monUser = "mon$srcService";
    my $monHost = $self->monHost( $srcService );
    my $monPass = my $pass = ariba::rc::Passwords::lookup( $monUser );

    foreach my $sid ( sort( keys( %sids ))) {
        next unless ( $sids{ $sid }->{ 'product' } eq $product );
        next if ( $schemaType && !$sids{ $sid }->{ 'types' }->{ $schemaType } );

        my @output;
        my $srcSecHost = $sids{ $sid }->{ 'srcSecHost' };
        my $srcSid = $sids{ $sid }->{ 'srcSid' };
        my $cmd = "ssh -o StrictHostKeyChecking=no -l $monUser $monHost /usr/local/ariba/bin/schema-sizes -sid $srcSid -password $syspass -host $srcSecHost";
        die( "Could not execute command: $cmd" ) unless ( ariba::rc::Utils::executeRemoteCommand( $cmd, $monPass, 0, undef, undef, \@output ));

        foreach my $line ( @output ) {
            next unless ( $line =~ m/^S3LIVE/ );
            my ( $schema, $size ) = split( /\s+/, $line );
            $sids{ $sid }->{ 'types' }->{ $schemaType }->{ uc( $schema ) }->{ 'size' } = $size;
        }
    }

    my $scripts = $self->cleansingScripts( $product );
    $self->initBetaPW();

    foreach my $script ( sort( keys( %$scripts ))) {
        nextStepBlock();

        my $installDir = $self->tgtInstallDir( $product );
        my $sql = $scripts->{ $script };
        $sql =~ m|.+/(.+)\.sql|;
        my $sqlTitle = $1;
        $sql = "@ $installDir/$sql";
        my $dependsGroup;

        my $expando = "EXP-" . stepName();
        $string .= defineExpando( $expando, stepName() . " $product $sqlTitle" );

        foreach my $sid ( sort( keys( %sids ))) {
            next unless ( $sids{ $sid }->{ 'product' } eq $product );
            next unless ( $sids{ $sid }->{ 'types' }->{ $schemaType } );

            my $tgtHost = $sids{ $sid }->{ 'tgtHost' };
            my $group = stepName() . ".$sid";
            $dependsGroup .= "group:$group ";
            $string .= defineRunGroup( $group, 3 );

            my $schemas = $sids{ $sid }->{ 'types' }->{ $schemaType };
            my $loop;
            my $password;
            foreach my $schema ( sort { $schemas->{ $b }->{ size } <=> $schemas->{ $a }->{ size } } keys %$schemas )  {
                incrementStepName();
                my $password = ariba::rc::Passwords::decryptUsingDES3Key( $schemas->{ $schema }->{ 'password' } );
                my $stepName = stepName() . ".$sid.$schema.$sqlTitle";
                $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
                $string .= defineAction( "Oracle", "$schema/$password\@$sid\@$tgtHost", "\$ $sql", "Timeout: undef" , ) . "\n";
            }
        }
        setDepends( $dependsGroup );
    }
    $self->initSuitePW();

    return ( $string );
}

1;

