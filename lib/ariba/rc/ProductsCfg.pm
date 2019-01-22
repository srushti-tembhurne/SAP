# This file defines an object that accesses products.json configuration settings
# It is used by Globals.pm
# $Id: //ariba/services/tools/lib/perl/ariba/rc/ProductsCfg.pm#7 $

package ariba::rc::ProductsCfg;
use JSON;
use File::Basename;
use strict;
use warnings;

# Input 1 : $jsonfile is the file path to a json file to read from (else use /usr/local/ariba/globals/products.json)
sub new {
    my ($class, $jsonfile) = @_;

    my $self = {};
    bless ( $self, $class );

    $self->{'JSONFILE'} = $jsonfile;
    $self->{'DEBUG'} = $ENV{'DEBUG_PRODUCTSCFG'};
    return $self;
}

# Intended for lazy internal access
# Read the products.json file into the PRODUCTS_CFG instance member
sub _readProductsCfg {
    my ( $self ) = @_;

    if (defined $self->{'PRODUCTS_CFG'}) {
        # Nothing to do; it was already properly read in earlier
        return;
    }

    my $file;
    my $readstatus = 0;
    my $json_text;
    my $json;

    if ($self->{'JSONFILE'}) {
        $file = $self->{'JSONFILE'};
    }
    else {
        $file = "/usr/local/ariba/globals/products.json";
    }

    if (-e $file) {
        if ($self->{'DEBUG'}) {
            print "ProductsCfg: Located $file\n";
        }
        $readstatus = open(FILE, $file);
        if ($readstatus) {
            $json_text = join("", <FILE>);
            close FILE;
            $readstatus = 1;
        }
    }
    else {
        die "Error locating $file\n";
    }

    unless ($json_text) {
        die "Error reading $file\n";
    }

    eval { $json = JSON::decode_json($json_text); }; die "Error decoding products.json\n$@" if $@;
    $self->{'PRODUCTS_CFG'} = $json;
}

sub useBuckets {
    my ( $self, $product ) = @_;

    $self->_readProductsCfg();

    return $self->{'PRODUCTS_CFG'}{$product}{'useBuckets'};
}

sub fancyNameForProduct {
    my ( $self, $product ) = @_;

    $self->_readProductsCfg();

    return $self->{'PRODUCTS_CFG'}{$product}{'fancyName'} || $product;
}

sub isValidProductName {
    my ( $self, $product ) = @_;

    $self->_readProductsCfg();

    return $self->{'PRODUCTS_CFG'}{$product} ? 1 : 0;
}

# return an array of page filters used when upgrading a product
# the list is the set of common filters plus service specific filters
sub pageFiltersForProduct {
    my ( $self, $product, $service ) = @_;

    $self->_readProductsCfg();

    my @pageFilters;
    foreach my $element ('common', $service) {
        if ( exists $self->{'PRODUCTS_CFG'}{$product}{'pageFilters'}{$element} ) {
            push (@pageFilters, @{ $self->{'PRODUCTS_CFG'}{$product}{'pageFilters'}{$element} } );
        }
    }

    return @pageFilters;
}


sub oldSharedServiceProducts {
    my ( $self, $product ) = @_;

    $self->_readProductsCfg();

    my @list = ();
    my @prods = keys (%{$self->{'PRODUCTS_CFG'}});
    for my $p (@prods) {
        if ($self->{'PRODUCTS_CFG'}{$p}{'type'} eq "oldSharedService") {
            push (@list, $p);
        }
    }

    if (wantarray()) {
        return @list;
    }
    return \@list;
}

sub newSharedServiceProducts {
    my ( $self ) = @_;

    $self->_readProductsCfg();

    my @list = ();
    my @prods = keys (%{$self->{'PRODUCTS_CFG'}});
    for my $p (@prods) {
        if ($self->{'PRODUCTS_CFG'}{$p}{'type'} eq "newSharedService") {
            push (@list, $p);
        }
    }

    if (wantarray()) {
        return @list;
    }
    return \@list;
}

sub migrateProducts {
    my ( $self ) = @_;

    $self->_readProductsCfg();

    my @list = ();
    my @prods = keys (%{$self->{'PRODUCTS_CFG'}});
    for my $p (@prods) {
        if ($self->{'PRODUCTS_CFG'}{$p}{'migrate'}) {
            push (@list, $p);
        }
    }

    if (wantarray()) {
        return @list;
    }
    return \@list;
}

sub aspProducts {
    my ( $self ) = @_;

    $self->_readProductsCfg();

    my @list = ();
    my @prods = keys (%{$self->{'PRODUCTS_CFG'}});
    for my $p (@prods) {
        if ($self->{'PRODUCTS_CFG'}{$p}{'type'} eq "asp") {
            push (@list, $p);
        }
    }

    if (wantarray()) {
        return @list;
    }
    return \@list;
}

sub sharedServiceSourcingProducts {
    my ( $self ) = @_;

    $self->_readProductsCfg();

    my @list = ();
    my @prods = keys (%{$self->{'PRODUCTS_CFG'}});
    for my $p (@prods) {
        if ($self->{'PRODUCTS_CFG'}{$p}{'sharedServiceSourcing'}) {
            push (@list, $p);
        }
    }

    if (wantarray()) {
        return @list;
    }
    return \@list;
}

sub sharedServiceBuyerProducts {
    my ( $self ) = @_;

    $self->_readProductsCfg();

    my @list = ();
    my @prods = keys (%{$self->{'PRODUCTS_CFG'}});
    for my $p (@prods) {
        if ($self->{'PRODUCTS_CFG'}{$p}{'sharedServiceBuyer'}) {
            push (@list, $p);
        }
    }

    if (wantarray()) {
        return @list;
    }
    return \@list;
}

sub sharedServicePlatformProducts {
    my ( $self ) = @_;

    $self->_readProductsCfg();

    my @list = ();
    my @prods = keys (%{$self->{'PRODUCTS_CFG'}});
    for my $p (@prods) {
        if ($self->{'PRODUCTS_CFG'}{$p}{'sharedServicePlatform'}) {
            push (@list, $p);
        }
    }

    if (wantarray()) {
        return @list;
    }
    return \@list;
}

sub networkProducts {
    my ( $self ) = @_;

    $self->_readProductsCfg();

    my @list = ();
    my @prods = keys (%{$self->{'PRODUCTS_CFG'}});
    for my $p (@prods) {
        if ($self->{'PRODUCTS_CFG'}{$p}{'network'}) {
            push (@list, $p);
        }
    }

    if (wantarray()) {
        return @list;
    }
    return \@list;
}

sub rollingUpgradePreferredProducts {
    my ( $self ) = @_;

    $self->_readProductsCfg();

    my @list = ();
    my @prods = keys (%{$self->{'PRODUCTS_CFG'}});
    for my $p (@prods) {
        if ($self->{'PRODUCTS_CFG'}{$p}{'rollingUpgradePreferred'}) {
            push (@list, $p);
        }
    }

    if (wantarray()) {
        return @list;
    }
    return \@list;
}

sub rollingUpgradableProducts {
    my ( $self ) = @_;

    $self->_readProductsCfg();

    my @list = ();
    my @prods = keys (%{$self->{'PRODUCTS_CFG'}});
    for my $p (@prods) {
        if ($self->{'PRODUCTS_CFG'}{$p}{'rollingUpgradable'}) {
            push (@list, $p);
        }
    }

    if (wantarray()) {
        return @list;
    }
    return \@list;
}

sub fastDeploymentPreferredProducts {
    my ( $self ) = @_;

    $self->_readProductsCfg();

    my @list = ();
    my @prods = keys (%{$self->{'PRODUCTS_CFG'}});
    for my $p (@prods) {
        if ($self->{'PRODUCTS_CFG'}{$p}{'fastDeploymentPreferred'}) {
            push (@list, $p);
        }
    }

    if (wantarray()) {
        return @list;
    }
    return \@list;
}

sub webServerProducts {
    my ( $self ) = @_;

    $self->_readProductsCfg();

    my @list = ();
    my @prods = keys (%{$self->{'PRODUCTS_CFG'}});
    for my $p (@prods) {
        if ($self->{'PRODUCTS_CFG'}{$p}{'webServer'}) {
            push (@list, $p);
        }
    }

    if (wantarray()) {
        return @list;
    }
    return \@list;
}

sub hadoopProducts {
    my ( $self ) = @_;

    $self->_readProductsCfg();

    my @list = ();
    my @prods = keys (%{$self->{'PRODUCTS_CFG'}});
    for my $p (@prods) {
        if ($self->{'PRODUCTS_CFG'}{$p}{'hadoop'}) {
            push (@list, $p);
        }
    }

    if (wantarray()) {
        return @list;
    }
    return \@list;
}

sub archesProducts {
    my ( $self ) = @_;

    $self->_readProductsCfg();

    my @list = ();
    my @prods = keys (%{$self->{'PRODUCTS_CFG'}});
    for my $p (@prods) {
        if ($self->{'PRODUCTS_CFG'}{$p}{'arches'}) {
            push (@list, $p);
        }
    }

    if (wantarray()) {
        return @list;
    }
    return \@list;
}

sub activeActiveProducts {
    my ( $self ) = @_;

    $self->_readProductsCfg();

    my @list = ();
    my @prods = keys (%{$self->{'PRODUCTS_CFG'}});
    for my $p (@prods) {
        if ($self->{'PRODUCTS_CFG'}{$p}{'activeActive'}) {
            push (@list, $p);
        }
    }

    if (wantarray()) {
        return @list;
    }
    return \@list;
}

sub branchConfigSubFolder {
    my ( $self, $product ) = @_;

    $self->_readProductsCfg();

    my $c = $self->{'PRODUCTS_CFG'}{$product}{'branchConfigSubFolder'};
    $c = undef if (defined($c) && $c eq "undefined");
    return $c;
}
1;
