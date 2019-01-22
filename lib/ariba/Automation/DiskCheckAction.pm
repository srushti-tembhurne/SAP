package ariba::Automation::DiskCheckAction;

use warnings;
use strict;

use ariba::Automation::Constants;
use ariba::Automation::Utils;
use ariba::Automation::Action;
use base qw(ariba::Automation::Action);

use ariba::Ops::Logger;
use ariba::rc::ArchivedProduct;
use ariba::rc::Globals;
use ariba::Ops::Constants;

sub validFields {
	my $class = shift;

	my $fieldsHashRef = $class->SUPER::validFields();

	$fieldsHashRef->{'rootDirDiskSpaceInGB'} = 1;
	$fieldsHashRef->{'robotDirDiskSpaceInGB'} = 1;
	$fieldsHashRef->{'homeDirDiskSpaceInGB'} = 1;
	
	return $fieldsHashRef;
}

sub execute {
	my $self = shift;

	my $logger = ariba::Ops::Logger->logger();
	my $logPrefix = $self->logPrefix();

	my $service = ariba::Automation::Utils->service();
   
	my $productName = $self->productName();
    
	my $homeDirDiskSpaceInGB = $self->homeDirDiskSpaceInGB();
	my $rootDirDiskSpaceInGB = $self->rootDirDiskSpaceInGB();
	my $robotDirDiskSpaceInGB = $self->robotDirDiskSpaceInGB();
	
		
	# ~/public_doc/logs
	my $publicDocLogs = join "/", 
		ariba::Automation::Constants::baseRootDirectory(), 
		ariba::Automation::Constants::logDirectory();

    my $homeDirPath=$ENV{"HOME"};
	my $homeDirDiskCheckResult = $self->runHomeDirDiskCheck();
	my $homeDirDiskCheck= chomp $homeDirDiskCheckResult;
	$logger->info("$logPrefix checking for diskspace in home directory");
	if($homeDirDiskCheckResult<$homeDirDiskSpaceInGB){
       $logger->error("Not enough diskspace under home directory $homeDirPath (Available: $homeDirDiskCheck GB, Required: $homeDirDiskSpaceInGB GB)");
	   return;
    }
   
    my $rootDirDiskCheckResult = $self->runRootDirDiskCheck();
	my $rootDirDiskCheck= chomp $rootDirDiskCheckResult;
	$logger->info("$logPrefix checking for diskspace in root directory");
	if($rootDirDiskCheckResult<$rootDirDiskSpaceInGB){
       $logger->error("Not enough diskspace under root directory / (Available: $rootDirDiskCheck GB, Required: $rootDirDiskSpaceInGB GB)");
	   return;
    }
	  
    my $robotDirDiskCheckResult = $self->runRobotDirDiskCheck();
   	my $robotDirDiskCheck= chomp $robotDirDiskCheckResult;
	$logger->info("$logPrefix checking for diskspace in robot directory");
    if($robotDirDiskCheckResult<$robotDirDiskSpaceInGB){
       $logger->error("Not enough diskspace under robots directory /robots (Available: $robotDirDiskCheck GB, Required: $robotDirDiskSpaceInGB GB)");
	   return;
    }

    return 1;
}

sub runHomeDirDiskCheck{
    my $homeDir=$ENV{"HOME"};
    my $diskUsageRobotCmd = "df -hP $homeDir |awk '{print \$4}'|sed 's/G//'| sed 's/Avail//'";
    my $robotDiskUsageCmd = `$diskUsageRobotCmd`;
	return $robotDiskUsageCmd;
}

sub runRootDirDiskCheck{
    my $diskUsageRootCmd = "df -hP / |awk '{print \$4}'|sed 's/G//'| sed 's/Avail//'";
    my $rootDiskUsageCmd = `$diskUsageRootCmd`;
	return $rootDiskUsageCmd;
}

sub runRobotDirDiskCheck{
    my $diskUsageRobotCmd = "df -hP /robots |awk '{print \$4}'|sed 's/G//'| sed 's/Avail//'";
    my $robotDiskUsageCmd = `$diskUsageRobotCmd`;
	return $robotDiskUsageCmd;
}

1;

