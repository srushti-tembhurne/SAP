package ariba::monitor::ANLExportManager;

# $Id: //ariba/services/monitor/lib/ariba/monitor/ANLExportManager.pm#10 $

=head1 DESCRIPTION

Class to encapsulate managing ANL exports.  Typical use is:

my $exportMgr = ariba::monitor::ANLExportManager->new($product);
$exportMgr->

=cut


use strict;
use ariba::Ops::PersistantObject;
use base qw(ariba::Ops::PersistantObject);

use ariba::Ops::OracleClient;
use ariba::Ops::DBConnection;
use ariba::Ops::DateTime;
use ariba::rc::InstalledProduct;
use ariba::rc::Passwords;
use ariba::monitor::QueryManager;
use ariba::monitor::ANLExport;

use File::Basename;
use File::Path;
use DirHandle;

# default filename to store list of tables to be exported/excluded
my $DEFAULTTABLELISTFILE    = "export-tables.cfg";

# additional optional table list file
my $DEFAULTCUSTOMERTABLELISTFILE = "customer-export-tables.cfg";

# default number of latest exports to keep when rotating.
my $DEFALTROTATIONCOUNT 			= 1;

# default number of latest exports pushed to production when rotating.
my $DEFAULTPRESENTATIONLOADSTOKEEP	= 2;

# constants
use constant ROOTDIRKEY					=> "Ops.DBExportRootDirectory";
use constant DIRMASK 					=> 0755;

use constant EXPORTSUCCESS 				=> "Export terminated successfully without warnings.";
use constant EXPORTSUCCESSWITHWARN 		=> "Export terminated successfully with warnings.";
use constant EXPORTSUCCESSEXISTS 		=> "Export terminated successfully, file exists for latest data load.";
use constant EXPORTNOTDONEDATALOADINPROGRESS	=> "Export not done because data load is in progress.";
use constant EXPORTNOTDONEMISSINGDATALOAD 		=> "Export not done because data load has never occured.";
use constant EXPORTFAILEDNOTABLES		=> "Export failed because no tables matched for export.";
use constant EXPORTFAILEDDBERROR		=> "Export failed because of db: ";
use constant EXPORTFAILEDFSERROR		=> "Export failed because of fs: ";
use constant EXPORTFAILEDNOSTATUS		=> "Export failed -- cannot find logfile.";

### overriden PersistantObject methods
sub validAccessorMethods {
	my $class = shift;

=head2 Instance Methods

=over 4

=item ariba::rc::InstalledProduct presentationProduct()

Returns the product object that represents the presentation instance.

=item ariba::rc::InstalledProduct loadingProduct()

Returns the product object that represents the loading instance.

=item SCALAR rotationCount(), setRotationCount(SCALAR num)

How many exports to keep when doing rotating export files.  See
rotateExports() for more details.

=item SCALAR presentationLoadsToKeep(), setPresentationLoadsToKeep(SCALAR num)

How many exports-pushed-to-presentation to keep when rotating exports.  See
rotateExports() for more details.

=item SCALAR noAction(), setNoAction(SCALAR bool)

When set to true, signals a dry run of import or export.  No actual import or
export will take place (including auxilary actions such as dropping tables,
export deletions, database updates, etc).

=item SCALAR debug(), setDebug(SCALAR bool)

Get and set the debug level.

=item SCALAR force(), setForce(SCALAR bool)

When set, causes all checks in importing and exporting to be bypassed.

=back

=cut

	my $methodsRef = $class->SUPER::validAccessorMethods();
	$methodsRef->{'exportsHash'} 				= undef;
	$methodsRef->{'duplicateExportsArray'} 		= undef;
	$methodsRef->{'exportsFaultedIn'} 			= undef;
	$methodsRef->{'presentationProduct'} 		= undef;
	$methodsRef->{'loadingProduct'} 			= undef;
	$methodsRef->{'rotationCount'} 				= undef;
	$methodsRef->{'presentationLoadsToKeep'} 	= undef;
	$methodsRef->{'noAction'} 					= undef;
	$methodsRef->{'debug'} 						= 0;
	$methodsRef->{'force'} 						= undef;
	$methodsRef->{'exportStatusString'}			= undef;
	$methodsRef->{'importStatusString'}			= undef;

	return $methodsRef;
}

sub dir() {
	return undef;
}

sub save() {
	return undef;
}

sub recursiveSave() {
	return undef;
}

### end PersistantObject overrides

=over

=item createFromProduct(ariba::rc::Product product)

Factory creator method.  Given a ariba::rc::Product object, return a
ariba::monitor::ANLExportManager object.  Product can be either the loading or
presentation product.

=back

=cut

sub createFromProduct {
	my $class = shift;
	my $product = shift;

	if (!defined($product) || !$product->customer()){
		return undef;
	}

	my $self = $class->SUPER::new($product->name() . $product->customer());

	# normalize the customer name
	my $customer = $product->customer();
    $customer =~ s/-T$//;
    my $loadingCustomer = $customer;
    $loadingCustomer .= "-T";

	my $presentationProduct = ariba::rc::InstalledProduct->new($product->name(), $product->service(), undef, $customer);
	my $loadingProduct = ariba::rc::InstalledProduct->new($product->name(), $product->service(), undef, $loadingCustomer);

	return undef unless defined($loadingProduct);

 	$self->setPresentationProduct($presentationProduct);
	$self->setLoadingProduct($loadingProduct);
	$self->setRotationCount($DEFALTROTATIONCOUNT);
	$self->setPresentationLoadsToKeep($DEFAULTPRESENTATIONLOADSTOKEEP);
	$self->setNoAction(0);
	return $self;

}

=over

=item exportFromLoading(SCALAR tableListFile)

Performs an export of the loading product's schema.  Gets the list of 

=back

=cut

sub exportFromLoading {
	my $self = shift;

	my $loadingProduct = $self->loadingProduct();
	my $customer = $loadingProduct->customer();

	my @tableList = ();
	my $tableListIsExcludeList = 0;

	# See the comments of the _populate() method for file syntax.
	my $readError = $self->_populateTableList(\@tableList, \$tableListIsExcludeList);
	if ($readError) {
		if ($self->debug()) {
			print "Error reading table list: $readError\n";
		}
		$self->setExportStatusString( EXPORTFAILEDFSERROR . $readError );
		return;
	}

	# If no tables were specified AND it is not an exlude list,
	# return with an error (empty exclude list is acceptable since
			# it means all tables).
	if ( ! @tableList && ! $tableListIsExcludeList) {
		if ($self->debug()) {
			print "Error: no tables selected for export\n";
		}
		$self->setExportStatusString( EXPORTFAILEDNOTABLES );
		return;
	}

	my $oracleClient = $self->_setupOracleClient($loadingProduct);

	if ($oracleClient->error()) {
		if ($self->debug()) {
			print "failed to connect!: ", $oracleClient->error(), "\n";
		}
		$self->setExportStatusString( EXPORTFAILEDDBERROR . $oracleClient->error() );
		return;
	}


	# get last data load completed time.
	# if 
	# 	1) there is no last data load completed time or
	# 	2) last completed time is *before* last start
	# 	   time (data load in progress) or
	#	3) last data load time is before or equal to last
	#	   export time
	#
	#then skip over this export.
	#

	my ($lastDataLoadStartTime, $lastDataLoadCompleteTime) = $self->lastDataLoadTimes();

	if (!$lastDataLoadCompleteTime || !$lastDataLoadStartTime) {
		if ($self->debug()) {
			print "\n", $oracleClient->user(), ":", $customer , ":", " has never had an data load done\n";
			print "Skipping this one.\n";
		}
		$self->setExportStatusString( EXPORTNOTDONEMISSINGDATALOAD );
		return;
	}

	if ($lastDataLoadCompleteTime < $lastDataLoadStartTime ) {
		if (!$self->force()) {
			if ($self->debug()) {
				print "\nSeems like data load is still going for ", $oracleClient->user(), ":", $customer, "\n";
				print "$lastDataLoadCompleteTime, $lastDataLoadStartTime\n";
				print "Skipping this one.\n";
			}
			$self->setExportStatusString( EXPORTNOTDONEDATALOADINPROGRESS );
			return;
		}
		else {
			print "Warning: data load in progress for $customer\n";
		}
	}

	my $version = ariba::monitor::ANLExportManager->_baseReleaseNameForProduct($loadingProduct);
	my $export  = ariba::monitor::ANLExport->newFromTimestamp($lastDataLoadCompleteTime, $version, $self->_baseExportFilePath());
	$export->setDebug($self->debug());

	my $currentExportDir = $export->fullPath();

	# make sure the directory to save the export under exists
	unless ( -d $currentExportDir ) { 
		eval { mkpath($currentExportDir, 0, DIRMASK) };
		if ($@) {
			if ($self->debug()) {
				print "Directory '$currentExportDir' does not exist and mkpath failed\n";
			}
			$self->setExportStatusString( EXPORTFAILEDFSERROR . "$@" );
			return;
		}
	}


	# skip if we already have an export file for this (last)
	# data load time
	if ( $export->exportExists() ) {
		if (!$self->force()) {
			if ($self->debug()) {
				print "\nExport file exists for latest data load:", $oracleClient->user(), ":", $customer, "\n";
				print "Skipping this one.\n";
			}
			$self->setExportStatusString( EXPORTSUCCESSEXISTS );
			return;
		}
		else {
			print "Warning: will over-write existing export file ",$export->cannonicalExportFileName(),"\n"
		}
	}

	#
	# if no tables were specified or if the list is an exclude list, get table list from schema.
	#
	if ( ! @tableList || $tableListIsExcludeList ) {
		my $sqlStatement = "select TNAME from SYSTEM.TAB where TABTYPE='TABLE'";

		if ($tableListIsExcludeList && @tableList) {
			$sqlStatement .= " and TNAME not in (" . join(",", map("'$_'", @tableList)) . ")";
		}

		if ($self->debug()) {
			print "Getting table list with query:\n\t", $sqlStatement, "\n";
		}

		@tableList = $oracleClient->executeSql( $sqlStatement );

		if ($oracleClient->error()) {
			if ($self->debug()) {
				print "OracleClient Error:", $oracleClient->error(), "\n";
			}
			$self->setExportStatusString( EXPORTFAILEDDBERROR . $oracleClient->error() );
			return;
		}

		unless ( @tableList ) {
			if ($self->debug()) {
				print "Warning: table query:\n", $sqlStatement, "\nmatched zero tables.\n";
			}
			$self->setExportStatusString( EXPORTFAILEDNOTABLES );
			return;
		}
	}

	# find value for 'nextBaseId'
	my $nextBaseIdQuery= "select ALONG from NAMEDLONGTAB WHERE ANAME = 'nextBaseId'";
	my $nextBaseId = $oracleClient->executeSql($nextBaseIdQuery);
	if ($oracleClient->error()) {
		if ($self->debug()) {
			print "OracleClient Error:", $oracleClient->error(), "\n";
		}
		$self->setExportStatusString( EXPORTFAILEDDBERROR . $oracleClient->error() );
		return;
	}

	my $exportParamHash = {
		CONSISTENT => 'Y',
		COMPRESS => 'Y',
		STATISTICS => 'none',
		LOG => $export->cannonicalExportLogFileName(),
		FILE => $export->cannonicalExportFileName(),
		TABLES => \@tableList,
	};

	my $status;
	if ($self->debug()) {
		print "\n$0: exporting $customer ",$oracleClient->user(),"@", $oracleClient->sid(), "...\n";
	}

	if ( !$self->noAction() ) {

		# perform the actual export
		$status = $oracleClient->dbExport($exportParamHash);

		if ( !$status || $oracleClient->error() ) {
			if ($self->debug()) {
				print $oracleClient->error(),"\n";
			}
			$status = EXPORTFAILEDDBERROR . $oracleClient->error();
		}
		else {
			# if export was successfull, zip the export file and save the
			# nextBaseId
			$status = $export->exportStatusString();
			if ($status) {
				if (!$export->zip()) {
					$status . ":" . $export->zipError()
				}
			} else {
				$status = EXPORTFAILEDNOSTATUS;
			}

			unless($export->saveNextBaseId($nextBaseId)) {
				print "could not save nextBaseId!: $!\n";
			}
		}

	} else {
		print "noAction set: would have ran exp with:\n";
		for (keys %{$exportParamHash}) {
			my $value = $exportParamHash->{$_};
			print "$_ => ", ( ref($value) eq "ARRAY" ? "@{$value}":"$value" ), "\n";
		}
		print "\n";
	}

	$self->setExportStatusString($status);
	return;
}

=over

=item SCALAR exportStatus()

If called after exportFromLoading(), returns a numerical status that corresponds to one of:
	ariba::monitor::ANLExportManager->FAILURE() - export failed
	ariba::monitor::ANLExportManager->WARNING() - export completed with warnings
	ariba::monitor::ANLExportManager->SUCCESS() - export completed successfully without warnings

Returns undef when called without running exportFromLoading().

Can also take an optional string argument, in which case it returns a numerical status as if that string was 

=back

=cut

sub exportStatus {
	my $self = shift;
	my $status = shift ||  $self->exportStatusString();

	if (!defined($status) || $status !~ /\bsuccessfully\b|not done/) {
		return $self->FAILURE();
	} elsif ($status =~ /with warnings|Zip Error/) {
		return $self->WARNING();
	} elsif ($status =~ /\bsuccessfully\b|not done/) {
		return $self->SUCCESS();
	}

	return undef;
}

sub importStatus {
	my $self = shift;
	my $status = shift || $self->importStatusString();

	if (!defined($status) || $status !~ /\bsuccessfully\b/) {
		return $self->FAILURE();
	} elsif ($status =~ /with warnings|Zip Error/) {
		return $self->WARNING();
	} elsif ($status =~ /\bsuccessfully\b/) {
		return $self->SUCCESS();
	}

	return undef;
}

# Performs a data push of a given export to the presentation instance.
# Assumes that the presentation instance is down.
#
sub importIntoPresentation {
	my $self = shift;
	my $me = shift;

	my $presentationProduct = $self->presentationProduct();
	my $loadingProduct      = $self->loadingProduct();

	my $baseExportDir = $self->_baseExportFilePath();
	unless ($baseExportDir) {
		print "Error: customer ",$loadingProduct->customer()," does not have an export directory defined!\n";
		return undef;
	}

	my $loadingBaseReleaseName = ariba::monitor::ANLExportManager->_baseReleaseNameForProduct($loadingProduct);
	my $baseReleaseName        = ariba::monitor::ANLExportManager->_baseReleaseNameForProduct($presentationProduct);

	if (scalar($self->_listDuplicateExports()) > 0) {
		print "Warning: duplicates detected:\n", join("\n", map({$_->toString(1)} $self->_listDuplicateExports())), "\n\n";
	}

	my @exports = $self->_listExports();
	my $chosenExport;
	my $answer;
	
	unless (scalar(@exports)) {
		print "No exports available for this customer.\n";
		return undef;
	}

	print "Data push from ", $loadingProduct->customer(), "  to ", $presentationProduct->customer(), " ($baseReleaseName)\n";
	print "The following are available for import for ", $loadingProduct->customer(), " :\n\n";


	# get export file choice from user
	while (!$chosenExport) {

		my $export = undef;
		my $index = 1;

		for $export (@exports) {
			print "[$index] ", $export->toString(1), "\n\n";
			++$index;
		}

		print "Choice: ";
		$answer = <STDIN>;
		chomp($answer);
		if ($answer !~ /^\d+$/ || $answer < 1 || $answer > scalar(@exports)) {
			print "Invalid choice $answer. Please enter a number between 1 and ",scalar(@exports), "\n";
			next;
		}

		$export = $exports[$answer - 1];
		print "[$answer] ", $export->toString(1), "\n\n";
		next unless _getConfirmation();
		$chosenExport = $export;
		last;
	}

	# check app version of export file against app version of customer
	# product
	if ($chosenExport->version() ne $baseReleaseName) {
		print "Error: base release version of selected export file (", $chosenExport->version(),
			  ") does not match base release version of customer ", $presentationProduct->customer(), " ($baseReleaseName)\n";
		unless($self->force()){
			print "Import aborted.\n";
			return;
		}
	}

	print "\n";

	# check that the selected export was successfull
	$self->setExportStatusString($chosenExport->exportStatusString());
	unless ($self->exportStatus() eq $self->SUCCESS()) {
		print "Error: the selected export file did not complete successfully or completed with warnings.\n";
		if ($self->force()) {
			unless (_getConfirmation("Do you wish to continue ?")) {
				print "Import aborted.\n";
				return;
			}
		}
		else {
			print "Import aborted.\n";
			return;
		}
	}

	# make sure we can decompress the export file successfully before
	# dropping any tables
	if( !$chosenExport->unzip() ){
		print "Import Aborted: Failed to decompress ", $chosenExport->toString(), ": ",$chosenExport->zipError(),"\n";
		return;
	}

	# get list of tables to drop/import
	my @importTablesList = ();
	my $cannonicalExportLogFile = $chosenExport->cannonicalExportLogFileName();
	open(EXPORTLOG, "<$cannonicalExportLogFile") || die "Cannot open export logfile $cannonicalExportLogFile: $!";
	while (<EXPORTLOG>) {
		next unless /^\. \. exporting table\s+(\w+)\s+\d+ rows exported$/;
		push(@importTablesList, $1);
	}
	close(EXPORTLOG);

	print "About to run Task.DropStarSchemaTables to drop tables, proceed?\n";
	if ($self->noAction()){
		print "Note: noaction is set, this will not actually drop any tables\n";
	}
	unless (_getConfirmation()) {
		print "Import aborted.\n";
		return;
	}

	my $oracleClient = $self->_setupOracleClient($presentationProduct);

	unless ($self->noAction()) {
		my @tasks = (
				"resetdatabaseowner", 
				"runtask -task Task.DropStarSchemaTables",
				);
		if (!$self->executeTasks(@tasks)) {
			print "DropStarSchemaTables task failed!\n";
			return;
		}
		$oracleClient->executeSql("drop table SOURCESYSTEMCONFIGTAB");
		if ($oracleClient->error()) {
			if ($oracleClient->error() =~ m/^ORA-00942: table or view does not exist/){
				$oracleClient->setError(undef);
			} else {
				print "Import aborted due to Oracle error:", $oracleClient->error(), "\n";
				return;
			}
		}
	}

	print "Tables dropped successfully.\n\n";
	unless (_getConfirmation("Begin import now?")) {
		print "Import aborted.\n";
		return;
	}

	my $importParamHash = {
		LOG =>  $chosenExport->cannonicalImportLogFileName(),
		FILE => $chosenExport->cannonicalExportFileName(),
		TABLES => \@importTablesList,
	};

	if ( !$self->noAction() ) {

		print "Import begun:    ", ariba::Ops::DateTime::prettyTime(time()),"\n";
		# do the push here
		if (!$oracleClient->dbImport($importParamHash) || $oracleClient->error()) {
			print "Error: import failed: ", $oracleClient->error(),"\n";
		}
		else {
			$self->setImportStatusString($chosenExport->importStatusString());
			print "Import finished: ", ariba::Ops::DateTime::prettyTime(time()),"\n",
					$self->importStatusString(),"\n";

			# update nextBaseId
			if ($chosenExport->nextBaseId()) {
				print "Updating nextBaseId...\n";

				# get the current nextBaseId
				my $nextBaseIdQuery= "select ALONG from NAMEDLONGTAB WHERE ANAME = 'nextBaseId'";
				my $currentNextBaseId = $oracleClient->executeSql($nextBaseIdQuery);
				if ($oracleClient->error()) {
					print "OracleClient Error:", $oracleClient->error(), "\n";
					$self->setImportStatusString("Failed to update nextBaseId: ". $oracleClient->error());
				}

				if ($currentNextBaseId < $chosenExport->nextBaseId()) {
					my $updateStatement = "update NamedLongTab set along = ". $chosenExport->nextBaseId() ." where aname = 'nextBaseId'";
					$oracleClient->executeSql($updateStatement);
					if ($oracleClient->error()){
						print "Error: failed to update nextBaseId: ",$oracleClient->error(),"\n\n";
						$self->setImportStatusString("Failed to update nextBaseId: ". $oracleClient->error());
					} else {
						print "Update successful\n\n";
					}
				} else {
					print "Presentation nextBaseId (",$currentNextBaseId,") is already equal to or higher than ",
						"loading nextBaseId (", $chosenExport->nextBaseId(), "), not doing update.\n";
				}
			}



		}
	} else {
		print "noAction: would have ran imp with:\n";
		for (keys %{$importParamHash}) {
			my $value = $importParamHash->{$_};
			print "$_ => ", ( ref($value) eq "ARRAY" ? "@{$value}":"$value" ), "\n";
		}
		print "\n\n";
		if ($chosenExport->nextBaseId()) {

			# get the current nextBaseId
			my $nextBaseIdQuery= "select ALONG from NAMEDLONGTAB WHERE ANAME = 'nextBaseId'";
			my $currentNextBaseId = $oracleClient->executeSql($nextBaseIdQuery);
			if ($oracleClient->error()) {
				print "OracleClient Error:", $oracleClient->error(), "\n";
				$self->setImportStatusString("Failed to update nextBaseId: ". $oracleClient->error());
			}

			if ($currentNextBaseId < $chosenExport->nextBaseId()) {
				print "noAction: would have updated nextBaseId in presentation instance with nextBaseId=",$chosenExport->nextBaseId(),"\n\n";

			} else {
				print "noAction: Presentation nextBaseId (",$currentNextBaseId,") is already equal to or higher than ",
						"loading nextBaseId (", $chosenExport->nextBaseId(), "), would not have done update.\n\n";
			}
			
		}
	}

	if (!$chosenExport->zip()){
		print $chosenExport->zipError() . "\n";
	}
}

sub _getConfirmation {
	my $question = shift || "Is this correct?";

	print $question, " (y/N):";
	my $answer = <STDIN>;
	chomp($answer);
	if (lc($answer) =~ /y(es|eah|o)?/) {
		return 1;
	}
	return 0;
}

#
# This function takes into consideration all export files for a
# product, not just the ones for the current base release name.
#

sub rotateExportFiles {
	my $self = shift;
	my $product = $self->loadingProduct();

	if ($self->debug()) {
		print "$0: Rotating ",$product->name()," ",$product->customer(),"\n";
	}

	my $exportBaseDir = $self->_baseExportFilePath();

	# If exportBaseDir is invalid just return undef since it means export
	# itself probably didn't happen (and has sent monitoring info).
	unless ($exportBaseDir) {
		print "Warning: export dir not defined for ", $product->customer(), "\n";
		return;
	}
	
	# keep last two exports loaded into presentation instance
	my @presentationExportsToKeep = $self->_listPresentationExports();
	if (scalar(@presentationExportsToKeep) > $self->presentationLoadsToKeep()) {
		@presentationExportsToKeep = @presentationExportsToKeep[0..($self->presentationLoadsToKeep() - 1)];
	}

	# generate list of export file names, sorted in ascending ( oldest to
	# newest) order.
	my @exports = $self->_listExports();
	
	my @kept = ();

	# While there are more export files than the currently set count...
	while (scalar(@exports) > $self->rotationCount()) {

		# ...remove the next oldest export
		my $export = pop @exports;

		# check for exports pushed to presentation that need to be kept
		if (scalar(@presentationExportsToKeep) > 0) {
			if( grep { $export->equals($_) } @presentationExportsToKeep ) {
				push @kept, $export;
				next;
			}
		}

		$self->_purgeExport($export);
	}

	if ($self->debug()) {
		foreach my $export (@exports) {
			print "$0: Keeping due to rotation count: ", $export->toString(1), "\n";
		}
		foreach my $export (@kept) {
			print "$0: Keeping due to presentation load count: ", $export->toString(1), "\n";
		}
	}

	foreach my $duplicateExport ($self->_listDuplicateExports()) {
		$self->_purgeExport($duplicateExport);
	}

	$self->_cleanupEmptyVersionDirs();
}

sub _purgeExport {
	my $self = shift;
	my $export = shift;

	if (!$self->noAction()) {
		$export->purge() || print "$0: Warning: can't remove export bundle ",$export->toString(), ": $!";
	} else {
		print "noAction set: would have deleted ", $export->toString(), "\n";
	}
}

sub _cleanupEmptyVersionDirs {
	my $self = shift;

	my $exportBaseDir = $self->_baseExportFilePath();
	return unless defined($exportBaseDir);

	opendir(BASEDIR, $exportBaseDir) || die "Can't open $exportBaseDir: $!\n";
	my @versions = grep  { !/^[.]{1,2}/ && -d "$exportBaseDir/$_" } readdir (BASEDIR);
	closedir(BASEDIR);

	
	for my $versionDir (@versions) {
		opendir (VERSIONDIR, "$exportBaseDir/$versionDir") || next;
		my @files = grep { !/^[.]{1,2}/ } readdir(VERSIONDIR);
		closedir(VERSIONDIR);

		if (scalar(@files) < 1) {
			rmdir("$exportBaseDir/$versionDir") || warn "Couldn't remove empty version dir $exportBaseDir/$versionDir: $!\n";
		}
	}
}

#
# $filename               - name of table list file, found under the config dir of the
# 							loading product instance
# $tableListRef           - array ref to store list of tables to export
# $tableListIsExcludedRef - scalar ref that gets set to true (1) if
#							this is an exclude list.
#
# Syntax for the table listing file is:
#     - one table name per line
#     - [exclude-list] (including brakckets) on a line by itself will cause
#       this list to be interpreted as an exlude list (i.e. tables not to be
#       exported).
#     - the '#' character starts a comment; comments must be on their own
#       lines
#

sub _populateTableList {
	my $self = shift;
	my $tableListRef = shift;
	my $tableListIsExcludeRef = shift;

	$$tableListIsExcludeRef = 0; # by default this is an include list

	my $requiredTableList = $self->loadingProduct()->configDir() . "/$DEFAULTTABLELISTFILE";
	my @tableListFiles = ($requiredTableList);

	my $optionalTableList = $self->loadingProduct()->configDir() . "/$DEFAULTCUSTOMERTABLELISTFILE";
	push (@tableListFiles, $optionalTableList) if -f $optionalTableList;
	
	for my $tableListFilePath (@tableListFiles) {
		open(TABLELIST, "<$tableListFilePath") or return "can't open $tableListFilePath: $!";

		while (my $line = <TABLELIST>) {
			next if $line =~ /^\s*$/;
			next if $line =~ /^\s*#.*$/;

			chomp($line);

			if ($line =~ /\[(\w)*-list\]/) { # matches "[exclude-list]" or "[include-list]"
				$$tableListIsExcludeRef = 1 if $1 eq 'exclude';
			}
			else {
				push @{$tableListRef}, $line;
			}
		}
		close(TABLELIST);
	}
	return 0; # any other return value indicates error
}

# 
# report on current status of exports, listing
# 1) duplicate export files
# 2) all non-duplicate export files -- dataload complete time, export complete time, version, file name
# 3) export files which had been loaded into the presentation instance, marking the current one

sub exportStatsToString {
	my $self = shift;

	my $exportStatString = "\nExport stats for customer ". 
		$self->presentationProduct()->customer(). "/". $self->loadingProduct()->customer(). ":\n\n";

	# 1
	if (scalar($self->_listDuplicateExports()) > 0) {
		$exportStatString .= "Warning: duplicates detected:\n" . 
			join("\n", map({$_->toString()} $self->_listDuplicateExports())) . "\n\n";
	}

	# 2
	my @exports = $self->_listExports();
	if (scalar(@exports)) {
		foreach my $export ($self->_listExports()) {
			$exportStatString .= $export->toString(1) . "\n\n";
		}
	} else {
		$exportStatString .= "\tNo exports available.\n\n";
	}

	# 3
	my $baseExportDir = $self->_baseExportFilePath();

	my @presentationExports = $self->_listPresentationExports();
	if (scalar(@presentationExports) > 0) {
		my $export = shift(@presentationExports);
		$exportStatString .= "\nPresentation instance is running:\n\n". $export->toString(1) ."\n\n";

		if (scalar(@presentationExports) > 0) {
			$exportStatString .= "Previous exports pushed to presentation:\n\n";

			foreach $export (@presentationExports) {
				$exportStatString .= $export->toString(1) . "\n\n";
			}
		}
	}
	else {
		my $customer = $self->loadingProduct()->customer();
		$exportStatString .= "Migration from loading to presentation not done for customer $customer\n";
	}

	return $exportStatString;
}

########## private methods #############

# Returns the list of export files loaded into the presentation instance,
# sorted in ascending order of last load.  E.g. (<latest>, <second-latest>,
# <third-latest>, ..., <Nth-latest>).
#
sub _listPresentationExports {

	my $self = shift;

	$self->_faultInExports();

	my @presentationExports = ();
	for my $export ($self->_listExports()) {
		if ($export->importStatusString()) {
			push @presentationExports, $export;
		}
	}

	# sort in descending time order (latest goes first)
	@presentationExports = sort( { $b->importCompleteTime() <=> $a->importCompleteTime() } @presentationExports);

	# no idea why this doesn't work
	# my @presentationExports = 
	#		sort { $a->importCompleteTime() <=> $b->importCompleteTime() }
	# 		grep { $_->importStatusString() } 
	# 		$self->_listExports();

	return @presentationExports;
}

sub _baseExportFilePath {
	my $self = shift;

	return ariba::monitor::ANLExportManager->_baseExportFilePathForProduct($self->loadingProduct());
}

# this method returns an oracleClient object appropriate for use with ANLExportManager
# when called as an instance method it will try to cache OracleClients
#
sub _setupOracleClient {
	my $self = shift;
	my $product = shift;
	my $debug = shift;

	$debug = $self->debug() if ref($self);

	my $clientKey = $product->customer() . "-oracleClient";
	my $oracleClient = $self->{$clientKey} if ref($self);

	unless (defined($oracleClient)) {

		my @connections = ariba::Ops::DBConnection->connectionsFromProducts($product);
		my @dbc = ariba::Ops::DBConnection->uniqueConnectionsByHostAndSidAndSchema(@connections);

		$oracleClient = ariba::Ops::OracleClient->newFromDBConnection(shift(@dbc));

		$oracleClient->setDebug($debug) if ($debug && $debug > 1);

		if ($debug) {
			print "$0: Customer:", $product->customer(),": OracleClient connect with ", join ( "::", $oracleClient->user(), $oracleClient->sid() ),
			      "\n",
			      "$0: connect string: ",ariba::rc::Utils::connectStringForSidOnHost($oracleClient->sid(), $oracleClient->host()),":",
			      "\n";
		}

		$oracleClient->connect();
		$self->{$clientKey} = $oracleClient if ref($self);
	}

	return $oracleClient;
}

# given an ariba::Ops::OracleClient object, returns the last data load 
# start and finish timestamps.
sub lastDataLoadTimes {
	my $self = shift;
	my $product = shift || $self->loadingProduct();
	
	return undef unless $product;

	my $oracleClient = $self->_setupOracleClient($product);

	my ($lastDataLoadStartTime, $lastDataLoadEndTime);

	my ($analysisCompletedTS, $analysisStartedTS) = ("AnalysisInitDBCompletedTimeStamp", "AnalysisInitDBStartedTimeStamp");

	my $selectSql =
	"Select ANAME, ALONG from NAMEDLONGTAB WHERE ANAME IN ( ".
	                "'$analysisCompletedTS', ".
	                "'$analysisStartedTS') ".
	"order by ALONG ASC";

	my @times = $oracleClient->executeSql($selectSql);
	my $colsep = $oracleClient->colsep();

	for my $row (@times) {
		my ($name, $value) = split(/$colsep/, $row); 

		if ( $name =~ /$analysisStartedTS/ ) { 
			$lastDataLoadStartTime = $value; 
			next;
		}
		if ( $name =~ /$analysisCompletedTS/ ) { 
			$lastDataLoadEndTime = $value; 
			next;
		}
	}
	
	return ($lastDataLoadStartTime, $lastDataLoadEndTime);
}

#
# for each existing export (i.e. each file ending in .exp
#  or .exp.gz) in 
# <customer>-T/dbexports/<version1>/
#                    .../<version2>/
# 
# insert into 'exportsHash' (via auto-loaded setExportsHash) an export object
# representing this export session, using the export objects hashKey() method
# for the key.
# 
# Additionally, push onto 'duplicateExportsArray' all exports which appear to
# be duplicates. See below for the algorithm used to determine this.

sub _faultInExports {
	my $self = shift;

	return if $self->{'exportFilesFaultedIn'};
	$self->{'exportFilesFaultedIn'} = 1;

	my %exports = ();
	my @duplicateExports = ();

	$self->setExportsHash(\%exports);
	$self->setDuplicateExportsArray(\@duplicateExports);

	my $exportBaseDir = $self->_baseExportFilePath();

	# this is the version of ANL running in loading instance
	my $currentBaseReleaseVersion = ariba::monitor::ANLExportManager->_baseReleaseNameForProduct($self->loadingProduct());

	# Grab the list of subdirs (which are base release versions)
	my $subdh = DirHandle->new($exportBaseDir) || die "Can't open $exportBaseDir: $!\n";
	for my $baseReleaseVersion ($subdh->read()) {
		next if $baseReleaseVersion =~ /^[.]{1,2}/;
		my $exportDir = $exportBaseDir . '/' . $baseReleaseVersion;
		next unless -d $exportDir;

		my $dh = DirHandle->new($exportDir) || die "Can't open $exportDir: $!\n";

		for my $file ($dh->read()) {
			next unless ariba::monitor::ANLExport->isExportFile($file);

			my $export = ariba::monitor::ANLExport->newFromFile($file, $baseReleaseVersion, $exportBaseDir);

			# Because the filename is the timestamp of the
			# corresponding data load there may be more than one
			# file with the same name under different versions.

			if (exists($exports{$export->hashKey})){

				# A) version in export hash == current product version
				# B) current dir (baseReleaseVersion) == current product version
				# C) neither is current version, but export hash is later version
				# D) neither is current version, but current dir (baseReleaseVersion) is later version
				#
				# actions:
				# A | (~B & C) ->  1 == basedir in export hash is correct, file in current dir to be added to duplicates
				# B | (~A & D) ->  2 == basedir in export hash is duplicate, put that one in duplicates and replace with current dir
				#
				#   A and B are mutually exclusive, as are C and D.  Therefore, B == ~A and D == ~C, and
				#   ~(A | (~B & C)) == ~A & (B | ~C) == (~A & B) | (~A & ~C) == (B & B) | (~A & D) == B | (~A & D)
				#   
				if ($export->version() eq $currentBaseReleaseVersion ||
					($baseReleaseVersion ne $currentBaseReleaseVersion && $export->version() cmp $baseReleaseVersion)) {
					# action 1
					push(@duplicateExports, $export);
				}
				else {
					# action 2
					push(@duplicateExports, $exports{$export->hashKey()});
					$exports{$export->hashKey()} = $export;
				}
			}

			else {
				$exports{$export->hashKey()} = $export;
			}

		}
		$dh->close();
	}
	$subdh->close();

}

sub _listExports {
	my $self = shift;

	$self->_faultInExports();

	my @exports = sort {$b->exportCompleteTime() <=> $a->exportCompleteTime()} values(%{$self->exportsHash()});
	return @exports;
}

sub _listDuplicateExports {
	my $self = shift;

	$self->_faultInExports();
	return $self->duplicateExportsArray();

}

sub executeTasks {
	my $self = shift;
	my @tasks = @_;

	my $presentation = $self->presentationProduct();
	my $user         = ariba::rc::Globals::deploymentUser($presentation->name(), $presentation->service());
	my $customer     = $presentation->customer();
	my ($host)       = $presentation->hostsForRoleInCluster("analysis");
	my $password     = ariba::rc::Passwords::lookup($user);

	my $basebin      = "/home/$user/$customer/base/bin";
	# generic template for running all of our tasks
	my $cmdformat    = "ssh -n $host -l $user $basebin/%s";


	# this is so execRemoteCommand doesn't print its own status lines.
	$main::quiet = 1;

	my $result = 1;

	for my $task (@tasks) {
		my $cmdline = sprintf($cmdformat, $task);

		if ($self->noAction()) {
			print "noAction: Would execute:$cmdline\n";
		} else {
			print "Running $cmdline\n";
			if (ariba::rc::Utils::executeRemoteCommand($cmdline, $password)) {
				print "$task finished successfully.\n\n";
			}
			else {
				print "$task failed!\n\n";
				$result = 0;
				last;
			}
		}
	}

	$main::quiet = 0;
	return $result;
}

######## class methods #################

sub SUCCESS { return 1; }
sub WARNING { return 2; }
sub FAILURE { return 3; }

sub _baseReleaseNameForProduct {
	my $class = shift;
	my $product = shift;

	my $baseReleaseName = $product->baseReleaseName();

	# mangle the base release, e.g.
	# "3.1.0.3 (SLCPhobos-67)" -> "3.1.0.3"
	$baseReleaseName =~ s/^(\d+(?:\.\d+)+).*$/$1/;

	return $baseReleaseName;
}

# returns the base export file path (sans version) for the given product
sub _baseExportFilePathForProduct {
	my $class = shift;
	my $product = shift;

	my $baseDir = $product->default(ROOTDIRKEY);
	$baseDir =~ s/\/$// if $baseDir;

	return $baseDir;
}

1;

