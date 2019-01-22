# This file defines an object that accesses services.json configuration settings
# It is used by Globals.pm
# $Id: //ariba/services/tools/lib/perl/ariba/rc/ServicesCfg.pm#22 $

package ariba::rc::ServicesCfg;
use lib '/usr/local/ariba/lib/ariba/CPANModules';
use JSON;
use File::Basename;
use strict;
use warnings;

# Input 1 : $jsonfile is the file path to a json file to read from (else use /usr/local/ariba/globals/services.json)
sub new {
    my ($class, $jsonfile) = @_;

    my $self = {};
    bless ( $self, $class );

    $self->{'DEBUG'} = $ENV{'DEBUG_SERVICESCFG'};

    if ($jsonfile && -e $jsonfile) {
        $self->{'JSONFILE'} = $jsonfile;
    }
    else {
        $jsonfile = "/usr/local/ariba/globals/services.json";
        if (-e $jsonfile) {
            $self->{'JSONFILE'} = $jsonfile;
        }
        else {
            print "ServicesCfg: Caanot locate services.json (Checked under /var/local/ops-config and /usr/local/ariba)\n";
        }
    }
    return $self;
}

# Intended for lazy internal access
# Read the services.json file into the SERVICES_CFG instance member
sub _readServicesCfg {
    my ( $self ) = @_;

    if (defined $self->{'SERVICES_CFG'}) {
        return;
    }

    my $file = $self->{'JSONFILE'};
    my $readstatus = 0;
    my $json_text;
    my $json;

    if (-e $file) {
        if ($self->{'DEBUG'}) {
            print "ServicesCfg: Located $file\n";
        }
        $readstatus = open(FILE, $file);
        if ($readstatus) {
            $json_text = join("", <FILE>);
            close FILE;
        }
    }
    else {
        die "Error locating services.json $file\n";
    }

    unless ($json_text) {
        die "Error reading services.json $file\n";
    }

    eval { $json = JSON::decode_json($json_text); }; die "Error decoding services.json\n$@" if $@;
    $self->{'SERVICES_CFG'} = $json;
}

# Return the aka value for the passed in datacenter (or undef if the aka is not available)
sub akaForDatacenter {
    my ( $self, $dc ) = @_;

    $self->_readServicesCfg();

    my $aka = $self->{'SERVICES_CFG'}{'datacenters'}{$dc}{'aka'};
    if ($aka && $aka ne "n/a") {
        return $aka;
    }
    return undef;
}

# Return list of all datacenter names including those marked as an aka
sub allDatacenters {
    my ( $self, $service ) = @_;

    $self->_readServicesCfg();

    my %alldc = ();

    my @datacenters = keys %{$self->{'SERVICES_CFG'}{'datacenters'}};
    for my $dc (@datacenters) {
        $alldc{$dc} = $dc;
        my $aka = $self->akaForDatacenter($dc);
        if ($aka) {
            $alldc{$aka} = $aka;
        }
    }
    @datacenters = keys %alldc;
    return @datacenters;
}

# return a list of datacenters the service is in, else return empty list
sub datacentersForService {
    my ( $self, $service ) = @_;

    if ($service =~ /^personal_robot/ || $service =~ /^personal_cqrobot/) {
        return ('vmlab');
    }

    $self->_readServicesCfg();

    my %all = ();

    my @datacenters = keys %{$self->{'SERVICES_CFG'}{'datacenters'}};
    for my $dc (@datacenters) {
        my @svcs = keys %{$self->{'SERVICES_CFG'}{'datacenters'}{$dc}{'services'}};
        for my $s (@svcs) {
            if ($service eq $s) {
                $all{$dc} = $dc;
            }
        }
    }

    my @a = keys %all;
    my @sorted = sort @a;
    return @sorted;
}

# Returns the physical primary datacenter for a service.
# This is only applicable for datacenters that host more than one service.
# If no service has the "primary" flag set then the last service sorted alphabetically will be returned.
sub physicalPrimaryDatacenterForService {
    my ( $self, $service ) = @_;

    my $primary;
    my @dcs = $self->datacentersForService( $service );
    foreach my $dc ( @dcs ) {
        $primary = $dc;
        last if ( $self->{'SERVICES_CFG'}{'datacenters'}{$dc}{'services'}{$service}{'primary'} );
    }

    return $primary;
}
    
# Returns the primary service for a datacenter.
# this is only applicable for datacenters that host more than one service
# The 'primary' flag must be set.  If no service for the datacenter has this flag set then return undef.
sub primaryServiceForDatacenter {
    my ( $self, $dc ) = @_;

    my $primary;
    my @services = $self->servicesForDatacenter( $dc );
    foreach my $service ( @services ) {
        $primary = $service if ( $self->{'SERVICES_CFG'}{'datacenters'}{$dc}{'services'}{$service}{'primary'} );
        last if ( $primary );
    }

    return $primary;
}
    

# Deprecated: USe datacentersForService
# return the datacenter the service is in, else undef if unascribed
sub datacenterForService {
    my ( $self, $service ) = @_;

    if ($service =~ /^personal_robot/ || $service =~ /^personal_cqrobot/) {
        return 'vmlab';
    }

    $self->_readServicesCfg();

    my @datacenters = keys %{$self->{'SERVICES_CFG'}{'datacenters'}};
    for my $dc (@datacenters) {
        my @svcs = keys %{$self->{'SERVICES_CFG'}{'datacenters'}{$dc}{'services'}};
        for my $s (@svcs) {
            if ($service eq $s) {
                return $dc;
            }
        }
    }
    return undef;
}

# Return list of all service names
sub allServices {
    my ( $self, $service ) = @_;

    $self->_readServicesCfg();

    my %allsvcs = ();
    my @datacenters = keys %{$self->{'SERVICES_CFG'}{'datacenters'}};
    for my $dc (@datacenters) {
        my @svcs = keys %{$self->{'SERVICES_CFG'}{'datacenters'}{$dc}{'services'}};
        for my $s (@svcs) {
            $allsvcs{$s} = $s;
        }
    }
    my @svcs = keys %allsvcs;
    my @sorted = sort @svcs;
    return @sorted;
}

sub isServiceValid
{
    my ( $self, $service ) = @_;

    return 0 unless ( $service );
    $service = lc($service);

    my @all_services = $self->allServices();
    if ( grep { lc($_) eq lc($service) } @all_services )
    {
        return 1;
    }
    return 0;
}

# Returns 1 if the passed in service is set to use opsconfig; return 0 if explicitly set to not use it; undef otherwise
sub usesOpsConfig {
    my ( $self, $service ) = @_;

    $self->_readServicesCfg();

    my @datacenters = keys %{$self->{'SERVICES_CFG'}{'datacenters'}};
    for my $dc (@datacenters) {
        my @svcs = keys %{$self->{'SERVICES_CFG'}{'datacenters'}{$dc}{'services'}};
        for my $s (@svcs) {
            if ($s eq $service) {
                my $opsconfig = $self->{'SERVICES_CFG'}{'datacenters'}{$dc}{'services'}{$s}{'opsconfig'};
                if (defined $opsconfig) {
                    if ($opsconfig) {
                        return 1;
                    }
                    return 0;
                }
            }
        }
    }
    return undef;
}

# Given a service, return the service type it is classified as (else undef)
sub serviceTypeForService {
    my ( $self, $service ) = @_;

    if ($service =~ /^personal_robot/) {
        return undef;
    }

    $self->_readServicesCfg();

    my @datacenters = keys %{$self->{'SERVICES_CFG'}{'datacenters'}};
    for my $dc (@datacenters) {
        my @svcs = keys %{$self->{'SERVICES_CFG'}{'datacenters'}{$dc}{'services'}};
        for my $s (@svcs) {
            if ($s eq $service) {
                my $type = $self->{'SERVICES_CFG'}{'datacenters'}{$dc}{'services'}{$s}{'type'};
                if ($type && $type eq "n/a") {
                    if ($type eq "n/a") {
                        return undef;
                    }
                }
                return $type;
            }
        }
    }
    return undef;
}

# Input datacenter id that is defined in services.json
# Return list or reference to list (depending on calling context) of service names that belong to the datacenter
sub servicesForDatacenter {
    my ( $self, $datacenter ) = @_;

    $self->_readServicesCfg();

    my %svcshash = ();

    my @datacenters = keys %{$self->{'SERVICES_CFG'}{'datacenters'}};
    for my $dc (@datacenters) {
        my $aka = $self->akaForDatacenter($dc);
        if ($dc eq $datacenter || ($aka && $aka eq $datacenter)) {
            my @svcs = keys %{$self->{'SERVICES_CFG'}{'datacenters'}{$dc}{'services'}};
            for my $s (@svcs) {
                $svcshash{$s} = $s;
            }
        }
    }

    my @svcs = keys %svcshash;
    my @sorted = sort @svcs;
    if (wantarray()) {
        return @sorted;
    }
    return \@sorted;
}

# Return list of services that belong to the "devlab" datacenter(s)
# Return list or reference to list (depending on calling context) of service names that belong to the "devlab" datacenter
sub devlabServices {
    my ( $self ) = @_;

    my @svcs = $self->servicesForDatacenter("devlab");
    if (wantarray()) {
        return @svcs;
    }
    return \@svcs;
}

# Return the list of services configured to use a non shared filesystem
sub servicesWithNonSharedFileSystem {
    my ( $self ) = @_;

    $self->_readServicesCfg();

    my %svcshash = ();

    my @datacenters = keys %{$self->{'SERVICES_CFG'}{'datacenters'}};
    for my $dc (@datacenters) {
        my $sharedfs = $self->{'SERVICES_CFG'}{'datacenters'}{$dc}{'sharedfs'};
        if ($sharedfs == 0) {
            my @svcs = keys %{$self->{'SERVICES_CFG'}{'datacenters'}{$dc}{'services'}};
            for my $s (@svcs) {
                $svcshash{$s} = $s;
            }
        }
    }

    my @svcs = keys %svcshash;
    my @sorted = sort @svcs;
    if (wantarray()) {
        return @sorted;
    }
    return \@sorted;
}

# Return 1 if the input service is configured to use shared filesystem; else returns 0
sub serviceUsesSharedFileSystem {
    my ($self, $service) = @_;

    $self->_readServicesCfg();

    my @datacenters = keys %{$self->{'SERVICES_CFG'}{'datacenters'}};
    for my $dc (@datacenters) {
        my $sharedfs = $self->{'SERVICES_CFG'}{'datacenters'}{$dc}{'sharedfs'};
        my @svcs = keys %{$self->{'SERVICES_CFG'}{'datacenters'}{$dc}{'services'}};
        for my $s (@svcs) {
            if ($s eq $service) {
                if ($sharedfs) {
                    return 1;
                }
                return 0;
            }
        }
    }
    # Expect personal services to not be registered and so we get here and return the default to use shared fs
    return 1;
}

# ----------------------------------------------
# The API's below used to work the //ariba/services/config area (not access methods for the services.json file)
# They rely on an opened p4 session to be in the caller's scope, which is the case for :
#   shared/bin/sandbox.pl
#   the tools/bin/configure-deployment

# Return ($status, $msg) where status == 1 is succes; status == 0 is failure; msg is informational
sub createOpsConfigBranch {
    my ($self, $product, $parentBranchName, $newBranchName, $change) = @_;

    my $msg = "";

    my ($status, %parentOpsConfigDepotPaths) = $self->findParentOpsConfigDepotPaths($product, $parentBranchName, $newBranchName);

    unless ($status) {
        $msg .= "The new branch \"$newBranchName\" already exists\n";
        return (0, $msg);
    }

    for my $srcPath (keys %parentOpsConfigDepotPaths) {
        my $destPath = $parentOpsConfigDepotPaths{$srcPath};
        $msg .= "Integrating $srcPath into $destPath...\n";
        my $cmd = "p4 integ -d -c $change $srcPath" . "/... $destPath" . "/...";
        my %out = qx($cmd);
        if ( $out{ error } && ${ $out{ error } }[ 0 ] !~ /already integrated/ ) {
            $msg .= "Could not branch from $srcPath to $destPath\n";
            return (0, $msg);
        }
        if ( $out{ info } ) {
            my $nfiles = scalar ( @{ $out{ info } } );
            $msg .= "The branch $destPath contains $nfiles files\n";
        }
    }
    return (1, $msg);
}

# Return (1, hash) for success  where hash key is path to parent branch and value is string path to new branch
# Return (0, hash) for warning that new branch already exists and key,value is as described above
#
# When $parentBranchName eq "trunk" return like the following if the parent exists and the new branch does not
#    (1, "//ariba/services/config/datacenters/<datacenter>/services/<service>/products/$product" =>
#        "//ariba/services/config/datacenters/<datacenter>/services/<service>/products/<product>/branches/<newBranchName>")
#
# When $parentBranchName ne "trunk" return like the following if the parent exists and the new branch does not
#    (1, "//ariba/services/config/datacenters/<datacenter>/services/<service>/products/<product>/branches/$parentBranchName" =>
#        "//ariba/services/config/datacenters/<datacenter>/services/<service>/products/<product>/branches/<newBranchName>")
sub findParentOpsConfigDepotPaths {
    my ($self, $product, $parentBranchName, $newBranchName) = @_;

    my %ret = ();

    my $result = qx(p4 dirs "//ariba/services/config/datacenters/*" 2>null);
    chomp($result);

    my @dcs = split(/\n/, $result);
    for my $dc (@dcs) {
        $result = qx(p4 dirs "$dc/services/*" 2>nul);
        chomp($result);
        my @svcs = split(/\n/, $result);
        for my $s (@svcs) {
            if ($parentBranchName eq "trunk") {
                $result = qx(p4 dirs "$s/products/$product/branches/$newBranchName" 2>null);
                if ($result) {
                    chomp($result);
                    $ret{$result} = "$/products/$product/branches/$newBranchName";
                    return (0, %ret);
                }
                $result = qx(p4 dirs "$s/products/$product" 2>null);
                if ($result) {
                    chomp($result);
                    $ret{$result} = "$result/branches/$newBranchName";
                }
            }
            else {
                $result = qx(p4 dirs "$s/products/$product/branches/$parentBranchName" 2>null);
                if ($result) {
                    chomp($result);
                    $ret{$result} = "$/products/$product/branches/$newBranchName";
                }
            }
        }
    }
    return (1, %ret);
}

sub _execCmd {
    my ($cmd, $oktofail) = @_;

    my $out = qx "$cmd";
    my $ret = $?;
    my $ret2 = $ret >> 8;
    if ($ret2) {
        die "The command failed $cmd\n" unless ($oktofail);
    }
    return $out;
}

sub _deleteLocalClient {
    my ($clientname) = @_;

    my $cmd = qq(p4 client -d $clientname);
    return _execCmd($cmd, 1);
}

# input the name of the p4 client and a flag to escape /
# return the path to the p4 client
sub _clientPath {
    my ($clientname, $escapeslash) = @_;

    my $tmp = ($ENV{TMP} || "/tmp") . "/$clientname";
    if ($escapeslash) {
        $tmp =~ s/\//\\\//g; # replace all / with \/
    }

    return $tmp;
}

# create a p4 client that will be used to sync the ops config files
# input the name of the p4 client to create
# return the output of the p4 client creation command
sub _createLocalClient {
    my ($clientname) = @_;

    if ($clientname) {
        my $tmp = _clientPath($clientname, 1);

        my $cmd = qq(p4 client -t svcdep-config -o $clientname | sed -e "s/svcdep-config/$clientname/" | sed -e 's,^Root:.*,Root: $tmp,' | sed -e "s/^Host.*//"  | p4 client -i);
        return _execCmd($cmd);
    }
}

# Return undef if could not sync (like no such files(s)  at the opsConfigLabel.
# Return 1 if sync'd ok
sub _p4sync {
    my ($path, $opsConfigLabel, $p4client) = @_;

    $p4client = "svcdep-config" unless ($p4client);

    my $cmd = "p4 -c $p4client sync -f $path";

    if ($opsConfigLabel) {
        my $vers = "@" . $opsConfigLabel;
        $cmd .= $vers;
    }

    my $out = _execCmd($cmd);
    if ($out && $out =~ /no such file/) {
        return undef;
    }
    return 1;
}

# Return a list of paths containing config files to be overlayed (last entries tak prcedence over earlier ones)
# Input: mandatory args: product, service, opsConfigLabel
#        optional args: branch, jobname
# Returns a list ref of paths to the new config directories datacenters,servicetypes,services,products,branches,jobs,sandboxes combination
#
# Note on the use of a p4 client
# The use case where a jobname is specified demands that the ops config files be sync'd to a local p4 client.
# Otherwise, a common p4 client is used (like for user rc running on a build server)
# The use of a local client each time ensures that all files will be owned by the same user (no permission problems).
sub getOpsConfigFiles {
    my ($self, $product, $service, $opsConfigLabel, $branch, $jobname) = @_;

    unless ($product && $service && $opsConfigLabel) {
        die "configure-deployment : All of the mandatory arguments have not been supplied";
    }

    my $root = "/home/svcdep/svcdep-config";
    my $configroot = $root . "/services/config";

    my $cdir;
    my @retlist = ();
    my @dcs = $self->datacentersForService($service);
    my $dc;

    my $ndcs = scalar (@dcs);
    if ($ndcs < 1) {
        print STDERR "ERROR : There is no associated datacenter for service $service. Check the services.json file. Skipping the addition of //ariba/services/config files\n";
        return @retlist;
    }

    my $path;
    my $ret;

    if ($jobname) {
        print"Using configs from Central Location since the Deploy Job is called from jenkins: $jobname\n";
        _createLocalClient($jobname);

        $root = _clientPath($jobname);
        $configroot = $root . "/services/config";

        $path = "//ariba/services/config/globals/...";
        $ret = _p4sync($path, undef, $jobname);
        unless ($ret) {
            die "The p4 sync command failed for $path\n";
        }

        for $dc (@dcs) {
            $path = "//ariba/services/config/datacenters/$dc/jobs/$jobname/...";
            $ret = _p4sync($path, $opsConfigLabel, $jobname);
            unless ($ret) {
                $ret = _p4sync($path, undef, $jobname); # Fallback to now
            }

            $path = "//ariba/services/config/datacenters/$dc/services/$service/products/$product/...";
            $ret = _p4sync($path, $opsConfigLabel, $jobname);
            unless ($ret) {
                $ret = _p4sync($path, undef, $jobname); # Fallback to now
            }
        }
    }
    else {
        $path = "//ariba/services/config/globals/...";
        $ret = _p4sync($path);
        unless ($ret) {
            die "The p4 sync command failed for $path\n";
        }
        for $dc (@dcs) {
            $path = "//ariba/services/config/datacenters/$dc/services/$service/products/$product/...";
            $ret = _p4sync($path, $opsConfigLabel);
            unless ($ret) {
                $ret = _p4sync($path); # Fallback to now
            }
        }
    }

    if ($branch) {
        $path = "//ariba/sandbox/build/$branch/$product/...";
        $ret = _p4sync($path, $opsConfigLabel, $jobname);
        unless ($ret) {
            $ret = _p4sync($path, undef, $jobname); # Fallback to now
        }

        $path = "//ariba/ond/$product/build/$branch/...";
        $ret = _p4sync($path, $opsConfigLabel);
        unless ($ret) {
            $ret = _p4sync($path, undef, $jobname); # Fallback to now
        }
    }

    # a) ond area (don't have to spin new archive builds to pickup changes here)
    # //ariba/ond/$product/build/$branch
    if ($branch) {
        my $ondroot = $root . "/ond/$product/build/$branch";
        my $cdir = $ondroot;
        if (-d $cdir) {
            push (@retlist, $cdir);
        }

        # //ariba/ond/$product/build/$branch/$service
        $cdir = "$ondroot/$service";
        if (-d $cdir) {
            push (@retlist, $cdir);
        }
    }

    my $servicetype = $self->serviceTypeForService($service);

    # c) datacenter level directory
    # //ariba/services/config/datacenters/<datacenter>
    # Try the aka datacenter if defined when the datacenter could not be found (like registering a service under devlab instead of lab1)
    for $dc (@dcs) {
        $cdir = "$configroot/datacenters/$dc";
        unless (-d $cdir) {
            my $aka = $self->akaForDatacenter($dc);
            if ($aka) {
                my $cdiraka = "$configroot/datacenters/$aka";
                unless (-d $cdiraka) {
                    # Can't find the datacenter nor its aka
                    $self->_warnAboutMissingConfigDirs($cdir);
                }
                else {
                    print STDERR "WARNING : Using the aka dataenter $cdiraka because $cdir does not exist\n";
                    push (@retlist, $cdiraka);
                    $dc = $aka; # So the subsequent checks will use the aka datacenter
                }
            }
            else {
                $self->_warnAboutMissingConfigDirs($cdir);
            }
        }
        else {
            push (@retlist, $cdir);
        }
    }

    # d) datacenter:service level directory
    # //ariba/services/config/datacenters/<datacenter>/services/<service>
    for $dc (@dcs) {
        $cdir = "$configroot/datacenters/$dc/services/$service";
        unless (-d $cdir) {
            $self->_warnAboutMissingConfigDirs($cdir);
        }
        else {
            push (@retlist, $cdir);
        }
    }

    # e) product (service common) level directory
    # //ariba/services/config/products/<product>
    $cdir = "$configroot/products/$product";
    unless (-d $cdir) {
        $self->_warnAboutMissingConfigDirs($cdir);
    }
    else {
        push (@retlist, $cdir);
    }

    # f) product:branch  (service common) level directory
    # //ariba/services/config/products/<product>/branches/<branch>
    if ($branch) {
        $cdir = "$configroot/products/$product/branches/$branch";
        unless (-d $cdir) {
            $self->_warnAboutMissingConfigDirs($cdir);
        }
        else {
            push (@retlist, $cdir);
        }
    }

    # g) datacenter:service:product level directory
    # //ariba/services/config/datacenters/<datacenter>/services/<service>/products/<product>
    for $dc (@dcs) {
        $cdir = "$configroot/datacenters/$dc/services/$service/products/$product";
        unless (-d $cdir) {
            $self->_warnAboutMissingConfigDirs($cdir);
        }
        else {
            push (@retlist, $cdir);
        }
    }

    # h) datacenter:servicetypes:product level directory
    # //ariba/services/config/datacenter/<datacenter>/servicetypes/<servicetype>/products/<product>
    if ($servicetype) {
        for $dc (@dcs) {
            $cdir = "$configroot/datacenters/$dc/servicetypes/$servicetype/products/$product";
            if (-d $cdir) {
                push (@retlist, $cdir);
            }
        }
    }

    # i) datacenter:servicetypes:product:branch level directory
    # //ariba/services/config/datacenter/<datacenter>/servicetypes/<servicetype>/products/<product>/branches/<branch>
    if ($branch && $servicetype) {
        for $dc (@dcs) {
            $cdir = "$configroot/datacenters/$dc/servicetypes/$servicetype/products/$product/branches/$branch";
            if (-d $cdir) {
                push (@retlist, $cdir);
            }
        }
    }

    # j) datacenter:service:product:branch level directory
    # //ariba/services/config/datacenters/<datacenter>/services/<service>/products/<product>/branches/<branch>
    if ($branch) {
        for $dc (@dcs) {
            $cdir = "$configroot/datacenters/$dc/services/$service/products/$product/branches/$branch";
            unless (-d $cdir) {
                $self->_warnAboutMissingConfigDirs($cdir);
            }
            else {
                push (@retlist, $cdir);
            }
        }
    }

    # k) datacenter:jobs level directory
    # //ariba/services/config/datacenters/<datacenter>/jobs/<jobname>
    if ($jobname) {
        for $dc (@dcs) {
            $cdir = "$configroot/datacenters/$dc/jobs/$jobname";
            if (-d $cdir) {
                push (@retlist, $cdir);
            }
        }
    }

    # l) sandboxes
    # //ariba/sandbox/build/<branch>/<product>
    if ($branch) {
        my $sandboxroot = $root . "/sandbox/build/$branch/$product";
        $cdir = $sandboxroot;
        if (-d $cdir) {
            push (@retlist, $cdir);
        }
        # //ariba/sandbox/build/<branch>/<product>/<service>
        $cdir = "$sandboxroot/$service";
        if (-d $cdir) {
            push (@retlist, $cdir);
        }
    }

    if ($jobname) {
        _deleteLocalClient($jobname);
    }
    return @retlist;
}

sub _warnAboutMissingConfigDirs {
    my ($self, $cdir) = @_;

    if ($self->{'DEBUG'}) {
        print STDERR "WARNING : The following directory does not exist so it cannot be overlayed into the resulting config directory: $cdir\n";
    }
}

1;
