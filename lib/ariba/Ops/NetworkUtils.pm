package ariba::Ops::NetworkUtils;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/NetworkUtils.pm#39 $

use strict;
use vars qw(@ISA @EXPORT_OK %EXPORT_TAGS);

use Exporter;
use File::Copy;
use Net::IPv4Addr qw(:all);
use Socket;
use ariba::rc::Utils;
use Sys::Hostname ();

@ISA       = qw(Exporter);
@EXPORT_OK = qw( 
    hostname hostToAddr addrToHost defaultRouteForTier setDefaultRouteForTier updateHostFile 
    hostnameToNetname hostnameToTier domainForHost isIPAddr isFQDN fqdnToShortHostname 
    macAddressForHost ping vendorForMacAddress snmpOctetstrToNumbers
);

%EXPORT_TAGS = (
    'all'       => [ @EXPORT_OK ],
);

my $DEBUG = 1;

my $DEFAULTROUTER = '/etc/defaultrouter';

my $hostname = hostname();

my @networkTiers;

@networkTiers = ('0', '1a', '1b', '1c', '1f', '1i', '1bx1','2b', '2', '3', '3x1', '3x2', '3x3', '4', '5');

my %ouiDB         = ();

sub hostname {
    return $hostname if $hostname;

    $hostname = Sys::Hostname::hostname();

    unless ( $hostname =~ /\./ ) {
        # machine is misconfigured and has hostname not full qualified
        # grunge to get domain name
        my $domain;
    
        local(*RESOLV);
        open(RESOLV, "/etc/resolv.conf");   # might not exist
        while( <RESOLV> ) {
            chomp;
            if ( /^search/ || /^domain/ ) {
                $domain = (split(/\s+/, $_))[1];
                last;
            }
        }
        close(RESOLV);
        if ( $domain ) {
            $hostname .= ".$domain";    
        }
    }

    return $hostname;
}

sub hostToAddr {
    my $host  = shift;
    my @addrs = (gethostbyname($host))[4];

    my $addr  = defined $addrs[0] ? inet_ntoa($addrs[0]) : $host;

    return $addr;
}

sub addrToHost {
    my $addr = shift;
    my $aton = inet_aton($addr);

    return $addr unless defined $aton;

    my $host = (gethostbyaddr($aton, AF_INET))[0];

    return $host if defined $host;
    return $addr;
}

sub defaultRouteForTier {
    my ($tier,$domain) = @_;

    # XXX - should write cover 'defaultRouteForNet
    $tier =~ s/n//;
    
    if ($tier == 0) {
        warn "Not on a production tier,";
        return '0.0.0.0';
    }

    unless (isFQDN($domain)) {
        warn "Not a valid domain,";
        return '0.0.0.0';
    }

    my $route  = hostToAddr("defaultroute.n$tier.$domain");

    unless (defined $route) {
        warn "Couldn't find IP for gateway: [$route]" if $DEBUG;
        return '0.0.0.0';
    }

    return $route;
}

sub setDefaultRouteForTier {
    my $route = hostToAddr(shift);

    return 0 unless isIPAddr($route);

    open (D, ">$DEFAULTROUTER") || die "Can't write [$DEFAULTROUTER]: $!";
    print D "$route\n";
    close(D);

    return 1;
}

# update the /etc/inet/hosts for jumpstart, as sun does the wrong thing.
sub updateHostFile {
    my $hostname = shift;

    unless ($^O =~ /solaris/) {
        warn "updateHostFile() solaris only.\n";
        return;
    }
    
    my $hosts = '/etc/inet/hosts';

    for my $file (qw(/etc/hostname.hme0 /etc/nodename)) {
        open  H, ">$file" or die $!;
        print H "$hostname\n";
        close H;
    }

    open H1, $hosts or die "Can't open [$hosts]\n";
    open H2, ">$hosts.tmp" or die "Can't write [$hosts.tmp]\n";
    while(<H1>) {
        print H2 $_ unless /(?:prod|dev)-js/;
    }
    close H1;
    
    my $ip = hostToAddr($hostname) || do {
        warn "Can't get IP for $hostname - Aborting /etc/hosts update!\n";
        unlink "$hosts.tmp" or warn "Can't unlink $hosts.tmp\n";
        return;
    };

    my ($host) = ($hostname =~ /(\w+?)\./);

    print H2 "$ip\t$hostname $host\n";
    close H2;

    move "$hosts.tmp", $hosts or warn "Can't move $hosts.tmp to $hosts !\n";
    print "Hostname changed to: [$hostname] == [$ip]\n" if $DEBUG;
}

sub hostnameToNetname {
    my ($hostname,$mask) = @_;

    # if $address/$mask is:
    # 10.10, return ancorp, EXCEPT 10.10.130, which is n5.
    # otherwise, get the tier and return that.
    # anything else, return unknown

    # text returned should not have spaces or slashes in it:
    # they're usually used for directory names

    my  $address = hostToAddr($hostname);

    if ( ( $address !~ /^10\.10\.130\./ || $address !~ /^10\.10\.1[34]\./ ) &&
          ( $address =~ /^10\.10/ || $address =~ /^10\.11/ ) ) {
        return 'corp';
    }

    # try a tier lookup
    my  $tier = hostnameToTier($address,$mask);

    if ( defined($tier) ) {
        return "n$tier";
    } else {
        #try to guess from hostname
        my $shortHostName = fqdnToShortHostname($hostname);

        # c3640-ras-n3-1.bou.ariba.com
        # c3640-vpn-n3-1.bou.ariba.com
        # c4003-n1-1.bou.ariba.com
        # c4003-n2-1.bou.ariba.com        
        my $net = (split(/-/, $shortHostName))[-2];
        if ( $net && $net =~ /^n[\w]+$/o ){
            return $net;
        } else {
            return 'unknown';
        }
    }
}

sub hostnameToTier {
    my ($address,$mask,$domain) = @_;

    unless (isIPAddr($address)) {
        $address = hostToAddr($address);
    }

    # check for a host not found.
    unless (isIPAddr($address)) {
        return 0;
    }

    unless ($domain) {
        $domain = domainForHost($address);
    }

    # this usually indicates a bad arpa zone file missing a '.'
    if ($domain !~ /ariba\.com$/) {
        return undef;
    }

    # internal
    if ($domain eq 'demo.ariba.com' or $domain eq 'sales.ariba.com' or  $domain eq 'beta.ariba.com' or isIPAddr($domain)) {
        return 0;
    }
    
    my $net;
    for my $netToCheck (@networkTiers) {
        # resolve a net
        my $network = hostToAddr("network.n$netToCheck.$domain");
        my $netmask = hostToAddr("netmask.n$netToCheck.$domain");

        # Skip cases where the network and netmask aren't defined.  
        next if $network eq "network.n$netToCheck.$domain" or $netmask eq "netmask.n$netToCheck.$domain";

        # mask for host ($address) defaults to the netmask of that tier.
        my $maskToUse;
        if ( defined($mask) ) {
            $maskToUse = $mask;
        } else {
            $maskToUse = $netmask;
        } 

        # check to see if $address/$mask is in that net
        #print "DEBUG: network=$network, netmask=$netmask, address=$address, maskToUse=$maskToUse\n" if $DEBUG;
        if ( eval { ipv4_in_network($network, $netmask, $address, $maskToUse) } ) {
            $net = $netToCheck;
            last;
        }
    }

    return $net;
}

sub domainForHost {
    my $host = shift;

    my @parts = split(/\./, addrToHost($host));

    # host
    shift(@parts);
    
    # while the above is strickly true it doesn't do want we want
    # when forward something like
    # c3640-n0-1.snv.ariba.com == 206.251.25.2
    # and reverse is something like
    # 206.251.25.2 == fe0-0.c3640-n0-1.snv.ariba.com
    if( scalar(@parts) > 3 ) {
        shift(@parts);
    }

    return (join '.', @parts);
}
    
sub isIPAddr {
    my $addr = shift;

    if ($addr =~ /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/) {
        return 1;
    } else {
        return 0;
    }
}

sub isFQDN {
    my @parts =  split /\./, shift;

    for my $part (@parts) {
        return 0 if $part !~ /^[a-zA-Z0-9-]+$/;
    }

    if (scalar @parts >= 2) {
        return 1;
    } else {
        return 0;
    }
}

#given a fqdn, strip to the domain name
sub fqdnToShortHostname {
    my $fqdn = shift;

    my $short = (split /\./, $fqdn)[0];
    return $short;
}

sub ping {
    my $host = shift;
    my $os   = $^O;
    my $ping;

    #
    # TMID: 11515
    #
    # We use to cache ping results, and not ping a host again if
    # it has already been pinged. However, due to some weird arp
    # cache timeout behavior, pinging an ip does not refresh the
    # arp cache, and can cause the entry to get timedout during
    # our run. Kill the local ping cache.
    #

    my $pingCmd = ariba::rc::Utils::pingCmd();

    if ($os eq 'linux') {

        $ping = "$pingCmd -c 2 $host";

    } elsif ($os eq 'solaris') {

        #
        # ping usage on solaris:
        # ping <hostname> <data_size> <packet_count>
        # default data size is 56 
        #
        $ping = "$pingCmd $host 56 2";

    } elsif ($os eq 'hpux') {

        $ping = "$pingCmd $host -n 2";

    } else {
        # unknown
        return undef;
    }

    # Check the return status of ping to see if it worked.
    if (system("$ping >/dev/null 2>&1") == 0) {
        return 1;
    }

    return undef;
}

sub formatMacAddress {
    my $mac = shift || return undef;

    # Normalize the mac address to arp/tcpdump format.
    $mac =~ s/^0x([0-9A-Z])/$1/igo;
    $mac =~ s/([0-9A-Z]{4,4})\./$1/igo;
    $mac =~ s/([^:-]{2,2})/$1:/go;

    my @addr = split(/[:-]+/o, $mac);

    grep ($_ =~ tr/A-Z/a-z/, @addr);

    grep s/^0(.)/$1/o, @addr;

    return join(':', @addr);
}

sub macAddressForHost {
    my $host = shift;
    
    my $os = $^O;
    my $mac;

    my $arpCmd = ariba::rc::Utils::arpCmd();

    if ($os eq 'linux') {

        # localhost case
        if ($host eq hostname()) {

            $mac = macAddressForVirtualOnLinux($host);

        } else {

            # On linux /sbin/arp, /bin/ping
            #
            #db12.snv.ariba.com (216.109.110.193) -- no entry
            #
            # sssdb1: Unknown host
            #
            #Address                  HWtype  HWaddress           Flags Mask            Iface
            #db10.snv.ariba.com       ether   00:10:18:10:BE:EB   C                     eth0

            ### In new OS:RHEL 6.7, we get incomplete for vips.

            ping($host) || return undef;
            open(ARP, "$arpCmd $host |");
            while (my $line = <ARP>) {
                next if (!defined($line) || $line =~ /^\s*Address\s*HWtype/); # skip header line
                if ($line =~ /no entry|incomplete/) {
                    $mac = undef;
                    last;
                } else {
                    $mac = (split(/\s+/, $line))[2];
                    last if ($mac);
                }
            }
            close(ARP);

            # virtual, but local to this machine case.
            if (!defined $mac) {
                $mac = macAddressForVirtualOnLinux($host);
            }

            # if we get a 'Unknown host' return from arp.
            $mac = undef if defined $mac and $mac eq 'host';
        }

    } elsif ($os eq 'solaris') {

        # On solaris /usr/sbin/arp, /usr/sbin/ping
        # hydra (10.10.13.109) at 8:0:20:c3:31:e1 permanent published

        ping($host) || return undef;
        open(ARP, "$arpCmd $host |");
        $_ = <ARP>;
        $mac = (split(/\s+/, $_))[3];
        close(ARP);

    } elsif ($os eq 'hpux') {

        # localhost case
        if ($host eq hostname()) {

            $mac = macAddressForVirtualOnHPUX('default');

        } else {

            # On hpux /usr/sbin/arp, /usr/sbin/ping
            # tobago.ariba.com (10.10.13.158) at 0:30:6e:6:c4:e3 ether
            ping($host) || return undef;
            open(ARP, "$arpCmd $host |");
            $_ = <ARP>;
            $mac = (split(/\s+/, $_))[3] if defined $_;
            close(ARP);

            # virtual, but local to this machine case.
            if (!defined $mac or $mac eq 'no') {
                $mac = macAddressForVirtualOnHPUX( hostToAddr($host) );
            }

            # if we get a 'no hostname' return from arp.
            $mac = undef if defined $mac and $mac eq 'no';
        }

    } else {

        # this only works on linux and solaris and hpux
        die "Error: macAddress() for host supported only on hpux, solaris and linux\n";
        $mac = undef;
    }

    return formatMacAddress($mac);
}

sub macAddressForVirtualOnLinux {

    my $host = shift;
    my $mac;

    #eth0      Link encap:Ethernet  HWaddr 00:13:21:07:42:4F  
    #  inet addr:216.109.110.187  Bcast:216.109.110.255  Mask:255.255.255.128
    #  UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
    #  RX packets:1130401466 errors:0 dropped:0 overruns:0 frame:0
    #  TX packets:1531102239 errors:0 dropped:0 overruns:0 carrier:0
    #  collisions:0 txqueuelen:1000 
    #  RX bytes:252277718962 (234.9 GiB)  TX bytes:1337112495990 (1.2 TiB)
    #  Interrupt:201 
    #
    #eth0:0    Link encap:Ethernet  HWaddr 00:13:21:07:42:4F  
    #  inet addr:216.109.110.185  Bcast:216.109.110.255  Mask:255.255.255.128
    #  UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
    #  Interrupt:201 
    #
    open(IFCONFIG, "/sbin/ifconfig |") or die "Unable to run ifconfig: $!";
    chomp(my @results = <IFCONFIG>);
    close(IFCONFIG);

    foreach my $line (@results) {

        my $ip;

        if ($line =~ /^[a-z]+[0-9]+.+Hwaddr (\w+:\w+:\w+:\w+:\w+:\w+)/i) {
            $mac = $1;
        }
        elsif ($line =~ /inet addr:(\d+\.\d+\.\d+\.\d+)/i) {
            $ip = $1;
        }

        if (defined $mac and defined $ip) {

            last if ($ip eq hostToAddr($host));

            $mac = undef;
        }
    }

    return $mac;
}

sub macAddressForVirtualOnHPUX {
    my $addr = shift;

    # first find the default interface
    my ($interface,$mac);

    open(NETSTAT, "/bin/netstat -rn |");

    while(<NETSTAT>) {
        next unless /^$addr/;
        my @cols = split(/\s+/);
        shift(@cols);
        for my $col (@cols) {
            if ($col =~ m|^lan\d+|) {
                $interface = $col;
                $interface =~ s/:\d+//g;
                last;
            }
        }
    }

    close(NETSTAT);

    return undef unless defined $interface;

    # then pull out the mac address for that interface
    # 0x001083FF4B59
    open(ARP, "/usr/sbin/lanscan -a -i|");
    while(<ARP>) {
        next unless /$interface/;
        $mac = lc((split /\s+/)[0]);
    }
    close(ARP);

    return $mac;
}

#
# get oui.txt from http://standards.ieee.org/regauth/oui/oui.txt
#
sub vendorForMacAddress {
    my $macAddr = shift;
    my $ouiFile = shift;

    # cache the ouiDB
    unless (scalar keys %ouiDB > 0) {

        open(OUIDB, $ouiFile) or do {
            warn "Couldn't read OUI DB: $ouiFile : $!";
            return;
        };

        #
        #OUI                             Organization
        #company_id                      Organization
        #                                Address
        #
        #
        #00-00-00   (hex)                XEROX CORPORATION
        #000000     (base 16)            XEROX CORPORATION
        #                                M/S 105-50C
        #                                800 PHILLIPS ROAD
        #                                WEBSTER NY 14580
        #                                UNITED STATES
        #
        #00-00-01   (hex)                XEROX CORPORATION
        #000001     (base 16)            XEROX CORPORATION
        #                                ZEROX SYSTEMS INSTITUTE
        #                                M/S 105-50C 800 PHILLIPS ROAD
        #                                WEBSTER NY 14580
        #                                UNITED STATES
        #
        #
        while (my $line = <OUIDB>) {
            chomp($line);
            next if ($line !~ /\(hex\)/);
            my ($macHexPrefix, $format, $company) = split (/\s+/, $line, 3);
            my $macPrefix = formatMacAddress($macHexPrefix);
            $ouiDB{$macPrefix} = $company;
        }

        close(OUIDB);
    }

    # Normalize the mac address
    my $macMatch = join(':', (split /:/, formatMacAddress($macAddr))[0,1,2]);

    return $ouiDB{$macMatch} || 'Unknown Vendor';
}

sub ipForHost {
    my ( $host ) = @_;

    return sprintf("%d.%d.%d.%d", unpack("CCCC", inet_aton("$host")));
}

# in snmp queries, some returned integer values such as port or index lists
# are in packed string form with length 4 and need converted back to numbers
# in case multiple of these object values are packed into one string
# this subroutine split them and convert each into numbers.
# an example of these is CISCO-LAG-MIB::clagAggPortListInterfaceIndexList
#
sub snmpOctetstrToNumbers {
    my $packedstr = shift;
    my @numlist = ();
    
    # process it only if the string length is multiple of 4
    unless ( length($packedstr) % 4 ) {
        my $i = 0;
        while ( my $ss = substr($packedstr, $i, 4) ) {
            $i += 4;

            # convert to d.d.d.d form
            my $octstr = inet_ntoa($ss); 

            # convert to integers
            my @octets = split(/\./, $octstr);
            $octets[0] <<= 24;
            $octets[1] <<= 16;
            $octets[2] <<= 8;

            my $val = $octets[0] + $octets[1] + $octets[2] + $octets[3];
            
            push @numlist, $val;
        }
    }

    return @numlist;
}

1;

__END__

=head1 NAME

Ariba Network Operations Network Utilities

=head1 SYNOPSIS

use ariba::Ops::NetworkUtils;

=head1 DESCRIPTION

Available functions (not exported by default):

$addr = hostToAddr( $host )

$host = addrToHost( $addr )

$addr = defaultRouteForTier( $tier, $domain )

setDefaultRouteForTier( $addr )

updateHostFile( $host )

$netnet = hostnameToNetname( $host )

$tier = hostnameToTier( $host )

$domain = domainForHost( $host/$addr )

true/false = isIPAddr( $addr )

true/false = isFQDN( $host )

$url = mrtgUrl( $host, $webserver )

=head1 EXAMPLES

use ariba::Ops::NetworkUtils qw(defaultRouteForTier domainForHost);

use Sys::Hostname;

my $tier = $ARGV[0];

my $host = $ARGV[1] || hostname();

my $route = defaultRouteForTier($tier, domainForHost($host));

print "$host -> route: $route\n";

my $mac = macAddressForHost($host);

=head1 AUTHOR

Daniel Sully <dsully@ariba.com>, Chris Williams <cgw@ariba.com>

=cut
