#
# $Id: //ariba/services/tools/lib/perl/ariba/Ops/MigrationHelper.pm#70 $
#
# A helper class to manage migration and initialization for products
#

package ariba::Ops::MigrationHelper;

use strict;
use warnings;

use ariba::Ops::Startup::Tomcat;
use ariba::Ops::Startup::WOF;
use ariba::Ops::Startup::Apache;
use ariba::Ops::Startup::AUCCommunity;

use ariba::Ops::DBConnection;
use ariba::Ops::OracleClient;
use ariba::Ops::PersistantObject;
use ariba::Ops::DatasetManager;
use ariba::rc::Utils;
use ariba::Ops::Url;
use ariba::rc::InstalledProduct;

use ariba::Ops::HanaClient;
use base qw(ariba::Ops::PersistantObject);

sub dir { return undef; }

my %validAccessorMethods = (
    'newProduct' => 1,
    'oldProduct' => 1,
    'doInit'  => 1,
    'testing' => 1,
    'migrateCmd' => 1,
    'datasetType' => 1,
    'realmSubset' => 1,
    'logFile' => 1,
    'tenant' => 1,
);

sub validAccessorMethods {
    return \%validAccessorMethods;
}

sub newFromProduct {
    my $class = shift;
    my $passedInProduct = shift;
    my $cluster = shift;

    my $product;

    # we want an InstalledProduct
    if ($passedInProduct->isa('ariba::rc::ArchivedProduct')) {
        $product = ariba::rc::InstalledProduct->new(
                    $passedInProduct->name(),
                    $passedInProduct->service(),
                    $passedInProduct->buildName(),
                    $passedInProduct->customer()
        );
    } else {
        # $product->isa('ariba::rc::InstalledProduct')
        $product = $passedInProduct;
    }

    $product->setClusterName($cluster) if ($cluster);

    my $instanceName = $product->name();
    $instanceName .= $product->customer() if $product->customer();
    $instanceName .= "-migration-helper";

    my $self = $class->SUPER::new($instanceName);

    $self->setNewProduct($product);
    $self->setDoInit(0);

    # setup environment so that migration runs in the same env as
    # apps
    if ($self->isDrupalProduct){
        ariba::Ops::Startup::Apache::setRuntimeEnv($product);
    } elsif ($self->isNetworkProduct()) {
        ariba::Ops::Startup::WOF::setRuntimeEnv($product);
    } elsif ($self->isPlatformProduct()) {
        ariba::Ops::Startup::Tomcat::setRuntimeEnv($product);
    }

    return $self;
}

sub isDrupalProduct {
    my $self = shift;

    ## See if the drupal directory exists, if it does, we're a Drupal product
    my $dir = $self->newProduct()->installDir() . "/drupal";
    return -x $dir;
}

sub isArchesProduct {
    my $self = shift;
    my $productName = $self->newProduct()->name();

    return 1 if (grep(/$productName$/, ariba::rc::Globals::archesProducts()));
    return 0;
}

sub isPlatformProduct {
    my $self = shift;

    my $installDir = $self->newProduct()->installDir();

    if (    -x "$installDir/bin/initdb"      # e.g. s4
         || -x "$installDir/base/bin/initdb" # e.g. anl/acm
       ) {

        return 1;
    }

    return 0;
}

sub isNetworkProduct {
    my $self = shift;

    return -d $self->_networkProductScriptDir();
}

sub runMigrationCommands {
    my $self = shift;

    my $result = 0;

    if ($self->newProduct()->default('Ops.MigrationType') eq 'simple') {
        $result = $self->_runSimpleMigration();
    } elsif ($self->isDrupalProduct()) {
        $result = $self->_runDrupalMigration();
    } elsif ($self->isArchesProduct()) {
        $result = $self->_runArchesMigration();
    } elsif ($self->isPlatformProduct()) {
        $result = $self->_runPlatformMigration();
    } elsif ($self->isNetworkProduct()) {
        $result = $self->_runNetworkMigration();
    } else {
        print "Warning: Could not run migration: ", $self->newProduct()->name(),"
        seems to be neither platform nor network\n";
    }

    return $result;
}

sub _runSimpleMigration {
    my $self = shift;
    my $product = $self->newProduct();
    my $installDir = $product->installDir();
    my $migDir = "$installDir/dbmigration/scripts";
    my $master = ariba::rc::Passwords::lookup("master");
    if ($self->migrateCmd() eq "migrate") {
        chdir $migDir or die "Can't cd to $migDir: $!";
        $ENV{'ARIBA_CONFIG_ROOT'} = "$installDir/config";
        my $cmd = "./MigrationHelper";
        print "Running $cmd\n";
        $cmd .= " $master";
        open(CMD, "|$cmd") or die "MigrationHelper: can't fork: $!";
        close(CMD);
    }
    return 1;
}

sub _runDrupalMigration {
    my $self = shift;
    my $product = $self->newProduct();

    if ($self->doInit()) {
        ariba::Ops::Startup::AUCCommunity::runDrupalInstall( $product->installDir(), $product );
    } else {
        ariba::Ops::Startup::AUCCommunity::runDrupalUpgrade( $product->installDir() );
    }

    ## Return success
    return 1;
}

sub _runPlatformMigration {
    my $self = shift;

    my $product = $self->newProduct();

    my $build = $product->buildName();
    my $name = $product->name();
    my $service = $product->service();
    my $installDir = $product->installDir();
    my $releaseName = $product->releaseName();

    my @commands;

    my $internalBin = "$installDir/internal/bin";
    my $initScript = "$internalBin/addandinitrealms";

    my $migration_warning_msg = "Warning: migration commands for platform products not implemented\n";

    # step 1. Collect commands to be run
    if ( (grep { $name eq $_ }
                    (ariba::rc::Globals::sharedServiceSourcingProducts(),
                        ariba::rc::Globals::sharedServiceBuyerProducts()) )
        &&
            ( -x $initScript )
        ) {
        if ($self->doInit()) {
            my $numRealms = $product->default('Ops.InitialRealmCount') || 2;
            my $shouldAddHanaRealms = $product->default('Ops.ShouldAddHanaRealms') || '' ;
            print "Migration Helper: shouldAddHanaRealms: $shouldAddHanaRealms";
            my $hanaRealmAdditionFlag = ($shouldAddHanaRealms && $shouldAddHanaRealms eq "true") ? "-hana" : "";

            push(@commands, "$initScript -readMasterPassword -add $numRealms -completeinit $hanaRealmAdditionFlag");
            #
            # Enable realms as needed
            #
            my $enableRealms = "$internalBin/enablerealms";
            if ( -x $enableRealms) {
                push(@commands, "$enableRealms -readMasterPassword");
            }
        }
        elsif ($self->migrateCmd() eq "restoremigrate") {

            my $migrateScript = "/usr/local/ariba/bin/ops-migrate-ss";

            my ($datasetType) = $self->datasetType() || ariba::Ops::DatasetManager->validDatasetTypesForProductName($name);

            my $cmd = "$migrateScript -service $service -product $name -targetBuild $build -datasetType $datasetType -noui";

            if ($self->realmSubset()) {
                $cmd .= " -restoreRealmSubset " . $self->realmSubset();
            }

            if ($self->logFile()) {
                $cmd .= " -log " . $self->logFile() ;
            }

            push(@commands, $cmd);
        }
        elsif ($self->migrateCmd() eq "restoreonly") {
            my $migrateScript = "/usr/local/ariba/bin/ops-migrate-ss";
            my ($datasetType) = $self->datasetType() || ariba::Ops::DatasetManager->validDatasetTypesForProductName($name);

            # restoreonly performs only steps 5 to steps 13.5 of the MCL. We need to change here, if the MCL steps are changed.
            my $cmd = "$migrateScript -service $service -product $name -targetBuild $build -datasetType $datasetType -startStep 5 -endStep 13.5 -noui";

            if ($self->realmSubset()) {
                $cmd .= " -restoreRealmSubset " . $self->realmSubset();
            }

            if ($self->logFile()) {
                $cmd .= " -log " . $self->logFile() ;
            }

            push(@commands, $cmd);
        }
        elsif ($self->migrateCmd() eq "migrate") {

        # Making a change for this to make use of ops-migrate-ss instead of
        # migrate_ss. migrates is normally used from the command line.
        # Using ops-migrate-ss gives us the advantage of setting up school schema
        # and other steps which are done on internal services

            my $migrateScript = "/usr/local/ariba/bin/ops-migrate-ss";

            # Do not take the dataset here
            #my ($datasetType) = $self->datasetType() || ariba::Ops::DatasetManager->validDatasetTypesForProductName($name);

            my $oldProduct = $self->oldProduct();
            my $srcBuildName = $oldProduct->buildName();

            # Migrate performs step number 14 to last step
            my $cmd = "$migrateScript -service $service -product $name -targetBuild $build -srcBuild $srcBuildName -startStep 14 -noui";
            if ($self->realmSubset()) {   ## Not sure if this is needed for migrate only option.
                $cmd .= " -restoreRealmSubset " . $self->realmSubset();
            }

            if ($self->logFile()) {
                $cmd .= " -log " . $self->logFile() ;
            }

            push(@commands, $cmd);

            #my $oldProduct = $self->oldProduct();
            #my $oldProductDir = $oldProduct->installDir();

            #my $migratessScript = "$internalBin/migrate_ss";
            #my $migratessConfig = "$installDir/etc/migration/" . $releaseName . "/migrate_ss.txt";
            #push(@commands, "$migratessScript -readMasterPassword -configFile $migratessConfig -oldBuild $oldProductDir -newBuild $installDir");
        }
        elsif ($self->migrateCmd() eq "loadmeta") {
            $initScript = "$installDir/bin/initdb";
            push(@commands, "$initScript -loadmeta -readMasterPassword");
        }

    } elsif ( -x ($initScript = "$installDir/base/bin/builddb")) {
        if ($self->doInit()) {
            push(@commands, "$initScript -readMasterPassword");
        } else {
            print $migration_warning_msg;
        }
    } elsif ( -x ($initScript = "$installDir/base/bin/initdb")) {
        if ($self->doInit()) {
            push(@commands, "$initScript -initdb -readMasterPassword");
        } else {
            print $migration_warning_msg;
        }
    } elsif ( -x ($initScript = "$installDir/bin/initdb")) {
        if ($self->doInit()) {
            push(@commands, "$initScript -initdb -readMasterPassword");
        } else {
            print $migration_warning_msg;
        }
    }

    my $host;
    for my $migrationRole ('asmui', 'buyerui', 'buyer', 'sourcing-node', 'database' ) {
        $host = ($product->hostsForRoleInCluster($migrationRole, 'primary'))[0];
        last if ($host);
    }

    # step 2. run migration/init commands
    my $ret = 0;
    my $master = ariba::rc::Passwords::lookupMasterPci($product);
    my $unixUser = $product->deploymentUser();
    my $password = ariba::rc::Passwords::lookup($unixUser);

    my $ssh = ariba::Ops::DeploymentHelper::sshWhenNeeded($unixUser, $host, $service);

    if (@commands && $host) {
        for my $command (@commands) {

            my $launchCmd = $command;
            if ($ssh) {
                $launchCmd = "$ssh '$command'";
            }

            print("$launchCmd\n");

            if ($ssh) {

                $ret = ariba::rc::Utils::sshCover(
                        $launchCmd,
                        $password,
                        $master
                        ) unless ($self->testing());

            } else {

                $ret = ariba::rc::Utils::localCover(
                    $launchCmd,
                    $master,
                    undef,
                    ) unless ($self->testing());

            }
            #
            # if one of the commands fails, dont run the next
            # one
            #
            if($ret != 0) {
                print "ERROR: [$launchCmd] failed, status [$ret]\n";
                last;
            }
        }
    }

    if ($ret != 0) {
        print "ERROR: failed to perform db migration in migrateDatabase().\n";
        print "       One of more migration commands failed.\n";
        return 0;
    }

    return 1;
}

#
# This is for network products.  After AN48 this will only be for AN.
#
# Returns (perl) true on success, false on failure
#
sub _runNetworkMigration {
    my $self = shift;

    my $dir = $self->_networkProductScriptDir();
    my $product = $self->newProduct();

    my $name = $product->name();
    my $service = $product->service();

    return unless -d $dir;

    # NOTE:  later, $ret is used with the &&= operator.  This works as follows, remembering the && is a short circuit operator, which will
    # check its second arg only if the first is TRUE.  $ret begins life as TRUE.  The first time &&= is seen, TRUE is the left side and
    # the result of the method call is the right side.  If both are TRUE, the result remains TRUE.  If the method call returns FALSE, the
    # result will be FALSE, which is then stored in $ret.  From the point of the first failure, on, the test will always have FALSE as the
    # left side, and $ret will remain FALSE, regardless of the success or failure of all subsequent method calls.  Presumably, this was used
    # to allow all the processing to be done, regardless of possible intermediate failures, while still returning a FALSE condition.
    my $ret = 1;

    my (@dbcsForEstore) = (

        ariba::Ops::DBConnection->connectionsForProductOfDBTypeAndInCommunity($product, ariba::Ops::DBConnection->typeMainEStoreBuyer())

    );



    my (@dbcsForMain) = (

        ariba::Ops::DBConnection->connectionsForProductOfDBTypeAndInCommunity($product, ariba::Ops::DBConnection->typeMain()),
        ariba::Ops::DBConnection->connectionsForProductOfDBTypeAndInCommunity($product, ariba::Ops::DBConnection->typeMainSupplier()),
        ariba::Ops::DBConnection->connectionsForProductOfDBTypeAndInCommunity($product, ariba::Ops::DBConnection->typeMainBuyer()),

    );

    my (@dbcsForEdi) = (
        ariba::Ops::DBConnection->connectionsForProductOfDBTypeAndInCommunity($product, ariba::Ops::DBConnection->typeMainEdi()),
    );

    my (@dbcsForHana) = (
        ariba::Ops::DBConnection->connectionsForProductOfDBTypeAndInCommunity($product, ariba::Ops::DBConnection->typeHana()),
        ariba::Ops::DBConnection->connectionsForProductOfDBTypeAndInCommunity($product, ariba::Ops::DBConnection->typeHanaSupplier()),
    );

    # If we have scripts that can migrate the db, use them,
    # else punt!
    #
    if ($self->doInit()) {
        print "Warning: init not implemented for network products\n";
        return 0;

    } elsif ($self->migrateCmd() eq "restoremigrate") {

        # first try the specified type or use service for type
        my ($type) = $self->datasetType() || $service;
        my ($dataSet) = ariba::Ops::DatasetManager->listBaselineRestoreCandidatesForProductAndTypeByModifyTime($product, $type);

        # fall back on whatever is first (default) type for this product
        if (!$dataSet) {
            ($type) = ariba::Ops::DatasetManager->validDatasetTypesForProductName($name);
            ($dataSet) = ariba::Ops::DatasetManager->listBaselineRestoreCandidatesForProductAndTypeByModifyTime($product, $type);
        }

        print "Restoring from dataset " . join(".", $dataSet->productName(), $dataSet->buildName(), $dataSet->instance()) . "\n";
        unless ($dataSet && $dataSet->restoreDBFromProduct($product)) {
            print "ERROR: failed to restore schemas from dataset\n";
            return 0;
        }

        #
        # run post-restore migrate scripts;
        # _runNetworkMclFromDBConnection will bail if the script
        # doesn't exist
        #
        my $anRestoreMigrateMcl = "$dir/../../$name/scripts/restore/an_restoremigrate.mcl";
        $ret &&= $self->_runNetworkMclFromDBConnections($anRestoreMigrateMcl, @dbcsForMain);

        my $ediRestoreMigrateMcl = "$dir/../../$name/scripts/restore/edi_restoremigrate.mcl";
        $ret &&= $self->_runNetworkMclFromDBConnections($ediRestoreMigrateMcl, @dbcsForEdi);
    }

    #
    # Get the directory connection only; an*sql scripts will guess the other usernames and passwords.
    #
    my $anmcl = "$dir/../../$name/scripts/auto-migrate.mcl";




    if ($name eq 'estore') {
        $ret &&= $self->_runNetworkMclFromDBConnections($anmcl, @dbcsForEstore);
    } else {
        if (@dbcsForHana)
        {
            my $hanamcl = "$dir/../../$name/scripts/hana/auto-migrate.mcl";
            $ret &&= $self->_runNetworkMclFromHanaDBs($hanamcl, @dbcsForHana);
        }

        $ret &&= $self->_runNetworkMclFromDBConnections($anmcl, @dbcsForMain);

        #
        # Running EDI auto-migrate.mcl
        #

        # Since the DBs are seperate, we are invoking EDI MCL once the AN MCL is done.
        my $edimcl = "$dir/../../$name/scripts/edi/auto-migrate.mcl";

        $ret &&= $self->_runNetworkMclFromDBConnections($edimcl, @dbcsForEdi);
    }

    return $ret;
}

# NOTE:  this method is a copy/paste/edit of 'sub _runNetworkMclFromDBConnections', below.  Changes are the
#        minimal set needed to support the HANA database environment, with some minor changes to code.
sub _runNetworkMclFromHanaDBs {
    my $self = shift;
    my $mcl= shift;
    my @dbcs = @_;

    unless (scalar(@dbcs)) {
        print "Skipping $mcl due to missing database connection information\n";
        return 1;
    }

    my $product = $self->newProduct();
    my $build = $product->buildName();
    my $service = $product->service();
    my $productName = $product->name();

    my $primaryDbc = $dbcs[0];
    my $type = $primaryDbc->type();

    my $dir = $self->_networkProductScriptDir();

    my $masterPassword = ariba::rc::Passwords::lookup("master");

    if (-f $mcl) {
        #
        # Why not use connectStringForSidOnHost?  sqlldr doesn't support
        # "sqlldr foo/bar@(DESCRIPTION=...)" (like sqlplus does), so we
        # have to generate a temp TNS_ADMIN for it.  This is what
        # _initializeExportImportENV does.
        #
        my $hc = ariba::Ops::HanaClient->newFromDBConnection($primaryDbc);

        my $oldPath = $ENV{PATH};
        # This may not be needed, adding anyway.  This is the "proper" way to find hdbsql, per Dana.  If hdbsql is not here,
        # it is not our problem, the problem is an incorrect installation.
        $ENV{PATH} = "/opt/sap/hdbclient:" . $ENV{PATH};

        my $oldPWD = $ENV{PWD};
        # anhdbsql currently requires that it be run from this dir
        chdir $dir or die "Can't cd to $dir: $!";

        my $command = "bin/anhdbsql -site $type -build $build -batch $mcl -service $service -product $productName";
        print $command, "\n";

        my $CMD;
        open($CMD, '|', "$command") or die "MigrationHelper: can't fork: $!";
        print $CMD "$masterPassword\n";
        close($CMD);

        my $ret = $?;

        $ENV{PATH} = $oldPath;
        chdir $oldPWD or die "Can't cd to $oldPWD: $!";

        if ($ret != 0) {
            print "ERROR: '$command' failed\n",
                  "       failed to perform db migration in migrateDatabase().\n",
                  "       One of more migration commands failed.\n";
            return 0;
        }
    } else {
        print "MCL $mcl doesn't exist, skipping auto-migration\n";
    }

    return 1;
}
sub _runArchesMigration {
    my $self = shift;

    my $product = $self->newProduct();

    my $build = $product->buildName();
    my $name = $product->name();
    my $service = $product->service();
    my $installDir = $product->installDir();
    my $releaseName = $product->releaseName();
    my $appInstalled = $product->hasBeenInstalled();

    my @commands;

    my $initScript = "$installDir/bin/initdb";
    my $migration_warning_msg = "Warning: migration commands for arches products not implemented\n";

    # step 1. Collect commands to be run
    if ( (grep { $name eq $_ } (ariba::rc::Globals::archesProducts()) ) && ( -x $initScript )) {

        if ($self->doInit()) {

            # Delete shard dirs before running initdb
            unless (ariba::Ops::DatasetManager->cleanupArchesShards($product)) {
                return 0;   #got an error
            }

            my $javaHome = $ENV{'JAVA_HOME'} = ariba::Ops::Startup::Common::javaHomeForProduct($product);
            my $cmd = "bash -c \"export JAVA_HOME=$javaHome; $initScript -all\"";

            if ($self->logFile()) {
                $cmd .= " -log " . $self->logFile() ;
            }
            push(@commands, $cmd);
        } elsif ($self->migrateCmd() eq "restoremigrate") {
            # first try the specified type or use service for type
            my ($type) = $self->datasetType() || $service;
            my ($dataSet) = ariba::Ops::DatasetManager->listBaselineRestoreCandidatesForProductAndTypeByModifyTime($product, $type);

            # fall back on whatever is first (default) type for this product
            if (!$dataSet) {
                ($type) = ariba::Ops::DatasetManager->validDatasetTypesForProductName($name);
                ($dataSet) = ariba::Ops::DatasetManager->listBaselineRestoreCandidatesForProductAndTypeByModifyTime($product, $type);
            }

            my $cdh5;
            if($product->name() =~/arches/i && $product->default('isCDH5')){
                $cdh5 = 1;
                print "\n CDH5 Restore..\n"
            }
            my $restoreOutput;
            if($cdh5){
                    $restoreOutput = $dataSet->restoreHbaseFromProduct_cdh5($product, $self->tenant() );
            }
            else{
                    $restoreOutput = $dataSet->restoreHbaseFromProduct($product, $self->tenant() );
            }

            unless ($restoreOutput == 1) {
                print "ERROR: failed to perform restore.\n";
                return 0;
            }

            my $migrateScript = "/usr/local/ariba/bin/ops-migrate-arches";
            my ($datasetType) = $self->datasetType() || ariba::Ops::DatasetManager->validDatasetTypesForProductName($name);
            my $cmd = "$migrateScript -service $service -product $name -targetBuild $build -datasetType $datasetType -startStep 6 -noui";

            if ($self->logFile()) {
                $cmd .= " -log " . $self->logFile() ;
            }

            push(@commands, $cmd);
        } elsif ($self->migrateCmd() eq "restoreonly") {
            my ($datasetType) = $self->datasetType() || ariba::Ops::DatasetManager->validDatasetTypesForProductName($name);
            my ($type) = $self->datasetType() || $service;
            my ($dataSet) = ariba::Ops::DatasetManager->listBaselineRestoreCandidatesForProductAndTypeByModifyTime($product, $type);

            # fall back on whatever is first (default) type for this product
            if (!$dataSet) {
                ($type) = ariba::Ops::DatasetManager->validDatasetTypesForProductName($name);
                ($dataSet) = ariba::Ops::DatasetManager->listBaselineRestoreCandidatesForProductAndTypeByModifyTime($product, $type);
            }

            my $cdh5;
            if($product->name() =~/arches/i && $product->default('isCDH5')){
                $cdh5 = 1;
            }
            my $restoreOutput;
            if($cdh5){
                    $restoreOutput = $dataSet->restoreHbaseFromProduct_cdh5($product, $self->tenant() );
            }
            else{
                    $restoreOutput = $dataSet->restoreHbaseFromProduct($product, $self->tenant() );
            }


            unless ($restoreOutput == 1) {
                print "ERROR: failed to perform restore.\n";
                return 0;
            }
        } elsif ($self->migrateCmd() eq "migrate") {
            my $migrateScript = "/usr/local/ariba/bin/ops-migrate-arches";

            my $oldProduct = $self->oldProduct();
            my $srcBuildName = $oldProduct->buildName();

            # Migrate performs step number 8 to last step
            my $cmd = "$migrateScript -service $service -product $name -targetBuild $build -srcBuild $srcBuildName -startStep 6 -noui";

            if ($self->logFile()) {
                $cmd .= " -log " . $self->logFile() ;
            }

            push(@commands, $cmd);
        }
    }

    my $host;
    for my $migrationRole ('indexmgr' ) {
        $host = ($product->hostsForRoleInCluster($migrationRole, 'primary'))[0];
        last if ($host);
    }

    # step 2. run migration/init commands
    my $ret = 0;
    my $master = ariba::rc::Passwords::lookup('master');
    my $unixUser = $product->deploymentUser();
    my $password = ariba::rc::Passwords::lookup($unixUser);

    my $ssh = ariba::Ops::DeploymentHelper::sshWhenNeeded($unixUser, $host, $service);

    if (@commands > 0 && $host) {
        for my $command (@commands) {
            my $launchCmd = $command;
            if ($ssh) {
                $launchCmd = "$ssh '$command'";
            }

            print("$launchCmd\n");

            if ($ssh) {
                $ret = ariba::rc::Utils::sshCover(
                $launchCmd,
                $password,
                $master
                ) unless ($self->testing());
            } else {
                $ret = ariba::rc::Utils::localCover(
                    $launchCmd,
                    $master,
                    undef,
                    ) unless ($self->testing());
            }
            #
            # if one of the commands fails, dont run the next one
            #
            if($ret != 0) {
                print "ERROR: [$launchCmd] failed, status [$ret]\n";
                last;
            }
        }
    }

    if ($ret != 0) {
        print "ERROR: failed to perform db migration in migrateDatabase().\n";
        print "       One of more migration commands failed.\n";
        return 0;
    }
    return 1;
}

sub _runNetworkMclFromDBConnections {
    my $self = shift;
    my $mcl= shift;
    my @dbcs = @_;

    unless (scalar(@dbcs)) {
        print "Skipping $mcl due to missing database connection information\n";
        return 1;
    }

    my $product = $self->newProduct();
    my $build = $product->buildName();
    my $service = $product->service();
    my $productName = $product->name();

    my $mainDbc = $dbcs[0];
    my $type = $mainDbc->type();

    my $dir = $self->_networkProductScriptDir();

    my $masterPassword = ariba::rc::Passwords::lookup("master");

    if (-f $mcl) {

        #
        # Why not use connectStringForSidOnHost?  sqlldr doesn't support
        # "sqlldr foo/bar@(DESCRIPTION=...)" (like sqlplus does), so we
        # have to generate a temp TNS_ADMIN for it.  This is what
        # _initializeExportImportENV does.
        #
        my $oc = ariba::Ops::OracleClient->newFromDBConnection($mainDbc);

        my ($previousOracleHome, $previousSharedLibraryPath, $previousTnsAdmin, $previousNLSLang, $tnsDir) = $oc->setupOracleENVForDBCs(@dbcs);

        my $oldPath = $ENV{PATH};
        $ENV{PATH} = $ENV{ORACLE_HOME} . "/bin:" . $ENV{PATH};

        my $oldPWD = $ENV{PWD};
        # andbsql currently requires that it be run from this dir
        chdir $dir or die "Can't cd to $dir: $!";

        my $command = "bin/andbsql -site $type -build $build -batch $mcl -service $service -product $productName";
        print $command, "\n";

        open(CMD, "|$command") or die "MigrationHelper: can't fork: $!";
        print CMD "$masterPassword\n";
        close(CMD);

        my $ret = $?;

        $oc->cleanupOracleENV($previousOracleHome, $previousSharedLibraryPath, $previousTnsAdmin, $previousNLSLang, $tnsDir);
        $ENV{PATH} = $oldPath;
        chdir $oldPWD or die "Can't cd to $oldPWD: $!";

        if($ret != 0) {
            print "ERROR: [$command] failed\n";
        }

        if ($ret != 0) {
            print "ERROR: failed to perform db migration in migrateDatabase().\n";
            print "       One of more migration commands failed.\n";
            return 0;
        }
    } else {
        print "MCL $mcl doesn't exist, skipping auto-migration\n";
    }

    return 1;
}

sub _networkProductScriptDir {
    my $self = shift;

    my $product = $self->newProduct();

    return $product->installDir() . "/lib/sql/common/scripts";
}

sub runPostMigrationCommands {
    my $self = shift;

    my $returnValue = 1;

    if ($self->isPlatformProduct()) {
        my $product = $self->newProduct();

        # this is only needed for hawk/10s1 SP to SP migrations; this is
        # fixed starting in 10s2 by scheduling these during presql
        # generate and apply
        if ($product->releaseName() =~ /^10s1/ && $product->name() =~ /s4/) {

            my $waitTime = 12*60;
            print "Will schedule post-migration dataloads, waiting $waitTime secs for global task nodes to come up...\n";

            my @globalTaskInstances = $product->appInstancesWithNameInCluster('GlobalTask');

            if (ariba::Ops::Startup::Common::waitForAppInstancesToInitialize(\@globalTaskInstances, $waitTime)) {
                for my $instance (@globalTaskInstances) {
                    next unless $instance->isUp();

                    my $url = ariba::Ops::Url->new($instance->postUpgradeTaskURL("None.Task.PostRollingUpgradeTaskForSP"));
                    my $response = $url->request();

                    my $errorString;
                    if ($response =~ /HTTP 404: Not Found Error/) {
                        $errorString = $response;
                    }
                    if ($url->error()) {
                        $errorString = $url->error();
                    }

                    if ($errorString) {
                        print "ERROR: could not schedule post-migration dataloads: $errorString\n";
                        $returnValue = 0;
                    } else {
                        print "Post-migration tasks scheduled successfully\n";
                    }
                }

            }
        }
    }

    return $returnValue;
}

1;
