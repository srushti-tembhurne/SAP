# $Id: //ariba/services/tools/lib/perl/ariba/rc/MavenBuild.pm#30 $
package ariba::rc::MavenBuild;

use strict;
use warnings;
use File::Path;
use Ariba::P4;
use File::Basename;

sub new {
    my $class = shift;
    my $self = {};
    bless ( $self, $class );

    return $self;
}

# return 1 if success; 0 otherwise
sub _initLastChangelist {
    my ( $self ) = @_;

    my $cmd = "p4 counter change";
    my ( $out, $ret ) = _executeCommandWithOutput( $cmd );
    if ( $ret != 0 ) {
        return 0;
    }
    chomp ( $out );
    $self->{ 'LASTCHANGELIST' } = $out;

    #write out last change list to a file
    my $file = $ENV{ 'ARIBA_LATEST_CHANGE_FILE' } || "";
    if ( $file ) {
        if ( open ( CHANGE, ">$file" ) ) {
            print CHANGE "$self->{ 'LASTCHANGELIST' }\n";
            close ( CHANGE );
        } else {
            _log( "WARNING: cannot write out last change list to $file: $!" );
        }
    }

    return 1;
}

# Some maven modules require a buildroot like directory filesystem that is updated and read by multiple modules
# The current example is ariba.platform:base and executions of BaseGen. There are resources that are
# staged by base and read in by other mopdules that need to execute BaseGen.
#
# Return a name of a directory which is formed by the required MVNARGS entries:
#   ariba.archiveroot, ariba.productname
#   return undef and log an error if any of the required properties are undefined
#
sub _getBuildRootFromMvnArgs {
    my ( $self, $buildname ) = @_;

    my %archiveprops = ();
    
    # Like: '-Dariba.productname=arecibo -Dariba.branchname=arecibo -Dariba.archiveroot=/home/rc/archive/builds -U -Prc'
    my @toks = split ( / /, $self->{'MVNARGS'} );
    for my $tok (@toks) {
        my @toks2 = split( /-D/, $tok );
        if ($#toks2 == 1) {
            @toks2 = split( /=/, $toks2[1]);
            if ($#toks2 == 1) {
                $archiveprops{$toks2[0]} = $toks2[1];
            }
        }
    }
    my $archiveroot = $archiveprops{'ariba.archiveroot'};
    my $productname = $archiveprops{'ariba.productname'};

    unless ($archiveroot && $productname) {
        _logError("The ariba.archiveroot and ariba.productname both must be passed in as -D maven arguments");
        return undef;
    }

    my $buildroot = $archiveroot . "/" .  $productname . "/" . $buildname;
    return $buildroot;
}

# param - name of aribap4 goal to execute
# Returns mvn command that needs to be filled in to include specific commands for the goal
sub _getMvnCommand {
    my ( $self, $goals ) = @_;

    my $cmd = "mvn ";

    $cmd = $cmd . "-P $self->{ 'PROFILE' } ";

    if ($self->{ 'RCBUILD_LOCALREPO' }) {
        $cmd = $cmd . "-Dmaven.repo.local=$self->{ 'RCBUILD_LOCALREPO' } ";
    }

    if ( $self->{ 'MVNARGS' } ) {
        $cmd = $cmd . $self->{ 'MVNARGS' } . " ";
    }

    $cmd = $cmd . $goals . " -f $self->{ 'POMCLIENTPATH' } ";

    if ( $self->{ 'PREVIEW' } ) {
        $cmd = $cmd . "-Dpreview=$self->{ 'PREVIEW' } ";
    }

    if ( $self->{ 'P4CLIENT' } ) {
        $cmd = $cmd . "-Dp4.client=$self->{ 'P4CLIENT' } ";
    }

    if ( $self->{ 'NEXTBUILDNAME' } ) {
        $cmd = $cmd . "-Dariba.buildname=" . $self->{ 'NEXTBUILDNAME' } . " ";
    }
    
    my $buildroot = $self->_getBuildRootFromMvnArgs($self->{ 'NEXTBUILDNAME' });

    if ($buildroot) {
        $cmd = $cmd . "-Daribaconfig.installroot=$buildroot ";
    }
    # else the system will fail downstream

    # Must end with a trailing space
    return $cmd;
}

# Class method
# Useful when we need the output of the executable comamnd and the command status
# Usage:
#my $command = 'echo -n ciao ; false';
#($output, $status) = _executeCommandWithOutput($command);
sub _executeCommandWithOutput {
    my $cmd = join ' ', @_;
    _log( "Executing: " . $cmd );
    ( $_ = qx{$cmd 2>&1}, $? >> 8 );
}

# Class method
# Useful when we do need the output of the executable comamnd and need just command status (not perl normalized status)
sub _executeCommand {
    my $cmd = join ' ', @_;
    _log( "Executing: " . $cmd );
    my $ret = system ( $cmd);
    return $ret >> 8;
}

# return 1 if success; 0 otherwise
sub _initP4Client {
    my ( $self ) = @_;

    $self->{ 'P4CLIENT' } = $ENV{ 'P4CLIENT' };
    unless ( $self->{ 'P4CLIENT' } ) {
        _log( "The P4CLIENT env variable is undefined" );
        return 0;
    }
    return 1;
}

# return 1 if success; 0 otherwise
sub _syncBuildName {
    my ( $self ) = @_;

    my $ret = $self->_initBuildNamePath();
    if ( $ret == 0 ) {
        return 0;
    }

    my $cmd = "p4 sync ";

    if ($self->{ 'FORCE' } ) {
        $cmd = $cmd . "-f -q ";
    }

    $cmd = $cmd . $self->{ 'BUILDNAMEPATH' };
    $ret = _executeCommand( $cmd );
    if ( $ret != 0 ) {
        _log( "The $cmd failed with status " . $ret );
        return 0;
    }
    return 1;
}

# return 1 if success; 0 otherwise
sub _editBuildName {
    my ( $self ) = @_;

    my $cmd = "p4 edit -c " . $self->{ 'CHANGELIST' } . " $self->{ 'BUILDNAMEPATH' }";
    my $ret = _executeCommand( $cmd );
    if ( $ret != 0 ) {
        _log( "The $cmd failed with status " . $ret );
        return 0;
    }
    return 1;
}

#
#   Syncs the given pom file.  if $syncPeers is true, then it syncs the directory of the tlp.
# return 1 if success; 0 otherwise
sub _syncPom {
    my ( $self, $pom, $syncPeers ) = @_;

    my $spec = $pom;
    if ( $syncPeers ) {
        $spec =~ s/pom.xml/.../;
    }
    my $cmd = "p4 sync ";

    if ($self->{ 'FORCE' } ) {
        $cmd = $cmd . "-f -q ";
    }

    $cmd = $cmd . " $spec" . "@" . $self->{ 'LASTCHANGELIST' };

    my $ret = _executeCommand( $cmd );
    if ( $ret != 0 ) {
        _log( "The $cmd failed with status " . $ret );
        return 0;
    }
    return 1;
}

# changes directory to the pom file passed in.
# also sets the POMCLIENTPATH property to the client path of the pom.xml file.
# return 1 if success; 0 otherwise
sub _initPomClientPath {
    my ( $self, $pom ) = @_;

    my $cmd = "p4 where $pom";
    my ( $out, $ret ) = _executeCommandWithOutput( $cmd );
    if ( $ret != 0 ) {
        _log( "The $cmd failed with status " . $ret );
        return 0;
    }
    my @toks = split ( / /, $out );
    $self->{ 'POMCLIENTPATH' } = $toks[ 2 ];
    chomp ( $self->{ 'POMCLIENTPATH' } );

    _log( "The rootClientPath = " . $self->{ 'POMCLIENTPATH' } );

    my $workingdir = dirname( $self->{ 'POMCLIENTPATH' } );
    _log( "Setting working dir to " . $workingdir );
    chdir ( $workingdir );
    return 1;
}

sub _initBuildNamePath {
    my ( $self ) = @_;

    my @toks = split ( /pom.xml/, $self->{ 'POMCLIENTPATH' } );
    $self->{ 'BUILDNAMEPATH' } = $toks[ 0 ] . "BuildName";

    _log( "The BuildName path = " . $self->{ 'BUILDNAMEPATH' } );
}

sub _initLastGoodChangePath {
    my ( $self ) = @_;

    my @toks = split ( /pom.xml/, $self->{ 'POMCLIENTPATH' } );
    $self->{ 'LASTGOODCHANGEPATH' } = $toks[ 0 ] . "lastChange";

    _log( "The lastGoodChange path = " . $self->{ 'LASTGOODCHANGEPATH' } );
}

# return 1 if success; 0 otherwise
sub _sync {
    my ( $self ) = @_;

    my $cmd = $self->_getMvnCommand( "ariba.devtools:aribap4:sync" ) . " -Dp4.revspec=@" . $self->{ 'LASTCHANGELIST' } . " ";

    if ($self->{ 'FORCE' } ) {
        $cmd = $cmd . "-Dp4.force=true";
    }

    my $ret = _executeCommand( $cmd );
    if ( $ret != 0 ) {
        _log( "The $cmd failed with status " . $ret );
        return 0;
    }
    return 1;
}

# return 1 if success; 0 otherwise
sub _syncModules {
    my ( $self ) = @_;

    my $cmd = $self->_getMvnCommand( "ariba.devtools:aribap4:syncModules" ) . "-N -Dp4.revspec=@" . $self->{ 'LASTCHANGELIST' } . " ";

    if ($self->{ 'FORCE' } ) {
        $cmd = $cmd . "-Dp4.force=true";
    }

    my $ret = _executeCommand( $cmd );
    if ( $ret != 0 ) {
        _log( "The $cmd failed with status " . $ret );
        return 0;
    }
    return 1;
}

# return 1 if success; 0 otherwise
sub _initChangelist {
    my ( $self ) = @_;

    _log( "Creating changelist in client $self->{ 'P4CLIENT' }" );

    # The P4:createNewChangelist prepends a required first tab and appends a tailing newline
    my $description =
        "Summary: Changelist created by MavenBuild.pm\n"
      . "\tImpact: N/A\n"
      . "\tTesting: N/A\n"
      . "\tRequested Reviewer(s): N/A\n"
      . "\tActual Reviewer(s): N/A\n"
      . "\tDocumentation: N/A\n"
      . "\tLocalization: N/A\n"
      . "\tQA: N/A\n"
      . "\tTest Case Reviewer(s): N/A\n"
      . "\tRelease:  N/A\n"
      . "\tEnvironment or Data Migration: N/A\n"
      . "\tRolling Upgrade: N/A\n"
      . "\tDetails: See summary\n"
      . "\ttmid: N/A";

    $self->{ 'CHANGELIST' } = Ariba::P4::createNewChangelist( $description );
    unless ( $self->{ 'CHANGELIST' } ) {
        _log( "Failure creating changelist" );
        return 0;
    }
    _log( "Created changelist $self->{ 'CHANGELIST' }" );
    return 1;
}

# return 1 if success; 0 otherwise
sub _deleteChangelist {
    my ( $self ) = @_;

    unless ( $self->{ 'CHANGELIST' } ) {
        return 1;
    }

    my $cmd = "p4 revert -c $self->{ 'CHANGELIST' } //ariba/... 2>&1";
    my $ret = _executeCommand( $cmd );
    if ( $ret != 0 ) {
        _log( "The $cmd failed with status " . $ret );
        return 0;
    }

    $cmd = "p4 change -d $self->{ 'CHANGELIST' } 2>&1";
    $ret = _executeCommand( $cmd );
    if ( $ret != 0 ) {
        _log( "The $cmd failed with status " . $ret );
        return 0;
    }
    return 1;
}

# return 1 if success; 0 otherwise
sub _revertUnchanged {
    my ( $self ) = @_;

    my $cmd = "p4 revert -a -c $self->{ 'CHANGELIST' } 2>&1";
    my $ret = _executeCommand( $cmd );
    if ( $ret != 0 ) {
        _log( "The $cmd failed with status " . $ret );
        return 0;
    }
    return 1;
}

# return 1 if success; 0 otherwise
sub _commit {
    my ( $self ) = @_;

    unless ( $self->_revertUnchanged() ) {
        return 0;
    }

    my $cmd = "p4 submit -c $self->{ 'CHANGELIST' } 2>&1";
    my $ret = _executeCommand( $cmd );
    if ( $ret != 0 ) {
        _log( "The $cmd failed with status " . $ret );
        return 0;
    }
    return 1;
}

# return 1 if success; 0 otherwise
sub _incrementVersion {
    my ( $self ) = @_;

    #edit it in a separate step - this allows recursing to all the child poms.
    my $cmd = $self->_getMvnCommand( "ariba.devtools:aribap4:edit" ) . "-Dp4.changelist=$self->{ 'CHANGELIST' }";

    my $ret = _executeCommand( $cmd );
    if ( $ret != 0 ) {
        _log( "The $cmd failed with status " . $ret );
        return 0;
    }

    $cmd = $self->_getMvnCommand( "ariba.devtools:aribap4:incrementVersion org.codehaus.mojo:versions-maven-plugin:update-properties" ) . "-N -Dp4.changelist=$self->{ 'CHANGELIST' }";

    if ( $self->{ 'ALLOWSNAPSHOTS' } ) {
        $cmd = $cmd . " -DallowSnapshots=true";
    }

    $ret = _executeCommand( $cmd );
    if ( $ret != 0 ) {
        _log( "The $cmd failed with status " . $ret );
        return 0;
    }

    return 1;
}

# return 1 if success; 0 otherwise
sub _editAndExecuteMvnGoalsAux {
    my ( $self ) = @_;

    my $cmd = $self->_getMvnCommand( "ariba.devtools:aribap4:edit" ) . "-Dp4.changelist=$self->{ 'CHANGELIST' }";

    if ( $self->{ 'ALLOWSNAPSHOTS' } ) {
        $cmd = $cmd . " -DallowSnapshots=true";
    }

    my $ret = _executeCommand( $cmd );
    if ( $ret != 0 ) {
        _log( "The $cmd failed with status " . $ret );
        return 0;
    }

    if ($self->{ 'MVNGOALS' } ) {
        $cmd = $self->_getMvnCommand( $self->{ 'MVNGOALS' } );

        $ret = _executeCommand( $cmd );
        if ( $ret != 0 ) {
            _log( "The $cmd failed with status " . $ret );
            return 0;
        }
    }

    return 1;
}

# return 1 if success; 0 otherwise
sub sync {
    my ( $self ) = @_;

    my $cmd = $self->_getMvnCommand( "ariba.devtools:aribap4:sync" ) . " -Dp4.revspec=@" . $self->{ 'LASTCHANGELIST' } . " ";

    if ($self->{ 'FORCE' } ) {
        $cmd = $cmd . "-Dp4.force=true";
    }

    my $ret = _executeCommand( $cmd );
    if ( $ret != 0 ) {
        _log( "The $cmd failed with status " . $ret );
        return 0;
    }
    return 1;
}

# Read the BuildName file, increment the build number portion, format a new name ,
# store it in the file and return it
# if $commit is true, then commit it back to perforce.
# Returned status is 1 if success; 0 otherwise
sub _genNextBuildName {
    my ( $self, $commit ) = @_;

    open my $file, '<', $self->{ 'BUILDNAMEPATH' } or return 0;
    my $line = <$file>;
    chomp ( $line );
    close $file;

    my @toks = split ( /-/, $line );
    my $basebn = $toks[ 0 ];
    my $bn = $toks[ 1 ];

    $bn = $bn + 1;

    $self->{ 'NEXTBUILDNAME' } = $basebn . "-" . $bn;

    open ( FL, "> $self->{ 'BUILDNAMEPATH' }.new" ) || error( "%s: %s", $self->{ 'BUILDNAMEPATH' }, $! );
    print FL "$self->{ 'NEXTBUILDNAME' }\n";
    close ( FL );
    if ( !rename ( "$self->{ 'BUILDNAMEPATH' }.new", $self->{ 'BUILDNAMEPATH' } ) ) {
        error( "%s: %s", $self->{ 'BUILDNAMEPATH' }, $! );
        return 0;
    }

    if ( $commit ) {
        my $date = POSIX::strftime( "%Y/%m/%d", localtime );
        my $comment = "Update label for build on $date";
        my $ret = Ariba::P4::updateFiles( [ $self->{ 'BUILDNAMEPATH' } ], $comment );
        if ( !$ret ) {
            error( "%s: %s", "Cannot " . lc ( $comment ), $ret );
            return 0;
        }
    }

    return 1;
}

sub error {
    my ( $format, @args ) = @_;
    printf STDERR "ERROR: $format\n", @args;
}

# return 1 if success; 0 otherwise
sub _label {
    my ( $self ) = @_;

    my $cmd = $self->_getMvnCommand( "ariba.devtools:aribap4:label" );
    $cmd = $cmd . " -Dp4.label=" . $self->{ 'NEXTBUILDNAME' };

    if ( $self->{ 'LABELARTIFACT' } ) {
        $cmd = $cmd . " -Dp4.labelArtifact=true";
    }

    my $ret = _executeCommand( $cmd );
    if ( $ret != 0 ) {
        _log( "The $cmd failed with status " . $ret );
        return 0;
    }
    return 1;
}

# return 1 if success; 0 otherwise
sub _buildGoals {
    my ( $self ) = @_;

    my $cmd = $self->_getMvnCommand( $self->{ 'MVNGOALS' } );
    my $ret = _executeCommand( $cmd );
    if ( $ret != 0 ) {
        _log( "The $cmd failed with status " . $ret );
        return 0;
    }
    return 1;
}

sub _readTLPList {
    my ( $self ) = @_;
    my @tlpList = ();

    local $/ = undef;
    open my $file, '<', $self->{ 'POMCLIENTPATH' };

    my $string = <$file>;
    close $file;

    if ( $string ) {
        $string =~ s/\s//g;
        if ( $string =~ /(<rc.buildorder>)(.*)(<\/rc.buildorder>)/ ) {
            # Process element here
            my $csvList = $2;
            $csvList =~ s/\s//g;
            if ( $csvList ) {
                @tlpList = split ( ',', $csvList );
            }
            # add TLP if not already in the list
            if ( !grep ( /$self->{ 'POMDEPOTPATH' }/, @tlpList ) ) {
                push ( @tlpList, $self->{ 'POMDEPOTPATH' } );
            }
        } else {
            _log( "Did not find rc.buildorder property" );
            return @tlpList;
        }
    }
    return @tlpList;
}

sub _readLastGoodChange {

    my ( $self ) = @_;

    $self->_initLastGoodChangePath();
    if ( -e $self->{ 'LASTGOODCHANGEPATH' } ) {
        open my $file, '<', $self->{ 'LASTGOODCHANGEPATH' };

        my $line = <$file>;
        chomp ( $line );
        close $file;
        _log( "The last good change was $line" );
        return $line;
    }
    _log( "$self->{ 'LASTGOODCHANGEPATH' } not found, initializing to 0" );
    return 0;
}

sub _saveLastGoodChange {
    my ( $self, $lastGoodChange ) = @_;
    # bootstrap issue - new projects don't have this file, so add it and ignore the
    # warning about already added.
    my $cmd = "p4 add -c " . $self->{ 'CHANGELIST' } . " $self->{ 'LASTGOODCHANGEPATH' }";
    _executeCommand( $cmd );

    $cmd = "p4 edit -c " . $self->{ 'CHANGELIST' } . " $self->{ 'LASTGOODCHANGEPATH' }";
    my $ret = _executeCommand( $cmd );

    open UBNF, '>', $self->{ 'LASTGOODCHANGEPATH' } or return 0;
    print UBNF $lastGoodChange;
    close UBNF;

    _log( "Updated the lastChange file $self->{ 'LASTGOODCHANGEPATH' } to record the last changelist $lastGoodChange");
    return 1;
}

# gets changes between 2 revisions given last change number,
# product and maven top level pom.  The pom file is read to get the list of
# depot paths to inspect for changes.
sub _getChangesForMavenProduct {
    my ( $self, $lastChange, $mavenTLP ) = @_;

    my $pompath = $mavenTLP;
    $pompath =~ s/pom.xml/.../;
    my @monitor = ( $pompath );

    _log( "Reading paths from $mavenTLP since $lastChange" );

    push ( @monitor, $self->_readModulePathsFromPom( $lastChange, "head", $mavenTLP ) );

    my @changesFullList = getChanges( $lastChange, "head", \@monitor );

    # Eliminate changes by rc user and changes on certain files
    my @changes = @changesFullList;
    unless ( $lastChange > 0 ) {
        @changes = _eliminateChanges( @changesFullList );
    }

    my $latestChange = ( sort { $b <=> $a } ( @changes ) )[ 0 ];
    return $latestChange;
}

# parse a pom file to get <path> elements containing pom.xml paths
# return an array containsing the paths with the label
sub _readModulePathsFromPom {
    my ( $self, $fromChange, $toChange, $pom ) = @_;
    my @interestingPaths = ();
    my %output = Ariba::P4::p4s( "print -q $pom" );

    if ( $output{ error } ) {
        print ( "Problem getting $pom, ignoring this entry" );
        foreach my $line ( @{ $output{ error } } ) {
            chomp ( $line );
            print ( $line);
        }
        return ();
    }

    my $depotPath = "";
    my $range;

    if ( $fromChange == 0 ) {
        $range = "#head";
    } else {
        $range = "\@$fromChange,$toChange";
    }

    foreach my $line ( @{ $output{ text } } ) {
        if ( $line =~ /^\s*$/ ) {
            next;
        }
        $line = Ariba::Util::stripCommentAndTrim( $line );

        if ( $line =~ /<path>/ ) {
            $depotPath = $line;
            $depotPath =~ s/<path>//;
            $depotPath =~ s/<\/path>//;

            if ( $depotPath =~ /.pom.xml/ ) {
                $depotPath =~ s/pom.xml/.../;
                push ( @interestingPaths, $depotPath );
            }

        }
    }
    return @interestingPaths;
}

# Input 0: passed indirectly via object reference
# Input 1: boolean rcbuild
# Input 2: boolean force - forces the rcbuild regardless of changes since last build
# Input 3: string name of maven profile (must be in .m2/settings.xml)
# Input 4: string p4 depot path to pom to build,label,deploy
# Input 5: any value other than undef to submit changes (rc case)
# Input 6: any value other than undef to label using pom coordinates (in addition to the build label)
# Input 7: boolean indicates snapshot versions can be used when updating dependency versions.
# Input 8: maven goals  Typical values are clean install (which is used as the default if passing undef)
# Input 9: maven command line arguments.  Typical values are -X -Xe -U
# Input 10: build name to use when undef submitChanges (CI case)
# Input 11: any value other than undef to simply mimmic the execution (for testing purposes)
# Return : 1 for success; 0 otherwise
sub build {
    my ( $self, $l_rcbuild, $l_force, $l_profile, $l_pomDepotPath, $l_submitChanges, $l_labelArtifact, $l_allowSnapshots, $l_mvnGoals, $l_mvnArgs, $l_buildName, $l_preview ) = @_;

    unless ( $l_profile ) {
        _log( "The profile is missing" );
        return 0;
    }

    unless ( $l_pomDepotPath ) {
        _log( "The pomDepotPath is missing" );
        return 0;
    }

    $self->{ 'RCBUILD' } = $l_rcbuild;
    $self->{ 'FORCE' } = $l_force;
    $self->{ 'PROFILE' } = $l_profile;
    $self->{ 'POMDEPOTPATH' } = $l_pomDepotPath;
    $self->{ 'PREVIEW' } = $l_preview;
    $self->{ 'LABELARTIFACT' } = $l_labelArtifact;
    $self->{ 'SUBMITCHANGES' } = $l_submitChanges;
    $self->{ 'ALLOWSNAPSHOTS' } = $l_allowSnapshots;

    unless ( $self->{ 'SUBMITCHANGES' } || $self->{ 'RCBUILD' } ) {
        unless ( $l_buildName ) {
            _log( "The buildName is missing" );
            return 0;
        }
        $self->{ 'NEXTBUILDNAME' } = $l_buildName;
    }

    if ( $l_mvnGoals ) {
        $self->{ 'MVNGOALS' } = $l_mvnGoals;
    }
    else {
        $self->{ 'MVNGOALS' } = "clean install";
    }

    if ( $l_mvnArgs ) {
        $self->{ 'MVNARGS' } = $l_mvnArgs;
    }

    my ( $deletechangelist, $ret );

    $ENV{ 'MAVEN_OPTS' } = "-Xmx1024m -XX:MaxPermSize=128m";

    if ( $self->{ 'RCBUILD' } ) {
        _log( "Performing RC build" );
        ( $deletechangelist, $ret ) = $self->_buildRCBuild();
    }
    else {
        _log( "Performing standard build" );
        ( $deletechangelist, $ret ) = $self->_buildStandard();
    }

    if ( $ret == 0 ) {
        if ( $deletechangelist ) {
            $self->_deleteChangelist();
        }
        return 0;
    }
    return 1;
}

# This is a generic routine that will create a changelist, open all the files for edit,
# and then execute the supplied Maven goals (if any).
# A good example is passing "org.codehaus.mojo:versions-maven-plugin:update-parent clean install"
#
# The changelist is committed unless the SUBMITCHANGES is defined
# Return : 1 for success; 0 otherwise
sub editAndExecuteMvnGoals {
    my ( $self, $l_profile, $l_pomDepotPath, $l_submitChanges, $l_allowSnapshots, $l_mvnGoals, $l_mvnArgs, $l_force ) = @_;

    unless ( $l_profile ) {
        _log( "The profile is missing" );
        return 0;
    }

    unless ( $l_pomDepotPath ) {
        _log( "The pomDepotPath is missing" );
        return 0;
    }

    $self->{ 'PROFILE' } = $l_profile;
    $self->{ 'POMDEPOTPATH' } = $l_pomDepotPath;
    $self->{ 'SUBMITCHANGES' } = $l_submitChanges;
    $self->{ 'ALLOWSNAPSHOTS' } = $l_allowSnapshots;

    if ( $l_mvnArgs ) {
        $self->{ 'MVNARGS' } = $l_mvnArgs;
    }

    if ($l_mvnGoals) {
        $self->{ 'MVNGOALS' } = $l_mvnGoals;
    }

    $self->{ 'FORCE' } = $l_force;

    $ENV{ 'MAVEN_OPTS' } = "-Xmx1024m -XX:MaxPermSize=128m";

    my ( $deletechangelist, $ret ) = $self->_editAndExecuteMvnGoals();

    if ( $ret == 0 ) {
        if ( $deletechangelist ) {
            $self->_deleteChangelist();
        }
        return 0;
    }
    return 1;
}

sub _deleteLocalRepo {
    my ($localrepo) = @_;
    rmtree($localrepo) or die "Cannot rmtree '$localrepo' : $!";
    _log("Deleted Maven local repository: $localrepo");
}

#
# Return like    my ($deletechangelist, $ret) = $self->_buildRCBuild();
# deleteChangelist == 1 means that the caller must delete the changelist (status will be 0 in that case)
# status == 1 if success; 0 otherwise
#
# The RC build process is as follows:
#
# - get last changelist; this is used as the point in time "head" for subsequent p4 sync
# - sync <product>-app level pom
# - update the BuildName
# - get list of top level poms from the <product>-app level module (to check for changes and possible label incrementing).
# - if the tlp is not in the list just processed, add it to the end.
# - for each TLP
#       - check for changes since last build via the lastchange file
#       - if changes (or force).
#            - sync modules
#            - sync code
#            - create a p4 changelist
#            - check out pom files
#            - edit pom files
#            - inc version (like 1.0-SNAPSHOT -> 1.1-SNAPSHOT)
#            - run mvnGoals ('clean deploy' is typical)
#            - update and commit the lastchange file
#            - commit pom files that were changed
#            - label the artifact with Buildname and pom coordinates
#
sub _buildRCBuild {
    my ( $self ) = @_;

    # Print environment variables
    print "Build environment:\n";
    print "\n $_=" , $ENV{"$_"} foreach (sort keys %ENV);

    my $deletechangelist = 0;

    my $localrepo = $ENV{ 'HOME' } . "/.m2/repository-rcbuild-$$";
    unless(-e $localrepo or mkdir $localrepo) {
        _log("Unable to create $localrepo");
        return ( $deletechangelist, 0 );
    }
    _log("Using Maven local repository: $localrepo");
    $self->{ 'RCBUILD_LOCALREPO' } = $localrepo;

    #initialize P4 client
    my $ret = $self->_initP4Client();
    if ( $ret == 0 ) {
        _deleteLocalRepo($localrepo);
        return ( $deletechangelist, $ret );
    }

    #initializes the latest changelist in Perforce.  This is used as "head" for the build.
    $ret = $self->_initLastChangelist();
    if ( $ret == 0 ) {
        _deleteLocalRepo($localrepo);
        return ( $deletechangelist, $ret );
    }

    # sync the tlp and peer files
    $ret = $self->_syncPom( $self->{ 'POMDEPOTPATH' }, 1 );
    if ( $ret == 0 ) {
        _deleteLocalRepo($localrepo);
        return ( $deletechangelist, $ret );
    }

    # set the client directory and path. this is used to locate the lastChange and BuildName files
    $ret = $self->_initPomClientPath( $self->{ 'POMDEPOTPATH' } );
    if ( $ret == 0 ) {
        _deleteLocalRepo($localrepo);
        return ( $deletechangelist, $ret );
    }

    $ret = $self->_syncBuildName();
    if ( $ret == 0 ) {
        _deleteLocalRepo($localrepo);
        return ( $deletechangelist, $ret );
    }

    #generate a new build name and commit.
    $ret = $self->_genNextBuildName( 1 );
    if ( $ret == 0 ) {
        _deleteLocalRepo($localrepo);
        return ( $deletechangelist, $ret );
    }

    #read the tlp list
    my @tlpList = $self->_readTLPList();

    my $projectChanged = 0;

    #process each top level pom in order
    foreach my $tlp ( @tlpList ) {
        my $tlpLastChange;

        $ret = $self->_syncPom( $tlp );
        if ( $ret == 0 ) {
            _deleteLocalRepo($localrepo);
            return ( $deletechangelist, $ret );
        }
        $ret = $self->_initPomClientPath( $tlp );
        if ( $ret == 0 ) {
            _deleteLocalRepo($localrepo);
            return ( $deletechangelist, $ret );
        }

        # read the last good changelist
        my $lastGoodChange = $self->_readLastGoodChange();
        unless ( $lastGoodChange > 0 ) {
            _log( "There is no lastChange file so setting the force flag");
            # if there is no last good change, force the build vs. detecting the obvious
            $self->{ 'FORCE' } = 1;
        }

        unless ( $self->{ 'FORCE' } ) {
            $tlpLastChange = $self->_getChangesForMavenProduct( $lastGoodChange, $tlp );
        }

        my $dobuild = 0;

        if ( defined ( $tlpLastChange ) && $tlpLastChange >= $lastGoodChange) {
            _log( "Detected that change $tlpLastChange has been made since the lastChange $lastGoodChange on project $tlp, so it will be rebuilt.");
            $dobuild = 1;
        }

        if ($self->{ 'FORCE' }) {
            _log( "The force flag is set, so it will be rebuilt.");
            $dobuild = 1;
        }

        if ($projectChanged) {
            _log( "A prior dependent project of $tlp was changed, so it will be rebuilt.");
            $dobuild = 1;
        }

        if ($dobuild) {
            _log( "\n------- Performing RC build on $tlp ---------\n" );

            # sync the modules at last change list
            $ret = $self->_syncModules();
            if ( $ret == 0 ) {
                _deleteLocalRepo($localrepo);
                return ( $deletechangelist, $ret );
            }

            #sync the code
            $ret = $self->_sync();
            if ( $ret == 0 ) {
                _deleteLocalRepo($localrepo);
                return ( $deletechangelist, $ret );
            }

            #init the change list for editing
            $deletechangelist = 1;
            $ret = $self->_initChangelist();
            if ( $ret == 0 ) {
                _deleteLocalRepo($localrepo);
                return ( $deletechangelist, $ret );
            }

            # check out for edit the pom files and increment the version.
            $ret = $self->_incrementVersion();
            if ( $ret == 0 ) {
                _deleteLocalRepo($localrepo);
                return ( $deletechangelist, $ret );
            }

            #finally, build the goals
            if ( $self->{ 'MVNGOALS' } ) {
                $ret = $self->_buildGoals();
                if ( $ret == 0 ) {
                    _deleteLocalRepo($localrepo);
                    return ( $deletechangelist, $ret );
                }
            }

            #update the last good change number, since we are here!
            # and commit then label;

            $ret = $self->_saveLastGoodChange( $self->{ 'LASTCHANGELIST' } );
            if ( $ret == 0 ) {
                _deleteLocalRepo($localrepo);
                return ( $deletechangelist, $ret );
            }

            $ret = $self->_commit();
            if ( $ret == 0 ) {
                _deleteLocalRepo($localrepo);
                return ( $deletechangelist, $ret );
            }

            # Now the changelist is committed so we don't have to worry about deleteing it on failure
            $deletechangelist = 0;
            $self->{ 'LABELARTIFACT' } = 1;
            $ret = $self->_label();
            if ( $ret == 0 ) {
                _deleteLocalRepo($localrepo);
                return ( $deletechangelist, $ret );
            }

            # We must build the projects that follow this one that changed
            $projectChanged = 1;
        } else {
            _log( "Skipping build of $tlp, no changes detected and no prior dependent projects changed" );
        }
    }

    _deleteLocalRepo($localrepo);
    return ( $deletechangelist, $ret );
}

sub _editAndExecuteMvnGoals {
    my ( $self ) = @_;

    # Print environment variables
    print "Build environment:\n";
    print "\n $_=" , $ENV{"$_"} foreach (sort keys %ENV);

    my $deletechangelist = 0;

    my $localrepo = $ENV{ 'HOME' } . "/.m2/repository-rcbuild-$$";
    unless(-e $localrepo or mkdir $localrepo) {
        _log("Unable to create $localrepo");
        return ( $deletechangelist, 0 );
    }
    _log("Using Maven local repository: $localrepo");
    $self->{ 'RCBUILD_LOCALREPO' } = $localrepo;

    #initialize P4 client
    my $ret = $self->_initP4Client();
    if ( $ret == 0 ) {
        _deleteLocalRepo($localrepo);
        return ( $deletechangelist, $ret );
    }

    #initializes the latest changelist in Perforce.  This is used as "head" for the build.
    $ret = $self->_initLastChangelist();
    if ( $ret == 0 ) {
        _deleteLocalRepo($localrepo);
        return ( $deletechangelist, $ret );
    }

    # sync the tlp and peer files
    $ret = $self->_syncPom( $self->{ 'POMDEPOTPATH' }, 1 );
    if ( $ret == 0 ) {
        _deleteLocalRepo($localrepo);
        return ( $deletechangelist, $ret );
    }

    # set the client directory and path. this is used to locate the last good change
    # and build name.
    $ret = $self->_initPomClientPath( $self->{ 'POMDEPOTPATH' } );
    if ( $ret == 0 ) {
        _deleteLocalRepo($localrepo);
        return ( $deletechangelist, $ret );
    }

    $ret = $self->_syncBuildName();
    if ( $ret == 0 ) {
        _deleteLocalRepo($localrepo);
        return ( $deletechangelist, $ret );
    }

    $ret = $self->_genNextBuildName( 0 );
    if ( $ret == 0 ) {
        _deleteLocalRepo($localrepo);
        return ( $deletechangelist, $ret );
    }

    #init the change list for editing (common changelist for all projects)
    $ret = $self->_initChangelist();
    if ( $ret == 0 ) {
        _deleteLocalRepo($localrepo);
        return ( $deletechangelist, $ret );
    }

    #read the tlp list
    my @tlpList = $self->_readTLPList();

    #process each top level pom in order
    foreach my $tlp ( @tlpList ) {
        my $tlpLastChange;

        if ($self->{ 'MVNGOALS' }) {
            _log( "\n------- Performing the open for edit and " . $self->{ 'MVNGOALS' } . " goal(s) on $tlp ---------\n" );
        }
        else {
            _log( "\n------- Performing the open for edit on $tlp ---------\n" );
        }

        $ret = $self->_syncPom( $tlp );
        if ( $ret == 0 ) {
            _deleteLocalRepo($localrepo);
            return ( $deletechangelist, $ret );
        }

        $ret = $self->_initPomClientPath( $tlp );
        if ( $ret == 0 ) {
            _deleteLocalRepo($localrepo);
            return ( $deletechangelist, $ret );
        }

        # sync the modules at last change list
        $ret = $self->_syncModules();
        if ( $ret == 0 ) {
            _deleteLocalRepo($localrepo);
            return ( $deletechangelist, $ret );
        }

        #sync the code
        $ret = $self->_sync();
        if ( $ret == 0 ) {
            _deleteLocalRepo($localrepo);
            return ( $deletechangelist, $ret );
        }

        $deletechangelist = 1; # Any failure from here down will result in reverting the changelist

        $ret = $self->_editAndExecuteMvnGoalsAux();
        if ( $ret == 0 ) {
            _deleteLocalRepo($localrepo);
            return ( $deletechangelist, $ret );
        }

        if ($self->{ 'SUBMITCHANGES' }) {
            $ret = $self->_commit();
            if ( $ret == 0 ) {
                _deleteLocalRepo($localrepo);
                return ( $deletechangelist, $ret );
            }
        }
        else {
            $deletechangelist = 0;
            _logInfo("The changelist " . $self->{ 'CHANGELIST' } . " contains edits to pom.xml for scrutiny and future commit|revert");
        }
    }

    _deleteLocalRepo($localrepo);
    return ( $deletechangelist, $ret );
}

# Return like    my ($deletechangelist, $ret) = $self->_buildStandard();
# deleteChangelist == 1 means that the caller must delete the changelist (status will be 0 in that case)
# status == 1 if success; 0 otherwise
#
#
# The Standard (CI/Robot) build process is as follows:
#
# - get last changelist; this is used as the point in time "head" for subsequent p4 sync
# - sync <product>-app level pom
# - sync modules
# - sync code
# - update the BuildName
# - create a p4 changelist
# - check out pom files
# - edit pom files
# - inc version (like 1.0-SNAPSHOT -> 1.1-SNAPSHOT)
# - commit pom files that were changed
# - label the artifact with Buildname and pom coordinates
# - run mvnGoals ('clean install' is typical)
#
sub _buildStandard {
    my ( $self ) = @_;

    # Print environment variables
    print "Build environment:\n";
    print "\n $_=" , $ENV{"$_"} foreach (sort keys %ENV);

    my $deletechangelist = 0;

    my $ret = $self->_initP4Client();
    if ( $ret == 0 ) {
        return ( $deletechangelist, $ret );
    }

    $ret = $self->_initLastChangelist();
    if ( $ret == 0 ) {
        return ( $deletechangelist, $ret );
    }

    if ( $self->{ 'SUBMITCHANGES' } ) {
        # After initChangelist we need to delete the changelist
        $deletechangelist = 1;
        $ret = $self->_initChangelist();
        if ( $ret == 0 ) {
            return ( $deletechangelist, $ret );
        }
    }

    $ret = $self->_syncPom( $self->{ 'POMDEPOTPATH' } );
    if ( $ret == 0 ) {
        return ( $deletechangelist, $ret );
    }

    $ret = $self->_initPomClientPath( $self->{ 'POMDEPOTPATH' } );
    if ( $ret == 0 ) {
        return ( $deletechangelist, $ret );
    }

    $ret = $self->_syncModules();
    if ( $ret == 0 ) {
        return ( $deletechangelist, $ret );
    }

    $ret = $self->_sync();
    if ( $ret == 0 ) {
        return ( $deletechangelist, $ret );
    }

    if ( $self->{ 'SUBMITCHANGES' } ) {
        $ret = $self->_syncBuildName();
        if ( $ret == 0 ) {
            return ( $deletechangelist, $ret );
        }

        $ret = $self->_editBuildName();
        if ( $ret == 0 ) {
            return ( $deletechangelist, $ret );
        }
        $ret = $self->_genNextBuildName( 0 );
        if ( $ret == 0 ) {
            return ( $deletechangelist, $ret );
        }

        $ret = $self->_incrementVersion();
        if ( $ret == 0 ) {
            return ( $deletechangelist, $ret );
        }

        $ret = $self->_commit();
        if ( $ret == 0 ) {
            return ( $deletechangelist, $ret );
        }

        # Now the changelist is committed so we don't have to worry about deleteing it on failure
        $deletechangelist = 0;
        $ret = $self->_label();
        if ( $ret == 0 ) {
            return ( $deletechangelist, $ret );
        }
    }

    if ( $self->{ 'MVNGOALS' } ) {
        $ret = $self->_buildGoals();
        if ( $ret == 0 ) {
            return ( $deletechangelist, $ret );
        }
    }

    return ( $deletechangelist, $ret );
}

# get the changes between 2 revisions
# if the first revision ($fromChange) is not defined, return a list
# containing only 1 element: the last known change
sub getChanges {
    my ( $fromChange, $toChange, $monitor, $additionalPerforcePath ) = @_;
    if ( !defined ( $toChange ) || $toChange eq "head" ) {
        $toChange = "#head";
    }
    if ( $fromChange eq $toChange ) {
        return ();
    }
    if ( @$monitor == 0 ) {
        return ();
    }
    my @paths = getInterestingPaths( $fromChange, $toChange, $monitor );
    if ( $additionalPerforcePath && $additionalPerforcePath =~ m|//ariba/| ) {
        $additionalPerforcePath .= "/...#head";
        push ( @paths, $additionalPerforcePath );

    }

    my $flag = ( $fromChange == 0 ? "-m 1" : "" );
    my @listOfChanges = ();

    # we can't call p4 changes on a huge array of paths, we will reach
    # the limit of the command line size
    # instead, we break it up into 20 paths and call p4 changes on these
    # 20 paths and then we reloop
    while ( @paths > 0 ) {
        my @tempArray = ();
        my $cpt = 0;
        while ( $cpt < 20 && @paths > 0 ) {
            push ( @tempArray, pop ( @paths ) );
            $cpt++;
        }
        my $fullPath = join ( " ", @tempArray );
        my $command = "changes $flag $fullPath";
        _logInfo( "Running $command" );
        my %out = Ariba::P4::p4s( $command );
        if ( $out{ error } ) {
            _logError( "Error getting the changes: " . join ( "", @{ $out{ error } } ) );
        }
        if ( exists ( $out{ info } ) && @{ $out{ info } } > 0 ) {
            my @changes = @{ $out{ info } };
            foreach my $change ( @changes ) {
                chomp ( $change );
                $change =~ s/^Change\s+(\d+).*/$1/;
                if ( $change > $fromChange ) {
                    if ( !grep ( $_ == $change, @listOfChanges ) ) {
                        push ( @listOfChanges, $change );
                    }
                }
            }
        }
    }
    if ( $fromChange == 0 ) {
        my $tempLatestChange = ( sort { $b <=> $a } ( @listOfChanges ) )[ 0 ];
        return ( $tempLatestChange );
    } else {
        return ( sort { $b <=> $a } ( @listOfChanges ) );
    }
}

# if given a depotDir (//ariba/b/c), return the depotDir in a array context
# with #head: //ariba/b/c/...#head
# if given a //ariba/.../blabla.txt, going to assume that this file is a
# components.txt (a triplet (compName Label Path)) and will return an array
# containing all the entries from the componentx.txt
# $fromChange is for the perforce query optimization
sub getInterestingPaths ($$$) {
    my ( $fromChange, $toChange, $paths ) = @_;
    my @interestingPaths = ();
    my $range;
    if ( $fromChange == 0 ) {
        $range = "#head";
    } else {
        $range = "\@$fromChange,$toChange";
    }
    foreach my $path ( @$paths ) {

        if ( $path =~ /.*\.txt$/ ) {
            push ( @interestingPaths, getPathsFromFile( $fromChange, $toChange, $path ) );
            # let's add the file itself so we know when it's updated
            push ( @interestingPaths, $path . $range );
        } elsif ( $path =~ m|//ariba/| ) {
            # remove trailing ... if any
            $path =~ s/\.\.\.$//;
            # remove trailing / if any
            $path =~ s/\/$//;
            $path .= "/...$range";
            push ( @interestingPaths, $path );
        } else {
            _logWarning( "Entry $path ignored: expecting an entry of form " . "//ariba/b/c or //ariba/b/c/components.txt" );
        }
    }
    return @interestingPaths;
}

sub _eliminateChanges () {
    my @changes = @_;
    my @goodChanges;

    my @usersToBeEliminated = ( "rc" );
    my @filesToBeEliminated = ( "BuildName", "ReleaseName" );

    foreach my $change ( @changes ) {
        _logInfo( "Checking $change for elimation..." );
        my $changeInfo = Ariba::P4::getChangelistInfo( $change );
        if ( grep ( /$$changeInfo{"User"}/i, @usersToBeEliminated ) ) {
            _logInfo( "The change $change is not considered for robot kick-off as it is submitted by the user " . $$changeInfo{ "User" } );
            next;
        }

        # Look at files that need to be eliminated
        my @files = Ariba::P4::ChangelistFiles( $change );
        my $skipThisChange = 1;
        foreach my $filePath ( @files ) {
            my $file = ( split ( /\//, $filePath ) )[ -1 ];
            $file =~ /(.*)#/;
            $file = $1;

            if ( !( grep ( /$file/i, @filesToBeEliminated ) ) ) {
                $skipThisChange = 0;
                last;
            }
        }
        if ( $skipThisChange ) {
            _logInfo( "The change $change is not considered for robot build kick-off as it edits build config files only" );
            next;
        }

        # If we are here, then this change needs to be considered for build kick-off
        push ( @goodChanges, $change );
    }

    return @goodChanges;
}

# Class method
sub _log {
    my ( $msg ) = @_;

    _logInfo($msg);
}

# TODO: Get Ariba vs. ariba perl naming issue fixed so running on a Mac (case insensitive) will work
# use ariba::Ops::Logger;
# my $logger = ariba::Ops::Logger->logger();
sub _logInfo() {
    my ( $msg ) = @_;
    # $logger->info($msg);
    print "ariba::rc::MavenBuild::Info $msg\n";
}

sub _logWarning() {
    my ( $msg ) = @_;
    # $logger->warning($msg);
    print "ariba::rc::MavenBuild::Warning $msg\n";
}

sub _logError() {
    my ( $msg ) = @_;
    # $logger->error($msg);
    print "ariba::rc::MavenBuild::Error $msg\n";
}
1;
