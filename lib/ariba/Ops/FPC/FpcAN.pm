#
# Base class for cleansing S4 and SSP
#
use strict;

use FindBin;
use lib "/usr/local/ariba/lib";
use lib "$FindBin::Bin/../../lib/";
use lib "$FindBin::Bin/../../lib/perl";

package ariba::Ops::FPC::FpcAN;
use base qw(ariba::Ops::FPC::FpcBase);
use ariba::Ops::MCLGen;
use ariba::Ops::MCL;

use Data::Dumper;
local $Data::Dumper::Useqq  = 1;
local $Data::Dumper::Indent = 3;

sub steps {
    my ( $self, $rootService ) = @_;

    my $string = "";
    $self->setScripts();

#    $string .= $self->checkSpaceStep( 'main' );
    $string .= $self->header( 'AN', $rootService, 'AN export/import/cleanse' );
    $string .= $self->backup( 'main main-edi main-buyer main-supplier', '', 'stop' );
    $string .= $self->backup( 'main main-edi main-buyer main-supplier', '', 'start' );
    $string .= $self->deleteOldVols( 'main' );
    $string .= $self->schemaStep( 'drop' );
    $string .= $self->schemaStep( 'create' );
    $string .= $self->exportImportStep( 'main' );
    $string .= $self->backup( 'main' );
    $string .= $self->deleteOldVols( 'main' );
#    $string .= $self->anStep( 'main', 'set', '777' );
#    $string .= $self->ediStep( 'main-edi' );
#    $string .= $self->anStep( 'main', 'setup' );
#    $string .= $self->backup( 'main' );
#    $string .= $self->anStep( 'main', 'cleanse' );
#    $string .= $self->anStep( 'main', 'storage' );
#    $string .= $self->anStep( 'main', 'passwords' );
#    $string .= $self->anStep( 'main', 'links' );
#    $string .= $self->anStep( 'main', 'copy' );
#    $string .= $self->verificationStep( 'main' );
#    $string .= $self->backup( 'main main-edi' );
#    $string .= $self->anStep( 'main', 'set', '755' );

#    print $MCL $fpc->startAppStep( "Start" );

    return ( $string );
}

sub stringSub {
    my ( $baseString, $subString ) = @_;

    $baseString =~ s|MCL_STRING|$subString|;

    return $baseString;
}

sub setScripts {
    my ( $self ) = @_;

    my $tgtInstallDir = $self->tgtInstallDir( 'an' );
    my $tgtService = $self->tgtService();
    my $srcService = $self->srcService();
    my $buildName = $self->buildName( 'an' );
    my $command = "\$ sudo su oracle -c 'export ORACLE_SID=UCSID; export ORAENV_ASK=NO; . oraenv ; cd $tgtInstallDir/lib/sql/common/scripts; ./bin/andbsql anlive -service $tgtService -site main MCL_STRING -build $buildName -feedback on'";

    $self->{ 'ANscript' } = { 
        set => {
            stepName => "chmod",
            title => "Give full write permissions to the scripts dir",
            command => "\$ sudo su an" . $self->tgtService() . " -c 'chmod PERMISSION $tgtInstallDir/lib/sql/common/scripts'",
            user => "mon",
            type => "Shell",
        },
        setup => { 
            stepName => "AN.ea_setup.mcl",
            title => "Init community schemas and truncate PROD transaction data from directory schemas",
            command => stringSub( $command, '-supplier \"1,3,5,7,9,11,13,15\" -buyer \"2,4,6,8,10,12,14,16\" ../../an/scripts/early_access/ea_setup.mcl' ),
            user => "mon",
            type => "Shell",
        },
        cleanse => {
            stepName => "AN.ea_cleanse.mcl",
            title => "Cleanse the directory database",
            command => stringSub( $command, '../../an/scripts/early_access/ea_cleanse.mcl' ),
            user => "mon",
            type => "Shell",
        },
        storage => {
            stepName => "AN.text_storage_parameters.sql",
            title => "Create intermedia storage",
            command => "\$ @ $tgtInstallDir/lib/sql/an/scripts/40/text_storage_parameters.sql",
            schema => 1,
            type => "Oracle",
        },
        links => {
            stepName => "AN.create.db.links",
            title => "Create DB links",
            command => stringSub( $command, '../../an/scripts/andblink.mcl' ),
            user => "mon",
            type => "Shell",
        },
        passwords => {
            stepName => "AN.cleanse_org_transact_password.mcl",
            title => "Cleanse Passwords",
            command => stringSub( $command, '../../an/scripts/early_access/cleanse_org_transact_password.mcl' ),
            user => "mon",
            type => "Shell",
        },
        copy => {
            stepName => "AN.Copy.EA.files",
            title => "Copy EA Files",
            command => "\$ /home/monbeta/bin/copy-an-early-access-files $srcService $tgtService",
            user => "an",
            type => "Shell",
        },
    };
}

sub deleteOldVols {
    my ( $self, $schemaType ) = @_;

    nextStepBlock();

    my $string;
    my $group = "GRP-" . stepName();
    my $expando = "EXP-" . stepName();
    my $title = stepName() . ".delete old volumes";
    my $sid = 'ANBTA2';
    my %sids = %{ $self->sids() };

    my %clean;
    foreach my $sid ( sort( keys( %sids ))) {
        next unless ( $sids{ $sid }->{ 'types' }->{ $schemaType } );

        $clean{ $sids{ $sid }->{ 'srcPriHost' } } = "/datapump01";
        $clean{ $sids{ $sid }->{ 'tgtHost' } } = $sids{ $sid }->{ 'tgtVolume' } . "/oraexp1";
    }

    $string .= defineRunGroup( $group, 100 );
    $string .= defineExpando( $expando, $title );

    while ( my ( $host, $dir ) = ( each %clean )) {
        incrementStepName();
        my $stepName = stepName() . ".clean.$host";
        my $command = "\$ sudo su oracle -c 'rm -rf $dir/ANLIVE_*'"; 
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= defineAction( "Shell", "mon".$self->srcService()."\@$host", $command ) . "\n";
    }

    setDepends( "group:$group" );
    return $string;
}

sub schemaStep {
    my ( $self, $action ) = @_;

    nextStepBlock();

    my @command;
    my $stepName;
    my $allGroups = "";
    my $string = "";
    my %sids = %{ $self->sids() };
    my $expando = "EXP-" . stepName();
    my $title = stepName() . ".$action.schemas";
    my $tgtService = $self->tgtService();
    my $oracleAction = $action eq 'drop' ? "OracleScript" : "Oracle";

    $string .= defineExpando( $expando, $title );

    # loop over all schemas on all sids and drop/create them
    # when creating schemas, some have non standard values, thus the if-else block
    $self->initBetaPW();
    foreach my $sid ( sort( keys( %sids ))) {
        my $product = $sids{ $sid }->{ 'product' };
        my $tgtHost = $sids{ $sid }->{ 'tgtHost' };

        while ( my ( $schemaType, $typeRef ) = ( each %{ $sids{ $sid }->{ 'types' }})) {

            # create a separate run group for each sid.  Conflicts have been seen when multiple
            # schemas were simultaneouls actioned.
            my $group = "GRP-" . stepName();
	        $allGroups .= "group:$group ";
            $string .= defineRunGroup( $group, 1 );

            foreach my $schema ( sort ( keys %{ $typeRef } )) {
                if ( $action eq "drop" ) {
                    @command = ( "\$ BEGIN",
                                 "\$   EXECUTE IMMEDIATE 'drop user $schema cascade';",
                                 "\$ EXCEPTION",
                                 "\$   WHEN OTHERS THEN",
                                 "\$     IF SQLCODE != -01918 THEN",
                                 "\$       RAISE;",
                                 "\$     END IF;",
                                 "\$ END;",
                                 "\$ /",
                               );
                } else {
                    my $dataValue = 40;
                    my $userType = 'AN49';
                    my $password = ariba::rc::Passwords::decryptUsingMasterPassword( $sids{ $sid }->{ 'types' }->{ $schemaType }->{ $schema }->{ 'password' } );

                    if ( $schema eq 'ANLIVE' ) {
                        $dataValue = 240;
                    } elsif ( $schema eq 'EDILIVE1' ) {
                        $dataValue = 350;
                        $userType = 'EDI';
                    }
                    $schema =~ m/(.+)LIVE(\d*)/;
                    @command = ( "\$ \@/oracle/admin/scripts/common/cr_schema_11g " . uc($1) . "DATA$2 $dataValue " . uc($schema) . " $userType $password\n" );
                }
                incrementStepName();
                $stepName = stepName() . ".$action.$schema";    
                $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
                $string .= "Retries: 5\n";
                $string .= "RetryInterval: 15\n";
                $string .= defineAction( $oracleAction, "$sid\@$tgtHost", @command ) . "\n";
            }
        }
    }
    $self->initSuitePW();

    setDepends( $allGroups );
    return $string;
}

sub ediStep {
    my ( $self, $schemaType ) = @_;

    nextStepBlock();

    my @command;
    my $stepName;
    my $string = "";
    my %sids = %{ $self->sids() };
    my $group = "GRP-" . stepName();
    my $expando = "EXP-" . stepName();
    my $title = stepName() . ".edi.sql";
    my $rootDepends = depends();
    my @mcls = ( "schema-sync.mcl", "init-db.mcl" );
    my $buildName = $self->buildName( 'an' );
    my $tgtService = $self->tgtService();
    my $tgtInstallDir = $self->tgtInstallDir( 'an' );

    $string .= defineExpando( $expando, $title );

    foreach my $sid ( keys %sids ) {
        next unless ( $sids{ $sid }->{ 'types' }->{ $schemaType } );

        my $tgtHost = $sids{ $sid }->{ 'tgtHost' };
        foreach my $schema ( keys %{ $sids{ $sid }->{ 'types' }->{ $schemaType } } ) {

            $group = "GRP-" . stepName();
    	    $string .= defineRunGroup( $group, 1 );
            my $firstTime = 1;
            my $dep;
            foreach my $mcl ( @mcls ) {
                if ( $firstTime ) {
                    $firstTime = 0;
                    $dep = $rootDepends;
                } else {
                    $dep = depends();
                }
                incrementStepName();
                $stepName = stepName() . ".$schema.$mcl";    
                @command = ( 
                    "\$ sudo su oracle -c 'export ORACLE_SID=$sid; export ORAENV_ASK=NO; . oraenv; cd $tgtInstallDir/lib/sql/common/scripts; ./bin/andbsql $schema -service $tgtService -site $schemaType ../../an/scripts/sampledata/edi/$mcl -build $buildName -feedback on'" 
                );

                $string .= defineStep( $stepName, $stepName, $dep, $expando, $group );
                #$string .= defineAction( "Shell", "mon$tgtService\@$tgtHost", @command ) . "\n";
                $string .= defineAction( "Wait", undef, "Run this manually\n" . @command[0] ) . "\n";
        
                setDepends( $stepName );
            }
            incrementStepName();
            $stepName = stepName() . ".schema.stats";    
            @command = ( "\$ exec dbms_stats.gather_schema_stats(NULL, GRANULARITY => 'ALL', CASCADE => TRUE)" );
            $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
            #$string .= defineAction( "Oracle", "$schema\@$sid\@$tgtHost", @command ) . "\n";
            $string .= defineAction( "Wait", undef, "Run this manually as EDILIVE1\@EDIBTA1\@db22.bou \n" . @command[0] ) . "\n";
        }
    }

    setDepends( $rootDepends );
    return $string;
}

sub exportImportStep {
    my ( $self, $schemaType ) = @_;

#??? check for existence of /datapump01
#??? verify there are exported files to rsync before starting rsync
#??? this can run in parallel with the schema drop/create on the target side

    nextStepBlock();

    my @command;
    my $stepName;
    my $string = "";
    my %sids = %{ $self->sids() };
    my $group = "GRP-" . stepName();
    my $expando = "EXP-" . stepName();
    my $title = stepName() . ".AN.export.import";
    my $srcService = $self->srcService();
    my $tgtService = $self->tgtService();

    my $srcSysPass = $self->decryptedSystemPassword( $srcService );
    my $tgtSysPass = $self->decryptedSystemPassword( $tgtService );

    $string .= defineRunGroup( $group, 1 );
    $string .= defineExpando( $expando, $title );

    foreach my $sid ( sort( keys( %sids ))) {
        next unless ( $sids{ $sid }->{ 'types' }->{ $schemaType } );

        my $srcPriHost = $sids{ $sid }->{ 'srcPriHost' };
        my $tgtHost = $sids{ $sid }->{ 'tgtHost' };
        my $tgtVolume = $sids{ $sid }->{ 'tgtVolume' };
        my $product = $sids{ $sid }->{ 'product' };
        my $srcSid = $sids{ $sid }->{ 'srcSid' };

        my ($sec, $min, $hr, $day, $mon, $year) = localtime(time);
        my $blockDate = sprintf( "%04d%02d%02d", $year+1900, $mon+1, $day );
        my $date = sprintf( "%02d-%02d-%04d %02d:%02d:%02d", $mon+1, $day, $year+1900, $hr, $min, $sec );

        my $schema;
        foreach my $key ( keys %{$sids{ $sid }->{ 'types' }->{ $schemaType } } ) {
            $schema = $key
        }

        # set dir permissions on rsync receiving dir to 777
        incrementStepName();
        @command = ( "\$ sudo su oracle -c 'chmod 777 $tgtVolume/oraexp1'" );
        $stepName = stepName() . ".chmod.777.tgt.dir";    
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= defineAction( "Shell", "mon$srcService\@$tgtHost", @command ) . "\n";

#??? how is DIR1 set?  Do I need to worry about checking for it?
#??? does expdp or impdp require running from relative dir?
        # log into prod db and export the data to /datapump01
        incrementStepName();
        @command = ( 
            "\$ sudo su oracle -c 'export ORACLE_SID=$srcSid; export ORAENV_ASK=NO; . oraenv ; expdp system/$srcSysPass schemas=$schema directory=DIR1 dumpfile=${schema}_%U.dmp exclude=statistics filesize=25G job_name=expdp_${schema}_$blockDate flashback_time=sysdate parallel=4 logfile=expdp_${schema}_$blockDate.log'",
            #??? make PASSWORD work for Shell command line args
            #"\$ sudo su oracle -c 'export ORACLE_SID=$srcSid; export ORAENV_ASK=NO; . oraenv ; expdp system/PASSWORD:$srcService:$srcSysPass schemas=$schema directory=DIR1 dumpfile=${schema}_%U.dmp exclude=statistics filesize=25G job_name=expdp_${schema}_$blockDate flashback_time=sysdate parallel=4 logfile=expdp_${schema}_$blockDate.log'", 
            "SuccessString:successfully completed",
        );
        $stepName = stepName() . ".export";    
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= defineAction( "Shell", "mon$srcService\@$srcPriHost", @command ) . "\n";
        setDepends( $stepName );

        # Change the file permissions on the archived files to 644 for global read permissions
        incrementStepName();
        @command = ( "\$ sudo su oracle -c 'chmod 644 /datapump01/${schema}_*'" );
        $stepName = stepName() . ".chmod.644.dump.files";    
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= defineAction( "Shell", "mon$srcService\@$srcPriHost", @command ) . "\n";
        setDepends( $stepName );

        # rsync the data dump from prod to beta
        incrementStepName();
        @command = ( "\$ rsync -auv -e \"ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null\" /datapump01/ANLIVE_* mon$srcService\@$tgtHost:$tgtVolume/oraexp1" );
        $stepName = stepName() . ".copy";    
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= "Retries: 3\n";
        $string .= "RetryInterval: 15\n";
        $string .= defineAction( "Shell", "mon$srcService\@$srcPriHost", @command ) . "\n";
        setDepends( $stepName );

        # reset dir permission on target host to 755 and 'chown oracle:dba' to the copied files
        incrementStepName();
        @command = ( 
            "\$ sudo su oracle -c 'chmod 755 $tgtVolume/oraexp1'",
            "\$ sudo su -c 'chown oracle:dba $tgtVolume/oraexp1/ANLIVE_*",
        );
        $stepName = stepName() . ".chmod.775";    
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= defineAction( "Shell", "mon$srcService\@$tgtHost", @command ) . "\n";
        setDepends( $stepName );

        # prep the target db host for data import
        incrementStepName();
        @command = ( 
            "\$ create directory AN49 as '$tgtVolume/oraexp1/'",
            "SuccessString: ORA-00955",
            "\$ grant read, write on directory AN49 to public",
        );
        $stepName = stepName() . ".import.prep";    
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= defineAction( "OracleScript", "$sid\@$tgtHost", @command ) . "\n";
        setDepends( $stepName );

        # import AN data on target host
        incrementStepName();
        @command = ( 
            "\$ export ORACLE_SID=$sid; export ORAENV_ASK=NO; . oraenv ; impdp system/$tgtSysPass schemas=$schema directory=AN49 dumpfile=${schema}_%U.dmp job_name=impdp_$schema parallel=4 logfile=impdp_${schema}_$blockDate.log",
        );
        $stepName = stepName() . ".import";    
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= defineAction( "Shell", "mon$tgtService\@$tgtHost", @command ) . "\n";
        setDepends( $stepName );

        # stats collection
        incrementStepName();
        @command = ( "\$ exec dbms_stats.gather_schema_stats(NULL, GRANULARITY => 'ALL', CASCADE => TRUE)" );
        $stepName = stepName() . ".stats.collection";    
        $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
        $string .= defineAction( "OracleScript", "$schema\@$sid\@$tgtHost", @command ) . "\n";
    }
    
    setDepends( "group:$group" );
    return $string;
}

sub anStep {
    my ( $self, $schemaType, $action, $permission ) = @_;

    nextStepBlock();

    my $string = "";
    my %sids = %{ $self->sids() };
    my $sid;

    SIDCHECK:
    foreach my $s ( keys %sids ) {
        # Find the SID matching the desired schema type
        if ( $sids{ $s }->{ 'types' }->{ $schemaType } ) {
            $sid = $s;
            last SIDCHECK;
        }
    }

    my $user;
    my $schema = "";
    my $command = $self->{ 'ANscript' }->{ $action }->{ 'command' };
    my $stepName = stepName . "." .$self->{ 'ANscript' }->{ $action }->{ 'stepName' };
    my $title = stepName() . "." . $self->{ 'ANscript' }->{ $action }->{ 'title' };
    my $actionType = $self->{ 'ANscript' }->{ $action }->{ 'type' };
    my $user = $self->{ 'ANscript' }->{ $action }->{ 'user' };
    my $ucSid = uc( $sid );

    $command =~ s/PERMISSION/$permission/g if ( $permission );
    $command =~ s/UCSID/$ucSid/g;
    if ( $self->{ 'ANscript' }->{ $action }->{ 'schema' } ) {
        foreach my $key ( keys %{ $sids{ $sid }->{ 'types' }->{ $schemaType } } ) {
            $schema = $key . "@";
        }
        $user = $sid;
    } else {
        $user = $self->{ 'ANscript' }->{ $action }->{ 'user' } . $self->tgtService();
    }

    $string .= defineStep( $stepName, $title, depends() );
    if ( $action eq 'cleanse' || $action eq 'links' ) {
        $string .= defineAction( "Wait", undef, "Run this manually \n" . $command ) . "\n";
    } else {
        $string .= defineAction( $actionType, "${schema}${user}\@$sids{ $sid }->{ 'tgtHost' }", $command ) . "\n";
    }

    setDepends( $stepName );
    return $string;
}

sub verificationStep {
    my ( $self, $schemaType ) = @_;

    nextStepBlock();

    my $stepName;
    my $string = "";
    my $group = "GRP-" . stepName();
    my $expando = "EXP-" . stepName();
    my $title = stepName() . " verification sql";
    my %sids = %{ $self->sids() };
    my $rootDepends = depends();
    my @sqls = ( "\$ select count(1) from PERSON where EMAIL_ADDRESS != 'no-reply\@ansmtp-ea.ariba.com'",
                 "\$ select count(1) from ORG where MAIN_EMAIL_ADDRESS != 'no-reply\@ansmtp-ea.ariba.com'",
                 "\$ select count(1) from ORG_PREFERENCE where (NAME LIKE '%email' OR NAME LIKE '%supplierlink%mail.toaddress' OR NAME LIKE '%email_address' OR NAME LIKE '%or_email_%') AND (VALUE != 'no-reply\@ansmtp-ea.ariba.com')",
                 "\$ select count(1) from LEGAL_RECORD where ACCEPTOR_EMAIL_ADDRESS != 'no-reply\@ansmtp-ea.ariba.com'",
                 "\$ select count(1) from RFX_EVENT where contact_email_address != 'no-reply\@ansmtp-ea.ariba.com'",
                 "\$ select count(1) from ORG_NOTFN_PREFERENCE where VALUE != 'no-reply\@ansmtp-ea.ariba.com'",
                 "\$ select count(1) from ORG where ANID like 'AN%'" );

    my @command;
    foreach my $sql ( @sqls ) {
        push ( @command, $sql );
        push ( @command, 'SuccessString: ^\s*0\s*$' );
    }

    $string .= defineExpando( $expando, $title );
    $string .= defineRunGroup( $group, 100 );

    foreach my $sid ( keys %sids ) {
        next unless ( $sids{ $sid }->{ 'types' }->{ $schemaType } );

        my $tgtHost = $sids{ $sid }->{ 'tgtHost' };
        foreach my $schema ( keys %{ $sids{ $sid }->{ 'types' }->{ $schemaType } } ) {
            incrementStepName();
            $stepName = stepName() . ".$schema.verification";    
            $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
            $string .= defineAction( "OracleScript", "$schema\@$sid\@$tgtHost", @command ) . "\n";
        }
    }

    setDepends( "group:$group" );
    return $string;
}

1;

