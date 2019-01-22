package ariba::monitor::ProductStatus;

# $Id: //ariba/services/monitor/lib/ariba/monitor/ProductStatus.pm#10 $
#
# This class is used to represent a product's status.
# It's currently used over the wire, allocated by cgi-bin/object-server?type=status-for-product
# and consumed by all the clients that talk to that program.
#
# In addition, it's the backing store for planned-downtime, and for each product's status.

use strict;
use base qw(ariba::Ops::PersistantObject);

use ariba::monitor::misc;

###############
# class methods

sub newWithDetails {
	my $class    = shift;
	my $product  = shift;
	my $service  = shift;
	my $customer = shift;
	my $buildName = shift;

	my $instance = join('-', $service, $product);

	# Append customer if we get passed it.
	if ($customer) {
		$instance .= "-$customer";
	}

	my $self = $class->SUPER::new($instance);

	$self->setProductName($product);
	$self->setService($service);
	$self->setCustomer($customer);
	$self->setBuildName($buildName);
	$self->_clean();

	return $self;
}

sub dir {
	my $class = shift;

	return ariba::monitor::misc::statusDir();
}

sub statusAndLastChange {
	my $self = shift;

	if ($self->status()) {
		return ($self->status(), $self->lastChange());
	} else {
		return ('unknown', time());
	}
}

sub writeStatus {
	my $self   = shift;
	my $status = shift;

	my $oldStatus = $self->status();

	$self->setStatus($status);

	if ( ($oldStatus && $oldStatus ne $status) || !$self->lastChange() ) {
			$self->setLastChange(time());
	}


	$self->save();

	return $status;
}

#
# these function overrides add subdirectories to the backing store
#
sub _computeBackingStoreForInstanceName {
	my $class = shift;
	my $instanceName = shift;

	#
	# XXX -- this relies on products and services not having
	# dashes (-) in the name.  This is true of products and
	# services today.  customers do have dashes in them, but
	# but since customer is last, we just pass 3 as the third
	# arg to split.
	#
	my ($service, $product, $customer) = split(/-/, $instanceName, 3); 
	my $file = $class->dir() . "/$service/$product";
	$file .= "/$customer" if ($customer);
	$file .= "/$instanceName";

	return($file);
}

sub listObjects {
	my $class = shift;
	my @list = ();

	foreach my $i ($class->instancesInDir()) {
		if($class->objectWithNameExists($i)) {
			push(@list, $class->new($i));
		}
	}

	return ((wantarray()) ? @list : \@list);
}

sub instancesInDir {
	my $class = shift;
	my $dir = shift || $class->dir();
	my %ret;
	my $DIR;

	opendir($DIR, $dir);
	while(my $f = readdir($DIR)) {
		next if($f =~ /^\.+$/);
		if( -d "$dir/$f" ) {
			foreach my $i ($class->instancesInDir("$dir/$f")) {
				$ret{$i} = 1;
			}
		} elsif( -f "$dir/$f") {
			$ret{$f} = 1;
		}
	}
	close($DIR);

	return(sort keys(%ret));
}

1;

__END__

=head1 NAME

ariba::monitor::ProductStatus

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 AUTHOR

Daniel Sully <dsully@ariba.com>

=head1 SEE ALSO

ariba::Ops::PersistantObject

=cut
