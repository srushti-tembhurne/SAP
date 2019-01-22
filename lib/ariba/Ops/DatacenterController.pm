#!/usr/local/bin/perl

package ariba::Ops::DatacenterController;

use strict;
use warnings;

#
# DatacenterController to check specific datacenters and multiple datacenter groupings
#

# all production datacenters (primary and secondary)
sub prodDatacenters {
    return ("snv", "bou", "eu1", "eu2", "us1", "ru1", "ru2", "cn1", "cn2", "uae1", "ksa1", "ksa2", "sc1-ms", "us1-ms", "eu1-ms",
            "eu2-ms", "ru1-ms", "ru2-ms", "cn1-ms", "cn2-ms", "uae1-ms", "uae2-ms", "ksa1-ms", "ksa2-ms", "snv2");
}

# all primary production datacenters
sub prodDatacentersOnly {
    return ("snv", "eu1", "ru1", "cn1", "uae1", "ksa1", "sc1-ms", "eu1-ms", "ru1-ms", "cn1-ms", "uae1-ms", "ksa1-ms");
}

# all MS production datacenters
sub prodAllMSDatacenters {
    return (prodUSMSDatacenters(), prodEUMSDatacenters(), prodRUMSDatacenters(), prodCNMSDatacenters(), prodUAEMSDatacenters(),
            prodKSAMSDatacenters());
}

# all production datacenters in US
sub prodUSDatacenters {
    return ("snv", "bou", "us1", "snv2");
}

# all production datacenters in EU
sub prodEUDatacenters {
    return ("eu1", "eu2");
}

# all production datacenters in CN
sub prodCNDatacenters {
    return ("cn1", "cn2");
}

# all production CS datacenters in UAE+KSA, not sure if this is needed?
sub prodUAEKSADatacenters {
    # NOTE:  ksa2 is the DR for both uae1 and ksa1.
    return ("uae1", "ksa1", "ksa2");  ## ramjr - checked.
}

# all production CS UAE datacenters
sub prodUAEDatacenters {
    # NOTE:  ksa2 is the DR for both uae1 and ksa1.
    return ("uae1", "ksa2"); # ramjr - checked but is this right?  Yes, I believe so. ;>
}

# all production CS datacenters in KSA
sub prodKSADatacenters {
    return ("ksa1", "ksa2");  ## ramjr - checked.
}

# Deprecated all production datacenters in ProdMS
sub prodSCDatacenters {
    warn "prodSCDatacenters() is deprecated, use prodUSMSDatacenters()";
    return prodUSMSDatacenters (@_);
}

# all production US Micro Services datacenters 
sub prodUSMSDatacenters {
    return ("sc1-ms", "us1-ms");
}

# all production EU Micro Services datacenters 
sub prodEUMSDatacenters {
    return ("eu1-ms", "eu2-ms");
}

# all production RU Micro Services datacenters
sub prodRUMSDatacenters {
    return ("ru1-ms", "ru2-ms");
}

# all production CN Micro Services datacenters
sub prodCNMSDatacenters {
    return ("cn1-ms", "cn2-ms");
}

# all production UAE Micro Services datacenters
sub prodUAEMSDatacenters {
    return ("uae1-ms", "uae2-ms");  ## ramjr - checked.
}

# all production KSA Micro Services datacenters
sub prodKSAMSDatacenters {
    return ("ksa1-ms", "ksa2-ms",);  ## ramjr - checked.
}

# all production datacenters in RU
sub prodRUDatacenters {
    return ("ru1", "ru2");
}

sub replicationDatacenters {
    ## Just adding eu3 & ru3 as replication datacenter for EU & RU incase we add in future & it may have different name too 
    return ("bou", "eu3", "ru3"); 
}

sub prodDatacentersDR {
    return ("eu2", "eu2-ms", "us1", "ru2", "ru2-ms", "cn2", "ksa2", "us1-ms", "cn2-ms", "uae2-ms", "ksa2-ms"); # ramjr - checked.
}

# primary production datacenter in SNV
sub prodUSDatacenterPrimary {
    return ("snv");
}

# all devlab type datacenters
sub devlabDatacenters {
    return ("devlab", "lab1", "lab2", "lab3", "sc1-lab1");
}

sub sc1lab1Datacenter {
    return  ("sc1-lab1");
}

# all devlab datacenters in US
sub devlabDatacenterOnly {
    return ("devlab");
}

# all devlab datacenters in EU
sub devlabEUDatacenterOnly {
    return ("lab1", "lab2", "lab3");
}

# all opslab datacenters (primary and secondary)
sub opslabDatacenters {
    return ("opslab", "opslabdr");
}

# secondary opslab datacenter
sub opslabDatacentersDR {
    return ("opslabdr");
}

# primary opslab datacenter
sub opslabDatacenterOnly {
    return ("opslab");
}

# all sales type of datacenters
sub salesDatacenters {
    return ("sales");
}

sub isProductionDatacenters {
    my $dc = shift;

    return (( scalar grep {$_ eq $dc} prodDatacenters()) ? 1 : 0 );
}

sub isProductionDatacentersOnly {
    my $dc = shift;

    return (( scalar grep {$_ eq $dc} prodDatacentersOnly()) ? 1 : 0 );
}


sub isProductionSCDatacenters {
    warn "isProductionSCDatacenters() is deprecated, use isProductionUSMSDatacenters()";
    return isProductionUSMSDatacenters(@_);
}

sub isProductionUSMSDatacenters {
    my $dc = shift;

    return (( scalar grep {$_ eq $dc} prodUSMSDatacenters()) ? 1 : 0 );
}

sub isProductionEUMSDatacenters {
    my $dc = shift;

    return (( scalar grep {$_ eq $dc} prodEUMSDatacenters()) ? 1 : 0 );
}

sub isProductionRUMSDatacenters {
    my $dc = shift;

    return (( scalar grep {$_ eq $dc} prodRUMSDatacenters()) ? 1 : 0 );
}

sub isProductionCNMSDatacenters {
    my $dc = shift;

    return (( scalar grep {$_ eq $dc} prodCNMSDatacenters()) ? 1 : 0 );
}

# For UAE
sub isProductionUAEDatacenters {
    my $dc = shift;

    return (( scalar grep {$_ eq $dc} prodUAEDatacenters()) ? 1 : 0 );
}

# For UAE-MS
sub isProductionUAEMSDatacenters {
    my $dc = shift;

    return (( scalar grep {$_ eq $dc} prodUAEMSDatacenters()) ? 1 : 0 );
}

sub isProductionKSADatacenters {
    my $dc = shift;

    return (( scalar grep {$_ eq $dc} prodKSADatacenters()) ? 1 : 0 );
}

sub isProductionKSAMSDatacenters {
    my $dc = shift;

    return (( scalar grep {$_ eq $dc} prodKSAMSDatacenters()) ? 1 : 0 );
}

sub isProductionAllMSDatacenters {
    my $dc = shift;

    return (( scalar grep {$_ eq $dc} prodAllMSDatacenters()) ? 1 : 0 );
}

sub isProductionUSDatacenters {
    my $dc = shift;
    
    return (( scalar grep {$_ eq $dc} prodUSDatacenters()) ? 1 : 0 );
}

sub isProductionEUDatacenters {
    my $dc = shift;

    return (( scalar grep {$_ eq $dc} prodEUDatacenters()) ? 1 : 0 );
}

sub isProductionRUDatacenters {
    my $dc = shift;

    return (( scalar grep {$_ eq $dc} prodRUDatacenters()) ? 1 : 0 );
}

sub isProductionCNDatacenters {
    my $dc = shift;

    return (( scalar grep {$_ eq $dc} prodCNDatacenters()) ? 1 : 0 );
}

sub isProductionUAEKSADatacenters {
    my $dc = shift;

    return (( scalar grep {$_ eq $dc} prodUAEKSADatacenters()) ? 1 : 0 );
}

sub isReplicationDatacenters {
    my $dc = shift;

    return (( scalar grep {$_ eq $dc} replicationDatacenters()) ? 1 : 0 );
}

sub isProdDatacentersDR {
    my $dc = shift;

    return (( scalar grep {$_ eq $dc} prodDatacentersDR()) ? 1 : 0 );
}

sub isDevlabDatacenters {
    my $dc = shift;

    return (( scalar grep {$_ eq $dc} devlabDatacenters()) ? 1 : 0 );
}

sub isSc1lab1Datacenters {
    my $dc = shift;

    return (( scalar grep {$_ eq $dc} sc1lab1Datacenter()) ? 1: 0 );
}

sub isDevlabDatacenterOnly {
    my $dc = shift;
    
    return (( scalar grep {$_ eq $dc} devlabDatacenterOnly()) ? 1 : 0 );
}

sub isDevlabEUDatacenterOnly {
    my $dc = shift;

    return (( scalar grep {$_ eq $dc} devlabEUDatacenterOnly()) ? 1 : 0 );
}

sub isDevlabRUDatacenterOnly {
    my $dc = shift;

    return (( scalar grep {$_ eq $dc} devlabRUDatacenterOnly()) ? 1 : 0 );
}

sub isOpslabDatacenters {
    my $dc = shift;

    return (( scalar grep {$_ eq $dc} opslabDatacenters()) ? 1 : 0 );
}

sub isOpslabDatacenterOnly {
    my $dc = shift;

    return (( scalar grep {$_ eq $dc} opslabDatacenterOnly()) ? 1 : 0 );
}

sub isOpslabDatacenterDR {
    my $dc = shift;

    return (( scalar grep {$_ eq $dc} opslabDatacentersDR()) ? 1 : 0 );
}

sub isSalesDatacenters {
    my $dc = shift;

    return (( scalar grep {$_ eq $dc} salesDatacenters()) ? 1 : 0 );
}

sub datacenterPrettyName {
    my $dc = shift;

    my $name;
    $name = "North America" if isProductionUSDatacenters( $dc );
    $name = "Europe" if isProductionEUDatacenters( $dc );
    $name = "Russia" if isProductionRUDatacenters( $dc );
    $name = "China" if isProductionCNDatacenters( $dc );
    $name = "UAE" if isProductionUAEDatacenters( $dc );
    $name = "KSA" if isProductionKSADatacenters( $dc );

    return ( $name );
}

# ??? what is this used for.  Do we need RU equivalent?  NOTE:  this method is not used in any of [mt]*/{bin,lib} directories.
sub swauthTargetForDatacenter {
    my $dc = shift;

    return 0 unless defined($dc);
    return prodUSDatacenterPrimary() if (isProductionEUDatacenters($dc));
    return $dc; 
}

sub hasEMC {
    my $dc = shift;
    return 0 unless defined ($dc);
    my %match = (
                 'datacenter' => $dc,
                 'os' => 'enginuity',
                );

    my @machines = ariba::Ops::Machine->machinesWithProperties(%match);
    return (scalar(@machines)); 
    }

sub switchDC {
    my $dc = shift;
    my $switch_dc = {
                        'us1-ms'  => 'us1',
                        'cn1-ms'  => 'cn1',
                        'cn2-ms'  => 'cn2',
                        'prod2'   => 'prod',
                        'ksa1-ms' => 'ksa1',
                        'ksa2-ms' => 'ksa2',
                        'uae1-ms' => 'uae1',
                        'uae2-ms' => 'ksa2',
                    };
    return $switch_dc->{$dc};
}

sub getLabDatacenterPeers {
    my $dc = shift;

    my %datacenterPeers = (
        'lab1'  => "sc1-lab1",
        'sc1-lab1'  => "lab1",
    );

    return $datacenterPeers{$dc};
}

1;
