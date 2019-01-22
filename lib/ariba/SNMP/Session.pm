package ariba::SNMP::Session;

# $Id: //ariba/services/tools/lib/perl/ariba/SNMP/Session.pm#9 $

use strict;
use base qw(ariba::Ops::PersistantObject);
use Scalar::Util;

use Data::Dumper;

BEGIN {
    my $mc = `uname -m`;
    chop($mc);
    if ($mc eq "x86_64" || $^O eq "solaris") {
        require "SNMP.pm";
        #
        # Meaning of how the snmp mib dirs get traversed between snmp
        # version 5.0.8 (one we have on solaris) and on
        # version 5.3.1 or 5.4 (one we have on redhat 4 64 bit)
        #
        # Look at: mib.c:netsnmp_set_mib_directory()
        #
        if ($SNMP::VERSION eq "5.0.8") {
            $ENV{'MIBDIRS'} = "+$ENV{'HOME'}/lib/mibs";
        } else {
            $ENV{'MIBDIRS'} = "-$ENV{'HOME'}/lib/mibs";
        }
    }
}

$ENV{'MIBS'}    = 'ALL';

my $mibInitialized = 0;
my $debug = 0;
$SNMP::debugging = $debug;

my $fixedDisk = '.1.3.6.1.2.1.25.2.1.4';

#
# for use with the pseudo-oid interfaceStats that gets expanded
# into In/Out/Error/etc. for each interface
#
my $PSEUDO_INTERFACE_LOW_CAPACITY = "LowCapacity";
my $PSEUDO_INTERFACE_HIGH_CAPACITY = "HighCapacity";
my $PSEUDO_INTERFACE_ERRORS = "Error";
my $PSEUDO_INTERFACE_DEFAULT = $PSEUDO_INTERFACE_HIGH_CAPACITY;



# Class methods
sub newFromMachine {
    my $class   = shift;
    my $machine = shift;

    my $self    = $class->SUPER::new($machine->hostname());

    # set some reasonable defaults
    $self->setHostname( $machine->hostname() );
    $self->setHostOs( $machine->os() );
    $self->setCommunity( $machine->snmpCommunity() || 'public' );
    $self->setVersion( $machine->snmpVersion() || 2 );
    $self->setPort( $machine->snmpPort() || 161 );
    $self->setGetNext(0);
    $self->setEnums(1);
    $self->setTimeout(2);

    # For some reason I haven't yet figured out, the effective snmp retry
    # (from observing strace) is apparently: 5 * ($RETRIES + 1). So, with
    # ariba::SNMP::Session sets default retries to 5, the effective num of
    # retries is 30. And, to make matters worse, ariba::SNMP::Session forces
    # a minimum timeout of 30 secs for bulk-walk requests, so non-responsive
    # devices can each take 15 minutes to fully timeout! In an effort to
    # hurry this along somewhat, we can set retries to "1", which effectively
    # is 5 * (1 + 1) = 10 retries at 30 secs each = 5 minutes.
    $self->setRetry(1);

    return $self;
}

# No backing store
sub dir {
    return undef;
}

# Instance methods

sub save {
    return undef;
}

sub recursiveSave {
    return undef;
}

# connect() can be called multiple times if the values need to change.
# 
# This can be the case for walking the dot1d table on cisco switches, where
# one needs to reset the community string to be $community@vlan - this is done
# via a "fingerprint" of the attributes, to see if a $snmp->setVlan() or any
# other change was made, in which case we'll create a new SNMP session to the device.

sub connect {
    my $self = shift;

    my $hostname    = $self->hostname();
    my $community   = $self->community();
    my @fingerprint = ();

    for my $attribute (sort $self->attributes()) {
        next if $attribute eq 'fingerprint';
        next if $attribute eq 'session';

        push @fingerprint, $self->attribute($attribute);
    }

    my $hash = join(':', @fingerprint);

    # if none of our values have changed, return the same session if it still exists.
    if (defined $self->session() && defined $self->fingerprint() && $self->fingerprint() eq $hash) {
        return $self->session();
    }

    # Cisco routers require this when looking at the dot1d table.
    if (defined $self->vlan()) {
        $community = sprintf('%s@%s', $community, $self->vlan());
    }

    my $Retries        = $self->retry();
    my $Timeout        = $self->timeout() * 1000000;
    my $Version        = $self->version();
    my $RemotePort     = $self->port();
    my $UseEnums       = $self->enums();
    my $UseSprintValue = $self->sprintValue() || $SNMP::use_sprint_value;

    # This is for v3
    my $SecName      = $self->secName();
    my $AuthPass     = $self->authPass();
    my $PrivPass     = $self->privPass();


    my $session  = SNMP::Session->new(
        'DestHost'       => $hostname,
        'Community'      => $community,
        'Retries'        => $Retries,
        'Timeout'        => $Timeout,
        'Version'        => $Version,
        'RemotePort'     => $RemotePort,
        'UseEnums'       => $UseEnums,
        'UseSprintValue' => $UseSprintValue,

        # This is for v3
        'SecName'    => $SecName,
        'SecLevel'   => 'authPriv',
        'AuthPass'   => $AuthPass,
        'PrivPass'   => $PrivPass,

    ); 

    unless ($session) {
        warn "no session for [$hostname]: $!";
        return 0;
    }
    if ($session) {
        $self->setSession($session);
        $self->setFingerprint($hash);
    }

    return $session;
}

sub valueForOidExpr {
    my $self      = shift;
    my $oidString = shift;

    my $class     = ref($self);

    my ($eval, %oids) = $self->parseOidExpr($oidString);

    if ($eval eq $oidString) {
        return $oidString;
    }

    return if $self->hostIsDown();

    my $session = $self->connect() || return;

    for my $oid (keys(%oids)) {
        my $varObj = $oid;
        my $vars;
        my $value;

        if ($self->getNext()) {
            $vars = SNMP::VarList->new([$varObj]);
            $value = $session->getnext($vars);
        } else {
            $value = $session->get($oid);
        }

        # Don't retry getnext or get as Net::SNMP already does it automatically
        # with its Retries setting. Doing it here would double retries. TMID: 95924

        my $errno  = $session->{'ErrorNum'};
        my $errmsg = $session->{'ErrorStr'};

        print "get of $oid error ($errno) : $errmsg\n" if $errno && $debug;

        # if the host is down, return a status to caller to indicate
        # that it should not try other oids on this host
        if ($errmsg =~ m|Timeout|i) {
            $self->setHostIsDown(1);
        }

        # if one of the values in expr is undefined, return
        # undefined for the whole thing
        #
        # fix errors like:
        # Argument "" isn't numeric in divide at (eval 632) line 1.
        # 
        # SNMP v2 introduces NOSUCHINSTANCE return value
        if (!defined($value) || $value eq "" || $value eq "NOSUCHINSTANCE") {
            if (wantarray()) {
                return (undef, $self->hostIsDown());
            } else {
                return undef;
            }
        }

        # clean quoted strings, (eg. description)
        # like:
        # PIX Firewall 'outside' interface
        # to just:
        # outside
        $value =~ s!.*\'([^\']*)\'.*!$1!g;
        $value =~ s!.*\"([^\"]*)\".*!$1!g;

        #
        # HACK -- some of our devices have integer overflow problems.
        # we'll convert to unsigned here to fix.
        #
        if($self->version() == 1 && $self->hostOs() eq 'ontap') {
            if($value =~ /^-\d+$/) {
                $value = unpack("I", pack("i", $value));
            }
        }

        $oids{$oid} = $value;
    }

    my $result = eval($eval);

    if (wantarray()) {
        return ($result, $self->hostIsDown());
    } else {
        return $result;
    }
}

sub walkOidExpr {
    my $self      = shift;
    my $oidString = shift;
    my $oidName   = shift || "";
    
    return () if ($self->hostIsDown());

    my $session = $self->connect() || return;

    #    from perldoc SNMP
    #
    #    $sess->getnext(<vars> [,<callback>])
    #        do SNMP GETNEXT, multiple <vars> formats accepted,
    #        returns retrieved value(s), <vars> passed as arguments
    #        are updated to indicate next lexicographical
    #        <obj>,<iid>,<val>, and <type>
    #
    #        Note: simple string <vars>,(e.g., 'sysDescr.0') form is
    #        not updated. If <callback> supplied method will operate
    #        asyncronously
    #
    #
    #     SNMP::VarList
    #         represents an array of MIB objects to get or set,
    #         implemented as a blessed reference to an array of
    #         SNMP::Varbinds, (e.g., [<varbind1>, <varbind2>, ...])
    #
    #     SNMP::Varbind
    #         represents a single MIB object to get or set,
    #         implemented as a blessed reference to a 4 element array;
    #         [<obj>, <iid>, <val>, <type>].

    my %oidList = ();
    my %fullyQualifiedList = ();
    my $multipleOids = 0;
    my $class = ref($self);

    my ($eval, %oidsHash) = $class->parseOidExpr($oidString);

    $multipleOids = (keys %oidsHash > 1);

    for my $oid (keys(%oidsHash)) {
        my $varObj = $oid;
        $varObj =~ s/\.([^\.]*)$//;
        my $varIid = $1;

        my $walkObj = $varObj;
        my @inferredObjs = ();

        # special case stats we obtain on interfaces.
        # do not get add interfaces that do not have traffic
        # to the list to be sampled. Also if the interface
        # has traffic, add other interesting stats to the list
        # as well.

        my $interfaceStatType = _interfaceStatTypeForPseudoOid($varObj);
        if ($interfaceStatType) {
            @inferredObjs = _realInterfaceOidsForInterfaceStatType($interfaceStatType);
            $walkObj = shift(@inferredObjs);
        }

        my $vars = SNMP::VarList->new([$walkObj,$varIid]);

        $session->getnext($vars);

        if ($session->{'ErrorNum'}) {
            if ($debug) {
                printf("%s error (%s) : %s\n", $walkObj, $session->{'ErrorNum'}, $session->{'ErrorStr'});
            }

            $session->getnext($vars);
        }

        # if the host is down, don't try other oids
        if ($session->{'ErrorStr'} && $session->{'ErrorStr'} =~ m|Timeout|i) {
            $self->setHostIsDown(1);
            last;
        }

        while (!$session->{'ErrorNum'}) {
            #
            # vars is a list of varbinds, and we have just 
            # varbind in our list (0th element)
            #
            # varbind in turn is obj, iid, value, type
            # so print obj.iid = value (type)
            #
            my $obj  = $vars->[0]->[0];
            my $iid  = $vars->[0]->[1];
            my $val  = $vars->[0]->[2];
            my $type = $vars->[0]->[3];

            if ($vars->[0][0] !~ /^$walkObj\b/) {
                last;
            }

            #
            # should be done before the 'next' in the
            # conditional below
            #
            $session->getnext($vars);

            #
            # add interfaces to the list, only if there
            # is traffic.
            #
            if ($interfaceStatType) {
                if ($interfaceStatType eq $PSEUDO_INTERFACE_ERRORS) {
                    my $interfaceHasTraffic = $self->valueForOidExpr("ifInOctets.$iid");
                    next unless ($interfaceHasTraffic);
                } elsif (!$val && $val <= 0) {
                    next; # make sure $session->getnext is called before
                          # hitting the next cycle
                }
            }
            #
            # ASA5585s have interface stats that return No Such Instance currently exists
            # and we want to ignore those interfaces See TMID:115334
            #
            if ($val =~ /No Such Instance currently exists/i) {
                next if($self->hostname() =~ /asa5585/i);
                     # make sure $session->getnext is called before
                        # hitting the next cycle
            }
            #
            # CSS11501 has an add on module thet reports memory and cpu slots
            # with 0 values.  See TMID:62890
            #
            if ($varObj =~ /apChassisMgrExtSubModule/ && (!$val && $val <= 0) ) {
                next; # make sure $session->getnext is called before
                      # hitting the next cycle
            }

            # this checks the hrStorageType to verify we
            # have a fixed disk, as opposed to a network
            # disk.
            if ($walkObj =~ /hrStorage/) {
                my $storageType = $self->valueForOidExpr("hrStorageType.$iid") || '';

                print "DEBUG: matched!: [$walkObj.$iid] type: [$storageType]\n" if $debug;

                next if $storageType ne $fixedDisk;
            }
            # FusionIO cards return "NOSUCHINSTANCE" if you query a non-existant device ID
            if ($walkObj =~ m/fusionIoDrv/ && $val =~ /NOSUCHINSTANCE/i) {
                next; # move on
            }

            # resolve the description, if given one.
            my $name = "$obj.$iid";
            my $fullName = "$obj.$iid";
            my $expandedName;

            if ($oidName) {
                $expandedName = $oidName;

                # For Cisco Class-based QOS OIDs, there is an extra index to
                # look up an IID in order to get the config's name
                if($walkObj =~ m/cbQos/) {
                    my $indexOid = "cbQosConfigIndex.$iid";
                    my $configIid = $self->valueForOidExpr($indexOid);
                    $expandedName =~ s/\.\d([^\d\.])/\.$configIid$1/g;
                } else {
                    $expandedName =~ s/\.\d([^\d\.])/\.$iid$1/g;
                }

                $expandedName = $self->valueForOidExpr($expandedName);

                $expandedName =~ s|/|:|g;

                if ($multipleOids or !$interfaceStatType) {
                    $name = $expandedName;
                    $fullName = $expandedName;
                } else {
                    $name = "$obj $expandedName";
                    $fullName = "$obj.$iid $expandedName";
                }
            }

            # if this oidString has multiple oids in it, 
            # grab the previous value, and substitute
            my $oidExpr = defined($oidList{$name}) ?  $oidList{$name} : $oidString;
            $oidExpr =~ s/\b$oid\b/$obj.$iid/g;

            $oidList{$name} = $oidExpr;
            $fullyQualifiedList{$fullName} = $oidExpr;

            for my $iobj ( @inferredObjs ) {
                my $oidExpr = $oidString;
                $oidExpr =~ s/\b$oid\b/$iobj.$iid/g;

                $name = "$iobj.$iid";
                $fullName = "$iobj.$iid";

                if ($expandedName) {
                    $name = "$iobj $expandedName";
                    $fullName = "$iobj.$iid $expandedName";
                }

                $oidList{$name} = $oidExpr;
                $fullyQualifiedList{$fullName} = $oidExpr;
            }
        } 

        if ($debug && $session->{'ErrorNum'}) {
            printf("%s error (%s) : %s\n", $walkObj, $session->{'ErrorNum'}, $session->{'ErrorStr'});
        }
    }

    #
    # If there were name collisions without using fully qualified
    # oid names, return the assoc array with fully qualified oids
    #
    if (keys(%fullyQualifiedList) > keys(%oidList)) {
        return (%fullyQualifiedList);
    } else {
        return (%oidList);
    }
}

sub _walkTheWalk {
        my $self = shift;
        my @oids = @_;

        # bulk walking needs version 2
        $self->setVersion(2);

        my $session = $self->connect() || return;

        my @vars    = map { [ $_ ] } @oids;

        my @responses = ();
        for my $var (@vars) {
                my @bulkWalk = $session->bulkwalk(0, 512, [ $var ]);
                push (@responses, @bulkWalk);
        }

        return @responses;
}

# F5 and CSS walks return differet data structures.  This subroutine is hard coded
# to mach the redundancy-check::checkIpPool subroutine for monitoring.
# Yes it's ugly, but so is SNMP so this is what you get :)
#
# Returns a hash of the format:
# values = (
#     <index> = {
#         name => '<string>',
#         value => '<number>',
#     },
#     <index> = { ...
# )

sub bulkWalkOidsF5 {
        my $self = shift;
        my @oids = @_;

        my @responses = $self->_walkTheWalk( @oids );

    # The last 6 numbers in an OI also appear near the beginning of the 'name' result.
    # If we strip out these numbers and anything that appears before them we're left
    # with a unique id that is used to match results from differet oid walks.
    # Hackey?  You bet.  Go ahead and implement something better.
    my @oidTails;
    for my $oid (@oids) {
        $oid =~ /.*((\.\d+){6})$/;
        push ( @oidTails, $1 );
    }

    my %values;
    for my $response (@responses) {
        for my $var (@$response) {
            my $name = $var->name();
            my $value  = $var->val();

            my $index;
            for my $tail ( @oidTails ) {
                if ( $name =~ /.*?$tail(.+)/ ) {
                    $index = $1;
                }
            }

            if ( Scalar::Util::looks_like_number( $value )) {
                $values{ $index }->{ value } = $value;
            } else {
                $values{ $index }->{ name } = $value;
            }
        }
    }

    return \%values;
}

sub bulkWalkOids {
    my $self = shift;
    my @oids = @_;

    my @responses = $self->_walkTheWalk( @oids );

        my %values;
    # Key by IID - so the caller can map between ports and interfaces
    for my $response (@responses) {
        for my $var (@$response) {
            my $iid  = $var->iid();
            my $name = $var->name();
            my $val  = $var->val();

            # values are returned with double quotes when running in production.
            # stripping out the quotes.
            $name =~ s/\.[\d\.]+//g;
            $val =~ s/"//g;

            $values{$iid}->{$name} = $val;
        }
    }

    return \%values;
}

sub setValueForOid {
    my $self  = shift;
    my $oid   = shift;
    my $value = shift;

    # writing requires v3 with views
    $self->setVersion(3);

    my $session = $self->connect() || return;

        return $session->set($oid, $value);
}

# Utility functions
sub parseOidExpr {
    my $class  = shift;
    my $string = join("", @_);

    my $eval   = $string;
    my %oids   = ();

    # Colon needs to be allowed for things like:
    # CISCO-STACK-MIB::portDuplex
    while ($string =~ m/(\.?[\d\w:-]+\.[\d\w\.-]+)/) {
        my $match = $1;

        $oids{$match} = undef;

        my $replaceMatch = quotemeta($match);
        $eval =~ s/$replaceMatch/\$oids\{'$match'\}/g;
        #$eval =~ s/\b$replaceMatch\b/\$oids\{"$match"\}/g;

        #print "string = $string, match = $match, eval = $eval\n";

        $string =~ s/$replaceMatch//g;
        #$string =~ s/\b$replaceMatch\b//g;
    }

    return ($eval, %oids);
}

sub oidType {
    my $class     = shift;
    my $oidString = shift;

    my $type;

    my ($eval, %oidsHash) = $class->parseOidExpr($oidString);
    my @oids = keys(%oidsHash);

    return $type unless(@oids);

    unless ($mibInitialized++) {
        # need to do this for getType to work
        SNMP::initMib(); 
    }

    for my $oid (@oids) {
        $oid =~ s/\.([^\.]*)$//;

        # this wasn't a human readable oid like what getType() wants - translate it.
        if ($oid =~ /^[\.\d]+$/) {
            $oid = SNMP::translateObj($oid);
        } else {
            # Remove numeric endings from oids to get the actual type.
            # For example, transform CSS oids such as
            # apSvcCurrentLocalConnections.10.119.101.98.49.57.46.56.52.52.56
            #   and
            # apSvcCurrentLocalConnections.10.119.101.98.49.57.46.56.52.52.56
            # into 
            # apSvcCurrentLocalConnections and apSvcCurrentLocalConnections.
            #
            # The leading '\.' is needed to avoid consuming embedded
            # digits in the word part of the oid, for an oid like
            # foo5.33.2.787
            #
            $oid =~ s/\.[\d.]*$//;
        }

        my $newType = SNMP::getType($oid);

        # This is a workaround - computerSystemPhysMemory.0 from the HP-UNIX mib 
        # does not return a valid type, so it defaults to 'INTEGER'
        if ($oid =~ /computerSystemPhysMemory/) {
            $newType = 'GAUGE';
        }

        if ($oid =~ /filesystemB/i && !defined($newType)) {
            $newType = 'INTEGER';
        }

        if ($oid =~ /hrMemorySize/i) {
            $newType = 'INTEGER';
        }

        # these are custom OIDs that don't have a native type
        # these are defined in net-snmp's snmpd.conf
        if ($oid =~ /2021\.5[12]\.101/i && !defined($newType)) {
            $newType = 'INTEGER';
        }

        # custom OIDs for NFS need to be set explicitly for graphing purposes.
        # This is a terrible, terrible hack that was added god knows when.
        #
        # $ snmpwalk -c public -v1 localhost nsExtendOutput2Table
        # NET-SNMP-EXTEND-MIB::nsExtendOutLine."nfsV3MbWritten".1 = STRING: 15799952.867328
        # $ snmpwalk -c public -v1 -On localhost nsExtendOutput2Table
        # .1.3.6.1.4.1.8072.1.3.2.4.1.2.14.110.102.115.86.51.77.98.87.114.105.116.116.101.110.1 = STRING: 15799952.867328
        #
        # See TMID 32659 for more details.
        
        # Here are the OIDs coming in via rebuild-queries:
        #
        # nsExtendOutLine.11.110.102.115.86.51.65.99.99.101.115.115
        # nsExtendOutLine.12.110.102.115.86.51.71.101.116.65.116.116.114
        # nsExtendOutLine.11.110.102.115.86.51.76.111.111.107.117.112
        # nsExtendOutLine.11.110.102.115.86.51.77.98.82.101.97.100
        # nsExtendOutLine.14.110.102.115.86.51.77.98.87.114.105.116.116.101.110
        # nsExtendOutLine.13.110.102.115.86.51.82.101.97.100.73.79.80.83
        # nsExtendOutLine.14.110.102.115.86.51.87.114.105.116.101.73.79.80.83
        
        my @nfs_oids = qw/
            nsExtendOutLine.14.110.102.115.86.51.77.98.87.114.105.116.116.101.110
            nsExtendOutLine.11.110.102.115.86.51.65.99.99.101.115.115
            nsExtendOutLine.11.110.102.115.86.51.76.111.111.107.117.112
            nsExtendOutLine.11.110.102.115.86.51.77.98.82.101.97.100
            nsExtendOutLine.12.110.102.115.86.51.71.101.116.65.116.116.114
            nsExtendOutLine.13.110.102.115.86.51.82.101.97.100.73.79.80.83
            nsExtendOutLine.14.110.102.115.86.51.87.114.105.116.101.73.79.80.83
            nsExtendOutLine.11.110.102.115.86.51.82.101.109.111.118.101
        /;

        if ( grep ( /$oid/, @nfs_oids ) ) {
            $newType = 'COUNTER';
        }

        if ($type && $type ne $newType) {
            $type = undef;
            last;
        }

        $type = $newType;
    }

    $type =~ s/\d+$// if $type;
    $type = lc($type) if $type;

    return $type;
}

sub DESTROY {
    my $self = shift;

    $self->close();
}

sub close {
    my $self = shift;

    $self->deleteSession();
}

# 
# returns number of bits (32 or 64) to expand the fake interface oid,
# or 0 (false) if it is not one of the fake interface oids
#

sub _interfaceStatTypeForPseudoOid {
    my $oid = shift;

    if ($oid =~ /^interfaceStats($PSEUDO_INTERFACE_LOW_CAPACITY|$PSEUDO_INTERFACE_HIGH_CAPACITY|$PSEUDO_INTERFACE_ERRORS)?$/) { 
        my $statType = $1 || $PSEUDO_INTERFACE_DEFAULT;
        return $statType;
    } 
    return 0;
}


my @oidsForLowCapacity = qw(
    ifInOctets
    ifOutOctets
);

my @oidsForHighCapacity = qw(
    ifHCInOctets
    ifHCOutOctets
);

my @oidsForInterfaceErrors = qw(
    ifInErrors
    ifOutErrors
    ifInDiscards
    ifOutDiscards
);

#
# return real interface oids to walk for a given interfaceStatType
# low (32 bit) or high (64 bit)
#
sub _realInterfaceOidsForInterfaceStatType {
    my $interfaceStatType = shift || $PSEUDO_INTERFACE_DEFAULT;

    my @oids;

    if ($interfaceStatType eq $PSEUDO_INTERFACE_LOW_CAPACITY) {
        @oids = @oidsForLowCapacity;
    } elsif ($interfaceStatType eq $PSEUDO_INTERFACE_HIGH_CAPACITY) {
        @oids = @oidsForHighCapacity;
    } elsif ($interfaceStatType eq $PSEUDO_INTERFACE_ERRORS) {
        @oids = @oidsForInterfaceErrors;
    } else {
        die "ERROR: ".__PACKAGE__."::_realInterfaceOidsForInterfaceStatType invalid interfaceStatType [$interfaceStatType]";
    }

    return @oids;
}

1;
