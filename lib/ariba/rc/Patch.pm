# 
# Module to encapsulate steps involved in an ops-patch
#
# $Id: //ariba/services/tools/lib/perl/ariba/rc/Patch.pm#42 $
#
package ariba::rc::Patch;

use strict;
use Ariba::P4;
use Ariba::P4::Label;
use Ariba::P5;
use File::Path;
use File::Basename;
use ariba::Ops::PersistantObject;
use ariba::rc::Utils;
use ariba::rc::Globals;

use base qw(ariba::Ops::PersistantObject);

sub newFromProductNameAndBuild {
	my $class = shift;
	my $prodname = shift;
	my $build = shift;

	my $archiveBuildDir = ariba::rc::Globals::archiveBuilds($prodname) . "/$build";


    my $configDir = "$archiveBuildDir/config";
	my $baseConfigDir = "$archiveBuildDir/base/config";
    my ($branchName, $releaseName, $buildName);

    eval {
        $branchName = ariba::rc::Utils::getBranchName($configDir);
        $releaseName = ariba::rc::Utils::getReleaseName($baseConfigDir);
        $releaseName = ariba::rc::Utils::getReleaseName($configDir) if $releaseName =~ m/^Unknown/;
        $buildName = ariba::rc::Utils::getBuildName($configDir);

		# test that the build really exists by loading components
		# here
		if ($prodname ne 'spotbuy') {
			my @components = Ariba::P5::loadProductComponentDetails($configDir);
		}
    };

    if ($prodname ne 'spotbuy' && $@) {
		return undef;
    }

	my $self = $class->SUPER::new($archiveBuildDir);
	$self->setProductName($prodname);
	$self->setConfigDir($configDir);
	$self->setBaseConfigDir($baseConfigDir);
	$self->setBranchName($branchName);
	$self->setReleaseName($releaseName);
	$self->setBuildName($buildName);

	return $self;
}

sub branchSuffixForProduct {
	my $self = shift;

	my $productName = $self->productName();
	my $branchSuffix;

	if ($productName eq "aesws") {
		$branchSuffix = "/services/aes/aesws";
	} elsif ($productName eq "an") {
		$branchSuffix = "/network/service";
	} elsif ($productName =~ /esig|edi|ais|perf|fx|ebs|aod|estore/) {
		$branchSuffix = "/network/$productName";
	} elsif ($productName =~ /aes|anl|acm|s2/) {
		$branchSuffix = "";
	} elsif ($productName eq "piwik") {
		$branchSuffix = "";
    } else {
		$branchSuffix = "";
	}

	return $branchSuffix;
}

#
# returns hashtable of the form
#   p4 location => build location
#
sub customMappingsForProductOrComponent {
	my $self = shift;
	my $productName = shift;
	my $actualProductName = shift;

    my @allProds = ariba::rc::Globals::allProducts();

	my $customMappings;

	if ($productName eq "spotbuy") {
		$customMappings = {}; 
	
	} elsif ($productName eq "mon") {
		$customMappings = { '/lib/perl' => '/lib', };

	} elsif ( grep  { $productName eq $_ } ( ariba::rc::Globals::archesProducts(), "sdb", "help", "doc", ariba::rc::Globals::sharedServiceSourcingProducts(), ariba::rc::Globals::sharedServiceBuyerProducts()) ) {

		$customMappings = { '' => '/config', };

	} elsif ($productName =~ /^ariba\.analytics\.migration$/) {
		$customMappings = { '' => '/image', };

	} elsif ($productName =~ /^ariba\.(asm|buyer|sdb)\.migrate\.([^.]+)/) {
		my $release = $2;
		$customMappings = { 
			"/etc/sql" => "/image/lib/sql",
			"/etc/migration" => "/image/etc/migration/$release",
			"/perl" => "/image/internal/bin",
		};

	} elsif ($productName eq "an") {
		$customMappings = { 
			'/sql' => "/lib/sql/$productName/scripts",
			'/common/sql' => "/lib/sql/$productName/scripts",
			'/common/datafix' => "/datafix",
			'/i18n/personalities/Ariba' => '/personalities/Ariba',
		};

	} elsif ($productName eq "perf") {
		$customMappings = { 
			'/sql' => "/lib/sql/$productName/scripts",
			'/common/sql' => "/lib/sql/$productName/scripts",
		};

	} elsif ($productName =~ /^(aes|anl|acm|s2)$/) {
		$customMappings = {};
	} elsif ($productName eq "ariba.network.common") {
		$customMappings = {
			'/ariba/network/common/anbasedirectorybusinesslogic' => '/lib/sql/base_dir',
			'/ariba/network/common/anbasebusinesslogic' => '/lib/sql/base',
			'/ariba/network/common/workflow' => '/lib/sql/workflow',
			'/sql' => '/lib/sql/common/scripts',
		};
	} elsif ($productName eq 'ariba.network.testcases') {
		$customMappings = {
			'/BQ' => '/internal/selenium/test.network/BQ',
			'/AN/FinancialSolution' => '/internal/selenium/test.network.financialSolutions/LQ',
			'/Discovery/' => '/internal/selenium/test.network.discovery/LQ',
			'/AN/SE' => '/internal/selenium/test.network.supplierSolutions/LQ/SE',
			'/AN/SMP' => '/internal/selenium/test.network.supplierSolutions/LQ/SMP',
			'/AN/Catalogs' => '/internal/selenium/test.network.supplierSolutions/LQ/Catalogs',
			'/AN/Admin'  => '/internal/selenium/test.network.supplierSolutions/LQ/Admin',
			'/AN/Configuration' => '/internal/selenium/test.network.supplierSolutions/LQ/Configuration',
			'/AN/TransactionCore' => '/internal/selenium/test.network.transactions/LQ/TransactionCore',
			'/AN/TravelAndExpense' => '/internal/selenium/test.network.transactions/LQ/TravelAndExpense',
			'/AN/BPO' => '/internal/selenium/test.network.transactions/LQ/BPO',
			'/AN/Dashboard' => '/internal/selenium/test.network.transactions/LQ/Dashboard',
			'/AN/Reports' => '/internal/selenium/test.network.infrastructure/LQ/Reports',
			'/AN/Accounts' => '/internal/selenium/test.network.infrastructure/LQ/Accounts',
			'/AN/SupplierPortal' => '/internal/selenium/test.network.infrastructure/LQ/SupplierPortal',
			'/EDI' => '/internal/selenium/test.network.edi',
		};
	} elsif ($productName eq 'help') {
	
	# currently only platform uses this label
	} elsif ($productName eq "ariba.ops.tools") {
		if (grep { $actualProductName eq $_ } ariba::rc::Globals::sharedServicePlatformProducts()) {
			$customMappings = { '' => '/image/internal/ops/overlay' };
		} else { 
			$customMappings = {}; 
		}

	} elsif ($productName =~ /^(esig|edi|ais|perf|fx|ebs|cxml|aod)$/) {
		$customMappings = {};

	} elsif ($productName =~ /^(estore)$/) {
		$customMappings = {
			'/sql' => '/lib/sql/estore/scripts',
			'/personalities' => '/docroot',
		};

	} elsif ($productName eq "ariba.estore.testcases") {
		$customMappings = {
			'' => '/internal/selenium/test.estore',
		};

	} elsif ( grep { $productName eq $_ } @allProds ) {
		$customMappings = {};

	} else {  # return an error by default
		$customMappings = undef;

	}

	return $customMappings;
}

sub p4Prefix {
my $self = shift;

	my $branchName = $self->branchName();
	# $branchName == //ariba

	my $p4Prefix = $branchName .  $self->branchSuffixForProduct();
	# $p4Prefix = //ariba/network/service

	return $p4Prefix;
}

#
# p4-to-build location lookup
#
#  Given:
# $p4location == //ariba/network/service/common/sql/43/test_stuff.sql
# $branchName == //ariba/network/service
#
# Attempt to arrive at a matching buildlocation 
# $buildLocation == /home/rc/archive/builds/an/Slayer-54/lib/sql/an/scripts/43/test_stuff.sql
#
sub mapP4ToBuild {
	my $self = shift;
	my $p4Location = shift;
	# $p4location == //ariba/network/service/common/sql/43/test_stuff.sql

	my $productName = $self->productName();
	my $configDir = $self->configDir();

	my $p4Prefix = $self->p4Prefix();

	my $buildLocation = $p4Location;
	# $buildLocation == //ariba/network/service/common/sql/43/test_stuff.sql

	my $componentName;
	unless ($buildLocation =~ s!^$p4Prefix/!! ) { 
		my @components = Ariba::P5::loadProductComponentDetails($configDir);
		foreach my $component (@components) {
			my $componentRoot = $component->[2];
			$componentRoot =~ s!\.\.\.$!!;
			$componentRoot = quotemeta($componentRoot);
			if ($buildLocation =~ s!^$componentRoot!!) {
				$componentName = $component->[0];
				print "$p4Location is in component $componentName\n"
					if $self->debug();
				last;
			}
		}

		# AN test scripts are not located within the p4Prefix, so
		# we special-case a component label here so they can be
		# ops-patched

		if (!defined($componentName) && $p4Prefix =~ m!/network/service!) {
			my $anPrefix = $p4Prefix;
			$anPrefix =~ s!/network/service!/network!;
			if($buildLocation =~ s!^$anPrefix/test/testCases/selenium/!!) {
				$componentName = "ariba.network.testcases";
			}
		}

		# ESTORE did the same silly thing

		if (!defined($componentName) && $p4Prefix =~ m!/network/estore!) {
			my $anPrefix = $p4Prefix;
			$anPrefix =~ s!/network/estore!/network!;
			if($buildLocation =~ s!^$anPrefix/test/testCases/selenium/estore!!) {
				$componentName = "ariba.estore.testcases";
			}
		}

		#component was not found in components.txt and we're not patching
		#the main build location.  Check for ops' tools as a special case
		#(an-family/mon/anl/aes/acm/ws-family products)

		if (!defined($componentName) && $buildLocation !~ s!^//ariba/services/tools/!!) {
			$self->setError("Error: Could not find component/product for $buildLocation\n");
			return undef;
		}
	}

	$buildLocation = "/$buildLocation";

	$componentName = $componentName || $productName;

	my $customMappingHashRef = $self->customMappingsForProductOrComponent($componentName, $productName);
	unless (defined($customMappingHashRef)) {
		$self->setError("\nError: Patching $componentName is not supported by this tool!\n");
		return undef;
	}

	while (my ($p4Path, $buildPath) = each(%$customMappingHashRef)) {
		$buildLocation =~ s/^$p4Path/$buildPath/;
	}
	# $buildLocation == //ariba/network/service/lib/sql/an/scripts/43/test_stuff.sql

	$buildLocation = $self->instance() . "$buildLocation";
	# $buildLocation == /home/rc/archive/builds/an/Slayer-54/lib/sql/an/scripts/43/test_stuff.sql

	return $buildLocation;
}

sub currentBuildLabel {
	my $self = shift;

	my $currentLabel = $self->SUPER::currentBuildLabel();

	unless ($currentLabel) {

		my $labelInfo = Ariba::P4::labels();
		my @allLabels = keys(%$labelInfo);

		$currentLabel = $self->buildName();

		my @oldLabels = grep(/$currentLabel/, @allLabels);
		my $patchNum = 0;
		for my $l (@oldLabels) {
			next unless($l =~ /.+-OP(\d+)$/);
			if ($patchNum < $1) {
				$patchNum = $1;
				$currentLabel = $l;
			}
		}

		$self->SUPER::setCurrentLabel($currentLabel);
	}

	return $currentLabel;
}

sub fileBelongsToLabel {
	my $self = shift;
	my $file = shift;
	my @labels = @_;

	my $label = undef;

	for my $l (@labels) {
		my $labelObj = Ariba::P4::Label::getLabel($l);
		my @viewsToCheck = @{$labelObj->{view}};
		map { s/[.]{3}$//; $_ = quotemeta } @viewsToCheck;
		if (grep { $file =~ /^$_/ } @viewsToCheck) {
			$label = $l;
			last;
		}
	}

	return $label;

}

sub currentPatchLevel {
	my $self = shift;

	return $self->patchLevelFromLabel($self->currentBuildLabel);
}

sub patchLevelFromLabel {
	my $self = shift;
	my $label = shift;

	my $level = 0;
	if ($label =~ m/.+-OP(\d+)/) {
		$level = $1;
	}
	return $level;
}

sub patchSuffix {
	my $self = shift;

	my $currentPatchNum = $self->currentPatchLevel();
	++$currentPatchNum;
	my $patchSuffix = "OP$currentPatchNum";

	return $patchSuffix;
}

sub syncNewBuildLabel {
	my $self = shift;

	my $currentLabel = $self->currentBuildLabel();

	my $patchSuffix = $self->patchSuffix();

	my $newLabel = "$currentLabel";
	$newLabel =~ s/(-OP(\d+))?$/-$patchSuffix/; # this substitution always happens

		# for the comments, show a) which changelists belong to
		# this label and b) which files got changed and the old/new revs

	my @updatedFilesForLabel = ();
	my $comment = "";
	my %commentChangelists = ();

	my $filesRef = $self->files();

	for my $file (keys %$filesRef) {
		next unless $self->fileBelongsToLabel($file, $currentLabel);

		my $newRev = $filesRef->{$file}{newrev};
		my $oldRev = $filesRef->{$file}{oldrev};

		push(@updatedFilesForLabel, "$file#$newRev");
		$commentChangelists{$filesRef->{$file}{change}} = 1;

		my $changeType = $filesRef->{$file}{changeType};
		if ($changeType eq 'edit') {
			$comment .= "\t$file#$newRev replace $file#$oldRev\n";
		} else {
			$comment .= "\t$file#$newRev $changeType\n";
		}
	}

	my @unchangedFilesForLabel = ();
	my $labelObj = Ariba::P4::Label::getLabel($currentLabel);
	my $currentLabelView = $labelObj->{view};
	for my $f (@$currentLabelView) {
		push(@unchangedFilesForLabel, "$f\@$currentLabel");
	}

	$comment = "Ops patch for change(s) " . 
		join(",", keys(%commentChangelists)) . "\n$comment";

	if ($self->debug()) {
		print "\nSyncing new label $newLabel:\n\n";
		print " ** creating new label $newLabel with view\n\t", 
			  join("\n\t", @$currentLabelView), 
			  "\n    and comment:\n\t$comment\n\n";
		print " ** syncing $newLabel to the old view\n\t", 
			  join("\n\t", @unchangedFilesForLabel), "\n\n";
		print " ** syncing $newLabel to the newly patched files\n\t", 
			  join("\n\t", @updatedFilesForLabel), "\n\n";
		print " ** locking $newLabel\n\n";
		print " ** updating ReleaseName ", $self->releaseName(),
			  " to ", $self->updateReleaseName($patchSuffix), "\n\n";
	} else {
		if (!Ariba::P4::createLabel($newLabel, $currentLabelView, $comment)) {
			$self->setError("Could not create $newLabel");
			return 0;
		}
		if (!Ariba::P4::labelsync($newLabel, join(' ', @unchangedFilesForLabel))) {
			$self->setError("Could not sync $newLabel to old label view");
			return 0;
		}
		if (!Ariba::P4::labelsync($newLabel, join(' ', @updatedFilesForLabel))) {
			$self->setError("Could not sync $newLabel to patched files");
			return 0;
		}
		if (!Ariba::P4::lockLabel($newLabel)) {
			$self->setError("Could not lock $newLabel");
			return 0;
		}
		if (!$self->updateReleaseName($patchSuffix)) {
			$self->setError("Could not update ReleaseName: $!");
			return 0;
		}
	}

	return 1;
}

sub rollbackPatch {
	my $self = shift;
	my $label = shift;

	my $level = $self->patchLevelFromLabel($label);
	if ($level < 1) {
		return;
	}
	my $patchSuffix = "OP$level";

	#1. get the list of files that were patched
	my $labelObj = Ariba::P4::Label::getLabel($label);
	for my $line (@{$labelObj->{description}}) {
		next unless $line =~ s!^\s*(//\S+)\s+!!;
		
		my $newFile = $1;
		my $p4BaseFile = $newFile;
		$p4BaseFile =~ s/#\d+$//;
		my $buildFile = $self->mapP4ToBuild($p4BaseFile);

		if ($line =~ m!^replace \s+(//\S+)!) {
			my $oldFile = $1;

			if ($self->debug()) {
				print "Would overwrite $buildFile with $oldFile\n";
			} else {
				$self->printFile($oldFile, $buildFile);
			}

			my $backupFile = "$buildFile.orig.$patchSuffix";
			if (-f $backupFile) {
				if ($self->debug) {
					print "Would remove backup file $backupFile\n";
				} else {
					unlink($backupFile);
				}
			}
		} elsif ($line =~ m!^add!) {
			# rm the build file
			if ($self->debug()) {
				print "Would remove added file $buildFile\n";
			} else {
				unlink($buildFile);
			}
		}
	}
}

sub updateReleaseName {
	my $self = shift;
	my $patchSuffix = shift;

    my $releaseNameFile = $self->configDir() . "/ReleaseName";
	my $newReleaseName = $self->releaseName();

    if (-f $releaseNameFile) {
		$newReleaseName =~ s/(-OP(\d+))?$/-$patchSuffix/;

		unless ($self->debug()) {
			my $backupFile = "$releaseNameFile.orig.$patchSuffix";
			unless (-f $backupFile) {
				rename($releaseNameFile,$backupFile);
			}
			open(RN, ">$releaseNameFile") or return undef;
			print RN "$newReleaseName\n";
			close(RN);
		}
    }

	return $newReleaseName;
}

sub collectFilesToPatch {
	my $self = shift;
	my @changeLists = @_;

	my $fileRegex = $self->fileRegex();
	my $currentLabel = $self->currentBuildLabel();

	for my $change (@changeLists) {

		for my $p4File (Ariba::P4::ChangelistFiles($change)) {
			if ($fileRegex) {
				next unless ($p4File =~ /$fileRegex/);
			}

			my $p4BaseFile = $p4File;
			$p4BaseFile =~ s/#(\d+)$//;
			my $newRev = $1;

			my $buildFile = $self->mapP4ToBuild($p4BaseFile);

			if ($buildFile) {

				my $filesRef = $self->files() || {};

				if (exists($filesRef->{$p4BaseFile})) {
					print "Warning: same file in multiple changelists found, will patch latest version only\n";
					next if ($newRev <= $filesRef->{$p4BaseFile}{newrev});
				}

				my $label = $self->fileBelongsToLabel($p4BaseFile, $currentLabel);

				# It's possible that we can get this far in and not
				# have a file that belongs to this label, e.g.
				# if a changelist contains changes for 
				# //ariba/services/webserver/config/roles.cfg and
				# //ariba/services/webserver/ssws/config/roles.cfg
				#
				if ($label) {

					# check for > 1 rev jumps,
					my $labelUpdateTime = Ariba::P4::Label::getLabel($label)->getUnixtimeUpdated($label);
					my $fileUpdateTime = Ariba::P4::getTimeFromFile($p4BaseFile, "#$newRev");

					my $fileInLabel = Ariba::P4::fileExists("$p4BaseFile\@$currentLabel");
					my $changeType = Ariba::P4::getFileStat($p4BaseFile, 'headAction', $change);

					my $oldRev;

					if ($fileInLabel) {
						$oldRev = Ariba::P4::getRevisionFromFile($p4BaseFile, $currentLabel);

						# skip version checks if this is a new file for this label
						if ($fileUpdateTime < $labelUpdateTime) {

							my $revDiff = $newRev - $oldRev;
							if ($revDiff > 1) {
								print "Warning: more than one version between $p4BaseFile#$oldRev and $p4BaseFile#$newRev\n";
							} elsif ($revDiff < 0) {
								print "Warning: patching to older version of $p4BaseFile\n";
							} elsif ($revDiff == 0) {
								print "Warning: patch for $p4BaseFile is same version as in current build, skipping\n";
								next;
							}
						}
					} else {
						# if we're patching an old build that doesn't
						# have this file but there have been changes,
						# show this as an 'add' since that's what
						# it is from the point of view of the build
						# being patched
						if ($changeType eq 'edit') {
							$changeType = 'add';
						}
					}

					$filesRef->{$p4BaseFile}{oldrev}    = $oldRev;
					$filesRef->{$p4BaseFile}{newrev}    = $newRev;
					$filesRef->{$p4BaseFile}{change}    = $change;
					$filesRef->{$p4BaseFile}{buildfile} = $buildFile;
					$filesRef->{$p4BaseFile}{changeType} = $changeType;
					$self->setFiles($filesRef);
				}
			}
		}
	}
}

sub applyPatch {
	my $self = shift;

	my $patchSuffix = $self->patchSuffix();
	my $build = $self->buildName();

	my $filesRef = $self->files();
	for my $file (keys (%$filesRef)) {

		my $p4File = $file . "#" . $filesRef->{$file}{newrev};
		my $buildFile = $filesRef->{$file}{buildfile};
		my $changeType = $filesRef->{$file}{changeType};

		my $newFile = $file;
		$newFile =~ s!^/!!;
		$newFile = "/var/tmp/ops-patch/$build$newFile";

		unless ($changeType eq 'delete') {
			#checkout file from p4
			if ($self->debug()) {
				print "\nChecking out from p4 $p4File to $newFile\n" if ($self->debug() );

			} else {

				unless (ariba::rc::Utils::mkdirRecursively(dirname($newFile))) {
					$self->setError("Failed to create dir ", dirname($newFile),": $@");
					return 0;
				}
				unless ($self->printFile($p4File, $newFile)) {
					$self->setError("Could not checkout $p4File: $!");
					return 0;
				}
			}
		}

		unless ($changeType eq 'add') {
			# move the original file aside, unless it has already been moved
			my $backupFile = "$buildFile.orig.$patchSuffix";
			unless (-f $backupFile) {
				rename($buildFile,$backupFile) unless $self->debug();
				print "\nWill rename $buildFile to $backupFile\n" if ($self->debug());
			} else {
				print "\n$backupFile exists, no rename done\n" if ($self->debug());
			}
		}

		unless ($changeType eq 'delete') {
			# copy replacement file to archive location
			unless ($self->debug()) {
				my $destDir = dirname($buildFile);
				if (!-d $destDir) {
					unless (ariba::rc::Utils::mkdirRecursively($destDir)) {
						$self->setError("Could not create $destDir: $@");
						return 0;
					}
				}
				unless ( ariba::rc::Utils::copyFiles(dirname($newFile), basename($newFile),
							$destDir, basename($buildFile))) {
					$self->setError("Could not transfer $newFile to $buildFile: $!");
					return 0;
				}
			} else {
				print "\ncopy from $newFile to $buildFile\n";
			}
		}
	}
	return 1;
}

sub filesToPatch {
	my $self = shift;

	my $filesRef = $self->files();
	my @files = map { "$_ " . $filesRef->{$_}{changeType} } keys(%$filesRef);
	return @files;
}

sub checkAlreadyPatched {
	my $self = shift;
	my @changes = @_;

	my @patchedChanges = ();
	my $currentLabel = $self->currentLabel();
	my $baseLabel = $self->buildName();

	my $labelInfo = Ariba::P4::labels();
	my @allLabels = grep(m/$baseLabel/, keys(%$labelInfo));

	for my $change (@changes) {
		for my $l (@allLabels) {
			next unless($l =~ /.+-OP(\d+)$/);

			my $labelObj = Ariba::P4::Label::getLabel($l);
			
			if(grep(/$change/, @{$labelObj->{description}})) {
				push(@patchedChanges, $change);
				last;
			}
		}
	}

	return @patchedChanges;
}

sub printFile {
	my $class = shift;
	my $p4File = shift;
	my $outputFile = shift;
	
	qx{p4 print -o $outputFile $p4File};
}

1;
