package ariba::Ops::ServiceController;

use ariba::Ops::DatacenterController;
use ariba::rc::Globals;
use strict;
use warnings;

#
# array reference of functions with specific service combinations
# this list is for specific queries, cronjob groupings, etc
#

my %functions = (
                    # This item includes both CS and MS services:
                    '3par'              => ['prod', 'prodeu', 'prodru', 'prodcn', 'prodcnms', 'prodms', 'prodeums', 'prodrums',
                                            'load', 'prod2', 'prodksa', 'prodksams', 'produae', 'produaems'],

                    # This item includes both CS and MS services:
                    '3par-node'         => ['prod', 'prodeu', 'prodru', 'prodcn', 'prodcnms', 'prodms', 'prodeums', 'prodrums',
                                            'lab', 'load', 'prod2', 'prodksa', 'prodksams', 'produae', 'produaems'],

                    # This item includes both CS and MS services:
                    'bcv'               => ['prod', 'prodeu', 'prodru', 'prodcn', 'prodcnms', 'prodms', 'prodeums', 'prodrums',
                                            'lab', 'prod2', 'prodksa', 'prodksams', 'produae', 'produaems'],

                    # This item includes both CS and MS services:
                    'cgroups'           => ['prod', 'prodeu', 'prodru', 'prodcn', 'prodcnms', 'prodms', 'prodeums', 'prodrums',
                                            'mig2', 'rel', 'sp', 'prod2', 'prodksa', 'prodksams', 'produae', 'produaems'],

                    # ---
                    'cycle-wof-apps-an' => ['dev6', 'rel', 'sp'],

                    # This item includes both CS and MS services:
                    'dumphost'          => ['prod', 'prodeu', 'prodru', 'prodcn', 'prodcnms', 'prodms', 'prodeums', 'prodrums',
                                            'lab', 'beta', 'beta2', 'betaeu', 'prod2', 'prodksa', 'prodksams', 'produae', 'produaems'],

                    # This item includes both CS and MS services:
                    'launchlog'         => ['prod', 'prodeu', 'prodru', 'prodcn', 'prodcnms', 'prodms', 'prodeums',
                                            'lab', 'prod2', 'prodksa', 'prodksams', 'produae', 'produaems'],

                    # ---
                    'mysql-rsync'       => ['prod', 'lab'],

                    # This item includes both CS and MS services:
                    'netapp'            => ['prod', 'prodeu', 'prodru', 'prodcn', 'prodcnms', 'prodms', 'prodeums',
                                            'prodrums', 'lab', 'prod2', 'prodksa', 'prodksams', 'produae', 'produaems'],

                    # ---
                    'no-s4-recycle'     => ['load', 'load2', 'load3', 'load4', 'dev', 'dev2', 'dev3', 'dev4', 'dev5',
                                            'sp', 'rel', 'test', 'lq', 'lq2', 'lq3', 'sctest1'],

                    # This item includes both CS and MS services:
                    'primary-procs'     => ['prod', 'prodeu', 'prodru', 'prodcn', 'prodcnms', 'prodms', 'prodeums', 'prodrums', 'dev', 'beta',
                                            'beta2', 'betaeu', 'sales', 'lab', 'prod2', 'prodksa', 'prodksams', 'produae', 'produaems'],

                    # This item includes both CS and MS services:
                    'publish'           => ['prod', 'prodeu', 'prodru', 'prodcn', 'prodcnms', 'prodms', 'prodeums', 'prodrums',
                                            'lab', 'prod2', 'prodksa', 'prodksams', 'produae', 'produaems'],

                    # This item includes both CS and MS services:
                    'sendmail'          => ['prod', 'prodeu', 'prodru', 'prodcn', 'prodcnms', 'prodms', 'prodeums', 'prodrums', 'lab', 'dev',
                                            'load', 'qa', 'beta', 'beta2', 'betaeu', 'sales', 'prodksa', 'prodksams', 'produae',
                                            'produaems'],

                    # This item includes both CS and MS services:
                    'ssrealms'          => ['prod', 'prodeu', 'prodru', 'prodcn', 'prodcnms', 'prodms', 'prodeums', 'prodrums',
                                            'beta', 'beta2', 'betaeu', 'sales', 'prod2', 'prodksa', 'prodksams', 'produae', 'produaems'],

                    # This item includes both CS and MS services:
                    'ws-reports'        => ['prod', 'prodeu', 'prodru', 'prodcn', 'prodcnms', 'prodms', 'prodeums', 'prodrums',
                                            'sales', 'prod2', 'prodksa', 'prodksams', 'produae', 'produaems'],
                );

sub checkFunctionForService {
    my $service = shift;
    my $function = shift;

    my $serviceArray = $functions{$function};
    die "ERROR: undefined function or service in serviceArray" unless defined($serviceArray);
    # error if $serviceArray is undef

    if( grep { $_ eq $service } @$serviceArray ) {
        return 1;
    } else {
        return 0;
    }
}

sub checkServicesForFunction {
    my $function = shift;

    my $serviceArray = $functions{$function};
    die "ERROR: undefined function or service in serviceArray" unless defined($serviceArray);

    return @$serviceArray;
}

# all production services
sub productionServices {
    my @services = productionServicesOnly();
    push (@services, otherProductionServices());

    return @services;
}

# all primary production services 
sub productionServicesOnly {
    return (productionCsServicesOnly(), productionMsServicesOnly());
}

# I believe Cs means Core Services (ie, legacy or "money making" services).  NO micro services (ms), see next method.
sub productionCsServicesOnly {
    return ("prod", "prodeu", "prodru", "prodcn", "prod2", "prodksa", 'produae',);
}

# all ms production services
sub productionMsServicesOnly {
    return ("prodms", "prodeums", "prodcnms", "prodrums", 'prodksams', 'produaems',);
}

# other customer facing services
sub otherProductionServices {
    return ("beta", "beta2", "betaeu");
}

# primary production service in US
sub productionServiceUSOnly {
    return ("prod");
}

# primary production service in EU
sub productionServiceEUOnly {
    return ("prodeu");
}

# primary production service in RU
sub productionServiceRUOnly {
    return ("prodru");
}

# production extended cluster in SNV
sub productionExtendedServicesOnly {
    return ("prod2");
}

# primary production service in Santa Clara
sub productionServiceSCOnly {
    return ("prodms");
}

# primary production service in China
sub productionServiceCNOnly {
    return ("prodcn");
}

# primary production service in KSA
sub productionServiceKSAOnly {
    return ("prodksa");
}

# primary production service in UAE
sub productionServiceUAEOnly {
    return ("produae");
}

sub labServiceOnly {
    return ("lab");
}

sub loadServiceOnly {
    return ("load");
}

sub devServiceOnly {
    return ("dev");
}

sub salesServiceOnly {
    return ("sales");
}

sub isProductionServices {
    my $service = shift;

    return (( scalar grep {$_ eq $service} productionServices()) ? 1 : 0 );
}

sub isProductionServicesOnly {
    my $service = shift;

    return (( scalar grep {$_ eq $service} productionServicesOnly()) ? 1 : 0 );
}

sub isProductionUSServiceOnly {
    my $service = shift;

    return (( scalar grep {$_ eq $service} productionServiceUSOnly()) ? 1 : 0 );
}

sub isProductionEUServiceOnly {
    my $service = shift;

    return (( scalar grep {$_ eq $service} productionServiceEUOnly()) ? 1 : 0 );
}

sub isProductionRUServiceOnly {
    my $service = shift;

    return (( scalar grep {$_ eq $service} productionServiceRUOnly()) ? 1 : 0 );
}

sub isProductionSCServiceOnly {
    my $service = shift;

    return (( scalar grep {$_ eq $service} productionServiceSCOnly()) ? 1 : 0 );
}

sub isLabServiceOnly {
    my $service = shift;

    return (( scalar grep {$_ eq $service} labServiceOnly()) ? 1 : 0 );
}

sub isLoadServiceOnly {
    my $service = shift;

    return (( scalar grep {$_ eq $service} loadServiceOnly()) ? 1 : 0 );
}

sub isDevServiceOnly {
    my $service = shift;

    return (( scalar grep {$_ eq $service} devServiceOnly()) ? 1 : 0 );
}

sub isSalesServiceOnly {
    my $service = shift;

    return (( scalar grep {$_ eq $service} salesServiceOnly()) ? 1 : 0 );
}

sub isProductionMsServicesOnly {
    my $service = shift;

    return (( scalar grep {$_ eq $service} productionMsServicesOnly()) ? 1 : 0 );
}

sub isProductionCsServicesOnly {
    my $service = shift;

    return (( scalar grep {$_ eq $service} productionCsServicesOnly()) ? 1 : 0 );
}

sub isProductionCNServiceOnly
{
    my $service = shift;
    return ((scalar grep ({$_ eq $service} productionServiceCNOnly())) ? 1 : 0 );
}

sub isProductionUAEServiceOnly
{
    my $service = shift;
    return ((scalar grep ({$_ eq $service} productionServiceUAEOnly())) ? 1 : 0 );
}

sub isProductionKSAServiceOnly
{
    my $service = shift;
    return ((scalar grep ({$_ eq $service} productionServiceKSAOnly())) ? 1 : 0 );
}

sub isProductionExtendedServicesOnly {
    my $service = shift;
  
    return (( scalar grep {$_ eq $service} productionExtendedServicesOnly()) ? 1 : 0 );
}

1;
