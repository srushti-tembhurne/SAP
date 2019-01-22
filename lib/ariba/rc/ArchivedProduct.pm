#
#
# A module that inherits from rc Product and provides information for
# archived-deployment
#
# $Id: //ariba/services/tools/lib/perl/ariba/rc/ArchivedProduct.pm#24 $
#
#
package ariba::rc::ArchivedProduct;
use strict;

use ariba::rc::Product;
use ariba::rc::ArchivedASPProduct;
use ariba::rc::ArchivedSharedServiceProduct;
use ariba::rc::Utils;

my %archivedProducts;
my $debug = 0;

# flag that governs whether or not to use archived products for which
# make-deployment returned with an error
my $useBrokenArchive = 0;

=head1 NAME

ariba::rc::ArchivedProduct - manage an archived products

=head1 SYNOPSIS

    use ariba::rc::ArchivedProduct;

    #
    # Load myself, just figure out what product i am based on where 
    # this script is running from
    #
    my $me = ariba::rc::Product->new();

    my $buildname = $me->buildName();
    my $service = $me->service();
    my $name = $me->name();

    #
    # Load product "an" for the same service
    #
    my $anProd;
    if (ariba::rc::ArchivedProduct->isArchived("an", $service)) {
        $anProd = ariba::rc::ArchivedProduct->new("an", $service);
    }


    #
    # when was it archived?
    #
    my $time = localtime($anProd->archivedOn());
    print "Product ", $anProd->name(), " was archived on $time\n";


=head1 DESCRIPTION

    ArchivedProduct is a subclass of Product. It inherently knows where
    to find each product, and can load them up, from inside any other
    product.

=head1 Additional API routines

Archived Product provides additional information like :

=over 4

=cut

sub new
{
	my $class = shift;
	my $prodname = shift;
	my $service = shift;
	my $buildname = shift;
	my $customer = shift;
    my $opsConfigLabel = shift;
	my $cluster = shift;

    my $realSelf;

    unless ( $prodname ) {
        my $configDir = ariba::rc::Product->_computeDeployRootFromNothing() . "/" .
                                            ariba::rc::Product->_configSubDirectory();
        $prodname = getProductName($configDir);
    }

    print "In creating $class new() for $prodname, $service\n" if ($debug);

    if ( ariba::rc::Globals::isASPProduct($prodname) ) {
        $realSelf = ariba::rc::ArchivedASPProduct->new($prodname, $service, $buildname, $customer);
    } else {
        $realSelf = ariba::rc::ArchivedSharedServiceProduct->new($prodname, $service, $buildname, $opsConfigLabel, $cluster);
    }

    print "    In creating $class new() for $prodname, $service but after, installdir = ", $realSelf->installDir(),"\n" if ($debug);

    return $realSelf;
}

=pod

=item * archivedProductsList()

a list of all products archived by rc

=cut
sub archivedProductsList
{
	my $class = shift;
	my $service = shift;
	my $product = shift;
	my $customer = shift;

	unless ( $service ) {
		my $configDir = ariba::rc::Product->_computeDeployRootFromNothing() . "/" .
			ariba::rc::Product->_configSubDirectory();
		$service = getServiceName($configDir);
	}

	my @products;

	unless (defined($customer)) {
		push(@products, ariba::rc::ArchivedSharedServiceProduct->archivedProductsList($service, $product));
	}

	push(@products, ariba::rc::ArchivedASPProduct->archivedProductsList($service, $product, $customer));

	return (@products);
}

sub exists {
        my $class = shift;
	my @args = @_;

        return $class->isArchived(@args);
}


sub isArchived {
        my $class = shift;
        my @args = @_;

        return ariba::rc::ArchivedSharedServiceProduct->isArchived(@args) ||
                ariba::rc::ArchivedASPProduct->isArchived(@args);
}

=pod

=item * archivedOn()

when was the product archived. Returns time in secs since epoch.

=cut
sub archivedOn
{
	my $self = shift;

	my $dir = $self->configDir();

	return((lstat($dir))[9]);
}

=pod

=item * archiveDir()

where the product has been archived by rc.

=cut
sub archiveDir
{
	my $self = shift;

	return($self->installDir());
}

sub useBrokenArchive {
	my $class = shift;

	$useBrokenArchive = shift;
}

sub deploymentInProgress {
	my $self = shift;

	my $progressMarkerFile = ariba::rc::Globals::inProgressMarker();
	my $archiveDir = $self->archiveDir();

	if (-e "$archiveDir/$progressMarkerFile") {
		return 1;
	}

	return;
}

sub deploymentFailed {
	my $self = shift;

	my $brokenArchiveMarker = ariba::rc::Globals::brokenArchiveMarker();
	my $archiveDir = $self->archiveDir();

	if ($self->deploymentInProgress()) { # deployment hasn't failed yet
		return;
	}

	if (-e "$archiveDir/$brokenArchiveMarker") {
		return 1;
	}

	return;
}

sub _getLatestArchivedInfo
{
	my $class = shift;
	my $dir = shift;

	my $buildname;

	opendir(DIR, "$dir") || return undef;
	my @dirs = grep(!/^\./, readdir(DIR));
	closedir(DIR);

	my $progressMarkerFile = ariba::rc::Globals::inProgressMarker();
	my $brokenArchiveMarker = ariba::rc::Globals::brokenArchiveMarker();

	my $last=0;
	for my $subdir (@dirs) {
		next if (! -d "$dir/$subdir" || $subdir =~ /^\./);

		# reject in-progress or incomplete deployments
		next if -e "$dir/$subdir/$progressMarkerFile";

		#FIXME 
		# These are two hacks for personal services.  Since ps
		# use archivedir as installdir, there will be symlinks
		# (1) and other directories not belonging to builds (2).
		# 

		# 1) reject symlinks
		next if (-l "$dir/$subdir");

		# 2) reject 
		next unless -d ( "$dir/$subdir/config" );


		# reject broken builds
		if ( !$useBrokenArchive && -e "$dir/$subdir/$brokenArchiveMarker" ) {
			print "=" x 77, "\n";
			print "Notice: ariba::rc::ArchiveDeployment _getLatestArchivedInfo() skipping $dir/$subdir because of $brokenArchiveMarker. Please scrub the build if no longer needed to avoid this message.\n";
			print "=" x 77, "\n";
			next;
		}

		my $cur = (lstat("$dir/$subdir"))[9];
		#print "inspecting $subdir under $dir ($cur , $last)\n";
		if ($cur > $last) {
			$last = $cur;
			$buildname=$subdir;
		}
	}

	return($buildname);
}

sub setBuildName
{
	my $self = shift;
	my $buildname = shift;

	$self->__setBuildNamePassedInOrFromDisk($buildname);
}

sub setProductName
{
	my $self = shift;
	my $prodname = shift;

	$self->__setProductNamePassedInOrFromDisk($prodname);
}

sub setServiceName
{
	my $self = shift;
	my $service = shift;

	$self->__setServiceNamePassedInOrFromDisk($service);
}

return 1;

__END__

=pod

=head1 AUTHOR

Manish Dubey <mdubey@ariba.com>

=head1 SEE ALSO

ariba::rc::Product 

ariba::rc::InstalledProduct

ariba::rc::PersonalProduct

=cut

