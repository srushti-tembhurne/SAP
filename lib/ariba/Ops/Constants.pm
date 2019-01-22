package ariba::Ops::Constants;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Constants.pm#118 $
#
#
# If you change an email address in this file you also need to change
# //ariba/services/operations/cfengine/cfengine/scripts/000207-add-aliases-always
#
#

use strict;
use ariba::rc::Globals;
use ariba::Ops::ServiceController;
use Time::Local;
use POSIX;

# make sure we can find the on-call data files in corp and prod
my $oncalldir = '';
if (-d '/home/anops/on-call') {
    $oncalldir = '/home/anops/on-call';
} elsif (-d '/home/svcops/on-call') {
    $oncalldir = '/home/svcops/on-call';
} else {
    # The environments are not defined in a CGI script
    my $srcTree = $ENV{'ARIBA_DEPOT_ROOT'} || ($ENV{'HOME'} && $ENV{'HOME'} . "/ariba") || '';
    $oncalldir = $srcTree . '/services/operations/on-call';
}

# various booleans.  You can use these instead of using 1 for true or 0 for false to improve
# code readability.  Examples:
#
#     my $mybool = TRUE;
#     if ( $mybool ) { do something }
#
#     sub myFunction
#        return FALSE;
# 
#    see tools/tests/constants.t for tests that have many examples too
#
#    this boolean constant solution was inspired by the CPAN package constant::boolean
#    see http://search.cpan.org/~dexter/constant-boolean-0.02/lib/constant/boolean.pm
# 
sub import {
    my $caller = caller;

    no strict 'refs';
    # double "not" operator is used for converting scalar to boolean value
    *{"${caller}::TRUE"}         = sub () { !! 1 };
    *{"${caller}::FALSE"}        = sub () { !! '' };
    *{"${caller}::SET"}          = sub () { !! 1 };
    *{"${caller}::UNSET"}        = sub () { !! '' };
    *{"${caller}::ENABLE"}       = sub () { !! 1 };
    *{"${caller}::DISABLE"}      = sub () { !! '' };
    *{"${caller}::ENABLED"}      = sub () { !! 1 };
    *{"${caller}::DISABLED"}     = sub () { !! '' };
    *{"${caller}::YES"}          = sub () { !! 1 };
    *{"${caller}::NO"}           = sub () { !! '' };
    *{"${caller}::ON"}           = sub () { !! 1 };
    *{"${caller}::OFF"}          = sub () { !! '' };
    *{"${caller}::UP"}           = sub () { !! 1 };
    *{"${caller}::DOWN"}         = sub () { !! '' };
    *{"${caller}::LEFT"}         = sub () { !! 1 };
    *{"${caller}::RIGHT"}        = sub () { !! '' };
    *{"${caller}::IGNORECASE"}   = sub () { !! 1 };
    *{"${caller}::NOIGNORECASE"} = sub () { !! '' };

    return 1;
};

my $updatedOnCallDeployDate = timelocal(0, 0, 0, 7, 5, 2013); ## June 7, 2013 (1 day after deploy date) 

my $constants = {
    'archiveLogBaseDir'         => '/var/tmp/applogs',
    'spewDir'                   => '/var/tmp/spew',
    'flumeKrDir'                => '/var/tmp/flumekr',
    'sqlLogsBaseDir'            => '/var/tmp',
    'creditCardScanDir'         => '/var/tmp/credit-card-scan',
    'mailLogDir'                => '/var/log',

    'archiveLogKeepDaysDefault' => 30,
    'archiveLogKeepDaysProd'    => 90,

    # due to space constraints we can only retain last 1 full back in both prod and devlab
    'backupKeepCopiesHanaDefault' => 1,
    'backupKeepCopiesHanaProd'    => 1,

    # how often (in days) we backup the hana DBs (for alerting)...
    'backupFreqHanaDefault'       => 7,
    'backupFreqHanaProd'          => 4, 

    'incrBackupFreqHanaDefault'   => 7,
    'incrBackupFreqHanaProd'      => 2,

    'anyBackupFreqHanaDefault'        => 4, 
    'anyBackupFreqHanaProd'           => 1, 

    # ...and the hana backups cron schedule (for the startup hook)...
    'fullBackupSchedHanaProd'         => '0 19 * * 3,6',
    'incrBackupSchedHanaProd'         => '0 19 * * 0,1,2,4,5',

    'fullBackupSchedHanaDefault'      => '30 22 * * 5',
    'incrBackupSchedHanaDefault'      => '0 20 * * 2',

    # ...and the hana cleanup cron schedule (for the startup hook).

    'cleanupSchedHanaDefault'     => '5 2 * * *',
    'cleanupSchedHanaProd'        => '5 18 * * *',
 
    'oncalldir'                 => $oncalldir,

    'oncallpeopledir'               => "$oncalldir/people",
    'oncallscheduledir'             => "$oncalldir/schedule",
    'updatedoncallformat'           => "$updatedOnCallDeployDate",

    'opsGroupsDir'              => "$oncalldir/groups",

    'machinedir'                => "/usr/local/ariba/machinedb",
    'machineProductInfoDir'         => "/tmp/machineProductInfo",
    'safeguardAccountDir'               => "/usr/local/safeguard/accounts",
    'inspectorProxyProfileDir'      => "/usr/local/ariba/etc/inspector-proxy-profiles",
    'caCertDir'                 => "/usr/local/ariba/lib/certs",
    'mailCertDir'               => "/etc/mail/certs",

    # this function/constant just needs to be defined, it gets
    # overriden by a default in ariba::Ops::Startup::Apache.pm
    'certDir' => '',

    'vendorContractDir'             => "/home/anops/vendors/contracts",
    'monitorDir'                    => "/var/mon",
    'pagedir'                       => "/var/mon/pages",
    'toolsLogDir'                   => "/var/log/tools",

    'keepRunningEventLogFile'       => "/var/log/kr-events",

    'emailDomainName'               => 'ariba.com',

    'operationsEmailAddress'        => 'ask_ops@ariba.com',
    'productionOperationsEmailAddress'  => 'dept_an_ops_prod@ariba.com',
    'operationsEmailNotificationAddress'    => 'an_auto@ariba.com',
    'operationsDBAEmailNotificationAddress'    => 'an_ops_dba_ariba@sap.com',
    'serviceOwnersEmailNotificationAddress' => 'DL_52E2C2C0DF15DB262A0055E1@exchange.sap.corp',
    'jiraEmailAddress' => 'hoa-alert@sap.com',
    'operationsEmailServer'         => 'smtpint-m1.snv.ariba.com',

    'operationsEmailServerDR'       => 'smtpint-m1.us1.ariba.com',

    # ??? make this an element in prod DD.xml, change all lookups of this value to look up from DD.xml, then delete this.
    'euMonServerPrimary'            => 'mon11.eu1.ariba.com',

    'developmentEmailNotificationAddress'   => 'dept_an_eng@ariba.com',
    'developmentPagerAddress'       => 'dev_oncall_pagers@ansmtp.ariba.com',

    'operationsPagerAddress'        => 'an_oncall_pagers@ansmtp.ariba.com',
    'operationsPagerAddressReal'        => '_an_oncall_pagers@ansmtp.ariba.com',
    'operationsOncallNotificationAddress'   => 'deo.caruana@sap.com',
    'operationsFloatingPagerAddress'    => '8886035837@skytel.com',

    'developmentFloatingPagerAddress'   => '8889787237@skytel.com',

    'oncallPagerAliasFile'          => '/home/monprod/an_oncall_pagers',
    'developmentOncallPagerAliasFile'   => '/home/monprod/dev_oncall_pagers',

    'webServer'                 => 'http://ops.ariba.com',
    'httpsWebServer'            => 'https://ops.ariba.com',

    'pageStatusPath'            => '/cgi-bin/pagestatus',

    'operationsSysadminEmailAddress'    => 'an_auto_sysadmin@ariba.com',
    'operationsSecurityAddress'         => 'an_auto_security@ariba.com,ariba.secops@sap.com',

    'networkEmailNotificationAddress'   => 'an_auto_network@ariba.com',

    'andbLibrary'               => 'anbdboralib',
    'andbDrives'                => 'andboradrv1,andboradrv2',
    'catdbLibrary'              => 'catdboralib',
    'catdbDrives'               => 'catdboradrv1,catdboradrv2',

    'nullReplyTo'               => 'nobody@ansmtp.ariba.com',

    'logViewerPort'             => '61502',
    'logViewerPidFile'          => '.log-viewer.pid',
    'iostatDataPidFile'         => '.iostat-data.pid',

    'reportViewerPort'          => '61503',
    'reportViewerPidFile'       => '.report-viewer.pid',
    'DAReportBaseDir'           => '/sybase/home/DA/SummaryReports',
    'DAReportOwner'             => 'sybase',

    'minMemorySizeUsedByOs'         => '1024', # MB

    'archiveManagerUser'            => 'archmgr',
    'archiveManager'                => '/home/archmgr',
    'archiveManagerCatalogDir'      => '/home/archmgr/catalog',
    'archiveManagerArchiveDir'      => '/home/archmgr/archive',
    'archiveManagerMCLDir'      => '/home/archmgr/mcls',
    'archiveManagerMetaDataDir'     => '/home/archmgr/dataset-metadata',
    'dsmStatusLogFile'              => '/home/archmgr/logs/status.log',
    'dsmuser'                       => 'dsmcp',  ##user has sudo privileges on all lab1/sc1-lab1 hosts 

    'systemLogsSubdir'         => 'System-Logs',
    'archivedSystemLogsSubdir' => 'Archived-System-Logs',
    'ntDomain' => 'ariba',
    'ntDomainPDC' => 'us-hqdc1',
    'ntDomainBDC' => 'us-pghdc3',

    'serviceForDatacenterMonitoring'    => 'load',

    'hdfsFirstExport' => -2147483648,
    'hdfsVersions'    => 2147483647,
    'cobaltVaultServers'    => 'cobalt-infra1 cobalt-infra2 cobalt-infra3 cobalt-infra4 cobalt-infra5',

    # hana DB users that have admin privs (needed by monitoring to read system tables)
    'hanaDBAdminUsers' => [ 'system', 'system_mon' ],

    # the standard *nix system cmd search paths -- most standard O/S cmds (such as cp and zcat)
    # will be found in one of these paths, regardless of O/S type/version.
    'sysCmdSearchPath' => '/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin',
};

# define realmachinedir as machinedir
$constants->{'realmachinedir'} = $constants->{'machinedir'};

# define this to test paged in service;  see qa as an example
my $failsafePagerAddress = {
    #'qa'   => 'dept_an_ops_arch@ariba.com',
};

my $opsMgr= '';
my $hour=strftime "%H", localtime;

if(($hour >= 10)&&($hour <= 18)){
        $opsMgr="acaruana";
}
else{
        $opsMgr="nratnakaram";
}

my $pagerEscalation = {
        'qa'    =>      [ failsafePagerAddressForService('qa') ],
};

#
# This is to be called to activate the personal service set of
# constants.
#
sub configureForPersonalService {

    my $tmpDir = "/robots/machine-global-cache-for-personal-service";

    $constants->{'personalServiceGlobalCacheDir'} = $tmpDir;

    $constants->{'robotRootDir'} = '/robots';

    $constants->{'machinedir'} = "$tmpDir/usr/local/ariba/machinedb";
    $constants->{'caCertDir'}  = "$tmpDir/usr/local/services/operations/cfengine/dist/common/ariba/lib/certs";
    $constants->{'certDir'}    = "$tmpDir/lib/certs",
    $constants->{'monitorDir'} = "$tmpDir/var/mon";
    $constants->{'pagedir'}    = "$tmpDir/var/mon/pages";

    #
    # these probably aren't needed, but change them just to be on the
    # safe side, personal service should never send email to prod
    # addresses.
    #
    my $user = $ENV{'USER'};
    my $defaultEmail = "$user\@ariba.com";

    $constants->{'operationsEmailAddress'} = $defaultEmail;
    $constants->{'productionOperationsEmailAddress'} = $defaultEmail;
    $constants->{'operationsEmailNotificationAddress'} = $defaultEmail;
    $constants->{'operationsDBAEmailNotificationAddress'} = $defaultEmail;
    $constants->{'operationsEmailServer'} = 'phoenix.ariba.com';
    $constants->{'operationsEmailServerDR'} = 'phoenix.ariba.com';

    $constants->{'developmentEmailNotificationAddress'} = $defaultEmail;
    $constants->{'developmentPagerAddress'} = $defaultEmail;

    $constants->{'operationsPagerAddress'} = $defaultEmail;
    $constants->{'operationsPagerAddressReal'} = $defaultEmail;
    $constants->{'operationsOncallNotificationAddress'} = $defaultEmail;
    $constants->{'operationsFloatingPagerAddress'} = $defaultEmail;
    $constants->{'developmentFloatingPagerAddress'} = $defaultEmail;

    $constants->{'operationsSysadminEmailAddress'} = $defaultEmail;
    $constants->{'operationsSecurityAddress'} = $defaultEmail;
    $constants->{'networkEmailNotificationAddress'} = $defaultEmail;


    createConstantFunctions();
};

sub createConstantFunctions {
# create autoloaded class methods from the constants hash
    for my $datum (keys %$constants) {
        no strict 'refs';
        no warnings; # avoid 'Subroutine xx redefined at yy'
        *$datum = sub { return $constants->{$datum} };
    }

}

#
# this happens at load time
#

if ( ariba::rc::Globals::isPersonalService($ENV{'ARIBA_SERVICE'}) ) {
    configureForPersonalService();
} else {
    createConstantFunctions();
}

sub failsafePagerAddressForService {
    my $service = shift;

    my $address;

    if (ariba::Ops::ServiceController::isProductionServicesOnly($service)) {
        $address = $constants->{'operationsPagerAddressReal'};
    } else {
        $address = $failsafePagerAddress->{$service};
    }

    return $address;
}

sub pagerEscalationForService {
    my $service = shift;

    my @alertList;

    if (ariba::Ops::ServiceController::isProductionServicesOnly($service)) {
        @alertList = qw( PRIMARY PRIMARY BACKUP BACKUP);
        push (@alertList, $opsMgr, $opsMgr);
    } else {
        if ( ref($pagerEscalation->{$service}) eq "ARRAY" ) {
            @alertList = @{$pagerEscalation->{$service}};
        }
    } 

    return @alertList;
}

sub archiveLogDir {
    my $service = shift;
    my $prodname = shift;
    my $customer = shift;

    my $ret = ariba::Ops::Constants->archiveLogBaseDir();
    $ret .= "/$service/$prodname";
    $ret .= "/$customer" if($customer);

    return($ret);
}

sub archiveLogKeepDays {
    my $class = shift;
    my $service = shift;

    if(ariba::Ops::ServiceController::isProductionServicesOnly($service)) {
        return ariba::Ops::Constants::archiveLogKeepDaysProd();
    } else {
        return ariba::Ops::Constants::archiveLogKeepDaysDefault();
    }
}

sub backupKeepCopiesHana {
    my $class = shift;
    my $service = shift;

    if(ariba::Ops::ServiceController::isProductionServicesOnly($service)) {
        return ariba::Ops::Constants::backupKeepCopiesHanaProd();
    }

    return ariba::Ops::Constants::backupKeepCopiesHanaDefault();
}

sub backupFreqHana {
    my $class = shift;
    my $service = shift;

    if(ariba::Ops::ServiceController::isProductionServicesOnly($service)) {
        return (ariba::Ops::Constants::backupFreqHanaProd(), ariba::Ops::Constants::incrBackupFreqHanaProd(), ariba::Ops::Constants::anyBackupFreqHanaProd());
    }

    return (ariba::Ops::Constants::backupFreqHanaDefault(), ariba::Ops::Constants::incrBackupFreqHanaDefault(), ariba::Ops::Constants::anyBackupFreqHanaDefault());
}

sub cleanupSchedHana {
    my $class = shift;
    my $service = shift;

    if(ariba::Ops::ServiceController::isProductionServicesOnly($service)) {
        return ariba::Ops::Constants::cleanupSchedHanaProd();
    }

    return ariba::Ops::Constants::cleanupSchedHanaDefault();
}

sub backupSchedHana {
    my $class = shift;
    my $service = shift;

    if(ariba::Ops::ServiceController::isProductionServicesOnly($service)) {
        return (ariba::Ops::Constants::fullBackupSchedHanaProd(), ariba::Ops::Constants::incrBackupSchedHanaProd());
    }

    return (ariba::Ops::Constants::fullBackupSchedHanaDefault(), ariba::Ops::Constants::incrBackupSchedHanaDefault());
}

sub archiveLogSuspendFile {
    my $sid = shift;

    my $file = "/var/tmp/clean-archivelogs.suspend";
    if($sid) {
        $sid = uc($sid);
        $file .= ".sid=$sid";
    }

    return($file);
}

sub archiveLogIsSuspended {
    my $sid = shift;

    return ( -e archiveLogSuspendFile() ||
             -e archiveLogSuspendFile($sid) );
}

sub sqlLogsDir {
    my $class = shift;
    my $prodname = shift;

    my $ret = ariba::Ops::Constants->sqlLogsBaseDir();
    $ret .= "/$prodname/application";

    return ($ret);
}

sub setConst {
    my $func = shift;
    my $newPath = shift;

    $constants->{$func} = $newPath;

    createConstantFunctions();
}


1;

__END__
