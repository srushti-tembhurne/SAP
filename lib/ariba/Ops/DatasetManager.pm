package ariba::Ops::DatasetManager;

use strict;
use DBI;

use DateTime;
use File::Basename;
use File::Copy;
use File::Path;
use File::Temp;
use FindBin;
use Log::Log4perl;

use ariba::Ops::PersistantObject;
use ariba::Ops::DBConnection;
use ariba::Ops::OracleClient;
use ariba::Ops::HanaClient;
use ariba::Ops::Logger;
use ariba::Ops::FileSystemUtilsRPC;
use ariba::Ops::Machine;
use ariba::Ops::HanaControl;
use ariba::Ops::Constants;
use ariba::Ops::NetworkUtils;
use ariba::Ops::DatasetManager::Lock;
use ariba::Ops::Startup::Common;
use ariba::rc::Utils;
use ariba::Ops::Utils; # functions here must be accessed using the fully qualified name.
use ariba::rc::Globals;
use ariba::rc::Passwords;
use ariba::Ops::OracleControl;
use ariba::Ops::DatabasePeers;
use ariba::Ops::ControlDeploymentHelper;
use ariba::rc::InstalledProduct;
use ariba::util::Simplefind;
use dmail::LockLib;
use ariba::Ops::MCL;
use ariba::Ops::MCLGen;
use ariba::Ops::NetworkDeviceManager;
use ariba::Ops::Inserv::VolumeLun;
use ariba::Ops::DatacenterController;
use ariba::Ops::Startup::Hadoop;
use ariba::Ops::HadoopHelper;
use ariba::Ops::Url;
use base qw(ariba::Ops::PersistantObject);

use constant DEFAULT_MAX_PARALLEL_RESTORE => 8;

my $logger = ariba::Ops::Logger->logger();
my $archiveMgrUid = (getpwnam(ariba::Ops::Constants->archiveManagerUser()))[2];
my $archiveMgrGid = (getpwnam(ariba::Ops::Constants->archiveManagerUser()))[3];
my $archiveMgrHome = '/home/' . ariba::Ops::Constants->archiveManagerUser() . "/dataset-testing";
my $shouldProxyFor3Par;
my $defaultInserv = "inserv2.lab1.ariba.com";
my %realmChunkHash;
my $MAX_TAR_COMMANDS = 4;

# create files with writable permission for multiuser support.
umask(002);

my $DS_STATUS_SUCCESSFUL = "Successful";

INIT {
        ariba::Ops::MCL::loadMclPackages();
        ariba::Ops::PersistantObject->enableSmartCache();
}

# FIXME: need to cleanly handle when a schema import/export fails.
# FIXME: logging to a file.
# FIXME: need to cleanly handle and recover from errors.   if unmounting a db filesystem failes
#        during a 3par backup, it's a manual and complicated procedure to recover involving
#        tools, dba and sysadmin.
#        recover can probably just assume that everything is down.  things that aren't are
#        safe to try and start again.
# FIXME: need to enforce a quota of FPC backups
# FIXME: need to check the application is down before running backup
# FIXME: add a warning (at least) when a restore is called for a dataset w/o a DR to a product with one

sub disableSnapShotBackups {
    return(0);
}

sub objectLoadMap {
    my $class = shift;

    my %map = (
        'peers', '@ariba::Ops::DatabasePeers',
        'vluns', '@ariba::Ops::Inserv::VolumeLun',
        'baseVolumes', '@SCALAR',
        'sidList', '@SCALAR',
        'versionList', '@SCALAR',
    );

    return \%map;
}

sub archiveProductDir {
    my $self = shift;

    my $id = $self->instance();
    my $dir = ariba::Ops::Constants->archiveManagerArchiveDir();
    $dir .= "/$id/product";

    return($dir);
}

sub archiveConfigForProduct {
    my $self = shift;
    my $p = shift;

    my $srcDir = $p->configDir();
    my $tgtDir = $self->archiveProductDir() . "/config";

    ariba::rc::Utils::mkdirRecursively($tgtDir);

    my @filesToCopy;

    my $DIR;
    opendir($DIR, $srcDir);
    while(my $f = readdir($DIR)) {
        next unless($f =~ /(?:\.cfg|\.xml|\.table|Name)$/);
        push(@filesToCopy, "$srcDir/$f");
    }
    closedir($DIR);

    my $files = join(' ', @filesToCopy);

    system("/bin/cp $files $tgtDir");

    #
    # also copy the lib/sql area
    #
    $srcDir .= "/../lib/sql";
    $tgtDir = $self->archiveProductDir() . "/lib/sql";
    ariba::rc::Utils::mkdirRecursively($tgtDir);

    system("/bin/cp -R $srcDir/* $tgtDir");
}

sub children {
    my $self = shift;
    my @ret = ();

    my $tree = ariba::Ops::DatasetManager::getDatasetTreeFast();
    return(@ret) unless $tree->{$self->instance()}->{'children'};

    foreach my $childId (sort keys %{$tree->{$self->instance()}->{'children'}}) {
        my $child = ariba::Ops::DatasetManager->new($childId);
        push(@ret, $child);
    }

    return(@ret);
}

sub inserv {
    my $self = shift;

    return($self->attribute('inserv')) if($self->attribute('inserv'));
    return($defaultInserv);
}

sub shouldProxy {
    my $class = shift;

    return($shouldProxyFor3Par) if(defined($shouldProxyFor3Par));

    my $host = ariba::Ops::NetworkUtils::hostname();
    my $m = ariba::Ops::Machine->new($host);
    if(ariba::Ops::DatacenterController::isDevlabDatacenters($m->datacenter)) {
        $shouldProxyFor3Par = 1;
    } else {
        $shouldProxyFor3Par = 0;
    }

    return($shouldProxyFor3Par);
}

sub checkPeersForOpenFiles {
    my (@peers) = (@_);
    my $ret = 1;

    $logger->info("Checking Databases for open files on data volumes.");
    $logger->info("(These commands can take some time.)");

    foreach my $peer (@peers) {
        unless($peer->checkDBFilesystemsForOpenFiles()) {
            $ret = 0;
        }
    }

    return($ret);
}

sub newDataset {
    my $class = shift;
    my $productName = shift;
    my $serviceName = shift;
    my $buildName = shift;
    my $debug = shift;

    if ( ! defined $productName || ! $productName ) {
        $logger->error("You must specify a product name");
        return;
    }
    if ( ! defined $serviceName || ! $serviceName ) {
        $logger->error("You must specify a service name");
        return;
    }
    if ( ! defined $buildName || ! $buildName ) {
        $logger->error("You must specify a build name");
        return;
    }


    my $archiveDir = ariba::Ops::Constants->archiveManagerArchiveDir();
    $logger->debug("Creating $archiveDir");
    unless (ariba::rc::Utils::mkdirRecursively($archiveDir)) {
        $logger->error("Failed to create dir $archiveDir: $!");
        return;
    }

    my $lockfile = $archiveDir . "/.lockfile";
    dmail::LockLib::forceQuiet() unless $debug;
    unless (dmail::LockLib::requestlock($lockfile,10)) {
        $logger->error("Cannot grab lock of $lockfile");
        return undef;
    }

    my $instance = $class->getNextAvailableId();
    my $self = $class->SUPER::new($instance);
    $self->_setCreateTime();
    $self->setProductName($productName);
    $self->setServiceName($serviceName);
    $self->setBuildName($buildName);
    $self->setDebug($debug);

    return unless $self->_save();

    my $metaDataObjectDir = ariba::Ops::Constants->archiveManagerMetaDataDir() . "/" . $self->instance();
    unless (ariba::rc::Utils::mkdirRecursively($metaDataObjectDir)) {
        $logger->error("Failed to create dir $metaDataObjectDir: $!");
        return;
    }
    my $archiveObjectDir = $archiveDir . "/" . $self->instance();
    unless (ariba::rc::Utils::mkdirRecursively($archiveObjectDir)) {
        $logger->error("Failed to create dir $archiveObjectDir: $!");
        return;
    }

    ariba::Ops::FileSystemUtilsRPC->setDir(ariba::Ops::Constants->archiveManagerMetaDataDir() . "/" . $self->instance());
    ariba::Ops::OracleControl->setDir(ariba::Ops::Constants->archiveManagerMetaDataDir() . "/" . $self->instance());
    ariba::Ops::DatabasePeers->setDir(ariba::Ops::Constants->archiveManagerMetaDataDir() . "/" . $self->instance());

    dmail::LockLib::releaselock($lockfile);

    return $self;
}

sub getNextAvailableId {
    my $class = shift;

    my @instances = $class->listByInstance();

    return 1 if !scalar(@instances);

    ##my $lastId = 1000;
    my ($lastId,$endID) = getLastId();
    die "Error: lastId is null, please check archmgr NFS Mount on running host\n" unless($lastId);

    foreach my $ds (sort { $a->instance() <=> $b->instance() } @instances) {
        my $instance = $ds->instance();
        next unless ($instance > $lastId);
        if($lastId+1 == $instance) {
            $lastId = $instance;
            next;
        }

        #
        # XXX -- don't use if we have turds left over -- long term we need to
        # clean this up, but for now just avoid it.
        #
        while($lastId+1 < $instance) {
            my $archiveDir = ariba::Ops::Constants->archiveManagerArchiveDir() . "/" . ($lastId+1);
            my $metaDir = ariba::Ops::Constants->archiveManagerMetaDataDir() . "/" . ($lastId+1);

            if( -e $archiveDir || -e $metaDir ) {
                $lastId++;
            } else {
                last;
            }
        }

        if($lastId+1 == $instance) {
            $lastId = $instance;
            next;
        }

        last;
    }

    die "Error: Host DC has crossed its datasetId limit of $endID, Please delete old unwanted dataset ids and re-run\n" if ( $lastId + 1 > $endID );

    return $lastId + 1;
}

sub listAll {
    my $class = shift;

    return $class->listObjects();
}

sub list {
    my $class = shift;

    my @return = ();
    foreach my $i ($class->listObjects()) {
        next if($i->softDeleted());
        push(@return, $i);
    }

    return @return;
}

sub listDeleted {
    my $class = shift;

    my @return = ();
    foreach my $i ($class->listObjects()) {
        next unless($i->softDeleted());
        push(@return, $i);
    }

    return(@return);
}

sub listByModifyTime {
    my $class = shift;

    return sort { $b->modifyTime() <=> $a->modifyTime() } $class->list();
}

sub listByInstance {
    my $class = shift;

    return sort { $a->instance() <=> $b->instance() } $class->list();
}

# sort comparator that will order datasets by largest(latest) build numbers first
# We do not want to rely on modification time as the sole criteria for selecting ]
# the dataset for restoring robot-initdb or robot-restoremigrate datasets
sub byBuildNumber {
    my $a_buildName = $a->buildName();
    my $b_buildName = $b->buildName();
    my ($a_prodBranch, $a_buildNumber) = split(/-/, $a_buildName);
    my ($b_prodBranch, $b_buildNumber) = split(/-/, $b_buildName);

    $b_buildNumber <=> $a_buildNumber; # reverse (biggest build numbers first)
}

# Get a dataset for the following criteria. This is dataset can be restored
# prior to a build qual instead of performing the initdb process.
#
# Input 1: productName
# Input 2: datasetType - typically "robot-initdb"
# Input 3: serviceName - typically like "perdsonal_robotxxx"
# Input 4: buildName - name of a current build like "S4R2-12".
#
# Return dataset (or undef if none) for the most recent match where
# the buildName branch part must match (i.e., backup S4R2-9 has branch part "S4R2" and buildname "S4R2-12" branch part "S4R2" matches)
sub getRobotDataset {
    my ($self, $productName, $datasetType, $serviceName, $buildName) = @_;

    debugmsg("DatasetManager::getRobotDataset for product \"$productName\", datasetType \"$datasetType\" service \"$serviceName\" build \"$buildName\"\n");

    my @candidates = $self->listRestoreCandidatesForProductNameAndTypeByModifyTime($productName, $datasetType);
    if (@candidates) {
        debugmsg("DatasetManager::getRobotDataset ; there are candidate datasets for deleting\n");
        @candidates = sort byBuildNumber @candidates;
        for my $backup (@candidates) {
            my $backupId = $backup->instance();
            my ($backupBuildName, $backupBuildNumber) = split (/-/, $backup->buildName());
            my ($currentBuildName, $currentBuildNumber) = split (/-/, $buildName);
            my $backupServiceName = $backup->serviceName();

            if ($backupServiceName eq $serviceName) {
                if ($backupBuildName eq $currentBuildName) {
                    debugmsg("DatasetManager::getRobotDataset ; found candidate dataset \"$backupId\"\n");
                    return $backup;
                }
                debugmsg("DatasetManager::getRobotDataset ; skipping dataset \"$backupId\" because its buildName \"$backupBuildName\" != \"$currentBuildName\"\n");
            }
            else {
                debugmsg("DatasetManager::getRobotDataset ; skipping dataset \"$backupId()\" because its serviceName \"$backupServiceName\" != \"$serviceName\"\n");
            }
        }
    }
    else {
        debugmsg("DatasetManager::getRobotDataset ; there are no candidate datasets for deleting\n");
    }
    return undef;
}

sub debugmsg {
    my ($msg) = @_;

    # $logger->debug($msg);
    print $msg;
}

# Delete the robot datasets for a product,service,datasettype combination except for one in particular
#
# Input 1: productName
# Input 2: datasetType - typically "robot-initdb"
# Input 3: serviceName - typically like "perdsonal_robotxxx"
# Input 4: exceptThisDatasetId - dataset instance to retain (do not delete)
sub deleteRobotDatasets {
    my ($self, $productName, $datasetType, $serviceName, $exceptThisDatasetId) = @_;

    my @candidates = $self->listRestoreCandidatesForProductNameAndTypeByModifyTime($productName, $datasetType);
    if (@candidates) {
        for my $backup (@candidates) {
            my $backupId = $backup->instance();
            my $backupServiceName = $backup->serviceName();

            next unless ($backupServiceName eq $serviceName);

            next if ($backupId eq $exceptThisDatasetId);

            debugmsg("DatasetManager::deleteRobotDatasets ; deleting dataset \"$backupId\" because != preserved dataset \"$exceptThisDatasetId\"\n");
            $backup->delete();
        }
    }
    else {
        debugmsg("DatasetManager::deleteRobotDatasets ; there are no candidate datasets to delete\n");
    }
}

sub listRestoreCandidatesForProductAndTypeByModifyTime {
    my $class = shift;
    my $product = shift;
    my $type = shift;

    return unless $product and $type;

    my @candidates;
    for my $backup ( $class->listByModifyTime() ) {
        next unless $backup->productName() eq $product->name();

        if( $backup->isFpc() || $backup->isThin() ) {
            next unless($backup->serviceName() eq $product->service());
        }

        if ( defined $type and $type ) {
            next if(!$backup->type() || $backup->type() ne $type);
        }

        next unless(
            $backup->isThin() || # no need to verify thin
            $backup->isFpc() || # no need to verify FPC
            $backup->isHbaseExport() || # no need to verify hbase
            $backup->verifyBackupForProduct($product) # verify succeeded
        );

        push(@candidates, $backup);
    }

    return @candidates;
}

sub listRestoreCandidatesForProductNameAndTypeByModifyTime {
    my $class = shift;
    my $productName = shift;
    my $type = shift;
    my $service = shift;

    return unless $productName;

    my @candidates;
    for my $backup ( $class->listByModifyTime() ) {
        next unless $backup->productName() eq $productName;
        if($service) {
            next unless ($service eq $backup->service());
        } else {
            next if($backup->isFpc() || $backup->isThin());
        }
        if ( defined $type and $type ) {
            next unless $backup->type() eq $type;
        }
        push(@candidates, $backup);
    }

    return @candidates;
}

sub listBaselineInstantRestoreCandidatesForProductAndTypeByModifyTime{
    my $class   = shift;
    my $product = shift;
    my $type    = shift;

    my @candidates = ();
    return @candidates unless defined $product;

    for my $backup ( $class->listByModifyTime() ) {
        next unless $backup->baseline();
        next unless $backup->isThin();
        next unless $backup->productName() eq $product->name();
        if ( defined $type and $type ) {
            next if(!$backup->type() || $backup->type() ne $type);
        }
        push @candidates, $backup;
    }
    return @candidates;
}

sub listBaselineRestoreCandidatesForProductAndTypeByModifyTime {
    my $class = shift;
    my $product = shift;
    my $type = shift;

    my @candidates;
    for my $backup ( $class->listRestoreCandidatesForProductAndTypeByModifyTime($product, $type) ) {
        next unless $backup->baseline();
        push(@candidates, $backup);
    }

    return @candidates;
}

sub listBaselineRestoreCandidatesForProductNameAndTypeByModifyTime {
    my $class = shift;
    my $productName = shift;
    my $type = shift;
    my $service = shift;

    my @candidates;
    for my $backup ( $class->listRestoreCandidatesForProductNameAndTypeByModifyTime($productName, $type, $service) ) {
        next unless $backup->baseline();
        push(@candidates, $backup);
    }

    return @candidates;
}

#
# in case anything in the wild I missed uses the old name
#
sub listFPCRestoreCandidatesForProductNameAndServiceByModifyTime {
    my $class = shift;

    return(
      $class->listSnapshotRestoreCandidatesForProductNameAndServiceByModifyTime(@_)
    );
}

sub listSnapshotRestoreCandidatesForProductNameAndServiceByModifyTime {
    my $class = shift;
    my $productName = shift;
    my $service = shift;

    return unless $productName and $service;

    my @candidates;
    for my $backup ( $class->listByModifyTime() ) {
        next unless ($backup->isFpc() || $backup->isThin());
        next unless $backup->productName() eq $productName;
        next unless $backup->serviceName() eq $service;
        next unless $backup->datasetComplete();
        push(@candidates, $backup);
    }

    return @candidates;
}

sub checkQuotaForProductAndService {
    my $class = shift;
    my $productName = shift;
    my $service = shift;

    my @restoreCandidates = $class->listSnapshotRestoreCandidatesForProductNameAndServiceByModifyTime($productName, $service);
    @restoreCandidates = grep { $_->backupType() ne 'thinchild' } @restoreCandidates;
    if (scalar @restoreCandidates >= $class->quotaForProductAndService($productName, $service)) {
        $logger->error("$productName running in $service has " . scalar(@restoreCandidates) . " datasets but is only allowed " . $class->quotaForProductAndService($productName, $service));
        $logger->error("Run 'dataset-manager listsnapshot|list -product <product> -service <service>' to identify the dataset ids to remove.");
        return 0;
    }

    return 1;
}

sub quotaForProductAndService {
    my $class = shift;
    my $productName = shift;
    my $service = shift;

    # see TMID:107391, 110769
    return 3 if ($service eq 'mig2' && $productName =~ /^(?:s4|buyer)$/);
    return 3 if ($service eq 'mig' && $productName =~ /^(?:s4|an)$/);

    # TMID 110142
    return 4 if ($service eq 'load' && $productName eq 's4');

    # TMID 111297
    return 3 if ($service eq 'load2' && $productName eq 's4');

    # see TMID:99180 and 104007, 109706 raising quota for buyer/(load|load2) to 4
    return 4 if (($service eq 'load' or $service eq 'load2') && $productName eq 'buyer');

    # see TMID: 107136, temporarily raising quota for buyer mig to 4
    return 4 if (($service eq 'mig') && $productName eq 'buyer');

    # see TMID: 106027, raising quota for an/(load|load2) to 4
    return 4 if (($service eq 'load' or $service eq 'load2') && $productName eq 'an');

    return 4 if ($service eq 'test');

    # raising quota for scperfh6 service as per Ticket HOA-157212
    return 4 if ($service =~ /^scperf/i);

    return 2;
}

sub getBaseLineBackupForService {
    my $class = shift;
    my $service = shift;

    my @candidates;
    for my $backup ( $class->listByModifyTime() ) {
        next unless $backup->serviceName() eq $service;
        return $backup if $backup->baseline();
    }

    return;
}

sub getDatasetById {
    my $class = shift;
    my $instance = shift;

    unless ( $class->objectWithNameExists($instance) ) {
        $logger->error("Dataset id $instance does not exist");
        return;
    }

    my $self = $class->SUPER::new($instance);
    ariba::Ops::FileSystemUtilsRPC->setDir(ariba::Ops::Constants->archiveManagerMetaDataDir() . "/" . $self->instance());
    ariba::Ops::OracleControl->setDir(ariba::Ops::Constants->archiveManagerMetaDataDir() . "/" . $self->instance());
    ariba::Ops::DatabasePeers->setDir(ariba::Ops::Constants->archiveManagerMetaDataDir() . "/" . $self->instance());

    return $self;
}

sub logDir {
    my $class = shift;
    return "/home/" . ariba::Ops::Constants->archiveManagerUser() . "/log";
}

sub dir {
    my $class = shift;
    return ariba::Ops::Constants->archiveManagerCatalogDir();
}

#As per JIRA:HOA-15855 adding HANABQ and HANABQ-Test dataset types
my @validASPDatasetTypes = ( "robot-BQ", "BQ", "BQTest", "LQ", "LQManual", "R-BQ", "R-LQ", "robot-initdb", "robot-restoremigrate", "R-LQManual","OPSLQ",
                             "LQ-TEST", "LQ-DEV", "13s2_LQ", "R4-LQ21", "R4-HANA", "HANABQ", "HANABQ-TEST", "R4-DualDB", "R4-Encryption","AppAndBFDataSet","CoreBuyerDataSet","InvoicingDataSet","14s2_LQ", "CQHANA", "HanaSSPPerDataSet" );
my @validANDatasetTypes = ( "default", ariba::rc::Globals::devlabServices() );
my @validArchesDatasetTypes = ( "LQ", "R-LQ", "LQManual" );

sub validDatasetTypesForProductName {
    my $class = shift;
    my $productName = shift;

    if (grep { $productName eq $_ } ariba::rc::Globals::sharedServiceSourcingProducts(), ariba::rc::Globals::sharedServiceBuyerProducts()) {
        return @validASPDatasetTypes;

    } elsif ( $productName eq 'an' ) {
        return @validANDatasetTypes;
    } elsif ( $productName eq 'arches' ) {
        return @validArchesDatasetTypes;
    }

    return;
}

## Instance methods

sub setDebug {
    my $self = shift;
    my $debugLevel = shift;

    my $debug = $debugLevel + $logger->logLevel();
    $main::quiet = 0 if $debugLevel >= 2;
    $self->SUPER::setDebug($debugLevel);
    $logger->setLogLevel($debug);

    return 1;
}

sub delete {
    my $self = shift;

    #  HACK! We have to remove the db snapshots first because we require the montiring volumelun package
    # in the removeSnapshot package.  If we remove the realm back first, the PO code faults in the vluns
    # but doesn't have the volumelun package loaded nor the dir() set so the backingstore gets set to undef.
    if ($self->isFpc()) {
        $logger->info("Removing 3par snapshots");
        unless ($self->removeSnapshots()) {
            return;
        }
    } elsif($self->isThin()) {
        $logger->info("Removing 3par snapshots");
        unless ($self->removeThinSnapshots()) {
            return(0);
        }
    } else {
        $logger->info("Removing Schema backups");
        unless ($self->removeDbSchemaBackups()) {
            return;
        }
    }

    if ( defined $self->realmRootDir ) {
        $logger->info("Removing realm backup");
        unless ( $self->removeRealmDirBackup() ) {
            return;
        }
    }

    if ( $self->testing() ) {
        $logger->debug("DRYRUN: would remove dataset instance " . $self->instance());
    } else {
        $logger->info("Removing dataset instance " . $self->instance());

        my $archiveDir = ariba::Ops::Constants->archiveManagerArchiveDir();
        my $metaDataDir = ariba::Ops::Constants->archiveManagerMetaDataDir();
        my $mclDataDir = ariba::Ops::Constants->archiveManagerMCLDir();
        for my $dir ($archiveDir, $metaDataDir, $mclDataDir) {
            my $instanceDir = $dir . "/" . $self->instance();
            next unless( -d $instanceDir );
            my $dirFH;
            opendir($dirFH, $instanceDir);
            my @files  = grep($_ !~ /^\.{1,2}$/, readdir($dirFH));
            closedir($dirFH);

            my @extraneousFiles;
            for my $file (@files) {
                if ($file =~ /\.mcl/) {
                    $logger->debug("Removing " . $file);
                    unlink($instanceDir . "/" . $file);
                    next;
                }
                if ($file =~ /log$/) {
                    $logger->debug("Removing " . $file);
                    unlink($instanceDir . "/" . $file);
                    next;
                }
                if ($file =~ /(?:mcl|oracleArchiveLogs|product|hana)/) {
                    $logger->debug("Removing " . $file);
                    if ($file eq 'hana') {
                        ariba::rc::Passwords::initialize($self->serviceName());
                        my $logfiles = $instanceDir . "/" . $file . "/*";
                        $self->deleteAdmOwnedHanaFiles($logfiles);
                    } 
                    ariba::rc::Utils::rmdirRecursively($instanceDir . "/" . $file);
                    next;
                }
                push(@extraneousFiles, $file);
            }

            if ( scalar(@extraneousFiles) ) {
                $logger->error("Extraneous files in '$instanceDir': " .  join (" ", @extraneousFiles) . "\n");
                return;
            }

            rmdir($instanceDir);
        }

        $self->remove();
    }
}

sub deleteAdmOwnedHanaFiles {
    my $self = shift;
    my $logfiles = shift;

    #get the hana adm id
    my $mon = ariba::rc::InstalledProduct->new("mon", $self->serviceName());
    my $usern = $mon->default("dbainfo.hana.admin.userName");

    #get one of the hana host name
    my $product = ariba::rc::InstalledProduct->new($self->productName(), $self->serviceName(), $self->buildName());
    my @dbConnections = ariba::Ops::DBConnection->connectionsFromProducts($product);
    @dbConnections = grep { $_->dbType() && $_->dbType eq 'hana' } @dbConnections;
    my $host;
    for my $dbc ( @dbConnections ) {
        $host = $dbc->host();
        last;
    }

    ariba::Ops::FileSystemUtilsRPC->deleteAdmOwnedHanaFile($host, $self->serviceName(), $usern, $logfiles);

    return 1;

}

sub markAsBaseline {
    my $self = shift;

    $self->setBaseline(1);
    return unless $self->_save();
}

sub unmarkAsBaseline {
    my $self = shift;
    $self->setBaseline(0);
    return unless $self->_save();
}

sub backupFromProduct {
    my $self = shift;
    my $product = shift;
    my $skipRealms = shift;
    my $skipClean = shift;

    $self->setProductBuildName($product->buildName());
    $self->setProductInstallDir($product->installDir());
    $self->setProductName($product->name());
    $self->setProductReleaseName($product->releaseName());
    $self->archiveConfigForProduct($product);
    $self->setExportTypeOracle(1);    ## By default set 1, for Oracle data pump
    my $cdh5;
    if($product->name() =~/arches/i && $product->default('isCDH5')){
        $cdh5 = 1;
        $self->setbackupType('hbase');
    }
    # backups the databases
    if ($self->isHbaseExport()) {
        if($cdh5){
            return unless $self->backupHbaseTablesFromProduct_cdh5($product);
        }
        else {
            return unless $self->backupHbaseTablesFromProduct($product);
        }
    } else {
        return unless $self->backupDBFromProduct($product, $skipClean);
    }

    #
    # Backup the realms directory
    # DO NOT do this if dataset is thin -- instant restore does this in
    # DO NOT do this if dataset is hbase
    # parallel via the MCL frame.
    #
    unless($skipRealms || ($self->isThin() || $self->isHbaseExport())) {
        if ( $product->default('System.Base.RealmRootDir') ) {
            return unless $self->backupRealmDirFromProduct($product);
        } else {
            $logger->info("realmRootDir not defined in product connection, not adding realms dir to backup");
        }
        $self->setDatasetComplete(1) unless $self->testing();
    }

    # Mark the backup as complete for the product
    return unless $self->_save();
    return $self;
}

sub backupHbaseFromProduct {
    my $self = shift;
    my $product = shift;

    $self->setProductBuildName($product->buildName());
    $self->setProductInstallDir($product->installDir());
    $self->setProductName($product->name());
    $self->setProductReleaseName($product->releaseName());
    $self->archiveConfigForProduct($product);

    return unless $self->backupHbaseTablesFromProduct($product);
    return $self;
}

sub calculateIndexedRealmChunks {
    my $root = shift;
    my $totalSize = 0;
    my %sizeIdx;
    my %realmIdx;

    open(REALMIDX, "$root/realmSizeIndex.txt");
    while(my $line = <REALMIDX>) {
        chomp($line);
        my ($size, $realm) = split(/\s+/, $line);
        $totalSize+=$size;
        $realmIdx{$realm} = $size;
    }
    close(REALMIDX);

    my $avgRealmSize = int( $totalSize / scalar(keys(%realmIdx)) );

    opendir(D,$root) || return;
    my @files = readdir(D);
    close(D);

    foreach my $f (@files) {
        next if($f =~ /^\.\.?$/);
        next if($realmIdx{$f});
        $realmIdx{$f} = $avgRealmSize;
    }

    my @sortedKeysList = sort { $realmIdx{$b} <=> $realmIdx{$a} }
                keys(%realmIdx);

    #
    # rules:
    #
    # we ideally want each tarfile to not exceed $avgRealmSize * 50
    #
    # some realms are larger than that by themselves, so that is an exception
    # also, we have a minimum "averageRealmSize" -- no need to split a small
    # realms area into 20 parts.
    #
    # we also limit a chunk to a max of 100 realms
    #

    my $chunk = 1;
    my $hash = {};
    $realmChunkHash{$root} = $hash;
    my $maxTarSize = $avgRealmSize * 50;
    $maxTarSize = 100000 if($maxTarSize < 100000);
    my $maxFilesInTar = 100;

    while(scalar(keys(%realmIdx))) {
        my @list;
        my $size = 0;
        my $files = 0;
        foreach my $k (@sortedKeysList) {
            next unless($realmIdx{$k});
            unless(scalar(@list)) {
                push(@list, "realms/$k");
                $size += $realmIdx{$k};
                $files++;
                delete($realmIdx{$k});
                last if($size > $maxTarSize);
                next;
            }

            if($size + $realmIdx{$k} < $maxTarSize) {
                push(@list, "realms/$k");
                $size += $realmIdx{$k};
                $files++;
                delete($realmIdx{$k});
            }

            last if($files == $maxFilesInTar);
        }

        $hash->{$chunk} = join(' ',@list);
        $chunk++;
    }
}

sub calculateRealmChunks {
    my $root = shift;

    if( -r "$root/realmSizeIndex.txt" ) {
        return(calculateIndexedRealmChunks($root));
    }

    my $FILES_PER_CHUNK = 50;

    my $hash = {};
    $realmChunkHash{$root} = $hash;

    opendir(D,$root) || return;
    my @files = readdir(D);
    close(D);
    @files = sort(@files);

    my $chunk = 1;
    while(scalar(@files)) {
        my @list;
        my $count = $FILES_PER_CHUNK;
        while($count && scalar(@files)) {
            my $f = shift(@files);
            next if($f =~ /^\.\.?/);
            $f = "realms/$f";
            push(@list, $f);
            $count--;
        }
        $hash->{$chunk} = join(' ', @list);
        $chunk++;
    }
}

sub getRealmListForChunk {
    my $self = shift;
    my $chunk = shift;
    my $root = shift || $self->realmRootDir();

    unless($realmChunkHash{$root}) {
        calculateRealmChunks($root);
    }

    return($realmChunkHash{$root}->{$chunk});
}

sub backupRealmDirFromProduct {
    my $self = shift;
    my $product = shift;

    my $realmRootDir = $product->default('System.Base.RealmRootDir');

    # get the complete list of files for the realm dir

    # get the unique list of app hosts for the product

    # split the list into x groups where x is the number of unique app hosts

    # Assign each file list group to an app server, kick off the backup in parallel


    my $realmsZipFile = ariba::Ops::Constants->archiveManagerArchiveDir() . "/" . $self->instance() . "/realmBackup.tgz";
    my $realmRootDirParent = dirname($realmRootDir);

    $logger->info("Backing up $realmRootDir.  This can take some time..." );
    $self->setRealmRootDir($realmRootDir);
    $self->setRealmBackupStatus("In Progress");
    return unless $self->_save();

    my $tarCmd = tarCmd() . " zcf";
    $tarCmd .= " $realmsZipFile -C $realmRootDirParent realms";

    if ( $self->testing() ) {
        $logger->debug("DRYRUN: would create realms tgz file");
    } else {
        system($tarCmd) == 0 or do {
            my $error = $?;
            $logger->error("Failed to create realms tgz file");
            $logger->error("tar returned " . ($error >> 8));
            $self->setRealmBackupStatus("Failed");
            return;
        };

        #
        # reread the backing store in case we were run in parallel
        #
        $self->readFromBackingStore();
        $self->setRealmBackupStatus($DS_STATUS_SUCCESSFUL);
        $self->setRealmSizeInBytes((stat($realmsZipFile))[7]);

        if($self->dbBackupStatus() eq 'Successful') {
            $self->setDatasetComplete(1);
        }

        return unless $self->_save();
    }

    $logger->info("Successfully backed up realm root dir: $realmRootDir");

    return 1;
}

sub numberFromRealmFile {
    my $file = shift;

    $file =~ m/-(\d+)\.tgz$/;
    my $num = $1;

    return($num || 0);
}

sub archivedRealmsBackupFiles {
    my $self = shift;

    my $realmsArchiveDir = ariba::Ops::Constants->archiveManagerArchiveDir() . "/" . $self->instance();
    my @realmsFiles;

    opendir(D,$realmsArchiveDir) || return;
    while (my $f = readdir(D)) {
        if($f =~ /^realmBackup/) {
            push(@realmsFiles, "$realmsArchiveDir/$f");
        }
    }
    closedir(D);

    @realmsFiles = sort { numberFromRealmFile($a) <=> numberFromRealmFile($b) } @realmsFiles;

    return(@realmsFiles);
}

sub removeRealmDirBackup {
    my $self = shift;

    if ( $self->isInstantRealm() ){
        if ( $self->testing() ) {
            $logger->debug("DRYRUN: would remove Instant Restore Realm");
        } else {
            my $inserv = $self->inserv();
            my $machine = ariba::Ops::Machine->new($inserv);
            my $nm = ariba::Ops::NetworkDeviceManager->newFromMachine($machine, $self->shouldProxy());

            unless($nm) {
                $logger->error("Unable to attach to 3par.");
                return(0);
            }

            my $dsId = $self->instance();
            my @vvs = ( "scro-$dsId-realm-0", "scrw-$dsId-realm-0" );

            foreach my $vv ( @vvs ){
                unless( $nm->removeVV($vv) ) {
                    $logger->error("Failed to remove $vv");
                    return(0);
                }
            }
        }
    } else {
        my @realmsFiles = $self->archivedRealmsBackupFiles();

        foreach my $realmsZipFile (@realmsFiles) {
            if ( $self->testing() ) {
                $logger->debug("DRYRUN: would remove Realms Zip file $realmsZipFile");
            } else {
                $logger->info("Removing $realmsZipFile");
                if ( -f $realmsZipFile ) {
                    if ( ! unlink($realmsZipFile) ) {
                        $logger->error("Failed to remove $realmsZipFile");
                        return;
                    }
                }
            }
        }
    }

    unless($self->testing()) {
        $self->deleteAttribute("realmRootDir");
        $self->deleteAttribute("realmSizeInBytes");
        $self->deleteAttribute("realmBackupStatus");
    }

    return unless $self->_save();

    return 1;
}

sub backupDBFromProduct {
    my $self = shift;
    my $product = shift;
    my $skipClean = shift;

    my @dbConnections = ariba::Ops::DBConnection->connectionsFromProducts($product);
    my $exportDir = ariba::Ops::Constants->archiveManagerArchiveDir() . "/" . $self->instance();
    my $productName = $product->name();
    if ($productName eq "suppliermanagement" ){
        push @dbConnections,getSystemDBConnection('smsys',$product);
    }
    my $serviceName = $product->service();
    my $class = ref($self);

    $self->setDbBackupStatus("In Progress");
    for my $dbc ( @dbConnections ) {
        next if $dbc->isGeneric();
        
        my $sid = $dbc->sid();
        my $schemaName = $dbc->user();
        my $password = $dbc->password();
        my $host = $dbc->host();

        my $dbType = $dbc->dbServerType() || "";
        next if($self->hanaOnly() && $dbType ne 'hana');
        next if($self->noHana() && $dbType eq 'hana');

        next if $self->skipDR() && $dbc->isDR();

        if (!$dbc->isDR()) {
            #FIXME
            #if (!$self->testing() && $self->numOfConnectionsToSchema($sid, $schemaName, $password, $host) != 0) {
            #   $logger->error("Can't run export.  There are active connections to $schemaName\@$sid");
            #   return;
            #}

            unless ($skipClean) {
                if (! $self->isFpc() && ! $self->isThin()) {
                    # Clean the schema, drop the materialized views
                    unless ( $self->prepareDBSchemasForBackup($dbc) ) {
                        $logger->error("Error preparing $schemaName\@$sid for backup");
                        $self->setDbBackupStatus("Failed");
                        return;
                    }
                }
            }
        }

        # Run the backup
        if (! $self->isFpc() && ! $self->isThin()) {
            $self->backupDBSchema($dbc);
        }
    }

    if ($self->isThin()) {
        #
        # this is the genius of thin datasets -- a "backup" is literally:
        # 1) create a new dataset
        # 2) rename the running exports as base copies in the new dataset
        # 3) restore to the new dataset
        #
        # we literally turn the live environment into a backup, and then
        # restore to it rather than taking a backup.
        #
        # extra genius -- this works for bootstrap too.  This code doesn't
        # distinguish, but for createsnapshot the type is 'thinchild', and
        # for bootstrap, it's 'thinbase'.
        #
        unless($self->restoreThin($product, 1)) {
            $self->setDbBackupStatus("Failed");
            return(0);
        }
    }

    if ($self->isFpc()) {
        $logger->info("3PAR snapshot backup requested.  Gathering product database and filesystem information.");

        my @peers = ariba::Ops::DatabasePeers->newListFromProduct(
                    $product,
                    {
                    'debug' => $self->debug(),
                    'isBackup' => 1,
                    'populateFsInfo' => 1,
                    'skipDR' => $self->skipDR(),
                    'skipTypes' => $self->skipTypes(),
                    'testing' => $self->testing(),
                    }
                );
        ####=============================================================================####
        # Skip HANA from Thin backup/restore, since HANA donesn't support thin export/import
        # HANA export (dataset id) will be linked as hanaChild in catalog file
        ####=============================================================================####
        @peers = grep { $_->peerType() !~ /hana/i } @peers;
        unless ( @peers ) {
            $self->setDbBackupStatus("Failed");
            return;
        }

        unless( checkPeersForOpenFiles(@peers) ) {
            $logger->error("There are open files on database volumes.\n");
            $logger->error("Contact the DBAs or sysadmins for assistance.\n");
            $self->setDbBackupStatus("Failed");
            return(0);
        }

        foreach my $peer (@peers) {
            foreach my $pc ($peer->primary(), $peer->secondary()) {
                next unless($pc);
                $pc->deleteAttribute('dbFsRef');
            }
        }

        $self->setPeers(@peers);

        unless ( $self->backupFPC(\@dbConnections) ) {
            $self->setDbBackupStatus("Failed");
            return;
        }
    }

    $self->setDbBackupStatus($DS_STATUS_SUCCESSFUL);
    if($self->realmBackupStatus() eq 'Successful') {
        $self->setDatasetComplete(1);
    }

    return unless $self->_save();

    return 1;
}

sub getParamsFromAlternateConfig {
    my $config = shift;
    my $param = shift;

    unless (-f $config) {
        $logger->error("$config does not exist");
        return 0;
    }

    my $value;
    open(FILE, $config);
    while (my $line = <FILE>) {
        if ($line =~ /$param/) {
            $value = (split(" = ", $line))[1];
            $value =~ s/\s//;

            return $value;
        }
    }

    return undef;
}

sub backupHbaseTablesFromProduct {
    my $self = shift;
    my $product = shift;

    my $productArches = $product->name();
    my $serviceArches = $product->service();

    my $aribaArchesConfig = $product->installDir() . "/config/ariba.arches.user.config.cfg";
    my $rootTable = ariba::Ops::Utils::getParamsFromAlternateConfig($aribaArchesConfig, 'ariba.hadoop.tenant.prefix');
    my $hadoopTenant = ariba::Ops::Utils::getParamsFromAlternateConfig($aribaArchesConfig, 'ariba.hadoop.tenant.actas');
    my $serviceHadoop = $hadoopTenant;

    unless ($rootTable) {
        $logger->error("Arches ariba.hadoop.tenant.prefix value is not set.");
        return 0;
    }

    unless ($serviceHadoop) {
        $logger->error("Arches ariba.hadoop.tenant.actas value is not set.");
        return 0;
    }

    ## TO-DO engr to checkin a parameter for hadoop service that arches talkes to. For now, just parse 'ariba.hadoop.tenant.actas'
    $serviceHadoop =~ s/^svc//;

    my $hadoop = ariba::rc::InstalledProduct->new("hadoop", $serviceHadoop) if ($productArches eq "arches");
    my $host = ($hadoop->rolesManager()->hostsForRoleInCluster('hbase-master', $hadoop->currentCluster()))[0];
    my $javaHome = $ENV{'JAVA_HOME'} = ariba::Ops::Startup::Common::javaHomeForProduct($hadoop);
    my $installDir = $hadoop->installDir();
    my $mrDir = $installDir . "/hadoop/share/hadoop/mapreduce1";
    my $hadoopHome = $installDir . "/hadoop";
    my $hbaseHome = $installDir . "/hbase";
    my $hadoopConfDir = $hadoopHome . "/conf";
    my $svcUser = "svc$serviceHadoop";
    my $cmd = "ssh $svcUser\@$host -x 'bash -c \"export JAVA_HOME=$javaHome; export HADOOP_HOME=$mrDir; export HADOOP_CONF_DIR=$hadoopConfDir";
    my $dsid = $self->instance();
    my $fromTenant = $self->fromTenant();
    my $exportDir = "/export/backup/$dsid/$rootTable";
    my @cmdExport;

    my $hdfsVersions = ariba::Ops::Constants::hdfsVersions();
    my $firstExport = ariba::Ops::Constants::hdfsFirstExport();

    #
    # Get tablenames
    #
    my $arches = ariba::rc::InstalledProduct->new($productArches, $serviceArches);
    my $installDirArches = $arches->installDir();
    
    $logger->info("Getting list of tables to export");
    my @tables = ariba::Ops::HadoopHelper::getHbaseTables($arches->name(), $arches->service(), 0);

    unless (scalar @tables > 0) {
        $logger->error("No tables returned from gethbasetables"); 
        return 0;
    }

    my @tablesWithTenantSpecificKey = ariba::Ops::HadoopHelper::getHbaseTables($arches->name(), $arches->service(), 1);
    my %hash;
    $hash{$_} = 1 foreach @tablesWithTenantSpecificKey;
    my @tablesWithoutTenantSpecificKey = grep( ! $hash{$_}, @tables);
    
    my $now = time();
    # Convert now time to milliseconds or hbase export with buyerTenant doesn't export correctly
    $now = $now * 1000;

    foreach my $table (@tablesWithTenantSpecificKey) {
        $table =~ s/\n//g;
        #
        # there is a limitation in the number of chars we can pass as a remote command, need to see how we can break this up.
        # below is just for 1 table
        #
        $logger->info("Preparing to take export of $table on $productArches $serviceArches");
        my $cmdExport = "ssh $svcUser\@$host $installDir/bin/hbase-export-table -service $serviceHadoop -table $table -tenant $fromTenant -rtable $rootTable -dsid $dsid -now $now";

        my $exportOutput = $self->runHbaseCommand($cmdExport, $serviceHadoop, $svcUser);
        if (grep $_ =~ /$exportDir\/$table already exists/, @{$exportOutput}) {
            $logger->info("WARN: skipped exporting $table. An export already exists in $exportDir...");
        }
    }

    foreach my $table (@tablesWithoutTenantSpecificKey) {
        $table =~ s/\n//g;
        #
        # there is a limitation in the number of chars we can pass as a remote command, need to see how we can break this up.
        # below is just for 1 table
        #
        $logger->info("Preparing to take export of $table on $productArches $serviceArches");
        my $cmdExport = "ssh $svcUser\@$host $installDir/bin/hbase-export-table -service $serviceHadoop -table $table -rtable $rootTable -dsid $dsid -now $now";

        my $exportOutput = $self->runHbaseCommand($cmdExport, $serviceHadoop, $svcUser);
        if (grep $_ =~ /$exportDir\/$table already exists/, @{$exportOutput}) {
            $logger->info("WARN: skipped exporting $table. An export already exists in $exportDir...");
        }
    }

    #
    # Copy exported files from hdfs to archmgr location
    #
    my $archiveDir = ariba::Ops::Constants->archiveManagerArchiveDir() . "/" . $self->instance();
    my $cmdCopy = "$cmd ; $hadoopHome/bin/hdfs dfs -get $exportDir $archiveDir\"'";
    $logger->info("Copying files from hdfs to archive manager");
    my $copyOutput = $self->runHbaseCommand($cmdCopy, $serviceHadoop, $svcUser);
    if (grep $_ =~ /File exists/, @{$copyOutput}) {
        $logger->info("WARN: skipped copying export from hdfs to $archiveDir, 1 or more of the files already exist.");
        return 0;
    }

    #
    # Compress export on archmgr directory
    #
    my $tarFile = $archiveDir . "/" . $rootTable . "_" . $self->instance() . ".tgz";
    $logger->info("Compressing $archiveDir/$rootTable to $tarFile"); 

    my $tarCmd = tarCmd() . " zcf";
    $tarCmd .= " $tarFile -C $archiveDir $rootTable";

    if ( $self->testing() ) {
        $logger->debug("DRYRUN: would create export $tarFile file");
    } else {
        system($tarCmd) == 0 or do {
            my $error = $?;
            $logger->error("Failed to create export $tarFile file");
            $logger->error("tar returned " . ($error >> 8));
            return 0;
        };

        #
        # Cleaning up export on hdfs
        #
        $logger->info("Cleaning up exports from hdfs");
        my $cmdRmr = "$cmd ; $hadoopHome/bin/hdfs dfs -rmr $exportDir\"'";
        my $rmrOutput = $self->runHbaseCommand($cmdRmr, $serviceHadoop, $svcUser);

        #
        # Clean up uncompressed export on archive manager 
        #
        $logger->info("Cleanup uncompressed exports from archive manager");
        my $rmDirCmd = "ssh $svcUser\@$host -x 'bash -c \"rm -rf $archiveDir/$rootTable\"'";
        my $rmDirOutput = $self->runHbaseCommand($rmDirCmd, $serviceHadoop, $svcUser);

        $self->setDatasetComplete(1);

        return unless $self->_save();
    }
}

sub runHbaseCommand {
    my $self = shift;
    my $cmd = shift;
    my $service = shift;
    my $svcUser = shift;

    if ($self->testing()) {
        $logger->info("DRYRUN: $cmd");
        return;
    } else {
        ariba::rc::Passwords::initialize($service);
        my $pass = ariba::rc::Passwords::lookup( $svcUser );
        my @cmdOutput;
        ariba::rc::Utils::executeRemoteCommand(
            $cmd,
            $pass,
            0,
            undef,
            undef,
            \@cmdOutput,
        );
        return (\@cmdOutput);
    }
}

sub filterHbaseTables {
    my $cmdOutput = shift;
    my $rootTable = shift;
    my @tables;

    foreach my $line  (@{$cmdOutput}) {
        #next if ($line =~ /^(?:SLF4J|HBase Shell|Type|Version|list|TABLE|\d+ row)/);
        next unless ($line =~ /^$rootTable\./);
        push(@tables, $line) if ($line =~ /(\w+\.)+/);
    }

    return \@tables;
}

sub isSnapShot {
    my $self = shift;
    return 1 if($self->isFpc() || $self->isThin());
    return 0;
}

sub isThinBase {
    my $self = shift;
    return 1 if $self->backupType() && $self->backupType() eq "thinbase";
    return 0;
}

sub isThinChild {
    my $self = shift;
    return 1 if $self->backupType() && $self->backupType() eq "thinchild";
    return 0;
}

sub isThin {
    my $self = shift;
    return ($self->isThinBase() || $self->isThinChild());
}

sub isHbaseExport {
    my $self = shift;
    return 1 if $self->backupType() && $self->backupType() eq "hbase";
    return 0;
}

sub sidDiskAndDatasetIdForVVName {
    my $vvname = shift;
    my $sidId;
    my $diskId;
    my $dsId;

    if($vvname =~ /-DS(\d+)-[DR]*(\d+)-(\d+)$/) {
        $dsId = $1;
        $sidId = $2;
        $diskId = $3;
    }

    return($sidId, $diskId, $dsId);
}

sub baseVVNameForSidAndDisk {
    my $self = shift;
    my $sidId = shift;
    my $diskId = shift;
    my $dr = shift;

    my $sidPrefix = "";
    $sidPrefix = "DR" if($dr);

    my $name = sprintf("base-DS%05d-%s%02d-%d",
        $self->instance(), $sidPrefix, $sidId, $diskId);

    return($name);
}

sub baseReadOnlySnapshotNameForSidAndDisk {
    my $self = shift;
    my $sidId = shift;
    my $diskId = shift;
    my $dr = shift;

    unless(defined $sidId && defined $diskId) {
        #
        # support a base return value for pattern matching
        #
        my $name = sprintf("basescro-DS%05d*", $self->instance());
        return($name);
    }

    my $sidPrefix = "";
    $sidPrefix = "DR" if($dr);

    my $name = sprintf("basescro-DS%05d-%s%02d-%d",
        $self->instance(), $sidPrefix, $sidId, $diskId);

    return($name);
}

sub baseSnapshotNameForSidAndDisk {
    my $self = shift;
    my $sidId = shift;
    my $diskId = shift;
    my $dr = shift;

    my $sidPrefix = "";
    $sidPrefix = "DR" if($dr);

    my $name = sprintf("scrw-DS%05d-%s%02d-%d",
        $self->instance(), $sidPrefix, $sidId, $diskId);

    return($name);
}

sub exportReadOnlyNameForSidAndDisk {
    my $self = shift;
    my $sidId = shift;
    my $diskId = shift;
    my $dr = shift;

    unless(defined $sidId && defined $diskId) {
        #
        # support a base return value for pattern matching
        #
        my $name = sprintf("scro-DS%05d*", $self->instance());
        return($name);
    }

    my $sidPrefix = "";
    $sidPrefix = "DR" if($dr);

    my $name = sprintf("scro-DS%05d-%s%02d-%d",
        $self->instance(), $sidPrefix, $sidId, $diskId);

    return($name);
}

sub runReadWriteNameForProductAndService {
    my $self = shift;
    my $product = shift;
    my $service = shift;
    my $sidId = shift;
    my $diskId = shift;
    my $dr = shift;

    my $sidPrefix = "";
    $sidPrefix = "DR" if($dr);

    my $name = sprintf("$service-$product-DS%05d-%s%02d-%d",
        $self->instance(), $sidPrefix, $sidId, $diskId);

    return($name);
}

sub unMountPeerDatabases {
    my $self = shift;
    my @args = (@_);

    return 0 unless( $self->shutdownDatabase(@args) );
    return ( $self->unmountFilesystems(@args) );
}

sub shutdownDatabase {
    my $self = shift;
    my $dbPeers = shift;

    # shutdown dataguard only for backups with a secondary defined
    if ( $dbPeers->secondary() && !$self->restore()) {
        my $sleepTime = 5;
        my $attempt = 0;
        $logger->info("Checking Dataguard Lag");
        my $results = $dbPeers->checkDataguardLag();
        while ($results == 0) {
            $logger->warn("Dataguard is not caught up after $attempt tries, sleeping $sleepTime seconds");
            $attempt++;
            last if $attempt >= 10;
            $results = $dbPeers->checkDataguardLag();
            sleep $sleepTime;
        }

        unless ($results) {
            $logger->error("Dataguard check did not succeed");
            return 0;
        }

        # 2. shutdown dataguard
        $logger->info("Shutting down dataguard");
        unless ($dbPeers->shutdownDataguard()) {
            $logger->error("Shutting down dataguard failed");
            return 0;
        }
    }

    # suspend archive log deletions
    unless ( $dbPeers->suspendArchiveLogDeletions() ) {
        $logger->error("Suspending archive log deletions failed");
        return 0;
    }

    # shutdown db
    my $andSecondary = "";
    $andSecondary = " and secondary" if $dbPeers->secondary();
    $logger->info("Shutting down primary$andSecondary databases for SID: " . $dbPeers->sid());
    unless ( $dbPeers->shutdownOracle($self->restore(), "ignoreError") ) {
        $logger->error("Shutting down Oracle Failed");
        return 0;
    }

    return 1;
}


sub unmountFilesystems {
    my $self = shift;
    my $dbPeers = shift;

    # unmount filesystems
    $logger->info("Unmounting database filesystems");
    unless ($dbPeers->unmountDbFilesystems()) {
        $logger->error("unmounting filesystems failed");
        return 0;
    }

    return 1;
}

sub mountPeerDatabases {
    my $self = shift;
    my (@args) = (@_);

    return 0 unless( $self->mountFilesystems(@args) );
    return( $self->startDatabase(@args) );
}

sub mountFilesystems {
    my $self = shift;
    my $dbPeers = shift;

    # 6. mount filesystems
    $logger->info("Mounting database filesystems back");
    unless ($dbPeers->mountDbFilesystems()) {
        $logger->error("mounting filesystems failed");
        return 0;
    }

    return 1;
}

sub startDatabase {
    my $self = shift;
    my $dbPeers = shift;

    # 7. start db
    unless ( $dbPeers->startupOracle() ) {
        $logger->error("Starting Oracle Failed");
        return 0;
    }

    # 8. start dataguard
    if ( $dbPeers->secondary() ) {
        $logger->info("Starting dataguard");
        unless ($dbPeers->startupDataguard()) {
            $logger->error("Starting dataguard failed");
            return 0;

        }
    }

    # resume archive log deletions
    unless ( $dbPeers->resumeArchiveLogDeletions() ) {
        $logger->error("Resuming archive log deletions failed");
        return 0;
    }


    return 1;
}

sub backupFPC {
    my $self = shift;
    my $dbcRef = shift;
    my %archiveLogDirs;

    ## HACK!  If robots get into this subroutine it will call a load exception since the monitor
    ## product isn't available there.  Therefore, we we cannot support running FPC datasets from
    ## non-Ops services.
    ariba::Ops::Inserv::VolumeLun->setDir(ariba::Ops::Constants->archiveManagerMetaDataDir() . "/" . $self->instance());

    $self->removeSnapshots();

    my %sidsSeen;
    foreach my $dbc (@{$dbcRef}) {
        next if($sidsSeen{$dbc->sid()});
        next if($dbc->isDR()); # we only need to do this for PRIMARY
        $sidsSeen{$dbc->sid()} = 1;

        next if($dbc->dbServerType() =~/Hana/si);
        #
        # B1 run this query on DB:
        #    select DESTINATION from v$archive_dest where dest_name='LOG_ARCHIVE_DEST_1';
        #
        #    query will return a directory with archive logs to back up
        #
        my $oc = ariba::Ops::OracleClient->newSystemConnectionFromDBConnection($dbc);
        unless($oc->connect()) {
            $logger->error("unable to connect to database to find archive logs: [" . $oc->error() . "].");
            return;
        }
        my $sql = "select DESTINATION from v\$archive_dest where dest_name='LOG_ARCHIVE_DEST_1'";
        my ( $result ) = $oc->executeSql($sql);
        if( $result ) {
            $logger->info("will backup archivelogs from $result on " . $dbc->host());
            $archiveLogDirs{$result} = $dbc->host();
        } else {
            $logger->error("Unable to find archive log location for " .
                $dbc->sid() . " which has DR.");
            $logger->info("This is a DB config problem.  Contact the DBAs");
            return(0);
        }
    }

    #
    # This loop does these steps:
    #
    # B2 Do your regular DSM check for the DR sync-up.
    # B3 Take down the primary Database.
    # B4 Take down the DR dataguard and database.
    #
    for my $dbPeers ($self->peers()) {
        unless ( $self->shutdownDatabase($dbPeers) ) {
            return;
        }
    }

    #
    # B5 Go to the primary host directory derived from the query result on B1.
    # B6 Save the last 20 log files, based on timestamp, from log directory
    #   to data directory
    #
    foreach my $dir (keys %archiveLogDirs) {
        $self->backupArchiveLogs($dir, $archiveLogDirs{$dir});
    }

    #
    # B6.5 - unmount the filesystems
    # B7 - Take a 3par snapshot backup.
    #
    for my $dbPeers ($self->peers()) {
        unless ( $self->unmountFilesystems($dbPeers) ) {
            return;
        }

        # 5. take snapshot
        $logger->info("Taking snapshot of the filesystems");

        for my $peerConnection ($dbPeers->primary(), $dbPeers->secondary()) {
            next unless $peerConnection;
            for my $filesystem ($peerConnection->dbFsInfo()) {
                my $inservHostname = $filesystem->inserv();
                my $machine = ariba::Ops::Machine->new($inservHostname);
                my $nm = ariba::Ops::NetworkDeviceManager->newFromMachine($machine, $self->shouldProxy());
                $nm->setDebug(1) if $self->debug() >= 2;
                my @virtualVols;
                my @vvList = $filesystem->vvList();

                for my $vvName (@vvList) {
                    push(@virtualVols, $nm->virtualVolumesByName($vvName));
                }
                if ($self->testing()) {
                    $logger->debug("DRYRUN: would cut snapshot for the following VVs: " . join ", ", @vvList);
                } else {
                    unless ($nm->makeSnapCopyForVirtualVolumes(\@virtualVols, $self->fpcId(), "readonly")) {
                        $logger->error("3par backup for vvlist " . join(",", $filesystem->vvList()) . " failed");
                        return;
                    }

                    my @vluns = $nm->vLunsforVirtualVolumesOfFilesystem({ 'vvlist' => \@vvList, 'instancePrefix' => "DS", 'fs' => $filesystem->fs() });
                    if ($self->vluns()) {
                        $self->appendToAttribute('vluns', @vluns);
                    } else {
                        $self->setVluns(@vluns);
                    }
                    return unless $self->_save();
                }
            }
        }

        return unless $self->mountPeerDatabases($dbPeers);

        $logger->info("Successfully created filesystem snapshots for " . $self->sid());
    }

    return 1;
}

sub oracleArchiveLogBackupDir {
    my $self = shift;

    my $DATADIR = ariba::Ops::Constants->archiveManagerArchiveDir();
    $DATADIR .= "/" . $self->instance() . "/oracleArchiveLogs";

    return($DATADIR);
}

sub restoreArchiveLogsMCL {
    my $self = shift;
    my $sid = shift;
    my (@volumes) = (@_);
    my $DATADIR = $self->oracleArchiveLogBackupDir();
    my $service = $self->serviceName();
    my $mcl = "";

    $logger->info("restoring from $DATADIR");

    unless (-d $DATADIR) {
        $logger->info("\t- skipping as dir does not exist");
        return "";
    }

    my $find = ariba::util::Simplefind->new($DATADIR);
    my @files = grep { $_ =~ /hostname/ } $find->find();

    if($sid) {
        @files = grep { $_ =~ m|/$sid/|i } @files;
    }

    foreach my $f (@files) {
        open(F, "< $f");
        my $host = <F>; chomp $host;
        close(F);

        unless( ariba::Ops::Machine->objectWithNameExists($host) ) {
            #
            # invalid host, skip
            #
            next;
        }

        my $restoreFromDir = dirname($f);
        my $restoreToDir = $restoreFromDir;
        $restoreToDir =~ s|^$DATADIR||;

        #
        # if the oracle logs dir is also the data dir, we don't need to restore
        # since the logs are part of the snapshot
        #
        my $skip = 0;
        foreach my $volumeName (@volumes) {
            # chop the a -- /ora144a and /ora144 are the same
            $volumeName =~ s/a$//;
            my $regex = "^" . $volumeName . "a?/";
            if($restoreToDir =~ m|$regex|) {
                $logger->info("Skipping $restoreToDir since it's in the snapshot.");
                $skip = 1;
                last;
            }
        }
        next if($skip);

        $logger->info("... restoring $restoreFromDir to $restoreToDir on $host.");

        my $user = "svc$service";
        my $dsm = $FindBin::Bin . "/" . basename($0);
        unless( $dsm =~ /dataset-manager/) {
            $dsm = "/usr/local/ariba/bin/dataset-manager";
        }
        my $sudo = ariba::rc::Utils::sudoCmd();
        my $cmd = "$sudo $dsm restorelogs -oracledir $restoreToDir -datasetdir $restoreFromDir";

        if($self->testing()) {
            $logger->info("Would be running: $cmd");
        } else {
            $mcl .= "Action: Shell $user\@$host {\n";
            $mcl .= "\t\$ $cmd\n";
            $mcl .= "}\n";
        }
    }

    return $mcl;
}

sub restoreArchiveLogs {
    my $self = shift;
    my $sid = shift;
    my $DATADIR = $self->oracleArchiveLogBackupDir();
    my $service = $self->serviceName();

    $logger->info("restoring from $DATADIR");

    unless (-d $DATADIR) {
        $logger->info("\t- skipping as dir does not exist");
        return;
    }

    my $find = ariba::util::Simplefind->new($DATADIR);
    my @files = grep { $_ =~ /hostname/ } $find->find();
    if($sid) {
        @files = grep { $_ =~ m|/$sid/| } @files;
    }

    foreach my $f (@files) {
        open(F, "< $f");
        my $host = <F>; chomp $host;
        close(F);

        unless( ariba::Ops::Machine->objectWithNameExists($host) ) {
            #
            # invalid host, skip
            #
            next;
        }

        my $restoreFromDir = dirname($f);
        my $restoreToDir = $restoreFromDir;
        $restoreToDir =~ s|^$DATADIR||;

        $logger->info("... restoring $restoreFromDir to $restoreToDir on $host.");

        my $user = "svc$service";
        my $passwd = ariba::rc::Passwords::lookup( $user );
        my $dsm = $FindBin::Bin . "/" . basename($0);
        unless( $dsm =~ /dataset-manager/) {
            $dsm = "/usr/local/ariba/bin/dataset-manager";
        }
        my $sudo = ariba::rc::Utils::sudoCmd();
        my $cmd = "ssh -l $user $host $sudo $dsm restorelogs -oracledir $restoreToDir -datasetdir $restoreFromDir";

        if($self->testing()) {
            $logger->info("Would be running: $cmd");
        } else {
            $logger->info("running: $cmd");
            ariba::rc::Utils::executeRemoteCommand($cmd,$passwd);
        }
    }
}

sub backupArchiveLogsMCL {
    my $self = shift;
    my $dir = shift;
    my $host = shift;
    my (@volumes) = (@_);
    my $service = $self->serviceName();
    my %files;
    my $mcl;
    my $DATADIR = $self->oracleArchiveLogBackupDir();
    #
    # dir pretty much has to be an absolute path, so this concat should be
    # safe
    #
    $DATADIR .= $dir;

    foreach my $v (@volumes) {
        $v =~ s/a$//; # chop the a -- /ora144a is the same as /ora144
        my $regex = "^" . $v . "a?/";
        if($dir =~ m|$regex|) {
            $logger->info("Skipping backup of $dir (it's on the snapshot of $v)");
            return "";
        }
    }

    $logger->info("Backing up $dir to $DATADIR");

    ariba::rc::Utils::mkdirRecursively($DATADIR);

    my $user = "svc$service";
    my $dsm = $FindBin::Bin . "/" . basename($0);
    unless( $dsm =~ /dataset-manager/) {
        $dsm = "/usr/local/ariba/bin/dataset-manager";
    }
    my $sudo = ariba::rc::Utils::sudoCmd();
    my $cmd = "$sudo $dsm backuplogs -oracledir $dir -datasetdir $DATADIR";

    if($self->testing()) {
        $logger->info("Would be running: $cmd");
    } else {
        $logger->info("running: $cmd");
        $mcl .= "Action: Shell {\n";
        $mcl .= "\t\$ chmod 0777 $DATADIR\n";
        $mcl .= "}\n";
        $mcl .= "Action: Shell $user\@$host {\n";
        $mcl .= "\t\$ $cmd\n";
        $mcl .= "}\n";
        $mcl .= "Action: Shell {\n";
        $mcl .= "\t\$ chmod 2775 $DATADIR\n";
        $mcl .= "}\n";
    }

    return $mcl;
}

sub backupArchiveLogs {
    my $self = shift;
    my $dir = shift;
    my $host = shift;
    my $service = $self->serviceName();
    my %files;
    my $DATADIR = $self->oracleArchiveLogBackupDir();
    #
    # dir pretty much has to be an absolute path, so this concat should be
    # safe
    #
    $DATADIR .= $dir;

    $logger->info("Backing up $dir to $DATADIR");

    ariba::rc::Utils::mkdirRecursively($DATADIR);

    my $user = "svc$service";
    my $passwd = ariba::rc::Passwords::lookup( $user );
    my $dsm = $FindBin::Bin . "/" . basename($0);
    unless( $dsm =~ /dataset-manager/) {
        $dsm = "/usr/local/ariba/bin/dataset-manager";
    }
    my $sudo = ariba::rc::Utils::sudoCmd();
    my $cmd = "ssh -l $user $host $sudo $dsm backuplogs -oracledir $dir -datasetdir $DATADIR";

    if($self->testing()) {
        $logger->info("Would be running: $cmd");
    } else {
        $logger->info("running: $cmd");

        my $mode = (stat($DATADIR))[2];
        chmod(0777, $DATADIR);
        ariba::rc::Utils::executeRemoteCommand($cmd,$passwd);
        chmod($mode, $DATADIR);
    }
}

sub _registerDBSchema {
    my $self = shift;
    my $sid = shift;
    my $schemaName = shift;
    my $dbType = shift;
    my $schemaId = shift;

    my $dbExportId = $self->_getNextDBExportID();
    my $exportFile = "$dbExportId.dmp";

    # If type isn't specified, default to type main.
    $dbType = ariba::Ops::DBConnection->typeMain() if ! defined $dbType or !$dbType;

    $self->setSchemaName($schemaName, $dbExportId);
    $self->setExportFile($exportFile, $dbExportId);
    $self->setLogfile("$exportFile.exp.log", $dbExportId);
    $self->setSchemaType($dbType, $dbExportId);
    $self->setBackupStatus("Not Started", $dbExportId);
    if ( defined $schemaId && $schemaId >= 0 ) {
        $self->setSchemaId($schemaId, $dbExportId);
    }

    return $dbExportId;
}

sub prepareDBSchemasForBackup {
    my $self = shift;
    my $dbc = shift;

    my $productName = $self->productName();
    my $schemaName = $dbc->user();
    my $dbType = $dbc->type;
    my $sid = $dbc->sid();
    my $password = $dbc->password();
    my $host = $dbc->host();

    my $databaseType = $dbc->dbType;
    if ($databaseType eq 'hana') {
       my $instance = $self->instance();
       my $LOGSDIR = ariba::Ops::Constants->archiveManagerArchiveDir() . "/$instance" . "/hana";

       if ( -d $LOGSDIR ) {
           return 1;
       }

       my $sudo = ariba::rc::Utils::sudoCmd();
       my $cmd = "mkdir $LOGSDIR; chmod 777 $LOGSDIR";
       my $user = "svc" . $self->serviceName();
       my $passwd = ariba::rc::Passwords::lookup( $user );
       my @output;

       unless ( ariba::rc::Utils::executeLocalCommand($cmd, undef, \@output, undef, 1, undef, $passwd) ) {
            print "mkdir $LOGSDIR failed:\n", join("\n", @output), "\n";
            return 0;
       }

       print ("$schemaName is on HANA, created $LOGSDIR...\n");
       return 1;
    }

    # Get the Oracle Connection
    my $oc = ariba::Ops::OracleClient->new($schemaName, $password, $sid, $host);
    $oc->setDebug(1) if $self->debug() >= 2;
    if ( !$oc->connect() ) {
        $logger->error("Connection to $schemaName\@$sid failed: [" . $oc->error() . "].");
        return;
    }

    ## HACK! We need to "clean" some values from the source build before creating a dataset.
    ## This happens when we do an product FPC as part of the clean script along with all normal
    ## cleansing that we don't want to do.  Long term, we should split the FPC cleansing script
    ## into two pieces, and run the appropriate one here.
    ## Also, this changes the database for a currently running service.  Brian Luo has assured us
    ## there will be no ill side affects as a result of this.
    if ($dbType eq ariba::Ops::DBConnection->typeMain() && $productName &&
        grep($_ eq $productName, ariba::rc::Globals::sharedServicePlatformProducts())) {

        my $cleanSQL = q`
        BEGIN
            update RealmProfileTab set rp_EnterpriseUserUrlFormat = '';
            update RealmProfileTab set rp_SupplierUserUrlFormat = '';
            commit;
        END;
        /
        `;

        $logger->info("Cleaning RealmProfileTab in source schema $schemaName\@$sid");
        return unless $self->_buildAndExcuteSQL($oc, $cleanSQL);
    }

    #
    # drop materialized view logs before doing export
    #
    my $matViewSQL = q`
    BEGIN
        FOR mv IN (SELECT DISTINCT(master) FROM USER_MVIEW_LOGS) LOOP
            EXECUTE IMMEDIATE 'DROP MATERIALIZED VIEW LOG ON ' || mv.master;
        END LOOP;
    END;
    /
    `;
    $logger->info("Dropping materialized view logs for schema $schemaName\@$sid");
    return unless $self->_buildAndExcuteSQL($oc, $matViewSQL);

    # Create stats
    my $createStatsSQL = q`
        exec dbms_stats.gather_schema_stats(NULL, GRANULARITY => 'ALL', CASCADE => TRUE);
    `;

    $logger->info("Creating stats for $schemaName\@$sid");
    return unless $self->_buildAndExcuteSQL($oc, $createStatsSQL);
    $oc->disconnect();

    return 1;
}

sub backupDBSchema {
    my $self = shift;
    my $dbc = shift;
    my $databaseType = $dbc->dbType;

    if ($databaseType eq 'hana') {
      $self->backupDBSchemaInHana($dbc);
    }
    else {
      $self->backupDBSchemaInOracle($dbc);
    }
}

sub backupDBSchemaInHana {

    require ariba::DBA::HanaSampleSQLQueries;

    my $self = shift;
    my $dbc = shift;

    my $dbType = $dbc->type();
    my $schemaId = $dbc->schemaId();
    my $schemaName = $dbc->user();
    my $password = $dbc->password();
    my $instance = $self->instance();
    my $port = $dbc->port();

    my $mon = ariba::rc::InstalledProduct->new('mon', $dbc->product()->service());

    # Only run the backup on the master in the cluster, per jira-ID: HOA-4243
    my $host = ariba::DBA::HanaSampleSQLQueries::whoIsMaster( $mon, $dbc);

    # If $host cannot be figured out from hana sample query, get it from the $dbc
    unless ($host && $host =~ /hana/) {
       $logger->warn("Master hana host in the cluster not found from ariba::DBA::HanaSampleSQLQueries::whoIsMaster");
       $host = $dbc->host();
    }

    my $exportDirPath = ariba::Ops::Constants->archiveManagerArchiveDir() . "/$instance" . "/hana";

    my $dbExportId = $self->_registerDBSchema($host, $schemaName, $dbType, $schemaId);
    my $hc = ariba::Ops::HanaClient->new($schemaName, $password, $host,$port);
    if ( !$hc->connectNew($exportDirPath,2) ) {
        $logger->error("Connection to $schemaName and host $host failed: [" . $hc->error() . "].");
        return;
    }
    $hc->setDebug(1) if $self->debug() >= 2;

    $logger->info("Exporting schema $schemaName on $host");

    # Do the export
    if ($self->testing()) {
        $logger->debug("DRYRUN: would export $schemaName");
    } else {
	###creating index and export path as it backup files for multiple hana hosts
	my $hanaIndexPath = $exportDirPath."/index";
	my $hanaExportPath = $exportDirPath."/export";
	my $permission = '777';
	unless ( -d $hanaIndexPath && -d $hanaExportPath ){
		unless(mkdirWithPermission($hanaIndexPath,$permission) && mkdirWithPermission($hanaExportPath,$permission)){
			$logger->error("Failed to create dir $hanaIndexPath or $hanaExportPath");
			###let it continue, as export itself create directories again if not found
		}
	}

        $hc->dbExport($schemaName, $exportDirPath);

        if ($hc->error()) {
            $logger->error("Running export of $schemaName failed: [" . $hc->error() . "].");
            $self->setBackupStatus("Failed", $dbExportId);
            return 0;
        }

        $self->setBackupStatus($DS_STATUS_SUCCESSFUL, $dbExportId);
    }

    $hc->disconnect();

    return 1;
}

sub backupDBSchemaInOracle {
    my $self = shift;
    my $dbc = shift;

    my $sid = $dbc->sid();
    my $schemaName = $dbc->user();
    my $password = $dbc->password();
    my $host = $dbc->host();
    my $dbType = $dbc->type();
    my $schemaId = $dbc->schemaId();

    my $instance = $self->instance();

    my $dbExportId = $self->_registerDBSchema($sid, $schemaName, $dbType, $schemaId);

    my $exportFile = $self->exportFile($dbExportId);

    # Get the Oracle Connection
    my $oc = ariba::Ops::OracleClient->new($schemaName, $password, $sid, $host);
    if ( !$oc->connect() ) {
        $logger->error("Connection to $schemaName\@$sid failed: [" . $oc->error() . "].");
        return;
    }

    my $tableSpaceName = $self->QueryForTableSpace($oc,$schemaName);
    $self->setTableSpaceName($tableSpaceName,$dbExportId);
    $oc->setDebug(1) if $self->debug() >= 2;

    $logger->info("Exporting schema $schemaName\@$sid on $host");

    my $exportFileFullPath = ariba::Ops::Constants->archiveManagerArchiveDir() . "/$instance/$exportFile";
    if ( -f $exportFileFullPath ) {
        $logger->error("$exportFile exists for dataset $instance, not running export of $schemaName\@$sid");
        return;
    }

    my $dirObjName = $self->getOracleDirObj($oc,'expdp');
    my %exportImportParamHash;
    ##$exportImportParamHash{'FILE'} = $exportFileFullPat;h
    $exportImportParamHash{'DUMPFILE'} = $exportFile;
    ##$exportImportParamHash{'BUFFER'} = 1024000;
    ##$exportImportParamHash{'COMPRESS'} = "Y";
    ##$exportImportParamHash{'CONSISTENT'} = "Y";
    ##$exportImportParamHash{'OWNER'} = $schemaName;
    ##$exportImportParamHash{'LOG'} = "$exportFileFullPath.exp.log";
    $exportImportParamHash{'LOGFILE'} = "$exportFile.expdp.log";
    $exportImportParamHash{'DIRECTORY'} = $dirObjName;
    $exportImportParamHash{'EXCLUDE'} = 'GRANT,STATISTICS';

    $logger->info("Begining export for $schemaName on $sid, log at $exportFileFullPath.exp.log");

    # Do the import
    if ($self->testing()) {
        $logger->debug("DRYRUN: would export $schemaName\@$sid");
    } else {
        $oc->dbExport(\%exportImportParamHash);
        $self->dropObjDirectory($oc,$dirObjName);

        # Set the size after the export but before we check for an error
        $self->setFileSizeInBytes((stat($exportFileFullPath))[7], $dbExportId);

        if ($oc->error()) {
            $logger->error("Running export of $schemaName\@$sid failed: [" . $oc->error() . "].");
            $self->setBackupStatus("Failed", $dbExportId);
            return;
        }

        $logger->info("Successfull export of $schemaName\@$sid");
        $self->setBackupStatus($DS_STATUS_SUCCESSFUL, $dbExportId);
    }

    $oc->disconnect();

    return 1;
}

sub QueryForTableSpace{
    my $self = shift;
    my $oc = shift;
    my $schemaName = shift;

    my $sql = "select DEFAULT_TABLESPACE from user_users where USERNAME= upper('".$schemaName."')";
    my $result = $oc->executeSql($sql);

    unless ($result){
        die "Error: in executing the sql:$sql\n";
    }

    return $result;
}

sub getOracleDirObj{
    my $self = shift;
    my $oc = shift;
    my $action = shift;

    my $instance = $self->instance();

    ##alarm 2;   ##enable later need to keep env
    my $randNum = int rand 1048576 + $$;
    my $exportPath = ariba::Ops::Constants->archiveManagerArchiveDir() . "/$instance";
    my $dirObjName = $action.$instance.$randNum;
    my $sql = "create directory $dirObjName as \'$exportPath\'";

    my $result = $oc->executeSql($sql);
    if ($result){
        die "Error: in executing the sql:$sql : $result\n";
    }
    my $sqlGrant = 'grant read, write , execute on directory '.$dirObjName.' to public';

    my $grantRes = $oc->executeSql($sqlGrant);
    if ($grantRes){
        my $dropSql = 'drop directory '.$dirObjName;
        $oc->executeSql($dropSql);
        die "Error: Unable to Grant permission to $dirObjName by executing the sql:$sqlGrant :$grantRes\n";
    }
    return $dirObjName;
}

sub _buildAndExcuteSQL {
    my $self= shift;
    my $oc = shift;
    my $sql = shift;

    my $sqlFile = "/tmp/dataset-sql.$$.sql";
    open (SQLFILE, ">$sqlFile") || do {
        $logger->error("Can't open $sqlFile: $!");
        return;
    };

    print (SQLFILE $sql) || do {
        $logger->error("error writing $sqlFile: $!");
        unlink($sqlFile);
        return;
    };

    close(SQLFILE) || do {
        $logger->error("error closing $sqlFile: $!");
        unlink($sqlFile);
        return;
    };

    if ($self->testing()) {
        $logger->debug("DRYRUN: would run $sqlFile using ariba::Ops::OracleClient::executeSqlFile()");
    } else {
        unless ($oc->executeSqlFile($sqlFile)) {
            $logger->error("Failed to run $sqlFile: " . $oc->error());
            unlink($sqlFile);
            return;
        }
    }

    unlink($sqlFile);
}

sub removeDbBackups {
    my $self = shift;

    if ($self->isFPC()) {
        return unless $self->removeSnapshots();
    } elsif ($self->isThin()) {
        return unless $self->removeThinSnapshots();
    } else {
        return unless $self->removeDbSchemaBackups();
    }

    return 1;
}

sub removeDbSchemaBackups {
    my $self = shift;

    for my $backupId ( $self->getDBExportIds() ) {
        unless ( $self->removeDBSchemaBackupByExportId($backupId) ) {
            return;
        }
    }

    return 1;
}

sub removeDBSchemaBackupByExportId {
    my $self = shift;
    my $dbExportId = shift;

    my $instance = $self->instance();
    my $exportFile = $self->exportFile($dbExportId);

    unless ( $exportFile ) {
        $logger->error("Cannot get export file name from dataset metadata, cannot remove DB schema backup");
        return;
    }

    my $exportLogFile = $self->logFile();

    if ( $self->testing() ) {
        $logger->debug("DRYRUN: would remove db Schema backup file and Log file for export ID $dbExportId of instance " . $self->instance());
    } else {
        $logger->info("removing schema backup $dbExportId from dataset instance " . $self->instance());
        for my $file ($exportFile, $exportLogFile) {
            $logger->debug("Removing $file");
            if ( -f ariba::Ops::Constants->archiveManagerArchiveDir() . "/$instance/$file" ) {
                unless ( unlink(ariba::Ops::Constants->archiveManagerArchiveDir() . "/$instance/$file") ) {
                    $logger->error("Failed to remove $file: " . $!);
                    return;
                }
            }
        }

        $self->removeBackupAttributes($dbExportId);
    }

    return 1;
}

sub removeSnapshots {
    my $self = shift;

    ariba::Ops::Inserv::VolumeLun->setDir(ariba::Ops::Constants->archiveManagerMetaDataDir() . "/" . $self->instance());

    for my $dbPeers ($self->peers()) {
        for my $peerConnection ($dbPeers->primary(), $dbPeers->secondary()) {
            next unless $peerConnection;
            for my $filesystem ($peerConnection->dbFsInfo()) {
                $logger->debug("Removing snapshots for " . $filesystem->fs() . " on " . $peerConnection->host());
                my $inservHostname = $filesystem->inserv();
                my $machine = ariba::Ops::Machine->new($inservHostname);
                my $nm = ariba::Ops::NetworkDeviceManager->newFromMachine($machine, $self->shouldProxy());
                $nm->setDebug(1) if $self->debug() >= 2;
                my @virtualVols;
                for my $vvName ($filesystem->vvList()) {
                    push(@virtualVols, $nm->virtualVolumesByName($vvName));
                }

                if ( $self->testing() ) {
                    $logger->debug("DRYRUN: would remove snapshot copies for vvlist " . join(",", $filesystem->vvList()));
                } else {
                    unless ($nm->removeSnapCopyForVirtualVolumes(\@virtualVols, $self->fpcId())) {
                        $logger->error("Removing snapshot copies for vvlist " . join(",", $filesystem->vvList()) . " failed");
                        return;
                    }
                    $filesystem->remove();
                }
            }

            $peerConnection->remove();
        }
        $dbPeers->remove();
    }

    my @vluns = $self->vluns();
    for my $vlun (@vluns) {
        $vlun->remove();
    }
    # clean up the meta-data
    $self->deleteAttribute('vluns');

    return 1;
}

#FIXME
# this currently verifies that all target product schemas have a
# corresponding dumpfile in the dataset, but does not check if
# there are dataset schemas that do not have a corresponding product
# schema.
#
sub verifyBackupForProduct {
    my $self = shift;
    my $product = shift;

    unless ( $product ) {
        $logger->error("product must be defined to verify the backup");
        return;
    }

    if ( $self->isFpc() || $self->isThin() || $self->isHbaseExport() ) {
        $logger->error("Verify is not supported for snapshot based backups");
        return;
    }

    if( $self->hanaOnly() ) {
        $logger->info("Skipping verify, as hana-only export only has hana in it.");
        return 1;
    }

    my %dbTypeCheck;
    my @dbConnections = ariba::Ops::DBConnection->connectionsFromProducts($product);
    if ($product->name() eq "suppliermanagement" ){
        push @dbConnections,getSystemDBConnection('smsys',$product);
    }

    unless ( scalar @dbConnections ) {
        $logger->error("could not get db connections for product " . $product->name());
        return;
    }

    if ( $product->default('System.Base.RealmRootDir') && ! $self->realmRootDir() ) {
        $logger->warn("Dataset " . $self->instance . " is missing realm backup");
        return;
    }

    for my $dbc (@dbConnections) {
        next if $dbc->isDR();
        next if $dbc->isGeneric();
        my $match = 0;

        my $schemaId = $dbc->schemaId();
        my $type = $dbc->type();

        for my $dbExportId ( $self->getDBExportIds() ) {
            my $dsType = $self->schemaType($dbExportId);
            my $dsSchemaId = $self->schemaId($dbExportId);
            my $dsStatus = $self->backupStatus($dbExportId);

            if ( ( $dsType eq $type ) && ( $dsSchemaId eq $schemaId ) && ( $dsStatus eq $DS_STATUS_SUCCESSFUL ) )
            {
                $logger->debug("$type schema $schemaId ("
                    .join('', $dbc->user(), '/', $dbc->sid(), '@', $dbc->host())
                    .") matches dataset $dsType schema $dsSchemaId with status $dsStatus");

                $match = 1;
                last;
            }
        }

        unless ($match) {
            $logger->warn("Dataset " . $self->instance() . " is missing schema type: '$type', id: '$schemaId'");
            return;
        }

    }

    return 1;
}

sub backupRealmsMCL {
    my $self = shift;
    my $product = shift;
    my $ret = "";
    my @hosts = nonSeleniumAppServersForProduct($product);

    my $realmRootDir = $product->default('System.Base.RealmRootDir');
    return($ret) unless($realmRootDir);
    my $realmRootDirParent = dirname($realmRootDir);
    my $realmsArchiveDir = ariba::Ops::Constants->archiveManagerArchiveDir() . "/" . $self->instance();

    my $USER = "svc" . $product->service();

    $ret .= "Step Realm\n";
    $ret .= "Title: Backup Realms\n";
    $ret .= "Options: expando\n\n";

    $ret .= "Group: realmBackupGroup {\n";
    $ret .= "\tMaxParallelProcesses: 5\n";
    $ret .= "}\n\n";

    $ret .= "Step R0\n";
    $ret .= "Title: Mark Realm Backup Started\n";
    $ret .= "Options: optional\n" unless($self->startOptional() || $product->default('Ops.useInstantRealmRestore'));
    $ret .= "Expando: Realm\n";
    $ret .= "Action: Perl {\n";
    $ret .= "\tDatasetManager::markRealmsBackupInProgress(" . $self->instance() . ",'$realmRootDir')\n";
    $ret .= "}\n\n";

    if ( $product->default('Ops.useInstantRealmRestore') ){
        my $hostsStr = join( ' ', @hosts );
        my $subret .= $self->backupRealmsInstantMCL( $product, $hostsStr );
        if ( $subret eq '' ){
            return '';
        } else {
            $ret .= $subret;
        }
    } else {
        my $substep = 1;
        while (my $chunks = $self->getRealmListForChunk($substep, $realmRootDir)) {
            my $tarFile = $realmsArchiveDir . "/realmBackup-${substep}.tgz";
            my $host = $hosts[ $substep % scalar(@hosts) ];
            my $cmd = tarCmd() . " zcf $tarFile -C $realmRootDirParent $chunks";
            $ret .= "Step R$substep\n";
            $ret .= "Title: Backup " . basename($tarFile) . "\n";
            $ret .= "Options: optional\n" unless($self->startOptional());
            $ret .= "Expando: Realm\n";
            $ret .= "Depends: R0\n";
            $ret .= "RunGroup: realmBackupGroup\n";

            #
            # XXX -- tar to local file system, and then move?
            #
            $ret .= "Action: Shell $USER\@$host {\n";
            $ret .= "\t\$ $cmd\n";
            $ret .= "}\n\n";

            $substep++;
        }
        return("") unless($substep > 1);
    }

    $ret .= "Step REnd\n";
    $ret .= "Title: Mark Realm Backup Successful\n";
    $ret .= "Options: optional\n" unless($self->startOptional() || $product->default('Ops.useInstantRealmRestore'));
    $ret .= "Expando: Realm\n";
    $ret .= "Depends: group:realmBackupGroup\n";
    $ret .= "Action: Perl {\n";
    $ret .= "\tDatasetManager::markRealmsBackupComplete(" . $self->instance() . ")\n";
    $ret .= "}\n\n";

    return($ret);
}

sub backupRealmsInstantMCL {
    my $self     = shift;
    my $product  = shift || die __PACKAGE__ . "::backupRealmsInstantMCL(): InstalledProduct is a mandatory argument!\n";
    my $hostsStr = shift || die __PACKAGE__ . "::backupRealmsInstantMCL(): Hosts String is a mandatory argument!\n";

    my $ret = '';

    my $realmRootDir = $product->default('System.Base.RealmRootDir');
    return($ret) unless($realmRootDir);
    my $realmRootDirParent = dirname($realmRootDir);
    my $realmsArchiveDir = ariba::Ops::Constants->archiveManagerArchiveDir() . "/" . $self->instance();

    $self->setIsInstantRealm(1);

    ## Get/compose some needed values:
    my $fsNum      = 0;
    my $dsId       = $self->instance();
    my $service    = $product->service();

    #
    ## Hard coding the dedicated NFS host -- be better if this were
    ## machinedb, but no distinct match (yet).
    ##
    ## CAREFUL -- for the 3par ops, this needs to NOT be fully qualified
    #
    my $nfsHost    = 'jellyfish.lab1';
    my $inservHost = $self->inserv();
    my $prodName   = $product->name();
    my $fs         = "$prodName-$service-realms";

    my ( $infoRef, @fsInfo );

    my $command =  "sudo /usr/local/ariba/bin/filesystem-device-details -x /$fs";
    ( $infoRef, @fsInfo ) = ariba::Ops::FileSystemUtilsRPC->newListOfVVInfoWithCommand( $command, $nfsHost, $service, undef, undef, undef );

#    use Data::Dumper;
#    print "=================================================================\n";
#    print "FS Info for '$sid' ('$fs'):\n";
#    print Dumper \@fsInfo;
#    print "=================================================================\n";
#    print Dumper \@fsInfo;
#    print "=================================================================\n";
#    print Dumper $infoRef;
#    print "=================================================================\n";
        
    my $lun = $infoRef->{ "/$fs" }->[0]->{ 'LUN' };
    unless ( defined $lun ) {
        die "Could not read LUN info!!\n";
    }

    #
    # oldVV should come from the fsInfo array
    #
    my $oldvv = ($fsInfo[0]->vvList())[0];

    my $newvv = "$service-$prodName-$dsId-realm-$fsNum";
    my $newrovv = "scro-$dsId-realm-$fsNum";
    my $newrwvv = "scrw-$dsId-realm-$fsNum";

    $ret .= <<EOT;
## BEGIN: MCL generated by ariba::Ops::DatasetManager->backupRealmsInstantMCL()

Variable: apphosts=$hostsStr
Variable: nfshost=$nfsHost
Variable: fs=$prodName-$service-realms
Variable: dg=$prodName-$service-rlmdg
Variable: lun=$lun
Variable: parHost=$inservHost
Variable: newvv=$newvv
Variable: oldvv=$oldvv
Variable: newrovv=$newrovv
Variable: newrwvv=$newrwvv

EOT

    my $step = 1; ## We're being squeezed between existing steps, this is starting at step 1

    $ret .= <<EOT;
Group: umountGrp {
}

#
# these should be unmounted by the app shutdown, but let's be paranoid
#
# The 'R' in the step names is reflective of 'Realm'
#
Step R$step
Title: umount \${fs}
Loop: host=\${apphosts}
RunGroup: umountGrp
Expando: Realm
Action: Shell mon\${SERVICE}@\${host} {
    \$ sudo umount -f /\${fs}
    SuccessIf: not\\smounted
}
EOT
    $step++;

    $ret .= <<EOT;
Step R$step
Title: umount \${fs} (\${nfshost})
Depends: group:umountGrp
Expando: Realm
Action: Shell mon\${SERVICE}@\${nfshost} {
    \$ sudo /etc/init.d/nfs restart
    \$ sudo umount -f /\${fs}
    SuccessIf: not\\smounted
}
EOT
    my $prevStep = $step;
    $step++;

    $ret .= <<EOT;

Step R$step
Title: offline \${dg} (\${nfshost})
Depends: R$prevStep
Expando: Realm
Action: Shell mon\${SERVICE}@\${nfshost} {
    \$ sudo /usr/local/ariba/bin/filesystem-utility offlineremove -g \${dg}
}
EOT
    $prevStep = $step;
    $step++;

    $ret .= <<EOT;

Step R$step
Title: remove OS LUNs (\${nfshost})
Depends: R$prevStep
Expando: Realm
Action: Shell mon\${SERVICE}@\${nfshost} {
    \$ sudo /usr/local/ariba/bin/filesystem-utility removeluns -l \${lun}
}
EOT
    $prevStep = $step;
    $step++;

    $ret .= <<EOT;

Step R$step
Title: Backup \${vv}
Depends: R$prevStep
RunGroup: 3par
Expando: Realm
Action: NetworkDevice \${parHost} {
    \$ removevlun -f \${oldvv} \${lun} \${nfshost}
    \$ showvlun -host \${nfshost} -l \${lun}
    ErrorString: \${oldvv}
    \$ setvv -name \${newrwvv} \${oldvv}
    \$ creategroupsv -ro \${newrwvv}:\${newrovv}
    \$ creategroupsv \${newrovv}:\${newvv}
    \$ createvlun -f \${newvv} \${lun} \${nfshost}

    \$ showvlun -host \${nfshost} -l \${lun}
    SuccessString: \${newvv}
}
EOT
    $prevStep = $step;
    $step++;

    $ret .= <<EOT;

Step R$step
Title: online \${dg} (\${nfshost})
Depends: R$prevStep
RunGroup: scsiRescan
Expando: Realm
Action: Shell mon\${SERVICE}@\${nfshost} {
    \$ sudo /usr/local/ariba/bin/filesystem-utility scanonline -g \${dg}
}
EOT
    $prevStep = $step;
    $step++;

    $ret .= <<EOT;

Step R$step
Title: mount \${fs} (\${nfshost})
Depends: R$prevStep
Expando: Realm
Action: Shell mon\${SERVICE}@\${nfshost} {
    \$ sudo mount -t vxfs /dev/vx/dsk/\${dg}/\${fs} /\${fs}
    \$ sudo /etc/init.d/nfs restart
}
EOT
    $prevStep = $step;
    $step++;

    $ret .= <<EOT;

Step R$step
RunGroup: realmBackupGroup
Title: mount \${fs}
Loop: host=\${apphosts}
Depends: R$prevStep
Expando: Realm
Action: Shell mon\${SERVICE}@\${host} {
    \$ sudo mount -t nfs \${nfshost}:/\${fs} /\${fs}
}

## END: MCL generated by ariba::Ops::DatasetManager->backupRealmsInstantMCL()

EOT

    return $ret;
}

sub restoreRealmsMCL {
    my $self = shift;
    my $product = shift;
    my $ret = "";
    my @hosts = nonSeleniumAppServersForProduct($product);

    my $realmRootDir = $product->default('System.Base.RealmRootDir');
    return($ret) unless($realmRootDir);
    my $realmRootDirParent = dirname($realmRootDir);

    my $USER = "svc" . $product->service();
    my $localhost = ariba::Ops::NetworkUtils::hostname();

    my @realmsFiles = $self->archivedRealmsBackupFiles();

    $ret .= "Step Realm\n";
    $ret .= "Title: Restore Realms\n";
    $ret .= "Options: expando\n\n";

    $ret .= "Group: realmsRestoreGroup {\n";
    $ret .= "\tMaxParallelProcesses: 5\n";
    $ret .= "}\n\n";

    if ( $product->default('Ops.useInstantRealmRestore') ){
        my $hostsStr = join( ' ', @hosts );
        my $subret .= $self->restoreRealmsInstantMCL( $product, $hostsStr );
        if ( $subret eq '' ){
            return '';
        } else {
            $ret .= $subret;
        }
    } else {
        my $substep = 1;

        $ret .= "Step R0a\n";
        $ret .= "Title: Rename Existing Realms Dir\n";
        $ret .= "Options: optional\n" unless($self->startOptional());
        $ret .= "Expando: Realm\n";
        $ret .= "Action: Shell $USER\@$localhost {\n";
        $ret .= "\t\$ /bin/mv $realmRootDir ${realmRootDir}.trash.$$\n";
        $ret .= "}\n\n";
        $ret .= "Step R0b\n";
        $ret .= "Title: Remove Existing Realms Dir\n";
        $ret .= "Options: optional\n" unless($self->startOptional());
        $ret .= "Depends: R0a\n";
        $ret .= "Expando: Realm\n";
        $ret .= "RunGroup: realmsRestoreGroup\n";
        $ret .= "Action: Shell $USER\@$localhost {\n";
        $ret .= "\t\$ /bin/chmod -R u+w ${realmRootDir}.trash.$$\n";
        $ret .= "\t\$ /bin/rm -rf ${realmRootDir}.trash.$$\n";
        $ret .= "}\n\n";

        foreach my $tarFile (@realmsFiles) {
            my $host = $hosts[ $substep % scalar(@hosts) ];
            my $cmd = tarCmd() . " zxf $tarFile -C $realmRootDirParent";
            $ret .= "Step R$substep\n";
            $ret .= "Title: Restore " . basename($tarFile) . "\n";
            $ret .= "Options: optional\n" unless($self->startOptional());
            $ret .= "Depends: R0a\n";
            $ret .= "Expando: Realm\n";
            $ret .= "RunGroup: realmsRestoreGroup\n";

            #
            # XXX -- tar to local file system, and then move?
            #
            $ret .= "Action: Shell $USER\@$host {\n";
            $ret .= "\t\$ $cmd\n";
            $ret .= "}\n\n";

            $substep++;
        }
        return("") unless($substep > 1);
    }

    $ret .= "Step REnd\n";
    $ret .= "Title: Mark Realm Restore Successful\n";
    $ret .= "Options: optional\n" unless($self->startOptional() || $product->default('Ops.useInstantRealmRestore'));
    $ret .= "Depends: group:realmsRestoreGroup\n";
    $ret .= "Expando: Realm\n";
    $ret .= "Action: Shell {\n";
    $ret .= "\t\$ echo 'All Realms Steps are Complete.'\n";
    $ret .= "}\n\n";

    return($ret);
}

sub restoreRealmsInstantMCL {
    my $self     = shift;
    my $product  = shift || die __PACKAGE__ . "::restoreRealmsInstantMCL(): InstalledProduct is a mandatory argument!\n";
    my $hostsStr = shift || die __PACKAGE__ . "::restoreRealmsInstantMCL(): Hosts String is a mandatory argument!\n";

    my $ret = '';

    my $realmRootDir = $product->default('System.Base.RealmRootDir');
    return($ret) unless($realmRootDir);
    my $realmRootDirParent = dirname($realmRootDir);
    my $realmsArchiveDir = ariba::Ops::Constants->archiveManagerArchiveDir() . "/" . $self->instance();

    ## Get/compose some needed values:
    my $fsNum      = 0;
    my $dsId       = $self->instance();
    my $service    = $product->service();

    #
    ## Hard coding the dedicated NFS host -- be better if this were
    ## machinedb, but no distinct match (yet).
    ##
    ## CAREFUL -- for the 3par ops, this needs to NOT be fully qualified
    #
    my $nfsHost    = 'jellyfish.lab1'; ## Hard coding the dedicated NFS host

    my $inservHost = $self->inserv();
    my $prodName   = $product->name();
    my $fs         = "$prodName-$service-realms";

    my ( $infoRef, @fsInfo );

    my $command =  "sudo /usr/local/ariba/bin/filesystem-device-details -x /$fs";
    ( $infoRef, @fsInfo ) = ariba::Ops::FileSystemUtilsRPC->newListOfVVInfoWithCommand( $command, $nfsHost, $service, undef, undef, undef );

#    use Data::Dumper;
#    print "=================================================================\n";
#    print "FS Info for '$sid' ('$fs'):\n";
#    print Dumper \@fsInfo;
#    print "=================================================================\n";
#    print Dumper \@fsInfo;
#    print "=================================================================\n";
#    print Dumper $infoRef;
#    print "=================================================================\n";
        
    my $lun = $infoRef->{ "/$fs" }->[0]->{ 'LUN' };
    unless ( defined $lun ) {
        die "Could not read LUN info!!\n";
    }

    my $oldDsId = $infoRef->{ "/$fs" }->[0]->{ 'VV' };
    unless ( defined $oldDsId ) {
        die "Could not read existing dataset ID!!\n";
    }
    $oldDsId =~ s/.*-(\d+)-.*/$1/;

    #
    # oldVV should come from the fsInfo array
    #
    my $oldvv = ($fsInfo[0]->vvList())[0];

    my $newvv = "$service-$prodName-$dsId-realm-$fsNum";
    my $newrovv = "scro-$dsId-realm-$fsNum";

    $ret .= <<EOT;
## BEGIN: MCL generated by ariba::Ops::DatasetManager->restoreRealmsInstantMCL()

Variable: apphosts=$hostsStr
Variable: nfshost=$nfsHost
Variable: fs=$fs
Variable: dg=$prodName-$service-rlmdg
Variable: lun=$lun
Variable: parHost=$inservHost
Variable: newvv=$newvv
Variable: oldvv=$oldvv
Variable: newrovv=$newrovv

EOT

    my $step = 1; ## We're being squeezed between existing steps, this is starting at step 1

    $ret .= <<EOT;
Group: umountGrp {
}

#
# these should be unmounted by the app shutdown, but let's be paranoid
#
Step R$step
Title: umount \${fs}
Loop: host=\${apphosts}
RunGroup: umountGrp
Expando: Realm
Action: Shell mon\${SERVICE}@\${host} {
    \$ sudo umount -f /\${fs}
    SuccessIf: not\\smounted
}
EOT
    $step++;

    $ret .= <<EOT;
Step R$step
Title: umount \${fs} (\${nfshost})
Depends: group:umountGrp
Expando: Realm
Action: Shell mon\${SERVICE}@\${nfshost} {
    \$ sudo /etc/init.d/nfs restart
    \$ sudo umount -f /\${fs}
    SuccessIf: not\\smounted
}
EOT
    my $prevStep = $step;
    $step++;

    $ret .= <<EOT;

Step R$step
Title: offline \${dg} (\${nfshost})
Depends: R$prevStep
Expando: Realm
Action: Shell mon\${SERVICE}@\${nfshost} {
    \$ sudo /usr/local/ariba/bin/filesystem-utility offlineremove -g \${dg}
}
EOT
    $prevStep = $step;
    $step++;

    $ret .= <<EOT;

Step R$step
Title: remove OS LUNs (\${nfshost})
Depends: R$prevStep
Expando: Realm
Action: Shell mon\${SERVICE}@\${nfshost} {
    \$ sudo /usr/local/ariba/bin/filesystem-utility removeluns -l \${lun}
}
EOT
    $prevStep = $step;
    $step++;

    $ret .= <<EOT;

Step R$step
Title: Restore \${newvv}
Depends: R$prevStep
RunGroup: 3par
Expando: Realm
Action: NetworkDevice \${parHost} {
    \$ removevlun -f \${oldvv} \${lun} \${nfshost}
    \$ showvlun -host \${nfshost} -l \${lun}
    ErrorString: \${oldvv}
    \$ removevv -f \${oldvv}
    \$ creategroupsv \${newrovv}:\${newvv}
    \$ createvlun -f \${newvv} \${lun} \${nfshost}
    \$ showvlun -host \${nfshost} -l \${lun}
    SuccessString: \${newvv}
}
EOT
    $prevStep = $step;
    $step++;

    $ret .= <<EOT;

Step R$step
Title: online \${dg} (\${nfshost})
Depends: R$prevStep
RunGroup: scsiRescan
Expando: Realm
Action: Shell mon\${SERVICE}@\${nfshost} {
    \$ sudo /usr/local/ariba/bin/filesystem-utility scanonline -g \${dg}
}
EOT
    $prevStep = $step;
    $step++;

    $ret .= <<EOT;

Step R$step
Title: mount \${fs} (\${nfshost})
Depends: R$prevStep
Expando: Realm
Action: Shell mon\${SERVICE}@\${nfshost} {
    \$ sudo mount -t vxfs /dev/vx/dsk/\${dg}/\${fs} /\${fs}
    \$ sudo /etc/init.d/nfs restart
}
EOT
    $prevStep = $step;
    $step++;

    $ret .= <<EOT;

Step R$step
Title: mount \${fs}
RunGroup: realmsRestoreGroup
Loop: host=\${apphosts}
Depends: R$prevStep
Expando: Realm
Action: Shell mon\${SERVICE}@\${host} {
    \$ sudo mount -t nfs \${nfshost}:/\${fs} /\${fs}
}

## END: MCL generated by ariba::Ops::DatasetManager->restoreRealmsInstantMCL()

EOT

    return $ret;
}

sub restoreRealmDirFromProduct {
    my $self = shift;
    my $product = shift;

    # FIXME: need to add product/buildname checking before kicking off restore.

    my $realmRootDir = $product->default('System.Base.RealmRootDir');

    return 1 unless $realmRootDir;

    $logger->info("Restoring Realm Root Dir: $realmRootDir");

    if ( $self->restoreRealmDir($realmRootDir) ) {
        $self->setRealmBackupfile(1);
        return 1;
    } else {
        return;
    }
}

sub restoreRealmDir {
    my $self = shift;
    my $realmRootDir = shift;

    my $realmRootDirParent = dirname($realmRootDir);

    my @realmsFiles = $self->archivedRealmsBackupFiles();

    $logger->info("Removing $realmRootDir" );
    if (-d $realmRootDir) {
        $logger->debug("Cleaning realms at $realmRootDir ...");

        if ($self->testing()) {
            $logger->debug("DRYRUN: would recursively delete $realmRootDir");
        } else {
            unless (ariba::rc::Utils::rmdirRecursively($realmRootDir)) {
                $logger->error("failed to remove $realmRootDir: $@");
                return;
            }
        }
    }

    foreach my $realmsZipFile (@realmsFiles) {
        $logger->info("Restoring RealmsRoot $realmRootDir from $realmsZipFile");

        if ($self->testing()) {
            $logger->debug("DRYRUN: would create path $realmRootDirParent");
        } else {
            unless (ariba::rc::Utils::mkdirRecursively($realmRootDirParent)) {
                $logger->error("Failed to create realmRootDirParent");
                return;
            }
        }

        my $untarCmd = tarCmd() . " zxf $realmsZipFile -C $realmRootDirParent";
        if ($self->testing()) {
            $logger->debug("DRYRUN: would restore realms via '$untarCmd'");
        } else {
            system($untarCmd) == 0 or do {
                my $error = $?;
                $logger->error("Failed to restore $realmRootDir");
                $logger->error("$untarCmd returned " . ($error >> 8));
                return;
            };

            $logger->info("Restored realms via '$untarCmd'");
        }

        $logger->info("Successfully restored realm root dir: $realmRootDir");
    }

    return 1;
}

sub restoreDBFromProduct {
    my $self = shift;
    my $product = shift;
    my $dbExportId = shift;
    my $schemaId = shift;
    my $archesService = shift;
    my $archesAdapter = shift;
    my $cdh5;
    if($product->name() =~/arches/i && $product->default('isCDH5')){
    
        $cdh5 = 1;
        $self->setbackupType('hbase');
    }

    if ( $self->isFpc()) {
        return unless $self->restoreFPC($product);
    } elsif ( $self->isThin() ) {
        return($self->restoreThin($product));
    } elsif ( $self->isHbaseExport() ) {
        if($cdh5){
            return($self->restoreHbaseFromProduct_cdh5($product, $archesService, $archesAdapter));
        }
        else {
            return($self->restoreHbaseFromProduct($product, $archesService, $archesAdapter));
        }
    } else {
        unless ($self->verifyBackupForProduct($product)) {
            $logger->error("Selected backup does not match all type and schema ids");
            return;
        }

        if (defined $dbExportId) {
            # here we restore a simple schema
            return unless $self->restoreDBSchemaFromProduct($product, $dbExportId, $schemaId);
        } else {
            my @dbExportIds = $self->getDBExportIds();
            my $error = $self->restoreDBSchemasFromProduct($product, \@dbExportIds);
            if ($error) {
                return;
            }
        }
    }

    return 1;
}

#
# We delete the Arches shards dirs before running intidb.  After the init is run
# a fresh series of shard files is created.  This can run the disk out of space.
#
sub cleanupArchesShards {
    my $self = shift;
    my $product = shift;

    my $service = $product->service();
    my $unixUser = $product->deploymentUser();
    my $password = ariba::rc::Passwords::lookup($unixUser);

    if (my $dirlist = $product->default('Arches.ShardRoot')) {

        # $dirlist is a comma separated list.  First create an array element for each line.
        # Then create an 'rm' command for each.  
        my @dirs = split /,/, $dirlist;

        my $commands = '';
        foreach my $dir (@dirs) {
            next unless $dir =~ /\/var\/data/;
            # trim trailing white space to avoid 'rm /dir /*'
            $dir =~ s/\s+$//;     # trim trailing white space to avoid 'rm /dir /*'
            $commands .= "rm -rf $dir/*;";
        }

        unless($commands) {
            debugmsg("(no dirs found to purge)\n");
            return 1;
        }

        $commands = "'" . $commands . "'";

        # Get the list of hosts on which we need to run the 'delete' commands.
        my @hosts = ($product->hostsForRoleInCluster('searchcore', 'primary'));

        # Loop over each host and run the 'delete' commands.  We could fork this
        # and run the deletes in parallel.  If speed becomes an issue we can make
        # this a future enhancement.
        foreach my $host (@hosts) {
            my $cmd = "ssh -l svc$service $host $commands"; 
            ariba::rc::Utils::executeRemoteCommand($cmd, $password);
        }
    }
    return 1;  #success
}

sub restoreHbaseFromProduct {
    my $self = shift;
    my $product = shift;
    my $toTenant = shift;
    my $toAdapter = shift;

    my $productName = $product->name();
    my $serviceArches = $product->service();

    my $aribaArchesConfig = $product->installDir() . "/config/ariba.arches.user.config.cfg";
    my $rootTable = ariba::Ops::Utils::getParamsFromAlternateConfig($aribaArchesConfig, 'ariba.hadoop.tenant.prefix');
    my $hadoopTenant = ariba::Ops::Utils::getParamsFromAlternateConfig($aribaArchesConfig, 'ariba.hadoop.tenant.actas');
    my $serviceHadoop = $hadoopTenant;

    unless ($rootTable) {
        $logger->error("Arches ariba.hadoop.tenant.prefix value is not set.");
        return;
    }

    unless ($serviceHadoop) {
        $logger->error("Arches ariba.hadoop.tenant.actas value is not set.");
        return;
    }

    ## TO-DO engr has a change to add a new paramter for hadoop service so we don't have to parse this
    $serviceHadoop =~ s/^svc//;

    my $hadoop = ariba::rc::InstalledProduct->new("hadoop", $serviceHadoop) if ($productName eq "arches");
    my $host = ($hadoop->rolesManager()->hostsForRoleInCluster('hbase-master', $hadoop->currentCluster()))[0];
    my $javaHome = $ENV{'JAVA_HOME'} = ariba::Ops::Startup::Common::javaHomeForProduct($hadoop);
    my $installDir = $hadoop->installDir();
    my $installDirArches = $product->installDir();
    my $mrDir = $installDir . "/hadoop/share/hadoop/mapreduce1";
    my $hadoopHome = $installDir . "/hadoop";
    my $hbaseHome = $installDir . "/hbase";
    my $hadoopConfDir = $hadoopHome . "/conf";
    my $svcUser = "svc$serviceHadoop";
    my $svcUserArches = "svc$serviceArches";
    my $cmd = "ssh $svcUser\@$host -x 'bash -c \"export JAVA_HOME=$javaHome; export HADOOP_HOME=$mrDir; export HADOOP_CONF_DIR=$hadoopConfDir";
    my $dsid = $self->instance();
    my $exportDir = "/export/restore/$dsid/$rootTable";
    my $fromTenant = $self->fromTenant();
    my $fromAdapter = $self->fromAdapter();

    ## remove this 'if' block once anrc changes have been made to support this feature
    if (!defined $toTenant) {
        $toTenant = $fromTenant;
    }
    
    if (!defined $toAdapter) {
        $toAdapter = $fromAdapter;
    }

    #
    # Check if file repository/usr/ariba.arches.user.config.properties exists as it is
    # requried for initdb. If not, then exit
    #
    my $propertiesFile = $installDirArches . "/repository/usr/ariba.arches.user.config.properties";
    unless (-e $propertiesFile) {
        $logger->info("$propertiesFile does not exist, attempting to create it");

        my $indexMgrApp = (grep { $_->appName() eq 'IndexMgr' } $product->appInstancesInCluster($product->currentCluster()))[0];
        my $indexAppName = $indexMgrApp->instanceName();
        my $indexHost = $indexMgrApp->host();
        my $startCmd = "ssh $svcUserArches\@$indexHost $installDirArches/bin/startup $indexAppName";
        my $stopCmd = "ssh $svcUserArches\@$indexHost $installDirArches/bin/stopsvc $indexAppName";
        my $svcUserPass = ariba::rc::Passwords::lookup($svcUserArches);
        my $masterPass = ariba::rc::Passwords::lookup('master');
        unless (ariba::rc::Utils::executeRemoteCommand($startCmd, $svcUserPass, 0, $masterPass, 120)) {
            $logger->error("Error in starting up $indexAppName");
            return 0;
        }
        unless (ariba::rc::Utils::executeRemoteCommand($stopCmd, $svcUserPass, 0, $masterPass, 120)) {
            $logger->error("Error in stopping $indexAppName");
            return 0;
        }

        unless (-e $propertiesFile) {
            $logger->error("$propertiesFile does not exist, unable to run initdb");
            return 0;
        }
    }

    my @archesIndexHosts = $product->hostsForRoleInCluster( 'indexmgr', $product->currentCluster() );
    my $archesHost = (@archesIndexHosts)[0];
    my $currentHost = ariba::Ops::NetworkUtils::hostname();

    # if adapter is not defined, simply run initdb, else only delete data for that adapter
    if (!defined $toAdapter) {
        #
        # Create tables by running initdb -all from current arches host
        #

        if ($productName eq 'arches') {
            $logger->info("Cleanning up shards dir before running initdb");
            unless (ariba::Ops::DatasetManager->cleanupArchesShards($product)) {
                return 0;  # bail if we get an error return
            }
        }

        $logger->info("Running initdb -all to create tables");
        my $cmdInitdb = "$installDirArches/bin/initdb -all";
        my @outputInitdb;

        ariba::rc::Passwords::initialize($serviceArches);

        #
        # If current host is a indexmgr arches host, then just run initdb directly
        # If current host is not a indexmgr arches host, then login to one and run it
        #
        if (grep {$_ eq $currentHost} @archesIndexHosts) {
            unless (ariba::Ops::Startup::Common::runCommandAndFeedMasterPassword($cmdInitdb, ariba::rc::Passwords::lookup('master'))) {
                $logger->error("Error running initdb on arches to disable, drop and recreate tables");
                return 0;
            }
        } else {
            my @output;
            my $cmdInitdbFull = "ssh $svcUserArches\@$archesHost -x 'bash -c \"export JAVA_HOME=$javaHome ; $cmdInitdb\"'";

            unless (ariba::rc::Utils::executeRemoteCommand($cmdInitdbFull, ariba::rc::Passwords::lookup($svcUserArches),
                   0, ariba::rc::Passwords::lookup('master'), 120, \@output)) {
                $logger->error("Error running initdb on arches to disable, drop and recreate tables");
                $logger->info(join("\n", @output));
                return 0;
            }
        }
    } else {
        my $indexMgrApp = (grep { $_->appName() eq 'IndexMgr' } $product->appInstancesInCluster($product->currentCluster()))[0];
        my $indexHost = $indexMgrApp->host();
        my $indexPort = $indexMgrApp->httpPort();
        my $url = "http://$indexHost:$indexPort/Arches/api/tenantinfo/secure/deletetenant";

        my $postBody = { adapter=>$toAdapter };

        my ($deleteTenantResult, $errorDeleteTenant) = post_Url($url,$postBody, 10800);
        
        $logger->info("Starting delete tenant via $url for adapter $toAdapter");
        
        unless (defined $deleteTenantResult) {
            $logger->error("No delete tenant result returned");
            return 0;
        }
        # todo, handle more error condition

        $logger->info("delete tenant by adapter result: $deleteTenantResult");
    }

    my $serviceDsid = $self->serviceName();
    #
    # root table name = /home/archmgr/archive/<dsid>/<root_tablename>.<tablename>
    # archiveDir: /home/archmgr/archive/$dsid/$serviceDsid
    #
    my $archiveDsidDir = ariba::Ops::Constants->archiveManagerArchiveDir() . "/$dsid";
    my $archiveDir = "$archiveDsidDir/$serviceDsid";
    mkdir($archiveDir) unless (-e $archiveDir);

    ## TO-DO: need to update to get rootTable name of dsid, for now we assume the rootTable name
    ## is the same as the dsid service
    my $tarFile = $archiveDir . "_" . $dsid . ".tgz";

    my $untarCmd = "ssh $svcUser\@$host -x 'bash -c \"" . tarCmd() . " zxf $tarFile -C $archiveDsidDir\"'";

    if ($self->testing()) {
        $logger->debug("DRYRUN: would decompress hbase tables via '$untarCmd'");
    } else {
        $logger->info("Preparing to decompress hbase tables under $archiveDir");

        my $untarOutput = $self->runHbaseCommand($untarCmd, $serviceHadoop, $svcUser);

        $logger->info("Done decompressing tables via '$untarCmd'");
        # We are troubleshooting issues where some of the HBase tables are not restored during restore-migrate.
        # We like to inspect the output of the untar command.
        $logger->info("Output of untar command is \n$untarOutput");
    }

    $logger->info("Copying dataset data from archive to hdfs (hadoop $serviceHadoop)");
    my $cmdCopy = "$cmd ; $hadoopHome/bin/hdfs dfs -rmr $exportDir ; $hadoopHome/bin/hdfs dfs -mkdir $exportDir ; $hadoopHome/bin/hdfs dfs -put $archiveDir $exportDir\"'";
    my $copyOutput = $self->runHbaseCommand($cmdCopy, $serviceHadoop, $svcUser);
    if (grep $_ =~ /File exists/, @{$copyOutput}) {                                                                                                                                                                                
        $logger->info("WARN: skipped copying export from hdfs to $archiveDir, 1 or more of the files already exist.");                                                                                                             
        return 0;
    }

    ## TO-DO add error checking here

    ## ls -l $archiveDir command returning junk and non-printable characters
    ## using find command as alternative
    my $tableListCmd = "ssh $svcUser\@$host -x 'find $archiveDir  -maxdepth 1 -mindepth 1 -printf \"%f\\n\"'";
    $logger->info("Preparing to get list of table files from $archiveDir");
    my $tablesDsid = $self->runHbaseCommand($tableListCmd, $serviceHadoop, $svcUser);
    $logger->info("List of tables in dataset, read from archive dir $archiveDir is: [ ".join(', ',@$tablesDsid)." ]");
    my @tablesSrc;
    my $rootTableSrc;

    foreach my $file (@$tablesDsid) {
        next if ($file =~ m/(^\.|^\s+$|\s+)/i);
        my @tableVals = $file =~ /^(.+?\.)(.+)/;
        $rootTableSrc = $tableVals[0];
        push(@tablesSrc, $tableVals[1]);
    }
    $rootTableSrc =~ s/\.//;
    my @cmdImport;

    $logger->info("Running import (restore) for arches tables $rootTable.* in $serviceArches");
    
    my $cmdModifyRowKey;
    my $runLocally = (grep {$_ eq $currentHost} @archesIndexHosts);
    $logger->info("Starting import of these HBase tables: [ ".join(', ', @tablesSrc)." ]");
    foreach my $table (@tablesSrc) {
        $logger->info("Running import (restore) for arches table $rootTable.$table");
        $cmdModifyRowKey = "$installDirArches/bin/modifyrowkey -fromTenant=$fromTenant -toTenant=$toTenant -tableName=$rootTable.$table -inputDir=$exportDir/$serviceDsid/$rootTableSrc.$table";
        if (defined $toAdapter) {
            $cmdModifyRowKey .= " -adapter=$toAdapter";
        }
        if ($runLocally) {
            my $ret = ariba::Ops::Startup::Common::runCommandAndFeedMasterPassword($cmdModifyRowKey, ariba::rc::Passwords::lookup('master'));
            if ($ret =~ /error/i) {
                $logger->error("Error running modifyrowkey to update arches data for buyer $toTenant");
                return 0;
            }
        }
        else {
            my $cmdModifyRowKeyFull = "ssh $svcUserArches\@$archesHost -x 'bash -c \"export JAVA_HOME=$javaHome ; $cmdModifyRowKey\"'";
            my @modifyRowKeyOutput;
            my $ret = ariba::rc::Utils::executeRemoteCommand($cmdModifyRowKeyFull, ariba::rc::Passwords::lookup($svcUserArches), 
                0, undef, undef, \@modifyRowKeyOutput);
            unless ( $ret ) {
                $logger->error("Error running modifyrowkey to update arches data for buyer $toTenant");
                $logger->info(join("\n", @modifyRowKeyOutput));
                return 0;
            }
        }    
    }

    ## TO-DO need to do some error checking here
    $logger->info("Done running import to $dsid");

    #
    # Cleaning up export on hdfs
    #
    $logger->info("Cleaning up exports from hdfs");
    my $cmdRmr = "$cmd ; $hadoopHome/bin/hdfs dfs -rmr $exportDir\"'";
    my $rmrOutput = $self->runHbaseCommand($cmdRmr, $serviceHadoop, $svcUser);

    #
    # Clean up uncompressed export on archive manager 
    #
    $logger->info("Cleanup uncompressed exports from archive manager");
    my $rmDirCmd = "ssh $svcUser\@$host -x 'bash -c \"rm -rf $archiveDir\"'";
    my $rmDirOutput = $self->runHbaseCommand($rmDirCmd, $serviceHadoop, $svcUser);

    return 1;
}

sub appServersForProduct {
    my $product = shift;
    my %hosts;

    my @hosts = ();
    my @appInstances = $product->appInstancesInCluster($product->currentCluster());
    foreach my $appInstance (@appInstances) {
        $hosts{$appInstance->host()} = 1;
    }

    return(sort(keys(%hosts)));
}

sub nonSeleniumAppServersForProduct {
    my $product = shift;

    my @hosts = grep { $_ !~ /^selenium/ } appServersForProduct($product);
    return(@hosts);
}

sub restoreDBSchemasFromProduct {
    my $self = shift;
    my $product = shift;
    my $dbExportIds = shift;
    my $schemaIds = shift;

    my $error;

    if ($self->maxParallelProcesses() > 1 && scalar(@$dbExportIds) > 1) {

        # Figure out unix username that the product runs as and
        # figure out the passwords i need for running my commands
        my $user = $product->deploymentUser();
        my $master = ariba::rc::Passwords::lookup('master');
        my $password = ariba::rc::Passwords::lookup($user);

        # Here we are preparing the parallel restore commands and starting them
        my @hosts = nonSeleniumAppServersForProduct($product);

        $logger->info("DB restore will use the following hosts: " . join(", ",@hosts));
        $logger->info("DB restore will use a maximum of " . $self->maxParallelProcesses() . " parallel processes");

        my $currentHost = ariba::Ops::NetworkUtils::hostname();
        ariba::Ops::ControlDeploymentHelper->setMaxParallelProcesses($self->maxParallelProcesses());
        ariba::Ops::ControlDeploymentHelper->setLoadBalancingEnabled();
        ariba::Ops::ControlDeploymentHelper->setAvailableHosts(@hosts);
        ariba::Ops::ControlDeploymentHelper->setLeastFavoriteHosts($currentHost);

        my $dsm = $FindBin::Bin . "/" . basename($0);
        unless( $dsm =~ /dataset-manager/) {
            $dsm = "/usr/local/ariba/bin/dataset-manager";
        }

        my $commandPrefix = "$dsm restoredb " . $self->instance();
        $commandPrefix .= " -product " . $product->name() . " -service " . $product->service() . " -build " . $product->buildName();
        if ($self->mapTablespace()) {
            $commandPrefix .= " -mapTablespace";
        }

        my $timeStarted = time();
        my @commands = ();

        for my $index (0 .. scalar(@$dbExportIds)-1) {

            my $dbExportId = @$dbExportIds[$index];

            my $command = $commandPrefix . " -dbexportid " . $dbExportId;
            if (defined $schemaIds && defined $$schemaIds[$index]) {
                $command .= " -schemaid " . $$schemaIds[$index];
            }

            $logger->info("Command for parallel restore: " . $command);

            my $logName = 'dataset-manager-' . $dbExportId;

            my $helper = ariba::Ops::ControlDeploymentHelper->newUsingProductServiceAndCustomer($product->name(), $product->service());
            # tell it want to run and have it queue up the command
            $helper->setTimeStarted($timeStarted);

            $helper->launchCommandsInBackgroundWithHostLoadbalancing({
                    action                        => "dataset-manager",     # action (used for managing logs)
                    user                          => $user,                 # which user to run as
                    host                          => $currentHost,          # will be ignored for multi-host balanced run
                    logName                       => $logName,              # log name
                    password                      => $password,             # user password
                    master                        => $master,               # master password, to feed to command
                    description                   => "Running dataset-manager (export id: " . $dbExportId . ")",    #simple description of the action
                    commandArray                  => [$command],            # command to run
                    replaceTokensInCommand        => 1,                     # whether to replace tokens in command string
            });
        }

        # wait for all of the commands to finish
        my $exitStatus = ariba::Ops::ControlDeploymentHelper->waitForBackgroundCommands();
        if ($exitStatus) {
            $logger->error("DB parallel restore returned a non-zero exit status: $exitStatus");
            $error = 1;
        }
        # errors? if so, collect them and show a summary of what happened
        my $numErrors = ariba::Ops::ControlDeploymentHelper->displayLogFilesNamesAnnotedWithErrors();
        if ($numErrors) {
            $logger->error("WARNING: Finished with $numErrors errors in the log(s)");
            $logger->error("Refer to log(s) marked with '**' for error(s).");
        }
    } else {
        for my $index (0 .. scalar(@$dbExportIds)-1) {
            my $dbExportId = $$dbExportIds[$index];
            unless ($self->restoreDBSchemaFromProduct($product, $dbExportId)) {
                $error = 1;
                last;
            }
        }
    }
    if ($error) {
        $logger->info("DB restore failed.");
    } else {
        $logger->info("DB restore succeeded.");
    }
    return $error;
}

sub restoreDBSchemaFromProduct {
    my $self = shift;
    my $product = shift;
    my $dbExportId = shift;
    my $schemaId = shift;

    $schemaId = $self->schemaId($dbExportId)
        unless defined $schemaId;

    my $targetDbc = ariba::Ops::DBConnection->connectionsForProductOfDBTypeAndSchemaId($product, $self->schemaType($dbExportId), $schemaId);
    unless ( $targetDbc ) {
        #
        # FIXME ???
        # Don't error out if the target does not have a schema
        # matcing one in the source dataset, just skip that one
        # in the source.  This change is here for now to handle
        # AN 48 deployments without the edi schema.  We may want
        # to make this a fatal error later.
        #
        $logger->warn("Could not build a DBConnection from type " .
                $self->schemaType($dbExportId) . " and schema id " . $schemaId . ", skipping this one");
        return 1;
    }

    my $sid = $targetDbc->sid();
    my $schemaName = $targetDbc->user();
    my $password = $targetDbc->password();
    my $host = $targetDbc->host();

    return $self->restoreDBSchema($dbExportId, $sid, $schemaName, $password, $host, $product, $targetDbc);

}

sub productIsBootstrapCompatible {
    my $product = shift;

    #
    # to be compatible with this function, each 3par VV must:
    #
    # 1) not be a copy of anything
    # 2) be named by SA convention of XXXX-Y where Y is a disk number in
    #    a disk group.
    #

    my @peersFromProduct = ariba::Ops::DatabasePeers->newListFromProduct(
        $product,
        {
            'populateFsInfo' => 1,
        }
    );
    unless(@peersFromProduct) {
        $logger->error("Cannot get database peers.\n");
        return(0);
    }

    foreach my $peer (@peersFromProduct) {
        foreach my $peerConn ($peer->primary(), $peer->secondary()) {
            next unless($peerConn);
            foreach my $filesystem ($peerConn->dbFsInfo()) {
                my $inservHostname = $filesystem->inserv();
                my $machine = ariba::Ops::Machine->new($inservHostname);
                my $nm = ariba::Ops::NetworkDeviceManager->newFromMachine($machine, ariba::Ops::DatasetManager->shouldProxy());

                my @vvList = $filesystem->vvList();
                foreach my $vv (@vvList) {
                    unless($vv =~ /-\d+$/) {
                        return(0);
                    }
                    my ( $obj ) = $nm->cmdShowvv( $vv );
                    if($obj->copyOf() && $obj->copyOf() ne '---') {
                        return(0);
                    }
                }
            }
        }
    }
    return(1);
}

sub productIsUsingThinDataVolumes {
    my $product = shift;
    my @skip = (@_);

    my @peersFromProduct = ariba::Ops::DatabasePeers->newListFromProduct(
        $product,
        {
            'populateFsInfo' => 1,
            'skipTypes' => @skip,
        }
    );
    unless(@peersFromProduct) {
        $logger->error("Cannot get database peers.\n");
        return(undef);
    }

    foreach my $peer (@peersFromProduct) {
        foreach my $peerConn ($peer->allPeerConnections()) {
            next unless($peerConn);
            foreach my $filesystem ($peerConn->dbFsInfo()) {
                next if($filesystem->fs() =~ /log/);
                my $inservHostname = $filesystem->inserv();
                my $machine = ariba::Ops::Machine->new($inservHostname);
                my $nm = ariba::Ops::NetworkDeviceManager->newFromMachine($machine, ariba::Ops::DatasetManager->shouldProxy());

                my @vvList = $filesystem->vvList();
                foreach my $vv (@vvList) {
                    my ($sidId, $diskId, $oldDS) = sidDiskAndDatasetIdForVVName($vv);
                    unless(defined($sidId) && defined($diskId) && defined($oldDS)) {
                            return(0);
                    }
                }
            }
        }
    }

    return(1);
}

sub removeThinSnapshots {
    my $self = shift;

    unless($self->isThin()) {
        $logger->error("removeThinSnapshots called for non-thin dataset!");
        return(0);
    }


    my $inserv = $self->inserv();
    my $machine = ariba::Ops::Machine->new($inserv);
    my $nm = ariba::Ops::NetworkDeviceManager->newFromMachine($machine, $self->shouldProxy());

    unless($nm) {
        $logger->error("Unable to attach to 3par.");
        return(0);
    }

    if($self->hasChildrenDatasets($nm)) {
        my $id = $self->instance();
        $logger->error("Cannot delete dataset $id because other thin datasets are based on it.");
        return(0);
    }

    my $top = $self->getTopologyOfDataset($nm);

    foreach my $sid (sort keys %{$top->{'readOnlyExports'}}) {
        foreach my $disk (sort keys %{$top->{'readOnlyExports'}->{$sid}}) {
            my $vv = $top->{'readOnlyExports'}->{$sid}->{$disk};
            $logger->info("Issuing removevv $vv");
            unless( $nm->removeVV($vv) ) {
                $logger->error("Failed to remove $vv");
                return(0);
            }
        }
    }
    foreach my $sid (sort keys %{$top->{'baseVVs'}}) {
        foreach my $disk (sort keys %{$top->{'baseVVs'}->{$sid}}) {
            my $vv = $top->{'baseVVs'}->{$sid}->{$disk};
            my $isDr = 0;
            $isDr = 1 if($sid =~ s/-DR$//);
            if($self->baseVVNameForSidAndDisk($sid, $disk, $isDr) ne $vv &&
               $self->baseSnapshotNameForSidAndDisk($sid, $disk, $isDr) ne $vv
            ) {
                $logger->info("Skipping $vv (not a DSM volume)...");
                next;
            }
            $logger->info("Issuing removevv $vv");
            unless( $nm->removeVV($vv) ) {
                $logger->error("Failed to remove $vv");
                return(0);
            }
        }
    }
    foreach my $sid (sort keys %{$top->{'baseRO'}}) {
        foreach my $disk (sort keys %{$top->{'baseRO'}->{$sid}}) {
            my $vv = $top->{'baseRO'}->{$sid}->{$disk};
            $logger->info("Issuing removevv $vv");
            unless( $nm->removeVV($vv) ) {
                $logger->error("Failed to remove $vv");
                return(0);
            }
        }
    }

    return(1);
}

sub hasChildrenDatasets {
    my $self = shift;
    my $nm = shift;

    my $tree = getDatasetTree($nm);
    if($tree->{$self->instance()}->{'children'}) {
        return(1);
    }

    if($tree->{$self->instance()}->{'restoredTo'}) {
        return(1);
    }

    return(0);
}

#
# This relies on the metadata in the datasets -- we don't rely on it for real
# operations, but for show without logging into the inserv, it works.
#
sub getDatasetTreeFast {
    my $ret;
    my @datasets = ariba::Ops::DatasetManager->listObjects();

    foreach my $ds (@datasets) {
        next unless($ds->isThin());
        my $id = $ds->instance();
        my $parent = $ds->parentDataset();
        next unless($parent);
        $ret->{$id}->{'parent'} = $parent;
        $ret->{$parent}->{'children'}->{$id} = 1;
    }

    return($ret);
}

sub getDatasetTree {
    my $nm = shift;
    my %baseVVs;
    my %baseROs;
    my %roEXPs;
    my %vvHash;
    my $ret;

    #
    # lookup the ro exports to get map the base volumes to datasetId
    #
    my ( @vvs ) = $nm->cmdShowvv();

    foreach my $vv (@vvs) {
        $vvHash{$vv->name()} = $vv;
    }

    foreach my $vv (@vvs) {
        my $vvname = $vv->name();
        if($vvname =~ /^([a-z0-9]+)-([a-z0-9]+)-DS(\d\d\d\d\d)-(?:DR)?\d\d-\d+$/) {
            my $service = $1;
            my $prodname = $2;
            my $ds = $3;
            $ds=~s/^0+//;
            $ret->{$ds}->{'restoredTo'} = 1;
            next;
        }
        next unless($vvname =~ /^scro-DS\d\d\d\d\d-(?:DR)?\d\d-\d+$/);
        my ($sidId, $diskId, $dsId) = sidDiskAndDatasetIdForVVName($vvname);
        $dsId =~ s/^0+//;

        $roEXPs{$vvname} = $dsId;

        my $cpOf = $vv->copyOf();
        next unless($cpOf && $cpOf ne '---');
        $baseVVs{$cpOf} = $dsId;
        $cpOf = $vvHash{$cpOf}->copyOf();
        next unless($cpOf =~ /^basescro/);
        my ($baseSID, $baseDisk, $baseVVdsId) = sidDiskAndDatasetIdForVVName($cpOf);
        $baseVVdsId =~ s/^0+//;
        $baseROs{$cpOf} = $baseVVdsId;
    }

    foreach my $vv (@vvs) {
        my $vvname = $vv->name();
        my $cpOf = $vv->copyOf() || "";

        next if($vvname =~ /^scroDS\d+-/);

        next unless($cpOf && $cpOf ne '---');
        my ($sidId, $diskId, $dsId) = sidDiskAndDatasetIdForVVName($vvname);
        next unless(defined($dsId));
        $dsId =~ s/^0+//;
        if($baseVVs{$cpOf} && $dsId != $baseVVs{$cpOf}) {
            $ret->{$dsId}->{'parent'} = $baseVVs{$cpOf};
            $ret->{$baseVVs{$cpOf}}->{'children'}->{$dsId} = 1;
        } elsif ($roEXPs{$cpOf} && $dsId != $roEXPs{$cpOf}) {
            $ret->{$dsId}->{'parent'} = $roEXPs{$cpOf};
            $ret->{$roEXPs{$cpOf}}->{'children'}->{$dsId} = 1;
        } elsif ($baseROs{$cpOf} && $dsId != $baseROs{$cpOf}) {
            $ret->{$dsId}->{'parent'} = $baseROs{$cpOf};
            $ret->{$baseROs{$cpOf}}->{'children'}->{$dsId} = 1;
        }
    }

    return($ret);
}

#
# this relies on the metadata in the dataset -- we don't trust it for real
# operations, but for show, it's prolly right
#
sub getTopologyOfDatasetFast {
    my $self = shift;
    my $ret;
    my $count;

    return(undef) unless($self->isThin);

    foreach my $vvinfo ($self->baseVolumes()) {
        my ($sidId, $diskId, $vv, $dr) = split(/:/, $vvinfo);
        $sidId .= "-DR" if($dr);
        $ret->{'baseVVs'}->{$sidId}->{$diskId} = $vv;
        $ret->{'readOnlyExports'}->{$sidId}->{$diskId} =
            $self->exportReadOnlyNameForSidAndDisk($sidId, $diskId, $dr);
        if($self->hasBaseReadOnly()) {
            $ret->{'baseRO'}->{$sidId}->{$diskId} =
                $self->baseReadOnlySnapshotNameForSidAndDisk($sidId,$diskId,$dr);
        }
        $count++;
    }

    $ret->{'count'} = $count;

    return($ret);
}

sub getTopologyOfDataset {
    my $self = shift;
    my $nm = shift;
    my $VVCheck = shift;
    my $service = shift;
    my $ret;
    my $count = 0;
    my $retry=0;
    my @vvs;

    return undef unless($nm);
    return undef unless($self->isThin());

    my $pattern = $self->exportReadOnlyNameForSidAndDisk();

    my @patterns;
    if ( defined $VVCheck && isscperf($service) ){
        $pattern =~ s/\*//g;
        for my $key (keys %$VVCheck) {
            my ($num) = $VVCheck->{$key}[0] =~ /DS\d+-(\d\d)-/i;
            push @patterns, $pattern.'-'.$num.'*';
        }
    } else {
        push @patterns, $pattern;
    }

    for my $patternStr (@patterns ){
        my @vvsTemp;
        do {
            sleep(1) if($retry);
            ( @vvsTemp ) = $nm->cmdShowvv( $patternStr );
            $retry++;
        } while( $retry < 3 && !scalar( @vvsTemp ) );
        push @vvs, @vvsTemp if (scalar( @vvsTemp ));;
    }

    unless(scalar(@vvs)) {
        $logger->warn( "WARNING: failed to get topology from 3par.  Trusting metadata instead." );
        return( $self->getTopologyOfDatasetFast() );
    }

    foreach my $vv ( @vvs ) {
        my $base = $vv->copyOf();
        my $expRO = $vv->name();
        my ($sidId, $diskId, $dsId) = sidDiskAndDatasetIdForVVName($expRO);
        $sidId .= "-DR" if($expRO =~ /-DR/);
        $ret->{'readOnlyExports'}->{$sidId}->{$diskId} = $expRO;
        $ret->{'baseVVs'}->{$sidId}->{$diskId} = $base;
        $count++;
    }

    $pattern = $self->baseReadOnlySnapshotNameForSidAndDisk();

    ( @vvs ) = $nm->cmdShowvv( $pattern );

    foreach my $vv ( @vvs ) {
        my $baseRO = $vv->name();
        my ($sidId, $diskId, $dsId) = sidDiskAndDatasetIdForVVName($baseRO);
        $sidId .= "-DR" if($baseRO =~ /-DR/);
        $ret->{'baseRO'}->{$sidId}->{$diskId} = $baseRO;
    }

    $ret->{'count'} = $count;

    return($ret);
}

sub promoteToSpecifiedParent {
    my $src = shift; # this is $self, but it's clearer naming it "source"
    my $tgt = shift;

    my $srcId = $src->instance();
    my $tgtId = $tgt->instance();

    my $lockProduct = 'promote';
    my $lockService = 'dataset';

    my $mclDir = ariba::Ops::Constants->archiveManagerMCLDir();
    ariba::rc::Utils::mkdirRecursively($mclDir);
    ariba::Ops::MCL::setDirectory($mclDir);
    my $mclname = "promote.mcl";
    my $mclFile = "$mclDir/$mclname";
    my $user = "mon" . $src->serviceName();

    #
    # check the locks
    #
    my $lock = ariba::Ops::DatasetManager::Lock->newFromProductAndService(
        $lockProduct, $lockService
    );

    if( -r $mclFile ) {
        my $lockCheck = $lock->checkLock($src->instance(), 'Resume');
        return(0) unless($lockCheck);
    } else {
        my $lockCheck = $lock->checkLock($src->instance(), 'New');
        return(0) unless($lockCheck);

        $lock->setAction('promote to $tgtId');
        $lock->setHost( ariba::Ops::NetworkUtils::hostname() );
        my $uid = $<;
        $lock->setUser( (getpwuid($uid))[0] );
        $lock->setDataset( $srcId );
    }

    $lock->setStatus('Running');
    $lock->save();

    unless( -r $mclFile ) {
        my $inserv = $src->inserv();
        my $machine = ariba::Ops::Machine->new($inserv);
        my $nm = ariba::Ops::NetworkDeviceManager->newFromMachine($machine, $src->shouldProxy());

        #
        # check 1 -- is $src a child of $tgt?
        #
        my $tree = getDatasetTree($nm);
        my $ds = $srcId;
        my $ok = 0;
        while($ds = $tree->{$ds}->{'parent'}) {
            if($ds == $tgtId) {
                $ok = 1;
                last;
            }
        }

        unless($ok) {
            $logger->error("Dataset $srcId is not a child of $tgtId.");
            $lock->release();
            return(0);
        }

        #
        # check 2 -- does the topology match?
        #
        my $srcTop = $src->getTopologyOfDataset($nm);
        my $tgtTop = $tgt->getTopologyOfDataset($nm);

        #
        # 2a -- check the count
        #
        if($srcTop->{'count'} != $tgtTop->{'count'}) {
            $logger->error("source has " . $srcTop->{'count'} . " VVs and target has " . $tgtTop->{'count'} . " VVs, which is incompatible.");
            $lock->release();
            return(0);
        }

        my %promotes;

        #
        # 2b -- check that we line up correctly
        #
        foreach my $sid (sort keys %{$srcTop->{'readOnlyExports'}}) {
            foreach my $diskId (sort keys %{$srcTop->{'readOnlyExports'}->{$sid}}) {
                unless($tgtTop->{'baseVVs'}->{$sid}->{$diskId}) {
                    my $ro = $srcTop->{'readOnlyExports'}->{$sid}->{$diskId};
                    $logger->error("$ro in $srcId does not have a matching base volume in $tgtId");
                    $lock->release();
                    return(0);
                }
                my $ro = $srcTop->{'readOnlyExports'}->{$sid}->{$diskId};
                my $rw = $tgtTop->{'baseVVs'}->{$sid}->{$diskId};
                $promotes{$ro} = $rw;
            }
        }

        my $MCL;
        open($MCL, "> $mclFile");

        my $group = "promote";
        my $expando = "EXPROMOTE";
        my $depends;

        print $MCL defineVariable('SERVICE', $src->serviceName()),"\n";
        print $MCL defineRunGroup($group,2);
        print $MCL defineExpando($expando, "Promote Volumes");

        setStepName(0,1);
        my @errorStrings;
        foreach my $ro (sort keys %promotes) {
            my $rw = $promotes{$ro};
            print $MCL defineStep(stepName(), "promote $rw -> $rw",
                $depends, $expando, $group);
            print $MCL defineAction("NetworkDevice", $inserv,
                "\$ promotesv -target $rw $ro",
            ),"\n";
            push(@errorStrings, "ErrorString: $rw");
            incrementStepName();
        }

        $depends = "group:$group";
        $group = undef;
        $expando = undef;

        print $MCL defineStep("1.0", "Wait for promote to finish",
            $depends, $expando, $group, undef, 1080, 10);
        print $MCL defineAction("NetworkDevice", $inserv,
            "\$ showtask -active",
            @errorStrings,
        ),"\n";

        $group = "rename";
        $expando = "EXRENAME";

        print $MCL defineRunGroup($group,2);
        print $MCL defineExpando($expando, "Rename Volumes");
        setStepName(2,1);
        
        foreach my $type (qw(readOnlyExports baseVVs)) {
            foreach my $sid (sort keys %{$srcTop->{$type}}) {
                foreach my $diskId (sort keys %{$srcTop->{'readOnlyExports'}->{$sid}}) {
                    $depends = "1.0";

                    my $a = $tgtTop->{$type}->{$sid}->{$diskId};
                    my $b = $srcTop->{$type}->{$sid}->{$diskId};
                    my $c = "$a-temp";

                    print $MCL defineStep(stepName(), "rename $a -> $c",
                        $depends, $expando, $group);
                    print $MCL defineAction("NetworkDevice", $inserv,
                        "\$ setvv -name $c $a",
                    );
                    $depends = incrementStepName();

                    print $MCL defineStep(stepName(), "rename $b -> $a",
                        $depends, $expando, $group);
                    print $MCL defineAction("NetworkDevice", $inserv,
                        "\$ setvv -name $a $b",
                    );
                    $depends = incrementStepName();

                    print $MCL defineStep(stepName(), "rename $c -> $b",
                        $depends, $expando, $group);
                    print $MCL defineAction("NetworkDevice", $inserv,
                        "\$ setvv -name $b $c",
                    ),"\n";
                    incrementStepName();
                }
            }
        }

        $group = "recreate";
        $expando = "EXROSNAP";

        print $MCL defineRunGroup($group,2);
        print $MCL defineExpando($expando, "Recreate RO Snapshots");
        setStepName(3,1);

        foreach my $sid (sort keys %{$srcTop->{'readOnlyExports'}}) {
            $depends = "group:rename";
            foreach my $diskId (sort keys %{$srcTop->{'readOnlyExports'}->{$sid}}) {
                my $ro = $tgtTop->{'readOnlyExports'}->{$sid}->{$diskId};
                my $rw = $tgtTop->{'baseVVs'}->{$sid}->{$diskId};
                my $roDel = $ro; $roDel =~ s/^scro/TRASH/;

                print $MCL defineStep(stepName(), "rename $ro -> $roDel",
                    $depends, $expando, $group);
                print $MCL defineAction("NetworkDevice", $inserv,
                    "\$ setvv -name $roDel $ro",
                );
                $depends = incrementStepName();

                print $MCL defineStep(stepName(), "recreate $ro",
                    $depends, $expando, $group);
                print $MCL defineAction("NetworkDevice", $inserv,
                    "\$ creategroupsv -ro $rw:$ro",
                ),"\n";
                incrementStepName();
            }
        }

        $depends = "group:$group";
        $group = "parents";
        $expando = "EXPARENTS";

        print $MCL defineRunGroup($group,2);
        print $MCL defineExpando($expando, "Update parent metadata");
        setStepName(4,1);

        my $dsm = $FindBin::Bin . "/" . basename($0);
        unless( $dsm =~ /dataset-manager/) {
            $dsm = "/usr/local/ariba/bin/dataset-manager";
        }

        foreach my $ds (ref($src)->list()) {
            my $newParent;
            if($ds->instance() == $src->instance()) {
                my $toId = $tgt->parentDataset();
                $toId = "undef" unless($toId);
                $newParent = $toId;
            } elsif($ds->instance() == $tgt->instance()) {
                my $toId = $src->parentDataset();
                if($toId == $ds->instance()) {
                    $toId = $src->instance(); # a one level swap
                }
                $toId = "undef" unless($toId);
                $newParent = $toId;
            } elsif($ds->parentDataset() == $srcId) {
                $newParent = $tgtId;
            } elsif($ds->parentDataset() == $tgtId) {
                $newParent = $srcId;
            }

            next unless($newParent);
            my $id = $ds->instance();

            print $MCL defineStep(stepName(), "set ${id}'s parent to $newParent",
                $depends, $expando, $group);
            print $MCL defineAction("Shell", "$user\@ambrosia.ariba.com",
                "\$ $dsm set -parent $newParent $id",
            ),"\n";
            incrementStepName();
        }

        # this is required -- otherwise all parallel steps will share a NM
        $nm->disconnect();

        close($MCL);

        my $localhost = ariba::Ops::NetworkUtils::hostname();
        my $cmd = "ssh $user\@$localhost -x sudo /bin/rm -rf /var/mcl/$mclname $mclFile.last.success";
        my $password = ariba::rc::Passwords::lookup($user);
        my @output;

        my $exitCode = ariba::rc::Utils::executeRemoteCommand(
            $cmd,
            $password,
            0,
            undef,
            undef,
            \@output
        );

        unless($exitCode) {
            unlink($mclFile);
            $lock->release();
            $logger->error("Failed to remove /var/mcl/$mclname");
            $logger->error(join("\n", @output));
            return(0);
        }
    }

    my $oldDollarZero = $0;
    $0 = "mcl-control";
    my $mcl = ariba::Ops::MCL->new($mclname);
    my $ret;

    #
    # For testing
    #
    # ariba::Ops::MCL::setDebug(1);
    $mcl->setPaused(1);

    $mcl->recursiveSave();
    if(!$src->noui() && ariba::Ops::Utils::sessionIsInRealTerminal()) {
        unless(ariba::Ops::Utils::sessionIsInScreen()) {
            $logger->error("This operation requires you to be inside screen.");
            $logger->info("Start a screen session, and restart the command.");
            $lock->detach();
            return(0);
        }
        $ret = $mcl->controlCenter();
    } else {
        $ret = $mcl->executeInParallel();
    }

    $mcl->recursiveSave();
    $0 = $oldDollarZero;

    if($ret) {
        $lock->release();
        system("/bin/mv $mclFile $mclFile.last.success");
    } else {
        $lock->detach();
    }

    return($ret);
}

sub makeThinBaseCopyOfThinChild {
    my $self = shift;

    unless($self->isThinChild()) {
        $logger->error("Call to makeThinBaseCopyOfThinChild requires thinchild dataset");
        return(0);
    }

    my $inserv = $self->inserv();
    unless($self->inserv()) {
        $logger->error("Source dataset does not define a 3par.");
        return(0);
    }

    my $dstDS = ref($self)->newDataset(
        $self->productName(),
        $self->serviceName(),
        $self->buildName(),
        $self->debug()
    );

    unless($dstDS) {
        $logger->error("Failed to create destination dataset.");
        return(0);
    }
    $logger->info("Created destination dataset " . $dstDS->instance());

    $dstDS->setInserv($inserv);
    $dstDS->setBackupType('thinbase');
    $dstDS->setSidList( $self->sidList() );

    my $machine = ariba::Ops::Machine->new($inserv);
    my $nm = ariba::Ops::NetworkDeviceManager->newFromMachine($machine, $self->shoudProxy());
    unless($nm) {
        $logger->error("Unable to connect to inserv $inserv.");
        return(0);
    }
    $nm->setDebug(1) if $self->debug() >= 2;

    my @vvs = $nm->cmdShowvv();
    my %vvMap;
    foreach my $vv (@vvs) {
        $vvMap{$vv->name()} = $vv;
    }
    my $cpgMap = $nm->cpgMapForVVPattern();
    my $top = $self->getTopologyOfDataset($nm);
    my %cpPairs;
    my %snapPairs;
    my @baseVVs;

    #
    # make new VVs
    #
    foreach my $sid (sort keys %{$top->{'baseVVs'}}) {
        my $isDr = 0;
        my $sidKey = $sid;
        $isDr = 1 if($sidKey =~ s/-DR$//);
        foreach my $disk (sort keys %{$top->{'baseVVs'}->{$sid}}) {
            my $sourceBase = $top->{'baseVVs'}->{$sid}->{$disk};
            my $newBaseName = $dstDS->baseVVNameForSidAndDisk(
                $sidKey, $disk, $isDr
            );
            push(@baseVVs, "$sidKey:$disk:$newBaseName:$isDr");

            #
            # for now use the CPG of the base volume -- we have to track back
            # to the real base volume to get it tho
            #
            my $vv = $vvMap{$sourceBase};
            while( $vv->copyOf() && $vvMap{$vv->copyOf()}) {
                $vv = $vvMap{$vv->copyOf()}
            }
            my $snpCpg = $cpgMap->{$vv->name()}->{'snpCpg'};
            my $usrCpg = $cpgMap->{$vv->name()}->{'usrCpg'} || $snpCpg;

            $logger->info("creating $newBaseName (for $sourceBase), usrcpg=$usrCpg, snpcpg=$snpCpg.");

            unless( $nm->createThinProvisionedVVFromCPGs( $newBaseName, $usrCpg )) {
                $logger->error( $nm->error() );
                return(0);
            }

            $cpPairs{$sourceBase} = $newBaseName;
            $snapPairs{$newBaseName} = $dstDS->exportReadOnlyNameForSidAndDisk(
                $sidKey, $disk, $isDr
            );
        }
    }

    $logger->info("Starting physical copies:");
    foreach my $src (sort keys %cpPairs) {
        $logger->info("\t$src -> $cpPairs{$src}");
    }

    unless( $nm->physicalCopyForVirtualVolumes(\%cpPairs, $logger) ) {
        $logger->error("Failed to physical copy VVs");
        return(0);
    }

    foreach my $src (sort keys %cpPairs) {
        my $base = $cpPairs{$src};
        my $expRO = $snapPairs{$base};

        $logger->info("Creating snapcopy $base:$expRO");
        unless( $nm->createSnapCopy($base, $expRO, "ro") ) {
            $logger->error("Creation of snap copy failed.");
            return(0);
        }
    }

    #
    # Copy archive directory over
    #
    my $archiveDir = ariba::Ops::Constants->archiveManagerArchiveDir();
    my $srcArchiveDir = $archiveDir . "/" . $self->instance();
    my $dstArchiveDir = $archiveDir . "/" . $dstDS->instance();
    $logger->info("Copying $srcArchiveDir to $dstArchiveDir...");
    my $ret = ariba::rc::Utils::copyFiles($srcArchiveDir, undef, $dstArchiveDir, undef);
    unless($ret) {
        $logger->error("Failed to copy $srcArchiveDir to target dataset.");
        return(0);
    }

    $dstDS->setBaseVolumes( @baseVVs );
    $dstDS->setDatasetComplete($self->datasetComplete());
    $dstDS->setDbBackupStatus($self->dbBackupStatus());
    $dstDS->setRealmBackupStatus($self->realmBackupStatus()) if($self->realmBackupStatus());
    $dstDS->setRealmRootDir($self->realmRootDir()) if($self->realmRootDir());
    $dstDS->setRealmSizeInBytes($self->realmSizeInBytes()) if($self->realmSizeInBytes());
    $dstDS->save();

    $logger->info("makebasecopy completed successfully.");

    return($dstDS);
}

sub mclDir {
    my $self = shift;

    my $DATADIR = ariba::Ops::Constants->archiveManagerMCLDir();
    $DATADIR .= "/" . $self->instance();

    return($DATADIR);
}

sub mclName {
    my $self = shift;
    return( "restore-" . $self->instance() . ".mcl" );
}

sub grepLunsForPeerAndVV {
    my $vvname = shift;
    my $peerConn = shift;
    my $exportHost = shift;
    my $svcNM = shift;
    my (@vluns) = (@_);
    my $ret = {};

    if($peerConn->peerType() eq 'oracle') {
        foreach my $vlun ( @vluns ) {
            print "B", $vlun->instance(),"\n";
            my $export;
            foreach my $ex ($vlun->exports()) {
                #
                # the base library will sometimes return a LUN that
                # is not actually mapped to this VV, so we do a
                # validity/sanity check here.
                #
                $logger->info("Check for $vvname $exportHost " . $ex->lun());
                if($svcNM->checkVlun( $vvname, $exportHost, $ex->lun())) {
                    $export = $ex;
                    last;
                }
            }
            my $lun = $export->lun();
            my $host = $exportHost;
            $host =~ s/\.ariba\.com$//;
            $ret->{$host} = $lun;
        }
    } else {
        foreach my $vlun ( @vluns ) {
            foreach my $ex ($vlun->exports()) {
                my $host = $ex->host();
                $host =~ s/\.ariba\.com$//;
                $ret->{$host} = $ex->lun();
            }
        }
    }

    return($ret);
}

sub restoreThin {
    my $self = shift;
    my $product = shift;
    my $saveServiceExports = shift;
    my $service = $product->service();
    my $prodName = $product->name();
    my $datasetId = $self->instance();
    my %archiveLogDirs;
    my %archiveLogHosts;
    my %assignedSid; # used for bootstrap
    my $nextSidId = 0; # also for bootstrap
    my @basevvlist;
    my $hasBaseRO;
    my $parAction = "NetworkDevice";
    my $DBNames = {};
    my $hanaTenantImpExp = 0;
    my $hanaSystemDBToken = 'hanasystemdbuser';

    my $skipHana = 1 if ( $self->noHana() );
    #
    # disabling this for now in favor of a simple retry loop
    #
    # if( -e "/usr/local/bin/cli" ) {
    #   $main::useInformFor3par = 1;
    #   $parAction = "3parInform";
    # }

    ## Tenant level backup/restore is only for scperf service (as of now)
    ## Remove service condition check if for all services
    my $isScPerf = isscperf($service);
    if ($isScPerf && ! $self->hanaChild() && ! $skipHana) {
        $hanaTenantImpExp = 1;
    }

    my $dsm = $FindBin::Bin . "/" . basename($0);
    unless( $dsm =~ /dataset-manager/) {
        $dsm = "/usr/local/ariba/bin/dataset-manager";
    }

    ariba::rc::Utils::mkdirRecursively($self->mclDir());
    ariba::Ops::MCL::setDirectory($self->mclDir());
    my $mclname = $self->mclName();
    my $mclfile = $self->mclDir() . "/$mclname";

    #
    # check lock files first
    #
    my $lock = ariba::Ops::DatasetManager::Lock->newFromProductAndService(
        $prodName, $service
    );

    if( -r $mclfile ) {
        my $lockCheck = $lock->checkLock($self->instance(), 'Resume');
        return(0) unless($lockCheck);
    } else {
        my $lockCheck = $lock->checkLock($self->instance(), 'New');
        return(0) unless($lockCheck);

        #
        # new operation, populate the lock data
        #
        if($saveServiceExports) {
            $lock->setAction('backup');
        } else {
            $lock->setAction('restore');
        }
        $lock->setHost( ariba::Ops::NetworkUtils::hostname() );
        my $uid = $<;
        $lock->setUser( (getpwuid($uid))[0] );
        $lock->setDataset( $self->instance() );
    }

    #
    # XXX there is the slight chance of a race state here, but it's not likely
    # in the case of this tool.
    #
    $lock->setStatus('Running');
    $lock->save();

    unless( -r $mclfile ) {
        my $svcNM;
        my $dsNM;
        my @lastStepsForSids;
        my %vlunsForFS;
        my $restoreHanaExport = 0;
        my $notifyEmail = $product->default('Ops.Notify.DatasetManagerEmail');

        #
        # check to see if we will be restoring a hana db export
        #
        if(!$saveServiceExports && $self->hanaChild()) {
            my @dbcList = ariba::Ops::DBConnection->connectionsFromProducts($product);
            @dbcList = grep { $_->dbServerType() eq 'hana' } @dbcList;
            $restoreHanaExport = $self->hanaChild() if(scalar(@dbcList));
        }

        $logger->info("Constructing MCL for restore to DS" . $self->instance());

        if($self->productName() ne $prodName) {
            my $baseProd = $self->productName();
            $logger->error("dataset is for $baseProd, and cannot be used to restore $prodName.");
            $lock->release();
            return(0);
        }

        if($self->serviceName() ne $service) {
            my $baseService = $self->serviceName();
            $logger->error("dataset is for $baseService, and cannot be used to restore $prodName in $service.");
            $lock->release();
            return(0);
        }

        my @peersFromProduct;

        eval {
            @peersFromProduct = ariba::Ops::DatabasePeers->newListFromProduct(
                $product,
                {
                 'debug' => $self->debug(),
                 'populateFsInfo' => 1,
                 'skipDR' => $self->skipDR(),
                 'skipTypes' => $self->skipTypes(),
                 'includeLogVolumes' => 1,
                }
            );
        };

        if($@) {
            $logger->error($@);
            $logger->info("This is LIKELY because the 3par didn't respond correctly...");
            $logger->info("Try again, it will probably work.");
            $lock->release();
            return(0);
        }

        ####=============================================================================####
        # Skip HANA peers for Thin backup/restore
        # HANA dataset will be linked as hanaChild in catalog file
        ####=============================================================================####
        @peersFromProduct = grep { $_->peerType() !~ /hana/i } @peersFromProduct;

        unless(@peersFromProduct) {
            $logger->error("Failed to get database peer info.");
            $lock->release();
            return(0);
        }

        unless( checkPeersForOpenFiles(@peersFromProduct) ) {
            $logger->error("There are open files on database volumes.\n");
            $logger->error("Contact the DBAs or sysadmins for assistance.\n");
            $lock->release();
            return(0);
        }

        ## Hana connections
        my $hanaDbcs = getDBConnectionsForProduct($product,"hana");

        $logger->info("Checking to see if DS$datasetId is compatible...");

        #
        # check to see if the service is using thin style data volumes
        # we also need to do a topology check in here,
        #
        # except if we are creating a new dataset, in which case we're in the
        # process of making and restoring to a known compatible snapshot, and
        # already checked this to decide if we are an fpc or thinchild snapshot
        #
        unless($saveServiceExports) {
            #
            # inserv() is a function that has a default hard coded for
            # legacy code -- but for instant restore we handle this being
            # undefined more sanely, so we'll get the actual attribute
            # Action: Snap Restore

            my $inservHostname = $self->attribute('inserv');
            my $dsTop;
            my %checkedThisVV;
            my $vvCount = 0;

            if($inservHostname) {
                my $machine = ariba::Ops::Machine->new($inservHostname);
                $dsNM = ariba::Ops::NetworkDeviceManager->newFromMachine($machine, $self->shouldProxy());
                unless($dsNM) {
                    $logger->error("Unable to connect to inserv $inservHostname for dataset.");
                    $lock->release();
                    return(0);
                }
                $dsNM->setDebug(1) if $self->debug() >= 2;
            }

            foreach my $peer (@peersFromProduct) {
                foreach my $peerConn ($peer->allPeerConnections()) {
                    next unless($peerConn);
                    foreach my $filesystem ($peerConn->dbFsInfo()) {
                        next if($filesystem->fs() =~ /log/); # skip log vols
                        unless($svcNM) {
                            my $inhst = $filesystem->inserv();
                            #
                            # we fail to get this sometimes (damn 3par).
                            # as long as one FS from the dataset gets this,
                            # it all works.
                            #
                            next unless($inhst);
                            my $mchn = ariba::Ops::Machine->new($inhst);
                            $svcNM = ariba::Ops::NetworkDeviceManager->newFromMachine($mchn, $self->shouldProxy());
                            $svcNM->setDebug(1) if $self->debug() >= 2;
                            unless($dsNM) {
                                # if the dataset has no inserv set, assume it's the
                                # same as the service
                                $dsNM = $svcNM;
                            }
                            $dsTop = $self->getTopologyOfDataset($dsNM);
                        }

                        my @vvList = $filesystem->vvList();
                        foreach my $vv (@vvList) {
                            my ($sidId, $diskId, $oldDS) = sidDiskAndDatasetIdForVVName($vv);
                            unless(defined($sidId) && defined($diskId) && defined($oldDS)) {
                                $logger->error("$prodName in $service is not setup to use thin datasets.");
                                $logger->error("vv=$vv, sid=$sidId, diskId=$diskId, oldDS=$oldDS");

                                $lock->release();
                                return(0);
                            }

                            unless( $dsTop->{'baseVVs'}->{$sidId}->{$diskId} ) {
                                $logger->error("Topology Incompatibility Detected.  $prodName in $service uses");
                                $logger->error("$vv which does not correspond to a volume in DS$datasetId");
                                $lock->release();
                                return(0);
                            }
                            $checkedThisVV{$vv} = 1;
                        }
                    }
                    #
                    # this can fail if we are restoring across 3pars...
                    # but, we most likely are not since that would require
                    # different base volumes (you can't have a snapshot across
                    # more than one 3par), and if this is wrong, we can fix
                    # the MCL.
                    #
                    unless($svcNM) {
                        $svcNM = $dsNM;
                    }
                }
            }
            $vvCount = scalar(keys(%checkedThisVV));

            unless( $vvCount == $dsTop->{'count'} ) {
                $logger->error("Topology Incompatibility Detected.  DS$datasetId has " . $dsTop->{'count'} . "VVs,");
                $logger->error("and the service is using $vvCount VVs.");
                $logger->info("This is LIKELY because the 3par didn't respond correctly...");
                $logger->info("Try again, it will probably work.");
                $lock->release();
                return(0);
            }

        } else {
            #
            # if we're taking a snap backup, we still need to set $svcNM and $dsNM
            #
            my $parentDS;
            my $vvCount;
            my %checkedThisVV;
            my $VVCheck;

            foreach my $peer (@peersFromProduct) {
                $assignedSid{"versionOf" . $peer->sid()} = $peer->dbVersion();

                foreach my $peerConn ($peer->allPeerConnections()) {
                    next unless($peerConn);
                    my $host = $peerConn->host();
                    my %hostVVs;
                    foreach my $filesystem ($peerConn->dbFsInfo()) {
                        next if($filesystem->fs() =~ /log/); # skip log vols
                        unless($svcNM) {
                            my $inhst = $filesystem->inserv();
                            my $mchn = ariba::Ops::Machine->new($inhst);
                            $svcNM = ariba::Ops::NetworkDeviceManager->newFromMachine($mchn, $self->shouldProxy());
                            $svcNM->setDebug(1) if $self->debug() >= 2;
                            $dsNM = $svcNM;
                            $self->setInserv($inhst);
                        }
                        my (@vvlist) = $filesystem->vvList();
                        foreach my $vv (@vvlist) {
                            my ($junk1, $junk2, $oldDS) = sidDiskAndDatasetIdForVVName($vv);
                            if($parentDS) {
                                if($parentDS != $oldDS) {
                                    $logger->error("Service is currently split between $oldDS and $parentDS.");
                                    $lock->release();
                                    return(0);
                                }
                            } else {
                                $parentDS = $oldDS;
                            }
                            $checkedThisVV{$vv} = 1;
                            $hostVVs{$vv} = 1;
                        }
                    }
                    push @{$VVCheck->{$host}}, keys(%hostVVs);
                }
            }
            $parentDS =~ s/^0+//;
            my $parentDataset = ariba::Ops::DatasetManager->new($parentDS);
            my $dsTop = $parentDataset->getTopologyOfDataset($dsNM,$VVCheck,$service);

            $vvCount = scalar(keys(%checkedThisVV));
            unless( $vvCount == $dsTop->{'count'} ) {
                $logger->error("Topology Incompatibility Detected.");
                $logger->error("DS$parentDS has " . $dsTop->{'count'} . " VVs, and the service is using $vvCount VVs.");
                $logger->info("This is LIKELY because the 3par didn't respond correctly...");
                $logger->info("Try again, it will probably work.");
                $lock->release();
                return(0);
            } else {
                $logger->info("Topology OK:");
                $logger->info("DS$parentDS has " . $dsTop->{'count'} . " VVs, and the service is using $vvCount VVs.");
            }

            #
            # we also need to save archive logs if we're making a backup.
            # NOTE: hana doesn't have this the same way
            #
            my %sidsSeen;
            my @dbcs = ariba::Ops::DBConnection->connectionsFromProducts($product);
            @dbcs = grep { !$_->dbType() || $_->dbType() ne 'hana' } @dbcs;

            foreach my $dbc (@dbcs) {
                next if($sidsSeen{$dbc->sid()});
                next if($dbc->isDR()); # only need archive logs for PRIMARY
                next unless($dbc->drDBPeer()); # no need if we don't have DR

                #
                # don't backup logs if we're skipping this type
                #
                my $skip = 0;
                foreach my $skipType ($self->skipTypes()) {
                    my $type = $dbc->type();
                    $type =~ s/.*-//;
                    $type = lc($type);
                    $skip = 1 if($skipType eq $type);
                }
                next if($skip);

                next if($dbc->dbServerType() =~/Hana/si);

                $sidsSeen{$dbc->sid()} = 1;
                #
                # B1 run this query on DB:
                #    select DESTINATION from v$archive_dest where dest_name='LOG_ARCHIVE_DEST_1';
                #
                #    query will return a directory with archive logs to back up
                #
                my $oc = ariba::Ops::OracleClient->newSystemConnectionFromDBConnection($dbc);
                unless($oc->connect()) {
                    $logger->error("unable to connect to database to find archive logs: [" . $oc->error() . "].");
                    $lock->release();
                    return(0);
                }
                my $sql = "select DESTINATION from v\$archive_dest where dest_name='LOG_ARCHIVE_DEST_1'";
                my ( $result ) = $oc->executeSql($sql);
                if( $result ) {
                    $logger->info("will backup archivelogs from $result on " . $dbc->host());
                    $archiveLogDirs{$dbc->sid()} = $result;
                    $archiveLogHosts{$result} = $dbc->host();
                } else {
                    $logger->error("Unable to get archive log location for " .
                        $dbc->sid() . " which has DR.");
                    $logger->info("This is a DB config problem.  You should contact the DBAs.");
                    $lock->release();
                    return(0);
                }
            }
        }

        if ( $hanaTenantImpExp ){
            my $types;
            my $mon = ariba::rc::InstalledProduct->new('mon', $product->service());
            my $user = $mon->default("dbainfo.hana.system.username");
            my $dbSql = 'select DATABASE_NAME from m_database'; ## to get DB name
            my $versionSql = "select value from sys.m_system_overview where name = 'Version'"; ## to get DB ver
            ## check HANA DB conncetions
            while (my ($key, $dbc) = each (%$hanaDbcs)){
                my $host = $dbc->{host};
                my $port = $dbc->{port};
                my $hc = ariba::Ops::HanaClient->new($user, ariba::rc::Passwords::lookup($hanaSystemDBToken),
                                                     $host,$port);
                if ( !$hc->connect(undef, 2) ) {
                    $logger->error("unable to connect to database: [" . $hc->error() . "].");
                    $lock->release();
                    return 0;
                }
                my $dbName = $hc->executeSql($dbSql);
                my $dbVersion = $hc->executeSql($versionSql);
                my @splitVersion = split(/\./,$dbVersion);
                $dbVersion = $splitVersion[0].'.'.$splitVersion[2];
                unless($dbName) {
                    $logger->error("failed to get DB name for $host:$port, hence ignoring");
                    $lock->release();
                    return 0;
                }
                my ($type) = $key =~ /([a-z]+)/i;
                push @{$types->{$type}}, $dbName.":".$dbVersion;

                push @{$DBNames->{$type}}, {
                        hostPort  => $host.":".$port,
                        dbName    => $dbName,
                        dbVersion => $dbVersion,
                        type      => $type,
                };
                $hc->disconnect();
            }

            if ( $saveServiceExports){
                $self->setHanaDBTypes($types);   ##Write Hana DB's in Catalog
            } else {
                ## Hana Topology check
                my $hanaDBTypes = {};
                $logger->info("Hana Topology check");
                for my $type (keys %$DBNames){
                    my @dbTypes = $self->getHanaDBTypes($type);
                    my $srcCnt = scalar(@dbTypes);
                    my $targetCnt = scalar(@{$DBNames->{$type}});

                    if ( $srcCnt ne $targetCnt ){
                        $logger->error("HANA Topology Incompatibility Detected: $type source has ".$srcCnt." DB(s) and taget has ".$targetCnt.". which is DB incompatible.\n");
                        $logger->error("Please check catalog for source DBs and P.table for destination\n");
                        $lock->release();
                        return 0;
                    }

                    ## Hana Version Topology check
                    unless( $hanaDBTypes->{$type} ) {
                        my @dbs = $self->getHanaDBTypes($type);
                        $hanaDBTypes->{$type} = \@dbs;
                    }
                    for my $value (@{$DBNames->{$type}}){
                        my $targetDBName = $value->{dbName};
                        my ($sourceDBName,$sourceDBVersion) = split(/:/,shift(@{$hanaDBTypes->{$type}}));
                        if ( $sourceDBVersion ne $value->{dbVersion} ){
                            $logger->error("HANA Topology Incompatibility Detected: DB Version Incompatibility");
                            $logger->error("Source DB: $sourceDBName, Version: $sourceDBVersion");
                            $logger->error("Target DB: $targetDBName, Version: ".$value->{dbVersion});
                            $lock->release();
                            return(0);
                        }
                    }
                }
                $logger->info("Hana Topology OK");
            }
        }

        open(MCL, "> $mclfile");

        print MCL "Variable: SERVICE=", $product->service(), "\n";
        print MCL "Variable: EXIT=1\n\n";
        if($saveServiceExports) {
            print MCL "MCLTitle: Backup to DS", $self->instance(), "\n\n";
        } else {
            print MCL "MCLTitle: Restore to DS", $self->instance(), "\n\n";
        }

        if($notifyEmail) {
            print MCL "Notify: failure email $notifyEmail\n\n";
        }

        print MCL defineRunGroup("scsiRescan",1);
        print MCL defineRunGroup("hanaConfig",1);
        print MCL defineRunGroup("3par",2);

        print MCL defineStep("MCL", "MCL Definition File",
            undef, undef, undef, undef, undef, undef);
        print MCL defineAction("Shell", undef,
            "\$ cat $mclfile",
        );
        print MCL "\n";

        my $USER = "svc" . $product->service();
        my $MONUSER = "mon" . $product->service();

        setBaseDependancy('WAIT') if($self->debug() > 1);

        if($restoreHanaExport) {
            my $cmd = "$dsm restore -product " . $product->name() . " -service " . $product->service() . " $restoreHanaExport";
            print MCL defineStep("HANA", "Restore hana export (DSID=$restoreHanaExport)",
                undef, undef, undef, undef, undef, undef);
            print MCL defineAction("Shell", undef,
                "\$ $cmd",
            ), "\n";
        }

        #
        # extra credit -- step to restore realms in parallel here
        #
        # EXTRA EXTRA credit -- do the realm backup in chunks in parallel!
        #
        if(
            ($saveServiceExports && $product->default('System.Base.RealmRootDir')) ||
            (!$saveServiceExports && $self->realmRootDir())
        ) {
            if($saveServiceExports) {
                my $backupRealms = $self->backupRealmsMCL($product);
                print MCL $backupRealms if($backupRealms);
            } else {
                my $restoreRealms = $self->restoreRealmsMCL($product);
                print MCL $restoreRealms if($restoreRealms);
            }
        }

        if($self->debug() > 1) {
            print MCL defineStep('WAIT', 'Wait for sanity check',
                undef, undef, undef, undef, undef, undef);
            print MCL defineAction('Wait', undef,
                "\$ Wait here for MCL review -- this step is debug only."
            );
            print MCL "\n";
        }

        my $sidPre = "0";
        foreach my $peer (@peersFromProduct) {
            $sidPre++;
            my $SID = $peer->primary()->sid();

            my $expando = "${SID}Stop";
            my $group = "stop$SID";
            my $depends = "";
            print MCL defineExpando($expando, "Shutdown $SID");
            print MCL defineRunGroup($group,1);

            if($peer->peerType() eq 'oracle') {
                #
                # wait for dataguard
                #
                if($saveServiceExports) {
                    print MCL defineStep("${sidPre}a", "Wait for Dataguard on $SID",
                        $depends, $expando, $group, undef, undef, undef);
                    print MCL defineAction("Perl", undef,
                        "Database::waitForDataguard('$SID','" . $product->name() . "','" . $product->service() . "','" . $product->buildName() . "')",
                    );
                    print MCL "\n";
                    $depends = "${sidPre}a";
                }

                #
                # stop archive log cleanup
                #
                print MCL defineStep("${sidPre}b", "Suspend Archive Deletion for $SID",
                    $depends, $expando, $group, undef, undef, undef);
                print MCL defineAction("Perl", undef,
                    "Database::suspendArchiveLogDeletion('$SID','" . $product->name() . "','" . $product->service() . "','" . $product->buildName() . "')"
                );
                print MCL "\n";
                $depends = "${sidPre}b";
            }

            #
            # shutdown database
            #
            my $count = 0;
            foreach my $peerConn ($peer->primary(), $peer->secondary()) {
                next unless($peerConn);
                my $dbhost = $peerConn->host();
                if($peerConn->peerType() eq 'hana') {
                    # HANA -- stop the DB
                    my $hanauser = lc($peerConn->sid()) . "adm";
                    foreach my $slave ($peerConn->standbyNodes(), $peerConn->slaveNodes()) {
                        next unless($slave);
                        my $slavehost = $slave->host();
                        print MCL defineStep("${sidPre}c${count}", "Shutdown $SID on $slavehost",
                            $depends, $expando, $group, undef, undef, undef);
                        print MCL defineAction("Shell", "$MONUSER\@$slavehost",
                            # "\$ /usr/local/ariba/bin/hana-control -s $hanauser -n -d stop -readMasterPassword",
                            "\$ /usr/local/ariba/bin/hana-control -s $hanauser -n -d stop -readMasterPassword",
                        );
                        print MCL "\n";
                        $depends = "${sidPre}c${count}";
                        $count++;
                    }

                    print MCL defineStep("${sidPre}c${count}", "Shutdown $SID on $dbhost",
                        $depends, $expando, $group, undef, undef, undef);
                    print MCL defineAction("Shell", "$MONUSER\@$dbhost",
                        # "\$ /usr/local/ariba/bin/hana-control -s $hanauser -n -d stop -readMasterPassword",
                        "\$ /usr/local/ariba/bin/hana-control -s $hanauser -n -d stop -readMasterPassword",
                    );
                    print MCL "\n";
                    $depends = "${sidPre}c${count}";
                    $count++;
                } else {
                    my $dbAction = "stop";
                    if( !$saveServiceExports ) {
                        $dbAction = "-k abort"; # on a restore, just kill the DB
                    }

                    $count++;
                    print MCL defineStep("${sidPre}c${count}", "Shutdown $SID on $dbhost",
                        $depends, $expando, $group, undef, undef, undef);
                    print MCL defineAction("Shell", "$MONUSER\@$dbhost",
                        "\$ /usr/local/ariba/bin/database-control -n -d $dbAction $SID -readMasterPassword",
                    );
                    print MCL "\n";
                    $depends = "${sidPre}c${count}";
                }
            }

            if($saveServiceExports && $peer->peerType() eq 'oracle') {
                #
                # if we are saving the snapcopy, backup the oracle logs too
                #
                if($archiveLogDirs{$peer->sid()}) {
                    my %volumes;
                    foreach my $p ($peer->primary(), $peer->secondary()) {
                        next unless($p);
                        foreach my $fs ($p->dbFsInfo()) {
                            next if($fs->fs() =~ /log/); # skip log vols
                            $volumes{$fs->fs()} = 1;
                        }
                    }
                    my $backupArchiveLogs = $self->backupArchiveLogsMCL(
                        $archiveLogDirs{$peer->sid()},
                        $archiveLogHosts{$archiveLogDirs{$peer->sid()}},
                        sort(keys(%volumes))
                    );
                    if($backupArchiveLogs) {
                        print MCL defineStep("${sidPre}d", "Backup Archive Logs for $SID",
                            $depends, $expando, $group, undef, undef, undef);
                        #
                        # return value of this function is a string defining actions
                        #
                        print MCL "$backupArchiveLogs\n";
                        $depends = "${sidPre}d";
                    }
                }
            }

            if($saveServiceExports && $peer->peerType() eq 'hana') {
                # HANA -- backup the archive logs
                my $archiveDir = ariba::Ops::Constants->archiveManagerArchiveDir();
                $archiveDir .= "/" . $self->instance();

                my $count = 1;
                my @tarDepends;
                foreach my $pc ($peer->allPeerConnections()) {
                    my $logsDir;
                    my $diskName;
                    foreach my $filesystem ($pc->dbFsInfo()) {
                        next unless($filesystem->fs() =~ /log/); # get the log volume
                        $logsDir = $filesystem->fs();
                        $diskName = $filesystem->diskName();
                        last;
                    }
                    my $tarFile = "$archiveDir/hanalogs-" . $pc->host() . "-" . $peer->sid() . ".tar.gz";

                    #
                    # XXX -- should fix the hard coded /hana/log, but the
                    # log mount can be deeper than the permission issue.
                    #
                    my @hanaCommands = (
                        "\$ sudo find /hana/log -type d | xargs sudo chmod a+rx",
                        "\$ sudo find /hana/log -type f | xargs sudo chmod a+r",
                        "\$ tar zcf $tarFile -C $logsDir .",
                    );

                    my @activeLuns = $pc->activeLunsOnHost($svcNM);
                    my $lunArg = join(',', @activeLuns);

                    if($peer->primary->isClustered()) {
                        #
                        # clustered hana unmounts the FS on shutdown, so we
                        # need to mount/umount it to backup the archive logs
                        #
                        push(@hanaCommands, "\$ sudo umount $logsDir");
                        unshift(@hanaCommands, "\$ sudo mount -t xfs $diskName $logsDir");
                        unshift(@hanaCommands, "\$ sudo /usr/local/ariba/bin/filesystem-utility loadhanadisks -l $lunArg");
                    }

                    print MCL defineStep("${sidPre}d$count", "Backup Archive Logs for $SID\@" . $pc->host(),
                        $depends, $expando, $group, undef, undef, undef);
                    print MCL defineAction("Shell", "$MONUSER\@" . $pc->host(),
                        @hanaCommands
                    ),"\n";
                    push(@tarDepends, "${sidPre}d$count");
                    $count++;
                }
                $depends = join(" ", @tarDepends);
            }
        }

        #
        # databases are down, restore/backup the filesystems
        #
        # for each volume, unmount FS, offline DG, remove luns (OS and 3par), restore/backup VV,
        # create luns (3par), online DG, mount FS
        #
        my $fsPre = "A";
        my %seenFS;

        foreach my $peer (@peersFromProduct) {
            foreach my $peerConn ($peer->allPeerConnections()) {
                next unless($peerConn);
                my $dr = ($peerConn->isSecondary()) ? "D" : "";
                foreach my $filesystem ($peerConn->dbFsInfo()) {
                    next if($filesystem->fs() =~ /log/); # skip log volumes
                    my $fsKey = $filesystem->host() . ":" . $filesystem->fs();
                    next if($seenFS{$fsKey});
                    $seenFS{$fsKey} = 1;

                    my @peersForFS = ariba::Ops::DatabasePeers::peerConnsForFS($filesystem, @peersFromProduct);
                    my @dep;
                    foreach my $p (@peersForFS) {
                        my $SID = $p->sid();
                        my $group = "stop$SID";
                        push(@dep, "group:$group");
                    }
                    my $depends = join(" ", @dep);

                    my $fs = $filesystem->fs();
                    my $action = (($saveServiceExports) ? "Backup" : "Restore");
                    my $exportHost = $filesystem->host();
                    my $parExportHost = $exportHost;
                    $parExportHost =~ s/\.ariba\.com$//;
                    my $diskGroup = $filesystem->diskGroup();
                    my $volumeName = $filesystem->fs(); $volumeName =~ s|^/||;

                    my $expando = "${fsPre}EXP";
                    print MCL defineExpando($expando, "$action $fs on $exportHost");
                    my $group = "RS$volumeName$parExportHost";
                    print MCL defineRunGroup($group, 30);

                    if($peerConn->peerType() eq 'oracle') {
                        print MCL defineStep("${fsPre}a","Unmount $fs",
                            $depends, $expando, undef, undef, undef, undef);
                        print MCL defineAction("Shell", "$USER\@$exportHost",
                            "\$ sudo /bin/umount /$volumeName"
                        );
                        print MCL "\n";
                        $depends = "${fsPre}a";

                        print MCL defineStep("${fsPre}b", "Offline Remove diskgroup for $fs on $exportHost",
                            $depends, $expando, undef, undef, undef, undef);
                        print MCL defineAction("Shell", "$USER\@$exportHost",
                            "\$ sudo /usr/local/ariba/bin/filesystem-utility offlineremove -g $diskGroup"
                        );
                        print MCL "\n";
                        $depends = "${fsPre}b";
                    }

                    if($peerConn->peerType() eq 'hana' && !$peer->primary()->isClustered()) {
                        print MCL defineStep("${fsPre}a","Unmount $fs",
                            $depends, $expando, undef, undef, undef, undef);
                        print MCL defineAction("Shell", "$USER\@$exportHost",
                            "\$ sudo /bin/umount /$volumeName"
                        );
                        print MCL "\n";
                        $depends = "${fsPre}a";
                    }

                    my @removeLunCommands;
                    my @restoreVVSteps;
                    my %lunsForDiskGroup;
                    my $lunList;
                    my @vvList = $filesystem->vvList();
                    foreach my $vvname (sort @vvList) {
                        my @vluns = $svcNM->vLunsforVirtualVolumesOfFilesystem({
                            'vvlist' => [ $vvname ], 'fs' => $filesystem->fs()
                        });
                        $vlunsForFS{$filesystem->fs()} = [] unless
                            ($vlunsForFS{$filesystem->fs()});
                        push(@{$vlunsForFS{$filesystem->fs()}}, @vluns);

                        my $luns;

                        #
                        # for Oracle, this returns a single lun/host pair
                        # for Hana, it returns all lun/host pairs
                        #
                        $luns = grepLunsForPeerAndVV($vvname, $peer, $exportHost, $svcNM, @vluns);
                        unless(scalar(keys(%$luns))) {
                            $logger->error("Did not find valid LUN export for $vvname");
                            $logger->info("This is likely due to the 3par being slow to respond.");
                            $logger->info("If you try again, it probably will work.");
                            unlink($mclfile);
                            $lock->release();
                            return(0);
                        }

                        #
                        # have to track the luns by host now
                        #
                        foreach my $host (keys %$luns) {
                            $lunsForDiskGroup{$host} = [] unless ($lunsForDiskGroup{$host});
                            push(@{$lunsForDiskGroup{$host}}, $luns->{$host});
                        }

                        $logger->info("Processing $vvname...");
                        my ( $sidId, $diskId, $lastRestoreId );
                        if($saveServiceExports && $self->isThinBase()) {
                            $sidId = $assignedSid{$peer->sid()};
                            unless($sidId) {
                                $sidId = sprintf("%02d",$nextSidId);
                                foreach my $p (@peersForFS) {
                                    $assignedSid{$p->sid()} = $sidId;
                                }
                                $nextSidId++;
                            }
                            if($vvname =~ /-(\d+)$/) {
                                $diskId = $1;
                            } else {
                                $logger->error("Found irregular vvname=$vvname\n");
                                close(MCL);
                                unlink( $mclfile );
                                $lock->release();
                                return(0);
                            }
                        } else {
                            ( $sidId, $diskId, $lastRestoreId ) = sidDiskAndDatasetIdForVVName($vvname);
                            foreach my $p (@peersForFS) {
                                $assignedSid{$peer->sid()} = $sidId;
                            }
                        }

                        my $expRO = $self->exportReadOnlyNameForSidAndDisk(
                            $sidId, $diskId, $peerConn->isSecondary()
                        );
                        my $svcRW = $self->runReadWriteNameForProductAndService(
                            $prodName, $service, $sidId, $diskId,
                            $peerConn->isSecondary()
                        );

                        my $step = "${fsPre}d$dr$diskId";
                        my $title;
                        my @commands1;
                        my @commands2;

                        #
                        # HANA -- this needs to be all hosts in the HANA cluster
                        #
                        foreach my $host (sort keys %$luns) {
                            my $lun = $luns->{$host};
                            push(@commands1, "\$ removevlun -f $vvname $lun $host");
                            push(@commands1, "SuccessString: (Issuing\\s+removevlun\\s+$vvname\\s+$lun\\s+$host|export\\s+not\\s+found)");
                        }
                        push(@commands1, "\$ sleep 5");

                        if($saveServiceExports) {
                            $title = "$vvname Backup";

                            my $isDr = $peerConn->isSecondary() || 0;
                            my $parent = $lastRestoreId;
                            $parent =~ s/^0+//;
                            $self->setParentDataset($parent);
                            my $oldDS=ariba::Ops::DatasetManager->new($parent);
                            my $oldExpRO = $oldDS->exportReadOnlyNameForSidAndDisk($sidId, $diskId, $peerConn->isSecondary() );
                            my $baseRW = $self->baseSnapshotNameForSidAndDisk($sidId, $diskId, $peerConn->isSecondary());

                            push(@basevvlist, "$sidId:$diskId:$baseRW:$isDr");

                            #
                            # this looks stupid, but we HAVE to check to see if
                            # this VV is already here... bad things happen if
                            # it is (such as broken backups).
                            #
                            push(@commands1, "\$ showvv $baseRW");
                            push(@commands1, "SuccessString: no\\s+vv\\s+listed");
                            push(@commands1, "\$ setvv -name $baseRW $vvname");
                            #
                            # CAREFUL -- this leading space is NECCESARY to
                            # group this in the same logical step as setvv
                            #
                            push(@commands1, " \$ showvv $baseRW");
                            push(@commands1, "ErrorString: no\\s+vv\\s+listed");
                            push(@commands1, "\$ creategroupsv -ro $baseRW:$expRO");
                            push(@commands1, "SuccessString: ($baseRW\\s+$expRO|Volume\\s+name\\s+$expRO\\s+in\\s+use)");
                            push(@commands1, "\$ creategroupsv $expRO:$svcRW");
                            push(@commands1, "SuccessString: ($expRO\\s+$svcRW|Volume\\s+name\\s+$svcRW\\s+in\\s+use)");
                        } else {
                            $title = "$svcRW Restore";
                            push(@commands1, "\$ removevv -f $vvname");
                            push(@commands1, "SuccessString: (Removing\\s+vv\\s+$vvname|VV\\s+$vvname\\s+not\\s+found)");
                            push(@commands2, "\$ creategroupsv $expRO:$svcRW");
                            push(@commands2, "SuccessString: ($expRO\\s+$svcRW|Volume\\s+name\\s+$svcRW\\s+in\\s+use)");
                        }
                        #
                        # this needs to be all hosts in HANA cluster
                        #
                        foreach my $host (sort keys %$luns) {
                            my $lun = $luns->{$host};
                            push(@commands2, "\$ createvlun -f $svcRW $lun $host");
                            #
                            # CAREFUL -- this leading space is NECCESARY to
                            # group this in the same logical step as createvlun
                            #
                            push(@commands2, " \$ showvlun -host $host -l $lun");
                            push(@commands2, "SuccessString: $svcRW");
                        }

                        my $parCt = 1;
                        my $parDep = "group:${fsPre}RemoveLunGrp";
                        while(my $cmd = shift(@commands1)) {
                            my $subtitle = "";
                            if($cmd =~ /^\$\s+([^\s]+)/) {
                                $subtitle = "(" . $1 . ") ";
                            }
                            push(@restoreVVSteps, defineStep("${step}$parCt", "$subtitle$title",
                               $parDep, $expando, "3par", undef, 20, 30));
                            $parDep = "${step}$parCt";
                            my @actionCmds = ();
                            push(@actionCmds, $cmd);
                            while($commands1[0] && $commands1[0] !~ /^\$/) {
                                my $check = shift(@commands1);
                                push(@actionCmds, $check);
                            }
                            push(@restoreVVSteps, defineAction($parAction, $svcNM->hostname(),
                                @actionCmds));
                            push(@restoreVVSteps, "\n");
                            $parCt++;
                        }

                        while(my $cmd = shift(@commands2)) {
                            my $subtitle = "";
                            if($cmd =~ /^\$\s+([^\s]+)/) {
                                $subtitle = "(" . $1 . ") ";
                            }
                            push(@restoreVVSteps, defineStep("${step}$parCt", "$subtitle$title",
                               $parDep, $expando, "3par", undef, 20, 30));
                            $parDep = "${step}$parCt";
                            my @actionCmds = ();
                            push(@actionCmds, $cmd);
                            while($commands2[0] && $commands2[0] !~ /^\$/) {
                                my $check = shift(@commands2);
                                push(@actionCmds, $check);
                            }
                            push(@restoreVVSteps, defineAction($parAction, $dsNM->hostname(),
                                @actionCmds));
                            push(@restoreVVSteps, "\n");
                            $parCt++;
                        }
                    }

                    #
                    # HANA -- this needs to touch all the hosts too
                    #
                    my $count = 0;
                    print MCL defineRunGroup("${fsPre}RemoveLunGrp", 1);

                    foreach my $host (sort keys %lunsForDiskGroup) {
                        $count++;
                        my $lunList = join(',',@{$lunsForDiskGroup{$host}});
                        my $removeLunCommand = "\$ sudo /usr/local/ariba/bin/filesystem-utility removeluns -l $lunList";

                        print MCL defineStep("${fsPre}c$count", "Remove OS LUNs for $fs on $host",
                            $depends, $expando, "${fsPre}RemoveLunGrp", undef, undef, undef);
                        print MCL defineAction("Shell", "$USER\@${host}.ariba.com",
                            $removeLunCommand
                        );
                        print MCL "\n";
                    }

                    #
                    # insert the VV restore steps here
                    #
                    foreach my $text (@restoreVVSteps) {
                        print MCL $text;
                    }
                    $depends = "group:3par";

                    if($peer->peerType() eq 'oracle') {
                        print MCL defineStep("${fsPre}e", "Online $fs on $exportHost",
                            $depends, $expando, "scsiRescan", undef, undef, undef);
                        print MCL defineAction("Shell", "$USER\@$exportHost",
                            "\$ sudo /usr/local/ariba/bin/filesystem-utility scanonline -g $diskGroup",
                        );
                        print MCL "\n";
                        $depends = "${fsPre}e";

                        print MCL defineStep("${fsPre}f", "Mount $fs on $exportHost",
                            $depends, $expando, $group, undef, undef, undef);
                        print MCL defineAction("Shell", "$USER\@$exportHost",
                            "\$ sudo mount /$volumeName",
                        );
                        print MCL "\n";
                    } else {
                        my @activeLuns = $peerConn->activeLunsOnHost($svcNM);
                        my $lunArg = join(',',@activeLuns);
                        print MCL defineStep("${fsPre}e", "Rescan SCSI for $fs on $exportHost",
                            $depends, $expando, "scsiRescan", undef, undef, undef);
                        print MCL defineAction("Shell", "$USER\@$exportHost",
                            "\$ sudo /usr/local/ariba/bin/filesystem-utility loadhanadisks -l $lunArg",
                        );
                        print MCL "\n";
                        $depends = "${fsPre}e";

                        #
                        # instant restore changes the mapper id... UGH
                        #
                        my $diskName;
                        foreach my $pc ($peer->allPeerConnections()) {
                            foreach my $peerfs ($pc->dbFsInfo()) {
                                next unless($peerfs->fs() eq $fs);
                                $diskName = $peerfs->diskName();
                                $diskName =~ s|^/dev/mapper/||;
                                last;
                            }
                            last if($diskName);
                        }

                        my $lunNumber;
                        foreach my $vlun (@{$vlunsForFS{$filesystem->fs()}}) {
                            foreach my $ex ($vlun->exports()) {
                                if($ex->host() eq $exportHost) {
                                    $lunNumber = $ex->lun();
                                    last;
                                }
                            }
                        }

                        unless($peer->primary()->isClustered()) {
                            my $commandArgs = "mountmultipath -l $lunNumber -v /$volumeName";
                            print MCL defineStep("${fsPre}f$count", "Mount $fs on $exportHost",
                                $depends, $expando, $group, undef, undef, undef);
                            print MCL defineAction("Shell", "$USER\@$exportHost",
                                "\$ sudo /usr/local/ariba/bin/filesystem-utility $commandArgs"
                            );
                            print MCL "\n";
                        }
                    }

                    $fsPre++;
                }
            }
        }

        #
        # Update WWIDs in config files for hana, multipath.conf
        #
        # XXX do it HERE -- run group is hanaConfig
        #

        my $cmdBase = "sudo /usr/local/ariba/bin/filesystem-utility updatehana";
        my $expando = undef;
        foreach my $peer (@peersFromProduct) {
            next unless($peer->peerType() eq 'hana');
            my $sid = $peer->sid();
            my @dep;

            foreach my $peerConn ($peer->allPeerConnections()) {
                foreach my $fs ($peerConn->dbFsInfo()) {
                    next if($fs->fs() =~ /log/); # skip log vols
                    my $volumeName = $fs->fs();    $volumeName =~ s|^/||;
                    my $exportHost = $fs->host();
                    $exportHost =~ s/\.ariba\.com$//;
                    push(@dep, "group:RS$volumeName$exportHost");
                }
            }
            my $depends = join(" ", @dep);
            my $group = "hanaConfig";

            my $counter = 1;
            foreach my $pc ($peer->allPeerConnections()) {
                my $host = $pc->host();
                my $map = $pc->diskToLunMapForHost($dsNM, $host);
                my @commands;
                foreach my $lun (sort(keys(%$map))) {
                    my $disk = $map->{$lun};
                    push(@commands, "\$ $cmdBase -l $lun -s $sid -i $disk");
                }
                if(scalar(@commands)) {
                    unless($expando) {
                        $expando = "EXPhanaCfg";
                        print MCL defineExpando($expando, "Update Multipath WWIDs in Config");
                    }
                    my $stepname = "UH$counter"; $counter++;
                    print MCL defineStep($stepname, "Update Multipath Configs on $host",
                        $depends, $expando, $group, undef, undef, undef,
                    );
                    print MCL defineAction("Shell", "$USER\@$host",
                        @commands,
                    ),"\n";
                }
            }
        }

        #
        # file systems restored, restore archive logs (if any), and restart DBs
        #
        $sidPre = "0";
        foreach my $peer (@peersFromProduct) {
            $sidPre++;
            my @dep;
            foreach my $peerConn ($peer->allPeerConnections()) {
                next unless($peerConn);
                foreach my $fs ($peerConn->dbFsInfo()) {
                    next if($fs->fs() =~ /log/); # skip log vols
                    my $volumeName = $fs->fs();    $volumeName =~ s|^/||;
                    my $exportHost = $fs->host();
                    $exportHost =~ s/\.ariba\.com$//;
                    push(@dep, "group:RS$volumeName$exportHost");
                }
            }

           ####=============================================================================####
           # Skipping below hanaConfig group MCL step as HANA doesn't support thin backup
           ####=============================================================================####
           ## if($peer->peerType() eq 'hana') {
           ##     push(@dep, "group:hanaConfig");
           ## }

            my $depends = join(" ", @dep);
            my $SID = $peer->primary()->sid();

            my $expando = "${SID}Start";
            my $group = "start$SID";
            print MCL defineExpando($expando, "Start $SID");
            print MCL defineRunGroup($group,1);

            if(!$saveServiceExports && $peer->peerType() eq 'oracle') {
                my %volumes;
                foreach my $p ($peer->primary(), $peer->secondary()) {
                    next unless($p);
                    foreach my $fs ($p->dbFsInfo()) {
                        next if($fs->fs() =~ /log/); # skip log vols
                        $volumes{$fs->fs()} = 1;
                    }
                }
                my $restoreArchiveLogs = $self->restoreArchiveLogsMCL($SID, sort(keys(%volumes)));
                if($restoreArchiveLogs) {
                    print MCL defineStep("${sidPre}e", "Restore Archive Logs for $SID",
                        $depends, $expando, $group, undef, undef, undef);
                    print MCL "$restoreArchiveLogs\n";
                    $depends = "${sidPre}e";
                }
            }

            if(!$saveServiceExports && $peer->peerType() eq 'hana') {
                # HANA -- restore logs here
                my $archiveDir = ariba::Ops::Constants->archiveManagerArchiveDir();
                $archiveDir .= "/" . $self->instance();

                my $count = 1;
                my @tarDepends;
                foreach my $pc ($peer->allPeerConnections()) {
                    my $tarFile = "$archiveDir/hanalogs-" . $pc->host() . "-" . $peer->sid() . ".tar.gz";
                    next unless( -r $tarFile );

                    my $logsDir;
                    my $diskName;
                    my $dbhost = $pc->host();
                    foreach my $filesystem ($pc->dbFsInfo()) {
                        next unless($filesystem->fs() =~ /log/); # get the log volume
                        $logsDir = $filesystem->fs();
                        $diskName = $filesystem->diskName();
                        last;
                    }

                    my @hanaCommands = (
                        "\$ sudo rm -rf --one-file-system $logsDir/*",
                        "\$ sudo tar zxpf $tarFile -C $logsDir .",
                    );

                    if($peer->primary->isClustered()) {
                        #
                        # clustered hana unmounts the FS on shutdown, so we
                        # need to mount/umount it to backup the archive logs
                        #
                        push(@hanaCommands, "\$ sudo umount $logsDir");
                        unshift(@hanaCommands, "\$ sudo mount -t xfs $diskName $logsDir");
                    }

                    print MCL defineStep("${sidPre}e$count", "Restore Archive Logs for $SID\@" . $pc->host(),
                        $depends, $expando, $group, undef, undef, undef);
                    print MCL defineAction("Shell", "$MONUSER\@$dbhost",
                        @hanaCommands
                    ),"\n";
                    push(@tarDepends, "${sidPre}e$count");
                    $count++;
                }
                $depends = join(" ", @tarDepends);
            }

            my $count = 1;
            foreach my $peerConn ($peer->primary(), $peer->secondary()) {
                next unless($peerConn);
                my $dbhost = $peerConn->host();
                if($peer->peerType() eq 'hana') {
                    # HANA -- start Hana here
                    my $hanauser = lc($peerConn->sid()) . "adm";

                    print MCL defineStep("${sidPre}f${count}", "Start $SID on $dbhost",
                        $depends, $expando, $group, undef, undef, undef);
                    print MCL defineAction("Shell", "$MONUSER\@$dbhost",
                        # "\$ /usr/local/ariba/bin/hana-control -s $hanauser -n -d start -readMasterPassword",
                        "\$ /usr/local/ariba/bin/hana-control -s $hanauser -n -d start -readMasterPassword",
                    );
                    print MCL "\n";
                    $depends = "${sidPre}f${count}";
                    $count++;

                    foreach my $slave ($peerConn->standbyNodes(), $peerConn->slaveNodes()) {
                        next unless($slave);
                        my $slavehost = $slave->host();
                        print MCL defineStep("${sidPre}f${count}", "Start $SID on $slavehost",
                            $depends, $expando, $group, undef, undef, undef);
                        print MCL defineAction("Shell", "$MONUSER\@$slavehost",
                            # "\$ /usr/local/ariba/bin/hana-control -s $hanauser -n -d start -readMasterPassword",
                            "\$ /usr/local/ariba/bin/hana-control -s $hanauser -n -d start -readMasterPassword",
                        );
                        print MCL "\n";
                        $depends = "${sidPre}f${count}";
                        $count++;
                    }
                } else {
                    print MCL defineStep("${sidPre}f$count", "Start $SID on $dbhost",
                        $depends, $expando, $group, undef, undef, undef);
                    print MCL defineAction("Shell", "$MONUSER\@$dbhost",
                        "\$ /usr/local/ariba/bin/database-control -n -d start $SID -readMasterPassword",
                    );
                    print MCL "\n";
                    $depends = "${sidPre}f$count";
                    $count++;
                }
            }

            if($peer->peerType() eq 'oracle') {
                my $dbhost = $peer->primary()->host();
                if($dbhost !~ /^tansy/) {
                    print MCL defineStep("${sidPre}g1", "Run stats cleanup for $SID",
                        $depends, $expando, $group, undef, undef, undef);
                    print MCL defineAction("Oracle", "$SID\@$dbhost",
                        "\$ \@ /home/archmgr/sql/fixed_stats.sql",
                        "Timeout: undef",
                    ),"\n";
                    $depends = "${sidPre}g1";
                }

                if($peer->secondary()) {
                    print MCL defineStep("${sidPre}g2", "Start Dataguard for $SID",
                        $depends, $expando, $group, undef, undef, undef);
                    print MCL defineAction("Perl", undef,
                        "Database::startDataguard('$SID','" . $product->name() . "','" . $product->service() . "','" . $product->buildName() . "')",
                    );
                    print MCL "\n";
                    $depends = "${sidPre}g2";
                }

                print MCL defineStep("${sidPre}h", "Resume Archive Log Deletion for $SID",
                    $depends, $expando, $group, undef, undef, undef);
                print MCL defineAction("Perl", undef,
                    "Database::resumeArchiveLogDeletion('$SID','" . $product->name() . "','" . $product->service() . "','" . $product->buildName() . "')",
                );
                print MCL "\n";
                $depends = "${sidPre}h";

                #
                # create DB link to secondary if needed (used for DG monitoring)
                #
                if($peer->secondary()) {
                    my $dbhost = $peer->primary()->host();

                    my $testVar = "${SID}HasDBLink";
                    print MCL defineVariable($testVar, 0),"\n";

                    print MCL defineStep("${sidPre}i", "Check for DB Link",
                        $depends, $expando, $group, undef, undef, undef,
                        "StoreSuccess: $testVar\n",
                    );
                    print MCL defineAction("Oracle", "$SID\@$dbhost",
                        "\$ select count(*) from dba_db_links where owner = 'PUBLIC' and db_link = 'DG_STANDBY.WORLD';",
                        'SuccessString: ^\s*0\s*$',
                    ), "\n";
                    $depends = "${sidPre}i";
                    my $link = uc($SID) . "_B";

                    print MCL defineStep("${sidPre}j", "Drop DB Link (if needed)",
                        $depends, $expando, $group, undef, undef, undef,
                        "ExecuteUnless: $testVar\n",
                    );
                    print MCL defineAction("Oracle", "$SID\@$dbhost",
                        "\$ drop public database link dg_standby;",
                    ), "\n";
                    $depends = "${sidPre}j";

                    print MCL defineStep("${sidPre}k", "Create DB Link to DR",
                        $depends, $expando, $group, undef, undef, undef);
                    print MCL defineAction("Oracle", "$SID\@$dbhost",
                        "\$ create public database link dg_standby connect to system identified by PASSWORD:system using '${link}';",
                    ), "\n";
                    $depends = "${sidPre}k";
                }
            }
        }

        if ( $hanaTenantImpExp ){
            my $group = "hanaexportimport";
            my $hanaDirPath = ariba::Ops::Constants->archiveManagerArchiveDir() . "/$datasetId" . "/hana";

            if($saveServiceExports) {
                mkdirWithPermission($hanaDirPath);
                unless( -d $hanaDirPath ){
                    $logger->error("Failed to create dir $hanaDirPath\n");
                    $lock->release();
                    return 0;
                }

                ## Hana tenant Export - write MCL steps
                my $action = "backup";
                my $expando = "hana".$action;
                print MCL defineExpando($expando, "HANA $action");

                my $group = "hanaexportimport";
                print MCL defineRunGroup($group,8);

                for my $type (keys %$DBNames){
                    for my $value (@{$DBNames->{$type}}){
                        my $dbName = $value->{dbName};
                        my $hostPort = $value->{hostPort};
                        my $filePrefix = $hanaDirPath."/".$dbName;
    
                        print MCL defineStep("B$dbName","Run Hana Backup for $dbName",undef,$expando,undef,undef,undef,undef);
                        print MCL defineAction("Shell", undef,
                             "\$ /usr/local/ariba/bin/hana-backup-restore $action -s $service -hp $hostPort -f $filePrefix -readMasterPassword",
                             'SuccessString: .*?Successfully.*',
                        );
                        print MCL "\n";
                    }
                }
            } else{
                ## Hana tenant restore - write MCL Steps
                my $action = "restore";
                my $expando = "hana".$action;
                print MCL defineExpando($expando, "HANA $action");
    
                my $group = "hanaexportimport";
                print MCL defineRunGroup($group,8);

                my $hanaDBTypes = {};
                for my $type (keys %$DBNames) {
                    unless( $hanaDBTypes->{$type} ) {
                        my @dbs = $self->getHanaDBTypes($type);
                        $hanaDBTypes->{$type} = \@dbs;
                    }
                    for my $value (@{$DBNames->{$type}}){
                        my $hostPort = $value->{hostPort};
                        my $targetDBName = $value->{dbName};
                        my ($sourceDBName,$sourceDBVersion) = split(/:/,shift(@{$hanaDBTypes->{$type}}));
                        my $depends="";
                        my $version = $value->{dbVersion};
                        ## MCL to stop Target DB before restore - only for HANA 2.xxx version
                        if ( $version >= 2 ){
                            print MCL defineStep("S$targetDBName","Stop Hana DB($targetDBName) for Restore",undef,$expando,undef,undef,undef,undef);
                            print MCL defineAction("Shell", undef,
                                "\$ /usr/local/ariba/bin/hana-backup-restore stop -s $service -hp $hostPort -v $version -db $targetDBName -readMasterPassword",
                                'SuccessString: .*?Successfully.*',
                            );
                            print MCL "\n";
                            $depends = "S$targetDBName";
                        }

                        ## MCL to restore hana DB
                        my $filePrefix = "$hanaDirPath/$sourceDBName";
                        print MCL defineStep("R$targetDBName","Run Hana Restore for $targetDBName",$depends,$expando,undef,undef,undef,undef);
                        print MCL defineAction("Shell", undef,
                            "\$ /usr/local/ariba/bin/hana-backup-restore $action -s $service -hp $hostPort -v $version -db $targetDBName -f $filePrefix -readMasterPassword", 
                            'SuccessString: .*?Successfully.*',
                        );
                        print MCL "\n";
                    }
                }
            }
        }
        close(MCL);

        #
        # This clears any previous state out from a previous restore to this
        # dataset.
        #
        system("/bin/rm -rf /var/mcl/$mclname");

        if($saveServiceExports) {
            $self->setBaseVolumes(@basevvlist);

            my @sidmap;
            my @versions;
            foreach my $sid (keys %assignedSid) {
                next if($sid =~ /^versionOf/);
                push(@sidmap, $assignedSid{$sid} . ":$sid");
                push(@versions, $assignedSid{$sid} . ":" . $assignedSid{"versionOf$sid"});
            }
            @sidmap = sort(@sidmap);
            @versions = sort(@versions);
            $self->setSidList(@sidmap);
            $self->setVersionList(@versions);

            if($self->isThinChild()) {
                $logger->info("Backup MCL completed successfully.");
            } else {
                $logger->info("Bootstrap completed successfully.");
            }
        } else {
            $logger->info("Restore MCL completed successfully.");
        }

        #
        # when we run the MCL, parallel steps will pull this object from the
        # PersistantObject cache, and be sharing the SAME ssh link if we
        # don't close this here.
        #
        if($svcNM->instance() ne $dsNM->instance()) {
            $svcNM->disconnect();
            ref($svcNM)->_removeObjectFromCache($svcNM);
        }
        $dsNM->disconnect();
        ref($dsNM)->_removeObjectFromCache($dsNM);
    }

    #
    # check to see if we have a 3par volume problem
    #
    # XXX -- this should be a machineDB record rather than hard coded
    # here.
    #
    my $parHost = $self->inserv();
    my $machine = ariba::Ops::Machine->new($parHost);
    my $dsNM = ariba::Ops::NetworkDeviceManager->newFromMachine($machine);
    my $maxVols;
    if($dsNM->hostname() =~ /inserv2\.opslab/) {
        $maxVols = 8150;
        $maxVols = 8050 if($saveServiceExports);
    } else {
        $maxVols = 16000; # inserv3 has more vvs allowed
    }
    my $vvCount = $dsNM->vvCount();
    # this is required -- otherwise we get bad exit codes later... blah
    $dsNM->disconnect();
    unless(defined($vvCount)) {
        $logger->error("Failed to check vv count on $parHost.");
        $logger->info("This is probably transient, and you should retry.");
        system("/bin/rm $mclfile");
        $lock->release();
        return(0);
    }
                
    $logger->info("Check: $parHost has $vvCount VVs...");
    if( $vvCount > $maxVols ) {
        $logger->error("$parHost does not have enough free VVs to safely complete this operation.");
        $logger->info("Contact the sysadmin team and ask them to clean up the 3par VVs");
        $logger->info("(remember to copy ask_ops\@ariba.com.");
        system("/bin/rm $mclfile");
        $lock->release();
        return(0);
    }

    if($saveServiceExports) {
        #
        # save here, before executing MCL -- this saves the meta data now
        # so that we don't lose it if we re-enter.
        #
        # this also allows parallel realm backup to work, since it will read
        # the current dataset state, and not clobber it with its write.
        #
        $self->recursiveSave() if($saveServiceExports);
    }

    my $oldDollarZero = $0;
    $0 = "mcl-control";
    my $mcl = ariba::Ops::MCL->new($mclname);
    my $ret;

    $mcl->recursiveSave();
    if(!$self->noui() && ariba::Ops::Utils::sessionIsInRealTerminal()) {
        #
        # real user session, use the UI control center, but force them to be
        # inside a screen session
        #
        # UNLESS the user asked for noui
        #
        unless(ariba::Ops::Utils::sessionIsInScreen()) {
            $logger->error("This operation requires you to be inside screen.");
            $logger->info("Start a screen session, and restart the command.");
            $lock->detach();
            return(0);
        }
        $ret = $mcl->controlCenter();
    } else {
        #
        # not a real user session, so run headless.  This CAN be brought up
        # in the UI if it fails.
        #
        $ret = $mcl->executeInParallel();
    }
    $mcl->recursiveSave();

    $0 = $oldDollarZero;

    #
    # we have to reload the dataset from disk... realm backup will write to
    # the backing store, so we have to pull in changes made there.
    #
    if($saveServiceExports) {
        $self->readFromBackingStore();
    }

    if($ret) {
        $lock->release();
        #
        # we also "remove" the MCL file when we've succeeded.
        #
        system("/bin/mv $mclfile $mclfile.last.success");
    } else {
        $lock->detach();
    }

    if( scalar( $mcl->stepFailures() ) ) {
        my $action = $saveServiceExports ? "backup" : "restore";
        $self->recordStatus('product' => $prodName, 'service' => $service,
            'action' => $action, 'status' => 'Failed', 'dataset' => $datasetId);
    }

    return $ret;
}

sub restoreFPC {
    my $self = shift;
    my $product = shift;

    ariba::Ops::Inserv::VolumeLun->setDir(ariba::Ops::Constants->archiveManagerMetaDataDir() . "/" . $self->instance());

    # We need to build the peers object with filesystem info so we can find out if the db has
    # lun layout has changed since the backup.
    my @peersFromProduct = ariba::Ops::DatabasePeers->newListFromProduct(
            $product,
            {
            'debug' => $self->debug(),
            'populateFsInfo' => 1,
            'skipDR' => $self->skipDR(),
            'skipTypes' => $self->skipTypes(),
            }
            );

    ## Exclude HANA from FPC
    @peersFromProduct = grep { $_->peerType() !~ /hana/i } @peersFromProduct;

    return unless @peersFromProduct;;

    unless( checkPeersForOpenFiles(@peersFromProduct) ) {
        $logger->error("There are open files on database volumes.\n");
        $logger->error("Contact the DBAs or sysadmins for assistance.\n");
        return(0);
    }

    # for the restore we build the db peer information from product again but don't set the isBackup variable
    # this ensures the restore backend POs don't overlap with the dataset backend POs.
    for my $dbPeers (@peersFromProduct) {

        unless ($self->checkVolumeLunMappingForDBPeers($dbPeers)) {
            #FIXME: we should set an attribute defining the peers to remap the luns
            $logger->error("Lun mappings for database volumes in the dataset don't match the running product.");
            $logger->error("This feature is not enabled yet, cannot proceed");
            return;
        }

        return unless $self->unMountPeerDatabases($dbPeers);

        $logger->info("Restoring filesystem snapshots for " . $self->sid());
        for my $peerConnection ($dbPeers->primary(), $dbPeers->secondary()) {
            next unless $peerConnection;

            # offline the veritas disks before removing the 3par lun exports
            unless ($peerConnection->onlineOfflineDisks("offline")) {
                $logger->error("Failed to offline disks");
                $logger->error($peerConnection->error()) if $peerConnection->error();
                return;
            }

            for my $filesystem ($peerConnection->dbFsInfo()) {

                my $inservHostname = $filesystem->inserv();
                my $machine = ariba::Ops::Machine->new($inservHostname);
                my $nm = ariba::Ops::NetworkDeviceManager->newFromMachine($machine, $self->shouldProxy());
                $nm->setDebug(1) if $self->debug() >= 2;
                my @virtualVols;

                # remove the luns exports
                unless ($self->removeExportsForFilesystem($nm, $filesystem)) {
                    $logger->error("Failed to remove 3par vlun exports for " . $filesystem->fs());
                    return;
                }

                # promote the snapshot to the base volume
                $logger->debug("Promoting snapshots for " . $filesystem->fs());
                for my $vvName ($filesystem->vvList()) {
                    push(@virtualVols, $nm->virtualVolumesByName($vvName));
                }
                if ($self->testing()) {
                    $logger->debug("Would promote snapshot for vvlist: " . join(",", $filesystem->vvList()));
                } else {
                    unless ($nm->promoteSnapCopyForVirtualVolumes(\@virtualVols, $self->fpcId(), $logger)) {
                        $logger->error("3par promote for vvlist " . join(",", $filesystem->vvList()) . " failed");
                        $logger->error($nm->error()) if $nm->error();
                        return;
                    }
                }

                # re-export the basevolume vluns
                unless ($self->createExportsForFilesystem($nm, $filesystem)) {
                    $logger->error("Failed to restore 3par vlun exports for " . $filesystem->fs());
                    return;
                }
            }

            unless ($peerConnection->onlineOfflineDisks("online")) {
                my $errorMessage = "Failed to online disks: ";
                $errorMessage .= $peerConnection->error() if $peerConnection->error();
                $logger->error($errorMessage);
                return;
            }
        }

        return unless $self->mountFilesystems($dbPeers);
        $self->restoreArchiveLogs($dbPeers->sid());
        return unless $self->startDatabase($dbPeers);


        $logger->info("Successfully restored filesystem snapshots for " . $self->sid());
    }

    return 1;
}

# We shouldn't use wildcards to remove vlun exports.  doing them one by one ensures
# we have accounted for all the exports before doing the promote.
sub createExportsForFilesystem {
    my $self = shift;
    my $nm = shift;
    my $filesystem = shift;

    return $self->updateExportsForFilesystem("create", $nm, $filesystem);
}

sub removeExportsForFilesystem {
    my $self = shift;
    my $nm = shift;
    my $filesystem = shift;

    return $self->updateExportsForFilesystem("remove", $nm, $filesystem);
}

sub updateExportsForFilesystem {
    my $self = shift;
    my $action = shift;
    my $nm = shift;
    my $filesystem = shift;

    for my $vlunFromDataset ($self->vlunsForFilesystem($filesystem)) {
        my $vvName = $vlunFromDataset->name();
        for my $export ($vlunFromDataset->exports()) {
            my $host = $export->host();
            my $lun = $export->lun();

            if ($action eq "create") {
                $logger->debug("Creating vlun: vv: $vvName, host: $host, lun: $lun");
                if ($self->testing) {
                    $logger->debug("DRYUN: Would create vun");
                } else {
                    unless ($nm->createVlun($vvName, $host, $lun)) {
                        $logger->error("Creating vlun: vv: $vvName, host: $host, lun: $lun failed: " . $nm->error());
                        return;
                    }
                }
            } elsif ($action eq "remove") {
                $logger->debug("Removing vlun: vv: $vvName, host: $host, lun: $lun");
                if ($self->testing) {
                    $logger->debug("DRYUN: Would remove vlun");
                } else {
                    unless ($nm->removeVlun($vvName, $host, $lun)) {
                        $logger->error("Removing vlun: vv: $vvName, host: $host, lun: $lun failed." . $nm->error());
                        return;
                    }
                }
            }
        }
    }
    return 1;
}

sub vlunsForFilesystem {
    my $self = shift;
    my $filesystem = shift;

    my @matchedVluns;
    for my $vlun ($self->vluns()) {
        # fault in the all the vluns so the grep works below
        for my $export ($vlun->exports()) {
            $export->host();
        }
        next unless $vlun->fs() eq $filesystem->fs();
        next unless grep($_->host() eq $filesystem->host(), $vlun->exports());
        push(@matchedVluns, $vlun);
    }

    return @matchedVluns;
}

sub checkVolumeLunMappingForDBPeers {
    my $self = shift;
    my $dbPeers = shift;

    for my $peerConnection ($dbPeers->primary(), $dbPeers->secondary()) {
        next unless $peerConnection;
        for my $filesystem ($peerConnection->dbFsInfo()) {
            my $inservHostname = $filesystem->inserv();
            unless ($inservHostname) {
                my $peerPosition = $peerConnection->isSecondary() ? "secondary" : "primary";
                $logger->error("$peerPosition for " . $dbPeers->sid() . " does not have inservHostname set.  There may Veritas problems on the database host.");
                return 0;
            }
            my $machine = ariba::Ops::Machine->new($inservHostname);
            my $nm = ariba::Ops::NetworkDeviceManager->newFromMachine($machine, $self->shouldProxy());
            $nm->setDebug(1) if $self->debug() >= 2;

            my @vvList = $filesystem->vvList();
            my @vlunsFromRunningProduct = $nm->vLunsforVirtualVolumesOfFilesystem({ 'vvlist' => \@vvList, 'fs' => $filesystem->fs() });

            for my $vlunFromDataset ($self->vlunsForFilesystem($filesystem)) {

                # fault in the all the vluns so the grep works below
                for my $export ($vlunFromDataset->exports()) {
                    $export->host();
                }

                if (!grep($_->name() eq $vlunFromDataset->name(), @vlunsFromRunningProduct)) {
                    $logger->warn($vlunFromDataset->name() . " not found in active product. ");
                    return 0;
                }
            }

            for my $vlunFromProduct (@vlunsFromRunningProduct) {
                my ($vlunFromDataset) = grep($_->name() eq $vlunFromProduct->name(), $self->vluns());

                unless ($vlunFromDataset) {
                    # the filesystem has been grown
                    $logger->warn($vlunFromProduct->name() . " not found in dataset.");
                    return 0;
                }

                $logger->debug($vlunFromProduct->name() . " found in both current product and dataset LUN topology");

                for my $export ($vlunFromProduct->exports()) {

                    unless ($export->host() eq $filesystem->host()) {
                        $logger->warn("Skipping export checks on " . $export->host());
                        next;
                    }

                    my ($exportFromDataset) = grep($_->host() eq $export->host(), $vlunFromDataset->exports());

                    unless ($exportFromDataset) {
                        $logger->warn($vlunFromProduct->name() . " was exported to " . $export->host() . " but is no longer");
                        return 0;
                    }

                    $logger->debug($vlunFromProduct->name() . " exported to " . $export->host() . " in both current product and dataset LUN topology");
                }
            }
        }
    }

    return 1;
}

sub runSQLCleanup {
    my $self = shift;
    my $product = shift;
    my $sid = shift;
    my $schemaName = shift;
    my $oc = shift;
    my $schemaType = shift;

    # FIXME: get this automatically somehow.  Maybe make a generic drop objects sql and check
    # it into the ops tree??
    # Drop all the objects from the target db schema
    # AN should call //ariba/network/branch/AN/10S2/network/service/common/sql/developer_eradicate_account.sql
    # S4 should call $installDir/internal/lib/sql/drop-db-objects.sql

    my @cleanSchemaSqlScripts;
    if ( ! defined $self->productName() ) {
        logger->error("productName attribute not set, cannot determine which clean script to run");
    } elsif ( $self->productName() eq "an" ) {
        @cleanSchemaSqlScripts = (
            "1:" . $product->installDir() . "/lib/sql/an/scripts/developer_eradicate_account.sql",
        );
        if($schemaType eq "main") {
            $logger->info("Will run create_person_table.sql on $schemaName\@$sid ($schemaType).");
            push(@cleanSchemaSqlScripts, "0:" . $product->installDir() . "/lib/sql/an/scripts/create_person_table.sql");
        } else {
            $logger->info("Not running create_person_table.sql on $schemaName\@$sid ($schemaType).");
        }
    } elsif( grep { $_ eq $product->name() } ariba::rc::Globals::sharedServicePlatformProducts() ) {
        @cleanSchemaSqlScripts = (
            "1:" . $product->installDir() . "/lib/sql/drop-db-objects.sql",
        );
    } else {
        # nothing to do, return success
        $logger->info("No SQL to be run for " . $product->name() . "... returning.");
        return 1;
    }

    foreach my $script (@cleanSchemaSqlScripts) {
        my ( $required, $cleanSchemaSqlScript ) = split(/:/, $script);
        unless ( -e $cleanSchemaSqlScript ) {
            if($required) {
                $logger->error("$cleanSchemaSqlScript does not exist.  Cannot clean database objects before the import");
                return 0;
            } else {
                $logger->info("$cleanSchemaSqlScript does not exist.  Skipping.");
                next;
            }
        }

        $logger->info("Cleaning schema $schemaName\@$sid using $cleanSchemaSqlScript");
        if ($self->testing()) {
            $logger->debug("DRYRUN: would run $cleanSchemaSqlScript using ariba::Ops::OracleClient::executeSqlFile()");
        } else {
            unless ($oc->executeSqlFile($cleanSchemaSqlScript)) {
                $logger->error("Failed to run $cleanSchemaSqlScript: " . $oc->error());
                return 0;
            }
        }
    }

    return 1;
}

sub restoreDBSchema {
    my $self = shift;
    my $dbExportId = shift;
    my $sid = shift;
    my $schemaName = shift;
    my $password = shift;
    my $host = shift;
    my $product = shift;
    my $targetDbc = shift;

    if ($host =~ /hana/) {
        $self->restoreDBSchemaFromHana($dbExportId, $schemaName, $password, $host, $product, $targetDbc);
    }
    else {
      $self->restoreDBSchemaFromOracle($dbExportId, $sid, $schemaName, $password, $host, $product);
    }
}

sub restoreDBSchemaFromHana {

    require ariba::DBA::HanaSampleSQLQueries;

    my $self = shift;
    my $dbExportId = shift;
    my $schemaName = shift;
    my $password = shift;
    my $passedhost = shift;
    my $product = shift;
    my $targetDbc = shift;
    my $instance = $self->instance();
    my $srcSchema = $self->schemaName($dbExportId);
    my $port = $targetDbc->port();

    my $importDirPath = ariba::Ops::Constants->archiveManagerArchiveDir() . "/$instance" . "/hana"; 
    my $dirPath = getServiceDir($product);
    unless ( -d $dirPath ){
        $logger->info("dirPath: $dirPath not exist");
        return 0;
    }
    if($self->testing()) {
        $logger->info("restoreDBSchemaFromHana: no DEBUG/dry run/testing output enabled");
        return 0;
    }
    eval {
        my $mon = ariba::rc::InstalledProduct->new('mon', $product->service());
        ##my $hc = ariba::Ops::HanaClient->new($schemaName, $password, $passedhost,'30015');
        my $hc = ariba::Ops::HanaClient->new($schemaName, $password, $passedhost,$port);
        # only run the restore on the master, per Jira-ID: HOA-4243
        # OLD CODE my $host = ariba::DBA::HanaSampleSQLQueries::whoIsMaster( $mon, $targetDbc);
        my $masterHost = eval {
            my $user = $mon->default("dbainfo.hana.system.username");
            my @rows = $hc->executeSqlByFile('select host,INDEXSERVER_ACTUAL_ROLE from m_landscape_host_configuration', user => $user, password => $mon->default("dbainfo.hana.system.password"));
            foreach my $row (@rows) {
                my ($hostname,$role) = split(' ', $row);
                print "\$hostname=$hostname \$role=$role\n";
                if($role eq 'MASTER') {
                    my $ret = `host $hostname|awk '{print \$1}'`;
                    chomp $ret;
                    return $ret if $ret =~ $hostname;
                    return $hostname;
                }
            }
            return $passedhost;
        };
        $hc->{host} = $masterHost;
        #die 'connect failed: ' . $hc->error() unless $hc->connect(5,5);  #we no longer connect()
        $hc->{connected} = 1; #fake this because we didn't call connect()
        die 'dropTablesForImport failed' . $hc->error() unless $hc->dropTablesForImport();
        die 'dbImport failed' . $hc->error() unless $hc->dbImport($schemaName, $importDirPath, $srcSchema, $dirPath);
    };
    if($@) {
        $logger->error("exception: $@");
        return undef;
        #something
    }
    return 1;
}

sub getServiceDir{
    my $product = shift;
    my $productName = $product->name();
    my $service =$product->service();

    my $serviceDir;
    if (ariba::rc::Globals::isPersonalService($service)) {
        $service =~ s/personal_//g;
        $serviceDir = ariba::rc::Globals->HOMEPREFIX.'/'.$service;
    }else{
        my $serviceDirTmp = ariba::rc::Globals::rootDir($productName, $service);
        $serviceDir = substr($serviceDirTmp,0,rindex($serviceDirTmp,'/'));
    }
    return $serviceDir;
}

sub restoreDBSchemaFromOracle {
    my $self = shift;
    my $dbExportId = shift;
    my $sid = shift;
    my $schemaName = shift;
    my $password = shift;
    my $host = shift;
    my $product = shift;

    my $instance = $self->instance();

    unless ($self->schemaName($dbExportId)) {
        $logger->error("There is no schema backup for backup ID '$dbExportId' in this dataset");
        return;
    }
    my $sourceSchema = $self->schemaName($dbExportId);
    my $sourceFile = $self->exportFile($dbExportId);
    my $schemaType = $self->schemaType($dbExportId);
    my $sourceTableSpace = $self->getTableSpaceName($dbExportId);

    my $oc = ariba::Ops::OracleClient->new($schemaName, $password, $sid, $host);
    $oc->setDebug(1) if $self->debug() >= 2;
    if ( !$oc->connect() ) {
        $logger->error("Connection to $schemaName\@$sid failed: [" . $oc->error() . "].");
        return;
    }

    if (!$self->testing() && $self->numOfConnectionsToSchema($sid, $schemaName, $password, $host) != 0) {
        $logger->error("Can't run import.  There are active connections to $schemaName\@$sid");
        return;
    }

    unless ( $self->runSQLCleanup($product, $sid, $schemaName, $oc, $schemaType) ) {
        return 0;
    }

    my $now = DateTime->now();
    my $uniqueLogID = $product->buildName() . "-" . $product->service() . "_" . $now->ymd('-') . "_" . $now->hms('.');

    my %exportImportParamHash;

    ## Turn off import logging so we don't write to /home/archmgr for restores
    #$exportImportParamHash{'LOG'} = ariba::Ops::Constants->archiveManagerArchiveDir() . "/$instance/$uniqueLogID-$sourceFile.imp.log";

    # Do the import
    if ($self->testing()) {
        $logger->debug("DRYRUN: would import $sourceFile into $schemaName\@$sid.");
    } else {

        # Must keep this reference alive until the import is done; the
        # file will be removed by the destructor
        my $mappedDumpFile;
        if ($self->mapTablespace()) {
            unless ($oc->connect()) {
                $logger->error("Failed to connect to $schemaName\@$sid to check tablespaces: " . $oc->error());
                return;
            }
            my @tablespaces = $oc->executeSql("select tablespace_name from user_tablespaces");
            $oc->disconnect();

            $logger->debug("Found the following tablespaces in target account $schemaName\@$sid: [ " . join(", ", @tablespaces) . " ]");

            if (scalar @tablespaces < 1) {
                $logger->warn("Found no tablespaces in $schemaName\@$sid, that doesn't make any sense");
            } elsif (scalar @tablespaces > 1) {
                $logger->info("Found more than one tablespace in the target account, no mapping will be performed");
            } else {
                my $tsName = $tablespaces[0];
                $logger->info("Mapping all tablespaces in the dump file to '$tsName'");
                eval {
                    $mappedDumpFile = mapImportFileToTablespace($exportImportParamHash{'FILE'}, $tsName);
                };
                if ($@) {
                    $logger->error($@);
                    return;
                }
                $logger->info("Finished mapping tablespace names");
                $exportImportParamHash{'FILE'} = $mappedDumpFile->filename();
            }
        }

        my $dataPump = $self->ExportTypeOracle();
        my $dirObjName = $self->getOracleDirObj($oc,'impdp');
        my $importFileFullPath = ariba::Ops::Constants->archiveManagerArchiveDir() . "/$instance/$sourceFile";
        if ($dataPump){
            my $targetTableSpace = $self->QueryForTableSpace($oc,$schemaName);
            $exportImportParamHash{'DUMPFILE'} =  $sourceFile;
            $exportImportParamHash{'REMAP_SCHEMA'} = $sourceSchema.':'.$schemaName;
            $exportImportParamHash{'DIRECTORY'} = $dirObjName;
            $exportImportParamHash{'LOGFILE'} = $sid."_"."$schemaName.impdp.log";
            my $grant = checkGrantExist($importFileFullPath);
            if ($grant){
                $exportImportParamHash{'EXCLUDE'} = 'GRANT';
            }
            if ( $sourceTableSpace && $targetTableSpace ){
                $exportImportParamHash{'REMAP_TABLESPACE'} = $sourceTableSpace.':'.$targetTableSpace;
            }
            $logger->info("Importing as Data Pump, since Exported DataSet is in Data Pump mode");
        } else {
            $exportImportParamHash{'FILE'} =  $importFileFullPath;
            $exportImportParamHash{'BUFFER'} = 1024000;
            $exportImportParamHash{'GRANTS'} = 'N';
            $exportImportParamHash{'TOUSER'} = $schemaName;
            $exportImportParamHash{'FROMUSER'} = $sourceSchema;
            $exportImportParamHash{'LOG'} = $sid."_"."$schemaName.imp.log";
            $logger->info("Importing as Conventional, since Exported DataSet is in Conventional mode");
        }

        if($self->productName() && $self->productName eq 'an') {
            $exportImportParamHash{'IGNORE'} = 'Y';
        }

        $oc->dbImport(\%exportImportParamHash,$dataPump);
        $self->dropObjDirectory($oc,$dirObjName);
        if ($oc->error()) {
            $logger->error("Running import of $sourceFile into $schemaName\@$sid failed: [" . $oc->error() . "].");
            return;
        }
        my $statSql = "EXECUTE DBMS_STATS.GATHER_SCHEMA_STATS(ownname =>'".$schemaName."',cascade=>TRUE,degree=>2);";
        unless ( $oc->executeSql($statSql)){
            $logger->error("Error: Failed to run statSql: $statSql: ".$oc->error());
        }
    }
    $logger->info("Successfull import of $sourceFile into $schemaName\@$sid");

    $oc->disconnect();

    return 1;
}

sub checkGrantExist{
    my $dmpFile = shift;

    $dmpFile .= '.expdp.log';
    my $cmd = "head -50 $dmpFile|grep -i OBJECT_GRANT"; 
    return executeLocalCommand($cmd);
}

sub dropObjDirectory{
    my $oc = shift;
    my $dirObjName = shift;

    my $dropSql = 'drop directory '.$dirObjName;
    if (my $dropRes = $oc->executeSql($dropSql)){
        die "Unable to drop $dirObjName by $dropSql: $dropRes\n";
    }
}

sub restoreDBRealmSubsetFromProduct {
    my $self = shift;
    my $product = shift;
    my $realmSubset = shift;

    $logger->info("Restoring schemas for realm subset " . join(", ", @$realmSubset));

    # First restore the default schema for the dataset; this is always
    # required and contains the realm -> schema mapping for the other
    # schemas.
    # Believe it or not, 0 is always the default schema from the source
    my $defaultSchemaExportId = 0;

    # This gets the default connection for the TARGET
    my $defaultDbc = ariba::Ops::DBConnection->connectionsForProductOfDBType($product, ariba::Ops::DBConnection::typeMain());
    unless ($defaultDbc) {
        $logger->error("Failed to get default database connection for product");
        return;
    }

    if ($self->testing()) {
        $logger->info("Would restore export ID $defaultSchemaExportId to " . $defaultDbc->user() . "\@" . $defaultDbc->sid() . " and do other stuff too");
        # Can't dryrun any further as the rest of the step depends on
        # having actually loaded the default schema
        return;
    }

    $logger->info("Restoring default schema (export ID $defaultSchemaExportId) to " . $defaultDbc->user() . "\@" . $defaultDbc->sid());
    # Always re-map tablespaces in case of personal service
    $self->setMapTablespace(1);
    unless ($self->restoreDBSchema($defaultSchemaExportId,
                                   $defaultDbc->sid(),
                                   $defaultDbc->user(),
                                   $defaultDbc->password(),
                                   $defaultDbc->host(), $product)) {
        $logger->error("Failed to restore default schema");
        return;
    }

    my %detailsForOldDefault = $self->detailsForSchemaBackupId($defaultSchemaExportId);
    my $oldDefaultOpsSchemaId = $detailsForOldDefault{SchemaId};

    my $OPS_TYPE_MAIN = ariba::Ops::DBConnection::typeMain();
    my $OPS_TYPE_MAIN_SS = ariba::Ops::DBConnection::typeMainStarShared();
    my $OPS_TYPE_MAIN_SD = ariba::Ops::DBConnection::typeMainStarDedicated();

    my $availableSchemas = {
        $OPS_TYPE_MAIN => { },
        $OPS_TYPE_MAIN_SS => { },
        $OPS_TYPE_MAIN_SD => { },
    };
    my $defaultSchemaName = $product->default("System.DatabaseSchemas.DefaultDatabaseSchema");
    my @availableTxn = grep { $_ ne "System.DatabaseSchemas.$defaultSchemaName" } $product->defaultKeysForPrefix("System.DatabaseSchemas.Transaction.Schema");
    map { s/^System\.DatabaseSchemas\.// } @availableTxn;
    $availableSchemas->{$OPS_TYPE_MAIN} = \@availableTxn;

    my @availableStarShared = $product->defaultKeysForPrefix("System.DatabaseSchemas.Star.Shared.Schema");
    map { s/^System\.DatabaseSchemas\.// } @availableStarShared;
    $availableSchemas->{$OPS_TYPE_MAIN_SS} = \@availableStarShared;

    my @availableStarDedicated = $product->defaultKeysForPrefix("System.DatabaseSchemas.Star.Dedicated.Schema");
    map { s/^System\.DatabaseSchemas\.// } @availableStarDedicated;
    $availableSchemas->{$OPS_TYPE_MAIN_SD} = \@availableStarDedicated;

    my $notEnoughSchemas = 0;
    my $schemasNeeded = {
        $OPS_TYPE_MAIN => { },
        $OPS_TYPE_MAIN_SS => { },
        $OPS_TYPE_MAIN_SD => { },
    };

    my $realmIdForName = {};
    my $newSchemaForOld = {};
    my $newOpsSchemaIdForOld = {
        $OPS_TYPE_MAIN => { },
        $OPS_TYPE_MAIN_SS => { },
        $OPS_TYPE_MAIN_SD => { },
    };
    my $schemasForOtherRealms = { };

    my $oc = ariba::Ops::OracleClient->newFromDBConnection($defaultDbc);
    $oc->setDebug(1);
    unless ($oc->connect()) {
        $logger->error("Failed to connect to default database!: [" . $oc->error() . "].");
        return;
    }

    my @result = $oc->executeSql("select st.realmid, st.schematype, st.isdedicated, st.databaseschema, rt.name from schematypemaptab st left outer join realmtab rt on st.realmid = rt.id");

    foreach my $row (@result) {
        my ($realmId, $schemaType, $schemaDedicated, $schemaName, $realmName) = split /\t/, $row;

        my $oldOpsSchemaId = ariba::Ops::DBConnection::_schemaIdForConnectionDict($schemaName);
        my $opsSchemaType;
        if ($schemaType eq "Star") {
            if ($schemaDedicated) {
                $opsSchemaType = $OPS_TYPE_MAIN_SD;
            } else {
                $opsSchemaType = $OPS_TYPE_MAIN_SS;
            }
        } elsif ($schemaType eq "Transactional") {
            $opsSchemaType = $OPS_TYPE_MAIN;
        }

        if ($realmId != -1) {
            $realmIdForName->{$realmName} = $realmId;
        }

        if ($opsSchemaType eq $OPS_TYPE_MAIN && $oldOpsSchemaId == $oldDefaultOpsSchemaId) {
            # Default schema from source is always mapped to the target default schema
            $newSchemaForOld->{$schemaName} = $defaultSchemaName;
        } else {
            # Otherwise map to any available schema of the appropriate type
            if (grep { $_ eq $realmName } @$realmSubset) {
                if (!$newSchemaForOld->{$schemaName}) {
                    my $newSchemaName = shift @{$availableSchemas->{$opsSchemaType}};
                    if (!$newSchemaName) {
                        $notEnoughSchemas = 1;
                        $schemasNeeded->{$opsSchemaType}->{$schemaName} = 1;
                        next;
                    }
                    $newSchemaForOld->{$schemaName} = $newSchemaName;

                    my $newOpsSchemaId = ariba::Ops::DBConnection::_schemaIdForConnectionDict($newSchemaName);
                    $newOpsSchemaIdForOld->{$opsSchemaType}->{$oldOpsSchemaId} = $newOpsSchemaId;
                }
            } else {
                my $schemas = $schemasForOtherRealms->{$realmName};
                unless ($schemas) {
                    $schemas = [];
                    $schemasForOtherRealms->{$realmName} = $schemas;
                }
                push @$schemas, $schemaName;
            }
        }
    }

    my $foundAllRealms = 1;
    foreach my $requestedRealm (@$realmSubset) {
        unless ($realmIdForName->{$requestedRealm}) {
            $logger->error("Failed to find realm $requestedRealm");
            $foundAllRealms = 0;
        }
    }
    unless ($foundAllRealms) {
        $logger->error("Failed to find all requested realms, aborting");
        return;
    }

    if ($notEnoughSchemas) {
        while (my ($type, $needed) = each %$schemasNeeded) {
            my $deficit = scalar keys %$needed;
            if ($deficit) {
                $logger->error("Unable to import realms; $deficit more schemas of type $type must be configured in Parameters.table");
            }
        }
        return;
    }

    my $surplusSchemas = undef;
    while (my ($schemaType, $schemas) = each %$availableSchemas) {
        if (scalar @$schemas) {
            $surplusSchemas += 1;
            foreach my $schemaName (@$schemas) {
                $logger->error("Schema $schemaName of type $schemaType is " .
                    "defined in Parameters.table but not used for any of imported relams. Please remove its definition.");
            }
        }
    }

    if ($surplusSchemas) {
        $logger->error("Unable to import realms; $surplusSchemas schemas are defined in Parameters.table but not used." .
            " Please remove their definitions.");
        return;
    }

    # Now, go through all the other (non-requested realms) and delete
    # those which rely on a schema that is not being imported.
    while (my ($realmName, $schemas) = each %$schemasForOtherRealms) {
        foreach my $schema (@$schemas) {
            unless ($newSchemaForOld->{$schema}) {
                $logger->info("Removing references to realm $realmName because it relies on schema $schema which is not being imported");
                delete $realmIdForName->{$realmName};
            }
        }
    }

    my $retainedRealmNames = join("', '", keys %$realmIdForName);
    $logger->info("The following realms will be retained: [ '$retainedRealmNames' ]");

    my $retainedRealmIds = join(", ", values %$realmIdForName);

    $oc->executeSql("delete from SchemaTypeMapTab where realmId > 0 and realmId not in ($retainedRealmIds)");
    $oc->executeSql("delete from RealmTab where id > 0 and id not in ($retainedRealmIds)");
    $oc->executeSql("delete from RealmProfileTab where rp_id > 0 and rp_id not in ($retainedRealmIds)");
    #delete dynamic fields for realms not being restored
    $oc->executeSql("delete from DynamicFieldMapTab where DynamicVariantName not in (select variant from realmtab where name in ('$retainedRealmNames'))");

    # Do the rename
    while (my ($oldName, $newName) = each %$newSchemaForOld) {
        $logger->info("Mapping schema $oldName from source dataset to $newName on target");
        $oc->executeSql("update SchemaTypeMapTab set databaseschema = '$newName' where databaseschema = '$oldName'");
    }

    # For S4 it is required to change few other tables:
    if ( defined $self->productName() && $self->productName() eq "s4") {

        $logger->info("Processing s4 specific schema re-mapping.");

        my $remapedOldSchemaNames = "'" . join ("' ,'", keys %$newSchemaForOld) . "'";
        $logger->info("The following old schemas will be remaped: [ $remapedOldSchemaNames ]");

        # Deletes schemas not being remaped schemas and some other stuff...
        $oc->executeSql("delete from AnalysisDBSchemaTab where ads_schemaname not in ($remapedOldSchemaNames)");
        $oc->executeSql("delete from AnalysisMultiRealmLoadTab where acs_schemaname not in ($remapedOldSchemaNames)");
        $oc->executeSql("delete from AnalysisMigrationLoadEntryTab where mlh_schemaname not in ($remapedOldSchemaNames)");
        cleanupAnalysisSchema($oc, $defaultDbc->user() . "\@" . $defaultDbc->sid());


        # Remap the ones that are being remaped
        while (my ($oldName, $newName) = each %$newSchemaForOld) {
            $oc->executeSql("update AnalysisDBSchemaTab set ads_schemaname = '$newName' where ads_schemaname = '$oldName'");
            $oc->executeSql("update AnalysisMultiRealmLoadTab set acs_schemaname = '$newName' where acs_schemaname = '$oldName'");
            $oc->executeSql("update AnalysisMigrationLoadEntryTab set mlh_schemaname = '$newName' where mlh_schemaname = '$oldName'");
        }
    }

    $oc->disconnect();


    my @retainedExportDBIds = ();
    my @retainedNewSchemaIds = ();
    foreach my $exportId ($self->getDBExportIds()) {

        if ($exportId eq $defaultSchemaExportId) {
            $logger->debug("Skipping export ID $exportId because it is the default schema and was already restored");
            next;
        }

        my %details = $self->detailsForSchemaBackupId($exportId);
        my $schemaType = $details{Type};
        my $oldSchemaId = $details{SchemaId};
        my $newSchemaId = $newOpsSchemaIdForOld->{$schemaType}->{$oldSchemaId};

        unless (defined $newSchemaId) {
            $logger->debug("Skipping export ID $exportId because it has no mapping");
            next;
        }

        push (@retainedExportDBIds, $exportId);
        push (@retainedNewSchemaIds, $newSchemaId);
    }

    my $restoreStatus = $self->restoreDBSchemasFromProduct($product, \@retainedExportDBIds, \@retainedNewSchemaIds);
    if ($restoreStatus) {
        $logger->error("Failed to restore exports " . join (", ", @retainedExportDBIds) . " for new schema targets " .
            join(", ", @retainedNewSchemaIds));
        return;
    }

    # Additional analysis cleanup for tx schemas
    for my $index (0 .. scalar(@retainedExportDBIds)-1)  {
        my $exportId = $retainedExportDBIds[$index];
        my $newSchemaId = $retainedNewSchemaIds[$index];

        my %details = $self->detailsForSchemaBackupId($exportId);
        my $schemaType = $details{Type};
        my $oldSchemaId = $details{SchemaId};

        # Additional analysis cleanup for tx schemas
        if ($schemaType eq $OPS_TYPE_MAIN) {
            $logger->info("Performing additional cleanup for exportid $exportId (type $schemaType) schema id $newSchemaId on target");

            my $dbc = ariba::Ops::DBConnection->connectionsForProductOfDBTypeAndSchemaId($product, $schemaType, $newSchemaId);
            unless ($dbc) {
                $logger->error("Failed to get DBConnection for type $schemaType id $newSchemaId");
                return;
            }

            $oc = ariba::Ops::OracleClient->newFromDBConnection($dbc);
            $oc->setDebug(1);
            unless ($oc->connect()) {
                $logger->error("Failed to connect to database on host " . $dbc->host() . ": ". $dbc->user() . "\@" . $dbc->sid());
                $logger->error("[".$oc->error()."].");
                return;
            }
            cleanupAnalysisSchema($oc, $dbc->user() . "\@" . $dbc->sid());

            $oc->disconnect();
        }
    }
    return 1;
}

sub cleanupAnalysisSchema {
    my $oc = shift;
    my $schemaName = shift;

    $logger->info("Doing additional analysis cleaning for schema $schemaName");

    $oc->executeSql("delete from AnalysisBgWorkStatusTab");
    $oc->executeSql("delete from AnalysisBgWorkTab");
    $oc->executeSql("delete from AnalysisBgWorkTaskStateTab");
    $oc->executeSql("delete from AnalysisRefreshWithPDWTab");
    $oc->executeSql("delete from AnalysisResetStateWorkTab");
    $oc->executeSql("delete from AnalysisSingleRealmDataLoadTab");
    $oc->executeSql("delete from AnalysisSingleRealmPLTab");
    $oc->executeSql("delete from AnalysisSwitchSchemasWorkTab");
    $oc->executeSql("delete from AnalysisTruncateAllWorkTab");
    $oc->executeSql("delete from AnalysisTruncateFactsWorkTab");
}

sub mapImportFileToTablespace {
    my $filename = shift;
    my $tablespace = shift;

    my $infile;
    open($infile, $filename)
        or die "open: $filename: $!";

    # Return the object to the caller; when caller lets it go out of
    # scope the file will be deleted.
    my $outfile = new File::Temp(SUFFIX => ".dmp", UNLINK => 1);

    mapHandlesToTablespace($infile, $outfile, $tablespace);

    close($infile)
        or die "close: $infile: $!";

    close($outfile)
        or die "close: $outfile: $!";

    $logger->debug("Mapped import file is " . $outfile->filename());

    return $outfile;
}

sub mapHandlesToTablespace {
    use bytes;

    my ($fin, $fout, $newts) = @_;

    binmode($fin);
    binmode($fout);

    # How does this work?
    #
    # 1. Bufsize must be EVEN.
    #
    # 2. Bufsize must be at least twice the size of the longest string
    # being matched.
    #
    # The buffer is kept full at all times, except for one partial
    # buffer at the end of the file.  We search/replace the whole
    # buffer, write out the lower HALF of the buffer, copy the upper
    # half of the buffer to the lower half, and refill the upper half.
    # This means every byte gets an extra copy, and gets searched
    # twice, but in return we don't have to worry about a matched
    # string getting split across buffers.
    #
    # Because we expect $fin and $fout are both regular files, we
    # don't consider the possibility that sysread/syswrite may return
    # less than the requested number of bytes.

    my $BUFSIZE = 8192;

    my $buf;
    my $offset = 0;
    my $length = 0;

    do {
        my $r = sysread($fin, $buf, $BUFSIZE - $offset, $offset);
        $length += $r;

        mapTablespaceBuffer(\$buf, $length, $newts);

        $offset = ($length == $BUFSIZE) ? $BUFSIZE / 2 : $length;
        syswrite($fout, $buf, $offset, 0);

        $length -= $offset;

        substr($buf, 0, $length) = substr($buf, $offset, $length);

    } while ($length > 0);
}

sub mapTablespaceBuffer {
    use bytes;

    my ($buf, $length, $newts) = @_;

    my $olen = length($$buf);

    # Preserve the length by padding with spaces
    $$buf =~ s/(\bTABLESPACE \"|\'tablespace )([^'"]+(\'|\"))/$1 . paddedTablespace($2, $newts)/eg;

    my $nlen = length($$buf);
    die "Internal error" unless $olen == $nlen;
}

sub paddedTablespace {
    use bytes;

    my $old = shift;
    my $newName = shift;

    my $new = $old;
    $new =~ s/[^'"]+/$newName/;

    my $pad = length($old) - length($new);

    if ($pad < 0) {
        die "Cannot replace tablespace '$old' with longer name '$new'\n";
    }

    $new .= ' ' x $pad;

    return $new;
}

sub numOfConnectionsToSchema {
    my $self = shift;
    my $sid = shift;
    my $schemaName = shift;
    my $password = shift;
    my $host = shift;

    my $oc = ariba::Ops::OracleClient->new($schemaName, $password, $sid, $host);
    $oc->setDebug(1) if $self->debug() >= 2;
    if ( !$oc->connect() ) {
        $logger->error("Connection to $schemaName\@$sid failed: [" . $oc->error() . "].");
        return;
    }

    # exclude the monitoring server from the list of machines we care
    # about, since monitoring never makes any changes to the product
    # schemas
    #my $mon = ariba::rc::InstalledProduct->new("mon");
    #die "Error: could not load mon product: $!" unless ($mon);
    #my ($monserver) = $mon->hostsForRoleInCluster('monserver', $mon->currentCluster());
    #my $sql = "select sid, username, machine, client_info from v\$session where username = \'$username\' and machine != \'$monserver\'";

#   my $sql = "select sid, username, machine, client_info from v\$session where username = \'$username\'";
#
#   my @connections = $oc->executeSql($sql);
#
#   if ($oc->error()) {
#       $logger->("Couldn't get number of connections for dbc [" . $sysOc->error() . "]";
#       return;
#   }

    $oc->disconnect();
#
#   return scalar @connections;

    return 0;
}

sub schemaName {
    my $self = shift;
    my $exportId = shift;

    my $attribute = "export_" . $exportId . "_Schema";
    return $self->$attribute();
}

sub setSchemaName {
    my $self = shift;
    my $schemaName = shift;
    my $exportId = shift;

    my $attribute = "export_" . $exportId . "_Schema";
    $self->setAttribute($attribute, $schemaName);
    return unless $self->_save();
}

sub setTableSpaceName {
    my $self = shift;
    my $tableSpaceName = shift;
    my $exportId = shift;

    my $attribute = "export_" . $exportId . "_TableSpace";
    $self->setAttribute($attribute,$tableSpaceName);
    return unless $self->_save();
}

sub getTableSpaceName {
    my $self = shift;
    my $exportId = shift;

    my $attribute = "export_" . $exportId . "_TableSpace";
    return $self->$attribute();
}

sub exportFile {
    my $self = shift;
    my $exportId = shift;

    my $attribute = "export_" . $exportId . "_File";
    return $self->$attribute();
}
sub setExportFile {
    my $self = shift;
    my $exportFile = shift;
    my $exportId = shift;

    my $attribute = "export_" . $exportId . "_File";
    $self->setAttribute($attribute, $exportFile);
    return unless $self->_save();
}
sub logFile {
    my $self = shift;
    my $exportId = shift;

    my $attribute = "export_" . $exportId . "_Log";
    return $self->$attribute();
}
sub setLogFile {
    my $self = shift;
    my $logFile = shift;
    my $exportId = shift;

    my $attribute = "export_" . $exportId . "_Log";
    $self->setAttribute($attribute, $logFile);
    return unless $self->_save();
}
sub schemaType {
    my $self = shift;
    my $exportId = shift;

    my $attribute = "export_" . $exportId . "_Type";
    return $self->$attribute();
}
sub setSchemaType {
    my $self = shift;
    my $type = shift;
    my $exportId = shift;

    my $attribute = "export_" . $exportId . "_Type";
    $self->setAttribute($attribute, $type);
    $self->_save();
}
sub backupStatus {
    my $self = shift;
    my $exportId = shift;

    my $attribute = "export_" . $exportId . "_Status";
    return $self->$attribute();
}
sub setBackupStatus {
    my $self = shift;
    my $status = shift;
    my $exportId = shift;

    my $attribute = "export_" . $exportId . "_Status";
    $self->setAttribute($attribute, $status);
    $self->_save();
}

sub setExportTypeOracle{
    my $self = shift;
    my $flag = shift;

    my $attribute = "dataPumpOracle";
    $self->setAttribute($attribute, $flag);
    $self->_save();
}

sub ExportTypeOracle{
    my $self = shift;

    my $attribute = "dataPumpOracle";
    return 0 unless( $self->$attribute());
    return $self->$attribute();
}

sub schemaId {
    my $self = shift;
    my $exportId = shift;

    my $attribute = "export_" . $exportId . "_SchemaId";
    return $self->$attribute();
}

sub setSchemaId {
    my $self = shift;
    my $schemaId = shift;
    my $exportId = shift;

    my $attribute = "export_" . $exportId . "_SchemaId";
    $self->setAttribute($attribute, $schemaId);
    return unless $self->_save();
}

sub fileSizeinBytes {
    my $self = shift;
    my $exportId = shift;

    my $attribute = "export_" . $exportId . "_FileSizeInBytes";
    return $self->$attribute();
}

sub setHanaDBTypes {
    my $self = shift;
    my $dbTypes = shift;

    while (my ($key, $value) = each (%$dbTypes)){
        my $attribute = "hana".$key;
        $self->setAttribute($attribute, @$value);
        $self->_save();
    }
}

sub getHanaDBTypes {
    my $self = shift;
    my $type = shift;
    my $num = shift;

    my $attribute = "hana".uc($type);
    return split(',',$self->$attribute());
}

sub setFileSizeInBytes {
    my $self = shift;
    my $size = shift;
    my $exportId = shift;

    my $attribute = "export_" . $exportId . "_FileSizeInBytes";
    $self->setAttribute($attribute, $size);
    return unless $self->_save();
}

sub removeBackupAttributes {
    my $self = shift;
    my $dbExportId = shift;

    return unless $dbExportId;

    for my $attribute ( grep($_ =~ /^export_${dbExportId}_/, $self->attributes()) ) {
        $self->deleteAttribute($attribute);
    }
    return unless $self->_save();
}

sub setTesting {
    my $self = shift;
    my $value = shift;

    $self->setDebug($value) if !$self->debug() && $value;

    $self->SUPER::setTesting($value);

    return 1;
}

sub setFpc {
    my $self = shift;
    $self->setBackupType("FPC");
    return 1;

}

sub isFpc {
    my $self = shift;
    return 1 if $self->backupType() && $self->backupType() eq "FPC";
    return 0;
}

sub fpcId {
    my $self = shift;

    return "DS" . $self->instance();
}

sub detailsForSchemaBackupId {
    my $self = shift;
    my $dbExportId = shift;
    my $attribute;

    my %status;

    for my $statusType ( qw(Schema FileSizeInBytes Type SchemaId Status) ) {
        my $attribute = "export_${dbExportId}_$statusType";
        $status{$statusType} = (defined($self->$attribute())) ? $self->$attribute() : "";

        #
        # for some reason, this isn't always set either... weird
        #
        if($status{$statusType} eq "" && $statusType eq 'SchemaId') {
            $status{$statusType} = $dbExportId;
        }
    }

    return %status;
}

sub getDBExportIds {
    my $self = shift;

    my @exportIdList;

    for my $attribute ( grep(/_File$/, $self->attributes()) ) {
        my $id = (split(/_/, $attribute))[1];
        push @exportIdList, $id;
    }

    return @exportIdList;
}

sub size {
    my $self = shift;

    my $size;
    $size += $self->realmSizeInBytes() if $self->realmSizeInBytes();
    my $indexDir = ariba::Ops::Constants->archiveManagerArchiveDir() . "/" . $self->instance() . "/hana/index";
    if (-e $indexDir) {
        $size += `du -s $indexDir` * 1024;
    } else {
           for my $dbExportId ($self->getDBExportIds()) {
               my $attribute = "export_" . $dbExportId . "_FileSizeInBytes";
               $size += $self->$attribute();
           }
    }

    return $size if $size;
    return 0;
}

sub _setCreateTime {
    my $self = shift;

    my $time = time();
    $self->setCreateTime($time);

}

sub setType {
    my $self = shift;
    my $type = shift;

    my $productName = $self->productName();
    return unless defined $type;

    if ( $productName eq "an" ) {
        unless ( grep(/^$type$/, @validANDatasetTypes) ) {
            $logger->error("$type is not in the list of valid $productName Dataset Types: " . join(" ", @validANDatasetTypes));
            return;
        }
    } else {
        unless ( grep(/^$type$/, @validASPDatasetTypes) ) {
            $logger->error("$type is not in the list of valid $productName Dataset Types: " . join(" ", @validASPDatasetTypes));
            return;
        }
    }

    $self->SUPER::setType($type);

    return unless $self->_save();
}

sub _save {
    my $self = shift;

    my $time = time();
    $self->setModifyTime($time);
    unless ($self->recursiveSave()) {
        return;
    }

    return 1;
}

sub _getNextDBExportID {
    my $self = shift;

    my $checkId = 0;
    while ( 1 ) {
        my $attribute = "export_" . $checkId . "_File";
        last unless $self->hasAttribute($attribute);
        $checkId++;
    }

    return $checkId;
}

#
# Given a product name, return a hash containing latest build name => type
#
sub latestDatasetsByProduct {
    my ($class, $product) = @_;
    my @candidates = $class->listBaselineRestoreCandidatesForProductNameAndTypeByModifyTime ($product);
    my %datasets;
    my @types = $class->validDatasetTypesForProductName ($product);
    my %typeMap = map { $_ => 1 } @types;

    for my $dataset (@candidates) {
        # skip incomplete datasets
        next if ! $dataset->datasetComplete();

        # skip datasets with invalid buildname or type
        my $buildName = defined $dataset->buildName() ? $dataset->buildName() : "";
        my $type = defined $dataset->type() ? $dataset->type() : "";
        next unless $buildName && $type;

        # builds for product "an" use the service name as the type
        my $serviceName = defined $dataset->serviceName() ? $dataset->serviceName() : "";
        if (exists $typeMap{$serviceName}) {
            $type = $serviceName;
        }

        # generate a map with the newest build for a type
        $datasets{$type} = $buildName unless exists $datasets{$type};
    }

    return reverse %datasets;
}

sub backupOracleLogs {
    my $oracleDir = shift;
    my $dsDir = shift;
    my $hostname = ariba::Ops::NetworkUtils::hostname();

    $oracleDir =~ s|/+$||;
    $dsDir =~ s|/+$||;

    opendir(D, "$oracleDir");
    my @files = grep { $_ !~ /^\.+$/ } readdir(D);
    closedir(D);

    my %fHash;
    map { $fHash{"$_"} = (stat("$oracleDir/$_"))[9] } @files;

    my $ct = 0;
    foreach my $f (sort { $fHash{$b} <=> $fHash{$a} } keys(%fHash)) {
        my $cp = ariba::rc::Utils::cpCmd();
        system("$cp --preserve=timestamp $oracleDir/$f $dsDir/$f");
        chmod(0644, "$dsDir/$f");
        $ct++;
        last if($ct > 29);
    }
    open(F, "> $dsDir/hostname");
    print F "$hostname\n";
    close(F);
}

sub restoreOracleLogs {
    my $oracleDir = shift;
    my $dsDir = shift;

    my $chown = ariba::rc::Utils::chownCmd();
    my $chmod = ariba::rc::Utils::chmodCmd();

    #
    # save some mode for later, Gustav!
    #
    my $mode = (stat($oracleDir))[2];

    #
    # we need to be able to read the directory for this to work
    #
    chmod(0777, $oracleDir);
    opendir(D, $oracleDir);

    #
    # remove any archive logs in the directory before we start
    #
    while(my $f = readdir(D)) {
        next if($f =~ /^\.+$/);
        system("su oracle -c \"rm -f $oracleDir/$f\"");
    }
    closedir(D);

    #
    # copy copy copy
    #
    opendir(D, $dsDir);
    while(my $f = readdir(D)) {
        next if($f =~ /^\.+$/);
        next if($f eq 'hostname');

        my $cp = ariba::rc::Utils::cpCmd();
        system("su oracle -c \"$cp --preserve=timestamp $dsDir/$f $oracleDir/$f\"");
        #
        # archive logs are -r--r----- oracle dba
        #
        system("su oracle -c \"$chown oracle:dba $oracleDir/$f\"");
        system("su oracle -c \"$chmod 440 $oracleDir/$f\"");
    }
    closedir(D);

    #
    # Gustav... it's later...
    #
    chmod($mode, $oracleDir);
}

sub recordStatus {
    my $self = shift;
    my %args = @_;
    my $logfh;
    my $statusLogFile = ariba::Ops::Constants->dsmStatusLogFile();

    unless( open( $logfh, ">>",  $statusLogFile ) ) {
        print "Failed to record success/failure status: $!\n";
        return;
    }

    print $logfh scalar(localtime()) . " Product $args{'product'} Service $args{'service'} Action $args{'action'} Status $args{'status'} Dataset $args{'dataset'}\n";

    close($logfh);
}

sub post_Url {
    my $url = shift;
    my $postBody = shift;
    my $timeout = shift || 45;

    my $requestUrl = ariba::Ops::Url->new($url);
    $requestUrl->setupFormPost($postBody);
    $requestUrl->setTimeout($timeout);
    $requestUrl->useOutOfBandErrors();
    $requestUrl->setSaveRequest(1);
    my $results = $requestUrl->request();
    my $error = $requestUrl->error();

    # Retry once on timed out
    if ($error && $error =~ /timed out/i) {
        $results = $requestUrl->request();
        $error = $requestUrl->error();
    }

    unless(defined $results) {
        $logger->error("Url did not return anything");
        return undef;
    }
    return ($results , $error);
}

sub mkdirWithPermission {
        my ($dir,$permission) = @_;

        unless ($permission){
            $permission = '777';
        }
        unless (ariba::rc::Utils::mkdirRecursively($dir)){
                ##if can't create dir let hana export create directory
                return 0;
        }
        my $cmd = qq!chmod -R $permission $dir!;
        unless(executeLocalCommand($cmd)){
                ##if can't change the permission then remove let hana export create directory
                rmdirRecursively($dir);
        }
}

sub getSystemDBConnection {
    my $name = shift;
    my $product = shift;

    my @productConnections;
    for my $dictKeypath ($product->defaultKeysForPrefix("dbconnections.$name")) {

        my $user = $product->default("$dictKeypath.username");
        my $pass = $product->default("$dictKeypath.password");
        my $sid = $product->default("$dictKeypath.serverid");
        my $host = $product->default("$dictKeypath.hostname");

        my $type = "main";
        my $schemaId = ariba::Ops::DBConnection->_schemaIdForConnectionDict($dictKeypath);
        my @realHosts = ariba::Ops::DBConnection->_realHostsForProductAndHost($product, $host);

        my $c = ariba::Ops::DBConnection->new($user, $pass, $sid, $host,
                $type,
                $schemaId,
                $product,
                @realHosts);
        if ($c) {
            unless ($schemaId) {
                unshift(@productConnections, $c);
            } else {
                push(@productConnections, $c);
            }
        }
    }
    return @productConnections;
}

sub getLastId{

    ##Dataset id Range
    my $datasetRange = {
        'lab1'     => '1000-8999',
        'sc1-lab1' => '9000-9999'
    };

    my $dc = getDCFromNFSMount();

    return (split(/-/,$datasetRange->{$dc}));
}

sub getDCFromNFSMount {

    my $nfsMount = {
        'maytag.ariba.com'           => 'lab1', 
        'kenmore.sc1-lab1.ariba.com' => 'sc1-lab1',
    };

    my $archiveManager = ariba::Ops::Constants->archiveManager();
    my $dfCmd = "df -P $archiveManager";
    my @output;
    ariba::rc::Utils::executeLocalCommand($dfCmd, undef, \@output, undef, 1);

    my $nfsFS = (split ( /:/,(grep( /$archiveManager/i,@output))[0]))[0];

    return $nfsMount->{$nfsFS};
}

sub backupHbaseTablesFromProduct_cdh5 {
    my $self = shift;
    my $product = shift;

    my $productArches = $product->name();
    my $serviceArches = $product->service();

    my $aribaArchesConfig = $product->installDir() . "/config/ariba.arches.user.config.cfg";
    my $rootTable = getParamsFromAlternateConfig($aribaArchesConfig, 'ariba.hadoop.tenant.prefix');
    my $hadoopTenant = getParamsFromAlternateConfig($aribaArchesConfig, 'ariba.hadoop.tenant.actas');
    my $serviceHadoop = $serviceArches;

    unless ($rootTable) {
        $logger->error("Arches ariba.hadoop.tenant.prefix value is not set.");
        return 0;
    }

    unless ($serviceHadoop) {
        $logger->error("Arches ariba.hadoop.tenant.actas value is not set.");
        return 0;
    }

    ## TO-DO engr to checkin a parameter for hadoop service that arches talkes to. For now, just parse 'ariba.hadoop.tenant.actas'
    $serviceHadoop =~ s/^svc//;

    my $arches = ariba::rc::InstalledProduct->new($productArches, $serviceArches);
    my $installDirArches = $arches->installDir();

    #my $hadoop = ariba::rc::InstalledProduct->new("hadoop", $serviceHadoop) if ($productArches eq "arches");
    my $host = $arches->default('Hadoop.DFS.NameNode.NameNode1.primary.RPCAddress');
    $host =~ s/\:.*//;
    #my $javaHome = $ENV{'JAVA_HOME'} = ariba::Ops::Startup::Common::javaHomeForProduct($hadoop);
    my $installDir = '/usr/local/ariba/bin';
    #my $mrDir = $installDir . "/hadoop/share/hadoop/mapreduce1";
    #my $hadoopHome = $installDir . "/hadoop";
    #my $hbaseHome = $installDir . "/hbase";
    #my $hadoopConfDir = $hadoopHome . "/conf";
    my $svcUser = "svc$serviceArches";
    my $dsid = $self->instance();
    my $fromTenant = $self->fromTenant();
    my $exportDir = "/export/backup/$dsid/$rootTable";
    my @cmdExport;
    if ( ariba::rc::Globals::isPersonalService($serviceArches) ) {
           $svcUser =~ s/^svc//;
           $svcUser =~ s/^personal_//i;
    }

    my $cmd = "ssh $svcUser\@$host ";#-x 'bash -c \"export JAVA_HOME=$javaHome; export HADOOP_HOME=$mrDir; export HADOOP_CONF_DIR=$hadoopConfDir";

    my $hdfsVersions = ariba::Ops::Constants::hdfsVersions();
    my $firstExport = ariba::Ops::Constants::hdfsFirstExport();

    #
    # Get tablenames
    #
    
    $logger->info("Getting list of tables to export");
    my @tables = ariba::Ops::HadoopHelper::getHbaseTables($arches->name(), $arches->service(), 0);

    unless (scalar @tables > 0) {
        $logger->error("No tables returned from gethbasetables"); 
        return 0;
    }

    my @tablesWithTenantSpecificKey = ariba::Ops::HadoopHelper::getHbaseTables($arches->name(), $arches->service(), 1);
    my %hash;
    $hash{$_} = 1 foreach @tablesWithTenantSpecificKey;
    my @tablesWithoutTenantSpecificKey = grep( ! $hash{$_}, @tables);
    
    my $now = time();
    # Convert now time to milliseconds or hbase export with buyerTenant doesn't export correctly
    $now = $now * 1000;

    foreach my $table (@tablesWithTenantSpecificKey) {
        $table =~ s/\n//g;
        #
        # there is a limitation in the number of chars we can pass as a remote command, need to see how we can break this up.
        # below is just for 1 table
        #
        $logger->info("Preparing to take export of $table on $productArches $serviceArches");
        my $cmdExport = "ssh $svcUser\@$host $installDir/hbase-export-table -service $serviceHadoop -table $table -tenant $fromTenant -rtable $rootTable -dsid $dsid -now $now";
    $logger->info("Command run =  $cmdExport");
        my $exportOutput = $self->runHbaseCommand($cmdExport, $serviceHadoop, $svcUser);

    $logger->info("Command output =  @$exportOutput[0]");
        if (grep $_ =~ /$exportDir\/$table already exists/, @{$exportOutput}) {
            $logger->info("WARN: skipped exporting $table. An export already exists in $exportDir...");
        }
    }

    foreach my $table (@tablesWithoutTenantSpecificKey) {
        $table =~ s/\n//g;
        #
        # there is a limitation in the number of chars we can pass as a remote command, need to see how we can break this up.
        # below is just for 1 table
        #
        $logger->info("Preparing to take export of $table on $productArches $serviceArches");
        my $cmdExport = "ssh $svcUser\@$host $installDir/hbase-export-table -service $serviceHadoop -table $table -rtable $rootTable -dsid $dsid -now $now";
    $logger->info("Command run = $cmdExport");
        my $exportOutput = $self->runHbaseCommand($cmdExport, $serviceHadoop, $svcUser);
    $logger->info("Command output = @$exportOutput");
        if (grep $_ =~ /$exportDir\/$table already exists/, @{$exportOutput}) {
            $logger->info("WARN: skipped exporting $table. An export already exists in $exportDir...");
        }
    }

    #
    # Copy exported files from hdfs to archmgr location
    #
    my $archiveDir = ariba::Ops::Constants->archiveManagerArchiveDir() . "/" . $self->instance();
    my $cmdCopy = "$cmd \"hdfs dfs -get $exportDir $archiveDir\"";
    $logger->info("Copying files from hdfs to archive manager: $cmdCopy");
    my $copyOutput = $self->runHbaseCommand($cmdCopy, $serviceHadoop, $svcUser);
    $logger->info("CopyOutput = @$copyOutput");
    if (grep $_ =~ /File exists/, @{$copyOutput}) {
        $logger->info("WARN: skipped copying export from hdfs to $archiveDir, 1 or more of the files already exist.");
        return 0;
    }

    #
    # Compress export on archmgr directory
    #
    my $tarFile = $archiveDir . "/" . $rootTable . "_" . $self->instance() . ".tgz";
    $logger->info("Compressing $archiveDir/$rootTable to $tarFile"); 

    my $tarCmd = tarCmd() . " zcf";
    $tarCmd .= " $tarFile -C $archiveDir $rootTable";

    if ( $self->testing() ) {
        $logger->debug("DRYRUN: would create export $tarFile file");
    } else {
        system($tarCmd) == 0 or do {
            my $error = $?;
            $logger->error("Failed to create export $tarFile file");
            $logger->error("tar returned " . ($error >> 8));
            return 0;
        };

        #
        # Cleaning up export on hdfs
        #
        $logger->info("Cleaning up exports from hdfs");
        my $cmdRmr = "$cmd hdfs dfs -rmr $exportDir";
        my $rmrOutput = $self->runHbaseCommand($cmdRmr, $serviceHadoop, $svcUser);

        #
        # Clean up uncompressed export on archive manager 
        #
        $logger->info("Cleanup uncompressed exports from archive manager");
        my $rmDirCmd = "ssh $svcUser\@$host -x 'bash -c \"rm -rf $archiveDir/$rootTable\"'";
        my $rmDirOutput = $self->runHbaseCommand($rmDirCmd, $serviceHadoop, $svcUser);

        $self->setDatasetComplete(1);

        return unless $self->_save();
    }
}


sub restoreHbaseFromProduct_cdh5 {
    my $self = shift;
    my $product = shift;
    my $toTenant = shift;
    my $toAdapter = shift;

    my $productName = $product->name();
    my $serviceArches = $product->service();

    my $aribaArchesConfig = $product->installDir() . "/config/ariba.arches.user.config.cfg";
    my $rootTable = getParamsFromAlternateConfig($aribaArchesConfig, 'ariba.hadoop.tenant.prefix');
    my $hadoopTenant = getParamsFromAlternateConfig($aribaArchesConfig, 'ariba.hadoop.tenant.actas');
    my $serviceHadoop = $serviceArches;

    unless ($rootTable) {
        $logger->error("Arches ariba.hadoop.tenant.prefix value is not set.");
        return;
    }

    unless ($serviceHadoop) {
        $logger->error("Arches ariba.hadoop.tenant.actas value is not set.");
        return;
    }

    ## TO-DO engr has a change to add a new paramter for hadoop service so we don't have to parse this
    $serviceHadoop =~ s/^svc//;

    my $arches = ariba::rc::InstalledProduct->new('arches', $serviceArches);
    my $installDirArches = $arches->installDir();

    my $host = $arches->default('Hadoop.DFS.NameNode.NameNode1.primary.RPCAddress');
    $host =~ s/\:.*//;

    my $javaHome = $ENV{'JAVA_HOME'} = ariba::Ops::Startup::Common::javaHomeForProduct($arches);
    my $installDir = "/tmp";
    my $svcUser = "svc$serviceArches";
    my $svcUserArches = "svc$serviceArches";

    if ( ariba::rc::Globals::isPersonalService($serviceArches) ) {
           $svcUser =~ s/^svc//;
           $svcUser =~ s/^personal_//i;
           $svcUserArches =~ s/^svc//;
           $svcUserArches =~ s/^personal_//i;
    }


    my $cmd = "ssh $svcUser\@$host ";#-x 'bash -c \"export JAVA_HOME=$javaHome; export HADOOP_HOME=$mrDir; export HADOOP_CONF_DIR=$hadoopConfDir";
    my $dsid = $self->instance();
    my $exportDir = "/export/restore/$dsid/$rootTable";
    my $fromTenant = $self->fromTenant();
    my $fromAdapter = $self->fromAdapter();

    ## remove this 'if' block once anrc changes have been made to support this feature
    if (!defined $toTenant) {
        $toTenant = $fromTenant;
    }
    
    if (!defined $toAdapter) {
        $toAdapter = $fromAdapter;
    }

    #
    # Check if file repository/usr/ariba.arches.user.config.properties exists as it is
    # requried for initdb. If not, then exit
    #
    my $propertiesFile = $installDirArches . "/repository/usr/ariba.arches.user.config.properties";
    unless (-e $propertiesFile) {
        $logger->info("$propertiesFile does not exist, attempting to create it");

        my $indexMgrApp = (grep { $_->appName() eq 'IndexMgr' } $product->appInstancesInCluster($product->currentCluster()))[0];
        my $indexAppName = $indexMgrApp->instanceName();
        my $indexHost = $indexMgrApp->host();
        my $startCmd = "ssh $svcUserArches\@$indexHost $installDirArches/bin/startup $indexAppName";
        my $stopCmd = "ssh $svcUserArches\@$indexHost $installDirArches/bin/stopsvc $indexAppName";
        my $svcUserPass = ariba::rc::Passwords::lookup($svcUserArches);
        my $masterPass = ariba::rc::Passwords::lookup('master');
        unless (ariba::rc::Utils::executeRemoteCommand($startCmd, $svcUserPass, 0, $masterPass, 120)) {
            $logger->error("Error in starting up $indexAppName");
            return 0;
        }
        unless (ariba::rc::Utils::executeRemoteCommand($stopCmd, $svcUserPass, 0, $masterPass, 120)) {
            $logger->error("Error in stopping $indexAppName");
            return 0;
        }

        unless (-e $propertiesFile) {
            $logger->error("$propertiesFile does not exist, unable to run initdb");
            return 0;
        }
    }

    my @archesIndexHosts = $product->hostsForRoleInCluster( 'indexmgr', $product->currentCluster() );
    my $archesHost = (@archesIndexHosts)[0];
    my $currentHost = ariba::Ops::NetworkUtils::hostname();

    # if adapter is not defined, simply run initdb, else only delete data for that adapter
    if (!defined $toAdapter) {
        #
        # Create tables by running initdb -all from current arches host
        #

        if ($productName eq 'arches') {
            $logger->info("Cleanning up shards dir before running initdb");
            unless (ariba::Ops::DatasetManager->cleanupArchesShards($product)) {
                return 0;  # bail if we get an error return
            }
        }

        $logger->info("Running initdb -all to create tables plenk");
        my $cmdInitdb = "bash -c \"export JAVA_OPTS=\'-Djavax.xml.parsers.DocumentBuilderFactory=com.sun.org.apache.xerces.internal.jaxp.DocumentBuilderFactoryImpl\';$installDirArches/bin/initdb -all \"";
        my @outputInitdb;

        ariba::rc::Passwords::initialize($serviceArches);

        #
        # If current host is a indexmgr arches host, then just run initdb directly
        # If current host is not a indexmgr arches host, then login to one and run it
        #
        if (grep {$_ eq $currentHost} @archesIndexHosts) {
            unless (ariba::Ops::Startup::Common::runCommandAndFeedMasterPassword($cmdInitdb, ariba::rc::Passwords::lookup('master'))) {
                $logger->error("Error running initdb on arches to disable, drop and recreate tables");
                return 0;
            }
        } else {
            my @output;
            my $cmdInitdbFull = "ssh $svcUserArches\@$archesHost -x 'bash -c \"export JAVA_HOME=$javaHome ;export JAVA_OPTS=\"-Djavax.xml.parsers.DocumentBuilderFactory=com.sun.org.apache.xerces.internal.jaxp.DocumentBuilderFactoryImpl\"; $cmdInitdb\"'";

            unless (ariba::rc::Utils::executeRemoteCommand($cmdInitdbFull, ariba::rc::Passwords::lookup($svcUserArches),
                   0, ariba::rc::Passwords::lookup('master'), 120, \@output)) {
                $logger->error("Error running initdb on arches to disable, drop and recreate tables");
                $logger->info(join("\n", @output));
                return 0;
            }
        }
    } else {
        my $indexMgrApp = (grep { $_->appName() eq 'IndexMgr' } $product->appInstancesInCluster($product->currentCluster()))[0];
        my $indexHost = $indexMgrApp->host();
        my $indexPort = $indexMgrApp->httpPort();
        my $url = "http://$indexHost:$indexPort/Arches/api/tenantinfo/secure/deletetenant";

        my $postBody = { adapter=>$toAdapter };

        my ($deleteTenantResult, $errorDeleteTenant) = post_Url($url,$postBody, 10800);
        
        $logger->info("Starting delete tenant via $url for adapter $toAdapter");
        
        unless (defined $deleteTenantResult) {
            $logger->error("No delete tenant result returned");
            return 0;
        }
        # todo, handle more error condition

        $logger->info("delete tenant by adapter result: $deleteTenantResult");
    }

    my $serviceDsid = $self->serviceName();
    if ( ariba::rc::Globals::isPersonalService($serviceDsid) ) {
        $serviceDsid =~ s/personal_//;
    }
    #
    # root table name = /home/archmgr/archive/<dsid>/<root_tablename>.<tablename>
    # archiveDir: /home/archmgr/archive/$dsid/$serviceDsid
    #
    my $archiveDsidDir = ariba::Ops::Constants->archiveManagerArchiveDir() . "/$dsid";
    my $archiveDir = "$archiveDsidDir/$serviceDsid";
    mkdir($archiveDir) unless (-e $archiveDir);

    ## TO-DO: need to update to get rootTable name of dsid, for now we assume the rootTable name
    ## is the same as the dsid service
    my $tarFile = $archiveDir . "_" . $dsid . ".tgz";

    my $untarCmd = "ssh $svcUser\@$host -x 'bash -c \"" . tarCmd() . " zxf $tarFile -C $archiveDsidDir\"'";

    if ($self->testing()) {
        $logger->debug("DRYRUN: would decompress hbase tables via '$untarCmd'");
    } else {
        $logger->info("Preparing to decompress hbase tables under $archiveDir");

        my $untarOutput = $self->runHbaseCommand($untarCmd, $serviceArches, $svcUser);

        $logger->info("Done decompressing tables via '$untarCmd'");
        # We are troubleshooting issues where some of the HBase tables are not restored during restore-migrate.
        # We like to inspect the output of the untar command.
        $logger->info("Output of untar command is @$untarOutput");
    }

    $logger->info("Copying dataset data from archive to hdfs (hadoop $serviceArches)");
    my $cmdCopy = "$cmd \"hdfs dfs -rmr $exportDir ; hdfs dfs -mkdir -p $exportDir ; hdfs dfs -put $archiveDir $exportDir\"";
    my $copyOutput = $self->runHbaseCommand($cmdCopy, $serviceArches, $svcUser);
    if (grep $_ =~ /File exists/, @{$copyOutput}) {                                                                                                                                                                                
        $logger->info("WARN: skipped copying export from hdfs to $archiveDir, 1 or more of the files already exist.");                                                                                                             
        return 0;
    }

    ## TO-DO add error checking here

    ## ls -l $archiveDir command returning junk and non-printable characters
    ## using find command as alternative
    my $tableListCmd = "ssh $svcUser\@$host -x 'find $archiveDir  -maxdepth 1 -mindepth 1 -printf \"%f\\n\"'";
    $logger->info("Preparing to get list of table files from $archiveDir");
    my $tablesDsid = $self->runHbaseCommand($tableListCmd, $serviceHadoop, $svcUser);
    $logger->info("List of tables in dataset, read from archive dir $archiveDir is: [ ".join(', ',@$tablesDsid)." ]");
    my @tablesSrc;
    my $rootTableSrc;

    foreach my $file (@$tablesDsid) {
        next if ($file =~ m/(^\.|^\s+$|\s+)/i);
        my @tableVals = $file =~ /^(.+?\.)(.+)/;
        $rootTableSrc = $tableVals[0];
        push(@tablesSrc, $tableVals[1]);
    }
    $rootTableSrc =~ s/\.//;
    my @cmdImport;

    $logger->info("Running import (restore) for arches tables $rootTable.* in $serviceArches");
    
    my $cmdModifyRowKey;
    my $runLocally = (grep {$_ eq $currentHost} @archesIndexHosts);
    $logger->info("Starting import of these HBase tables: [ ".join(', ', @tablesSrc)." ]");
    foreach my $table (@tablesSrc) {
        $logger->info("Running import (restore) for arches table $rootTable.$table");
        $cmdModifyRowKey = "bash -c \"export JAVA_HOME=$javaHome ;export JAVA_OPTS=\'-Djavax.xml.parsers.DocumentBuilderFactory=com.sun.org.apache.xerces.internal.jaxp.DocumentBuilderFactoryImpl\';$installDirArches/bin/modifyrowkey -fromTenant=$fromTenant -toTenant=$toTenant -tableName=$rootTable.$table -inputDir=$exportDir/$serviceDsid/$rootTableSrc.$table\"";
        if (defined $toAdapter) {
            $cmdModifyRowKey .= " -adapter=$toAdapter";
        }
        if ($runLocally) {
            my $ret = ariba::Ops::Startup::Common::runCommandAndFeedMasterPassword($cmdModifyRowKey, ariba::rc::Passwords::lookup('master'));
            if ($ret =~ /error/i) {
                $logger->error("Error running modifyrowkey to update arches data for buyer $toTenant");
                return 0;
            }
        }
        else {
            my $cmdModifyRowKeyFull = "ssh $svcUserArches\@$archesHost \'$cmdModifyRowKey\'";
            my @modifyRowKeyOutput;
            my $ret = ariba::rc::Utils::executeRemoteCommand($cmdModifyRowKeyFull, ariba::rc::Passwords::lookup($svcUserArches), 
                0, undef, undef, \@modifyRowKeyOutput);
            unless ($ret) {
                $logger->error("Error running modifyrowkey to update arches data for buyer $toTenant");
                $logger->info(join("\n", @modifyRowKeyOutput));
                return 0;
            }
        }    
    }

    ## TO-DO need to do some error checking here
    $logger->info("Done running import to $dsid");

    #
    # Cleaning up export on hdfs
    #
    $logger->info("Cleaning up exports from hdfs");
    my $cmdRmr = "$cmd \"hdfs dfs -rmr $exportDir\"";
    my $rmrOutput = $self->runHbaseCommand($cmdRmr, $serviceArches, $svcUser);

    #
    # Clean up uncompressed export on archive manager 
    #
    $logger->info("Cleanup uncompressed exports from archive manager");
    my $rmDirCmd = "ssh $svcUser\@$host -x 'bash -c \"rm -rf $archiveDir\"'";
    my $rmDirOutput = $self->runHbaseCommand($rmDirCmd, $serviceArches, $svcUser);

    return 1;
}

sub getDBConnectionsForProduct {
    my ($product,$dbType) = @_;

    my %databaseHash = ();
    my $databasePrefix = "System.Databases.";
    for my $dictKeypath ($product->defaultKeysForPrefix(quotemeta($databasePrefix))) {
        my $key = $dictKeypath;
        $key =~ s/^$databasePrefix//;

        $databaseHash{$key}{HOST} = $product->default("$dictKeypath.AribaDBHostname");
        $databaseHash{$key}{SID} = $product->default("$dictKeypath.AribaDBServer");
        $databaseHash{$key}{TYPE} = $product->default("$dictKeypath.AribaDBSchemaType");
        $databaseHash{$key}{DBTYPE} = $product->default("$dictKeypath.AribaDBType");
        $databaseHash{$key}{PORT} = $product->default("$dictKeypath.AribaDBPort");
        $databaseHash{$key}{HANAHOSTS} = $product->default("$dictKeypath.HanaDBHosts") || [];
        $databaseHash{$key}{HANADBNAME} = $product->default("$dictKeypath.HanaDBName");
        $databaseHash{$key}{HANADBADMINID} = $product->default("$dictKeypath.HanaDBAdminID");
    }

    my $dbcs;
    for my $key (keys %databaseHash){
        next if ($databaseHash{$key}{DBTYPE} !~ /$dbType/i);
        my ($sidType,$num) = $key =~ /([a-z]+)(\d+)/i;
        my $type = $sidType =~ /^Transaction/i ? "TX" : "SV";
        $dbcs->{$type.$num} = {
            'host' => $databaseHash{$key}{HOST},
            'port' => $databaseHash{$key}{PORT},
            'sid'  => $databaseHash{$key}{SID},
        };
    }
    return $dbcs;
}

sub isscperf {
    my $service = shift;

    return 1 if ( $service =~ /^scperf/i );
    return 0;
}

1;
