package ariba::rc::ComponentInfo;

use vars qw(@ISA);
use ariba::Ops::MemoryObject;
use ariba::rc::LabelUtils;

@ISA = qw(ariba::Ops::MemoryObject);

use File::Basename;
use FileHandle;
use File::Temp;

my $debug = 0;
my @componentInfoObjects;

#
# class methods
#
sub new
{
    my $class = shift;
    my $infoFile = shift;
    my $label = shift;

    my $self = $class->SUPER::new($infoFile);
    bless($self, $class);

    $self->setInfoFile($infoFile);
    $self->setLabel($label);

    $self->print() if ($debug);

    return $self;
}

sub infoFor
{
    my $objOrClass = shift;
    my ($componentOrProduct, $version) = @_;

    #
    # TODO:
    # in case working without a component registry file and with p4
    # (make-deployment time, backward compatibility). return something 
    # useful.
    #
    if (!@componentInfoObjects && ref($objOrClass)) {
	my $defDir = dirname($objOrClass->infoFile()) . "/config";
	my $defFile = $componentOrProduct . "-definition.cfg";
	my $file = "$defDir/$defFile";

	unless (-f $file) {
		$file = "$defDir/product.bdf";
	}

	my $obj = ariba::Ops::MemoryObject->new($file);
	$obj->setDefinitionFile($file);
	return $obj;

    }

    my $returnObj = undef;
    for my $obj (@componentInfoObjects) {
	#$obj->print();
	if ($obj->name() eq $componentOrProduct) {
	    if ($ENV{'ARIBA_SKIP_COMPONENT_COMPATIBILITY_CHECK'}) {
		$returnObj = $obj;
	    } else {
		my $objVersion = $obj->version();
		if(ariba::rc::LabelUtils::isLabelInRange($version, $objVersion)) {
		    $obj->print() if ($debug);
		    $returnObj = $obj;
            if ($version eq 'latest' && defined($ENV{'ARIBA_RETURN_LAST_MATCHING_COMPONENT'})) {
                next;
            }
            elsif ($version ne 'latest' || !defined($ENV{'ARIBA_RETURN_LAST_MATCHING_COMPONENT'})) {
                last;
            }
		}
	    }
	}
    }

    return $returnObj;
}

#
# extract (from p4) and open product definition file.
#
sub initInfoFile
{
    my $self = shift;

    my $depotFile = $self->infoFile();

    if ($depotFile =~ m|^//|) {
        # Configuration file is in Perforce, extract it to local filesystem.

	my $file = File::Temp::tmpnam();
	my $label = $self->label();
	if (defined($label) && $label ne "latest") {
	    $label = "\@" . ariba::rc::LabelUtils::exactLabel($label);
	} else {
	    $label = "";
	}
	Ariba::P4::getFile($depotFile . $label, $file);
        return $file;
    }
    else {
        # They must be using ARIBA_COMPONENT_INFO_LOC to point to a checked
        # out file on the local filesystem.

        return $depotFile;
    }
}

#
# Load product definition file
#
sub readInInfo
{
    my $self = shift;

    my $path = $self->initInfoFile();
    my $fh = new FileHandle $path;
    return 0 unless($fh);

    my $objs = ariba::Ops::MemoryObject->createObjectsFromStream($fh);

    push(@componentInfoObjects, @$objs);

    print "Read in $#componentInfoObjects objects\n" if ($debug);

    $fh->close();
    if ($path ne $self->infoFile()) {
	unlink($path);
    }
    return 1;
}

sub writeOutInfoFromHash
{
	my $filename = shift;
	my $hashRef = shift;

	my $fh = FileHandle->new($filename, "w");

	return 0 unless ($fh);

	print $fh "# This file was generated automatically by $0\n";

	#
	# hash is of the form
	#
	# hash->{"name"} = ('n1', 'n2', ...);
	# hash->{"version"} = ('v1', 'v2', ...);
	# hash->{"definitionFile"} = ('d1', 'd2'...);
	# hash->{"p4SrcRootNode"} = ('p1', 'p2'...);
	# hash->{"devEmail"} = ('none', 'e2'...);
	# hash->{"releaseNotesEmail"} = ('none', 'r2'...);
	# hash->{"releaseAdminEmail"} = ('none', 'a2'...);
	#
	my @keys = keys(%{$hashRef});

	my $values;

	print $fh "BEGIN TEMPLATE\n";
	for (my $i = 0; $i < @keys; $i++) {
		print $fh "$keys[$i]\n";
		push(@{$values->[$i]}, @{$hashRef->{$keys[$i]}});
	}
	print $fh "END TEMPLATE\n\n";

	my $numRecords = @{$values->[0]};

	for (my $j = 0; $j < $numRecords; $j++) {
		for (my $i = 0; $i < @keys; $i++) {
			print $fh $values->[$i]->[$j], "\n";
		}
		print $fh "\n";
	}

	return 1;

}


sub componentInfoFile
{
    my ($branch) = @_;

    if ($ENV{PATH_TO_REGISTRY_FILE}) {
        # Be explicit: allow them to specify a file to use for the registry.

        return $ENV{PATH_TO_REGISTRY_FILE};
    }
    elsif (defined($branch) && $branch !~ m|^//|) {
        # This case is where ARIBA_COMPONENT_INFO_LOC was set.  I don't know
        # why that isn't just read in here, but it isn't.  See above for a
        # more explicit approach that doesn't assume a particular file name.

        return "$branch/registry.txt";
    }
    else {
        if (defined($branch)) {
            my $file = "$branch/registry.txt";
            if (Ariba::P4::fileExists($file)) {
                return $file;
            }
        }
        return "//ariba/tools/build/etc/registry.txt";
    }
}

sub main
{
    my $ci = ariba::rc::ComponentInfo->new("registry.txt");
    $ci->readInInfo();

    #use Ariba::P4;
    #ariba::rc::LabelUtils::init(Ariba::P4::labels());
    my $obj = $ci->infoFor($ARGV[0], $ARGV[1]);

    if (defined($obj)) {
	print "found object =\n";
	$obj->print();
    } else {
	print "No objects found\n";
    }
}

#main();

1;
