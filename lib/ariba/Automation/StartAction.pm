package ariba::Automation::StartAction;

use warnings;
use strict;

use ariba::Automation::Utils;
use ariba::Automation::Action;
use base qw(ariba::Automation::Action);

use ariba::Ops::Logger;
use ariba::rc::Globals;
use ariba::rc::Utils;
use ariba::rc::ArchivedProduct;
use ariba::Ops::DatasetManager;
use ariba::Ops::DatasetManager::Product;
use ariba::Ops::DBConnection;
use ariba::Ops::OracleClient;

sub validFields {
    my $class = shift;

    my $fieldsHashRef = $class->SUPER::validFields();

    $fieldsHashRef->{'buildName'} = 1;
    $fieldsHashRef->{'productName'} = 1;
    $fieldsHashRef->{'migration'} = 1;
    $fieldsHashRef->{'datasetType'} = 1;
    $fieldsHashRef->{'sourceBuildname'} = 1;
    $fieldsHashRef->{'loadRealms'} = 1;

    return $fieldsHashRef;
}

sub execute {
    my $self = shift;

    my $logger = ariba::Ops::Logger->logger();
    my $logPrefix = $self->logPrefix();

    my $service = ariba::Automation::Utils->service();

    my $productName = $self->productName();
    my $migrationCommand = $self->migration();
    my $restoreDatasetType = $self->datasetType();
    my $sourceBuildname = $self->sourceBuildname();
    my $buildName = $self->buildName();
    my $loadRealms = $self->loadRealms();

    unless (ariba::rc::ArchivedProduct->isArchived($productName, $service, $buildName)) {
        $logger->error("$logPrefix No archived deployment $productName / $buildName for service $service exists");
        return;
    }

    my $product = ariba::rc::ArchivedProduct->new($productName, $service, $buildName);
    unless ($product) {
        $logger->error("$logPrefix could not load archived product $productName / $buildName for service $service");
        return;
    }

    $buildName = $product->buildName() unless $buildName;
    $product->setClusterName('primary');

    my $conditionalMigrationCommand; # captures the supplied migrationCommand (when "robot-initdb" or "robot-restoremigrate")
    my $skipMigration; # when set, do not perform initdb (instead it will be restored from a dataset)

    if ($migrationCommand && ($migrationCommand eq "robot-saveinitdb")) {
        # This migration command performs a save of the DB as dataset type robot-initdb
        $conditionalMigrationCommand = "robot-initdb";
        $skipMigration = 1;
        $logger->info("$logPrefix Will perform a save of the DB to a robot-initdb dataset (the raw migration steps will not be performed)");
    }
    elsif ($migrationCommand && ($migrationCommand eq "robot-initdb" || $migrationCommand eq "robot-restoremigrate")) {
        my $classicBuild = $self->_isClassicBuild($product->archiveDir());
        if ($classicBuild) {
            if ($migrationCommand eq "robot-initdb") {
                $migrationCommand = "initdb";
                $logger->info("$logPrefix Will perform $migrationCommand instead of optimized robot-initdb because this is a classic build ");
            }
            elsif ($migrationCommand eq "robot-restoremigrate") {
                $migrationCommand = "restoremigrate";
                $logger->info("$logPrefix Will perform $migrationCommand instead of optimized robot-restoremigrate because this is a classic build ");
            }
        }
        else {
            # Incremental build is a requirement to work the robot-initdb optimization
            $conditionalMigrationCommand = $migrationCommand;

            my $dataset = $self->_getRestorableRobotDataSet($productName, $migrationCommand, $service, $buildName, $product->archiveDir());
            if ($dataset) {
                my $datasetId = $dataset->instance();
                $logger->info("$logPrefix Will attempt to restore the $migrationCommand dataset \"$datasetId\" because the dataset exists and it meets the criteria");

                my $ret = $self->_restoreRobotDataSet($dataset, $productName, $migrationCommand, $service);

                if ($ret) {
                    # We restored the robot-{initdb,restoremigrate} dataset
                    # Set the skipMigration flag so we skip the initdb and just do the start
                    $skipMigration = 1;
                }
                else {
                    if ($migrationCommand eq "robot-initdb") {
                        $migrationCommand = "initdb";
                        $logger->info("$logPrefix There is no robot-initdb dataset so performing the brute force initdb");
                    }
                    elsif ($migrationCommand eq "robot-restoremigrate") {
                        $migrationCommand = "restoremigrate";
                        $logger->info("$logPrefix There is no robot-restoremigrate dataset so performing the brute force restoremigrate");
                    }
                }
            }
            else {
                if ($migrationCommand eq "robot-initdb") {
                    $migrationCommand = "initdb";
                }
                elsif ($migrationCommand eq "robot-restoremigrate") {
                    $migrationCommand = "restoremigrate";
                }
                $logger->info("$logPrefix Will perform $migrationCommand");
            }
        }
    }

    $logger->info("$logPrefix Starting $productName ($buildName) on $service ");

    #
    # start the product and optionally perform migration
    #
    my $startCmd = $product->archiveDir() . "/bin/control-deployment -cluster primary "
        . " " . $product->name()
        . " " . $product->service()
        . " -buildname " . $product->buildName()
        . " install";

    unless ($skipMigration) {
        $startCmd .= " -$migrationCommand" if $migrationCommand;
        $startCmd .= " -restoreDatasetType $restoreDatasetType" if $restoreDatasetType;
        $startCmd .= " -sourceBuildname $sourceBuildname" if $sourceBuildname;
        $startCmd .= " -restoreRealmSubset $loadRealms" if $loadRealms;
    }

    $logger->info("$logPrefix Starting $productName via $startCmd");

    my $ret = $self->executeSystemCommand($startCmd);
    unless ($ret) {
        $logger->info("$logPrefix Problem starting $productName ($buildName) via $startCmd");
        return;
    }

    $logger->info("$logPrefix Done starting $productName ($buildName) via $startCmd");

    if ($conditionalMigrationCommand && ! $skipMigration) {
        $self->_saveRobotDataSet($product, $conditionalMigrationCommand);
    }

    return 1;
}

# Input 1: The product object to save using the supplied dataset type
# Input 2: The dataset type (robot-initdb or robot-restoremigrate)
# Return 1: If the dataset was saved successfully; 0 otherwise
sub _saveRobotDataSet {
    my ($self, $product, $datasetType) = @_;

    my $logger = ariba::Ops::Logger->logger();
    my $logPrefix = $self->logPrefix();

    my $productName = $product->name();
    my $buildName = $product->buildName();
    my $serviceName = $product->service();

    my $dataset = ariba::Ops::DatasetManager->newDataset($productName, $serviceName, $buildName, 1);
    if ($dataset) {
        my $datasetId = $dataset->instance();
        $logger->info("$logPrefix Saving the $datasetType dataset \"$datasetId\" (for product $productName , build $buildName, service $serviceName)");
        $dataset->setType($datasetType);
        $dataset->backupFromProduct($product, 1, 1);
        $dataset->backupRealmDirFromProduct($product);
        $logger->info("$logPrefix Done saving the $datasetType dataset \"$datasetId\"");
        return 1;
    }
    return 0;
}

# Return 1 if the archived build is classic; else 0 (incremental)
# Incremental build is requirement for performing robot-initdb; use raw initdb if an attempt is made to perform robot-initdb on a classic build
sub _isClassicBuild {
    my ($self, $archiveDir) = @_;
    my $flagfile = $archiveDir . "/internal/build/incbuildroot.tar";
    if (-f $flagfile) {
        return 0;
    }
    return 1;
}

# Return dataset that can be restored from instead of running initdb or undef if initdb must be run
sub _getRestorableRobotDataSet {
    my ($self, $productName, $datasetType, $serviceName, $buildName, $archiveDir) = @_;

    my $logger = ariba::Ops::Logger->logger();
    my $logPrefix = $self->logPrefix();

    my $dataset = ariba::Ops::DatasetManager->getRobotDataset( $productName, $datasetType, $serviceName, $buildName);

    if ($dataset) {
        my $datasetId = $dataset->instance();
        my $buildNameFromDataset = $dataset->buildName();

        my $flagfile = $archiveDir . "/internal/build/dbschemachanged";
        if (-f $flagfile) {
            open FH, "< $flagfile" or die "Can't open $flagfile : $!";
            my @f = <FH>;
            close FH;

            my $buildNameRequiringInitdb = $f[0];

            # The incremental build is expected to execute the DBSchemaChangeDetectorPlugin
            # which will generate the dbschemachanged when:
            # a) In the full incremental build case, the file will contain the build name
            # b) If a change is made to an aml (or migration related tool) then the build name is also encoded in the file
            # otherwise, any previouslt generated dbschemachanged file will be carried forwrd unchanged.

            # Now in this robot-initdb case we must run initdb (as opposed to restoring a robot-initdb dataset) when:
            # a) The dbschmachangedfile has a buildname, with a number that is > the build sequence number related to the dataset
            # If there is a dataset with a buildname with sequence number <= then we can restore that dataset.

            my ($branchPartRequiringInitdb, $buildNumberRequiringInitDb) = split(/-/, $buildNameRequiringInitdb);
            my ($branchPartFromDataset, $buildNumberFromDataset) = split(/-/, $buildNameFromDataset);

            if ($buildNumberRequiringInitDb > $buildNumberFromDataset) {
                print "The dataset \"$datasetId\" relates to build \"$buildNameFromDataset\" that is earlier than the last known build with a db schema change \"$buildNameRequiringInitdb\", so initdb must be run\n";
                return undef;
            }
            return $dataset;
        }
        else {
            print "The $flagfile file does not exist (it is expected to always exist in incremental builds), so initdb must be run\n";
        }
    }
    else {
        print "There are no restorable robot datasets for product \"$productName\" datasetType \"$datasetType\" service \"$serviceName\" for build \"$buildName\"\n";
    }
    return undef;
}

# Input 1: The dataset to restore
# Input 2: The product name to restore
# Input 3: The dataset type (robot-initdb or robot-restoremigrate)
# Input 4: The service name for this robot 
#
# Return 1: If the dataset was restored successfully; 0 otherwise
sub _restoreRobotDataSet {
    my ($self, $dataset, $productName, $datasetType, $service) = @_;

    my $logger = ariba::Ops::Logger->logger();
    my $logPrefix = $self->logPrefix();

    if ($dataset) {
        my $datasetId = $dataset->instance();
        $logger->info("$logPrefix Now restoring the $datasetType dataset \"$datasetId\" because the DB schema did not change for product $productName");

            $dataset->setMaxParallelProcesses(1);
            $dataset->setRestore(1);

            # Use the product object with the embedded config
            my $productObject = ariba::Ops::DatasetManager::Product->new($dataset);

            $dataset->restoreDBFromProduct($productObject);
            $dataset->restoreRealmDirFromProduct($productObject);

        $logger->info("$logPrefix Done restoring the $datasetType dataset \"$datasetId\"");

        $logger->info("$logPrefix Now deleting the old $datasetType datasets (except dataset \"$datasetId\")");
            ariba::Ops::DatasetManager->deleteRobotDatasets( $productName, $datasetType, $service, $datasetId);
        $logger->info("$logPrefix Done deleting the old $datasetType datasets");
        return 1;
    }
    return 0;
}

sub notifyMessage {
    my $self = shift;
    my $htmlEmail = shift;

    my $logger = ariba::Ops::Logger->logger();
    my $logPrefix = $self->logPrefix();

    my $productName = $self->productName();
    my $service = ariba::Automation::Utils->service();
    my $buildName = $self->buildName();

    return if $productName =~ /ws/;
    return unless ariba::rc::ArchivedProduct->isArchived($productName, $service, $buildName);

    my $product = ariba::rc::ArchivedProduct->new($productName, $service, $buildName);
    unless ($product) {
        $logger->error("$logPrefix could not load archived product $productName / $buildName for service $service");
        return;
    }

    my ($frontDoor, $inspectorURL, $installDir, $message);
    $frontDoor = $inspectorURL = $product->default('VendedUrls.FrontDoor');

    $inspectorURL =~ s/Main/inspector/;
    $installDir = $product->installDir();

    if ($htmlEmail) {
        $message = <<FIN;
Front Door URL: <a href="$frontDoor">$frontDoor</a><br>
Inspector URL: <a href="$inspectorURL">$inspectorURL</a><br>
FIN

    if ( grep($_ eq $productName, ariba::rc::Globals::sharedServicePlatformProducts()) ) {
        my $adminFrontDoor = $inspectorURL = $product->default('VendedUrls.AdminFrontDoorTopURL') . '/'
            . $product->default('Tomcat.ApplicationContext') . '/Main';

        $message .= <<FIN;
Service Manager URL: <a href="$adminFrontDoor">$adminFrontDoor</a><br>
Customer Sites URL: <a href="$frontDoor/ad/ss">$frontDoor/ad/ss</a><br>
Product Install Dir: <tt>$installDir</tt><br>
Application Keep Running logs Dir: <tt>/tmp/$service/$productName</tt><br>
FIN
        }
        return $message;
    }

    $message = "Front Door URL: $frontDoor\n" .
           "Inspector URL: $inspectorURL\n";

    if ( grep($_ eq $productName, ariba::rc::Globals::sharedServicePlatformProducts()) ) {
        my $adminFrontDoor = $inspectorURL = $product->default('VendedUrls.AdminFrontDoorTopURL') . '/'
            . $product->default('Tomcat.ApplicationContext') . '/Main';

        $message .= "Service Manager URL: $adminFrontDoor\n";
        $message .= "Customer Sites URL: $frontDoor/ad/ss\n";
    }

    $message .= "----\n" .
            "Product Install Dir: $installDir\n" .
            "Application Keep Running logs Dir: /tmp/$service/$productName\n";

    return $message;
}

sub getRealmIds
{
    my $product = shift;
    my $realmNames = shift;

    my $realmIds = "";

    my @names = split(",", $realmNames);
    for my $name (@names) {
        my $id;
        if ($name =~ /^\d+$/) {
            $id = $name;
        }
        else {
            my ($mainTXDBConnection) = ariba::Ops::DBConnection->connectionsForProductOfDBType($product, ariba::Ops::DBConnection->typeMain());
            my $oracleClient = ariba::Ops::OracleClient->newFromDBConnection($mainTXDBConnection);

            $oracleClient->connect() || die "connect() failed ", $oracleClient->error(), "\n";

            $id = $oracleClient->executeSql("select id from realmtab where name = '$name'");
            $oracleClient->disconnect();

            die "Could not find realm $name" unless $id;
        }

        if ($realmIds ne "") {
            $realmIds .= ",";
        }
        $realmIds .= $id;
    }

    return $realmIds;
}

1;
