package ariba::rc::ProductDefinition;

use vars qw(@ISA);
use ariba::Ops::MemoryObject;
use ariba::rc::ComponentInfo;
use ariba::rc::LabelUtils;

@ISA = qw(ariba::Ops::MemoryObject);

use File::Basename;
use FileHandle;
use File::Temp;

my %inlineVariables;
my %exportedVariables;
my %objectStore;
my %seenThisComponentAlready;
my $debug = 0;
my $envStack;

#
# expand variables in a string based on hash with key value pairs
#
sub expandVariables
{
    my ($string, $env) = @_;

    if (defined($string)) {
    $string =~ s/(\$([0-9a-zA-Z_-]*))/defined $env->{$2}?$env->{$2}:$1/eg;
    }

    return $string;
}

#
# Add a variable to the list of the exported variables
#
sub addExportedVariables
{
    my ($variable, $value) = @_;
    $exportedVariables{$variable} = $value;
}

#
# expand variables in a string based on variables not exported to the env
# but set internally for local use.
#
sub expandInlineVariables
{
    my $string = shift;

    $string = ariba::rc::ProductDefinition::expandVariables(
                        $string, \%inlineVariables);

    return $string;
}

#
# from a line passed in, parse out variable = value, and set variable
# to value.
# export any variable requested via 'export' command
#
sub updateAndExportInlineVariables
{
    my $string = shift;
    my $line = ariba::rc::ProductDefinition::expandInlineVariables($string);
    if ($line =~ /=/o) {
		#
		# need to limit this to 2, so that a variable can have an = in its
		# value
		#
        my ($name,$val) = split(/=/, $line, 2);
        $name =~ s/^\s*([0-9a-zA-Z_-]*)\s*$/$1/;
        $val =~ s/^\s*(.*)\s*$/$1/;
        $inlineVariables{$name} = $val;
        $string = undef;
    } elsif ($line =~ /^\s*export/o) {
        my ($name,$val) = split(/\s+/, $line, 2);
        $val =~ s/^\s*(.*)\s*$/$1/;
        for my $var (split(/\s+/, $val)) {
            if (defined $inlineVariables{$var}) {
                $ENV{$var} = $inlineVariables{$var};
                $exportedVariables{$var} = $inlineVariables{$var};
            }
        }
        $string = undef;
    } elsif ($line =~ /^\s*$/o) {
        $string = undef;
    } else {
        $string = $line;
    }

    return $string;
}

sub pushEnvVar
{
    my ($varName, $newValue) = @_;

    my $origValue = $ENV{$varName};

    push(@{$envStack{$varName}}, $origValue);

    $ENV{$varName} = $newValue;
    $inlineVariables{$varName} = $newValue;

    return $origValue;
}

sub popEnvVar
{
    my ($varName) = @_;

    if (!@{$envStack{$varName}}) {
        die "ERROR: Stack underflow for env var $varName\n";
    }

    my $origValue = pop(@{$envStack{$varName}});

    my $curValue = $ENV{$varName};
    $ENV{$varName} = $origValue;
    $inlineVariables{$varName} = $origValue;

    return $curValue;
}

# -- class methods
#
# traverse through build and archive objects and expand all environment
# variables to their values.
#
sub expandEnvVarsInObjects
{
    my $class = shift;

    for my $type ("build", "archive", "configure") {
        my @objects = $class->objectsOfType($type);
        for my $obj (@objects) {
            for my $key ($obj->attributes()) {
                my $value = $obj->$key();
    
                if (defined($value)) {
                    $obj->setAttribute($key,
                    ariba::rc::ProductDefinition::expandVariables($value,
                                        \%ENV));
                    print "$key = ",$obj->$key(),"\n" if ($debug);
                }
            }
            print '=' x 65, "\n" if ($debug);
        }
    }
}

#
#
#
sub new
{
    my $class = shift;
    my $name = shift;
    my $confFile = shift;
    my $label = shift;
    my $ignoreEnv = shift;
    my $labelPattern = shift;

    my $self = $class->SUPER::new($name);
    bless($self, $class);

    my $privateBdfKey = "PRIVATE_BDF_" . $name;
    $privateBdfKey =~ s/\./_/g;
    if ($ENV{$privateBdfKey}) {
        $confFile = $ENV{$privateBdfKey};
    } else {
        $confFile =~ s|\$ARIBA_BUILD_BRANCH|$ENV{'ARIBA_BUILD_BRANCH'}|g;
    }

    $self->setName($name);
    $self->setConfFile($confFile);
    $self->setLabel($label);
    $self->setLabelPattern($labelPattern);
    $self->setEvaluateDependencies(1);

    unless ($ignoreEnv) {
        for my $name (sort(keys(%ENV))) {
            $inlineVariables{$name} = $ENV{$name};
        }
    }

    return $self;
}

#
# Make sure that the midlevel component is compatible
# with lower level components that this product is using
#
sub validateCompatibility
{
    my $class = shift;
    my $obj = shift;
    my $existingObj = shift;
    my $requester = shift;

    my $objLabel = $obj->label();
    my $overrideLabel = $existingObj->label();
    my $name = $obj->modname();
    my $file = $requester->confFile();
    my $rlabel = $requester->label();
    my $overrideName = $requester->name();

    return 1 if ($ENV{'ARIBA_SKIP_COMPONENT_COMPATIBILITY_CHECK'} ||
                 $ENV{'ARIBA_DO_NOT_VALIDATE_COMPONENT_COMPATIBILITY'});

    if (!ariba::rc::LabelUtils::isLabelInRange($overrideLabel, $objLabel)) {
        die "ERROR: component $name has incompatibility.",
        "  $objLabel (required) as specified by",
        "  $overrideName in $file\n",
        "  is not valid against $overrideLabel (requested $rlabel)\n";
    }
    return 1;
}

#
# stuff list of objects into a category/type assoc array, so objects of
# a particular type (build/archive/dependecy) can be easily recalled for
# processing later.
#
sub storeObjects
{
    my $class = shift;
    my $objects = shift;
    my $requester = shift;
    my $type = shift;
    my $checkDependencies = shift;
    my @storedObjects;

    print "saving $#{$objects} objects of type $type\n" if ($debug);
    for my $obj (@$objects) {
        #
        # Do not record a dependency more than once.
        #
        my $existingObj;
        if ($type eq "dependency" && defined($objectStore{$type})) {
            my @currentObjs = @{$objectStore{$type}};
            my $modname = $obj->modname();

            my $alreadyRecorded = 0;

            my $i = -1;
            for $curObj (@currentObjs) {
                $i++;
                if ($curObj->modname() eq $modname) {
                    $alreadyRecorded = 1;
                    $existingObj = $curObj;
                    splice(@{$objectStore{$type}}, $i, 1);
                    last;
                }
            }

            if ($alreadyRecorded && $checkDependencies) {
                ariba::rc::ProductDefinition->validateCompatibility($obj,
                        $existingObj,
                        $requester);
            }
        }
        if ($existingObj) {
            push(@storedObjects, $existingObj);

            #You have to store the object in the objectStore with in this loop,
            #Otherwise, if a dependency has been defined twice in the same component.bdf
            #file then that get's added twice to the $objectStore resulting in very
            #erratic results.

            push(@{$objectStore{$type}}, $existingObj);

        } else {
            push(@storedObjects, $obj);

            #same  as the above comment
            push(@{$objectStore{$type}}, $obj);

        }
        #$obj->print;
    }

    return \@storedObjects;
}

#
# give back the list of objects of a particular type (stored away
# previously, into one of the various buckets.
#
sub objectsOfType
{
    my $class = shift;
    my $type = shift;
    my @objs;

    if (defined($objectStore{$type})) {
        @objs = @{$objectStore{$type}};
    }

    return @objs;
}

#
# Clear the contents of %objectStore
#
sub clearObjectStore ()
{
    my $self = shift;
    %objectStore = ();
    %inlineVariables = ();
    %exportedVariable = ();
    %seenThisComponentAlready = ();
}

#
# based on what part of definition file is being parsed, set the
# category(bucket) type that objects should be stored away into.
#
sub setState
{
    my $self = shift;
    my $state = shift;

    $self->{'state'} = $state;

    my $type;

    if (defined($state)) {
    $state =~ m|(\w*)-|;
    $type = $1;
    } else {
    $type = $state;
    }

    #print "obj = $self, state = $state, type = $type\n";
    $self->setObjectType($type);
}

#
# extract (from p4) and open product definition file.
#
sub initDefinitionFile
{
    my $self = shift;

    my $depotFile = $self->confFile();

    if ($depotFile =~ m|^//|) {
        # Configuration file is in Perforce, extract it to local filesystem.

        my $file = File::Temp::tmpnam();
        my $label = $self->label();
        if (defined($label) && $label ne "latest") {
            $label = "\@" . ariba::rc::LabelUtils::exactLabel($label);
        } else {
            $label = "";
        }
        my $status = Ariba::P4::getFile($depotFile . $label, $file);
        if ($status == 0) {
            my $hack = new FileHandle ">$file";
            $hack->close();
        }
        return $file;
    }
    else {
        # They must be using -toolsroot option to point to their source
        # tree on the local filesystem.

        return $depotFile;
    }
}

#
# cycle through all the dependencies and get them recursively initialized.
#
sub processDependencies
{
    my $self = shift;
    my $dependencies = shift;
    my $robot = shift;
    my $force = shift;
    my $mirroredBuild = shift;

    if (!$self->evaluateDependencies()) {
        return;
    }

    if ($debug) {
        print "Processing $#{$dependencies} dependencies\n";
        $self->print();
        for my $depend (@$dependencies) {
            print "************** dependency: \n";
            $depend->print();
            print "**************\n";
        }
    }

    if ($ENV{'ARIBA_RESOLVE_PRODUCT_LABELS'})
    {
        #
        # Preprocess the labels and convert any product labels
        # to the respective component label
        #
        my %prodLabels;
        foreach my $depend (@$dependencies)
        {
            my $modname = $depend->modname();
            my $label = $depend->label();

            if ($prodLabels{$label} || ariba::rc::LabelUtils::isProductLabel($label))
            {
                my $compLabel;

                if ($prodLabels{$label})
                {
                    # We have already loaded this prodLabel
                    # No need to load it again
                    my %labelsInfo = %{$prodLabels{$label}};
                     $compLabel = $labelsInfo{$modname}{label};
                }
                else
                {
                    my $labelsRef;
                    ($compLabel,$labelsRef) = ariba::rc::LabelUtils::extractCompLabelFromProdLabel($modname,$label);
                    $prodLabels{$label} = $labelsRef;
                }

                # Set the component label
                print "[Pre-processing] Replacing the product label $label with $compLabel for the component $modname \n";
                $depend->setLabel($compLabel);
            }
        }
    } # End of pre-processing for resolving product labels

    if (my $traceReferences = $ENV{TRACE_COMPONENT_REFERENCES}) {
        my $pattern = qr/^($traceReferences)/i;
        my $referer = $self->name();
        for my $depend (@$dependencies) {
            my $component = $depend->modname() || "";
            next unless $component =~ $pattern;
            print STDERR "$component referenced by $referer\n";
        }
    }

    # In this first pass, we want to gather the confFile names of all
    # the dependencies and then fetch them all from P4 in one batch.
    # Letting them be fetched one by one in readInConfig is too slow.
    # This provides a big speedup because the top-level product.bdf
    # usually mentions nearly every component.  This doesn't help much
    # if the dependency graph is deep and each component only mentions
    # its immediate dependencies.
    my @toProcess;
    my @defFileNames;
    my $type = "dependency";
    for my $depend (@$dependencies) {

        my $alreadyProcessed = 0;
        if (defined($objectStore{$type})) {
            my @currentObjs = @{$objectStore{$type}};
            my $modname = $depend->modname();

            for $curObj (@currentObjs) {
                my $curModName = $curObj->modname();
                if ($curModName eq $modname) {
                    $alreadyProcessed = $curObj->processed();
                    last;
                }
            }
        } else {
            $alreadyProcessed = $depend->processed();
        }

        if (defined($alreadyProcessed)) {
            print "Module ", $depend->modname(),
                  " has processing = $alreadyProcessed\n" if $debug;
            next;
        }

        my $name = $depend->modname();
        my $versionPattern = $depend->label();
        my $version = ariba::rc::LabelUtils::exactLabel($depend->label());
        my $info = ariba::rc::ComponentInfo->infoFor($name, $version);
        my $defFile = $depend->configfile();

        if (!$defFile && !defined($info)) {
            die "ERROR: could not find definition file for component/product ".
                "$name, version $version. Exiting...\n";
        }

        $defFile = $info->definitionFile();

        pushEnvVar("ARIBA_BUILD_BRANCH", $info->p4SrcRootNode());
        if ($mirroredBuild) {
            $version = $mirroredBuild;
        }
        my $module = ariba::rc::ProductDefinition->new(
                $name,
                $defFile,
                $version,
                undef,
                $versionPattern);
        popEnvVar("ARIBA_BUILD_BRANCH");

        push @toProcess, [ $depend, $info, $module ];
        if ($module->confFile() =~ m|^//|) {
            my $name = $module->confFile();
            unless ($version eq "latest") {
                $name .= "\@$version";
            }
            push @defFileNames, $name;
        }
    }

    # Now that we have all the conffile names, fetch them all at once
    # from perforce.
    my $defFileHandles;
    if (scalar @defFileNames) {
        print "Batch fetch of ", scalar @defFileNames, " conf files\n" if $debug;
        eval {
            $defFileHandles = Ariba::P4::getAllFiles(@defFileNames);
        };
        if ($@) {
            print "warning: batch fetch of ", scalar @defFileNames, " conffiles failed: $@\nFalling back to non-batch mode.  This may slow things down.\n";
            $defFileHandles = {};
        }
    }

    # Second pass, now that we have the conffiles fetched, we read in
    # the configs and recurse for each component.
    foreach my $toProcess (@toProcess) {
        my ($depend, $info, $module) = @$toProcess;

        my $key = $module->confFile();
        my $version = $module->label();
        unless ($version eq "latest") {
            $key .= "\@$version";
        }
        my $fileHandle = $defFileHandles->{$key};
        unless ($fileHandle) {
            print "Batch fetch failed to return $key\n" if $debug;
        }

        $depend->setProcessed("starting");

        pushEnvVar("ARIBA_BUILD_BRANCH", $info->p4SrcRootNode());
        $module->readInConfig($robot, $force, $fileHandle, $mirroredBuild);
        popEnvVar("ARIBA_BUILD_BRANCH");

        $depend->setProcessed("done");
    }
}

#
# Load product definition file
#
sub readInConfig
{
    my $self = shift;
    my $robot = shift;
    my $force = shift;
    my $p4ConfigHandle = shift;
    my $mirroredBuild = shift;

    if (defined $seenThisComponentAlready{$self->confFile()} && $seenThisComponentAlready{$self->confFile()} eq $self->label()) {
        print ("This file has been processed already:", $self->confFile()," at revision " , $self->label(), "\n") if ($debug);
        return;
    }

    my $file;
    my $fh;
    my $confFileName = $self->confFile();
    if (($confFileName =~ m|^//|) && $p4ConfigHandle) {
        $file = $confFileName;
        $fh = $p4ConfigHandle;
        print "Using conffile from batch fetch for $confFileName\n" if $debug;
    } else {
        $file = $self->initDefinitionFile();
        $fh = new FileHandle $file;
        die("Could not open file $file, $!\n") unless $fh;
    }

    my $state = $self->state();

    # Declaring this here. Need this to store the list of dependencies parsed
    # under the 'dependency-definition-section'
    my @dependenciesList;

    while (my $line = <$fh>) {
        #
        # which section of config file is this?
        #
        if ($line =~ /^\s*#*.*\[\s*begin:\s*(.*)\s*\]/io) {
            if (defined $state) {
                die("Error in file $file (line:$.), ",
                        "begin $1 before end $state\n");
            }
            $state = $1;
            $self->setState($state);
            $endState = "\\[end: $state\\]";
            next;
        }

        if (!defined($state)) {
            next;
        }

        #
        # define the callback function to look at and process lines
        #
        if ($state eq "variable-definition-section") {
            ariba::Ops::MemoryObject->setStreamLineCallback(
                    \&ariba::rc::ProductDefinition::updateAndExportInlineVariables);
        } else {
            ariba::Ops::MemoryObject->setStreamLineCallback(
                    \&ariba::rc::ProductDefinition::expandInlineVariables);
        }

        my $objs = ariba::Ops::MemoryObject->createObjectsFromStream($fh,
                $endState);

        #
        # variable definition section should return no objects.
        # we consume the lines fully in updateAndExportInlineVariables
        # routine.
        #
        if ($#{$objs} < 0) {
            $state = $endState = undef;
            $self->setState($state);
            next;
        } else {
            print "got $#{$objs} objects in state = $state, type = ",
                  $self->objectType, ", name = ", $self->name, "\n" if ($debug);
        }

        #
        # override values of some attributes in this child objects.
        # however, for dependency let child control it fully. we will
        # simply not process the dependency the way child wants it, if we
        # already have it defined ourselves (look at storeObjects), else
        # only child can tell which grand children it's compatible with.
        #
        if ($state ne "dependency-definition-section") {
            my $label = $self->attribute('label');

            #This is for supporting sandboxes. If a component labels starts with
            # sb.some.label-, then that gets replaced by 'latest
            if ($label && $label =~ /^sb\..*/) {
                $self->setAttribute('label','latest');
            }

            if ($robot) # Mark the label as 'latest' if this is for a robot
            {
                # If there is a "force" option for this comp. Set the label to that value

                my $modname =  $self->name();

                if ($modname) {

                    my $range = $self->labelPattern();

                    if ($force->{$modname}) {
                        my $forceLabel = $force->{$modname}->{'label'};
                        my $labelMask = $force->{$modname}->{'labelPattern'};

                        # if a label pattern is specified in the
                        # %force hash, use this instead of the
                        # pattern from the BDF file;  this simulates
                        # updating labels in product.bdf by labelcomponents
                        $range = $labelMask if ($labelMask);

                        if (ariba::rc::LabelUtils::matchedLabels($range, [$forceLabel])) {
                            $self->setAttribute('label', 'latest');
                            print " ROBOT [$modname] is at $label [$range], forcing to $forceLabel (latest)\n" if ($debug);
                        } else {
                            print " ROBOT new label $forceLabel out of range for $modname $label [$range], will sync at $label\n" if ($debug);
                        }
                    } else {
                        print " ROBOT (no override) $modname will sync at $label [$range]\n" if ($debug);
                    }
                }
            }

            for my $object (@$objs) {

                my @attributes = $object->attributes;
                for my $attr (@attributes) {
                    my $overrideValue = $self->attribute($attr);
                    if (defined($overrideValue)) {
                        $object->setAttribute($attr, $overrideValue);
                    }
                }
            }
        }

        # This fix is to persist the dependency information while loading the product definition.
        #
        # If we are in the dependency definition section, store the
        # list of dependencies so that we can use that later while persisting
        # this component.
        if ($state eq "dependency-definition-section")
        {
            foreach my $obj (@$objs)
            {
                push (@dependenciesList, $obj->modname());
            }
        }

        # If we are in the build-definition-section, retrive the already stored list of dependencies
        # and add it to the build object that will be stored in the data store.
        #
        # The list of dependencies is set as a comma separated string.
        # For some reason, it didn't take in an array reference.
        #
        # To be consistent with the other attributes, set the values of dependencies
        # to 'none' if there are no dependencies.
        if ($state eq "build-definition-section")
        {
            foreach my $obj (@$objs)
            {
                    my $dependencies = join (",",@dependenciesList);
                    $dependencies = $dependencies || 'none';
                    $obj->setDepends($dependencies);
            }
        }

        print ">>> start processing $state for ", $self->name(), "\n" if ($debug);
        my $storedObjs = ariba::rc::ProductDefinition->storeObjects($objs,
            $self,
            $self->objectType(),
            $self->evaluateDependencies());

        #
        # If we were defining dependencies, read them in recursively now
        #
        if ($state eq "dependency-definition-section") {
            $self->processDependencies($storedObjs,$robot,$force, $mirroredBuild);
        }

        print ">>> done processing $state for ", $self->name(), "\n" if ($debug);

        $state = $endState = undef;
        $self->setState($state);

    }
    $fh->close();

    #
    # If the file was not equal to the configured conf file, it's a
    # temp file so delete it.
    #
    if ($file && $file ne $self->confFile()) {
        unlink($file);
    }
    $seenThisComponentAlready{$self->confFile()} = $self->label();
}

sub writeConfigFromHash
{
    my $filename = shift;
    my $hashRef = shift;

    my $fh = FileHandle->new($filename, "w");

    return 0 unless ($fh);

    print $fh "# This file was generated automatically by $0\n";

    #
    # hash is of the form
    #
    # hash->{"variable-definition-section"}->{"var1"} = "val1";
    # hash->{"variable-definition-section"}->{"var2"} = "val2";
    #
    # hash->{"dependency-definition-section"}->{"modname"} = ('m1', 'm2'...);
    # hash->{"dependency-definition-section"}->{"label"} = ('l1', 'l2'...);
    #
    # hash->{"dependency-definition-section"}->{"modname"} = ('m1', 'm2'...);
    # hash->{"build-definition-section"}->{"p4dir"} = ('p1', 'p2'...);
    # hash->{"build-definition-section"}->{"envvar"} = ('e1', 'e2'...);
    # hash->{"build-definition-section"}->{"modname"} = ('m1', 'm2'...);
    # hash->{"build-definition-section"}->{"label"} = ('l1', 'l2'...);
    # hash->{"build-definition-section"}->{"sync"} = ('yes', 'no'...);
    # hash->{"build-definition-section"}->{"destdir"} = ('d1', 'd2'...);
    # hash->{"build-definition-section"}->{"command"} = ('none', 'c2'...);
    #
    # hash->{"dependency-definition-section"}->{"modname"} = ('m1', 'm2'...);
    # hash->{"archive-definition-section"}->{"source"} = ('s1', 's2'...);
    # hash->{"archive-definition-section"}->{"destination"} = ('d1', 'd2'...);
    # hash->{"archive-definition-section"}->{"postprocess"} = ('none', 'p2'...);
    #
    # the call to reverse(sort(..)) is to make sure variable-definition is at the top...
    # variable-definition has to be on the top else you cannot set variables
    # which may affect the resolution of the dependency tree
    # a bit hackish but efficient :)
    for my $sectionName (reverse(sort(keys(%$hashRef)))) {
        print $fh "#\n";
        print $fh "# DO NOT CHANGE THIS TAG [begin: $sectionName]\n";
        print $fh "#\n";

        my @keys = keys(%{$hashRef->{$sectionName}});

        if ($sectionName eq "variable-definition-section") {
            for my $keyName (@keys) {
                print $fh "$keyName = ", $hashRef->{$sectionName}->{$keyName}, "\n";
                print $fh "export $keyName\n";
            }
        } else {
            my $values;

            print $fh "BEGIN TEMPLATE\n";
            for (my $i = 0; $i < @keys; $i++) {
                print $fh "$keys[$i]\n";
                push(@{$values->[$i]}, @{$hashRef->{$sectionName}->{$keys[$i]}});
            }
            print $fh "END TEMPLATE\n\n";

            my $numRecords = @{$values->[0]};

            for (my $j = 0; $j < $numRecords; $j++) {
                for (my $i = 0; $i < @keys; $i++) {
                    print $fh $values->[$i]->[$j], "\n";
                }
                print $fh "\n";
            }
        }

        print $fh "#\n";
        print $fh "# DO NOT CHANGE THIS TAG [end: $sectionName]\n";
        print $fh "#\n";
    }

    return 1;
}

sub writeToFile
{
    my ($self, $filename) = @_;

    my $rhProperties = {};
    foreach my $type (keys %objectStore)
    {
      foreach my $obj ($self->objectsOfType($type)) {
          foreach my $attr ($obj->attributes()) {
              my $value = $obj->attribute($attr) || 'none';
              push @{$rhProperties->{"$type-definition-section"}->{$attr}}, $value;
          }
      }
    }
    # specify the variables originally defined
    while (my ($k, $v) = each(%exportedVariables)) {
        $rhProperties->{'variable-definition-section'}->{$k} = $v;
    }
    writeConfigFromHash($filename, $rhProperties);
}

1;
