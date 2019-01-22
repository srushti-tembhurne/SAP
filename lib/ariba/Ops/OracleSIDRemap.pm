#------------------------------------------------------------------------------
# $Id: //ariba/services/tools/lib/perl/ariba/Ops/OracleSIDRemap.pm#5 $
# $HeadURL$
#------------------------------------------------------------------------------
package ariba::Ops::OracleSIDRemap;

use warnings;
use strict;
use lib "/usr/share/perl5/";
## Core/CPAN modules
use File::Copy qw( move );
use Carp;
use Data::Dumper;
# Some Data::Dumper settings:
local $Data::Dumper::Useqq = 1;
local $Data::Dumper::Indent = 3;

## For finding Oracle config files:
use File::Find::Rule;

## Ariba modules
use ariba::Ops::NetworkUtils;
use ariba::Ops::NetworkDeviceManager;
use ariba::Ops::Machine;
use ariba::rc::InstalledProduct;
use ariba::rc::Utils;
use ariba::rc::Passwords;
use ariba::Ops::OracleClient;

use ariba::Ops::OracleServiceManager;

local $| = 1;

=head1 NAME

ariba::Ops::OracleSIDRemap

=head1 VERSION

Version 0.01

=cut

use version; our $VERSION = '1.00';

## This is designed to run on ambrosia.ariba.com, this is the location of the Oracle
## configs sync'd from Perforce.
my $oraConfBase       = '/var/perforce_sync/';
my $defaultOraConfDir = "${oraConfBase}ariba/services/operations/cfengine/dist/rh/configs/";

=head1 SYNOPSIS

    use ariba::Ops::OracleSIDRemap;

    my $sidRemapper = ariba::Ops::OracleSIDRemap->new();
    ## Create trace file:
    $remapper->createTraceFile({
            sid => $srcSid,
        });

    ## Now process it:
    $remapper->processTraceFile({
        dstSid => $dstSid,
        destService => $destService,
    });

    ## Now load the new SID/DB
    $remapper->loadNewSid();

=head1 DESCRIPTION

ariba::Ops::OracleSIDRemap is used for remapping Oracle DB SIDs. For dev/opslab we take a copy of a production DB and manually remap it into a different SID. This will perform the same procedure programmatically so the process can be scripted and/or automated.

=cut

=head1 PUBLIC METHODS

new()

    FUNCTION: Constructor

   ARGUMENTS: hashref of named arg => value pairs (datasetId and destService are mandatory)
              valid args: debug, dryrun, destService, datasetId, srcSid, dstSid, tracefile
                    srcDir, dstDir
           
     RETURNS: a blessed ariba::Ops::OracleSIDRemap object

=cut

sub new {
    my $class = shift;
    croak __PACKAGE__ . "::new(): Class method called as instance method!\n" if ref $class;
    my $args = shift;

    my $self = {};
    $self->{ 'debug' } = $args->{ 'debug' } if $args->{ 'debug' };
    $self->{ 'dryrun' } = $args->{ 'dryrun' } if $args->{ 'dryrun' };

    ## If these are passed to new, let's use them:
    $self->{ 'srcSid' }      = lc $args->{ 'srcSid' } if $args->{ 'srcSid' };
    $self->{ 'dstSid' }      = lc $args->{ 'dstSid' } if $args->{ 'dstSid' };
    $self->{ 'destService' } = lc $args->{ 'destService' } if $args->{ 'destService' };
    $self->{ 'datasetId' }   = lc $args->{ 'datasetId' } if $args->{ 'datasetId' };
    $self->{ 'tracefile' }   = lc $args->{ 'tracefile' } if $args->{ 'tracefile' };

    ## Check for required arguments:
    my @required;
    push( @required, 'datasetId' ) unless $self->{ 'datasetId' };
    push( @required, 'destService' ) unless $self->{ 'destService' };
    croak "Cannot create new $class: Required field(s) '" . join( " and ", @required ) . "' missing!\n"
        unless defined $self->{ 'datasetId' } && defined $self->{ 'destService' };

    my $srcMount   = ariba::Ops::OracleSIDRemap->mountPointForSid( $self->{ 'srcSid' } ); ## oraXXX
    my $srcMountPt = "${srcMount}a"; ## oraXXXa
    my $srcMountDg = "${srcMount}dg"; ## oraXXXdg

    my $dstMount   = ariba::Ops::OracleSIDRemap->mountPointForSid( $self->{ 'dstSid' } ); ## oraXXX
    my $dstMountPt = "${dstMount}a"; ## oraXXXa
    my $dstMountDg = "${dstMount}dg"; ## oraXXXdg

    $self->{ 'srcMount' }   = $srcMount;
    $self->{ 'srcMountPt' } = $srcMountPt;
    $self->{ 'srcMountDg' } = $srcMountDg;
    $self->{ 'dstMount' }   = $dstMount;
    $self->{ 'dstMountPt' } = $dstMountPt;
    $self->{ 'dstMountDg' } = $dstMountDg;

    ## Ariba machine/DB/NetworkDevice stuff
    my $hostname = ariba::Ops::NetworkUtils::hostname();
    my $machine  = ariba::Ops::Machine->new( $hostname );
    my $me       = ariba::rc::InstalledProduct->new( 'mon', $machine->service() );

    ariba::rc::Passwords::initialize( $self->{ 'destService' } );

    $self->{ 'hostname' } = $hostname;
    $self->{ 'dbUser' }   = 'system';
    $self->{ 'dbPass' }   = $me->default("dbainfo.system.password");

    $self->{ 'sudoUser' } = "svc$self->{ 'destService' }";
    $self->{ 'sudoPass' } = ariba::rc::Passwords::lookup( $self->{ 'sudoUser' } );
    $self->{ 'sudoCmd' }  = ariba::rc::Utils::sudoCmd();

    ## Not sure we'll need this but here it is anyway:
    $self->{ 'storeadminHost' } = 'ambrosia.ariba.com';

    ## Set ORACLEHOME for $self
    eval{
        print "Getting ORACLEHOME for '" . $self->{ 'srcSid' } . "'\n";
        $self->{ 'oracleHomeSrc' } = ariba::Ops::OracleSIDRemap->_setOracleHomeForSid( $self->{ 'srcSid' } );
        print "Getting ORACLEHOME for '" . $self->{ 'dstSid' } . "'\n";
        $self->{ 'oracleHomeDst' } = ariba::Ops::OracleSIDRemap->_setOracleHomeForSid( $self->{ 'dstSid' } );
    };
    if ( $@ ){
        croak __PACKAGE__ . "::new(): Error setting ORACLEHOME: $@\n";
    }

    return bless $self, $class;
}

=head1

createTraceFile()

    FUNCTION: Creates a tracefile for a given SID

   ARGUMENTS: hashref containing 'tracefile' and 'srcSid'
              trace file name (scalar) (default: /tmp/trace_<SID>_<PID>.trc)
              SID name (scalar)

              *If srcSid or tracefile were passed to new() you don't need to pass them here
           
     RETURNS: 1 for success, croak's on failure

=cut

sub createTraceFile{
    my $self = shift;
    croak __PACKAGE__ . "::createTraceFile(): Instance method called as class method!\n" unless ref $self;
    my $args = shift;

    my $sid = lc $args->{ 'srcSid' }
        || $self->{ 'srcSid' }
        || croak "createTraceFile: sid is a mandatory argument!!\n";

    my $tracefile = $args->{ 'tracefile' }
        || $self->{ 'tracefile' }
        || "/tmp/trace_${sid}_$$.trc";

    if ( -e $tracefile ) {
        my $cmd = "$self->{ 'sudoCmd' } rm $tracefile";
        my @output;
        my $exitRef;

        if ( $self->{ 'dryrun' } ){
            print "dryrun: would run '$cmd'\n";
        } else {
            print "running '$cmd'\n" if $self->{ 'debug' };
            ariba::rc::Utils::executeLocalCommand(
                $cmd,
                undef,
                \@output,
                undef,
                1,
                $exitRef,
                $self->{ 'sudoPass' },
            ) or warn "Could not delete '$tracefile': $!\n";
        }
    }

    ## (Re)save these for later:
    $self->{ 'tracefile' } = $tracefile;
    $self->{ 'srcSid' }    = $sid;

     print "Creating trace file '$tracefile' for SID '$self->{ 'srcSid' }.\n"
        if $self->{ debug };

    ## Lets try setting the effective user to 'oracle'
    my @oracleUser = getpwnam 'oracle';
    $) = $oracleUser[3]; ## Effective GID
    $> = $oracleUser[2]; ## Effective UID
    ## We need to set some oracle ENV variables
    $ENV{ 'ORACLE_SID' } = $self->{ 'srcSid' };
# $ENV{ 'ORACLEHOME' } = '/oracle/app/oracle/product/11.2.0.2.0.p10';
    $ENV{ 'ORACLE_HOME' } = $self->{ 'oracleHomeSrc' };

    ## DB will not be up, need to use OracleServiceManager instead of OracleClient ...
    print "Creating OracleServiceManager object for SID '" . $self->{ 'srcSid' } . "'\n" if $self->{ debug };
    #my $serviceManager = OracleServiceManager->new( $self->{ 'srcSid' } );
    my $serviceManager = ariba::Ops::OracleServiceManager->new( $self->{ 'srcSid' } );
    $serviceManager->setDebug( 2 );
    $serviceManager->{ 'oracleHomeSrc' } = $ENV{ 'ORACLEHOME' };
    print "Calling OracleServiceManager->startupMount()\n" if $self->{ debug };

    if ( my $return = $serviceManager->startupMount() ){
        print "OracleServiceManager->startupMount() Succeeded!\n";
    } else {
        my $err = $serviceManager->error();
        if ( $err ){
            print "Error : '$err'\n";
        } else {
            print "\$serviceManager->error() empty ...\n";
        }
        if ( $return ){
            print "Returned: '$return'\n";
        } else {
            print "\$serviceManager->startupMount() returned nothing ...\n";
        }
        exit;
    }

    ## SQL variables:
    my @results;

    ## Create the trace file:
    my $sql = "alter database backup controlfile to trace as \'$self->{ 'tracefile' }\';";
    #print "Preparing to run SQL: '$sql'\n" if $self->{ 'debug' };
    $serviceManager->_runSqlFromServiceManager( $sql, "Database altered." );
    croak "Error: " . $serviceManager->error() . "\n" if $serviceManager->error();

    $serviceManager->shutdown();

    ## And set the effective user back to ourself
    my @svcUser = getpwnam $ENV{ 'USER' };
    $) = $svcUser[3];
    $> = $svcUser[2];

    ## Marker for later
    $self->{ 'traceCreated' } = 1;
    return 1;
}

=head1

processTraceFile()

    FUNCTION: Takes a tracefile and rewrites it with the pertinent changes made

   ARGUMENTS: hashref with tracefile, srcSid, dstSid
              trace file name (scalar)
              old SID name (scalar)
              new SID name (scalar)

     RETURNS: 1 for success, croak's on failure

        NOTE: output files will be /tmp/cr_<new SID>_1.sql and /tmp/cr_<new SID>_2.sql

=cut

sub processTraceFile {
    my $self = shift;
    croak __PACKAGE__ . "::processTraceFile(): Instance method called as class method!\n" unless ref $self;
    croak __PACKAGE__ . "::processTraceFile(): Must run createControlFile() first!\n" unless $self->{ 'traceCreated' } == 1;
    my $args = shift;

    my $tracefile = $self->{ 'tracefile' } ## Default to saved trace file if it exists
        || $args->{ tracefile } ## Next try the tracefile argument
        || croak "proecssTraceFile: trace file name required!!\n";

    my $srcSid = $self->{ 'srcSid' } ## Default to saved sid if it exists
        || $args->{ srcSid } ## Next try the srcSid argument
        || croak "proecssTraceFile: old SID name required!!\n";

    my $dstSid = $self->{ 'dstSid' }
        || $args->{ 'dstSid' }
        || croak "proecssTraceFile: new SID name required!!\n";

    my $dstDir = $self->{ 'dstDir' }
        || $args->{ 'dstDir' }
        || croak "proecssTraceFile: target directory name required!!\n";

    my $srcDir = $self->{ 'srcDir' }
        || $args->{ 'srcDir' }
        || croak "proecssTraceFile: source directory name required!!\n";

    croak __PACKAGE__ . "::processTraceFile(): Source mount point mandatory\n" unless defined $srcDir;
    croak __PACKAGE__ . "::processTraceFile(): Target mount point mandatory\n" unless defined $dstDir;

    ## Make sure these are all lowercase
    $srcSid = lc $srcSid;
    $dstSid = lc $dstSid;
    ## But we also need uppercase versions ...
    my $ucSrcSid = uc $srcSid;
    my $ucDstSid = uc $dstSid;

    ## output files
    my $outfile1 = "/tmp/cr_${dstSid}_01.sql";
    my $outfile2 = "/tmp/cr_${dstSid}_02.sql";

    ## Store this info for possible later use:
    $self->{ 'tracefile' } = $tracefile;
    $self->{ 'srcSid' } = $srcSid;
    $self->{ 'dstSid' } = $dstSid;
    $self->{ 'srcDir' } = $srcDir;
    $self->{ 'dstDir' } = $dstDir;
    $self->{ 'outfile1' } = $outfile1;
    $self->{ 'outfile2' } = $outfile2;

    croak "Trace file '$tracefile' does not exist!!\n" unless ( -e $tracefile );

    print "Processing trace file '$tracefile'\n" if $self->{ 'debug' };

    ## Read the contents of the trace file, I normally wouldn't slurp this but I want the whole file
    ## in memory since I want to reopen and rewrite the file
    open my $IN, '<', $tracefile || croak "Couldn't open '$tracefile' for reading: $!\n";
    my @traceContents = <$IN>;
    close $IN or croak "Error closing '$tracefile': $!\n";

    ## NOTE: Between this open() (the select() actually) and the close() below, anything printed
    ## stands a chance of being printed into the trace file. If debug output is needed,
    ## make sure to 'print STDOUT "stuff to print"' or it will corrupt the trace file.
    ## NOTE: I'm specifically calling this out because of the mildly hokey filehandle manipulation.
    open my $OUT, '>', $outfile1 or croak "Couldn't open '$outfile1' for writing: $!\n";
    open my $OUT2, '>', $outfile2 or croak "Couldn't open '$outfile2' for writing: $!\n";
    my $srcFh = select $OUT or croak "Error selecting filehandle for '$outfile1': $!\n";

    my $found;
    my $endFirstFile;
    ## Need to match:
    ## CREATE CONTROLFILE REUSE DATABASE "S4TOOL1" RESETLOGS FORCE LOGGING ARCHIVELOG
    ## Versus:
    ## CREATE CONTROLFILE REUSE DATABASE "ANAUX1" NORESETLOGS  NOARCHIVELOG
    ## I've changed this regex a couple of times, the RESETLOGS versus NORESET logs is the
    ## determinator:
    #my $regex = "CREATE CONTROLFILE REUSE DATABASE \"$ucSrcSid\" RESETLOGS FORCE LOGGING";
    my $regex = "\"$ucSrcSid\" RESETLOGS";

    LINE:
    foreach my $line ( @traceContents ){
        my $orig = $line;
        if ( ( ! $found && $line !~ m/$regex/ ) || $line =~ m/^--/ ){
            ## ( Not found and not a match ) || a comment ...
            next LINE;
        } elsif ( ! $found && $line =~ m/$regex/ ){
            ## First line we're looking for
            $found = 1;
            
            ## Change the SID
            $line =~ s/$ucSrcSid/$ucDstSid/;
            ## Per DBAs, change REUSE to SET
            $line =~ s/REUSE/SET/;

            print $line;
        } elsif ( $found && $line =~ m/^;$/ ){
            ## Found the end of the first file so print the ';' and switch to the next file
            print $line;
            print STDOUT "*** Found second file ...\n";
            $endFirstFile = 1;

            select $OUT2 or croak "Error selecting filehandle for '$outfile2': $!\n";
        } elsif ( $found ) {
            ## Ignore blank lines
            next LINE if $line =~ m/^\s*$/;
            ## Ignore these specific lines per James
            next LINE if $line =~ m/RECOVER DATABASE USING BACKUP CONTROLFILE/;
            next LINE if $line =~ m/ALTER DATABASE ADD SUPPLEMENTAL LOG DATA/;
            next LINE if $line =~ m/ALTER DATABASE OPEN RESETLOGS/;
            ## Also swap mount point
            $line =~ s/$self->{ 'srcDir' }/$self->{ 'dstDir' }/;
            ## Change the SID
            $line =~ s/$ucSrcSid/$ucDstSid/;

            print $line;
        }
    }

    ## NOTE: After this select() it's OK to just print again.
    select $srcFh or croak "Error selecting filehandle for 'STDOUT': $!\n";
    close $OUT or croak "Error closing '$outfile1': $!\n";
    close $OUT2 or croak "Error closing '$outfile2': $!\n";

    unless ( $found && $endFirstFile ){
        croak "Failed to find appropriate section from trace file.";
    }

    ## We've processed the tracefile, let's remove it
    my $cmd = "$self->{ 'sudoCmd' } rm $tracefile";
    my @output;
    my $exitRef;

    print "running '$cmd'\n" if $self->{ 'debug' };
    ariba::rc::Utils::executeLocalCommand(
        $cmd,
        undef,
        \@output,
        undef,
        1,
        $exitRef,
        $self->{ 'sudoPass' },
    ) or warn "Could not delete '$tracefile': $!\n";

    $self->{ 'traceProcessed' } = 1;
    ## If we didn't croak before now, return success
    return 1;
}

=head1

loadNewSid()

    FUNCTION: Bring up the new SID

   ARGUMENTS: none, all necessary data has already been collected
           
     RETURNS: 1 for success, croak's on failure

        NOTE: You MUST run createTraceFile first then processTraceFile before running loadNewSid

=cut

sub loadNewSid{
    my $self = shift;

    ## Short circuit this if $self->{ 'dryrun' }
    if ( $self->{ 'dryrun' } ){
        print "Not loading new SID under dryrun!\n";
        return 1;
    }
    croak __PACKAGE__ . "::loadNewSid(): Instance method called as class method!\n" unless ref $self;

    croak __PACKAGE__ . "::loadNewSid(): Must run processControlFile() first!\n" unless $self->{ 'traceProcessed' } == 1;

    ## SQL variables:
    my @results;
    my $sql;
    my $return; ## catch returned info

    ## Lets try setting the effective user to 'oracle'
    my @oracleUser = getpwnam 'oracle';
    my @mondevUser = getpwnam 'mondev';

    $) = $mondevUser[3]; ## Effective GID
    $> = $mondevUser[2]; ## Effective UID

    my $dstMount = "/$self->{ 'dstMountPt' }/";
    my $srcSid = uc $self->{ 'srcSid' };
    my $dstSid = uc $self->{ 'dstSid' };

    print "Calling: renameDirectoriesAndDeleteFiles( '$dstMount', '$srcSid', '$dstSid' )\n"
        if $self->{ 'debug' };
    ariba::Ops::OracleSIDRemap->renameDirectoriesAndDeleteFiles( $dstMount, $srcSid, $dstSid );
    print "Directories renamed successfully.\n" if $self->{ 'debug' };


    ## Need to create this as mon$service
    ## For stopping and starting Oracle:
    my $sm = ariba::Ops::OracleServiceManager->new( $self->{ 'dstSid' } );
    print "Setting debug on SM to '$self->{ 'debug' }'\n" if $self->{ 'debug' };
    $sm->setDebug( $self->{ 'debug' } );
    ## Set oracleHome appropriately
    $sm->setOracleHome( $self->{ 'oracleHomeDst' } );

    ## We need to set some oracle ENV variables
    $ENV{ 'ORACLE_SID' } = $self->{ 'dstSid' };
    $ENV{ 'ORACLE_HOME' } = $self->{ 'oracleHomeDst' };
    $ENV{ 'ORACLE_BASE' } = '/oracle/app/oracle';

    print "Calling OracleServiceManager->startupNoMount()\n" if $self->{ 'debug' };
    $sm->startupNoMount();
    croak "Error: " . $sm->error() . "\n" if $sm->error();
    print "OracleServiceManager->startupNoMount() Complete\n" if $self->{ 'debug' };

    ## Read in the SQL rather than trying to run the file:
    open my $IN, '<', $self->{ 'outfile1' }
        or croak "Error opening '$self->{ 'outfile1' }' for read: $!\n";
    my @sqlFromFile = <$IN>;
    close $IN or croak "Error closing '$self->{ 'outfile1' }': $!\n";

    ## Join the file into a scalar:
    $sql = join ' ', @sqlFromFile;

    $) = $oracleUser[3]; ## Effective GID
    $> = $oracleUser[2]; ## Effective UID
    
    print "Calling OracleServiceManager->_runSqlFromServiceManager()\n" if $self->{ 'debug' };
#    print "++ $sql ++\n" if $self->{ 'debug' };
#    if ( length $sql < 4096 ){
        $sm->_runSqlFromServiceManager( $sql, '^Control file created.' );
#    } else {
#       $sm->_runSqlFromServiceManager( \@sqlFromFile, '^Control file created.' );
#    }
    print "OracleServiceManager->_runSqlFromServiceManager() Complete\n" if $self->{ 'debug' };

    ## This 'alter database open resetlogs' is taking a long time, let's see just how long:
    use Time::HiRes qw( gettimeofday );
    my $startsql = gettimeofday();

    $sql = 'alter database open resetlogs;';
    print "Calling OracleServiceManager->_runSqlFromServiceManager( '$sql' )\n" if $self->{ 'debug' };
    $sm->_runSqlFromServiceManager( $sql, '^Database altered.' );
    print "OracleServiceManager->_runSqlFromServiceManager() Complete\n" if $self->{ 'debug' };

    my $runtime = gettimeofday() - $startsql;
    print "'$sql' took '$runtime' seconds ...\n" if $self->{ 'debug' };

    ## Run second file unless it's zero-length
    ## Read in the SQL rather than trying to run the file:
    unless ( -z $self->{ 'outfile2' } ){
        open $IN, '<', $self->{ 'outfile2' }
            or croak "Error opening '$self->{ 'outfile2' }' for read: $!\n";
        ## Empty out @sqlFromFile just to e safe:
        @sqlFromFile = ();
        @sqlFromFile = <$IN>;
        close $IN or croak "Error closing '$self->{ 'outfile2' }': $!\n";

        ## Join the file into a scalar:
        $sql = join ' ', @sqlFromFile;

        print "Calling OracleServiceManager->_runSqlFromServiceManager( '$sql' )\n" if $self->{ 'debug' };
#        print "++ $sql ++\n" if $self->{ 'debug' };
        $sm->_runSqlFromServiceManager( $sql, '^Tablespace altered.' );
        print "OracleServiceManager->_runSqlFromServiceManager() Complete\n" if $self->{ 'debug' };
    }

    ## Oracle doesn't seem to come all the way back up, let's bounce it
    print "Calling OracleServiceManager->shutdown()\n" if $self->{ 'debug' };
    $sm->shutdown();
    print "OracleServiceManager->shutdown() Complete\n" if $self->{ 'debug' };

    ## The /tmp/cr_* files are owned by root, we're running under sudo so:
    @oracleUser = getpwnam 'root';
    $) = $oracleUser[3]; ## Effective GID
    $> = $oracleUser[2]; ## Effective UID
    ## cleanup /tmp/cr_*files
    foreach my $sqlFile ( $self->{ 'outfile1' }, $self->{ 'outfile2' } ){
        unlink $sqlFile or croak "Error removing '$sqlFile': $!\n";
    }

    ## And back to the oracle user
    @oracleUser = getpwnam 'oracle';
    $) = $oracleUser[3]; ## Effective GID
    $> = $oracleUser[2]; ## Effective UID

    print "Leaving loadNewSid()\n" if $self->{ 'debug' };
    return 1;
}

=head1

renameDirectoriesAndDeleteFiles()

    FUNCTION: Renames /ora108/oradata1/OLDSID/ to /ora108/oradata1/NEWSID/at the OS level
              Also removes all existing control files

   ARGUMENTS: Directory (/oraXXXa/), Source SID, Target SID
           
     RETURNS: 1 for success, croak's on error

        NOTE: This is a class method, NOT an instance method

=cut

sub renameDirectoriesAndDeleteFiles{
    my $class = shift;
    croak __PACKAGE__ . "::renameDirectoriesAndDeleteFiles(): Class method called as instance method!\n" if ref $class;
    my $dir = shift || croak __PACKAGE__ . "::renameDirectoriesAndDeleteFiles(): Directory required!\n";
    my $srcSid = shift || croak __PACKAGE__ . "::renameDirectoriesAndDeleteFiles(): Source SID required!\n";
    my $dstSid = shift || croak __PACKAGE__ . "::renameDirectoriesAndDeleteFiles(): Target SID required!\n";

    ## Directory names are upper case:
    $srcSid = uc $srcSid;
    $dstSid = uc $dstSid;

# print "**** srcSid: '$srcSid'\tdstSid: '$dstSid' ****\n";

    ## This module makes File::Find much easier, I've never used it before so:
    ## http://search.cpan.org/~rclamp/File-Find-Rule-0.33/lib/File/Find/Rule.pm
# my @directories = File::Find::Rule->directory
# ->name( "$srcSid" )
# ->in( $dir );
    ## The File::Find::Rule wasn't working, this worked:
    my @directories = `find $dir -name $srcSid -type d`;
            
    ## Rename directories:
    foreach my $directory ( @directories ){
        chomp $directory;
        my $dstDirectory = $directory;
        $dstDirectory =~ s/$srcSid/$dstSid/;

# print "**** srcDir: '$directory'\tdstDir: '$dstDirectory' ****\n";

        move( $directory, $dstDirectory )
            or croak __PACKAGE__ . "::renameDirectoriesAndDeleteFiles(): Rename failed: $!\n";
        ## Now delete all .ctl files in those directories:
        my @ctlFiles = File::Find::Rule->file()
                                     ->name( "*.ctl" )
                                     ->in( $dstDirectory );

        foreach my $ctlFile ( @ctlFiles ) {
            unlink $ctlFile or warn "Could not remove '$ctlFile': $!\n";
        }
    }

    return 1;
}

=head1

mountPointForSid()

    FUNCTION: Calculate the mount point name (eg. ora123) for a given SID

   ARGUMENTS: SID
           
     RETURNS: scalar mount point, croak's on error

        NOTE: This is a class method, NOT an instance method

=cut

sub mountPointForSid{
    my $class = shift;
    croak __PACKAGE__ . "::mountPointForSid(): Class method called as instance method!\n" if ref $class;
    my $sid = shift || croak __PACKAGE__ . "::mountPointForSid(): sid is mandatory!\n";
    my $oraConfDir = shift || $defaultOraConfDir;

    my @mounts = $class->listMountPoints( $sid, $oraConfDir );
    ## uniq
    @mounts = keys %{{ map { $_ => 1 } @mounts }};
#    print Dumper \@mounts;

    croak __PACKAGE__ . "::mountPointForSid(): Error: found more than one unique mount point, please open a ticket for Tools to look at this!\n" if ( scalar @mounts > 1 );
    croak __PACKAGE__ . "::mountPointForSid(): Error: found less than one unique mount point, please open a ticket for Tools to look at this!\n" if ( scalar @mounts < 1 );

    my $mount = $mounts[ 0 ]; ## /oraXXX/
    $mount =~ s/\///g; ## oraXXX

    return $mount;
}

=head1

listAllSIDs()

    FUNCTION: Proecsses Oracle config files and returns an array of SID names

   ARGUMENTS: None
           
     RETURNS: array of SID names as scalars, croak's on failure

        NOTE: This is a class method, NOT an instance method

=cut

sub listAllSIDs{
    my $class = shift;
    croak __PACKAGE__ . "::listAllSIDs(): Class method called as instance method!\n" if ref $class;
    my $oraConfDir = shift || $defaultOraConfDir;

    ## This module makes File::Find much easier, I've never used it before so:
    ## http://search.cpan.org/~rclamp/File-Find-Rule-0.33/lib/File/Find/Rule.pm
    my @initFiles = File::Find::Rule->file()
                                     ->name( "init*.ora" )
                                     ->in( $oraConfDir );

    my @sids;
    foreach my $file ( @initFiles ){
        $file =~ s/.*init(.*)\.ora/$1/;
        push @sids, $file;
    }
    return @sids;
}

=head1

listMountPoints()

    FUNCTION: Proecsses Oracle config files and returns an array of mount points

   ARGUMENTS: SID - optional - restricts list of mount points to given SID
           
     RETURNS: array of mount points as scalars, croak's on failure

        NOTE: This is a class method, NOT an instance method

=cut

sub listMountPoints{
    my $class = shift;
    croak __PACKAGE__ . "::listMountPoints(): Class method called as instance method!\n" if ref $class;
    my $sid = shift;
    my $oraConfDir = shift || $defaultOraConfDir;

    $sid = uc $sid;

    ## This module makes File::Find much easier, I've never used it before so:
    ## http://search.cpan.org/~rclamp/File-Find-Rule-0.33/lib/File/Find/Rule.pm
    my @initFiles = File::Find::Rule->file()
                                     ->name( "init*.ora" )
                                     ->in( $oraConfDir );

    if ( $sid ){
        ## If we were passed a SID, filter out other SIDs
        @initFiles = grep { $_ =~ m/init$sid\./i } @initFiles;
    }

#    print "\thas '", scalar @initFiles, "' we need ...\n";
#    print Dumper \@initFiles;

    if ( ! scalar @initFiles ){
        if ( $sid ){
            croak "Init file not found for '$sid'\n";
        } else {
            croak "No init files found\n";
        }
    }

    my @retval;

    foreach my $file ( @initFiles ){

        my @controlFiles = ariba::Ops::OracleSIDRemap->getControlFilesFromInitFile( $file );

        foreach my $ctlFile ( @controlFiles ){

            my $mountPoint = ariba::Ops::OracleSIDRemap->mountPointFromControlFile( $ctlFile );
            push @retval, $mountPoint;
        }
    }

    ## uniq
    @retval = keys %{{ map { $_ => 1 } @retval }};
    return @retval;
}

=head1

getControlFilesFromInitFile()

    FUNCTION: From an Oracle init file (pfile), return a list of control files

   ARGUMENTS: init file name, absolute path
           
     RETURNS: array of filenames

        NOTE: This is a class method, NOT an instance method

=cut

sub getControlFilesFromInitFile{
    my $class = shift;
    croak __PACKAGE__ . "Class method called as instance method!\n" if ref $class;
    my $initFile = shift or die __PACKAGE__ . "::getControlFilesFromInitFile: filename required!\n";
    croak "getControlFilesFromInitFile: '$initFile' not found!\n" unless ( -e $initFile );
    
    my @controlFiles;
    my $found = 0;

    open my $IN, '<', $initFile or die "Error opening '$initFile' for read: $!\n";
    LINE:
    while ( my $origLine = <$IN> ){
        my $line = $origLine;
        chomp $line;
        ## Strip all leading whitespace
        $line =~ s/^\s*//;
        ## Skip comments:
        next LINE if ( $line =~ /^#/ );
        ## Skip lines other than what we're looking for:
        next LINE unless ( $found || $line =~ m/^control_files\s*=/ );

        ## Example:
        ## controlFiles = (/ora149/oraredo1/S4TOOL1/control01.ctl,
        ## /ora149/oraredo2/S4TOOL1/control02.ctl)

        ## We matched ($found isn't incremented so it's still "!$found" but we got here
        ## so this line must be the controlFiles line
        $found = 1;

        $line =~ s/^control_files\s*=\s*//;
        ## Since some SIDs only have one control file, the '(' may or may not be there
        ## so I'm stripping it off seperately
        $line =~ s/^\(//;
        ## Some SIDs only have one control file (no comma on the line):
        if ( $origLine =~ m/^\s*control/ && $origLine !~ m/[,]$/ ){ $found = 0; }
        my $last = 0;
        if ( $line =~ s/[)]$// ){ $last = 1 } ## found the last control file, there's
                                               ## only one controlFiles per file so
                                               ## stop processing the file
                                               ## -- but only after we grab this

        ## ^^ substitutions above leaves either a ',' at the end:
        $line =~ s/(?:[,])$//;
        push @controlFiles, $line if($line =~ /\.ctl/);
        last if($last);
    }
    return @controlFiles;
}

=head1

mountPointFromControlFile()

    FUNCTION: From an Oracle control filename, return the mount point it's associated with

   ARGUMENTS: control file name, absolute path
           
     RETURNS: the associated mount point as a scalar

        NOTE: This is a class method, NOT an instance method

=cut

sub mountPointFromControlFile{
    my $class = shift;
    croak __PACKAGE__ . "::mountPointFromControlFile(): Class method called as instance method!\n" if ref $class;
    my $controlFile = shift or croak "mountPointFromControlFile: filename required!\n";

    ##                     v     v v non-greedy flags
    $controlFile =~ s|^(/.*?\d+.*?/?).*|$1|;

    $controlFile = ( $controlFile =~ m|/$| ) ? $controlFile : "$controlFile/";
    return $controlFile;
}

=head1

_setOracleHomeForSid()

    FUNCTION: Parse /etc/oratab for the ORACLEHOME associated with the source SID

   ARGUMENTS: SID (scalar)
           
     RETURNS: nothing. croak's on failure

        NOTE: This is an instance method, NOT a class method

=cut

sub _setOracleHomeForSid{
    my $class = shift;
    my $sid = shift;
    $sid = uc $sid;

    print "Getting ORACLEHOME for '$sid'\n";

    my $retval;

    open my $ORATAB, '<', '/etc/oratab' or croak __PACKAGE__ . "::_setOracleHomeForSid(): Error opening /etc/oratab for reading: $!\n";

    LINE:
    while ( my $line = <$ORATAB> ){
        chomp $line;

        my ( $SID, $home, $notNeeded ) = split /:/, $line;

        next LINE unless (uc($SID) eq $sid);
   
        if ( $home ){
            $retval = $home;
# $self->{ 'oracleHome' } = $home;
            last LINE;
        } else {
            croak __PACKAGE__ . "::_setOracleHomeForSid(): Could not get ORACLEHOME for '$sid'!\n";
        }
    }
    close $ORATAB or croak __PACKAGE__ . "::_setOracleHomeForSid(): Error closing oratab: $!\n";
    return $retval;
}

=head1 AUTHOR

Marc Kandel C<< <mkandel at ariba.com> >>

=head1 LICENSE

Copyright 2012 Ariba, Inc.

=cut

1; # End of Module

__END__
