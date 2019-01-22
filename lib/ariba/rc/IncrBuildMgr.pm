package ariba::rc::IncrBuildMgr;

# $Id: //ariba/services/tools/lib/perl/ariba/rc/IncrBuildMgr.pm#42 $


# TODO: this comment needs updating
#
# IncrBuildMgr
#
# Instances of this object will perform an incremental build over a
# universe of metadata described product components.
#
# The component metadata is modeled by instances of CompMeta
#
# Note that CompMeta may encapsulate a ProductDefinition object,
# which is the traditional metadata object for Platform product
# components.
#
# Note also that there are other components that
# can have their metadata modeled by CompMeta that are not
# described by a ProductDefinition; these include AN specific
# and test components.
#
# Given a set of CompMeta objects (a product universe)
# the IncrBuildMgr will construct
# a graph DAG that reflects the dependency tree.
#
# The IncrBuildMgr is also given as input a set of CompMeta objects
# that represent a subset of the product universe (delta) that is to be rebuilt
# including any upstream components that (in)directly depend on the
# delta change set.
#
# The IncrBuildMgr->incrBuild() API is the main external
# method that is to be called by Ariba build scripts like make-build2
# or test programs that exercise this object. A subsequent DFS over
# the constructed graph produces an ordered (bottom up) from most independent
# towards most dependent.
#
# Internal Operation:
#
#     When a node in the DAG is visited that exists in the
# delta change set, an internal callback (rebuildCallback) routine is invoked.
# This rebuildCallback routine, in turn, invokes the user supplied callback that
# was injected via the constructor.
#    We expect that user supplied callback to expect a component name as input and
# to perform a clean rebuild for that component, which produces a set of artifacts
# (jar/zip files).
#    These published artifacts are described by the CompMeta,
# which is related to the DAG node that is being visited. after control is
# returned back to the rebuildCallback a binary compatibility check is performed
# against the prior artifacts (previously backed up at constructor time).
#    This binary compatibility check is important and helps us optimize the
# amount of transitive rebuilding that is necessary because of the change.
#    If the newly produced artifacts are binary compatibile, then the upstream
# dependencies (those that depend directly or indirectly on the changed component)
# are not subsequently rebuilt!
#     When the change is not binary compatible, all upstream transitive dependencies
# will be rebuilt as we must fail the build if there was a signature change that
# was not refactred in a dependent component. Note that a change is binary
# compatible for our purposes when there is no changes to the signature of
# public or procted fields, methods or inherited types.
#
#
# The IncrBuilkdMgr object has the following internal attributes (API):
#
# $self->{$PRODUCT_ID}           string name of product
# $self->{$PRODUCT_UNIVERSE_MAP} hash<component name, CompMeta>
# $self->{$BASE_LABEL}           string base label name
# $self->{$COMP_BUILD_CALLBACK}  reference to a component build callback routine
# $self->{$COMP_CLEAN_CALLBACK}  reference to a component clean callback routine
# $self->{$DELTA_COMPS_META}     reference to array of CompMeta for the delta change
# $self->{$DEBUG}                0 or 1
# $self{$BINARY_COMPAT_CHECKER}  reference to a binary compat checking routine (test hook)
# $self->{$PRIOR_BUILD_INSTALLER} reference to a subroutine to install prior build image (test hook)
# $self->{$INDEXER_CALLBACK} reference to a subroutine to invoke a java package to Ariba comp indexer (test hook)
# $self->{$VALIDATE_META_CALLBACK} reference to a subroutine to invoke DependencyEmitter (test hook)
#

use strict;
no warnings 'recursion';
use Data::Dumper;
use ariba::rc::CompMeta;
use ariba::rc::IncrBuildPlugins::IncrBuildPluginBase;
use ariba::rc::IncrBuildMgrException;
use ariba::rc::JavaClassIndexer;
use ariba::rc::IncrBuildMgrResults;
use ariba::rc::MergeFileIndexer;
use File::Copy;
use File::Path;
use lib "$ENV{'ARIBA_SHARED_ROOT'}/bin";
use Ariba::P5;
use Time::HiRes qw(gettimeofday);
use File::Basename;
use POSIX;
use Cwd 'abs_path';

my $ARIBA_BUILD_ROOT = $ENV{'ARIBA_BUILD_ROOT'};
my $ARIBA_INSTALL_ROOT = $ENV{'ARIBA_INSTALL_ROOT'};
my $ARIBA_SHARED_ROOT = $ENV{'ARIBA_SHARED_ROOT'};
my $JAVA_HOME = $ENV{'JAVA_HOME'};
my $ARIBA_SOURCE_ROOT = $ENV{'ARIBA_SOURCE_ROOT'};
my $ORIG_P4CLIENT = $ENV{'P4CLIENT'};
my $CLEANING_P4CLIENT = "$ORIG_P4CLIENT-cleaning";

# self object attribute keys:
my $PRODUCT_ID = 'productId';
my $PRODUCT_UNIVERSE_MAP = 'productUniverseMap';
my $BASE_LABEL = 'baseLabel';
my $BUILD_NAME = 'buildName';
my $COMP_BUILD_CALLBACK = 'compBuildCallback';
my $COMP_CLEAN_CALLBACK = 'compCleanCallback';
my $DELTA_COMPS_META = 'deltaCompsMeta';
my $DEBUG = 'debug';
my $DEPSMAP = 'depsmap';
my $BINARY_COMPAT_CHECKER = 'binaryCompChecker';
my $PRIOR_BUILD_INSTALLER = 'priorBuildInstaller';
my $INDEXER_CALLBACK = 'indexerCallback';
my $VALIDATE_META_CALLBACK = 'validateMetaCallback';
my $INDEX_DIR = 'indexDir';
my $VALIDATE_META_FOR_ALL_COMPS = 'validateAllComps';
my $DIE_ON_VALIDATE_META_MISMATCH = 'dieOnValidationMismatch';
my $RESULTS = 'results';
my $WANT_RESULTS = 'wantResults';
my $FULL_BUILD = 'fullBuild';
my $FILEMERGE_COMPS_LIST = 'filemergeCompsList';
my $FILEMERGE_FILE_LIST = 'filemergeFilesList';
my $REPORT_REBUILD_LIST_ONLY= 'reportRebuildListOnly';
my $BUILD_ID = 'buildId';
my $USE_BACKDROP = 'useBackdrop';
my $BACKDROP = 'backdrop';
my $BOOTSTRAP_ROOTS = 'bootstrapRoots';
my $ADDVISCHANGEINFO = 'addvischangeinfo';
my $JAVA_CLASS_INDEXER = 'javaClassIndexer';
my $CLASSES_ADDED = 'classesAdded';
my $LIST_OF_ROOTS = 'listOfRoots';
my $REBUILD_REQUIRED_PLUGINS = 'rebuildRequiredPlugins';
my $CLEAN_CLIENT= 'cleanClient';

# The a dependency map depsmap is a hash where:
#   key is String component name; value is reference to inner hash
#   The innerhash has string key=$DEPENDSONKEY or $USEDBYKEY
#   and the value is an array of String component names

# depsmap keys
my $USEDBYKEY = 'usedby';
my $DEPENDSONKEY = 'dependson';
# other constants
my $SUCCESS = 'SUCCESS';
my $BUILD_ROOT_BACKUP_FILE = "$ARIBA_INSTALL_ROOT/internal/build/incbuildroot.tar";
my $BACKDROP_FILE = "$ARIBA_INSTALL_ROOT/internal/build/incbuildbackdrop.txt";

{
    #
    # Constructor
    # Default behavior is to :
    #   - validate metdata only on delta comps
    #   - die on metadata validation mismatch
    #   - full build will not be done
    #   - result object from incrBuild() is not an IncrBuildMgrResults
    #   - default directory
    #
    sub new {
        my $class = shift;
        my $self = {};
        bless ($self, $class);

        if (!defined $ARIBA_INSTALL_ROOT) {
            die _incrDie("The ARIBA_INSTALL_ROOT environmnent varibale must be defined in the environment\n");
        }
        if (!defined $ARIBA_SHARED_ROOT) {
            die _incrDie("The ARIBA_SHARED_ROOT environmnent varibale must be defined in the environment\n");
        }

        my %productUniverseMap = ();
        $self->{$PRODUCT_UNIVERSE_MAP} = \%productUniverseMap;

        my @deltaCompsMeta = ();
        $self->{$DELTA_COMPS_META} = \@deltaCompsMeta;

        my %depsmapouterhash = ();
        $self->{$DEPSMAP} = \%depsmapouterhash;

        my %bootstraphash = ();
        $self->{$BOOTSTRAP_ROOTS} = \%bootstraphash;

        my %addvischangeinfo = ();
        $self->{$ADDVISCHANGEINFO} = \%addvischangeinfo;

        $self->validateMetadataForAllComps(0);
        $self->dieOnValidateMetadataMismatches(1);

        $self->{$RESULTS} = ariba::rc::IncrBuildMgrResults->new();

        $self->setWantResults(0);
        $self->setFullBuild(0);

        my $uniqueId = gettimeofday;
        $self->setBuildId($uniqueId);

        my $incrBuildIndexDir = "$ARIBA_INSTALL_ROOT/internal/build/index";
        $self->_createIndexDir($incrBuildIndexDir);
        $self->setPackageToCompsIndexDirectory($incrBuildIndexDir);;
        $self->setFilemergeIndexDirectory($incrBuildIndexDir);

        return $self;
    }

    # Call this API to run the incremental build in a way that no rebuilding
    # or validation or binary compatible checks are done - strictly return the list
    # of components that would be rebuilt if the components in the delta set are compatible or not (depending on the flag).
    # Input 1: Pass 0 to have delta set be treated as binary compatible; all other flag values represent incompatible changes
    sub reportRebuildListOnly {
        my ($self, $treatAsIncompatible) = @_;
        $self->{$REPORT_REBUILD_LIST_ONLY} = $treatAsIncompatible;
    }

    # Input 1: non-zero to return IncrBuildMgrResults from incrBuild()
    sub setWantResults {
        my ($self, $flag) = @_;
        if (defined $flag) {
            $self->{$WANT_RESULTS} = $flag;
        }
    }

    # Input 1: non-zero to perform full build
    sub setFullBuild {
        my ($self, $flag) = @_;
        if (defined $flag) {
            $self->{$FULL_BUILD} = $flag;
            if ($flag) {
                $self->_prepareBaseImageForFullBuild();
            }
        }
    }

    # If input defined non-zero then:
    # In conjunction with full incr build: sync the baseline client client (no need to incrementally clean using the baseline)
    # In conjunction with pure incr build: sync the baseline client client and incrementally clean using the baseline
    sub setCleanClient {
        my ($self, $flag) = @_;
        $self->{$CLEAN_CLIENT} = $flag;
    }

    sub setBackdrop {
        my ($self, $flag, $value) = @_;
        $self->{$USE_BACKDROP} = $flag;
        $self->{$BACKDROP} = $value;
    }

    sub setDebug {
        my ($self, $flag) = @_;
        $self->{$DEBUG} = $flag;
    }

    # Input 1: Scalar flag when 0 validate metadata for delta comps only; otherwise validate all comps
    sub validateMetadataForAllComps {
        my ($self, $flag) = @_;

        if (defined $flag) {
            $self->{$VALIDATE_META_FOR_ALL_COMPS} = $flag;
        }
        else {
            $self->{$VALIDATE_META_FOR_ALL_COMPS} = 0;
        }
    }

    # Input 1: Scalar flag when 0 do not die on metadata validation mismatch; otherwise die
    sub dieOnValidateMetadataMismatches {
        my ($self, $flag) = @_;

        if (defined $flag) {
            $self->{$DIE_ON_VALIDATE_META_MISMATCH} = $flag;
        }
        else {
            $self->{$DIE_ON_VALIDATE_META_MISMATCH} = 0;
        }
    }

    # Input string identifier for this build
    sub setBuildId {
        my ($self, $id) = @_;

        $self->{$BUILD_ID} = $id;
    }

    #
    # init
    #
    # Consider calling this from within the constructor
    # or alternatively, inline inside of incrBuild.
    #
    # Input 1: productId: String representing product to be built
    # Input 2: productUniverse: reference to array of CompMeta objects in the product universe
    # Input 3: deltaCompMeta: reference to array of CompMeta objects in the delta change (can pass undef and call loadDelta later)
    # Input 4: baseLabel: String
    # Input 5: compBuildCallback Reference to a subroutine to call to build the component
    # Input 6: $wantResults: non-zero to return IncrBuildMgrResults from incrBuild()
    # Input 7: $fullBuild : non-zero to build the universe (note that fullBuild will be automatically set if it determs there is no base full incr build image)
    # Return 1 if fullBuild was changed; 0 otherwise
    sub init {
        my ($self, $productId, $productUniverseRef, $deltaCompMetaRef, $baseLabel, $compBuildCallback, $wantResults, $fullBuild, $buildName) = @_;

        $self->_banner("Initializing", 1);

        $self->{$PRODUCT_ID} = $productId;
        $self->{$BASE_LABEL} = $baseLabel;
        $self->{$BUILD_NAME} = $buildName;
        $self->{$COMP_BUILD_CALLBACK} = $compBuildCallback;

        $self->_loadProductUniverseMap($productUniverseRef);

        if (defined $fullBuild) {
            $self->setFullBuild($fullBuild); # This will prepare base image for full build
        }

        my $wentIntoFullBuildMode = 0;
        unless ($self->{$FULL_BUILD}) {
            $wentIntoFullBuildMode = $self->_prepareBaseImageForPureIncrBuild();
        }

        if ($deltaCompMetaRef) {
            $self->loadDelta($deltaCompMetaRef);
        }

        $self->_constructDAG();

        $self->setWantResults($wantResults);

        $self->{$JAVA_CLASS_INDEXER} = ariba::rc::JavaClassIndexer->new($self->{$INDEX_DIR});

        $self->_loadFilemergeList($deltaCompMetaRef);

        $self->{$REBUILD_REQUIRED_PLUGINS} = ariba::rc::IncrBuildPlugins::IncrBuildPluginBase->new($self->{$PRODUCT_UNIVERSE_MAP}, $self);

        $self->_debug("Done Initializing", 1);
        return $wentIntoFullBuildMode;
    } # init

    sub _createClassIndexes {
        my ($self) = @_;

        if ($self->{$FULL_BUILD}) {
            $self->{$JAVA_CLASS_INDEXER}->removeClassIndex();
            my @productUniverse = $self->_getProductUniverseComps();
            $self->{$JAVA_CLASS_INDEXER}->createAuxClassIndexes(\@productUniverse);
        }
    }

    # Input 1: reference to callback to perm the component cleaning
    sub setCompCleanCallback {
        my ($self, $cleanCallback) = @_;

        $self->{$COMP_CLEAN_CALLBACK} = $cleanCallback;
    }

    # A P4 client named "$P4CLIENT-cleaning is created for use by comp build
    # code to sync and clean those comp using the base label version Makefiles
    sub _createCleaningClient {
        my ($self) = @_;

        my $asrc = $ARIBA_SOURCE_ROOT;
        # Replace "/" with "\\/"
        $asrc =~ s/\//\\\\\//g;
        $asrc .= "cleaning";

        # Create a copy of the orignal p4client, but switch the Root field
        # and filter out files and dirs we know wont be needed by Linux based component cleans
        # -//ariba/....java //$CLEANING_P4CLIENT/...java
        my $cmd = "p4 client -o $CLEANING_P4CLIENT | sed s/Root\:.*/Root\:\\\t$asrc/ | sed s/Host\:.*// | p4 client -i";

#        # We don't need all this alternate platform files for cleaning; it saves disk space and help sync speed
#        my $filefilter = "";
#        for my $extension ("java", "gif", "swf", "html", "doc", "ps", "exe", "dll", "jar", "war", "ear", "zip", "tar", "gz", "bz2", "cat") {
#            # Ex: "\n\t-\/\/ariba\/....java\t\/\/$CLEANING_P4CLIENT\/....java";
#            $filefilter .= '\n\t\-\/\/ariba\/....' . $extension . "\t\/\/$CLEANING_P4CLIENT\/...." . "$extension";
#        }
#
#        my $dirfilter = "";
#        for my $dirname ("jvms", "sparc", "HP_UX", "sun", "windows", "SunOS", "win32", "Win32", "hpux", "AIX", "irix", "weblogic", "websphere", "macosx", "source", "solaris") {
#            # Ex: "\n\t-\/\/ariba\/...\/jvms\/... \/\/$CLEANING_P4CLIENT\/...\/jvms\/...";
#            $dirfilter .= '\n\t\-\/\/ariba\/...\/' . $dirname . "\/...\t\/\/$CLEANING_P4CLIENT\/...\/" . "$dirname" . "\/...";
#        }
#
#        my $sedfilter = $filefilter . $dirfilter;
#        my $sedfiltercmd = 'sed \'$a\\' . $sedfilter . "\'" ;

        $self->_debug("Creating the P4 cleaning client \"$CLEANING_P4CLIENT\" using command = $cmd");
        my @out = qx "$cmd";
        my $ret = $?;

        if ($ret > 0) {
            # perldoc -f system (must >> 8 to get actual value)
            $ret = $ret >> 8;
            die _incrDie("IncrBuildMgr: ERROR running the command to create the p4 client for baseline cleaning. The command=\"$cmd\"\n");
        }
    }

    sub _syncSharedToCleaningClient {
        my ($self) = @_;

        my $sharedCompMeta = $self->_getCompMeta("prod_shared");
        my $p4spec = $sharedCompMeta->getBaselineP4Spec();
        my $cmd = "p4 -c $CLEANING_P4CLIENT sync $p4spec";
        $self->_debug("Syncing component \"prod_shared\" to the cleaning client using command: \"$cmd\"", 1);
        my @out = qx "$cmd";
        my $ret = $?;
        $self->_debug("Done syncing component \"prod_shared\" to the cleaning client", 1);

        if ($ret > 0) {
            # perldoc -f system (must >> 8 to get actual value)
            $ret = $ret >> 8;
            die _incrDie("IncrBuildMgr: ERROR running the command to sync the p4 cleaning client for \"prod_shared\" The command=\"$cmd\"\n");
        }
    }

    # Sync and (clean unless full build) a component to the base build label
    # The p4 clen client should be previously switched (but will switch automatically if it has to)
    # Input 1: CompMeta to baseline sync and clean
    sub syncAndCleanCompAtBaseline {
        my ($self, $compMeta) = @_;

        my $cname = $compMeta->getName();

        my $notmsg = "Not performing component sync and clean to the cleaning client for \"$cname\"";
        if (! $self->{$CLEAN_CLIENT}) {
            $self->_debug($notmsg . " because there is no clean client defined");
            return;
        }

        my $cb = $self->{$COMP_CLEAN_CALLBACK};
        if (! $cb) {
            $self->_debug($notmsg . " because there is no clean callback defined");
            return;
        }

        my $cleanCommand = $compMeta->getCleanCommand();
        if (! $cleanCommand) {
            $self->_debug($notmsg . " because there is no clean command defined");
            return;
        }

        my $p4spec = $compMeta->getBaselineP4Spec();
        if (! $p4spec) {
            $self->_debug($notmsg . " because there is no baseline P4 Spec command defined");
            return;
        }

        # Now sync the component using the base label
        # We sync the baseline component using the cleaning client even in full builds so that syncing the cleaning client 
        # during pure incremental will be faster. For example, in the case that a delta component is part of a filemerge network,
        # then the sync of the filemerge network of comps to the cleaning client will be fast.
        # We want the pure incr builds to be as fast as possible.

        my $cmd = "p4 -c $CLEANING_P4CLIENT sync $p4spec";

        if ($self->{$FULL_BUILD}) {
            $self->_debug("Syncing component \"$cname\", to the cleaning client, so that during the next pure incremental build the sync will be fast.\nDo not be alarmed by this: \"$cmd\"", 1);
        }
        else {
            $self->_debug("Syncing component \"$cname\", to the cleaning client, so the next cleaning step removes obsolete files: \"$cmd\"", 1);
        }

        my @out = qx "$cmd";
        my $ret = $?;
        $self->_debug("Done Syncing component \"$cname\" to cleaning client", 1);

        if ($ret > 0) {
            # perldoc -f system (must >> 8 to get actual value)
            $ret = $ret >> 8;
            die _incrDie("IncrBuildMgr: ERROR running the command to sync the component \"$cname\" to the cleaning client. The command=\"$cmd\"\n");
        }

        unless ($self->{$FULL_BUILD}) {
            $self->_debug("Cleaning component \"$cname\" to the cleaning client", 1);
            my $msg = &$cb($compMeta, $CLEANING_P4CLIENT);
            if ($msg ne $SUCCESS) {
                $self->_warn("Unexpected issue \"$msg\" while cleaning component \"$cname\" to the cleaning client");
            }
            $self->_debug("Done Cleaning component \"$cname\" to the cleaning client", 1);
        }
    }

    # This is the main external API to begin the incremental build
    # It performs a DFS over the DAG (depsmap) invoking the
    # rebuildCallback for components that need to be rebuilt.
    #
    # Return Style 1: (when $wantResults) IncrBuildMgrResults object
    # Return Style 2: (undef or $wantResults == 0) hash of component names that were rebuilt to compatibility flag value (0 a compat delta, 1 an incompat delta; 2 a transitive rebuild)
    # May throw (die) an IncrBuildMgrException if a component can't be rebuilt
    sub incrBuild {
        my ($self) = @_;

        my $start = time();
        $self->_banner("Starting the component build phase", 1);

        # We assert that we can use the previous builds p4 client during incremental build
        # as all the current p4 syncing has taken place. We will restore to the original p4 client at the end
        if ($self->{$CLEAN_CLIENT}) {
            $self->_debug("About to create the P4 cleaning client because the feature is enabled");
            $self->_createCleaningClient();
            unless ($self->{$FULL_BUILD}) {
                $self->_syncSharedToCleaningClient();
            }
        }
        else {
            $self->_debug("Not creating P4 cleaning client because the feature is disabled");
        }

        # load rebuildSet from delta and filemerge sets
        my %deltaSet = (); # <component name, component name>
        my %filemergeSet = (); # <component name, component name>
        $self->_updateRebuildSet(\%deltaSet, \%filemergeSet);

        my $rootsRef = $self->_getListOfRoots();

        # dfs over each root
        my %visitedSet = (); # component names we've visited (not necessarily rebuilt)
        my %rebuildHash = (); # hash of component name keys to compatibility flag values (0==compat,1==direct incompat,2==indirect incompat) that were rebuilt over all roots
        foreach my $cm (@$rootsRef) {
            my %thisRootsRebuildHash = (); # hash of component name keys to compatibility flag values over just this root
            my $root = $cm->getName();
            if (defined $root) {
                my $abootstrap = $self->_isTransitiveBootstrapRoot($cm);
                $self->_debug("Starting build dfs at root \"$root\"");

                $self->_dfs($root, $root, \%deltaSet, \%filemergeSet, \%rebuildHash, \%thisRootsRebuildHash, \%visitedSet, $abootstrap);
            }
        }

        my $elapsed = Ariba::P5::getElapsedTime(time() - $start);
        $self->_info("Finished the component build phase (delta time = $elapsed)", 1);

        $self->_saveBuildRoot();
        # TODO we really need a rolling archive area
        #        $self->_deleteBackupDir();

        # TODO: We really should have only one way to return results
        # Using an IncrBuildMgrResults would mean we can simply _dfs to not work the rebuildHash parameter (but IncrBuildMgrTest must be refactored)

        if ($self->{$FULL_BUILD}) {
            $self->_debug("About to create full class index", 1);
            $self->_createClassIndexes();
            $self->_debug("Done creating full class index", 1);

            $self->_debug("About to perform full metadata validation", 1);
            $self->_performFullMetaValidation();
            $self->_debug("Done performing full metadata validation", 1);
        }

        if (defined $self->{$WANT_RESULTS} && $self->{$WANT_RESULTS}) {
            return $self->{$RESULTS};
        }
        return \%rebuildHash;
    }

    # The full incremental build will built up the indexes as it builds each component
    # The metadata validation using the dependencyEmitter consults these indexes
    # so it is necessary to perform this validation once the indexes have stabilized.
    # This routine is intended to be called as a final step in a full incremental
    # build.
    sub _performFullMetaValidation {
        my ($self) = @_;

        my %visitedSet = (); # component names we've visited (not necessarily rebuilt)
        my $rootsRef = $self->_getListOfRoots();

        foreach my $cm (@$rootsRef) {
            my $root = $cm->getName();
            if (defined $root) {
                $self->_performFullMetaValidationDFS($root, $root, \%visitedSet);
            }
        }
    }

    # This routine is to be called to perform the meta validation over a graph
    # Input 1: The string path used to print the component path we're at during the process.
    # Input 2: The name of a node in the DAG that is to be dfs'd over
    # Input 3: A set used to optimize the navigation so we don't re-report
    sub _performFullMetaValidationDFS {
        my ($self, $path, $node, $visitedSetRef) = @_;

        my $depsmapref = $self->{$DEPSMAP};
        my %depsmap = %$depsmapref;
        my $innerhashref = $depsmap{$node};
        my $dependsref = $innerhashref->{$DEPENDSONKEY};
        my @depends = @$dependsref;

        foreach my $compName (@depends) {
            if ($compName) {
                unless ($visitedSetRef->{$compName}) {
                    $visitedSetRef->{$compName} = $compName;
                    my $nextpath = $path . ":" . $compName;

                    $self->_performFullMetaValidationDFS($nextpath, $compName, $visitedSetRef);
                }
            }
        }

        my $compMeta = $self->_getCompMeta($node);

        $self->_validateMeta($compMeta, $path)
    }

    # Input 1: The root component name that is to be checked if it refers directly or indirectly to a component marked as bootstrap
    # Return 0 if it does not; 1 if it contains only non-transitive (standalone) bootstrap comps; 2 if it contains > 1 transitive bootstrap comps
    sub _containsBootstrapComponent {
        my ($self, $node, $visitedSetRef) = @_;

        my $cm = $self->_getCompMeta($node);

        if ($cm->isStandaloneBootstrap()) {
            return 1;
        }
        elsif ($cm->isTransitiveBootstrap()) {
            return 2;
        }

        my $depsmapref = $self->{$DEPSMAP};
        my %depsmap = %$depsmapref;
        my $innerhashref = $depsmap{$node};
        my $dependsref = $innerhashref->{$DEPENDSONKEY};
        my @depends = @$dependsref;

        my $cbs = 0;
        foreach my $compName (@depends) {
            unless ($visitedSetRef->{$compName}) {
                $visitedSetRef->{$compName} = $compName;
                my $containsBootstrap = $self->_containsBootstrapComponent($compName, $visitedSetRef);
                if ($containsBootstrap == 1) {
                    if ($cbs == 0) {
                        $cbs = 1;
                        # Keep iterating looking if there are any transitively marked bootstrap comps
                    }
                }
                elsif ($containsBootstrap == 2) {
                    return $containsBootstrap;
                }
            }
        }
        return $cbs;
    }

    sub _getSmallestBuildOrderUnderRoot {
        my ($self, $node, $visitedSetRef, $currentSmallest) = @_;

        my $cm = $self->_getCompMeta($node);

        if ($cm->getBuildOrder() < $currentSmallest) {
            $currentSmallest = $cm->getBuildOrder();
        }

        my $depsmapref = $self->{$DEPSMAP};
        my %depsmap = %$depsmapref;
        my $innerhashref = $depsmap{$node};
        my $dependsref = $innerhashref->{$DEPENDSONKEY};
        my @depends = @$dependsref;

        my $cbs = 0;
        foreach my $compName (@depends) {
            unless ($visitedSetRef->{$compName}) {
                $visitedSetRef->{$compName} = $compName;
                my $smallval = $self->_getSmallestBuildOrderUnderRoot($compName, $visitedSetRef, $currentSmallest);
                if ($smallval < $currentSmallest) {
                    $currentSmallest = $smallval;
                }
            }
        }
        return $currentSmallest;
    }

    # Returns a string representing the expected results that would occur if the components
    # in the current delta would be rebuilt.
    #
    # This is otherwise known as the "Expected Results Tool"
    # Used to perform "what if" dry runs (no building) of what would happen if an incremental build were run
    #
    # Input 1: non-zero to treat all comps in the delta as being binary incompatible
    # Return an IncrBuildMgrResults object that shows what components would be rebuilt (from the current delta)
    sub getExpectedResults {
        my ($self, $treatAsIncompatible) = @_;

        my %expectedSet = ();

        $self->_reportDependencyDAGAux(0, \%expectedSet);

        my %deltaSet = (); # <component name, component name>
        my %filemergeSet = (); # <component name, component name>
        $self->_updateRebuildSet(\%deltaSet, \%filemergeSet);

        # TODO update an actual IncrBuildMgrResults object
        my $er = ariba::rc::IncrBuildMgrResults->new();

        my @era = keys (%expectedSet);
        for my $k (@era) {
            if (exists $deltaSet{$k}) {
                my $cm = $self->_getCompMeta($k);
                if ($cm->isBootstrap()) {
                    $er->addCompToRebuildSetAsBootstrap($k);
                }
                else {
                    $er->addCompToRebuildSetAsIncompatible($k);
                }
            }
            else {
                if ($treatAsIncompatible) {
                    $er->addCompToRebuildSetAsTransitive($k);
                }
            }
        }

        for my $k (keys %filemergeSet) {
            $er->addCompToRebuildSetAsFilemerge($k);
        }

        return $er;
    }

    # Returns a string representing the product universe depedency DAG
    # as a hierarchical "-"  separated ascii art form of component names
    sub reportDependencyDAG {
        my ($self) = @_;
        $self->_reportDependencyDAGAux(1);
    }

    # Returns a string representing the product universe depedency DAG
    # as a hierarchical "-"  separated ascii art form of component names
    # Input 1: Pass 1 to print the info as it is discovered
    # Input 2: Reference to a set where expected results will be stored (comp names)
    sub _reportDependencyDAGAux {
        my ($self, $print, $expectedSetRef) = @_;

        my $rootsRef = $self->_getListOfRoots();

        my %visitedSet = ();
        my $visitedSetRef = \%visitedSet;

        my @deltaCompsMeta = @{$self->{$DELTA_COMPS_META}};
        foreach my $compMeta (@deltaCompsMeta) {
            my $delta = $compMeta->getName();
            if (defined $expectedSetRef) {
                $expectedSetRef->{$delta} = $delta;
            }
        }

        foreach my $cm (@$rootsRef) {
            my $root = $cm->getName();
            if (defined $root) {
                my $e = $self->_reportDependencyDAG($root, 0, $visitedSetRef, $expectedSetRef, $print);
                if ($e) {
                    if (defined $expectedSetRef) {
                        $expectedSetRef->{$root} = $root;
                    }
                }
            }
        }
    }

    # Internal routine shared for two different caller uses cases:
    # 1. repoortDependencyDAG (to print dependency graph as ascii art form)
    # 2. used by getExpectedResults to perform a "what if" rebuild
    sub _reportDependencyDAG {
        my ($self, $node, $level, $visitedSetRef, $expectedSetRef, $print) = @_;

        my $depsmapref = $self->{$DEPSMAP};
        my %depsmap = %$depsmapref;
        my $innerhashref = $depsmap{$node};
        my $dependsref = $innerhashref->{$DEPENDSONKEY};
        my @depends = @$dependsref;

        my $str = "";

        for my $l (1 .. $level) {
            $str = $str . "-";
        }

        $str = $str . $node . "\n";

        if ($print) {
            print $str;
        }

        my $e2 = 0;
        foreach my $compName (@depends) {
            unless ($visitedSetRef->{$compName}) {
                $visitedSetRef->{$compName} = $compName;
                my $e = $self->_reportDependencyDAG($compName, $level + 1, $visitedSetRef, $expectedSetRef, $print);
                if ($e) {
                    $expectedSetRef->{$node} = $node;
                    $e2 = 1;
                }
            }
            else {
                $str = "";
                for my $l (1 .. $level + 1) {
                    $str = $str . "-";
                }
                $str = $str . $compName . "*\n";
                if ($print) {
                    print $str;
                }

                my $v = $expectedSetRef->{$compName};
                if (defined $v) {
                    $expectedSetRef->{$node} = $node;
                    $e2 = 1;
                }
            }
        }

        if ($e2 || exists $expectedSetRef->{$node}) {
            return 1;
        }
        return 0;
    }

    # Searches the CompMeta srcPath for component time install.csv, across entire product universe,
    # and generates an index by default under ARIBA_INSTALL_ROOT/internal/build/index/filemergeindex.txt
    # that is consulted to discover which components have to be rebuilt (in addition to those from the delta set)
    # so the filemerge will happen correctly.
    sub generateFullFilemergeIndex {
        my ($self) = @_;

        my $indexer = ariba::rc::MergeFileIndexer->new($self->{$INDEX_DIR} . "/filemergeindex.txt");
        if (defined $indexer) {
            my @productUniverse = $self->_getProductUniverseComps();
            $indexer->genIndexFileFromSearch(\@productUniverse, 1);
        }
        else {
            die _incrDie("The MergeFileIndexer is not defined!\n");
        }
    }

    #
    # Internal methods below here ###############################################
    #

    # The set of components that, at a minimum, must be rebuilt includes the delta set and the filemerge set
    # Input 1 : reference to delta rebuilt set to update
    # Input 2 : reference to filemerge rebuilt set to update
    sub _updateRebuildSet {
        my ($self, $deltaSetRef, $filemergeSetRef) = @_;

        my @deltaCompsMeta = @{$self->{$DELTA_COMPS_META}};
        foreach my $compMeta (@deltaCompsMeta) {
            my $deltaComponent = $compMeta->getName();
            if (exists $self->{$DEPSMAP}->{$deltaComponent}) {
                $deltaSetRef->{$deltaComponent} = $deltaComponent;
            }
            else {
                $self->_warn("Component information for $deltaComponent in the delta set does not exist");
            }
        }

        my $mergeListRef = $self->{$FILEMERGE_COMPS_LIST};
        if (defined $mergeListRef) {
            my @mergeList = @$mergeListRef;
            for my $c (@mergeList) {
                if (exists $self->{$DEPSMAP}->{$c}) {
                    $filemergeSetRef->{$c} = $c;
                }
                else {
                    $self->_warn("Component information for $c in the filemerge set does not exist");
                }
            }
        }
        else {
            $self->_debug("There is no list of filemerge components available");
        }
    }

    # Return: Reference to array of CompMeta representing the components that no other comp in the universe depends on
    # Side-effect is to store the results in an instance member
    sub _getListOfRoots {
        my ($self) = @_;

        if (defined $self->{$LIST_OF_ROOTS}) {
            return $self->{$LIST_OF_ROOTS};
        }

        my $depsmapref = $self->{$DEPSMAP};
        my %depsmap = %$depsmapref;

        my @roots = ();
        foreach my $c (keys %depsmap) {
            my $innerhashref = $depsmap{$c};
            my $usedbyref = $innerhashref->{$USEDBYKEY};
            my @usedby = @$usedbyref;
            my $usedbysize = @usedby;
            if ($usedbysize == 0) {
                my $compMeta = $self->_getCompMeta($c);
                push (@roots, $compMeta);
            }
        }

        my %visitedSet = ();
        my $visitedSetRef = \%visitedSet;

        foreach my $cm (@roots) {
            my $root = $cm->getName();
            if (defined $root) {
                my $buildOrder = $cm->getBuildOrder();

                if ($self->{$FULL_BUILD}) {
                    my $newBuildOrder = $self->_getSmallestBuildOrderUnderRoot($root, $visitedSetRef, $buildOrder);
                    if ($newBuildOrder < $buildOrder) {
                        $self->_debug("Determined that the root component \"$root\" depends on a component with lower buildOrder so bumping it's build order from $buildOrder to $newBuildOrder");
                        $cm->setBuildOrder($newBuildOrder);
                    }
                }
                else {
                    my $bs = $self->_containsBootstrapComponent($root, $visitedSetRef);
                    if ($bs) {
                        my $newBuildOrder = -10000 + $buildOrder;
                        # Preserve the relative build ordering, but place the bootstrap graphs first in the list of roots
                        $self->_debug("Determined that the root component \"$root\" depends on a bootstrap component so bumping it's build order from $buildOrder to $newBuildOrder");
                        $cm->setBuildOrder($newBuildOrder);
                        if ($bs == 2) {
                            $self->_addTransitiveBootstrapRoot($cm);
                        }
                    }
                }
            }
        }

        my @sorted = sort { $a->getBuildOrder() <=> $b->getBuildOrder() } @roots;

        if ($self->{$DEBUG}) {
            $self->_debug("The root components will have their graphs built in this order");
            for my $r (@sorted) {
                my $rn = $r->getName();
                print "  $rn  ";
            }
            print "\n";
        }

        $self->{$LIST_OF_ROOTS} = \@sorted;

        return \@sorted;
    } # _getListOfRoots

    # Add the supplied CompMeta reference to a set of roots that must be rebuilt (because they contain transitive bootstrap comps)
    sub _addTransitiveBootstrapRoot {
        my ($self, $rootCompMeta) = @_;

        my $bootstrapRootSetRef = $self->{$BOOTSTRAP_ROOTS};
        $bootstrapRootSetRef->{$rootCompMeta} = $rootCompMeta;
    }

    # Return 1 if thie supplied compMeta is a root marked as containing a transitive bootstrap comp; 0 otherwise
    sub _isTransitiveBootstrapRoot {
        my ($self, $rootCompMeta) = @_;

        my $bootstrapRootSetRef = $self->{$BOOTSTRAP_ROOTS};
        my $r = $bootstrapRootSetRef->{$rootCompMeta};
        if (defined $r) {
            return 1;
        }
        return 0;
    }

    # This is a depth first search starting at $node where we update the sortedRebuildListRef
    # if the node is in the deltaSetRef. The updated visitedSetRef is used to keep from
    # recursing down into already visited sub trees.
    #
    # Input 1: node: name of component we are visiting (initially it should be a root)
    # Input 2: path: string colon delimited comp names from root down to this node so we can print this contextual info
    # Input 3: deltaSetRef: reference to a set of component names we must rebuild (the delta set)
    # Input 4: filemergeSetRef: reference to a set of component names we must rebuild (the filemerge set)
    # Input 5: rebuildHashRef: reference to hash of component name keys to change codes (across all the roots)
    #   (TODO use constants: 0==compat,1==direct incompat,2==transitive incompat,4=transitive delete; 16 == add/is change)
    # Input 6: thisRootsRebuildHashRef: reference to hash of component name keys to change codes (over this root only)
    # Input 7: visitedSetRef: reference to set of component names that we've ever visited (a traversal optimization)
    # Input 8: set to 1 if every component in this root's graph must be rebuilt (contains a bootstrap component); 0 otherwise
    #
    # Return: 1 if this subtree had a incompatible build (transitive builds are then neccessary); else 0
    sub _dfs {
        my ($self, $path, $node, $deltaSetRef, $filemergeSetRef, $rebuildHashRef, $thisRootsRebuildHashRef, $visitedSetRef, $abootstrap) = @_;

        my $depsmapref = $self->{$DEPSMAP};
        my %depsmap = %$depsmapref;
        my $innerhashref = $depsmap{$node};
        my $dependsref = $innerhashref->{$DEPENDSONKEY};
        my @depends = @$dependsref;

        my $incompatible = 0;
        foreach my $compName (@depends) {
            if ($compName) {
                if (exists $rebuildHashRef->{$compName}) {
                    my $v = $rebuildHashRef->{$compName};
                    if ($v != 16) {
                        # TODO: Use constants not magic numbers: Also maintain a mapping of change codes to what is considered 'incompatible' (requires transitive rebuilds)
                        $incompatible = $v;
                    }
                }
                unless ($visitedSetRef->{$compName}) {
                    $visitedSetRef->{$compName} = $compName;
                    my $nextpath = $path . ":" . $compName;
                    $self->_debug("Drilling build dfs down into \"$nextpath\"");
                    my $incompatibleChildren =
                        $self->_dfs($nextpath, $compName, $deltaSetRef, $filemergeSetRef, $rebuildHashRef, $thisRootsRebuildHashRef, $visitedSetRef, $abootstrap);

                    if ($incompatibleChildren) {
                        $incompatible = 1;
                    }
                }
            }
        }

        my $adelta = exists $deltaSetRef->{$node};
        my $afilemerge = exists $filemergeSetRef->{$node};

        my $conflictingAddVisChange = 0;

        my $compMeta = $self->_getCompMeta($node);

        unless ($self->{$FULL_BUILD}) {
            $conflictingAddVisChange = $self->_shouldBuildBecauseOfAddVisChange($node);
        }

        if ((exists $thisRootsRebuildHashRef->{$node} && $compMeta->isMarkedToAlwaysBuild()) || $conflictingAddVisChange || $abootstrap || $incompatible || $adelta || $afilemerge || $self->{$FULL_BUILD}) {

            if ($self->{$FULL_BUILD}) {
                $self->_banner("Starting rebuild of \"$path\" because this is a full build");
            }
            elsif ($compMeta->isMarkedToAlwaysBuild()) {
                $self->_banner("Starting rebuild of \"$path\" because it is marked to always be built if any child was built");
            }
            elsif ($conflictingAddVisChange) {
                $self->_banner("Starting rebuild of \"$path\" because it may define a method that conflicts with an added or visibility changed method in the delta set");
            }
            elsif ($abootstrap) {
                $self->_banner("Starting rebuild of \"$path\" because it's in a bootstrap graph");
            }
            elsif ($incompatible) {
                $self->_banner("Starting rebuild of \"$path\" because of transitive incompatibility");
            }
            elsif ($adelta) {
                $self->_banner("Starting rebuild of \"$path\" because it is a delta");
            }
            elsif ($afilemerge) {
                $self->_banner("Starting rebuild of \"$path\" because it is in the filemerge network");
            }

            $self->_rebuildCallback($node, $adelta);

            if ($afilemerge) {
                if (exists $filemergeSetRef->{$node}) {
                    delete($filemergeSetRef->{$node});
                }
            }

            my $changeCode = 0;
            if ($adelta) {
                if (exists $deltaSetRef->{$node}) {
                    delete($deltaSetRef->{$node});
                }

                if (defined $self->{$REPORT_REBUILD_LIST_ONLY}) {
                    if ($self->{$REPORT_REBUILD_LIST_ONLY}) {
                        $changeCode = 1; # Treat the delta as incompatible (a what-if testing scenario)
                    }
                }
                else {
                    unless ($self->{$FULL_BUILD}) {
                        $self->_debug("About to perform binary compatibility check for $path", 1);
                        $changeCode = $self->_characterizeDelta($compMeta);
                        $self->_debug("Done performing binary compatibility check for $path", 1);
                    }
                }
            }
            else {
                $self->_debug("Skipping binary compatibility check for $path because it is not a delta");
            }

            if ($incompatible) {
                # We are in a transitive rebuild chain - there was a previously detected binary incompatibility
                # Put the node in the transitive rebuild bucket
                $changeCode = 2 | $changeCode;
            }

            $rebuildHashRef->{$node} = $changeCode;
            $thisRootsRebuildHashRef->{$node} = $changeCode;

            if ($afilemerge) {
                $self->{$RESULTS}->addCompToRebuildSetAsFilemerge($node);
            }
            elsif ($abootstrap) {
                $self->{$RESULTS}->addCompToRebuildSetAsBootstrap($node);
            }
            elsif ($changeCode & 1) {
                $self->{$RESULTS}->addCompToRebuildSetAsIncompatible($node);
                $incompatible = 1;
            }
            elsif ($changeCode & 2) {
                $self->{$RESULTS}->addCompToRebuildSetAsTransitive($node);
                $incompatible = 1;
            }
            elsif ($changeCode & 4) {
                $self->{$RESULTS}->addCompToRebuildSetAsTransitive($node);
                $incompatible = 1;
            }
            elsif (($changeCode & 16) || $conflictingAddVisChange) {
                $self->{$RESULTS}->addCompToRebuildSetAsAddVisChange($node);
            }
            else {
                # The following reasons will result in component put in the compat bucket:
                # full-build
                # transitive bootstrap comps
                # marked to always build
                $self->{$RESULTS}->addCompToRebuildSetAsCompatible($node);
            }

            $self->_info("Finished rebuild of \"$path\"\n", 1);
            return $incompatible;
        }
        return $incompatible; # assert $incompatible == 0
    } # _dfs

    # Load the productUniverseMap (key is comp name value is CompMeta)
    # The $self->{$PRODUCT_UNIVERSE_MAP} is referenced by key:component name to acquire its CompMeta
    # The internal data structure (depsmap) and dfs traversal is relative to comp names.
    #
    # Input 1: reference to array of CompMeta objects that describe the product universe
    sub _loadProductUniverseMap {
        my ($self, $productUniverseRef) = @_;

        my $numcomps = 0;
        foreach my $compMeta (@$productUniverseRef) {
            $compMeta->setBuildOrder($numcomps); # The order the roots are built comes from this
            $numcomps++;
            $self->{$PRODUCT_UNIVERSE_MAP}->{$compMeta->getName()} = $compMeta;
        }
        $self->_debug("There are " . $numcomps . " components in the product universe");
    }

    # Interal convenience API
    # return a list of CompMeta objects in the product universe
    sub _getProductUniverseComps {
        my ($self) = @_;
        return (values %{$self->{$PRODUCT_UNIVERSE_MAP}});
    }

    # Interal convenience API
    # Input component name
    # return a CompMeta associated with a component name
    sub _getCompMeta {
        my ($self, $compName) = @_;
        my $cm = $self->{$PRODUCT_UNIVERSE_MAP}->{$compName};
        if (! defined $cm) {
            $self->_warn("Cannot locate a CompMeta for component \"$compName\"");
        }
        return $cm;
    }

    #
    # Internal convenience API to return array of component names in the product universe
    # returns:
    #    list of component names that form the universe of components for this product
    sub _getProductUniverseNames {
        my ($self) = @_;
        return (keys %{$self->{$PRODUCT_UNIVERSE_MAP}});
    }

    # Load the deltaCompsMeta member
    # Input: reference to array of CompMeta (delta change)
    sub loadDelta {
        my ($self, $deltaCompMetaRef) = @_;

        unless ($self->{$FULL_BUILD}) {
            if ($deltaCompMetaRef) {
                $self->_info("The passed in delta contains:");
                my @ds = @{$deltaCompMetaRef};
                for my $d (@ds) {
                    my $s = $d->getName();
                    print "\t\"$s\" ";
                }
                print "\n";
            }

            push (@{$self->{$DELTA_COMPS_META}}, @{$deltaCompMetaRef});

            # Here we add the components marked as deleted into the product universe so
            # that we can check that no other components still delare that thy depend on the deleted comp.
            foreach my $compMeta (@$deltaCompMetaRef) {
                if ($compMeta->isDeleted()) {
                    $self->{$PRODUCT_UNIVERSE_MAP}->{$compMeta->getName()} = $compMeta;
                }
            }

            $self->_loadFilemergeList($deltaCompMetaRef);
            $self->_backupDeltaArtifactsForBinCompatCheck();
        }
    }

    # Load the members
    #    $self->{$FILEMERGE_COMPS_LIST}
    #    $self->{$FILEMERGE_FILE_LIST}
    #
    # Input: reference to array of CompMeta (delta change)
    sub _loadFilemergeList {
        my ($self, $deltaCompMetaRef) = @_;

        return unless ($deltaCompMetaRef);

        $self->_info("Loading the relevant members from the filemerge set into the delta set");
        my @deltaCompNames = ();
        foreach my $compMeta (@$deltaCompMetaRef) {
            if (! $compMeta->isDeleted()) {
                push (@deltaCompNames, $compMeta->getName());
            }
        }

        # It's quick enough that we can regenerate this index each time we do an incremental build...
        $self->generateFullFilemergeIndex($deltaCompMetaRef);

        my $fmi = ariba::rc::MergeFileIndexer->new($self->{$INDEX_DIR} . "/filemergeindex.txt");
        $self->{$FILEMERGE_COMPS_LIST} = $fmi->getComponentsToMergeWithBatch(\@deltaCompNames);
        $self->{$FILEMERGE_FILE_LIST} = $fmi->getFilesToMergeWithBatch(\@deltaCompNames);

        $self->_removeFilemergeFiles();
    }

    sub _removeFilemergeFiles {
        my ($self) = @_;

        if (defined $self->{$FILEMERGE_FILE_LIST}) {
            for my $f (@{$self->{$FILEMERGE_FILE_LIST}}) {
                my $absf = $ARIBA_INSTALL_ROOT . "/$f";
                move($absf, "$absf-removeForIncrBuild") or die _incrDie("IncrBuildMgr: ERROR failed to remove(hide) the filemerge destination file \"$absf\".\n");
            }
        }
    }

    # Delete the content of ARIBA_{INSTALL,BUILD}_ROOT when in full build mode
    sub _prepareBaseImageForFullBuild {
        my ($self) = @_;
        if ($self->{$FULL_BUILD}) {
            # The ARIBA_BUILD_ROOT and ARIBA_INSTALL_ROOT must be empty in the full build case
            if (-d $ARIBA_BUILD_ROOT) {
                $self->_debug("Cleaning ARIBA_BUILD_ROOT because this is a full build");
                if (-d "$ARIBA_BUILD_ROOT/make") {
                    my $ret = system("chmod -R +w $ARIBA_BUILD_ROOT/make");
                    if ($ret != 0) {
                        $ret = $ret >> 8;
                        die _incrDie("Could not chmod -R +w $ARIBA_BUILD_ROOT/make\n");
                    }
                }
                # Do not delete content of config file as these are generated during pre-build phase of make-build2 driver
                my $cmd = "find $ARIBA_BUILD_ROOT/\* ! -name config -type d -prune -exec rm -rf {} \\;";
                my $ret = system("$cmd");
                if ($ret != 0) {
                    $ret = $ret >> 8;
                    die _incrDie("Could not delete the contents of $ARIBA_BUILD_ROOT\n");
                }
            }

            if (-d $ARIBA_INSTALL_ROOT) {
                $self->_debug("Cleaning ARIBA_INSTALL_ROOT because this is a full build\n");
                my $ret = system("rm -rf $ARIBA_INSTALL_ROOT/*");
                if ($ret != 0) {
                    $ret = $ret >> 8;
                    die _incrDie("Could not delete the contents of $ARIBA_INSTALL_ROOT\n");
                }
            }
        }
    }

    # Return 1 if the system went from pure into full build mode because the critical BUILD_ROOT_BACKUP_FILE did not exist; 0 otherwise
    sub _prepareBaseImageForPureIncrBuild {
        my ($self) = @_;
        unless ($self->{$FULL_BUILD}) {
            # We must restore the ARIBA_INSTALL_ROOT from the base image
            # However, if there is no backup tar file, then it makes no sense to be in pure incremental mode, so we go into buildAll mode and ensure it's clean
            my $extracted = $self->_installPriorBuildImage();
            if (! $extracted) {
                $self->_warn("Automatically going into -buildAll mode because the base build does not contain $BUILD_ROOT_BACKUP_FILE");
                $self->setFullBuild(1);
                return 1;
            }
        }
        return 0;
    }

    # Return 1 if the restored image contained the backup tar file and it was extracted; 0 otherwise
    sub _installPriorBuildImage {
        my ($self) = @_;

        my $cb = $self->{$PRIOR_BUILD_INSTALLER};
        if ($cb) {
            return &$cb($self->{$BASE_LABEL});
        }
        else {
            # TODO: Support AN in P5::installImage
            if (lc($self->{$PRODUCT_ID}) eq 'an') {
                my $cmd = "unzip -qq -o -d $ARIBA_INSTALL_ROOT $self->{$BACKDROP}/rc.zip";
                $self->_debug("Installing prior build using command \"$cmd\"");
                my $ret = system($cmd);
                if ($ret != 0) {
                    $ret = $ret >> 8;
                    $self->_warn("Installing Prior Build Image using \"$cmd\" failed $ret.");
                    return 0;
                }

                $cmd = "chmod -R +x $ARIBA_INSTALL_ROOT/bin $ARIBA_INSTALL_ROOT/internal/bin";
                $ret = system($cmd);
                if ($ret != 0) {
                    $ret = $ret >> 8;
                    die _incrDie("Command failed to change permissions \"$cmd\" failed.\n", $ret);
                }
            }
            else {
                # It is unclear when the USE_BACKDROP is undefined.
                # May be we should remove it and make it the default.
                if ($self->{$USE_BACKDROP}) {
                    my $ret = Ariba::P5::installimage("-backdrop", $self->{$BACKDROP}, "-i"); # backdrop is the complete image/ folder
                    if ($ret != 0) {
                        $ret = $ret >> 8;
                        $self->_warn("Installing Prior Build Image ".$self->{$BASE_LABEL}." failed $ret.");
                        return 0;
                    }
                    # Capture the backdrop in a file so post-builder can diff the backdrop build image against the latest build image
                    open (my $fh, ">", $BACKDROP_FILE) or die "Cannot open $BACKDROP_FILE: $!" ;
                    my $bd = abs_path($self->{$BACKDROP});
                    print $fh $bd;
                    close ($fh) or die "Cannot close $BACKDROP_FILE : $!" ;
                } else {
                    # TODO: Delete this block and always have USE_BACKDROP defined for incr builds
                    my $ret = Ariba::P5::installimage("-product", $self->{$PRODUCT_ID},
                                               "-buildname", $self->{$BASE_LABEL},
                                               "-jre",
                                               "-cygwin",
                                               "-perl");
                    if ($ret != 0) {
                        $ret = $ret >> 8;
                        $self->_warn("Installing Prior Build Image ".$self->{$BASE_LABEL}." failed $ret.");
                        return 0;
                    }
                }
            }
        }

        return $self->_restoreBuildRoot();
    }

    sub _saveBuildRoot {
        my ($self) = @_;

        # Unknown tool is clobbering the make directory (and others too, but the code generated .make files seem to always be involved)
        # We are marking as not writable in hopes a build failure will happen to whataver place is trying to write here
        # so we can fix that tool (a race condition?)
        my $cmd = "chmod -R 555 $ARIBA_BUILD_ROOT/make";
        my $ret = system($cmd);
        if ($ret != 0) {
            die _incrDie("changing permission (to 555) of the ARIBA_BUULD_ROOT/make directory failed. The cmd=\"$cmd\".\n", $ret);
        }
        $cmd = "tar cf $BUILD_ROOT_BACKUP_FILE -C $ARIBA_BUILD_ROOT --exclude classes --exclude install --exclude ishield --exclude config/* --exclude ianywhere/resource/installer_vms --exclude 'make/*/bom*.txt' .";
        $self->_debug("Executing the command to create a tar file of ARIBA_BUILD_ROOT. The command=\"$cmd\".");
        my $ret = system($cmd);
        if ($ret != 0) {
            die _incrDie("Saving ARIBA_BUILD_ROOT Image failed. The cmd=\"$cmd\".\n", $ret);
        }
    }

    # Return 1 if the base build root backup file was extracted; 0 if it was not.
    sub _restoreBuildRoot {
        my ($self) = @_;

        my $extracted = 0;
        my $cmd = "tar xf $BUILD_ROOT_BACKUP_FILE -C $ARIBA_BUILD_ROOT";
        eval {
            if (-e $BUILD_ROOT_BACKUP_FILE) {
                my $ret = system($cmd);
                if ($ret != 0) {
                    $self->_warn("Cannot restore ARIBA_BUILD_ROOT. The command=\"$cmd\".");
                }
                else {
                    $extracted = 1;
                }
                $cmd = "chmod -R 777 $ARIBA_BUILD_ROOT/make";
                $ret = system($cmd);
                if ($ret != 0) {
                    die _incrDie("changing permission (to 777) of the ARIBA_BUULD_ROOT/make directory failed. The cmd=\"$cmd\".\n", $ret);
                }
            }
            else {
                $self->_warn("Cannot restore ARIBA_BUILD_ROOT. The file \"$BUILD_ROOT_BACKUP_FILE\" does not exist.");
            }
        };
        if ($@) {
            $self->_warn("Cannot restore ARIBA_BUILD_ROOT. The command=\"$cmd\".");
        }
        return $extracted;
    }

    #
    # Internal API to backup the published artifacts for subsequent binary compatibility checking
    sub _backupDeltaArtifactsForBinCompatCheck {
        my ($self) = @_;
        unless ($self->{$FULL_BUILD}) {
            my @compMetas = @{$self->{$DELTA_COMPS_META}};
            foreach my $compMeta (@compMetas) {
                if (! $compMeta->isNew) {
                    my $artifactPathsRef = $compMeta->getPublishedArtifactPaths();
                    my @artifactPaths = @$artifactPathsRef;
                    foreach my $artifactPath (@artifactPaths) {
                        $self->_backupDeltaArtifactForBinCompatCheck($artifactPath);
                    }
                }
            }
        }
    }

    # Returns: path to directory root for backed-up artifacts
    sub _getBackupDir {
        my ($self) = @_;

        return "/tmp/incrBuildMgr/backup/$self->{$BUILD_ID}";
    }

    # Input 1: full path to component artifact
    # Returns: path to backup copy of the artifact
    sub _getBackupPathForArtifact {
        my ($self, $artifact) = @_;

        my $backup = $self->_getBackupDir();
        my $ap2 = "$backup/" . fileparse($artifact);
        return $ap2;
    }

    sub _deleteBackupDir {
        my ($self) = @_;

        my $backup = $self->_getBackupDir();
        if (-d $backup) {
            my $cmd = "rm -rf $backup";
            my $ret = system($cmd);
            if ($ret != 0) {
                $self->_warn("Could not remove backup directory post build. The command was: \"$cmd\".");
            }
        }
    }

    # Input string path to an artifact
    sub _backupDeltaArtifactForBinCompatCheck {
        my ($self, $artifact) = @_;

        my $backup = $self->_getBackupDir();
        eval {
            mkpath($backup);
        };
        if ($@) {
            die _incrDie("IncrBuildMgr: ERROR failed to create backup directory \"$backup\".\n");
        }

        copy ($artifact, $backup) or warn "IncrBuildMgr: WARNING failed to backup prior build artifact \"$artifact\" to \"$backup\". (Component Makefile may list uninstalled artifacts) \n";
    }

    # Input 1: name of directory to create where index files are stored under
    sub _createIndexDir {
        my ($self, $indexDir) = @_;

        eval {
            mkpath($indexDir);
        };
        if ($@) {
            die _incrDie("IncrBuildMgr: ERROR failed to create index directory \"$indexDir\".\n");
        }
    }

    # Input 1: name of directory to generate index files under
    sub setIndexDirectory {
        my ($self, $indexDir) = @_;
        $self->{$INDEX_DIR} = $indexDir;
    }

    # Deprecated: Use setIndexDirectory
    # Input 1: name of directory to generate pkgtocomps.txt under
    sub setPackageToCompsIndexDirectory {
        my ($self, $indexDir) = @_;
        $self->{$INDEX_DIR} = $indexDir;
    }

    # Deprecated: Use setIndexDirectory
    # Input 1: name of directory to generate the filemergeindex.txt file
    sub setFilemergeIndexDirectory {
        my ($self, $indexDir) = @_;

        $self->{$INDEX_DIR} = $indexDir;
    }

    # _updateFilemergeIndex
    #
    # TODO: pass along stats about what changed (if anything).
    # Also, refrain fromupdating blindly - only update if there is a real change)
    #
    # Incrementally update the filemergeindex.txt for a just rebuilt component.
    #
    # Input: $compMeta reference to CompMeta describing the component whose filemerged artifacts will be indexed
    sub _updateFilemergeIndex {
        my ($self, $compMeta) = @_;

        my $indexer = ariba::rc::MergeFileIndexer->new($self->{$INDEX_DIR} . "/filemergeindex.txt");
        if (defined $indexer) {
            my $installcsv = $compMeta->getSrcPath() . "/install.csv";
            $indexer->updateIndexFile($installcsv, $compMeta->getName());
        }
    }

    # Construct the data structure $self->{$DEPSMAP} that contains the
    # dependency graph that will be traversed by incrBuild()
    sub _constructDAG {
        my ($self) = @_;
        my @comps = $self->_getProductUniverseNames();

        # The a dependency map depsmap stores:
        #   key is String component name; value is hash with key=$DEPENDSONKEY or $USEDBYKEY
        #   value is an array of String component names
        foreach my $component (@comps) {
            if (!exists $self->{$DEPSMAP}->{$component}) {
                my $depsRef = $self->_getDependentComponentNames($component);
                my @deps = @$depsRef;
                my %innerhash = ();
                $self->{$DEPSMAP}->{$component} = \%innerhash;
                $innerhash{$DEPENDSONKEY} = $depsRef;
                my @usedby = ();
                $innerhash{$USEDBYKEY} = \@usedby;

                if (@deps > 0) {
                    foreach my $dep (@deps) {
                        if (defined $dep) {
                            $self->_updateUsedBy($component, $dep);
                        }
                    }
                }
            }
        }
    }

    # Return reference to a list of component names that the supplied component directly depends on
    sub _getDependentComponentNames {
        my ($self, $compName) = @_;
        my $compMeta = $self->_getCompMeta($compName);
        return $compMeta->getDependencyNames();
    }

    # A test hook
    # Input1: reference to routine that will be passed the paths of two artifacts
    #         (the first is the new one, the second is the old one
    # and it should return 0 if compatible or 1 if not
    sub setBinaryCompatibilityChecker {
        my ($self, $checker) = @_;
        $self->{$BINARY_COMPAT_CHECKER} = $checker;
    }

    # A test hook
    # Input1: reference to routine that will be passed the baseLabel to perform prior build installs
    # This routine can be leveraged by test programs to perform custom test installations
    sub setPriorBuildImageInstaller {
        my ($self, $installer) = @_;
        $self->{$PRIOR_BUILD_INSTALLER} = $installer;
    }

    # Deprecated
    # A test hook
    # Input 1: reference to routine to perform pkgtocomps invocation
    # This routine can be leveraged by test programs to perform custom test installations
    sub setPackageIndexer {
        my ($self, $cb) = @_;
        $self->{$INDEXER_CALLBACK} = $cb;
    }

    # A test hook
    # Input1: reference to routine to perform metadata validation
    # This routine can be leveraged by test programs to perform custom test installations
    sub setMetaValidator {
        my ($self, $cb) = @_;
        $self->{$VALIDATE_META_CALLBACK} = $cb;
    }

    # _characterizeDelta
    #
    # Input 1: Reference to CompMeta object that describes components, whose artifacts are to be
    #   compared with ther previous versions. A change code is returned that symbolizes
    #   the nature of the detected change.
    #
    # Return
    #   0 no change of significance (also covers: new, standalone bootstrap comps) (aka compatible change)
    #   1 significant change that requires transitive rebuilding of all comps depending on the input comp (aka incompatible change)
    #   4 A deleted component
    #   8 A transitive bootstrap comp
    #  16 A change to method visibility or method addition was detected
    sub _characterizeDelta {
        my ($self, $compMetaRef) = @_;

        my $cn = $compMetaRef->getName();

        if ($compMetaRef->isNew) {
            $self->_debug("Skipping binary compatibility check for $cn because it is marked as being a new component");
            return 0;
        }

        if ($compMetaRef->isStandaloneBootstrap()) {
            $self->_debug("Skipping binary compatibility check for $cn because it is marked as being a standalone bootstrap component");
            return 0;
        }

        if ($compMetaRef->isDeleted()) {
            return 4;
        }

        if ($compMetaRef->isTransitiveBootstrap()) {
            return 8;
        }

        $self->_info("Checking if the change to \"$cn\" is considered as incompatible by the incremental build plugin system");

        my $plugin = $self->{$REBUILD_REQUIRED_PLUGINS};
        if ($plugin && $plugin->isTransitiveRebuildRequired($compMetaRef)) {
            $self->_info("The change to \"$cn\" is considered as incompatible by the incremental build plugin system");
            return 1; # incompatible change
        }

        my $artifactPathsRef = $compMetaRef->getPublishedArtifactPaths();

        my $worstcase = 0; # To handle multi-artifact case

        my $cb = $self->{$BINARY_COMPAT_CHECKER};
        my @artifacts = @$artifactPathsRef;
        my $numartifacts = $#artifacts + 1;

        $self->_debug("About to perform binary compatibility check for $cn with $numartifacts artifacts");

        foreach my $ap (@artifacts) {
            my $ap2 = $self->_getBackupPathForArtifact($ap);

            if (! -e $ap) {
                $self->_warn("Unable to characterize Java changes the component \"$cn\" aritfact because the artifact \"$ap\" does not exist.");
                next;
            }

            if (! -e $ap2) {
                $self->_warn("Unable to characterize Java changes the component \"$cn\" aritfact because the backup artifact \"$ap2\" does not exist.");
                next;
            }

            if ($cb) {
                my $ret = &$cb($ap, $ap2);
                $self->_debug("Ran the binary compatibility checker via callback for $ap and $ap2 which returned $ret");
                if ($ret != 0) {
                    return 1; # The first artifact build that is incompatible is treated as an overall component incompatible change
                }
            }
            else {
                # Do not use runjava to launch this JVM as the generated classpath masks the old artifact jar (ClassLoader conflicts)
                my $command = "$JAVA_HOME/bin/java -classpath $ARIBA_SHARED_ROOT/java/jars/validatorAndBinChecker.jar:$ARIBA_INSTALL_ROOT/classes/bcel.jar ariba.build.tool.BinaryCompatChecker $ap2 $ap debug";
                my @bcout = qx "$command";
                my $ret = $? ;

                if ($ret > 0) {
                    # perldoc -f system (must >> 8 to get actual value)
                    $ret = $ret >> 8;
                }

                $self->_debug("Ran command to characterize Java changes: \"$command\" returned $ret (output: \"@bcout\")");

                $self->_markIfClassesAdded(\@bcout);

                if ($ret == 1) {
                    $self->_info("The change to \"$cn\" is considered as incompatible by the binary compatibility checker; transitive rebuilding will now occur ");
                    return 1; # incompatible change
                }

                if ($ret == 2) {
                    # add pub/prot method
                    $self->_updateAddVisChangeInfo($compMetaRef, \@bcout);
                    $worstcase |= 16;
                }
                elsif ($ret == 4) {
                    # increase method vis
                    $self->_updateAddVisChangeInfo($compMetaRef, \@bcout);
                    $worstcase |= 16;
                }
                elsif ($ret == 6) {
                    # add pub/prot method
                    # AND
                    # increase method vis
                    $self->_updateAddVisChangeInfo($compMetaRef, \@bcout);
                    $worstcase |= 16;
                }
            }
        }
        return $worstcase;
    } # _characterizeDelta

    # We check the output of the BinaryCompatChecker for an added class change
    # If there was such a change, the class indexes must be regenerated; we mark it so the
    # indexes can be recreated at the end of the incrBuild
    sub _markIfClassesAdded {
        my ($self, $bcarray) = @_;

        foreach my $outputLine (@{$bcarray}){
            chomp($outputLine);
            if ($outputLine !~ /BinaryCompatChecker: AddClassChange: /) {
                $self->{$CLASSES_ADDED} = 1;
                return;
            }
        }
    }

    # _validateMeta
    # Does not make sense for us to validate 3rdparty components at this time because we currently
    # expect that the Ariba consuming component that depends on third party comps manage their
    # transitive closure (we do not use a dependency manager)
    #
    # Input 1: Reference to CompMeta object that describes components, whose artifacts are to be analyzed
    # for missing dependencies.
    # Input 2: String path used to help identify where we're in the DAG
    #
    # In case of a failure:
    #   die with IncrBuildMgrException/setMetaValidationError (if $self->{$DIE_ON_VALIDATE_META_MISMATCH})
    sub _validateMeta {
        my ($self, $compMetaRef, $path) = @_;

        my $cb = $self->{$VALIDATE_META_CALLBACK};

        if ($cb) {
            return &$cb($compMetaRef);
        }

        if ($compMetaRef->getSrcPath() =~ /3rdParty/i) {
            return; # TODO: Be consistent with the return value: it seems to be not required
        }

        if (defined $path) {
            $self->_debug("Metadata validation for \"$path\"");
        }

        my $artifactPathsRef = $compMetaRef->getPublishedArtifactPaths();
        my $declaredDependencyNamesRef = $compMetaRef->getDependencyNames();
        my $component = $compMetaRef->getName();
        my %dependencies = (); # A Set (key eq value) Component names returned by DependencyEmitter
        my @missing = (); # array to store missing dependency
        my $ret;

        foreach my $ap (@$artifactPathsRef) {
            # Be careful: A component may have multiple artifacts and each artifact may have the same missing dependencies
            # We have to aggregate them into a unique set so we don't report them multiple times.
            if (! -e $ap) {
                $self->_warn("Unable to validate metadata for the component \"$component\" aritfact because the artifact \"$ap\" does not exist.");
                next;
            }

            my $command = "$JAVA_HOME/bin/java -classpath $ARIBA_SHARED_ROOT/java/jars/validatorAndBinChecker.jar:$ARIBA_INSTALL_ROOT/classes/bcel.jar ariba.build.tool.DependencyEmitter $ap external";

            if (defined $self->{$INDEX_DIR}) {
                my $indexDir = $self->{$INDEX_DIR};

                $command .= " $indexDir";
            }
            else {
                # should never get here as constructor has default definition and IncrBuildMgrTest also defines the INDEX_DIR
                $command .= " /tmp";
            }

            # running command and storing value in an array
            my @dependencyEmitterOutput = qx "$command";
            $ret = $? ;

            if ($ret > 0) {
                # perldoc -f system (must >> 8 to get actual value)
                $ret = $ret >> 8;
                die("IncrBuildMgr: ERROR : Failure running command to validate metadata:  \"$command\" output: \"@dependencyEmitterOutput\" return code: $ret\n");
            }

            $self->_debug("Successfully ran command: \"$command\" output: \"@dependencyEmitterOutput\" return code: $ret");

            foreach my $outputLine (@dependencyEmitterOutput){
                chomp($outputLine);
                if ($outputLine =~ /DependencyEmitter: ERROR/) {
                    # Should not get here because the exit code handler above should've returned
                    return;
                }
                next if ($outputLine =~ /DependencyEmitter: DEBUG/);
                next if ($outputLine =~ /^#/);

                # Sample line to parse: org.apache.oro,org.apache.log4j,ariba.util.xml,ariba.util.parameters,ariba.util.core
                if ($outputLine =~ /\,/) {
                    my @alist = split(/\,/, $outputLine);
                    for my $a (@alist) {
                        $dependencies{$a} = $a;
                    }
                }
                elsif ($outputLine ne "") {
                    $dependencies{$outputLine} = $outputLine;
                }
            }
        }

        my %declaredDependencyMap = ();
        for my $d (@$declaredDependencyNamesRef) {
            $declaredDependencyMap{$d} = $d;
        }

        my @dependencyEmitterEntry = keys (%dependencies);
        for my $d (@dependencyEmitterEntry) {
            my $v = $declaredDependencyMap{$d};
            if (defined $v) {
                # The component mentioned by DependencyEmitter is already declared in CompMeta (not missing)
            }
            else {
                # The component mentioned by DependencyEmitter either is missing or it's an ambiguous case
                if ( $d !~ /\|/g) {
                    # The component mentioned by DependencyEmitter is missing
                    push(@missing, $d);
                }
                else {
                    # The component mentioned by DependencyEmitter is an ambiguous case
                    # One of these must be declared else it is missing.
                    my @a = split(/\|/, $d);
                    my $found = 0;
                    for my $option (@a) {
                        $v = $declaredDependencyMap{$option};
                        if (defined $v) {
                            $found = 1;
                        }
                    }
                    if (! $found) {
                        # Neither of the components mentioned in the ambiguous case is declared
                        # We report this | separated ambiguity as a "missing dependency"
                        # Care must be taken by tools like the FixComponentBDF.pl to not blindly
                        # add such an ambiguity to component.bdf.
                        push(@missing, $d);
                    }
                }
            }
        }

        # Printing the missing dependencies and conditionally returning exception
        if (scalar(@missing) != 0 ) {

            $self->{$RESULTS}->addMissingDependenciesForComp($component, \@missing);

            if ($self->{$DIE_ON_VALIDATE_META_MISMATCH}) {
                my $errorMsg = "IncrBuildMgr: ERROR: Following are missing dependencies for component \"$component\": \"@missing\"\n";
                my $exception = ariba::rc::IncrBuildMgrException->new($component, $ret, $errorMsg);
                $exception->setMetaValidatorError(\@missing);
                die $exception;
            }

            $self->_warn("Following are missing dependencies for component \"$component\": \"@missing\"");

            $self->_warn("Following is more information as to why there are missing dependencies for component \"$component\"");
            foreach my $ap (@$artifactPathsRef) {
                if (! -e $ap) {
                    next;
                }

                my $command = "$JAVA_HOME/bin/java -classpath $ARIBA_SHARED_ROOT/java/jars/validatorAndBinChecker.jar:$ARIBA_INSTALL_ROOT/classes/bcel.jar ariba.build.tool.DependencyEmitter $ap external";

                if (defined $self->{$INDEX_DIR}) {
                    my $indexDir = $self->{$INDEX_DIR};

                    $command .= " $indexDir";
                }
                else {
                    # should never get here as constructor has default definition and IncrBuildMgrTest also defines the INDEX_DIR
                    $command .= " /tmp";
                }
                my @reason = qx "$command reason";
                $ret = $? ;

                if ($ret > 0) {
                    $ret = $ret >> 8;
                    die("IncrBuildMgr: ERROR : Failure running command to return reason for missing dependencies \"$command\" : return code: $ret\n");
                }
                $self->_printDependencyReason(\@reason);
            }
        }
    } # _validateMeta

    sub _printDependencyReason {
        my ($self, $reasonRef) = @_;

        my %seen = (); # key and value are the same (a set) like of the form "[com.foo.bar]"

        $self->_debug("A sample of the dependent classes and their owning component:");
        my @reason = @$reasonRef;
        for my $line (@reason) {
            # Example line:
            # "DE: [com.jclark.xsl.om.Node] => [com.jclark]"
            # Do not report more than one reason why there is a missing component dependency

            my @toks = split(/\n/, $line);

            for my $tok (@toks) {
                my @toks2 = split(/ => /, $tok);
                if ($#toks2 == 1) {
                    my $v = $seen{$toks2[1]};
                    if (!$v) {
                        print "$toks2[0] => $toks2[1]\n";
                        $seen{$toks2[1]} = $toks2[1];
                    }
                }
            }
        }
    }

    # Input 1: name of component to check if it depends on the second parameter
    # Input 2: name of component (a delta) to check if the first parameter directly depends on it
    # Return 0 means "no, the compName does not depend on changedCompName"; else return 1
    sub _directlyDependsOn {
        my ($self, $compName, $changedCompName) = @_;
        my $depsRef = $self->_getDependentComponentNames($compName);
        my @deps = @$depsRef;
        if (@deps > 0) {
            foreach my $dep (@deps) {
                if (defined $dep) {
                    if ($changedCompName eq $dep) {
                        return 1;
                    }
                }
            }
        }
        return 0;
    }

    # _shouldBuildBecauseOfAddVisChange
    #
    # Call this method as we unwind during the dfs to see if we need to build the component because of
    # add methods or increase method visibility changes to a delta component.
    #
    # Input 1: name of the component we are testing if it should be built because it may conflict with the add method|increasing visibility change
    # Return 0 if it need not be built; 1 if it must be built
    sub _shouldBuildBecauseOfAddVisChange {
        my ($self, $compName) = @_;

        my @changedCompClassNames = keys (%{$self->{$ADDVISCHANGEINFO}});
        if ($#changedCompClassNames < 0) {
            # There is no detected change to add a method or increase method visibility, so we don't have to build the component for this reason
            return 0;
        }

        for my $changedCompClassName (@changedCompClassNames) {
            my @toks = split(':', $changedCompClassName);
            my $changedCompName = $toks[0];
            my $changedClassName = $toks[1];

            if ($self->_directlyDependsOn($compName, $changedCompName)) {
                $self->_debug("Signaling that rebuilding component \"$compName\" is necessary as there is may be an impacting addvis change on its direct dependency \"$changedCompName\"");
                return 1;
            }

            # Notice: The following logic to check if rebuilding because of an addvis change considers the case of subclasses only
            # The latest logic above to test based on direct dependencies is needed for non subclass case; like calling a multi parameter method using null
            # and the new method or old method cannot be determined
            # It is likely that the above logic is sufficient, but it demands that bdf metadata be correct (no missing dependencies)
            # Because that is historically not the case, we are leaving the prior logic just in case.

            my $methodsiglistref = $self->{$ADDVISCHANGEINFO}->{$changedCompClassName};
            my @methodsigs = @$methodsiglistref;
            my %methodsigset = ();
            for my $ms (@methodsigs) {
                $methodsigset{$ms} = $ms;
            }
            if ($self->{$JAVA_CLASS_INDEXER}->doesCompDefineMethod($compName, \%methodsigset)) {
                $self->_debug("Signaling that rebuilding component \"$compName\" is necessary as there is may be an impacting addvis change on its direct dependency \"$changedCompName\"");
                return 1;
            }
        }
        return 0;
    }

    # _updateAddVisChangeInfo
    #
    # Call this method after BC checks with the BC command output as input to this method.
    # If the BC detected a delta artifact method addition or method increase of visibility,
    # this method will update the self->{$ADDVISCHANGEINFO} member with that information.
    #
    # The self->{$ADDVISCHANGEINFO} is a reference to a hash with the following key: values:
    #   key:   variable compname:classname that had an added or changed visibility method
    #   value: reference to a list of method signatures that changed; of the form: "accessname:methodname(type1,type2)"
    #
    # Input 1: Reference to CompMeta object that was just built and analyzed by BC
    # Input 2: Reference to array of String returned from BC that is to be parsed
    sub _updateAddVisChangeInfo {
        my ($self, $compMetaRef, $bcarray) = @_;

        # Example format from BinaryCompatChecker when an add method or increased method vis change is detected:
        # "BinaryCompatChecker: AddVisChange: class.name public|protected|private|package methodName(paramTypeName1,paramTypeName2)"

        my $compname = $compMetaRef->getName();

        foreach my $outputLine (@{$bcarray}){
            chomp($outputLine);
            next if ($outputLine !~ /BinaryCompatChecker: AddVisChange: /);

            my @tokens = split(/ /, $outputLine);

            my $classname = $tokens[2];
            my $access = $tokens[3];
            my $methodsig = $tokens[4];
            my $fullmethodsig = "$classname:$methodsig";

            my $compclasskey = $compname . ":" . $classname;
            my $ref = $self->{$ADDVISCHANGEINFO}->{$compclasskey};
            unless (defined $ref) {
                my @methodsigs = ();
                $ref = \@methodsigs;
                $self->{$ADDVISCHANGEINFO}->{$compclasskey} = $ref;
            }
            push (@$ref, $fullmethodsig);
        }
    } # _updateAddVisChangeInfo

    # _rebuildCallback
    #
    # This method is invoked by the DAG traversal DFS for nodes that have been qualified
    # for rebuilding. This callback will call the user defined callback
    # as was supplied by the constructor/init.
    #
    # If the component build was successful, the artifacts will be examined and the indexes will be updated.
    #
    # Next, the component's artifacts are validated against the metadata for completeness.
    # The metadata validation consults the just updated index to translate which Java packages
    # the artifact depends on to which Ariba components the artifact depends on.
    #
    # The validation will die with an IncrBuildMgrException if the CompMeta is mssing direct dependencies.
    #
    # Input 1: Component name that is to be rebuilt
    # Input 2: $adelta 0 if it's not a delta; otherwise it is
    #
    # Returns: String error message or $SUCCESS build was OK
    sub _rebuildCallback {
        my ($self, $compName, $adelta) = @_;

        if ($self->{$REPORT_REBUILD_LIST_ONLY}) {
            $self->_debug("Not rebuilding component \"$compName\" because we are in reporting mode only");
            return $SUCCESS;
        }

        $self->_debug("Start component cleaning and rebuilding for \"$compName\"", 1);

        my $compMeta = $self->_getCompMeta($compName);
        if (! $compMeta->isDeleted()) {

            $self->syncAndCleanCompAtBaseline($compMeta);

            my $cb = $self->{$COMP_BUILD_CALLBACK};
            if ($cb) {
                # TODO: handle filemerge case differently - no need to recompile (just run the filemerge as an optimization)
                # There is a command that may help: 'gnu make install-csv-files'

                $self->_debug("About to perform component rebuilding for \"$compName\"", 1);
                my $msg = &$cb($compMeta);
                $self->_debug("Done performing component rebuilding for \"$compName\"", 1);

                if ($msg eq $SUCCESS) {
                    if ($adelta) {
                        $self->_debug("About to perform filemerge index updating for \"$compName\"", 1);
                        $self->_updateFilemergeIndex($compMeta);
                        $self->_debug("Done performing filemerge index updating for \"$compName\"");
                    }

                    $self->_debug("About to perform class index updating for \"$compName\"", 1);
                    $self->{$JAVA_CLASS_INDEXER}->updateClassIndex($compMeta);
                    $self->_debug("Done performing class index updating for \"$compName\"");

                    unless ($self->{$FULL_BUILD}) {

                        $self->_debug("About to perform metadata validation for \"$compName\"", 1);
                        my $ret = $self->_validateMeta($compMeta);
                        $self->_debug("Done performing metadata validation for \"$compName\"");

                        $self->_debug("Done component cleaning and rebuilding for \"$compName\"", 1);
                        return $ret;
                    }
                }
                $self->_debug("Component cleaning and rebuilding done with message $msg for \"$compName\"", 1);
                return $msg;
            }
            else {
                $self->_debug("Not rebuilding component \"$compName\" because there is no build callback defined");
            }
        }
        else {
            $self->_debug("Not rebuilding component \"$compName\" because it is marked as deleted");
            return $SUCCESS;
        }
    }

    # In a situation like where D depends on F then we say that F is usedby D.
    # In this example the param $component would be D and $dependency would be F
    # We say the $dependency is "usedby" the $component.
    # We say the $component "dependson" the $dependency.
    #
    # In this routine, we update the "usedby" relationship in the depsmap member.
    #
    # Elsewhere we've associated that $component "dependson" $dependency.
    #
    # Update the $dependency component's usedby list in depsmap to reflect that it is usedby $component
    #
    sub _updateUsedBy {
        my ($self, $component, $dependency) = @_;

        if (!exists $self->{$DEPSMAP}->{$dependency}) {
            # Create the depsmap datastructure that models $dependency
            my $depsRef = $self->_getDependentComponentNames($dependency);
            my @deps = @$depsRef;
            my %innerhash = ();
            $self->{$DEPSMAP}->{$dependency} = \%innerhash;
            $innerhash{$DEPENDSONKEY} = $depsRef;
            my @usedby = ();
            $innerhash{$USEDBYKEY} = \@usedby;
            push(@usedby, $component);

            foreach my $dep (@deps) {
                $self->_updateUsedBy($dependency, $dep);
            }
        }
        else {
            # Update the depsmap datastructure that models $dependency
            my $innerhash = $self->{$DEPSMAP}->{$dependency};
            my $usedby = $innerhash->{$USEDBYKEY};
            push(@{$usedby}, $component);
        }
    }
}

sub _printer {
    my ($self, $level, $command, $printtime) = @_;

    my $header;
    my $trailer;
    if ($level eq "BANNER") {
        $header = "\n### IncrBuildMgr";
        $trailer = " ###\n";
    }
    else {
        $header = "IncrBuildMgr $level";
        $trailer = "\n";
    }

    if ($printtime) {
        printf("%s %s %s %s", $header, POSIX::strftime("%H:%M:%S", localtime), $command, $trailer);
    }
    else {
        printf("%s %s %s", $header, $command, $trailer);
    }
}

sub _banner {
    my ($self, $command) = @_;

    $self->_printer("BANNER", $command, 1);
}

sub _info {
    my ($self, $command, $printtime) = @_;

    $self->_printer("INFO", $command, $printtime);
}

sub _debug {
    my ($self, $command, $printtime) = @_;

    if ($self->{$DEBUG}) {
        $self->_printer("DEBUG:", $command, $printtime);
    }
}

sub _warn {
    my ($self, $command, $printtime) = @_;

    $self->_printer("WARNING", $command, $printtime);
}

# Returns an IncrBuildMgrException that can be die's with
sub _incrDie {
    my ($message, $code) = @_;

    my $ex = ariba::rc::IncrBuildMgrException->new();
    if (defined $code) {
        $ex->setErrorCode($code);
    }
    $ex->setErrorMessage($message);
    return $ex;
}

1;
