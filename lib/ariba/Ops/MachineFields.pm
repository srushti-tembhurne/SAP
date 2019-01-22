# $Id$

package ariba::Ops::MachineFields;

use strict;
use vars qw($fields $valueValidationMap $dataCenters);
use ariba::Ops::Constants;
use ariba::rc::Globals;
use JSON;

my $globalDir = $ariba::rc::Globals::GLOBALDIR;

$dataCenters = [ parseValidFields('datacenters.json') ];

$fields = {
    'serialNumber'  => {
        'desc'       => 'Serial Number of Device',
        'values'     => [ qw(text) ],
        'required'   => 0,
        'saRequired' => 1,
    },

    'assetTag'  => {
        'desc'       => 'Ariba Asset Tag',
        'values'     => [ qw(digits) ],
        'required'   => 0,
        'saRequired' => 0,
    },

    'hardwareVendor'    => {
        'desc'       => 'Hardware Vendor',
        'values'     => [ parseValidFields('hardwareVendors.json') ], 
        'required'   => 0,
        'saRequired' => 1,
    },

    'hardwareType'  => {
        'desc'       => 'Hardware Model',
        'values'     => [ parseValidFields('hardwareTypes.json') ],
        'required'   => 0,
        'saRequired' => 1,
    },

    'arch'  => {
        'desc'       => 'Hardware Architecture',
        'values'     => [ parseValidFields('arches.json') ],
        'required'   => 0,
        'saRequired' => 1,
    },

    'maintenance'   => {
        'desc'       => 'Maintenance Level/Contract Number',
        'values'     => [ qw(text) ],
        'required'   => 0,
        'saRequired' => 0,
    },

    'os'        => {
        'desc'       => 'Operating System',
        'values'     => [ parseValidFields('os.json') ], 
        'required'   => 0,
        'saRequired' => 1,
    },

    'osVersion' => {
        'desc'       => 'Operating System Version',
        'values'     => [ qw(text) ],
        'required'   => 0,
        'saRequired' => 1,
    },

    'osPatchLevel'  => {
        'desc'       => 'Operating System Patch Level',
        'values'     => [ qw(text) ],
        'required'   => 0,
        'saRequired' => 1,
    },

    'providesServices'  => {
        'desc'       => 'Services this machine provides',
        'values'     => [ (parseValidFields('providesServices.json')) ], 
        'required'   => 1,
        'saRequired' => 1,
        'multiple'   => 1,
    },

    'datacenter'    => {
        'desc'       => 'Datacenter Location',
        'values'     => $dataCenters ,
        'required'   => 0,
        'saRequired' => 1,
    },

    'monitoringDatacenter'  => {
        'desc'       => 'Datacenter to send monitoring data to',
        'values'     => $dataCenters ,
        'required'   => 0,
        'saRequired' => 0,
    },

    'macAddr'   => {
        'desc'       => 'MAC Address',
        'values'     => [ qw(macaddress) ],
        'required'   => 0,
        'saRequired' => 1,
    },

    'macAddrSecondary'  => {
        'desc'       => 'Secondary MAC Address',
        'values'     => [ qw(macaddress) ],
        'required'   => 0,
        'saRequired' => 0,
    },

    'macAddrTernary'    => {
        'desc'       => 'Third MAC Address',
        'values'     => [ qw(macaddress) ],
        'required'   => 0,
        'saRequired' => 0,
    },

    'macAddrQuadrary'   => {
        'desc'       => 'Fourth MAC Address',
        'values'     => [ qw(macaddress) ],
        'required'   => 0,
        'saRequired' => 0,
    },

    'macAddrConsole'    => {
        'desc'       => 'Console MAC Address',
        'values'     => [ qw(macaddress) ],
        'required'   => 0,
        'saRequired' => 1,
    },

    'monserverForDatacenter'    => {
        'desc'       => 'Defines host as monserver for the datacenter',
        'values'     => [ qw(0 1) ],
        'required'   => 0,
        'saRequired' => 0,
    },

    'ipAddr'    => {
        'desc'       => 'IP Address',
        'values'     => [ qw(dottedquad) ],
        'required'   => 0,
        'saRequired' => 1,
    },

    'ipAddrSecondary'   => {
        'desc'       => 'Secondary IP Address',
        'values'     => [ qw(dottedquad) ],
        'required'   => 0,
        'saRequired' => 0,
    },

    'ipAddrAdmin'   => {
        'desc'       => 'Admin IP Address',
        'values'     => [ qw(dottedquad) ],
        'required'   => 0,
        'saRequired' => 0,
    },

    'extBgpPeerAddr'    => {
        'desc'       => 'IP Address of External BGP Peer',
        'values'     => [ qw(dottedquad) ],
        'required'   => 0,
        'saRequired' => 0,
    },

    'hostname'  => {
        'desc'       => 'Hostname',
        'values'     => [ qw(hostname) ],
        'required'   => 0,
        'saRequired' => 1,
    },

    'dnsDomain' => {
        'desc'       => 'DNS Domain',
        'values'     => [ qw(domain) ],
        'required'   => 0,
        'saRequired' => 1,
    },

    'defaultRoute'  => {
        'desc'       => 'Default Route',
        'values'     => [ qw(dottedquad) ],
        'required'   => 0,
        'saRequired' => 1,
    },

    'netmask'   => {
        'desc'       => 'Netmask',
        'values'     => [ qw(dottedquad) ],
        'required'   => 0,
        'saRequired' => 0,
    },

    'consoleServer'=> {
        'desc'       => 'Serial Console Server',
        'values'     => [ qw(consoleServer) ],
        'required'   => 0,
        'saRequired' => 1,
    },

    'consoleServerPort' => {
        'desc'       => 'Serial Console Server Port',
        'values'     => [ qw(digits) ],
        'required'   => 0,
        'saRequired' => 1,
    },

    'consoleHostName'   => {
        'desc'       => 'Console Host Name',
        'values'     => [ qw(hostname) ],
        'required'   => 0,
        'saRequired' => 1,
    },

    'networkSwitch' => {
        'desc'       => 'Network Switch the machine is plugged into',
        'values'     => [ qw(hostname) ],
        'required'   => 0,
        'saRequired' => 0,
    },

    'networkSwitchSecondary'    => {
        'desc'       => 'Secondary Network Switch the machine is plugged into',
        'values'     => [ qw(hostname) ],
        'required'   => 0,
        'saRequired' => 0,
    },

    'networkSwitchPort' => {
        'desc'       => 'Switch Port the machine is plugged into',
        'values'     => [ qw(port) ],
        'required'   => 0,
        'saRequired' => 0,
    },

    'networkSwitchPortSecondary'    => {
        'desc'       => 'Secondary Switch Port the machine is plugged into',
        'values'     => [ qw(port) ],
        'required'   => 0,
        'saRequired' => 0,
    },

    'useSsh'    => {
        'desc'       => 'Monitoring will use ssh to log into the device instead of telnet if set to 1.  '
                  .  'If set to 2, monitoring will not use the username@host syntax',
        'values'     => [ qw(0 1 2) ],
        'required'   => 0,
        'saRequired' => 0,
    },

    'rackNumber'    => {
        'desc'       => 'Rack Number',
        'values'     => [ qw(rackNumber) ],
        'required'   => 0,
        'saRequired' => 1,
    },

    'rackPosition'  => {
        'desc'       => 'Rack Position',
        'values'    => [ qw(rackPosition) ],
        'required'   => 0,
        'saRequired' => 1,
    },

    'rackPorts' => {
        'desc'       => 'Rack Network Port',
        'values'     => [ qw(text) ],
        'required'   => 0,
        'saRequired' => 0,
    },

    'status'    => {
        'desc'       => 'Status',
        'values'     => [ qw(ordered inservice outofservice spare) ],
        'required'   => 1,
        'saRequired' => 1,
    },

    'owner'     => {
        'desc'       => 'Owning Group',
        'values'     => [qw(
                            ops devadmin unassigned
                            ais-dev ais-dev2 ais-dev3 ais-dev4 ais-dev5 ais-hf ais-itg ais-load ais-load2
                            ais-mach ais-mig ais-mig2 ais-qa ais-rel ais-sp ais-stage ais-test 
                            an-dev an-dev2 an-dev3 an-dev4 an-dev5 an-hf an-itg an-load an-load2
                            an-mach an-mig an-mig2 an-qa an-rel an-sp an-stage an-test
                            doc-dev doc-dev2 doc-dev3 doc-dev4 doc-dev5 doc-hf doc-itg doc-load doc-load2
                            doc-mach doc-mig doc-mig2 doc-qa doc-rel doc-sp doc-stage doc-test
                            edi-dev edi-dev2 edi-dev3 edi-dev4 edi-dev5 edi-hf edi-itg edi-load edi-load2
                            edi-mach edi-mig edi-mig2 edi-qa edi-rel edi-sp edi-stage edi-test 
                            help-dev help-dev2 help-dev3 help-dev4 help-dev5 help-hf help-itg help-load help-load2
                            help-mach help-mig help-mig2 help-qa help-rel help-sp help-stage help-test 
                            s2-dev s2-dev2 s2-dev3 s2-dev4 s2-dev5 s2-hf s2-itg s2-load s2-load2
                            s2-mach s2-mig s2-mig2 s2-qa s2-rel s2-sp s2-stage s2-test 
                            s4-dev s4-dev2 s4-dev3 s4-dev4 s4-dev5 s4-hf s4-itg s4-load s4-load2
                            s4-mach s4-mig s4-mig2 s4-qa s4-rel s4-sp s4-stage s4-test 
                            s4pm-dev s4pm-dev2 s4pm-dev3 s4pm-dev4 s4pm-dev5 s4pm-hf s4pm-itg s4pm-load s4pm-load2
                            s4pm-mach s4pm-mig s4pm-mig2 s4pm-qa s4pm-rel s4pm-sp s4pm-stage s4pm-test 
                            ssp-dev ssp-dev2 ssp-dev3 ssp-dev4 ssp-dev5 ssp-hf ssp-itg ssp-load ssp-load2
                            ssp-mach ssp-mig ssp-mig2 ssp-qa ssp-rel ssp-sp ssp-stage ssp-test 
                        )],
        'required'   => 0,
        'saRequired' => 0,
    },

    'ownerTMID'  => {
        'desc'       => 'Owner of TicketMaster ID',
        'values'     => [ qw(string) ],
        'required'   => 0,
        'saRequired' => 0,
    },
    
    'cpuCount'  => {
        'desc'       => 'Number of CPUs',
        'values'     => [ parseValidFields('cpuCounts.json') ],
        'required'   => 0,
        'saRequired' => 1,
    },

    'cpuSpeed'  => {
        'desc'       => 'Speed of CPUs (Mhz/Ghz)',
        'values'     => [ parseValidFields('cpuSpeeds.json') ],
        'required'   => 0,
        'saRequired' => 1,
    },

    'memorySize'    => {
        'desc'       => 'Memory Size (Megabytes)',
        'values'     => [ parseValidFields('memorySizes.json') ], 
        'required'   => 0,
        'saRequired' => 1,
    },

    'hddCount'  => {
        'desc'       => 'Number of HDDs',
        'values'     => [ qw(1hdd 2hdd 3hdd 4hdd 5hdd 6hdd) ],
        'required'   => 0,
        'saRequired' => 0,
    },

    'snmpVersion'  => {
        'desc'       => 'SNMP Version',
        'values'     => [ qw(1 2 3) ],
        'required'   => 0,
        'saRequired' => 0,
    },

    'cageNumber'  => {
        'desc'       => 'cageNumber',
        'values'     => [ parseValidFields('cageNumbers.json') ],
        'required'   => 0,
        'saRequired' => 1,
    },       

    'lastUpdated'  => {
        'desc'       => 'Last Updated Time',
        'values'     => [ qw(digits) ],
        'required'   => 0,
        'saRequired' => 0,
    },

    'comments'  => {
        'desc'       => 'Additional Comments',
        'values'     => [ qw(text) ],
        'required'   => 0,
        'saRequired' => 0,
    },

    'etherChannel1Ports'    => {
        'desc'       => 'Interfaces that are a member of EtherChannel1',
        'values'     => [ qw(port) ],
        'required'   => 0,
        'saRequired' => 0,
    },

    'etherChannel2Ports'    => {
        'desc'       => 'Interfaces that are a member of EtherChannel2',
        'values'     => [ qw(port) ],
        'required'   => 0,
        'saRequired' => 0,
    },

    'etherChannel3Ports'    => {
        'desc'       => 'Interfaces that are a member of EtherChannel3',
        'values'     => [ qw(port) ],
        'required'   => 0,
        'saRequired' => 0,
    },

    'wwns'  => {
        'desc'       => 'HBA WWns',
        'values'     => [ qw(wwn) ],
        'required'   => 0,
        'saRequired' => 0,
        'multiple'   => 1,
    },

    'isp'   => {
        'desc'       => 'Internet Service Provider',
        'values'     => [ qw(internap cogent) ],
        'required'   => 0,
        'saRequired' => 0,
    },
};

# See after the __END__ marker for detailed breakdown of the complex regex patterns.
$valueValidationMap = {
    digit      => '\d',
    digits     => '\d+',
    rackPosition => '(\d+[a-zA-Z]?)|([a-zA-Z]\d+)|(([a-zA-Z]){0,2}[ -]\d+)',
    rackNumber => '((([a-zA-Z]?){0,3}\d+[A-Z]?([\-\s]?){0,3}){1,})|(\d+\.\d+)|([A-Z]\-\d+)|(Cabinet \d+)|(Row [A-Z] Cab \d)',
    port       => '\d/\d',
    wwn        => '([0-9a-f]{16})',
    dottedquad => '([0-1]?[0-9]{1,2}|2[0-4][0-9]|25[0-5])(\.(?:[0-1]?[0-9]{1,2}|2[0-4][0-9]|25[0-5])){3}',
    domain     => '([a-zA-Z\d][a-zA-Z\d-]*\.){1,}[a-zA-Z]{2,3}',
    consoleServer   => '(([a-zA-Z\d][a-zA-Z\d-]*\.){2,}[a-zA-Z]{2,3})|(ipmi)|(ilo)|(lom)|(rlm)|(acs\d+.*)',
    hostname   => '([a-zA-Z\d][a-zA-Z\d-]*\.){2,}[a-zA-Z]{2,3}',
    macaddress => '(?:[0-9a-fA-F]{1,2}:?){6}',
    string     => '\S+',
    text       => '.*',
};

sub parseValidFields {
    my $filename = shift;
    my $json_str;
    
    my $file = "$globalDir/$filename";
    return () unless (-f $file);

    open (my $fh, '<', $file) or die "cannot read json file $file: $!";

    $json_str .= $_ while (<$fh>);
    my $data = decode_json($json_str);
    my @r = grep {$data->{$_} == 1} keys %$data;
    
    return @r;
}


1;

__END__

NOTE:  in some cases, parenthetical expressions use the ?: "don't remember", and in others, they don't, even though the
       remembered pattern is never used, that I can tell.  However, since these patterns are used elsewhere, and so are
       compiled elsewhere, there's no way to know for sure, without a deep dive in all the code, if a remembered match
       is ever used, so DON'T change it!

    'dottedquad'    => '(                       # BEGIN first octet, remembered (needed?)
                            [0-1]?              # 0 or 1, zero or one time
                            [0-9]{1,2}          # 0 through 9, repeated 1 or 2 times
                          |                     # OR
                            2[0-4][0-9]         # 2 followed by 0 through 4 followed by 0 through 9
                          |                     # OR
                            25[0-5]             # 25 followed by 0 through 5
                        )                       # END first octet
                        (                       # BEGIN second octet
                            \.                  # followed by a literal dot
                            (?:                 # grouped with no memory
                                  [0-1]?        # 0 or 1, zero or one time
                                  [0-9]{1,2}    # followed by 0 through 9, repeated 1 or two times
                                |               # OR
                                  2[0-4][0-9]   # 2 followed by any of 0 through 4 followed by any of 0 through 9
                                |               # OR
                                  25[0-5]       # 25 followed by any of 0 through 5
                            )                   # END second octet definition
                        ){3}',                  # And repeat it 3 times exactly.

    'domain'    => '(
                        [a-zA-Z\d-]+            # any of these characters one or more times (WRONG:  dash cannot be first, this allows it)
                        \.                      # literal dot
                    ){1,}                       # and the above required once but allowed an infinite nubmer of times
                    [a-zA-Z]{2,3}',             # and the final dot followed by 2 or 3 alpha characters

    'hostname'  => '(                           # This is same as above 'domain' except it must have at least 2 of these, rather than 1.
                        [a-zA-Z\d-]+            # This has the same bug, allowing a leading dash, which it shouldn't.
                        \.
                    ){2,}
                    [a-zA-Z]{2,3}',

    'macaddress'    => '(?:                     # Don't remember what's found
                            [0-9a-fA-F]{1,2}    # Any hex number, one or two characters, ...
                            :?                  # followed a colon zero or one times
                        ){6}',                  # repeated eactly 6 times.

Modified to remove dash as a possible first character.

    'domain'    => '(
                        [a-zA-Z\d]              # any of these characters, exactly once
                        [a-zA-Z\d-]*            # followed by any of these characters zero or more times
                        \.                      # followed by a literal dot
                    ){1,}                       # and the above required once but allowed an infinite nubmer of times
                    [a-zA-Z]{2,3}',             # and the final dot followed by 2 or 3 alpha characters

    'hostname'  => '(
                        [a-zA-Z\d]              # any of these characters, exactly once
                        [a-zA-Z\d-]*            # followed by any of these characters zero or more times
                        \.                      # followed by a literal dot
                    ){2,}                       # and the above required twice but allowed an infinite nubmer of times
                    [a-zA-Z]{2,3}',             # and the final dot followed by 2 or 3 alpha characters
