# $Id$

package ariba::LogWatcher::Conf;

use strict;

sub new {
    my $proto = shift;

    my $logWatchConf = {
        '/var/log/cisco/pix-n1-1' => [ { 'include' => 'pix' } ],
        '/var/log/cisco/pix-n2-1' => [ { 'include' => 'pix' } ],

        '/var/log/cisco/routers' =>
        [
            {
                'regex' => 'Line protocol',
                'seen_throttle' => 1,
                'mail'  => 1,
                'mailsubj' => 'Router Changed Interface State',
            },

            {
                'regex' => 'Bad enqueue',
                'seen_throttle' => 1,
                'mail'  => 1,
                'mailsubj' => 'VPN Error',
            },
    
            {
                'regex' => 'SYS-2-MALLOCFAIL',
                'seen_throttle' => 1,
                'mail'  => 1,
                'mailsubj' => 'Memory Error',
            },
        ],

        '/var/log/cisco/switches' =>
        [
            {
                'regex' => 'changed state',
                'seen_throttle' => 1,
                'mail'  => 1,
                'mailsubj' => 'Switch Changed Interface State',
            },

            {
                # TMID: 31511
                'regex' => 'flap',
                'seen_throttle' => 1,
                'mail'  => 1,
                'mailsubj' => 'Switch is flapping',
            },

            {
                # TMID: 31511
                # astro is a regex for "Astro/Leman/NiceR" - which is a type of ASIC used
                # on the Cat 4k switch.  "astro" means ASIC problem, which very likely
                # means the switch is going to fail soon.
                'regex' => 'astro',
                'seen_throttle' => 1,
                'mail'  => 1,
                'mailsubj' => 'Switch failure imminent',
                'crit' => 1,
            },
        ],

        '/var/log/messages' =>
        [
            {
                'regex' => 'Read-only file system',
                'seen_throttle' => 1,
                'mail'  => 1,
                'mailsubj' => 'Root filesystem is read-only',
                'crit' => 1,
            },

            {
                'regex' => 'EXT3-fs error',
                'seen_throttle' => 1,
                'mail'  => 1,
                'mailsubj' => 'Root filesystem error',
                'crit' => 1,
            },

            {
                'regex' => 'failed to monitor',
                'seen_throttle' => 5,
                'mail'  => 1,
                'mailsubj' => 'Lockd error',
            },

            {
                'regex' => 'Port h: client process failure: killing process',
                'seen_throttle' => 1,
                'mail'  => 1,
                'mailsubj' => 'VCS Cluster Daemon restarted',
                'crit' => 1,

            },

            {
                'regex' => 'SCSI error(?!.*0x00000018\s*$)',  # alert on all scsi errors except 0x00000018',
                'seen_throttle' => 1,
                'mail'  => 1,
                'mailsubj' => 'SCSI errors',
                'crit' => 1,

            },

            {
                'regex' => 'ECC chipkill',
                'seen_throttle' => 1,
                'mail'  => 1,
                'mailsubj' => 'Memory ECC errors',
                'crit' => 1,

            },

            {
                'regex' => 'disk.predictiveFailure',
                'seen_throttle' => 1,
                'mail'  => 1,
                'mailsubj' => 'Netapp disk.predictiveFailure warning',
                'crit' => 1,

            },

            {
                'regex' => 'disk.offline',
                'seen_throttle' => 1,
                'mail'  => 1,
                'mailsubj' => 'Netapp disk.offline warning',
                'crit' => 1,

            },

            {
                'regex' => 'Failed Disk.*is still present in the system',
                'seen_throttle' => 1,
                'mail'  => 1,
                'mailsubj' => 'Netapp Failed Disk is still present in the system warning',
                'crit' => 1,

            },
            
            {
                'regex' => '.*',          # instead of kernel mark, we're now looking for anything
                'seen_interval' => 1800, # 30 mins
                'mail' => 1,
                'mailsubj' => 'DB Syslog Missing - warn',
                'absence_check' => 1,    # flag to indicate that we're looking for ABSENCE of particular pattern
                'remoteProvidesServices' => "db",
                'remoteStatus' => "inservice",
                'myService' => "syslog",
            },
            
            {
                'regex' => '.*',          # instead of kernel mark, we're now looking for anything
                'seen_interval' => 3600, # 1 hr
                'mail' => 1,
                'mailsubj' => 'DB Syslog Missing - crit',
                'crit' => 1,
                'absence_check' => 1,    # flag to indicate that we're looking for ABSENCE of particular pattern
                'remoteProvidesServices' => "db",
                'remoteStatus' => "inservice",
                'myService' => "syslog",
            },

        ],

        '/var/log/snort.alert' =>
        [
            {
                'regex' => 'DOS',
                'seen_throttle' => 1,
                'mail'  => 1,
                'mailsubj' => 'DOS snort alert',
            },

            {
                'regex' => 'EXPLOIT',
                'seen_throttle' => 1,
                'mail'  => 1,
                'mailsubj' => 'EXPLOIT snort alert',
            },

            {
                'regex' => 'ORACLE',
                'seen_throttle' => 1,
                'mail'  => 1,
                'mailsubj' => 'ORACLE snort alert',
            },
        ],

    };

    my $include = {
        'pix' =>
        [
            {
                'regex' => 'Switching to',
                'seen_throttle' => 1,
                'mail'  => 1,
                'mailsubj' => 'PIX Status Change',
            },
            {
                'regex' => 'connection denied',
                'seen_throttle' => 5,
                'wait_throttle' => 60,
                'mail'  => 1,
                'mailsubj' => 'PIX Connection Denied Warning',
            },

        ],
    };

    my $regex = {
        'udpdeny' => '/Deny inbound UDP from/',
    };

    return ($logWatchConf, $include, $regex);
}

1;
