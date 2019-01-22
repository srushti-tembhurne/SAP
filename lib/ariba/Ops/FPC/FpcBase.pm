#
# Base class for FPC migrations
#
use strict;

use FindBin;
use lib "/usr/local/ariba/lib";
use lib "/usr/local/ariba/bin";
use lib "$FindBin::Bin/../../lib/";
use lib "$FindBin::Bin/../../lib/perl";

package ariba::Ops::FPC::FpcBase;
use ariba::rc::ArchivedProduct;
use ariba::rc::Globals;
use ariba::Ops::DBConnection;
use ariba::Ops::MCLGen;
use ariba::Ops::MCL;
use ariba::Ops::FileSystemUtilsRPC;
use ariba::monitor::Url;
use ariba::Ops::Machine;
use ariba::Ops::NetworkDeviceManager;

use Data::Dumper;
local $Data::Dumper::Useqq  = 1;
local $Data::Dumper::Indent = 3;

my $SSH_ERR = "Could not get valid output from remote ssh command.  There is no solution aside from running this script again.  Please do so.\n";

sub lunCounter {
    my ( $self, $literalHost ) = @_;

    my $lun = $self->{ 'lunCounter' }->{ $literalHost };
    $self->{ 'lunCounter' }->{ $literalHost }++;

    return $lun;
}

# Add each unique inserv host to the hash and look up it's next lun number
sub setLunCounter {
    my ( $self, $inservHost, $literalHost ) = @_;

    unless ( $self->{ 'lunCounter' }->{ $literalHost } ) {
        my $inservMachine = ariba::Ops::Machine->new( $inservHost );
        my $netDevice = ariba::Ops::NetworkDeviceManager->newFromMachine( $inservMachine );
        my $lun = $netDevice->nextAvailableLun( $literalHost );
        $self->{ 'lunCounter' }->{ $literalHost } = $lun;
    }
}

sub setRootTmpDir {
    my ( $self, $tgtService ) = @_;

    $self->{ 'rootTmpDir' } = '/tmp/fpc';
}

sub rootTmpDir {
    my ( $self ) = @_;

    return $self->{ 'rootTmpDir' };
}

sub tgtService {
    my ( $self ) = @_;

    return $self->{ 'tgtService' };
}

sub setTgtService {
    my ( $self, $tgtService ) = @_;

    $self->{ 'tgtService' } = $tgtService;
}

sub srcService {
    my ( $self ) = @_;

    return $self->{ 'srcService' };
}

sub setSrcService {
    my ( $self, $srcService ) = @_;

    $self->{ 'srcService' } = $srcService;
}

sub copyhost {
    my ( $self, $service ) = @_;

    return $self->{ $service }->{ 'copyhost' };
}

sub buildName {
    my ( $self, $product ) = @_;

    return $self->{ $product }->{ 'buildName' };
}

sub tgtInstallDir {
    my ( $self, $product ) = @_;

    return $self->{ $product }->{ 'tgtInstallDir' };
}

sub tmid {
    my ( $self ) = @_;

    return $self->{ 'tmid' };
}

sub setTmid {
    my ( $self, $tmid ) = @_;

    $self->{ 'tmid' } = $tmid;
}

sub sids {
    my ( $self ) = @_;

    return $self->{ sids };
}

sub srcSid {
    my ( $self, $sid ) = @_;

    return $self->{ sids }->{ $sid }->{ 'srcSid' };
}

sub tgtLiteralHost {
    my ( $self, $sid ) = @_;

    return $self->{ sids }->{ $sid }->{ 'tgtLiteralHost' };
}

sub srcSecHost {
    my ( $self, $sid ) = @_;

    return $self->{ sids }->{ $sid }->{ 'srcSecHost' };
}

sub tgtVolume {
    my ( $self, $sid ) = @_;

    return $self->{ sids }->{ $sid }->{ 'tgtVolume' };
}

sub setSuitePW {
    my ( $self, $suitePW ) = @_;

    $self->{ 'suitePW' } = $suitePW;
}

sub suitePW {
    my ( $self ) = @_;

    return $self->{ 'suitePW' };
}

sub initBetaPW {
    my ( $self ) = @_;

    my $pw = ariba::rc::Passwords::lookup( 'betaMaster' );
    ariba::rc::Passwords::reinitialize( 'beta', $pw );
}

sub setEmailDomain {
    my ( $self, $productObject ) = @_;

    my $email = $productObject->default( 'Application.Base.Data.AribaSystemUserEmailAddress' );
    $email =~ m/.+@(.+)/; 
    my $domain = $1;

    $self->{ 'emailDomain' } = $1;
}

sub emailDomain {
    my ( $self ) = @_;

    return $self->{ 'emailDomain' };
}

sub initSuitePW {
    my ( $self ) = @_;

    # ??? fix hard coding 'prodsuite'
    my $pw = $self->suitePW();
    ariba::rc::Passwords::reinitialize( 'prodsuite', $pw );
}

sub header {
    my ( $self, $product, $service, $title ) = @_;

    my $string = "#!/usr/local/ariba/bin/mcl\n";
    $string .= "\n";
    $string .= "MCLTitle: $title\n";
    $string .= "AllowGroupChanges\n";
    $string .= "Variable: SERVICE=$service\n\n";
    if ( $product eq 'ss' ) {
        $string .= "Variable: beforeTime=null\n";
        $string .= "Variable: afterTime=null\n\n";
    }
    return $string;
}

sub pageFilter {
    my ( $self, $commands, $group, $expando ) = @_;

    my $srcService = $self->srcService();
    my $monHost = $self->monHost( $srcService );
    my $string = "";

    incrementStepName();
    my $stepName = stepName() . ".set.page.filters";
    $string .= defineStep( $stepName, $stepName, depends(), $expando, $group );
    $string .= defineAction( "Shell", "mon$srcService\@$monHost", @$commands ) . "\n";

    setDepends( $stepName );
    return( $string );
}

sub getTimeStamp {
    my ( $self, $timeVariable ) = @_;

    nextStepBlock();
    my $string = "";
    my @commands;
    my $stepName = stepName() . ".$timeVariable";
    my $subtractTime = 0;

    $subtractTime = 120 if ( $timeVariable eq 'beforeTime' );

    @commands = ( 
        "\$ date --date '-$subtractTime min' '+%Y-%m-%d:%H:%M:%S'",
        'SuccessString: \d\d\d\d-\d\d-\d\d:\d\d:\d\d:\d\d',
    );

    $string .= defineStep( $stepName, "get $timeVariable time stamp", depends() );
    $string .= "Store: $timeVariable=(\\d\\d\\d\\d-\\d\\d-\\d\\d:\\d\\d:\\d\\d:\\d\\d)\n";
    $string .= defineAction( "Shell", undef, @commands ) . "\n";

    setDepends( $stepName ); 
    return $string;
}

sub wait {
    my ( $self, $stepDescription ) = @_;

    nextStepBlock();
    my $string = "";
    my $stepName = stepName();

    $string .= defineStep( $stepName, "Wait State", depends() );
    $string .= defineAction( "Wait", undef, $stepDescription ) . "\n";

    setDepends( $stepName ); 
    return $string;
}

sub startApp {
    my ( $self, $action ) = @_;

    nextStepBlock();
    my $string = "";

    my %sids = %{ $self->sids() };
    my $tgtService = $self->tgtService();
    my $host = $self->copyhost( $tgtService );

    my $expando = "EXP-" . stepName();
    my $title = stepName() . " Start App";
    $string .= defineExpando( $expando, $title );

    my $stepName = stepName() . ".App.Startup";
    my @commands = ( "\$ " . $self->tgtInstallDir() . "/bin/control-deployment -cluster primary incomplete $tgtService $action" );
    $string .= defineStep( $stepName, $stepName, depends(), $expando );
    $string .= defineAction( "Shell", "mon$tgtService\@$host", @commands ) . "\n";

    setDepends ( $stepName );
    return $string;
}

sub backupSubStep {
    my ( $self, $sid, $action, $expando, $group ) = @_;

    my $string = "";
    my $stepName;
    my @commands;
    my $title;

    my %sids = %{ $self->sids() };

    incrementStepName();
    if ( $action ) {
        # Starting or stopping the SIDS/DB
        @commands = ( "\$ /usr/local/ariba/bin/database-control -n -k $action $sid -readMasterPassword" );
        $title = "$action sid: $sid";
        $stepName = stepName() . ".db.$action";
    } else {
        # Taking a bcv snapshot of the SIDS/DB
        my $tmid = $self->tmid();
        my $product = $sids{ $sid }->{ 'product' };
        $stepName = stepName();
        $stepName =~ s/\.//g;
        my $altStepName = $1;
        @commands = ( "\$ sudo /usr/local/ariba/bin/filesystem-device-details -f -s $sid",
                      "\$ sudo /usr/local/ariba/bin/bcv-backup -sid $sid -volType data01 -d -bcv $altStepName$product$tmid -snap" ); 
        $title = "BCV Snapshot of sid: $sid";
        $stepName = stepName() . ".bcv.$sid";
    }

    $string .= defineStep( $stepName, $title, depends(), $expando, $group );
    $string .= defineAction( "Shell", "mon".$self->srcService()."\@$sids{ $sid }->{ 'tgtHost' }", @commands ) . "\n";

    setDepends ( $stepName );
    return $string;
}

#??? fix this to work if $schemaTypes is null (process all sids regardelss of type)
sub getSidsToAction {
    my ( $self, $product, $schemaTypes ) = @_;

    my %sids = %{ $self->sids() };
    my @schemaArray = split ' ', $schemaTypes;
    my @sidsToAction;

    foreach my $sid ( sort( keys( %sids ))) {
        foreach my $type ( @schemaArray ) {
            next unless ( $sids{ $sid }->{ 'types' }->{ $type } );
            next if ( $product && $sids{ $sid }->{ 'product' } ne $product );

            push ( @sidsToAction, $sid ) unless ( grep ( /^$type/, @sidsToAction ) );
        }
    }
    return @sidsToAction;
}

sub backup {
    my ( $self, $schemaTypes, $product, $action ) = @_;

    nextStepBlock();
    my $string = "";
    my @sidsToAction;
    my $rootDepends = depends();

    my $expando = "EXP-" . stepName();
    my $group = "GRP-" . stepName();
    my $title = stepName() . " Backup DBs";
    $string .= defineExpando( $expando, $title );
    $string .= defineRunGroup( $group, 100 );

    my @sidsToAction = getSidsToAction ( $self, $product, $schemaTypes );
    my @actionLoop = $action ? $action : @{ [ 'stop', '', 'start' ] };

    foreach my $sid ( @sidsToAction ) {
        setDepends( $rootDepends );
        foreach my $actn ( @actionLoop ) {
            $string .= $self->backupSubStep( $sid, $actn, $expando, $group );
        }
    }

    setDepends( "group:$group" );
    return $string ;
}

sub getDataVolume {
    my ( $service, $sid, $host ) = @_;

    my @volumes = ariba::Ops::FileSystemUtilsRPC::fileSystemsForSidAndHost( $sid, $host, $service );
    foreach my $vol ( @volumes ) {
        return $vol unless ( $vol =~ m/log/ || $vol =~ m/rman/ );
    }
}

sub setPasswordAndHosts {
    my ( $self, $service ) = @_;

    my ( $productObject, $foo ) = getProductObject( 'mon', $service );

    my $syspass = $productObject->default( "dbainfo.system.password" );
    $self->{ $service }->{ 'syspass' } = $syspass;

    my @hosts = $productObject->hostsForRoleInCluster( 'monserver', 'primary' );
    $self->{ $service }->{ 'monHost' } = shift( @hosts );

     @hosts = $productObject->hostsForRoleInCluster( 'copyhost', 'primary' );
    $self->{ $service }->{ 'copyhost' } = shift( @hosts );
}

sub monHost {
    my ( $self, $service ) = @_;

    return $self->{ $service }->{ 'monHost' };
}

sub encryptedSystemPassword {
    my ( $self, $service ) = @_;
 
    return $self->{ $service }->{ 'syspass' };
}

sub decryptedSystemPassword {
    my ( $self, $service ) = @_;
 
    my $enc = $self->{ $service }->{ 'syspass' };
    my $syspass = ariba::rc::Passwords::decryptValueForSubService( $self->{ $service }->{ 'syspass' }, $service );

    return $syspass;
}

sub getInservAndVVs {
    my ( $self, $service, $sid, $host, $tgtLiteralHost ) = @_;

    my %VVs;
    my @output;
    my $inservHost;

    # get the password for the required user
    my $user = "mon" . $service;
    my $pass = ariba::rc::Passwords::lookup( $user );

    # find the inserv host for the source db host.
    my $cmd = "ssh -o StrictHostKeyChecking=no -l $user $host sudo '/usr/local/ariba/bin/filesystem-device-details -x -s $sid'";

    my $count = 4;
    while ( $count >= 0 && !$inservHost ) {
        die "Could not execute command: $cmd" unless ( ariba::rc::Utils::executeRemoteCommand( $cmd, $pass, 0, undef, undef, \@output ));
        foreach my $line ( @output ) {
            if ( $line =~ m/^Inserv: (.+)/ ) {
                $inservHost = $1;
                last;
            }
        }
        $count--;
    }
    die "$cmd\n $SSH_ERR" unless $inservHost;

    $self->setLunCounter( $inservHost, $tgtLiteralHost );

    # Create a hash of VVs
    my $foundDataVolume = 0;
    foreach my $vv ( @output ) {
       # Volume markers start with '#'.  If one is found check if it is the data volume.
       # If it is then set the flag and parse all further found VVs until a non data volume
       # marker is found (or eof)
       if ( $vv =~ m/^#/ ) {
           if ( $vv =~ m/^#.+data/ ) {
               $foundDataVolume = 1;
           } else {
               $foundDataVolume = 0;
           }
           next;
       }
       next unless $foundDataVolume;
       if ( $vv =~ m/^VV: (\d+?.+)/ ) {
           my $lun = $self->lunCounter( $tgtLiteralHost );
           $VVs{ $1 } = $lun;
       }
    }

    return ( $inservHost, \%VVs );
}

sub _sendCommand {
    my ( $host, $service, $cmd, $regex ) = @_;

    my @output;
    my $found;

    # get the password for the required user
    my $user = "mon" . $service;
    my $pass = ariba::rc::Passwords::lookup( $user );
    my $fullCommand = "ssh -o StrictHostKeyChecking=no -l $user $host \"$cmd\"";
    
    my $count = 4;
    while ( $count >= 0 && !$found ) {
        die "$!, Could not execute command: $fullCommand" unless ( ariba::rc::Utils::executeRemoteCommand( $fullCommand, $pass, 0, undef, undef, \@output ));
        if ( $regex ) {
            foreach my $line ( @output ) {
                if ( $line =~ $regex ) {
                    $found = $1;
                    last;
                }
            }
        } else {
            $found = 1;
            last;
        }
        $count--;
    }
    die "$fullCommand\n $SSH_ERR" unless $found;

    return $found;
}

sub getLiteralHost {
    my ( $self, $host, $service ) = @_;

    # get the literal db host name of the target db.  eg db27.bou
    my $cmd = "hostname";
    my $regex = qr /(.+).ariba.com/;

    return ( _sendCommand( $host, $service, $cmd, $regex )); 
}

sub getSrcInstalledBuildName {
    my ( $self, $product, $service ) = @_;
    
    my $host = $self->copyhost( $service );

    # find the inserv host for the source db host.
    my $cmd = "/usr/local/ariba/bin/product-info -installed -product $product -service $service";
    my $regex = qr /^buildname: (.+)/;

    return( _sendCommand( $host, $service, $cmd, $regex ));    
}

sub getProductObject {
    my ( $product, $service, $buildName ) = @_;

    my @dbConnections;
    my $productObj;

    print "looking up product db structure for: $product $service $buildName\n";
    die ( "Archived deployment not found for: $product $service $buildName\n" ) unless 
        ariba::rc::ArchivedProduct->isArchived( $product, $service, $buildName );
    $productObj = ariba::rc::ArchivedProduct->new( $product, $service, $buildName );
    $productObj->setClusterName( 'primary' );
    $productObj->setReturnEncryptedValues(1);
    
    my @dbProducts = qw( an s4 buyer );  # ??? fix to use constants
    if ( grep { $_ eq $product } @dbProducts ) { 
        @dbConnections = ariba::Ops::DBConnection->connectionsFromProducts( $productObj );
        @dbConnections = grep { !$_->dbType() || $_->dbType ne 'hana' } @dbConnections;
    }
 
    return ( $productObj, \@dbConnections );
}

sub getAppHost {
    my ( $productObject ) = @_;

    my @hosts = $productObject->allHosts();

    my $appHost;
    my $maxMemory;
    foreach my $host ( @hosts ) {
        next unless ( $host =~ m/^app/ );
        my $machineObject = ariba::Ops::Machine->new( $host );
        my $memory = $machineObject->memorySize();
        if ( $memory > $maxMemory ) {
            $appHost = $host;
            $maxMemory = $memory;
        }
    }

    return $appHost;
}

sub setNFS {
    my ( $self, $product, $srcObject ) = @_;

    my $srcService = $self->srcService();
    my $tgtService = $self->tgtService();
    my $tmid = $self->tmid();
 
    # find the inserv host for the source/primary/product
    my $user = "mon" . $srcService;
    my $pass = ariba::rc::Passwords::lookup( $user );
    my $host = $self->monHost( $srcService );
    my $realmsRoot = $srcObject->default( 'System.Base.RealmRootDir' );
    $realmsRoot =~ m/(.+$product)/;
    my $nfsDir = $1;
    $nfsDir =~ s/fs/netapp/;

    my $nfsHost;
    my $nfsVolume;
    my @output;
    my $cmd = "ssh -o StrictHostKeyChecking=no -l $user $host df $realmsRoot";

    my $count = 4;
    while ( $count >= 0 && ( !$nfsHost || !$nfsVolume ) ) {
        die "Could not execute command: $cmd" unless ( ariba::rc::Utils::executeRemoteCommand( $cmd, $pass, 0, undef, undef, \@output ));
        foreach my $line ( @output ) {
            if ( $line =~ m/(^nfs\d+).+($product.+)/ ) {
                $nfsHost = "$1.snv";
                $nfsVolume = $2;
                last;
            }
        }
        $count--;
    }
    die "$cmd\n $SSH_ERR" unless ( $nfsHost && $nfsVolume );
  
    $self->{ 'nfs' }->{ $product }->{ 'host' } = $nfsHost;
    $self->{ 'nfs' }->{ $product }->{ 'volume' } = $nfsVolume;
    $self->{ 'nfs' }->{ $product }->{ 'nfsroot' } = $nfsDir;
    $self->{ 'nfs' }->{ $product }->{ 'snapshotDir' } = "$nfsDir$srcService/.snapshot";
    $self->{ 'nfs' }->{ $product }->{ 'snapshotName' } = "${tmid}_${product}${tgtService}_realms";
}

sub nfs {
    my ( $self ) = @_;

    return $self->{ 'nfs' };
}

sub _checkCpg {
    my ( $sids ) = @_;

    my %inservHosts;
    my %vvInfo;
    my $missingPC1 = '';
    my $missingCPG = '';

    foreach my $sid ( sort( keys( %$sids ))) { 

        # get the cpg for the inserv host ( if it hasn't been looked up yet )
        my $inservHost = $sids->{ $sid }->{ 'inservHost' };
        unless ( $inservHosts{ $inservHost } ) {
            my $machine = ariba::Ops::Machine->new( $inservHost );
            my $nm = ariba::Ops::NetworkDeviceManager->newFromMachine( $machine );
            unless($nm) {
                print "Unable to connect to inserv $inservHost.\n" ;
                exit (1);
            }
            $inservHosts{ $inservHost } = $nm->cpgMapForVVPattern( '', 1 );
        }

        # Verify that each production VV has an associated pc1VV and that pc1VV
        # has beta_cpg allocated to it.
        foreach my $vv ( sort( keys( %{$sids->{ $sid }->{ 'VVs' }} ))) {
            my $pc1VV = "pc1-$vv";

            if ( $inservHosts{ $inservHost }->{ $pc1VV } ) {
                if ( $inservHosts{ $inservHost }->{ $pc1VV }->{ 'snpCpg' } eq '--' ) {
                    $missingCPG .= $sids->{ $sid }->{ 'srcSecHost' } . ", " .
                                   $sids->{ $sid }->{ 'srcSid' } . ", " .
                                   $pc1VV . "\n";
                }
            } else {
                # the VV has no associated pci volume
                $missingPC1 .= $sids->{ $sid }->{ 'srcSecHost' } . ", " .
                               $sids->{ $sid }->{ 'srcSid' } . ", " .
                               $vv . "\n";
            }
        }
    }

    if ( $missingPC1 ) {
        print "\nWARNING: The following volumes have no associated PC1 volume.\n";
        print "The SYSADMINS need to:\n";
        print "     - manually create the PC1 volumes.\n";
        print "     - attach beta_cpg to the new PC1 volumes.\n";
        print "     - run full backups for the new volumes.\n";
        print "The backups may take a full day to run depending on the size of the volume.\n";
        print "-----\n";
        print "$missingPC1\n";
    }

    if ( $missingCPG ) {
        print "\nWARNING: The following volumes have grown but no physical copy has been run.\n";
        print "Ask the SYSADMINS to manuall fix this before executing the FPC JMCL.\n";
        print "-----\n";
        print "$missingCPG\n";
    }
}

sub addToHash {
    my ( $self, $host, $sid, $commands ) = @_;

    my $rootTmpDir = $self->rootTmpDir();

    unless ( $commands->{ $host } ) {
        $commands->{ $host } = "sudo rm -rf $rootTmpDir;";        
    }
    $commands->{ $host } .= " mkdir -m 777 -p $rootTmpDir/" . uc( $sid ) . ";";
}

sub cleanupTmpDirs {
    my ( $self, $sids, $service ) = @_;

    my %commandsHash;
    foreach my $sid ( sort( keys( %$sids ))) {
        $self->addToHash ( $sids->{ $sid }->{ 'tgtLiteralHost' }, $sid, \%commandsHash ); 
        $self->addToHash ( $sids->{ $sid }->{ 'srcPriLiteralHost' }, $sids->{ $sid }->{ 'srcSid' }, \%commandsHash ); 
        $self->addToHash ( $sids->{ $sid }->{ 'srcSecLiteralHost' }, $sids->{ $sid }->{ 'srcSid' }, \%commandsHash ); 
    }

    foreach my $host ( keys %commandsHash ) {
        _sendCommand( $host, $service, $commandsHash{ $host }, '' );
    }
}

sub new {
    my ( $class_name, $products, $srcService, $tgtService, $tmid, $schemaType, $suitePW, $baseSS ) = @_;

    my $self = {};

    bless ( $self, $class_name );

    # set some basic values
    $self->setSrcService( $srcService );
    $self->setTgtService( $tgtService );
    $self->setTmid( $tmid );
    $self->setRootTmpDir();

    $self->setPasswordAndHosts( $srcService );
    $self->setPasswordAndHosts( $tgtService );
    # gather sid, host, volume mapping
    my %sids;

    # KLUDGE: JMCL can not use the snv password to decrypt prod/beta encrypted value
    # as a work around we store the snv password and from it store the beta password
    # elsewhere we will reinit the service to be beta for beta password decryption
    # and then set it back to snv.
    $self->setSuitePW( $suitePW );

    foreach my $product ( @$products ) {
        my $buildName = $self->getSrcInstalledBuildName( $product, $srcService );
        my ( $srcProductObj, $srcDbConnections ) = getProductObject( $product, $srcService, $buildName );
        my ( $tgtProductObj, $tgtDbConnections ) = getProductObject( $product, $tgtService, $buildName );

        $self->setNFS( $product, $srcProductObj );
        $self->setEmailDomain( $tgtProductObj );

        $self->{ $product }->{ 'appHost' } = getAppHost( $tgtProductObj ) if ( $product eq 's4' );

        my $installDir = ariba::rc::Globals::rootDir( $product, $tgtService );
        $self->{ $product }->{ 'buildName' } = $tgtProductObj->buildName();
        $self->{ $product }->{ 'tgtInstallDir' } = "$installDir/$self->{ $product }->{ 'buildName' }";

        # loop over all schemas.  For each unique sid create a hash element with various data fields
        foreach my $tgtDb ( @$tgtDbConnections ) {
            next if ( $tgtDb->type() =~ /star/ );

# debugging/development short cuts
#next unless ( uc( $tgtDb->sid() ) eq "BYRBTA1" );
#next unless ( uc( $tgtDb->sid() ) eq "S4BTA1" );
#next unless ( uc( $tgtDb->sid() ) eq "S4BTA1" || uc( $tgtDb->sid() ) eq "BYRBTA1" );
#next unless ( uc( $tgtDb->sid() ) eq "BYRBTA1" || uc( $tgtDb->sid() ) eq "BYRBTA2" );

            if ( $sids{ uc( $tgtDb->sid() ) } ) {
                # already found this sid so just add the schema to its hash
                $sids{ uc( $tgtDb->sid() ) }->{ 'types' }->{ $tgtDb->type() }->{ uc( $tgtDb->user() ) }->{ 'password' } = $tgtDb->password();
            } else {
                # find the associated source DB object
                my $srcDb;
                my $srcPriHost;
                my $srcSecHost;
                foreach my $s ( @$srcDbConnections ) {
                    if ( $s->type() eq $tgtDb->type() && $s->schemaId() == $tgtDb->schemaId() ) {
                        $srcDb = $s;
                        $srcPriHost = $srcDb->host();
                        # for produs we host beta in bou.  This is not in the product object so do a regex switch.
                        if ( $srcPriHost =~ /.*\.snv\..*/ ) {
                            $srcSecHost = $srcPriHost;
                            $srcSecHost =~ s/\.snv\./\.bou\./;
                        } else {
                            my $drPeer = $srcDb->drDBPeer();
                            $srcSecHost = $drPeer->host();
                        }
                        last;
                    }
                }

                my $tgtDbHost = $tgtDb->host();
                my $tgtLiteralHost = $self->getLiteralHost( $tgtDbHost, $srcService );

                my $inservHost;
                my $VVs;
                if ( $product ne 'an' ) {
                    ( $inservHost, $VVs ) = $self->getInservAndVVs( $srcService, uc( $srcDb->sid() ), $srcSecHost, $tgtLiteralHost );
                }

                # create a new sid entry
                $sids{ uc( $tgtDb->sid() ) } = {
                    product => $product,
                    srcSid => uc( $srcDb->sid() ),
                    tgtHost => $tgtDbHost,
                    srcPriHost => $srcPriHost,
                    srcSecHost => $srcSecHost,
                    tgtVolume => getDataVolume( $tgtService, $tgtDb->sid(), $tgtDbHost ),
                    srcVolume => getDataVolume( $srcService, $srcDb->sid(), $srcSecHost ),
                    	#??? this is hard coded for prodDR->beta.  Needs to be expanded for general use
                    inservHost => $inservHost,
                    tgtLiteralHost => $tgtLiteralHost,
                    srcPriLiteralHost => $self->getLiteralHost( $srcPriHost, $srcService ),
                    srcSecLiteralHost => $self->getLiteralHost( $srcSecHost, $srcService ),
                    types => {
                        $tgtDb->type() => {
                            uc( $tgtDb->user() ) => {
                                password => $tgtDb->password(),
                            },
                        },
                    },
                };
                $sids{ uc( $tgtDb->sid() ) }->{ 'VVs' } = $VVs;
            }
        }
    }
    $self->{ 'sids' } = { %sids };

    _checkCpg( \%sids ) unless $baseSS;
    $self->cleanupTmpDirs( \%sids, $srcService );

#warn ( Dumper \%sids );
#exit;

    setStepName( 0, 0 );

    return $self;
}

1;
