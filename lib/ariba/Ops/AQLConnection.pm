#
#
# $Id: //ariba/services/tools/lib/perl/ariba/Ops/AQLConnection.pm#2 $
#
# A package to keep AQL connection information.
#
#

package ariba::Ops::AQLConnection;

use strict;

use ariba::rc::Product;



my $AQL_DIRECT_ACTION_SUFFIX = 'ad/AqlQuery/MonitorActions';



#
# class methods
#

sub newFromProduct
{
	my $class = shift;
	my $product = shift;

	
	return undef unless ($product);


	my $self = {};

	bless($self,$class);

	$self->setProduct($product);


	return $self;
}

sub setProduct
{
	my $self = shift;
	my $product = shift;

	$self->{product} = $product;
}

sub product
{
	my $self = shift;

	return $self->{product};
}


sub directActionUrl 
{
	my $self = shift;

	my $product = $self->{product};
	my $frontDoor = $product->default("VendedUrls.FrontDoor");

	return $frontDoor . '/' . $AQL_DIRECT_ACTION_SUFFIX;

}

1;
