package ariba::rc::ProductUniverseAN;

# $Id: //ariba/services/tools/lib/perl/ariba/rc/ProductUniverseAN.pm#8 $

# This class represents the product universe. This acts as the link between the
# productDeifnition and the new CompMeta object.
#
#

use strict;
use warnings;
use ariba::rc::CompMeta;
use ariba::rc::ProductUniverse;
use ariba::rc::BuildDef ();
use File::Basename;
use File::Path;
use Data::Dumper;

use base ("ariba::rc::ProductUniverse");

my $ARIBA_INSTALL_ROOT = $ENV{'ARIBA_INSTALL_ROOT'};

# Input: compMeta is metadata for component whose build command is to be set as a function of the buildAll flag
# Input: buildAll flag when defined to non-zero then make sure the build command does not perform cleaning before building
sub _setProjectBuildCommand {
    my ($self, $compMeta, $dir, $buildAll) = @_;

    my $projname = $compMeta->getName();

    #
    # Workaround for a workaround...
    # TODO: Revisit later: 
    # There are some AN project components that cannot tolerate executing the build command
    # from their project directory. For example: see 'anbasedirectorybusinesslogic' Project.mk
    #
    # ValidationDisptacher has curious overloaded directrly structure shared with MigrationDispatcher
    # and is another bastard case.
    #
    # Many AN project components can tolerate this approach though.
    #
    # We desire to execute the build command from the per project for a couple reasons:
    # 1. the CompMeta->getSrcDir() is used as the root directory to search for Java packages
    #    We want to search at a lower level else we can create a pkgtocomps.txt index with many ambiguities.
    #    Note: the getSrcDir() is also the directory from which the build command is executed from.
    #
    # 2. The build log shows the location from where the projects are executed in. If we execute at the per project
    #    level, then the logs are more helpful.
    #
    if ($projname eq 'ANBaseDirectoryBusinessLogic' || $projname eq 'ValidationDispatcher') {
        if ($buildAll) {
            $compMeta->setBuildCommand("cd $dir && mp2 project-fullincbuild-$projname");
        }
        else {
            $compMeta->setBuildCommand("cd $dir && mp2 project-incbuild-$projname");
        }
        $compMeta->setCleanCommand("cd $dir && mp2 project-clean-$projname");
    }
    else {
        if ($buildAll) {
            $compMeta->setBuildCommand("mp2 project-fullincbuild-$projname");
        }
        else {
            $compMeta->setBuildCommand("mp2 project-incbuild-$projname");
        }
        $compMeta->setCleanCommand("mp2 project-clean-$projname");
    }
}

# The incr build system supports going into buildAll mode under certain conditions.
# In these conditions, the component build command that were previously defined will need to be
# redefined as no per component cleaning is needed.
# This method is for this purpose.
#
# Input 1: productUniverse containing all the comp metadata, where each contains a build command to possibly redefine.
# Input 2: buildAll flag when defined to non-zero then make sure the build command does not perform cleaning before building
sub updateCompMetaUniverseBuildCommand {
    my ($self, $productUniverse, $buildAll) = @_;

    foreach my $compMeta (@$productUniverse) {
        next if (! $compMeta);

        my $cmd = $compMeta->getBuildCommand();
        if ($cmd && $cmd =~ /mp2\sproject-/) {
            #
            # There are two kinds of components to consdider:
            #
            # 1. A component.bdf (aka hub) component; No redefinition of the build command is needed for this case.
            #
            # 2. An AN project (Project.mk described); there are two sub categories for this case (both cases need command redefintion):
            #  2A. A project that can tolerate being cd'd to and having mp2 command exected there (typical)
            #  2B. A project that can not tolerate being cd'd to; in this case the cd must be to the hub and the mp2 executed from there (atypical)
            #
            # We assert that the previous build command looks like 'cd to/some/hub/dir && mp2 project-incbuild-<projectname>'

            my $hubdir = $self->_getHubDirFromBuildCommand($compMeta);
            $self->_setProjectBuildCommand($compMeta, $hubdir, $buildAll);
        }
    }
}

# Return the path to the hub component that we must cd (or undef if there is no cd in the build command
sub _getHubDirFromBuildCommand {
    my ($self, $compMeta) = @_;

    my $cmd = $compMeta->getBuildCommand();
    if ($cmd =~ /^cd /) {
        # Example: cd /foo/bar && mps project-blah
        my @toks = split(/\s/, $cmd);
        return $toks[1];
    }
}

# In cases like network.service the build command is like: 'cd service && mp2 an i18n cprogs_Linux edi_maps catalog_resources'
# Return a tuple containing the directory name for this project (complete path to service) and the subdirectory name 'service'
sub _getProjectDir {
    my ($self, $compMeta, $cmd) = @_;

    my $dir = $compMeta->getSrcPath();
    my $subdir;
    if ($cmd =~ /cd [a-zA-Z0-9_-]* && /) {
        my @tokens = split(/ /, $cmd);
        $subdir = $tokens[1];
        $dir = "$dir/$subdir";
    }
    return ($dir, $subdir);
}

# OVERRIDE of base class implementation to deal with general and AN specific cases
#
# Input1: Array ref to the ProductDefinition
# Input 2: non-zero flag represents this is a full incr build
# Returns an array ref to CompMeta objects
sub getCompMetaUniverse {
    my ($self, $productDefinition, $buildAll) = @_;

    my @hubcomps = (); # (list of ref list); first element in iner list is parent ref to CompMeta; second...last are the the children ref to CompMeta
    $self->{'hubcomps'} = \@hubcomps;

    my @compMetaUniverse;

    foreach my $proddef (@$productDefinition) {
        my $compMeta = $self->_getCompMetaForComp($proddef);
        next if (! $compMeta);

        my $cmd = $compMeta->getBuildCommand();

        my $compName = $compMeta->getName();

        if ($cmd && $cmd =~ /mp2 /) {
            # This may be either:
            # - A bdf registered component with a build command like ariba.{network.util,common,rss}
            #   OR
            # - A a component listed in the build definiton section (typically not named) with a build command (networkservicehub)
            #
            # These are termed "AN hub components"
            # They contain sub projects which are to be exposed in the product universe
            #
            # Currently, there is a restriction that there will be at most one no named component
            # in the product definition section with a build command and we name it "ANProductHub"
            # for the lifetime of this build.

            # TODO: we need a scalable (not hard coded way) to discover components that have nested projects, but no other sources of their own;
            # In other words, we need to filter out which components do not needed indexing.
            if ((! $compName) || $compName eq "" || $compName eq "networkservicehub" || $compName eq "ariba.network.common" || $compName eq "ariba.network.util") {
                # Do not index this component - it's children will be (else we risk considering the parent as having ambiguous package ownerships with children)
                # Do not incrementally clean this component as it is a parent (it builds after it's children) and a clean will remove children artifacts (that may have just been built!).
                $compMeta->markAsHubDoNotIndex(); 
                # We may want to rename the networkservicehub or revert the change to the an-defintion.cfg so it doesn't have a name
                # Consistency is good
                if ((! $compName) || $compName eq "") {
                    $compMeta->setName("ANProductHub");
                }
            }

            my ($dir, $subdir) = $self->_getProjectDir($compMeta, $cmd);
            if (!chdir($dir)) {
                die("ProductUniverseAN: could not chdir to %s: %s", $dir, $!);
            }

            # Execute the command to extract all the metadata contained in the AN Makefile's
            # It is expected to create a file named $TMP/em.txt
            my $command = "mp2 emitmeta";
            qx "$command";
            my $ret = $? ;

            if ($ret > 0) {
                # perldoc -f system (must >> 8 to get actual value)
                $ret = $ret >> 8;
                die("ProductUniverseAN: could not acquire AN project metadata. Command=\"$command\" retcode=$ret\n");
            }

            if ($self->_isDebug()) {
                print "ProductUniverseAN: Ran command \"$command\" in $dir \n";
            }

            my $hublabel = $compMeta->getLabel();
            my $hubp4dir = $compMeta->getP4Dir();
            if ($subdir) {
                $hubp4dir = $hubp4dir . "/" .$subdir;
            }

            my $compmetalistref = $self->_getCompMetaForEachProject($dir, $hubp4dir, $hublabel, $buildAll);

            # Assign children as dependencies of the parent
            my $depsref = $compMeta->getDependencyNames();
            my @deps = ();
            # Add dependencies from the component.bdf
            for my $dn (@$depsref) {
                push (@deps, $dn);
            }
            # Add dependencies from the Project.mk
            for my $cm (@$compmetalistref) {
                push (@deps, $cm->getName());
            }
            $compMeta->setDependencyNames(\@deps);

            unshift (@$compmetalistref, $compMeta); # add parent to head of the list
            push (@{$self->{'hubcomps'}}, $compmetalistref);

            # Add the parent and children to the product universe
            push (@compMetaUniverse, @$compmetalistref);

            $compMeta->setBuildCommand("$cmd INCREMENTAL=true"); # The flag causes children to not be built again (just parent contributions)
            # Leave the cleanCommand undefined - we want to clean at children level only.
            $compMeta->markToAlwaysBuild(); # There may be makefile targets that have to run after children are built
        }
        elsif ($compName && $compName ne "") {
            # This is a case of a bdf registered component

            # Get the published artifact info reflected in Makefile|Build.mk...
            my @ca = ();
            push (@ca, $compMeta);
            $self->_updateCompMetaUniverseWithPublishedArtifactInfo(\@ca, 1, 1);

            # Now create a mapping between components and the artificats they publish
            # We use this mapping to translate dependencies on artifacts to the actual components themselves
            $self->_updateArtifactComponentMap($compMeta);

            # The following superclass code will look at the product definition build command 
            # and turn it from 'gnu make install' to 'gnu make clean' and set that as the cleanCommand
            $self->determineAndSetCleanCommand($compMeta);

            push (@compMetaUniverse,$compMeta);
        }
    }

    return \@compMetaUniverse;
} # getCompMetaUniverse

# Generate $ARIBA_INSTALL_ROOT/internal/build/componentshub.txt
# which contains name label depotpath for AN project components
sub createComponentsHubTxt {
    my ($self) = @_;

    my $dn = "$ARIBA_INSTALL_ROOT/internal/build";
    unless (-d $dn) {
        mkpath($dn);
    }

    my $fn = "$dn/componentshub.txt";
    if (-e $fn) {
        unlink($fn);
    }

    open HUBCOMPS, ">", $fn or die("ProductUniverseAN: could not open file $fn : $!");

    my @hubs = @{$self->{'hubcomps'}};
    for my $listref (@hubs) {
        my @list = @$listref;
        my $parentcm = $list[0];
        my $label = $parentcm->getLabel(); # Children projects of an "AN hub" getthe same label as the parent
        my $sz = @$listref;
        for (my $i = 1; $i < $sz; $i += 1) {
            my $childcm = $list[$i];
            my $cn = $childcm->getName();
            my $depotpath = $childcm->getP4Dir();
            print HUBCOMPS "$cn $label $depotpath/...\n";
        }
    }
    close(HUBCOMPS);
    print "ProductUniverseAN: Created \"$fn\"\n";
}

############ Internal methods below ##########

# Update a mapping between component and it's published artifacts
#
# There are AN projects that have PROJECT_DEPENDENT_JARS.
# We must be able to translate these jars (aka artifacts) to the components that produce them so that
# we can establish a proper build dependency such that if the component is changed (and is rebuilt) that
# the AN PROJECT can be rebuilt incrementally.
#
# Input 1: reference to CompMeta that may publish artifacts
sub _updateArtifactComponentMap {
   my ($self, $compMeta) = @_;

    if (! defined $self->{'artifactComponentMap'}) {
        my %map = ();
        $self->{'artifactComponentMap'} = \%map;
    }
    my $artifactpathsListRef = $compMeta->getPublishedArtifactPaths();
    if ($artifactpathsListRef) {
        my @a = @$artifactpathsListRef;
        for my $ap (@a) {
            my $bn = basename($ap);
            $self->{'artifactComponentMap'}->{$bn} = $compMeta->getName();
        }
    }
}

# Input 1: string path to directory of hub makefile
# Input 2: string hub p4dir to base per project p4dir off of
# Input 3: string hub label to use for each child project
# Input 4: non zero flag signifies this is a full incr build
# Return a reference to a list of CompMeta objects that describe each AN project
sub _getCompMetaForEachProject {
    my ($self, $hubdir, $hubp4dir, $hublabel, $buildAll) = @_;

    my $fn = "$ENV{'TMP'}/em.txt";
    if (-e $fn) {
        if ($self->_isDebug()) {
            print "ProductUniverseAN: emit meta returned the following:\n";
        }

        my @retlist = ();

        open INPUTFILE, $fn;
        my @entries = <INPUTFILE>;

        # Each line looks like following example:
        # ANDatafileIDL:JavaWebObjectsFramework:ariba/network/service/common/andatafileidl=IDLTemplateBase,XmlUtil 
        for my $e (@entries) {
            my @tokens = split(/:/, $e);
            my $projname = $tokens[0];
            my $projtype = $tokens[1];
            my $projdirdeplist  = $tokens[2];
            my @tokens2 = split(/=/, $projdirdeplist);
            my $projdir  = $tokens2[0];
            my $deplist  = $tokens2[1];

            if ($self->_isDebug()) {
                print "ProductUniverseAN emitmeta line: \"$e\"\n";
            }

            my $compMeta = ariba::rc::CompMeta->new();

            $compMeta->setName($projname);

            $compMeta->setLabel($hublabel);
            $compMeta->setP4Dir("$hubp4dir/$projdir");

            $self->_setProjectBuildCommand($compMeta, $hubdir, $buildAll);

            my $deps = $self->_formDependencyList($deplist);
            $compMeta->setDependencyNames($deps);

            $compMeta->setSrcPath("$hubdir/$projdir");

            my @artifactPaths = ();
            if ($projtype eq 'JavaWebObjectsFramework') {
                my $ap1 = "$ARIBA_INSTALL_ROOT/WebObjects/Frameworks/$projname.framework/Resources/Java/" . lc($projname) . ".jar";
                push (@artifactPaths, $ap1);
            }
            elsif ($projtype eq 'JavaWebObjectsApplication') {
                my $ap2 = "$ARIBA_INSTALL_ROOT/WebObjects/Apps/$projname.woa/Contents/Resources/Java/" . lc($projname) . ".jar";
                push (@artifactPaths, $ap2);
            }
            $compMeta->setPublishedArtifactPaths(\@artifactPaths);
            push (@retlist, $compMeta);
        }
        close(INPUTFILE);
        return \@retlist;
    }
    else {
        die("ProductUniverseAN: could not find the output file \"$fn\" which is supposed to be generated from the command \"mp2 emitmeta\". Check if WOTargets.mk is up to date\n");
    }
}

# Input 1: string comma separated names of dependencies that the named component has
#    (as returned as part of "mp2 emitmeta") These may be named project frameworks,
#    apps, WebObject libs (Java*), artifacts
# Return reference to list of dependencies that are names in the product universe
sub _formDependencyList {
    my ($self, $depslist) = @_;

    my @deps = split(/,/, $depslist);

    my @retlist = ();

    for my $d (@deps) {
        next if ($d eq "");
        next if ($d =~ /^Java/); # WebObjects component is not built so safe to skip (of course the per project mp2 will build against these though)

        if ($d =~ /.jar/i || $d =~ /.zip/i) {
            if ($self->{'artifactComponentMap'}) {
                my $c = $self->{'artifactComponentMap'}->{$d};
                if ($c) {
                    # There is a reference to an artifact - we will mark the dependency on the component that produces the artifact
                    push (@retlist, $c);
                    next;
                }
            }
        }
        else {
            push (@retlist, $d);
        }
    }
    return \@retlist;
}

1;
