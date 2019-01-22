package ariba::Ops::MigrationHelper::SSExport;
#
# manage shared service products exports
#

use strict;

use IO::Dir;
use File::Basename;
use FindBin;

use ariba::rc::Utils;

use ariba::Ops::PersistantObject;
use ariba::Ops::DBConnection;
use ariba::Ops::Startup::Common;
use ariba::Ops::OracleClient;

use base qw(ariba::Ops::PersistantObject);

#
# exportName => name of the export directory where the db dump files
#   and realms archive will be kept
#
# service => name of the service export will be done from
#
# productName => name of the product export is done for
#

sub newFromDetails {
	my $class = shift;
	my $detailsRef = shift;

	my $productName = $detailsRef->{'productName'};
	my $service     = $detailsRef->{'service'};
	my $exportName  = $detailsRef->{'exportName'};

	my $self = $class->SUPER::new($exportName.$service.$productName);

	$self->setExportName($exportName);
	$self->setProductName($productName);
	$self->setServiceName($service);

	return $self;
}

#
# instance methods
#

sub restoreSchemasToProduct {
	my $self = shift;
	my $product = shift;
	my $masterPassword = shift;

	my $class = ref($self);
	my $installDir = $product->installDir();

	my $logger = ariba::Ops::Logger->logger();

    my @connections = (ariba::Ops::DBConnection->connectionsForProductOfDBType($product, ariba::Ops::DBConnection->typeMain() ),
                ariba::Ops::DBConnection->connectionsForProductOfDBType($product, ariba::Ops::DBConnection->typeMainStarDedicated()),
                ariba::Ops::DBConnection->connectionsForProductOfDBType($product, ariba::Ops::DBConnection->typeMainStarShared())
    );

	my $exportDir = $self->exportDir();
	my @exportFiles = $self->dbExportFiles();

    #
    # match up files with target schemas
    #
    my %fileToDbcHash = ();

	$logger->info("checking file to schema mapping \n");

    for my $file (@exportFiles) {
		my $dbc;
        for $dbc (@connections) {
            if ($class->compareDBConnectionWithFilename($dbc, $file)) {
                unless (exists $fileToDbcHash{$file}) {
                    $fileToDbcHash{$file} = $dbc;
                } else {
                    my $oldDbc = $fileToDbcHash{$file};
					$logger->error("multiple files for " . join("/", $dbc->user(), $dbc->sid(), $dbc->host(), $dbc->type(), $dbc->schemaId())
                    	. ", previous dbc = " . join("/", $oldDbc->user(), $oldDbc->sid(), $oldDbc->host(), $oldDbc->type(), $oldDbc->schemaId()));
					return;
                }
            }
        }
    }

    #
    # validate that we have all schemas in target product matched to
    # dump files
    #
    if (scalar keys %fileToDbcHash != scalar @connections) {
        my @haveDbc = values %fileToDbcHash;
        my @missing = ();
		my $dbc;
        for $dbc (@connections) {
            next if (grep {$dbc == $_} @haveDbc);
            push (@missing, $dbc);
        }
        $logger->error("missing files for the following schemas:\n" . join("\t\n", map( {  $_->user() . "/" . $_->sid() . " ( " . $_->type() . "_". $_->schemaId() . " )" } @missing)));
		return;
    }

    foreach my $file (keys %fileToDbcHash) {

		my $dbc = $fileToDbcHash{$file};
        my ($sid, $schema, $password, $host) = ($dbc->sid(), $dbc->user(), $dbc->password(), $dbc->host());

        $logger->debug("sid      = $sid");
        $logger->debug("schema   = $schema");
        $logger->debug("host     = $host");

		if ($file =~ /\.gz$/) {
			$logger->info("unzipping $exportDir/$file");
			system("gunzip $exportDir/$file");
			if ($?) {
				$logger->error("Could not unzip $exportDir/$file, gzip returned ". ($?>>8));
				exit(1);
			}
			$file =~ s/\.gz$//;
		}

		# this file should come from the newer build, which is presumably
		# where we were called from, so use FindBin to locate it.

		#FIXME should this be the target build or src build
        my $dropSqlFile = "$FindBin::Bin/../internal/lib/sql/drop-db-objects.sql";

        $logger->info("Cleaning schema $schema\@$sid using $dropSqlFile");

		my $oracleClient = ariba::Ops::OracleClient->newFromDBConnection($dbc);
		if ($self->testing()) {
			$logger->info("DRYRUN: would run $dropSqlFile using ariba::Ops::OracleClient::executeSqlFile()");
		} else {
			unless ($oracleClient->executeSqlFile($dropSqlFile)) { 
				$logger->error("Failed to run $dropSqlFile: " . $oracleClient->error());
				return;
			}
		}

		$logger->debug("Finished cleaning schema $schema\@$sid.");

		$logger->info("Importing schema $schema\@$sid from $exportDir/$file...");

		my $schemaIdString = "";
		$schemaIdString = "-" . $dbc->schemaId() if $dbc->schemaId();

		my $svcExpImpType = "";
		if ($dbc->type() eq ariba::Ops::DBConnection::typeMainStarShared()) {
			$svcExpImpType = "-sharedstar";
		} elsif ($dbc->type() eq ariba::Ops::DBConnection::typeMainStarDedicated()) {
			$svcExpImpType = "-dedicatedstar";
		}

		my $exportSchema = $self->schemaFromFilename($file);

		my $importCmd = "$FindBin::Bin/svc-exp-imp -i -f $exportDir/$file -noprompt " . $product->name() . " " . $product->service() . " $svcExpImpType $schemaIdString -fromUser $exportSchema";

		if ($self->testing()) {
			$logger->info("DRYRUN: $importCmd");
		} else {
			unless (ariba::Ops::Startup::Common::runCommandAndFeedMasterPassword($importCmd, $masterPassword)) {
				$logger->error("Import $schema\@$sid failed");
				$logger->error("Check import log for errors");
				return;
			}
		}
	}
    return 1;
}

sub restoreRealmRootToProduct {
	my $self = shift;
	my $product = shift;

	my $logger = ariba::Ops::Logger->logger();

	## 6. restore RealmsRoot Directory
	my $realmRootDir = $product->default('System.Base.RealmRootDir');
	if (-d $realmRootDir) {
		$logger->debug("Debug: Cleaning realms at $realmRootDir ...");

		if ($self->testing()) {
			$logger->info("DRYRUN: would recursively delete $realmRootDir\n");
		} else {
			unless (ariba::rc::Utils::rmdirRecursively($realmRootDir)) {
				$logger->error("failed to remove $realmRootDir: $@");
				return;
			}
		}
	}

	my $realmsZipFile = $self->exportDir() . "/" . $self->realmsRootArchiveFilename();
	my $realmRootDirParent = dirname($realmRootDir);

	## 6.2. untar RealmsRoot backup into RealmsRoot directory
	$logger->info("Restoring RealmsRoot $realmRootDir from $realmsZipFile");

	my $untarCmd = tarCmd() . " zxf $realmsZipFile -C $realmRootDirParent";

	if ($self->testing()) {
		$logger->info("DRYRUN: would restore realms via '$untarCmd'");
	} else {
		if (r($untarCmd)) {
			$logger->error("Failed to restore $realmRootDir");
			$logger->error("$untarCmd returned " . ($? >> 8));
			return;
		}
	}

	return 1;
}

sub exportSchemasFromProduct {
	my $self = shift;
	my $product = shift;
	my $masterPassword = shift;

	my $class = ref($self);
	my $installDir = $product->installDir();

	my $logger = ariba::Ops::Logger->logger();

    my @connections = (ariba::Ops::DBConnection->connectionsForProductOfDBType($product, ariba::Ops::DBConnection->typeMain() ),
                ariba::Ops::DBConnection->connectionsForProductOfDBType($product, ariba::Ops::DBConnection->typeMainStarDedicated()),
                ariba::Ops::DBConnection->connectionsForProductOfDBType($product, ariba::Ops::DBConnection->typeMainStarShared())
    );

	my $exportDir = $self->exportDir();

	unless (ariba::rc::Utils::mkdirRecursively($exportDir)) {
		$logger->error("Failed to create dir $exportDir: $!");
		return;
	}

	for my $dbc (@connections) {
		my $file = $class->_exportFilenameForDBC($dbc);

        my ($sid, $schema, $password, $host) = ($dbc->sid(), $dbc->user(), $dbc->password(), $dbc->host());

        $logger->debug("sid      = $sid");
        $logger->debug("schema   = $schema");
        $logger->debug("host     = $host");

		my $svcExpImpType = "";
		if ($dbc->type() eq ariba::Ops::DBConnection::typeMainStarShared()) {
			$svcExpImpType = "-sharedstar";
		} elsif ($dbc->type() eq ariba::Ops::DBConnection::typeMainStarDedicated()) {
			$svcExpImpType = "-dedicatedstar";
		}
		
		$logger->info("Exporting schema $schema\@$sid to $exportDir/$file...");

		my $schemaIdString = "";
		$schemaIdString = "-" . $dbc->schemaId() if $dbc->schemaId();

		my $exportCmd = "$FindBin::Bin/svc-exp-imp -e -f $exportDir/$file -noprompt " . $product->name() . " " . $product->service() . " $svcExpImpType $schemaIdString -fromUser $schema";

		if ($self->testing()) {
			$logger->info("DRYRUN: $exportCmd");
		} else {
			unless (ariba::Ops::Startup::Common::runCommandAndFeedMasterPassword($exportCmd, $masterPassword)) {
				$logger->error("Export $schema\@$sid failed");
				$logger->error("Check export log for $exportDir/$file for errors");
				return;
			}
		}
	}
    return 1;
}

sub exportRealmRootFromProduct {
	my $self = shift;
	my $product = shift;

	my $logger = ariba::Ops::Logger->logger();

	my $realmRootDir = $product->default('System.Base.RealmRootDir');
	my $exportDir = $self->exportDir();
	my $realmsZipFile = "$exportDir/" . $self->realmsRootArchiveFilename();
	my $realmRootDirParent = dirname($realmRootDir);

	$logger->debug("Creating $exportDir");

	unless (ariba::rc::Utils::mkdirRecursively($exportDir)) {
		$logger->error("Failed to create dir $exportDir: $!");
		return;
	}
	
	## 6.2. create a tar of RealmsRoot directory
	$logger->info("Creating RealmsRoot $realmsZipFile from $realmRootDir" );

	my $tarCmd = tarCmd() . " zcf $realmsZipFile -C $realmRootDirParent realms";

	if ($self->testing()) {
		$logger->info("DRYRUN: would create $realmsZipFile via '$tarCmd'");
	} else {
		if (r($tarCmd)) {
			$logger->error("Failed to create $realmsZipFile");
			$logger->error("$tarCmd returned " . ($? >> 8));
			return;
		}
	}

	return 1;
}


#
# returns a list of export files, or empty list
#
sub dbExportFiles {
	my $self = shift;

	my $expDir = $self->exportDir();

	my $expDirHandle = IO::Dir->new($expDir) || die "Can't open $expDir: $!";
	my @files = grep { $self->_isExportFilename($_) } $expDirHandle->read();
	$expDirHandle->close() || die "Can't close $expDir: $!";

	return @files;
}

sub realmsArchiveFileName {
	my $self = shift;

	my $expDir = $self->exportDir();
	return $self->productName() . "_" . $self->serviceName() . "_" . "realms.tar";
}

#
# returns current export dir
#
sub exportDir {
	my $self = shift;

	my $class = ref($self);
	my $basedir = $class->exportDirForProductNameAndService($self->productName(), $self->serviceName());
	return "$basedir/" . $self->exportName();
}

#
# utility class methods
#

sub _isExportFilename { my $class = shift; my $filename = shift; return ($filename =~ m/\.dmp(\.gz)?$/); } 

sub _exportFilenameForDBC {
	my $class = shift;
	my $dbc = shift;

	my $name = $dbc->product()->name();
	my $service = $dbc->product()->service();
	my $type = $dbc->type();
	my $id = $dbc->schemaId();
	my $user = $dbc->user();

	my $fileName = join("_", $name, $service, $type, $id, $user) . ".dmp";
	return $fileName;
}

sub _exportInfoFromFilename {
	my $class = shift;
	my $filename = shift;

	return unless ($filename =~ s/.dmp(\.gz)?$//);

	my ($name, $service, $type, $id, $user) = split("_", $filename);
	return ($name, $service, $type, $id, $user);
}

sub schemaFromFilename { 
	my $class = shift;

	my ($name, $service, $type, $id, $user) = $class->_exportInfoFromFilename(@_);

	return unless $name;

	return $user;
}

sub compareDBConnectionWithFilename {
	my $class = shift;
	my $dbc = shift;

	my ($name, $service, $type, $id, $user) = $class->_exportInfoFromFilename(@_);

	return unless $name;

	return ( ($dbc->type() eq $type) && ($dbc->schemaId() eq $id) );
			
}

sub exportFilenameFromDbc {
	my $class = shift;
	my $dbc = shift;

	#              s4_hf_main-star-dedicated_1_S3LIVEDW01.dmp
	my $fileName = join("_",  $dbc->product()->name(), $dbc->product()->service(), $dbc->type(), $dbc->schemaId(), uc($dbc->user()) ) . ".dmp";

	return $fileName;
}

sub exportDirForProductNameAndService {
	my $class = shift;
	my $productName = shift;
	my $serviceName = shift;

	#FIXME move this somewhere else?
	return "/var/tmp/$productName";
}

sub realmsRootArchiveFilename {
	my $self = shift;

	my $productName = $self->productName();
	my $serviceName = $self->serviceName();

	return $productName . "_" . $serviceName  . "_realms.tar.gz";
}

1;
