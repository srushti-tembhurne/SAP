#
#
# $Id: //ariba/services/tools/lib/perl/ariba/rc/BuildDef.pm#74 $
#
# A module to read in and manage all Build related Product definitions
#
#
package ariba::rc::BuildDef;

use File::Basename;
use File::Path;
use P4;

use ariba::rc::Globals;
use ariba::rc::ProductDefinition;

my $testing = 0;
my $debug   = 0;
my $allInfo;

#
# generate dependent module definition file, with exact modules version
# noted in the file
#
sub generateModulesDefinition {
    my ( $productName, $dir, $mirroredBuild ) = @_;

    if ( !-d $dir ) {
        mkpath( $dir, $debug );
    }

    print "Saving BranchName $ENV{'ARIBA_BUILD_BRANCH'} to $dir/BranchName\n";
    open ( FL, ">$dir/BranchName" );
    print FL "$ENV{'ARIBA_BUILD_BRANCH'}\n";
    close ( FL );

    my $moduleDefFile = "$dir/components.txt";

    open ( MOD, ">$moduleDefFile" )
      || die ( "Could not write $moduleDefFile, $!\n" );

    my @dependencies = objectsFor( "dependency" );
    my @buildObjs    = objectsFor( "build" );

    for my $buildObj ( @buildObjs ) {
        my $objName  = valueForKey( $buildObj, "modname" );
        my $objLabel = valueForKey( $buildObj, "label" );

        if ( $objName ) {
            $objName = lc ( $objName );

            for my $depend ( @dependencies ) {
                my $depName = valueForKey( $depend, "modname" );

                if ( lc ( $depName ) eq $objName ) {
                    my $version = valueForKey( $depend, "label" );
                    my $label   = ariba::rc::LabelUtils::exactLabel( $version );
                    my $p4dir   = $buildObj->p4dir();
                    if ( $mirroredBuild ) {
                        $label = $mirroredBuild;
                    }
                    print MOD "$depName $label $p4dir/...\n";
                    last;
                }
            }
        }

        my $p4dir = $buildObj->p4dir();
        if ( $p4dir =~ /\/\/ariba\/shared/ ) {
            print "Found shared component definition via p4dir\n";
            print MOD "shared $objLabel $p4dir/...\n";
        }
    }

    close ( MOD );
}

sub valueForKey {
    my ( $buildObj, $key ) = @_;

    my $val;
    my $tmpVal = $buildObj->$key();
    if ( defined ( $tmpVal ) && $tmpVal && $tmpVal ne "none" ) {
        $val = $tmpVal;
    }

    return $val;
}

#
# get a list of depot areas that we must sync to, label and set a client
# view etc.
#
# This sub now returns a hash. If you are just looking for the dir paths
# please use just the keys of the hash
#
sub depotAreas {
    my ( $buildInfo, $includeNoSync ) = @_;
    my %views;
    for my $buildObj ( @$buildInfo ) {
        #
        # accumulate client view information
        #
        $key = "p4dir";
        my $p4dir            = valueForKey( $buildObj, $key );
        my $labelUsedForSync = valueForKey( $buildObj, "labelUsedForSync" );

        my $sync = valueForKey( $buildObj, "sync" );
        if (defined $p4dir
            && ( ( defined $sync && $sync eq "yes" )
                || $includeNoSync )
          ) {
            $views{ $p4dir } = $labelUsedForSync;
        }
    }

    return \%views;
}

#
# create a client for release build, based on what areas of depots
# are needed for build.
#
sub createReleaseClient {
    my ( $buildInfo, $product, $client, $root ) = @_;

    my $viewsHash = depotAreas( $buildInfo, 1 );
    my @views     = keys %{ $viewsHash };
    my $comment   = "For release builds of $product";
    $client = Ariba::P4::createClient( $client, \@views, $root, $comment );

    Ariba::P4::switchClient( $client ) if ( $client );

    return $client;
}

#
# apply a label to areas of depot that are needed for the build.
# Expects P4CLIENT, P4PORT, P4TICKETS to be defined environment variables
#
sub createApplyBuildLabel {
    my ( $buildInfo, $label, $comment ) = @_;

    my $viewsHash = depotAreas( $buildInfo );
    my @views     = keys %$viewsHash;

    Ariba::P4::createLabel( $label, \@views, $comment );

    #Ariba::P4::applyLabel($label,$views);
    #return 1;

    # use the Perforce perl RunLabelSync API not Ariba::P4::applyLabel as the latter execs per component (2x faster)

    my $p4  = new P4;
    my $p4c = $ENV{ 'P4CLIENT' };
    my $p4p = $ENV{ 'P4PORT' };
    $p4->SetClient( $p4c );
    $p4->SetPort( $ENV{ 'P4PORT' } );
    $p4->SetTicketFile( $ENV{ 'P4TICKETS' } );
    $p4->Connect() or die ( "Failure connecting to perforce with P4CLIENT $pfc and P4PORT $p4p with ticket file $ticketfile" );

    for my $topdir ( @views ) {
        my $td               = $topdir . "/...";
        my $labelUsedForSync = $$viewsHash{ $topdir };
        $td .= "\@$labelUsedForSync" if ( $labelUsedForSync && $labelUsedForSync ne '' );
        $p4->RunLabelsync( "-l", $label, $td );
        if ( $p4->ErrorCount() ) {
            die ( $p4->Errors() . " during labelsync $label $td" );
        }
        # No real need to log warnings about label being in sync because we create the p4 client with the same label already
        #        if ($p4->WarningCount()) {
        #            print "Warning from Perforce labelsync $label $td : " . $p4->Warnings() . "\n";
        #        }
    }

    $p4->Disconnect();

    return 1;
}

#
# return objects that should be acted upon for a given reason,
# build/archive/configure etc.
#
sub objectsFor {
    my ( $reason ) = shift;

    return ariba::rc::ProductDefinition->objectsOfType( $reason );
}

#
# load in the definition file
# and create dependent module list
#
sub loadProductDefinition {
    my ( $info, $name, $reason, $release, $robot, $force, $mirroredBuild ) = @_;

    if ( $reason eq "archive" || $reason eq "build" ) {
        ariba::rc::LabelUtils::init( Ariba::P4::labels() );
    }
    my $prodInfo = $info->infoFor( $name, "latest" );
    if ( !defined ( $prodInfo ) ) {
        die "ERROR: Could not get information for product $name\n";
    }

    my $confFile = $prodInfo->definitionFile();
    my $productDef = ariba::rc::ProductDefinition->new( $name, $confFile, $mirroredBuild );

    if ( $reason ne "archive" && $reason ne "build" ) {
        $productDef->setEvaluateDependencies( 0 );
    }
    $productDef->readInConfig( $robot, $force, undef, $mirroredBuild );

    #
    # Create a client, if neccessary
    #
    if ( $reason eq "archive" || $reason eq "build" ) {

        my @buildObjs = objectsFor( "build" );
        if ( $release ) {
            createReleaseClient( \@buildObjs, $name, $ENV{ 'RELEASE_BUILD_CLIENT' }, $ENV{ 'ARIBA_SOURCE_ROOT' } );
        }

        for my $buildObj ( @buildObjs ) {
            #
            # Fix version of modules
            # (including support for the optional mirroredBuild override
            $key = "label";
            my $label = valueForKey( $buildObj, $key );

            if ( defined $label ) {
                $buildObj->setAttribute( $key, ariba::rc::LabelUtils::exactLabel( $label ) );
            }

            $key = "p4dir";
            my $p4dir = valueForKey( $buildObj, $key );
            if ( defined $p4dir ) {
                my $clientDir = Ariba::P4::depotToClient( $p4dir );
                $buildObj->setClientDir( $clientDir );

                $key = "envvar";
                my $name = valueForKey( $buildObj, $key );
                if ( defined $name ) {
                    $ENV{ $name } = $clientDir;
                }
            }
        }
    }

    #
    # second pass to expand all env vars
    #
    ariba::rc::ProductDefinition->expandEnvVarsInObjects();
}

sub initializeAllComponentInfo {
    my ( $branch ) = @_;

    if ( !defined ( $allInfo ) ) {
        my $infoFile = ariba::rc::ComponentInfo::componentInfoFile( $branch );
        $allInfo = ariba::rc::ComponentInfo->new( $infoFile );
        $allInfo->readInInfo();
    }

    return $allInfo;
}

#
# initialize a product with given name
#
sub initializeProduct {
    my ( $prod, $branch, $release, $reason, $robot, $force, $mirroredBuild ) = @_;

    $ENV{ 'ARIBA_BUILDNAME' } = "Unknown-Build"
      unless ( defined ( $ENV{ 'ARIBA_BUILDNAME' } ) );

    $ENV{ 'ARIBA_BUILD_BRANCH' }   = $branch;
    $ENV{ 'ARIBA_RC_PATH' }        = "/tmp";
    $ENV{ 'RELEASE_BUILD_CLIENT' } = ariba::rc::Globals::rcBuildClient( $prod, $branch );
    $ENV{ 'ARIBA_ARCHIVE_ROOT' }   = $ENV{ 'ARIBA_DEPLOY_ROOT' }
      || ariba::rc::Globals::archiveBuilds( $prod ) . "/$ENV{'ARIBA_BUILDNAME'}";

    my $ver = ariba::rc::Globals::versionNumberFromBranchName( $branch );
    $ENV{ 'ARIBA_BUILD_ROOT' } = $ENV{ 'ARIBA_BUILD_ROOT' }
      || ariba::rc::Globals::objDir( $prod, $ver );

    $ENV{ 'ARIBA_INSTALL_ROOT' } = "$ENV{'ARIBA_BUILD_ROOT'}/install";

    $ENV{ 'ARIBA_SOURCE_ROOT' } = $ENV{ 'ARIBA_SOURCE_ROOT' }
      || ariba::rc::Globals::srcDir( $prod, $ver );

    $ENV{ 'IS_SANDBOX' } = 1 if ( $branch =~ /\/\/ariba\/sandbox\// );

    if ( $reason eq "archive" || $reason eq "build" ) {
        #
        # load in P4 module only when needed.
        #
        eval "use Ariba::P4";
        die "Eval Error: $@\n" if ( $@ );
        eval "use Ariba::P5";
        die "Eval Error: $@\n" if ( $@ );
    }
    my $componentInfoLoc = $ENV{ 'ARIBA_COMPONENT_INFO_LOC' } || $branch;
    initializeAllComponentInfo( $componentInfoLoc );

    my $client = $release ? $ENV{ 'RELEASE_BUILD_CLIENT' } : $ENV{ 'P4CLIENT' };
    my $hostname = qx(hostname);
    chomp ( $hostname );

    print "\nBuild configuration:\n";
    printf "%20s %s\n", "P4 Branch",         $branch;
    printf "%20s %s\n", "P4 Client",         $client;
    printf "%20s %s\n", "Product Name",      $prod;
    printf "%20s %s\n", "Product Operation", $reason;
    printf "%20s %s\n", "Source Dir",        $ENV{ 'ARIBA_SOURCE_ROOT' };
    printf "%20s %s\n", "Build Dir",         $ENV{ 'ARIBA_BUILD_ROOT' };
    printf "%20s %s\n", "Build Host",        $hostname;
    printf "%20s %s\n", "Install Dir",       $ENV{ 'ARIBA_INSTALL_ROOT' };

    loadProductDefinition( $allInfo, $prod, $reason, $release, $robot, $force, $mirroredBuild );

    my @objects = objectsFor( $reason );

    if ( $reason eq "build" ) {
        my %ariba;
        my %third;
        my %others;

        foreach my $object ( @objects ) {
            if ( my $label = $object->label() ) {
                # It's a component if it has a "modname", otherwise it
                # is just loose source that may or may not be sync'd at
                # a label or "latest".

                if ( my $name = $object->modname() ) {
                    $name =~ s/^ariba\.//;
                    $label =~ s/^$name-//i;

                    if ( $name =~ /^(.*)\.\d+x$/ ) {
                        # This makes labels of the form foo-M.* match a
                        # component name of foo.Mx, where M is any number.
                        # This labelling scheme is used by component groups
                        # such as makesys that are related but need to be
                        # separate components for each major version M.

                        my $stem = $1;
                        $label =~ s/^$stem-//;
                    }

                    if ( $name =~ /^(.*)-((\d\.?)+)/ ) {
                        # This makes identifying component and labels of the type below.
                        #Note the '-' in the component name
                        #jre.x86.sun-1.4.2
                        #jre.x86.sun-010402.1.*

                        my $stem = $1;
                        $label =~ s/^$stem-//;
                    }

                    my $version = $label;

                    if ( $label eq "latest" && $name =~ /^(.*)-(\d+(\.\d+)+)$/ ) {
                        ( $name, $version ) = ( $1, $2 );
                        $third{ $name } = $version;
                    }
                    #until now we depend on the name of the component to define
                    #if a component is a third party component name or not
                    #Since we are missing a lot of components because of the
                    #Changes in naming 3rd Party, we take one more look at the
                    #location of the code to see, if that's from 3rdParty.

                    elsif ( $object->p4dir() =~ /\/\/ariba\/3rdParty\/.*/ ) {
                        $third{ $name } = $version;
                    } else {
                        $ariba{ $name } = $version;
                    }

                    # We need to save the version of the component so we can
                    # export this info during each component build, so the
                    # component build system can store the info for BOM files.
                    # If the component is fetched at latest, append .XXX to
                    # the version, where XXX is the most recent changelist
                    # pertinent to that component.  This is to protect against
                    # 3rd party components that update their bits.  Note that
                    # this might create a version with more than 3 sequences
                    # of digits in it (bom processing code should be written
                    # to handle any number of digit sequences).

                    if ( $label eq "latest" ) {
                        my $p4dir = $object->p4dir();
                        my $query = qx{p4 changes -s submitted $p4dir/... 2>&1};
                        if ( $? == 0 && $query =~ /^Change (\d+) / ) {
                            # $version still might be latest here if the component
                            # was built at head but wasn't a 3rd party component.
                            # In this case use 0.changelist so that it is ordered
                            # correctly amongst other instances of itself also at
                            # head, but less than a later labelled version (which
                            # is presumed to be 1.0 or greater).

                            if ( $version eq "latest" ) {
                                $version = "0.$1";
                            } else {
                                $version .= ".$1";
                            }
                        }
                    }

                    $object->setVersion( $version );
                } elsif ( my $envvar = $object->envvar() ) {
                    my $where = $object->p4dir() || "//unknown";
                    $others{ $envvar } = "$where ($label)";
                }
            }
        }

        if ( %ariba ) {
            print "\nAriba components used in this build:\n";

            foreach my $key ( sort keys %ariba ) {
                printf "   %-25s %s\n", $key, $ariba{ $key };
            }
        }

        if ( %third ) {
            print "\n3rd party components used in this build:\n";

            foreach my $key ( sort keys %third ) {
                printf "   %-25s %s\n", $key, $third{ $key };
            }
        }

        if ( %others ) {
            print "\nOther source included in this build:\n";

            foreach my $key ( sort keys %others ) {
                printf "   %-25s %s\n", $key, $others{ $key };
            }
        }
    }

    return @objects;
}

sub mailingList {
    my ( $product, $role, $branch ) = @_;
    
    unless($product eq "mobile"){
    initializeAllComponentInfo( $branch );

    my $prodInfo = $allInfo->infoFor( $product, "any" );
    my $email = $prodInfo->$role();

    return ( $email );
    }
}

sub getInformEmails {
    my ( $product ) = @_;
    my ( $devInform, $relInform, $relAdmin );
    my $branch = $ENV{ 'ARIBA_BUILD_BRANCH' };
    my ( $leadInform, $threshold ) = ariba::rc::BuildContactInfo::get_contact_info( $branch, undef, $product ) if ( defined ( $branch ) );
    if ( $leadInform ) {
        $relAdmin  = "DL_5310D2A5DF15DB206E007A94\@exchange.sap.corp";
        $relInform = $leadInform;
        $devInform = $leadInform;
    } else {
        $relAdmin  = mailingList( $product, "releaseAdminEmail" );
        $relInform = mailingList( $product, "releaseNotesEmail" );
        $devInform = mailingList( $product, "devEmail" );
    }
    return ( $devInform, $relInform, $relAdmin );
}

sub prodConfigDir {
    my ( $product, $branch ) = @_;

    initializeAllComponentInfo( $branch );

    my $prodInfo = $allInfo->infoFor( $product, "any" );
    my $confDir = dirname( $prodInfo->definitionFile() );

    $branch = $ENV{ 'ARIBA_BUILD_BRANCH' } || $branch;

    $confDir =~ s|\$ARIBA_BUILD_BRANCH|$branch|g;

    return ( $confDir );
}

sub prodConfigDefinitionFile {
    my ( $product, $branch ) = @_;

    initializeAllComponentInfo( $branch );

    my $prodInfo = $allInfo->infoFor( $product, "any" );
    my $defFile = $prodInfo->definitionFile();
    $branch = $ENV{ 'ARIBA_BUILD_BRANCH' } || $branch;

    $defFile =~ s|\$ARIBA_BUILD_BRANCH|$branch|g;

    return ( $defFile );
}

sub getBuildObjs {
    my ( $product, $branch, $reason ) = @_;

    $product ||= "tibco-cd";
    $branch  ||= "//ariba";
    $reason  ||= "build";
    $testing = 1;

    if ( $reason eq "archive" || $reason eq "build" ) {
        #
        # load in P4/P5 modules only when needed.
        #
        eval "use Ariba::P4";
        die "Eval Error: $@\n" if ( $@ );
        eval "use Ariba::P5";
        die "Eval Error: $@\n" if ( $@ );
    }

    # Turn off stupid Carp'ing from Ariba::Util
    $SIG{ __DIE__ }  = 'DEFAULT';
    $SIG{ __WARN__ } = 'DEFAULT';

    my $componentInfoLoc = $ENV{ 'ARIBA_COMPONENT_INFO_LOC' } || $branch;
    initializeAllComponentInfo( $componentInfoLoc );

    delete $ENV{ 'ARIBA_BUILD_ROOT' };
    delete $ENV{ 'ARIBA_SOURCE_ROOT' };
    delete $ENV{ 'ARIBA_DEPLOY_ROOT' };

    return initializeProduct( $product, $branch, 0, $reason );
}

sub _writeLastChange {
    my ( $file, $value ) = @_;

    if ( open ( CHANGE, ">$file" ) ) {
        print CHANGE "$value\n";
        close ( CHANGE );
    } else {
        warn "Can't write out latest changelist synced to $file: $!";
    }
}

sub _printP4Output {
    my ( @output ) = @_;

    # TMID 141522 : print output of the p4 sync command
    for my $line ( @output ) {
        if ( $line ) {
            if ( ref ( $line ) eq 'HASH' ) {
                my %h = %$line;

                for my $key ( sort keys %h ) {
                    my $v = $h{ $key };
                    print "\t$key: $v\n";
                }
                print "\n";
            } else {
                chomp ( $line );
                print "\t$line\n";
            }
        }
    }
}

# Pass in $asdir initially as 1 so as to try p4 sync as dir first and
# internally it will try again with $asdir as 0 to try as a file.
# We are thus being reactive to the case where product.bdf mentions component depot paths as files
# so as to not incur the overhead of using p4 fstat every time as was done in prior versions.
#
# Return 0 if successs or 1 if error
sub _sync_aux {
    my ( $p4, $blockRef, $p4dir, $asdir, $oldlabel, $force, $atChange ) = @_;

    my $cmdarg = "$p4dir";
    if ( $asdir ) {
        $cmdarg .= "/...";
    }

    my $label = valueForKey( $blockRef, "label" );
    my $syncLabel = $oldlabel || $label;

    if ( $syncLabel && $syncLabel !~ /latest/io ) {
        $cmdarg .= "\@$syncLabel";
        $blockRef->setLabelUsedForSync( $syncLabel );
    } else {
        # If the syncLabel is "latest", sync to the latest changelist
        # instead of syncing to 'head'. This is to ensure consistency
        # various components
        $cmdarg .= "\@$atChange";
        $blockRef->setLabelUsedForSync( $atChange );
    }

    print "p4 sync $cmdarg\n";

    my @output;
    my $warnings;
    if ( $force ) {
        @output = $p4->RunSync( "-f", $cmdarg );
    } else {
        @output = $p4->RunSync( $cmdarg );
    }

    # TMID 141522 : print output of the p4 sync command
    _printP4Output( @output );

    if ( $p4->ErrorCount() ) {
        my $msg = $p4->Errors();
        if ( $msg =~ /clobber writable file/ ) {
            print "Warning from Perforce sync $cmdarg : $msg\n";
        } else {
            die ( $p4->Errors() . " during sync $cmdarg" );
        }
    }
    if ( $p4->WarningCount() ) {
        $warnings = $p4->Warnings();
    }

    if ( $asdir ) {
        if ( $warnings ) {
            if ( $warnings =~ /no such file/ ) {
                # This may be the rare case where the product.bdf mentions files instead of dirs
                # Try again, next time without the /... part
                print "NOTE: The p4 sync system detected a p4 path to a file in the product config definition file: the error=$warnings\n";
                return _sync_aux( $p4, $blockRef, $p4dir, 0, $oldlabel, $force, $atChange );
            } elsif ( $warnings =~ /up-to-date/ ) {
                # Suppress the common case of the src being up to date.
                # This allows one to look at the log file and focus on
                # the files that were added/deleted/updated.
                return 0;
            }
            print $warnings;
            return 0;
        }
    } else {
        if ( $warnings ) {
            if ( $warnings =~ /error/ ) {
                print $warnings;
                return 1;
            } elsif ( $warnings =~ /up-to-date/ ) {
                # Suppress the common case of the src being up to date.
                # This allows one to look at the log file and focus on
                # the files that were added/deleted/updated.
                return 0;
            }
            print $warnings;
            return 0;
        }
    }
}

#
# Moved from make-build so as to reduce code in that script
# and this module contains other build/p4 related client api
#
# Return 0 if success
sub syncSource {
    my ( $buildInfo, $oldlabel, $force, $atChange, $latestChangeFile ) = @_;
    my $latestChange;

    printf ( "\nFetching updated source from Perforce... starting at %s\n", POSIX::strftime( "%H:%M:%S", localtime ) );

    # Find out the latest change from perforce if we didn't receive the atChange
    if ( !$atChange ) {
        my $out = `p4 changes -m1 -s submitted`;
        $out =~ /Change (\d+) .*/;
        $atChange = $1;
    }

    if ( $atChange ) {
        my $file = $ENV{ 'ARIBA_LATEST_CHANGE_FILE' } || $latestChangeFile || "";
        if ( $file ) {
            _writeLastChange( $file, $atChange );
        }
    } else {
        print "Unable to find the latest changelist from perforce\n";
        return 1;
    }

    my $p4  = new P4;
    my $p4c = $ENV{ 'P4CLIENT' };
    my $p4p = $ENV{ 'P4PORT' };
    $p4->SetClient( $p4c );
    $p4->SetPort( $ENV{ 'P4PORT' } );
    $p4->SetTicketFile( $ENV{ 'P4TICKETS' } );
    $p4->Connect() or die ( "Failure connecting to perforce with P4CLIENT $pfc and P4PORT $p4p with ticket file $ticketfile" );

    for my $blockRef ( @$buildInfo ) {
        my $sync = valueForKey( $blockRef, "sync" );
        next if $sync && $sync =~ /^no/o;

        my $p4dir = valueForKey( $blockRef, "p4dir" );
        $p4dir =~ s,\\,/,g;
        $p4dir =~ s,/\.\.\.$,,;

        _sync_aux( $p4, $blockRef, $p4dir, 1, $oldlabel, $force, $atChange );
    }
    $p4->Disconnect();
    return 0;
}

sub main {
    my @objs = getBuildObjs( @ARGV );

    for my $obj ( @objs ) {
        $obj->print();
    }

    my $configDir = "config";
    generateModulesDefinition( $product, $configDir );

    my $emailFor = "releaseNotesEmail";
    print "config dir for $product = ", prodConfigDir( $product, $branch ), "\n";
    unless($product eq "mobile"){
        print "mailing list $emailFor = ", mailingList( $product, $emailFor ), "\n";
    }
}

#main();

1;
