#!/usr/local/bin/perl

package ariba::Ops::MCL::Helpers::DatasetManager;

use ariba::Ops::Logger;
my $logger = ariba::Ops::Logger->logger();

use ariba::Ops::DatasetManager;

sub markRealmsBackupInProgress {
	my $dsId = shift;
	my $rootDir = shift;

	my $ds = ariba::Ops::DatasetManager->new($dsId);
	$ds->setRealmBackupStatus("In Progress");
	$ds->setRealmRootDir($rootDir);

	$ds->_save();

	return("OK: realm backup status set.");
}

sub markRealmsBackupComplete {
	my $dsId = shift;

	my $ds = ariba::Ops::DatasetManager->new($dsId);
	$ds->setRealmBackupStatus("Successful");
	my @realmFiles = $ds->archivedRealmsBackupFiles();
	my $size=0;
	foreach my $f (@realmFiles) {
		$size += (stat($f))[7];
	}
	$ds->setRealmSizeInBytes($size);
	if($ds->dbBackupStatus() eq 'Successful') {
		$ds->setDatasetComplete(1);
	}

	$ds->_save();

	return("OK: realm backup status set.");
}

1;
