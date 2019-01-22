#!/usr/local/bin/perl

package ariba::Ops::HadoopHelper;

use strict;
use FindBin;
use lib "$FindBin::Bin";
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../lib/perl";

use ariba::rc::InstalledProduct;
use ariba::rc::InstalledSharedServiceProduct;
use ariba::rc::Passwords;
use ariba::rc::Product;
use ariba::Ops::Startup::Common;

#
# Hadoop specific helper functions
#

#
# Return the list of tables that we care to take backup / restores of
#
sub getHbaseTables {
    my $product = shift;
    my $service = shift;
    my $keysContainTenantSpecificInfoOnly = shift;

    my $arches = ariba::rc::InstalledProduct->new($product, $service);
    my $javaHome = $ENV{'JAVA_HOME'} = ariba::Ops::Startup::Common::javaHomeForProduct($arches);


    my $installDir = $arches->installDir();
    my $cmdGetTables = "$installDir/bin/gethbasetables -replicateOnly";
    if ($keysContainTenantSpecificInfoOnly) {
        $cmdGetTables .= " -keysContainTenantSpecificInfoOnly";
    }

    my $user = "svc$service";
    my $host = ($arches->rolesManager()->hostsForRoleInCluster('indexmgr', $arches->currentCluster()))[0];
    ariba::rc::Passwords::initialize($service);
    my $passwd = ariba::rc::Passwords::lookup( $user );
    my @output;

    my $cmd = "ssh svc$service\@$host -x 'bash -c \"export JAVA_HOME=$javaHome ; $cmdGetTables\"'";
    ariba::rc::Utils::executeRemoteCommand($cmd,$passwd, 0, undef, undef, \@output);

    my @tables = ();
    foreach my $line (@output) {
        next if ($line =~ /^\s+$/);
        next if ($line =~ /^SLF4J/);
        $line =~ s/^table//;
        $line =~ s/\n$//;
        push(@tables, $line);
    }
    return(@tables);
}

1;
