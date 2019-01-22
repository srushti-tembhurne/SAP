package ariba::Ops::Startup::Apache;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/Apache.pm#279 $

use strict;
use Carp;

use Config;
use File::Path;
use ariba::Ops::NetworkUtils;
use ariba::Ops::Startup::Common;
use ariba::Ops::Utils;
use ariba::rc::CipherStore;
use ariba::rc::Utils;
use ariba::Ops::Constants;      
use ariba::rc::Globals;
use ariba::Ops::BusyPageOnHttpVendor;
use ariba::rc::InstalledProduct;

my $mkdir = ariba::rc::Utils::mkdirCmd();
my $chown = ariba::rc::Utils::chownCmd();
my $chmod = ariba::rc::Utils::chmodCmd();
my $rm    = ariba::rc::Utils::rmCmd();

my $envSetup = 0; ## Track environment is/is not setup

my $APACHE_LOG_DIR = "/var/log/apache";
my $APACHE_LOG_DIR_PERSONAL_SERVICE = "/var/tmp/apache";

sub stop             { control(0, @_) }
sub start            { control(1, @_) }
sub gracefulRestart  { control(2, @_) }

# Only do this once.
chomp(my $arch = lc(`uname -s`));

sub apacheLogDir {
    my $dir;
    if ( ariba::rc::Globals::isPersonalService($ENV{'ARIBA_SERVICE'}) ) {
        $dir = $APACHE_LOG_DIR_PERSONAL_SERVICE;
    } else {
        $dir = $APACHE_LOG_DIR;
    }

    return $dir;
}

sub control {
    my $controlCode = shift;
    my $product     = shift;
    my $confFile    = shift;
    my $defines     = shift || '';

    my $apacheVersion = $product->default('ApacheVersion') || 1.3;

    my $SUDO = ariba::Ops::Startup::Common::realOrFakeSudoCmd();

    my $wwwCmd     = "$ENV{'ARIBA_DEPLOY_ROOT'}/bin/apachectl";

    if($controlCode == 0) {
        my $command     = "$SUDO $wwwCmd stop -f $confFile";

        print "$command\n";
        r($command);
        sleep(5);
    }
    elsif ($controlCode == 1) {
        my $sudo        = $product->default('webserverhttpport') <= 1024 ? $SUDO : '';
        my $ssl         = $product->default('webserverhttpsport') || $product->default('certserverhttpsport');
        my $startCmd    = ($ssl) ? "startssl" : "start";

        if ( $apacheVersion eq '2.4' && $startCmd eq 'startssl' ){
            $startCmd = 'start';
        }

        my $shCmd       = shCmd();
        my $limitCmd    = $product->default("EnableCoredump") ? 'limit coredumpsize unlimited;' : '';

        my $command     = "$sudo $shCmd -c '$limitCmd $wwwCmd $startCmd -f $confFile $defines'";
        my $passPhrase  = $product->default('sslcertificate.password');

        if (defined($passPhrase)) {
            my $cipherStore = ariba::rc::CipherStore->new( $product->name() . $product->service() );

            # Store the cert password in shared memory, so that pp-prompt
            # can use it. shell read() doesn't work anymore, it will block.
            # pp-prompt must delete() this shm segment after it's used.
            my $key = join('/', ($product->name(), $product->service(), ':certPassPhrase'));
            unless ($cipherStore->storeHash({ $key => $passPhrase })) {
                print "Error: Failed to store $key in Cipher Store: $!\n";
            }

            if (scalar($cipherStore->keysNotStored())) {
                print "Error: the following keys failed saving to cipherstore (probably due to badly encrypted values):\n",
                "Error: ", join (",", $cipherStore->keysNotStored()), "\n",
                "Error: This is not a fatal error, but some certs may not work because of this.\n";
            }
        }

        print "$command\n";
        r($command);
    }
    elsif($controlCode == 2) 
    {
        my $command     = "$SUDO $wwwCmd graceful -f $confFile";
        print "$command\n";
        r($command);
    }

    return 1;
}

sub httpdProperty {
    my $product  = shift;
    my $property = shift;

    my $apacheVersion = $product->default('ApacheVersion') || 1.3;

    my $wwwCmd     = "$ENV{'ARIBA_DEPLOY_ROOT'}/bin/apachectl";

    #
    # Get output of httpd -V
    #
    # Server version: Apache/2.0.53
    # Server built:   Aug 19 2005 16:50:52
    # Server's Module Magic Number: 20020903:9
    # Architecture:   32-bit
    # Server compiled with....
    # -D APACHE_MPM_DIR="server/mpm/prefork"
    # -D APR_HAS_SENDFILE
    # -D APR_HAS_MMAP
    # -D APR_USE_FCNTL_SERIALIZE
    # -D APR_USE_PTHREAD_SERIALIZE
    # -D SINGLE_LISTEN_UNSERIALIZED_ACCEPT
    # -D APR_HAS_OTHER_CHILD
    # -D AP_HAVE_RELIABLE_PIPED_LOGS
    # -D HTTPD_ROOT="/home/rc/objs/ssws_ariba/sunos/install"
    # -D SUEXEC_BIN="/home/rc/objs/ssws_ariba/sunos/install/bin/suexec"
    # -D DEFAULT_PIDLOG="logs/httpd.pid"
    # -D DEFAULT_SCOREBOARD="logs/apache_runtime_status"
    # -D DEFAULT_LOCKFILE="logs/accept.lock"
    # -D DEFAULT_ERRORLOG="logs/error_log"
    # -D AP_TYPES_CONFIG_FILE="conf/mime.types"
    # -D SERVER_CONFIG_FILE="conf/httpd.conf"
    #

    #
    open(WWW, "$wwwCmd -V|") || return undef;
    my @output = <WWW>;
    close(WWW);

    #
    # Match for the property
    #
    my $value;
    for my $line (@output) {
        if ($line =~ m|$property|i) {
            #
            # For lines of this format:
            #
            # Server version: Apache/2.0.53
            # -D APACHE_MPM_DIR="server/mpm/prefork"
            #
            my ($p, $v) = split (/\s*[=:]\s*/, $line, 2);
            if ($v) {
                chomp($v);
                $value = $v;
            } else {
            #
            # For lines like:
            #
            # -D APR_HAS_SENDFILE
            #
                $value = 1;
            }
            last;
        }
    }
    return $value;
}

sub tokenizeHttpdConfig {
    my ($config,$templateFile,$configOutputFile,$defaultsProduct,$type) = @_;

    # read in the template httpd config file, and slam in the
    # values for this instance of httpd
    open(CONF, $templateFile) || die "Could not read config file $templateFile, $!\n";
    sysread(CONF, my $confString, -s CONF);
    close(CONF);

    # slam in defaults that every consumer of the webserver has
    $config->{'PORT'}    = $defaultsProduct->default($type . 'httpport')  || $defaultsProduct->default('webserverhttpport');
    $config->{'SSLPORT'} = $defaultsProduct->default($type . 'httpsport') || $defaultsProduct->default('webserverhttpsport');

    $config->{'ARCH'}      = $arch;
    $config->{'USER'}      = $defaultsProduct->default('webserveruser') || $ENV{'USER'};
    $config->{'GROUP'}     = $defaultsProduct->default('webservergroup') || $ENV{'GROUP'};
    $config->{'CACERTDIR'} = ariba::Ops::Constants->caCertDir();
    $config->{'CERTDIR'}   = ariba::Ops::Constants->certDir() ||  $config->{'SERVERROOT'} . "/lib/certs";

    print '-' x 72, "\n";;
    print "Webserver Setting :\n";

    $confString =~ s/\r//g;

    for my $from (sort (keys(%$config))) {

        my $to = $config->{$from};

        # Token can be an empty string.
        next unless defined $to;

        $to =~ s/^\s*//g;
        $to =~ s/\s*$//g;
        $confString =~ s/\*$from\*/$to/g;
        printf ("\t%-20s%s\n", $from, $to);
    }

    print '-' x 72, "\n";

    chmod 0644, $configOutputFile;
    open(CONF, "> $configOutputFile.$$") || die "Could not write config file $configOutputFile.$$, $!\n";
    print CONF "#\n# This file generated by $0\n";
    print CONF "# using $templateFile as the template\n#\n";
    print CONF $confString;
    close(CONF);
    rename("$configOutputFile.$$", $configOutputFile);

    return $confString;
}

sub IPAddressesToIPPatterns {
    my $ipaddresses = shift || "";

    my @ippatterns = ();
    for my $address (split(/\s*,\s*/, $ipaddresses)) {
        $address =~ s/\./\\\./g;
        if ($address =~ /^\d+/) {
            push @ippatterns, $address . ".*";
        }
    }

    return @ippatterns;
}

sub configureHttpdForWebObjects {
    my ($templateFile,$configOutputFile,$role,$defaultsProduct) = @_;

    my($serverHost,$certFile);
    if($role eq 'adminserver' || $role eq 'aodadminserver') {
        $serverHost = $defaultsProduct->default('adminservicehost');
        $certFile = $defaultsProduct->default('sslcertificate.admincertfile');
    } else {
        $serverHost = $defaultsProduct->default('servicehost');
        $certFile = $defaultsProduct->default('sslcertificate.certfile');
    }

    $serverHost = ariba::Ops::NetworkUtils::hostname() unless $serverHost;
    my $serverPort = $defaultsProduct->default('WebServerHTTPPort') || "";

    my $logDir = logDirForRoleHostPort($role, $serverHost, $serverPort);

    my $certServerHost = $defaultsProduct->default('certservicehost') || '';
    my $certServerPort = $defaultsProduct->default('certserverhttpsport') || '';
    my $certServerVerifyClient = $defaultsProduct->default('CertServerVerifyClient');
    my $certServiceCertFile = $defaultsProduct->default('sslcertificate.certservicecertfile');

    $ENV{'PIDFILE'} = "$logDir/httpd.pid";

    my $woVersion = $defaultsProduct->woVersion();
    my $interval  = defined $woVersion && $woVersion >= 4.5 ? 300 : '';

    my $transportipaddresses = $defaultsProduct->default('transportipaddresses');
    my @transportippatterns = IPAddressesToIPPatterns($transportipaddresses);
    my $visualizerDataAccessIpAddresses = $defaultsProduct->default('VisualizerDataAccessIpAddresses');
    my @visualizerDataAccessIpPatterns = IPAddressesToIPPatterns($visualizerDataAccessIpAddresses);
    my %config = (
        'SERVERROOT'      => $ENV{'ARIBA_DEPLOY_ROOT'},
        'CONFIGROOT'      => $ENV{'ARIBA_CONFIG_ROOT'},
        'SERVICE'     => $ENV{'ARIBA_SERVICE'},
        'SUPPORT'     => $defaultsProduct->default('ansupport.email') || $defaultsProduct->default('notify.email'),
        'SERVICEHOST'     => $serverHost,
        'DESTSERVICEHOST' => $defaultsProduct->default('DestServiceHost'),
        'CERTSERVICEHOST' => $certServerHost,
        'CERTDESTSERVICEHOST' => $defaultsProduct->default('CertDestServiceHost'),
        'CERTSSLPORT'     => $certServerPort,
        'SSLCIPHERSUITE'  => $defaultsProduct->default('SSLCipherSuite'),
        'CERTSERVERVERIFYCLIENT' => $certServerVerifyClient,
        'CERTFILE' => $certFile,
        'CERTSERVICECERTFILE' => $certServiceCertFile,
        'PIDFILE'     => $ENV{'PIDFILE'},
        'ROLE'        => $role,
        'INTERVAL'    => $interval,
        'CATALOGUPLOADDIR'=> $defaultsProduct->default('cataloguploadapi.cataloguploaddir'),
        'CATALOGVIRTUALDIR' => $defaultsProduct->default('cataloguploadapi.catalogvirtualdir'),
        'MAXCATALOGSIZE'  => $defaultsProduct->default('cataloguploadapi.maxcatalogsize'),
        'MAXCXMLSIZE'     => $defaultsProduct->default('maxcxmlsize'),
        'MAXEDISIZE'      => $defaultsProduct->default('maxedisize'),
        'TRANSPORTIPADDRESSES' => join('|', @transportippatterns),
        'VISUALIZER-DATA-ACCESS-IP-ADDRESSES' => join('|', @visualizerDataAccessIpPatterns),
        'LOGDIR'      => $logDir,
        'PREFORKSERVERLIMIT' => $defaultsProduct->default('preforkserverlimit'),
        'PREFORKMAXCLIENTS'  => $defaultsProduct->default('preforkmaxclients'),
        'PREFORKMINSPARESERVERS' => $defaultsProduct->default('preforkminspareservers'),
        'PREFORKMAXSPARESERVERS' => $defaultsProduct->default('preforkmaxspareservers'),
        'PREFORKSTARTSERVERS'   => $defaultsProduct->default('preforkstartservers'),
        # Leaving these two for now, they may be used, so that usage would break. However, this really looks like a job that
        # was started and never finished, as my basic searching cannot find anything using OR setting these tokens.
        'MINSPARESERVERS'    => $defaultsProduct->default('MinSpareServers'),
        'MAXSPARESERVERS'    => $defaultsProduct->default('MaxSpareServers'),
    );

    # should be webserver or adminserver for WS
    my $type = $role;

    # for inpsector-proxy in mon
    if ($role =~ /monserver/ ) {
        $config{'PROXYPORT'} = $defaultsProduct->default('InspectorProxy.Port');
        $config{'SSLPROXYPORT'} = $defaultsProduct->default('InspectorProxy.SSLPort');
        $type = "WebServer"; # force it for mon
    }

    my $confString = tokenizeHttpdConfig(\%config,$templateFile,$configOutputFile,$defaultsProduct, $type);

    unless ($confString) {
        die "There was an error in doing tokenizeHttpdConf!";
    }

    my $user  = $defaultsProduct->default('webserveruser');
    my $group = $defaultsProduct->default('webservergroup');

    my $SUDO = ariba::Ops::Startup::Common::realOrFakeSudoCmd();
    # Make dirs needed by apache and supporting cgi
    r("$SUDO $mkdir -p $logDir/safe");
    r("$SUDO $mkdir -p $logDir/ssl_mutex");
    r("$SUDO $chown -R $user:$group $logDir");

    if ($certServerHost) {
        r("$SUDO $mkdir -p " . apacheLogDir() . "/$certServerHost$certServerPort/safe");
        r("$SUDO $chown -R $user:$group " . apacheLogDir() . "/$certServerHost$certServerPort");
    }

    my $temp = ariba::Ops::Startup::Common::tmpdir();
    r("$SUDO $mkdir -p $temp/ariba; $SUDO chmod -R 777 $temp/ariba");
    r("$SUDO $mkdir -p /var/catalog; $SUDO chmod 775 /var/catalog");
    r("$SUDO $mkdir -p /var/tmp/$user/woa");
    r("$SUDO $chmod 700 /var/tmp/$user/woa");
    r("$SUDO $chown -R $user:ariba /var/catalog");
    r("$SUDO $chown -R $user:$group /var/tmp/$user/woa");
    r("$SUDO $main::INSTALLDIR/bin/clean-old-files-from-dir /var/catalog") if $role eq "webserver";

    ###############################
    # Setup defines to pass to wwwctl
    # Get the AN releasename
    my @defines = ();

    return @defines if ($role =~ /monserver|migration-ui/);

    push(@defines, "UseCertServer") if($certServerPort);

    if (ariba::rc::InstalledProduct->isInstalled('an')) {
        my $anRelease = ariba::rc::InstalledProduct->new('an')->releaseName();
        if ($anRelease and $anRelease =~ s/^(\d+).*?$/$1/) {
            push @defines, 'PunchOutProcessor' if $anRelease >= 34;
            push @defines, 'LIMITEDHTTP' if $anRelease >= 39;
        }
    }

    # Are we running on an adco server?
    my $adco = $defaultsProduct->default('adcorelease');
    if (defined $adco and $adco !~ /^\s*$/ and $adco !~ /(?:NOADCO|Unknown)/) {
        push @defines, 'ADCO';
    }

    # different directives for woadaptor >= 5.0
    if ($woVersion) {
        my ($woMajorVersion) = ($woVersion =~ /^(\d)/);
        push @defines, "WOADAPTOR$woMajorVersion";

        # Remove the old WOAdaptor shared memory file, if any
        if ($woMajorVersion >= 5) {
            my $shmemFile = "/tmp/WOAdaptorState";
            if ($confString =~ m/WebObjectsOptions.*\bstateFile\s*=\s*(\S+?)(,|\s|$)/) {
                $shmemFile = "/tmp/$1";
            }
            r("$SUDO $rm -f $shmemFile");
        }
    }

    return join(' ', (map { "-D$_ " } (@defines)) );
}

sub configureHttpdForASPProducts {
    my ($templateFile,$configOutputFile,$role,$defaultsProduct) = @_;

    unless ( $role =~ /^cws/ ){
        my $rewriteRuleFile = rewriteRulesForASPProducts($defaultsProduct, $role);
    }

    my $trustedipaddresses = $defaultsProduct->default('trustedsubnet');
    my @trustedippatterns = IPAddressesToIPPatterns($trustedipaddresses);
    my $serverHost = $defaultsProduct->default('servicehost');
    $serverHost = ariba::Ops::NetworkUtils::hostname() unless $serverHost;

    my $service = $defaultsProduct->service();
    my $serverPort = $defaultsProduct->default('WebServerHTTPPort') || "";

    if ( $role eq 'cwsadminserver' ){
        $serverHost = $defaultsProduct->default('AdminServiceHost');
        $serverPort = $defaultsProduct->default('WebserverHttpsPort') || "";
    }

    my $logDir = logDirForRoleHostPort($role, $serverHost, $serverPort);

    $ENV{'PIDFILE'} = "$logDir/httpd.pid";

    my %config = (
        'SERVERROOT'      => $ENV{'ARIBA_DEPLOY_ROOT'},
        'CONFIGROOT'      => $ENV{'ARIBA_CONFIG_ROOT'},
        'SERVICE'     => $ENV{'ARIBA_SERVICE'},
        'SUPPORT'     => $defaultsProduct->default('ansupport.email') || $defaultsProduct->default('notify.email'),
        'SERVICEHOST'     => $serverHost,
        'PIDFILE'     => $ENV{'PIDFILE'},
        'ROLE'        => $role,
        'TRUSTEDIPADDRESSES' => join('|', @trustedippatterns),
        'LOGDIR'      => $logDir,

        'ADMINSERVICEHOST'   => $defaultsProduct->default('adminservicehost') || '',
        'PREFORKSERVERLIMIT' => $defaultsProduct->default('preforkserverlimit'),
        'PREFORKMAXCLIENTS'  => $defaultsProduct->default('preforkmaxclients'),
        'WORKERSERVERLIMIT'  => $defaultsProduct->default('workerserverlimit'),
        'WORKERMAXCLIENTS'   => $defaultsProduct->default('workermaxclients'),
    );
    
    #config override for cws
    if($role =~ /^cws/) {
        $config{'CWSCACHEROOT'} = $defaultsProduct->default('CacheRoot');
        $config{'WORKERSTARTSERVERS'} = $defaultsProduct->default('workerstartservers');
        $config{'WORKERMINSPARETHREADS'} = $defaultsProduct->default('workerminsparethreads');
        $config{'WORKERMAXSPARETHREADS'} = $defaultsProduct->default('workermaxsparethreads');
        $config{'WORKERMAXREQUESTSPERCHILD'} = $defaultsProduct->default('workermaxrequestsperchild');
        $config{'WORKERTHREADLIMIT'} = $defaultsProduct->default('workerthreadlimit');
        $config{'WORKERTHREADSPERCHILD'} = $defaultsProduct->default('workerthreadsperchild');
        $config{'SSLCIPHERSUITE'} = $defaultsProduct->default('sslciphersuite');
    }

    my $type = $role;
    $type =~ s/aes-//;
    my $confString = tokenizeHttpdConfig(\%config,$templateFile,$configOutputFile,$defaultsProduct, $type);

    unless ($confString) {
        die "There was an error in doing tokenizeHttpdConf!";
    }

    my $user  = $defaultsProduct->default('webserveruser');
    my $group = $defaultsProduct->default('webservergroup');

    my $SUDO = ariba::Ops::Startup::Common::realOrFakeSudoCmd();
    # Make dirs needed by apache and supporting cgi
    r("$SUDO $mkdir -p $logDir/safe");
    if ( $role =~ /^cws/ ){
        r("$SUDO mkdir -p $logDir/ssl_mutex");
        r("$SUDO mkdir -p $logDir/balancer");
        r("$SUDO mkdir -p $logDir/cache");
    }
    r("$SUDO $chown -R $user:$group $logDir");

    return undef;
}

sub configureHttpdForSharedService {
    my ($templateFile,$configOutputFile,$role,$defaultsProduct) = @_;
    my $service = $defaultsProduct->service();

    my $serverHost = $defaultsProduct->default('servicehost');
    my $certServerHost = $defaultsProduct->default('certservicehost') || '';
    my $certServerPort = $defaultsProduct->default('certserverhttpsport') || '';
    my $listenOnCertServerPort = $certServerPort && "Listen $certServerPort" || '';
    my $certFile = $defaultsProduct->default('sslcertificate.certfile');
    my $certServiceCertFile = $defaultsProduct->default('sslcertificate.certservicecertfile');

    # Setup defines to pass to wwwctl
    my @defines = ();

    push(@defines, "UseCertServer") if($certServerPort) ;

    my $type = $role;
    $type =~ s/^(ss|ows)-//;

    if ( $type eq 'adminserver') { 
        $serverHost = $defaultsProduct->default('adminservicehost'); 
        $certFile = $defaultsProduct->default('sslcertificate.admincertfile');
        $listenOnCertServerPort = "";
    } elsif ($type eq 'testserver') {
        $serverHost = $defaultsProduct->default('testservicehost');
        $listenOnCertServerPort = "";
    }

    my $serverPort = $defaultsProduct->default($type. 'httpport') || "";

    $serverHost = ariba::Ops::NetworkUtils::hostname() unless $serverHost;

    my $logDir = logDirForRoleHostPort($role, $serverHost, $serverPort);
    $ENV{'PIDFILE'} = "$logDir/httpd.pid";

    my $inspectoraccessipaddresses = $defaultsProduct->default('inspectoraccessipaddresses');
    my $cacheRoot = $defaultsProduct->default('CacheRoot') || "";
    my @inspectorippatterns = IPAddressesToIPPatterns($inspectoraccessipaddresses);

    # this may be overridden by s4/s2/s4pm
    my $maxuploadsize = $defaultsProduct->default('maxuploadsize');
    my $realmToCommunityMapDir = $defaultsProduct->default('RealmToCommunityMapDir') || "/tmp";
    mkdirRecursively($realmToCommunityMapDir);

    my %config = (
        'SERVERROOT'  => $ENV{'ARIBA_DEPLOY_ROOT'},
        'PIDFILE'     => $ENV{'PIDFILE'},
        'SERVICEHOST' => $serverHost,
        'CERTSERVICEHOST' => $certServerHost,
        'CERTSSLPORT'     => $certServerPort,
        'CERTFILE'    => $certFile,
        'CERTSERVICECERTFILE' => $certServiceCertFile,
        'LISTENONCERTSSLPORT' => $listenOnCertServerPort,
        'CACHEROOT'   => $cacheRoot,
        'CONFIGROOT'  => $ENV{'ARIBA_CONFIG_ROOT'},
        'SUPPORT'     => $defaultsProduct->default('notify.email'),
        'ROLE'        => $role,

        'INSPECTORACCESSIPADDRESSES' => join('|', @inspectorippatterns),

        'LOGDIR'       => $logDir,

        'PREFORKSERVERLIMIT' => $defaultsProduct->default('preforkserverlimit'),
        'PREFORKMAXCLIENTS'  => $defaultsProduct->default('preforkmaxclients'),
        'PREFORKSTARTSERVERS'   => $defaultsProduct->default('preforkstartservers'),
        'WORKERSERVERLIMIT'  => $defaultsProduct->default('workerserverlimit'),
        'WORKERMAXCLIENTS'   => $defaultsProduct->default('workermaxclients'),
        'SOURCINGCONTEXTLOCATIONPATTERN' => "",
        'BUYERCONTEXTLOCATIONPATTERN' => "",
        'SSLCIPHERSUITE' => $defaultsProduct->default('sslciphersuite'),
        );

    #
    # right now we serve sourcing and buyer via ssws. Skip this for ows.
    # Gather some more information about these products.
    #
    if($role =~ m/^ss-/ || $role eq 'mwswebserver') {
        my $sourcing = undef;
        my $buyer;
        my $sourcingContext = "INVALIDCONTEXT";
        my $buyerContext = "INVALIDCONTEXT";

        my $sourcingBuyerLogin = "INVALIDURI";
        my $sourcingSupplierLogin = "INVALIDURI";

        my $sourcingVirtualHost = "INVALIDVHOST";
        my $supplierVirtualHost = "INVALIDVHOST";
        my $visibilityVirtualHost = "INVALIDVHOST";

        my $invoicingVirtualHost = "INVALIDVHOST";
        my $procurementVirtualHost = "INVALIDVHOST";

        my $s4RealmToCommunityMapFileName = "/dev/null";
        my $buyerRealmToCommunityMapFileName = "/dev/null";

        for my $pname (ariba::rc::Globals::sharedServiceSourcingProducts()) {
            if (ariba::rc::InstalledProduct->isInstalled($pname, $service)) {

                $sourcing = ariba::rc::InstalledProduct->new($pname, $service);
                $sourcingContext = $sourcing->default('Tomcat.ApplicationContext');

                $sourcingBuyerLogin = "/$sourcingContext/customer";
                $sourcingSupplierLogin = "/$sourcingContext/supplier";

                #
                # If app specified a max upload limit, set limit on
                # webserver to be slightly higher than that. This will give
                # apps a chance to throw up a nice error message rather than
                # webserver simply blocking the upload.
                #
                my $appSpecificMaxUploadLimit = $sourcing->default('System.Analysis.Admin.DataFileUploadMaxSize');
                if ($appSpecificMaxUploadLimit) {
                    $maxuploadsize = $appSpecificMaxUploadLimit * 1.25;
                }

                #
                # Get Buyer Login URLs, there should be 2 of them, one
                # for # sourcing and one for visibility
                #
                my $sourcingCustomerLoginUrls = $sourcing->default('System.PasswordAdapters.PasswordAdapter1.LoginURLs');

                if ($sourcingCustomerLoginUrls) {
                    my $sourcingVhostUrl = $sourcingCustomerLoginUrls->[0];
                    my $visibilityVhostUrl = $sourcingCustomerLoginUrls->[1];

                    if ($sourcingVhostUrl =~ m|http://<realm>.([^/]*)|) {
                        $sourcingVirtualHost = $1;
                }

                if ($visibilityVhostUrl =~ m|http://<realm>.([^/]*)|) {
                    $visibilityVirtualHost = $1;
                }
                }

                #
                # Get Supplier URL login, there is only one of these
                #
                my $sourcingSupplierLoginUrls = $sourcing->default('System.PasswordAdapters.SourcingSupplierUser.LoginURLs');
                if ($sourcingSupplierLoginUrls) {
                    my $supplierVhostUrl = $sourcingSupplierLoginUrls->[0];

                    if ($supplierVhostUrl =~ m|http://<realm>.([^/]*)|) {
                        $supplierVirtualHost = $1;
                }
                }

                $s4RealmToCommunityMapFileName = realmToCommunityMapFileNameForProduct($defaultsProduct, $sourcing);
                open(FL, ">$s4RealmToCommunityMapFileName");
                close(FL);

                #
                # token-replace the rewrite rules file for this sourcing
                # product 
                #
                my %sourcingTokenHash = (
                        'S4REALMTOCOMMUNITYMAPFILE' => $s4RealmToCommunityMapFileName,
                        'SOURCINGCONTEXTROOT' => $sourcingContext,
                        'SOURCINGBUYERLOGIN' => $sourcingBuyerLogin,
                        'SOURCINGSUPPLIERLOGIN' => $sourcingSupplierLogin,
                        'SUPPLIERVHOST' => $supplierVirtualHost,
                        'SOURCINGVHOST' => $sourcingVirtualHost,
                        'SERVICEHOST' => $serverHost,
                        'VISIBILITYVHOST' => $visibilityVirtualHost,
                        'PRODNAME' => $pname,
                        );

                if ($config{'SOURCINGCONTEXTLOCATIONPATTERN'}) { 
                    $config{'SOURCINGCONTEXTLOCATIONPATTERN'} .= "|";
                }
                $config{'SOURCINGCONTEXTLOCATIONPATTERN'} .= $sourcingContext;

                my $sourcingRewritesTemplate = $ENV{'ARIBA_CONFIG_ROOT'} . "/sourcingrewriteincludes.conf";
                my $sourcingRewritesOutput = $ENV{'ARIBA_CONFIG_ROOT'} . "/sourcing-$pname-$role-rewriteincludes.conf";

                my $sourcingConfigString = tokenizeHttpdConfig(\%sourcingTokenHash,$sourcingRewritesTemplate,$sourcingRewritesOutput,$defaultsProduct, $type);

                my $sourcingIncludesString = $config{'SOURCINGREWRITEINCLUDES'} || "";
                $sourcingIncludesString .= "Include " . $ENV{'ARIBA_CONFIG_ROOT'} . "/$sourcingRewritesOutput\n";

                if ($sourcing->singleHostForRoleInCluster('testserver')) {
                    my $sourcingTestRewritesTemplate = $ENV{'ARIBA_CONFIG_ROOT'} . "/sourcingtestrewriteincludes.conf";
                    my $sourcingTestRewritesOutput = $ENV{'ARIBA_CONFIG_ROOT'} . "/sourcing-$pname-test-rewriteincludes.conf";

                    my $sourcingTestConfigString = tokenizeHttpdConfig(\%sourcingTokenHash,$sourcingTestRewritesTemplate,$sourcingTestRewritesOutput,$defaultsProduct,$type);
                    $sourcingIncludesString .= "Include " . $ENV{'ARIBA_CONFIG_ROOT'} . "/$sourcingTestRewritesOutput\n";
                }


                $config{'SOURCINGREWRITEINCLUDES'}  = $sourcingIncludesString;
            }
        }

        for my $pname (ariba::rc::Globals::sharedServiceBuyerProducts()) {
            if (ariba::rc::InstalledProduct->isInstalled($pname, $service)) {

                $buyer = ariba::rc::InstalledProduct->new($pname, $service),
                    $buyerContext = $buyer->default('Tomcat.ApplicationContext');

                my $buyerCustomerLoginUrls = $buyer->default('System.PasswordAdapters.PasswordAdapter1.LoginURLs');

                if ($buyerCustomerLoginUrls) {
                    my $procurementVhostUrl = $buyerCustomerLoginUrls->[0];
                    my $invoicingVhostUrl = $buyerCustomerLoginUrls->[1];

                    if ($invoicingVhostUrl =~ m|http://<realm>.([^/]*)|) {
                        $invoicingVirtualHost = $1;
                    }

                    if ($procurementVhostUrl =~ m|http://<realm>.([^/]*)|) {
                        $procurementVirtualHost = $1;
                    }

                }
                $buyerRealmToCommunityMapFileName = realmToCommunityMapFileNameForProduct($defaultsProduct, $buyer);
                open(FL, ">$buyerRealmToCommunityMapFileName");
                close(FL);

                my $mobile_community = 0;
                if ( $role eq 'mwswebserver' ) {
                    $mobile_community = getMobileCommunity($defaultsProduct);
                }

                my %buyerTokenHash = (
                        'BUYERREALMTOCOMMUNITYMAPFILE' => $buyerRealmToCommunityMapFileName,
                        'BUYERCONTEXTROOT' => $buyerContext,
                        'INVOICINGVHOST' => $invoicingVirtualHost,
                        'PROCUREMENTVHOST' => $procurementVirtualHost,
                        'SERVICEHOST' => $serverHost,
                        'PRODNAME' => $pname,
                        'MOBILECOMMUNITY' => $mobile_community,
                );

                $config{'BUYERCONTEXTROOT'} = $buyerContext unless defined $config{'BUYERCONTEXTROOT'};
                if ($config{'BUYERCONTEXTLOCATIONPATTERN'}) { 
                    $config{'BUYERCONTEXTLOCATIONPATTERN'} .= "|";
                }
                $config{'BUYERCONTEXTLOCATIONPATTERN'} .= $buyerContext;


                my $buyerRewritesTemplate = $ENV{'ARIBA_CONFIG_ROOT'} . "/buyerrewriteincludes.conf";
                my $buyerRewritesOutput = $ENV{'ARIBA_CONFIG_ROOT'} . "/buyer-$pname-$role-rewriteincludes.conf";
                my $buyerConfigString = tokenizeHttpdConfig(\%buyerTokenHash,$buyerRewritesTemplate,$buyerRewritesOutput,$defaultsProduct,$type);

                my $buyerIncludesString = $config{'BUYERREWRITEINCLUDES'} || "";
                $buyerIncludesString .= "Include " . $ENV{'ARIBA_CONFIG_ROOT'} . "/$buyerRewritesOutput\n";

                if ($buyer->singleHostForRoleInCluster('testserver')) {
                    my $buyerTestRewritesTemplate = $ENV{'ARIBA_CONFIG_ROOT'} . "/buyertestrewriteincludes.conf";
                    my $buyerTestRewritesOutput = $ENV{'ARIBA_CONFIG_ROOT'} . "/buyer-$pname-test-rewriteincludes.conf";

                    my $buyerTestConfigString = tokenizeHttpdConfig(\%buyerTokenHash,$buyerTestRewritesTemplate,$buyerTestRewritesOutput,$defaultsProduct,$type);
                    $buyerIncludesString .= "Include " . $ENV{'ARIBA_CONFIG_ROOT'} . "/$buyerTestRewritesOutput\n";
                }

                $config{'BUYERREWRITEINCLUDES'}  = $buyerIncludesString;
            }
        }
    }
    $config{'MAXUPLOADSIZE'} = $maxuploadsize;
    my $confString = tokenizeHttpdConfig(\%config,$templateFile,$configOutputFile,$defaultsProduct,$type);

    unless ($confString) {
        die "There was an error in doing tokenizeHttpdConf!";
    }

    my $user  = $defaultsProduct->default('webserveruser');
    my $group = $defaultsProduct->default('webservergroup');

    my $SUDO = ariba::Ops::Startup::Common::realOrFakeSudoCmd();

    # Make dirs needed by apache and supporting cgi
    r("$SUDO $mkdir -p $logDir/safe");
    r("$SUDO $mkdir -p $logDir/ssl_mutex");
    r("$SUDO $chown -R $user:$group $logDir");

    if ($certServerHost) {
        r("$SUDO $mkdir -p " . apacheLogDir() . "/$certServerHost$certServerPort/safe");
        r("$SUDO $mkdir -p " . apacheLogDir() . "/$certServerHost$certServerPort/ssl_mutex");
        r("$SUDO $chown -R $user:$group " . apacheLogDir() . "/$certServerHost$certServerPort");
    }

    if ($cacheRoot) {
        r("$SUDO $rm -fr $cacheRoot");
        r("$SUDO $mkdir -p $cacheRoot");
        r("$SUDO $chown -R $user:$group $cacheRoot");
        r("$chmod -R 700 $cacheRoot");
    }

    return join(' ', (map { "-D$_ " } (@defines)) );
}

sub rewriteRulesForASPProducts {
    my $me = shift;
    my $role = shift;

    my $configDir = $me->configDir();
    my $configFile = "$configDir/rewriterules-$role.conf";

    my @aesFirstRules = rewriteRulesForAES($role, "firstPass");
    my @tomcatRules = rewriteRulesForTomcatASPApps($role);
    my @aesRules = rewriteRulesForAES($role, "secondPass");
    my @vikingToS2LegacyRules = rewriteRulesForLegacyASPApps($role);

    open(CONF,"> $configFile.$$") || die "Error: can't open for write $configFile.$$\n";
    print CONF "#\n";
    print CONF "# This is an automatically generated file\n";
    print CONF "#\n";
    print CONF "# AES related $role rewrite rules for customers who";
    print CONF "# default to AES for their front door:\n";
    print CONF "#\n";
    print CONF join("\n", @aesFirstRules);
    print CONF "#\n";
    print CONF "# Tomcat app (ANL, ACM, S2, CDBUYER) related $role rewrite rules:\n";
    print CONF "#\n";
    print CONF join("\n", @tomcatRules);
    print CONF "#\n";
    print CONF "# AES related $role rewrite rules:\n";
    print CONF "#\n";
    print CONF join("\n", @aesRules);
    print CONF "#\n";
    print CONF "# Legacy rewrite rules for S2 apps to redirect old Viking URLs\n";
    print CONF "#\n";
    print CONF join("\n", @vikingToS2LegacyRules);
    print CONF "# end of file\n";
    close(CONF);
    rename("$configFile.$$", "$configFile");

    return $configFile;
}

sub rewriteRulesForAES {
    my $role = shift;
    my $pass = shift;

    my @aesRules = ();
    # 
    # aes does not have an adminserver 
    #
    return @aesRules if $role =~ /adminserver/;

    # aes customer instances
    my @aspProducts   = (
        ariba::rc::InstalledProduct->installedProductsList(undef, 'aes'),
    );

    my $me = ariba::rc::InstalledProduct->new('aesws', $ENV{'ARIBA_SERVICE'});
    my $docRoot = $me->docRoot();

    #
    # some customers are substrings of others, sort in reverse order, so
    # that apache config regex appear in the right order in the config
    # file
    #
    for my $product (sort {$b->customer() cmp $a->customer()} @aspProducts) {

        #
        # On firstPass, we only produce rules for AES instances that are
        # the default front door for integrated apps.  On secondPass, we
        # do the opposite.  In short, the firstPass rules get placed ahead
        # of the rules for ANL and ACM, making the customer name by itself
        # take precidence.
        #
        my $frontdoor = $product->default('aes_default_frontdoor');
        $frontdoor = "false" unless($frontdoor);
        next if($pass eq "firstPass" && $frontdoor eq "false");
        next if($pass eq "secondPass" && $frontdoor eq "true");

        my $name          = $product->name();
        my $customer      = $product->customer();
        my $webLogicPort  = $product->default('webserver_port') || $product->default('server1_port');
        my @webLogicHosts = $product->hostsForRoleInCluster('sourcing', $product->currentCluster());

        unless ($webLogicPort) {
            # multi-node AES instances use Weblogic plugin
            my @appInstances = $product->appInstancesVisibleViaRoleInCluster($role, $product->currentCluster());
            next if (scalar(@appInstances) > 1);

            my ($instance) = $product->appInstancesOnHostLaunchedByRoleInCluster($webLogicHosts[0], 'sourcing', $product->currentCluster());
            $webLogicPort = $instance->port();
        }

        my $baseMajorRelease = $product->baseMajorReleaseName();

        my $loginPage;
        if ($baseMajorRelease >= 4.1) {
            $loginPage = "http://$webLogicHosts[0]:$webLogicPort/Sourcing/suppliers.jsp";
        } else {
            $loginPage = "http://$webLogicHosts[0]:$webLogicPort/index.jsp";
        }
        push( @aesRules,
            "RewriteRule\t^/$customer/?\$\t$loginPage\t[P,L]\n"
        );

        #
        # Starting 4.1 sourcing urls were seggregated into /Sourcing
        # namespace. We still have 2 4.0 customers (rn, sourcing1)
        # so we need to have 4.0 style rewrite.
        # 
        # XXXXX
        #
        # Note: 4.0 style rewrite conflicts with anl jk rules and
        # will cause problems. It should be taken out as soon as
        # we can
        #
        if ($baseMajorRelease >= 4.1) {
            push( @aesRules,
                "RewriteRule\t^/$customer/Sourcing/?\$\thttp://$webLogicHosts[0]:$webLogicPort/Sourcing/\t[P,L]\n"
            );
            push( @aesRules,
                "RewriteRule\t^/$customer/(Sourcing/.*)\thttp://$webLogicHosts[0]:$webLogicPort/\$1\t[P,L]\n"
            );
        } else {
            #
            # Do not match this for Analysis! If there is a 4.0
            # aes customer who wants to do analysis, we cannot
            # support it.
            #
            push( @aesRules,
                "RewriteCond\t\%{REQUEST_URI}\t!^/$customer/Analysis/\n",
                "RewriteCond\t\%{REQUEST_URI}\t!^/$customer/anl/\n",
                "RewriteRule\t^/$customer/(.*)\thttp://$webLogicHosts[0]:$webLogicPort/\$1\t[P,L]\n"
            );
        }

        #
        # Split docroot vending. Vend static resources in
        # /AribaSourcing directly from webserver
        #
        if ($baseMajorRelease >= 4.2) {
            push( @aesRules,
                "RewriteRule\t^/$customer/AribaSourcing/?(.*)\t$docRoot/$customer/$name/\$1\n"
            );

        }
    }

    return @aesRules;

}

sub rewriteRulesForLegacyASPApps {
    my $role = shift;

    # assume anyone running S2 will not have legacy Viking/4r4
    # installed; generate redirects to the appropriate S2 instances
    # from the legacy URLs
    
    my @s2Products = ariba::rc::InstalledProduct->installedProductsList(undef, 's2');

    my @rules = ();

    for my $product (sort {$b->customer() cmp $a->customer()} @s2Products) {

        my $customer = $product->customer();
        my $service = $product->service();

        next if ( ariba::rc::InstalledProduct->isInstalled('aes', $service, undef, $customer)
                || ariba::rc::InstalledProduct->isInstalled('acm', $service, undef, $customer)
                || ariba::rc::InstalledProduct->isInstalled('anl', $service, undef, $customer) );


        my $loginPage = $product->default('VendedUrls.FrontDoor');


        # from TMID 71622
        push( @rules,
            #[1] is covered by S2 redirect

            #[2] 
            "RewriteRule\t^/$customer/Sourcing/enterprise.jsp\$\t$loginPage?realm=System&passwordadapter=PasswordAdapter1\t[L]\n",

            #[3]
            "RewriteRule\t^/$customer/Sourcing/suppliers.jsp\$\t$loginPage?realm=System&passwordadapter=SourcingSupplierUser\t[L]\n",

            #[4]
            "RewriteRule\t^/$customer/ACM/Main/?\$\t$loginPage\t[L]\n",

            #[5]
            "RewriteRule\t^/$customer/ACM.*\$\t$loginPage\t[L]\n",
            
            #(6)
            "RewriteRule\t^/$customer/Analysis/Main/?\$\t$loginPage\t[L]\n",
            
            #(7)
            "RewriteRule\t^/$customer/Analysis.*\$\t$loginPage\t[L]\n",

            #(8)
            "RewriteRule\t^/$customer/Sourcing.*\$\t$loginPage?realm=System&passwordadapter=PasswordAdapter1\t[L]\n",

            #[10] 
            "RewriteRule\t^/$customer/Supplier.*\$\t$loginPage?realm=System&passwordadapter=SourcingSupplierUser\t[L]\n",
        );
    }

    return @rules;
}

sub rewriteRulesForTomcatASPApps {
    my $role = shift;

    my @tomcatASPProducts= (
        # anl customers
        ariba::rc::InstalledProduct->installedProductsList(undef, 'anl'),
        # acm customers
        ariba::rc::InstalledProduct->installedProductsList(undef, 'acm'),
        # s2 customers
        ariba::rc::InstalledProduct->installedProductsList(undef, 's2'),
        # cdbuyer customers
        ariba::rc::InstalledProduct->installedProductsList(undef, 'cdbuyer'),
    );

    my @rules = ();

    my $me = ariba::rc::InstalledProduct->new('aesws', $ENV{'ARIBA_SERVICE'});
    my $docRoot = $me->docRoot();

    #
    # some customers are substrings of others, sort in reverse order, so
    # that apache config regex appear in the right order in the config
    # file
    #
    for my $product (sort {$b->customer() cmp $a->customer()} @tomcatASPProducts) {
        my $customer      = $product->customer();

        my $appcontext = $product->default('Tomcat.ApplicationContext');

        my $loginPage;
        if ($role =~ /adminserver/) {
            $loginPage = $product->default('VendedUrls.AdminFrontDoorTopURL');
            next unless $loginPage;
            $loginPage .= "/$appcontext/Main";

        } else {
            $loginPage = $product->default('VendedUrls.FrontDoor');
        }

        push( @rules,
            "RewriteRule\t^/$customer/?\$\t$loginPage\t[L]\n",
            "RewriteRule\t^/$appcontext/?\$\t$loginPage\t[L]\n",
        );

        if ($product->name() eq 's2') {
            push( @rules,
                "RewriteRule\t^/$customer/buyers/?\$\t$loginPage\t[L]\n",
                "RewriteRule\t^/$customer/suppliers/?\$\t$loginPage?realm=System&passwordadapter=SourcingSupplierUser\t[L]\n",
            );
        }
    }

    return @rules;
}

sub generateProxyFilesForRole {
    my ($me, $role) = @_;

    my $redirectTo   = ($me->hostsForRoleInCluster('monserver', 
                $me->currentCluster()))[0] . ":" .  $me->default('webserverhttpsport');

    my @redirectURIs = qw(
        index-page-for-machines pagestatus queryInspector show-page status-for-product
        list-contacts powergraph recent-outages show-schedule vm
    );

    for my $uri (@redirectURIs) {

        my $proxyFile = "$main::INSTALLDIR/docroot/cgi-bin/$uri.proxy";
        unlink($proxyFile);

        if ($role eq "backup-monserver") {
            open(FL, "> $proxyFile") || next;
            print FL "https://$redirectTo/cgi-bin/$uri\n";
            close(FL);
        }
    }
}

sub overrideAdminURLs {
    my $defaultsProduct = shift;

    my ($anAdminServer)  = $defaultsProduct->default('acadminurlprefix');
    my ($ibxAdminServer) = $defaultsProduct->default('ibx.adminurl');
    my ($fxAdminServer)  = $defaultsProduct->default('fx.adminurlprefix');

    my @rewriteURLS = ();
    my %args = ();

    my $adminServer = $anAdminServer  || $ibxAdminServer || $fxAdminServer;
    $adminServer =~ s|(.*://[^/]*)(/.*)|$1|; # /

    push(@rewriteURLS, qw(WOCGIAdaptorURL WOCGIAdaptorURLSecure CatalogTesterTestURL));

    for my $arg (@rewriteURLS) {
        my $key = lc($arg);
        my $val = $defaultsProduct->default($key);
        if (defined $val && $val) {
            $val =~ s|(.*://[^/]*)(.*)|$adminServer$2|;
            $args{$arg} = $val;
        }
    }

    return %args;
}

sub writeWebObjectsXMLConfFile {
    my ($me, $role, $products) = @_;


    my $retryDefault  = 0;
    my $sendTODefault = 5;
    my $recvTODefault = 90;
    my $cnctTODefault = 3;
    my $redirTODefault  = $me->docRoot() . '/busy/busy.html';
    my $errHttpCodeDefault = 200;
    my $configDir = $me->configDir();
    my $cluster = $me->currentCluster();

    if ($me->name() eq 'ws') {
        $redirTODefault  = 'https://' . $me->default('ServiceHost') . '/busypage/busy.html';
    }

    my $wofconf = "$configDir/WebObjects-$role.xml";
    my $confString  = join "\n", (
        qq(<?xml version="1.0" encoding="UTF-8"?>),
        qq(<!DOCTYPE adaptor SYSTEM "woadaptor.dtd">),
        qq(\n),
    );

    $confString .= join ' ', (
            qq(<adaptor),
            qq(protocol="http"),
            qq(transport="fsocket"),
            qq(urlVersion="4"),
            qq(>\n\n),
    );

    # Get the roles played by this host for this product
    my %applications = ();

    for my $product (@$products) {
        # For each role, see if the role makes some wof app visible
        # through this host. If so add the app info to the conf
        # file.
        my @instances = $product->appInstancesVisibleViaRoleInCluster($role, $cluster);

        for my $instance (sort { $a->appName() cmp $b->appName() } @instances) {
            #
            # Make sure that only WOF and Java app types or app with Write2WOXml flag end
            # up in WebObjects config file
            #
            next unless ($instance->isWOFApp() || $instance->isJavaApp() || $instance->write2WOXml() );

            my $appName = $instance->exeName();

            $applications{$appName}->{'retries'}++;

            my $retries  = $instance->retries();

            # XXX - dsully. will have to modify all apps.cfg again to fix this.
            # hack around for right now.
            if (defined $retries and $retries =~ /^\d+$/) {
                $applications{$appName}->{'retries'} = $retries + 1;
            }

            # BEJ - support for new protocol
            if ($instance->deadProbeRetries()) {
                $applications{$appName}->{'deadProbeRetries'} = $instance->deadProbeRetries();
            }

            if ($instance->redir()) {

                if ($instance->redir() =~ /^\//) {
                    $applications{$appName}->{'redir'} = $instance->redir();
                } elsif ($me->name() eq 'ws') {
                    $applications{$appName}->{'redir'} = ariba::rc::Globals::rootDir($me->name(),$me->service()) .'/'.$instance->redir();
                } else {
                    $applications{$appName}->{'redir'} = $me->docRoot() .'/'.$instance->redir();
                }

            } else {

                $applications{$appName}->{'redir'} = $redirTODefault;
            }

            $applications{$appName}->{'errHttpCode'} =
              $instance->errHttpCode() || $errHttpCodeDefault;

            # grab the instance values, and stringify.
            my $instanceDetails = 
                sprintf(qq!<instance id="%s" host="%s" port="%s"
                        sendTimeout="%s"
                        recvTimeout="%s"
                        cnctTimeout="%s"\n\t\t\t!,
                        $instance->instanceId(),
                        $instance->host(),
                        $instance->port(),
                        $instance->sendTo() || $sendTODefault,
                        $instance->recvTo() || $recvTODefault,
                        $instance->cnctTo() || $cnctTODefault,
                        );

            # Add community details if defined.
            my $community = $instance->community();

            if ($community) {

                if (defined $instance->attribute("communityClusterEnabled") && $instance->attribute("communityClusterEnabled") eq 'yes') {
                    $instanceDetails .= "applicationClustering=\"true\"\n\t\t\t";
                    $instanceDetails .= "community=\"" .
                    $product->default("CommunityCluster." .$community . ".CommunityList").
                    "\"\n\t\t\t";
                }
                else {
                    $instanceDetails .= "community=\"$community\"\n\t\t\t";
                }
                $applications{$appName}->{'communityDispatch'} = "true";
            }
            my $noCommunityAction = $instance->noCommunityAction();
            if ($noCommunityAction) {
                $applications{$appName}->{'noCommunityAction'} = $noCommunityAction;
            }
            my $truncateCommunityLookup = $instance->truncateCommunityLookup();
            if ($truncateCommunityLookup) {
                $applications{$appName}->{'truncateCommunityLookup'} = $truncateCommunityLookup;
            }
                
            # Add extended protocol information
            if ($instance->processingTo()) {
                $instanceDetails .= "processingTimeout=\"" . $instance->processingTo() . "\"\n\t\t\t";
                $instanceDetails .= "pingTimeout=\"" . $instance->pingTo() . "\"\n\t\t\t";
            }

            if ($instance->transportPort()) {
                $instanceDetails .= "transportPort=\"" . $instance->transportPort() . "\"\n\t\t\t";
            }

            if ($instance->newInstanceTo()) {
                $instanceDetails .= "newInstanceTimeout=\"" . $instance->newInstanceTo() . "\"\n\t\t\t";
            }

            if ($instance->newInstanceTo() || $instance->processingTo()) {
                $instanceDetails .= "lastRecvTimeout=\"" . $instance->lastRecvTo() . "\"\n\t\t\t";
            }
            
            $instanceDetails .= "/>\n";

            push (@{$applications{$appName}->{'instances'}}, $instanceDetails);
        }
    }

    for my $appName (sort keys %applications) {

            
        # support for extended protocol
        my $probeRetries =  $applications{$appName}->{'deadProbeRetries'};

        # Community dispatch support
        my $communityParams;
        my $communityDispatch = $applications{$appName}->{'communityDispatch'};
        if ($communityDispatch) {
            $communityParams = "communityDispatch=\"$communityDispatch\"";
            my $act = $applications{$appName}->{'noCommunityAction'} || "random";
            if ($act eq "random") {
                $communityParams .= " noCommunityRandom=\"true\"";
            } elsif ($act =~ /^\d+$/) {
                $communityParams .= " noCommunityDefault=\"$act\"";
            } else {
                $communityParams .= " noCommunityUrl=\"$act\"";
                my $trunc = $applications{$appName}->{'truncateCommunityLookup'};
                if ($trunc) {
                    $communityParams .= " noCommunityUrlTruncateBody=\"$trunc\"";
                }
            }
        }

        $confString .= sprintf(
          qq!\t<application name="%s" scheduler="ROUNDROBIN" retries="%d"\n\t\tredir="%s" errHttpCode="%s" dormant="60"%s%s>\n!,
            $appName,
            ($applications{$appName}->{'retries'} - 1),
            $applications{$appName}->{'redir'},
            $applications{$appName}->{'errHttpCode'},
            ($probeRetries ? "\n\t\tdeadProbeRetries=\"$probeRetries\"" : ""),
            ($communityParams ? "\n\t\t$communityParams" : "")
        );

        ariba::Ops::Utils::fisherYatesShuffle($applications{$appName}->{'instances'});

        $confString .= "\t\t";
        $confString .= join "\t\t", (@{$applications{$appName}->{'instances'}});
        $confString .= "\t</application>\n\n";
    }

    $confString .= "</adaptor>\n";

    open(CONF,"> $wofconf.$$") || die "can't open for write $wofconf.$$\n";
    print CONF $confString;
    close(CONF);
    rename("$wofconf.$$", "$wofconf");
}

# 
# For an explanation of weblogic module parameters see
# http://edocs.bea.com/wls/docs81/plugins/plugin_params.html
#
sub writeModWLConfigFile {
    my $me = shift;
    my $role = shift;
    my $products = shift;

    my $configDir = $me->configDir();
    my $docRoot = $me->docRoot();

    my $cluster   = $me->currentCluster();
    my $configFile = "$configDir/modwl-$role.conf";

    my $confString = "# This is an automatically generated file\n";

    #
    # Cycle over all products and generate one file for all workers
    #
    for my $product (@$products) {

        my $productName = $product->name();
        my $customer = $product->customer();

        my @appInstances = $product->appInstancesVisibleViaRoleInCluster($role, $cluster);

        # don't use modwl for single-node
        next unless scalar(@appInstances) > 1;

        #
        # first check to see if this product has any weblogic
        # instances
        #
        my $hasWeblogicAppInstances = 0;
        for my $appInstance (@appInstances) {
            if ($appInstance->isWebLogicApp()) {
                $hasWeblogicAppInstances = 1;
                last;
            }
        }

        next unless ($hasWeblogicAppInstances);

        #
        # Cluster information
        #
        my @clusteredHosts = ();
        for my $appInstance (@appInstances) {
            next unless ($appInstance->isWebLogicApp());
            my $port = $appInstance->port();
            my $host = $appInstance->host();
            push(@clusteredHosts, qq($host:$port));
        }

        next unless @clusteredHosts;

        $confString  .= join "\n", (
            qq(\n# Begin config section for $productName <$customer>),
            qq(RewriteRule\t^/$customer/AribaSourcing/?(.*)\t$docRoot/$customer/$productName/\$1),
            qq(RewriteRule\t^/$customer/?\$\t/$customer/Sourcing/suppliers.jsp [PT,L]),
            qq(RewriteRule\t^/$customer/Sourcing\$\t/$customer/Sourcing/ [PT,L]),
 
            qq(<Location "/$customer/Sourcing">),
                qq(\tSetHandler weblogic-handler),
                qq(\tWeblogicCluster ) . join(",", @clusteredHosts),
                qq(\tPathTrim /$customer),
                qq(\tErrorPage /busy/busy.html),
                qq(\tDynamicServerList OFF),
            qq(</Location>\n),
        );

        my $nodeNum = 0;
        for my $clusteredHost (@clusteredHosts) {
            ++$nodeNum;
            my $nodeName = "Node$nodeNum";

            $confString  .= join "\n", (
                qq(<Location "/$customer/Sourcing/$nodeName>),
                qq(\tSetHandler weblogic-handler),
                qq(\tWeblogicCluster $clusteredHost),
                qq(</Location>\n),
            );
        }
    }

    open(CONF,"> $configFile.$$") || die "Error: can't open for write $configFile.$$\n";
    print CONF $confString;
    close(CONF);
    rename("$configFile.$$", "$configFile");

    return ($configFile);
}

#
# XXX -- this probably needs to be written to work such that each web server
# maps 1 to 1 to a fastcgi node.  For now we'll just use one worker...
# that's enough to demo it, and I'm not sure how this would look in a
# many to many case.
#
sub createPiwikConfigFile {
    my $me = shift;
    my $cfg="";
    
    my $piwikIndex = $me->default('FastCGI.PiwikIndex');
    my $configDir = $me->configDir();
    my $confFile = "$configDir/httpd-piwik-fastcgi_external.conf";

    foreach my $appInstance ($me->appInstancesLaunchedByRoleInCluster('piwikapps', $me->currentCluster())) {
        my $host = $appInstance->host();
        my $port = $appInstance->port();

        $cfg .= "\tFastCgiExternalServer \"$piwikIndex\" -host ${host}:$port\n";
    }

    open(CONF,"> $confFile");
    print CONF $cfg;
    close(CONF);
}

sub byAppNameAndOrderId {
    return 0 unless ($a->orderId() && $b->orderId());

    return $a->appName() cmp $b->appName() || 
           $a->orderId() <=> $b->orderId();
}

###########################################################################################
# Helper method to fetch AppInstances. The only purpose is to have a name that is intutive
# for people to understand as we now fetch AppInstances in different states and this method
# explicitly says what the default method to fetch is.
###########################################################################################
sub getDefaultAppInstances
{
    my $product = shift;
    my $role    = shift;
    my $cluster = shift;
    my @appInstances = $product->appInstancesVisibleViaRoleInCluster($role, $cluster);
    return(@appInstances);
}

########################################################################################
# Helper method to fetch AppInstances from a given product and filter it based on
# the bucket number passed
########################################################################################
sub getAppInstancesByBucket
{
   my $requestedBucket  = shift;
   my $product          = shift;   
   my $role             = shift;
   my $cluster          = shift;
   
   my @instanceList = getDefaultAppInstances($product,$role, $cluster);
    
   my @filteredInstanceList = ();   
   foreach my $instance (@instanceList)
   {
        if ($instance->recycleGroup() == $requestedBucket) {            
            push @filteredInstanceList , $instance;
        }        
   }
   
   return(@filteredInstanceList);
}

sub getInstancesInBucket 
{
   my ($buildArgs,$productName , $service,$role,$cluster) = @_;
   my  @appInstances = ();

   my ($buildName,$bucket) = split(':',$buildArgs);
   if(defined($buildName) && defined($bucket)) {
       unless (ariba::rc::InstalledProduct->isInstalled($productName , $service, $buildName)) 
       {
          die "Unable to find  installed product: Product=$productName , Service=$service , BuildName=$buildName\n";
       }

       my $product = ariba::rc::InstalledProduct->new($productName, $service, $buildName);
       @appInstances =  getAppInstancesByBucket($bucket,$product,$role,$cluster);
   }
   return (@appInstances);    

}

############################################################################################
# All the logic to fetch appInstances based on how Apache.pm is invoked is encapsulated
# in this subroutine.
# Apache.pm can be invoked in multiple ways:
#   During Regular startup: 
#     fetches appInstances() from installed product
#   During Capacity change:
#     After bucket0 shuts down: B0 instances from new product + B1 instances from old product
#     After bucket1 shuts down: B0 and B1 instances from new product
############################################################################################
sub getAppInstances
{
    my $product                 = shift; #Values like: buyer , s4
    my $role                    = shift; #Values like: ss-webserver,ss-adminserver
    my $cluster                 = shift; #Values like: primary    
    my $changingProductName     = shift; #Passed during dynamic capacity change - its a product name like buyer
    my $oldBuildArgs            = shift; #Used to fetch new build , Format : SSPR3-500:0
    my $newBuildArgs            = shift; #Used to fetch new build , Format : SSPR3-510:1
  
    my   $productName  = $product->name();
    my   (@appInstances,@appInstances0,@appInstances1) = ();
    #When no product is changing or if the current product is not the changing product 
    if(!isChangingProduct($productName,$changingProductName))
    {        
        @appInstances = getDefaultAppInstances($product, $role , $cluster);
    }
    else
    {
        my $service          = $product->service();  
       
        @appInstances0 = getInstancesInBucket($oldBuildArgs,$productName , $service, $role,$cluster);
        @appInstances1 = getInstancesInBucket($newBuildArgs,$productName , $service, $role,$cluster);
        @appInstances  = (@appInstances0 , @appInstances1);
        @appInstances  = sort { $a->workerName() cmp $b->workerName() } @appInstances;
    }
    return(@appInstances);
}

#L2P map file will be stored in each webserver in the topology root specific 
#to each product. This method, would create the directory structure for storing 
#l2p map files if the directories do not already exist
sub buildTopoRoot
{
  my $me          = shift;
  my $sswsDocRoot = $me->docRoot();
  my $baseDir = $sswsDocRoot . "/topology/";

  my $buyerTopoRoot = $baseDir . "buyer/";
  mkdirRecursively([$buyerTopoRoot]) unless -d $buyerTopoRoot;

  my $s4TopoRoot    = $baseDir . "s4/";
  mkdirRecursively([$s4TopoRoot]) unless -d $s4TopoRoot;
}

#########################################################################################
# Ensures that bucketSelector passed is a valid one incase its passed.
# Returns:
#    Nothing : Incase bucketSelector passed is valid
#    Aborts  : Incase invalid bucketSelector is passed
#########################################################################################
sub assertValidBucketSelector
{
    my $bucketSelector       = shift;
    
    if (defined($bucketSelector)) {     
        if(($bucketSelector != 0) && ($bucketSelector != 1)) {
          die ("Assertion failure: Unexpected value of bucketSelector, contains:$bucketSelector, valid values are either 0 or 1\n");
        }     
    }      

}

########################################################################################
# Indicates if current product is the changing product.
# Input:
#   productName,changingProductName
# Output:
#   boolean indicating if current product is the changing product
########################################################################################
sub isChangingProduct
{
    my $productName         = shift;
    my $changingProductName = shift;
    my $isChangingProduct   = 0;
    
    if((defined $changingProductName) && ($productName eq $changingProductName)){
      $isChangingProduct = 1;
    }
    return($isChangingProduct);
}

#########################################################################################
# As part of dynamic capacity, for realm rebalance usecase, during Flux state, we should 
# update the load balancer workers for only one bucket.  This method implements above logic.
# 
# Note: This method should be used in conjunction with isChangingProduct() otherwise all 
# products would get updated
# Input:
#   $appInstance       : Tomcat AppInstance
#   $bucketSelector    : Contain 0 or 1, indicates the bucket to be selected
# Output:
#   boolean indicating if its necessary to include a balance worker in ModJK config file
##########################################################################################
sub shouldUpdateBalanceWorker
{
    my $appInstance         = shift;   
    my $bucketSelector      = shift; #This would be undef if its not a flux state rebalance
    my $updateBalanceWorker = 1;  
   
    if(defined($bucketSelector)) {
        if($bucketSelector != $appInstance->recycleGroup() ) {
           $updateBalanceWorker=0;
        }
    }
    return($updateBalanceWorker);
}

# getMobileCommunityFromMap - returns community number for aribamobileapi from
#    MWS buyer community/realm map file and sets mobileCommunity file.
sub getMobileCommunityFromMap {
    # $me is $me from startup script for MWS (or SSWS) product
    my $me = shift;

    my $mapFileName = $me->default( 'RealmToCommunityMapDir' ) . '/buyer.txt';

    # Read in MWS community/realm map file
    my $community = '';
    my $realm;
    if ( !open(CMAP, "<$mapFileName") ) {
        # unable to open file, community not found
        return 0;
    }
 
    while ( my $line = <CMAP> ) {
        # skip non-mobile lines
        next unless $line =~ /aribamobileapi/i;

        # get realm and community from line
        ( $realm, $community ) = split /\s+/, $line;

        last if $community;
    }
    close(CMAP);

    # set zero community if undefined
    my $mobileCommunity = $community || 'C0';

    ## This will be 'C\d', strip off the 'C' and leave just the community number:
    $mobileCommunity =~ s/C//;

    return $mobileCommunity;
}

# getMobileCommunity - will get community number from mobileCommunity file
sub getMobileCommunity {
    my $me = shift;

    my $mobileCommunityFile = $me->default( 'RealmToCommunityMapDir' ) . 'mobileCommunity';

    my $community = 0;
    if ( open(MOBILE,"<$mobileCommunityFile") ) { 
        $community = <MOBILE> || 0;
        close(MOBILE);
    }
    return $community;
}

# writeMobileCommunityFile - will write out mobileCommunity file
sub writeMobileCommunityFile {
    my $me = shift;
    my $community = shift || 0;

    if ( $community > 0 ) {
        my $mobileCommunityFile = $me->default( 'RealmToCommunityMapDir' ) . 'mobileCommunity';
        # write out Community number to mobileCommunity file
        if ( open(MOBILE,">$mobileCommunityFile") ) {  
            print MOBILE $community;
            close(MOBILE);
        }
    }
}
sub writeModJKConfigFile {
    my $me = shift;
    my $role = shift;
    my $products = shift;
    my $changingProductName  = shift; #Possible values: buyer, s4
    my $oldBuildArgs         = shift; 
    my $newBuildArgs         = shift;
    my $bucketSelector       = shift; #Contains 0,1 or undef
  
    my $configDir = $me->configDir();
    my $cluster   = $me->currentCluster();
    my $configFile = "$configDir/modjk-$role.properties";
    my $softAffinityFile = "$configDir/jkmount-$role.conf";
    my $wsName = $me->name();
    my $releaseName = $me->releaseName();

    my $mobile_community = 0;
    if ( $role eq 'mwswebserver' ) {
        $mobile_community = getMobileCommunityFromMap($me);
        writeMobileCommunityFile($me, $mobile_community);
    }

    my $modJK = "new";
    # Going back to old modjk for ssws, grr
    $modJK = "old" if ($wsName eq "ssws"); # See TMID 130174

    my $confString = "# This is an automatically generated file\n";
    my $jkMountString = "# This is an automatically generated file\n";

    #
    # modjk does not like two workers with same host/port combination
    # it fails completely and siliently. Catch this.
    #
    my %hostPortCount;

    my $mpmModel = $ENV{'APACHE_MPM'} || httpdProperty($me, "APACHE_MPM");
    my $httpdIsPrefork = $mpmModel =~ /prefork/ ? 1 : 0;
    my $httpdIsWorker = $mpmModel =~ /worker/ ? 1 : 0;

    #This method checks and builds the directory structure for storing L2P mapping files
    buildTopoRoot($me);
    assertValidBucketSelector($bucketSelector);

    #
    # Cycle over all products and generate one file for all workers
    #
    for my $product (@$products) {
        my $productName = $product->name();
        my $customer = "";
        if ($product->isASPProduct()) {
            $customer = $product->customer();
        }

 		# only add buyer entries for mws
        next if ( $role eq 'mwswebserver' && $productName ne 'buyer' );

        my $workerList = $productName;
        $workerList .= "_$customer" if ($customer);

        # If mws, then switch role to ssws to get app instances
        my $was_mws = 0;
        if ( $role eq 'mwswebserver' ) {
            $was_mws = 1;
            $role = 'ss-webserver';
        }
        my @appInstances = getAppInstances($product, $role, $cluster, $changingProductName, $oldBuildArgs, $newBuildArgs);
        $role = 'mwswebserver' if ( $was_mws );

        my $applicationContext = $product->default('Tomcat.ApplicationContext');

        # we assume this exists below, and it won't exist for non-tomcat apps,
        # so a broken AN build won't disrupt the ssws startup
        next unless defined($applicationContext);

        my $additionalApplicationContexts = $product->default('Tomcat.AdditionalApplicationContexts');

        my @applicationContexts = ($applicationContext); 
        push(@applicationContexts, split(/\s*\|\s*/, $additionalApplicationContexts)) if ( $additionalApplicationContexts );

        #
        # Mod_jk block is only specified for Tomcat app instances.
        # first check to see if this product has any at all.
        #
        my $hasTomcatAppInstances = 0;
        for my $appInstance (@appInstances) {
            if ($appInstance->isTomcatApp() || $appInstance->isSpringbootApp()) {
                $hasTomcatAppInstances = 1;
                last;
            }
        }

        next unless ($hasTomcatAppInstances);

        #
        # generate static information for the properties file
        #
        $confString  .= join "\n", (
            qq(\n),
            qq(# Begin config section for $productName <$customer>\n),
        );

        $jkMountString  .= join "\n", (
            qq(\n),
            qq(# Begin jkmount section for $productName <$customer>\n),
        );

        $jkMountString .= "JkMount\t/$_/*\t$workerList\n" for ( @applicationContexts );

        #
        # generate block of information for each worker
        #
        my @workers;
        my @rebalanceWorkers;
        my @servletWorkers;
        my %servletMounts;
        my %servletLoadBalancedWorkers;
        my $nrJkMountString = "";

        # XXX: Don't sort byAppNameAndOrderId as it will cause 500 errors
        for my $appInstance (@appInstances) {

            next unless ($appInstance->isTomcatApp() || $appInstance->isSpringbootApp());

            # Skip entries for mws not in mobile community
            next if ( $role eq 'mwswebserver'
                      && $mobile_community
                      && $appInstance->community() != $mobile_community );

            my $name = $appInstance->workerName();

            my $port = $appInstance->port();
            my $host = $appInstance->host();
            my $cacheSize = $appInstance->cacheSize();
            my $cacheTimeout = $appInstance->cacheTimeout();

            #
            # Collect data to generate worker list and jkmounts
            # for special purpose per community servlets, some
            # ex are:
            #
            # AN cxml post
            # ERP upload/download activity
            #
            my $alias = $appInstance->alias();
            my $community = $appInstance->community() || 0;
            my $servletsString = $appInstance->servletNames();

            my $shouldUpdateBalanceWorker = 1;
            if(isChangingProduct($productName,$changingProductName)) {
               $shouldUpdateBalanceWorker = shouldUpdateBalanceWorker($appInstance,$bucketSelector);
            }
            
            my @servlets;
            if ($servletsString) {
                @servlets = split(/\s*\|\s*/, $servletsString);
            } else {
                #
                # If this is not a special servlet, add it
                # to the list of workers serving 'Main'
                # servlet
                #
                unshift(@servlets, '*');
                push(@workers, $name);
                push(@rebalanceWorkers, $name) if ($shouldUpdateBalanceWorker);
            }

            if ($alias && @servlets) {
                for my $servlet (@servlets) {
                    my $mount = $servlet;
                    my $lbworker = "$productName$alias";
                    $lbworker .= "$customer" if ($customer);

                    $mount .= "/*" if $appInstance->isSpringbootApp();

                    unless ($servlet eq "*") {
                        $servletMounts{$mount} = $lbworker;
                        $servletLoadBalancedWorkers{$lbworker}{$name} = $name  if ($shouldUpdateBalanceWorker);
                    }

                    if ($community) {
                        $mount .= "/C$community";
                        $lbworker .= "_C$community";

                        #FIXME hack to fix 1-ALY74Z
                        if ($servlet eq "soap") {
                            delete $servletMounts{$mount};
                            $mount .= "/*";
                        }

                        $servletMounts{$mount} = $lbworker;
                        $servletLoadBalancedWorkers{$lbworker}{$name} = $name  if ($shouldUpdateBalanceWorker);;
                    }
                }
                push(@servletWorkers, $name);
            }

            #
            # For prefork binaries cache setting should be
            # set to not cache
            #
            # http://tomcat.apache.org/connectors-doc/reference/workers.html
            #
            if ($httpdIsPrefork) {
                $cacheSize = 1;
                $cacheTimeout = 0;
            }

            $hostPortCount{"$host:$port"}++;

            #
            # in mod_jk >= 1.2.8 socketTimeout got renamed to
            # recycleTimeout and the new socketTimeout means
            # something else now.
            # http://tomcat.apache.org/connectors-doc/reference/workers.html
            # Try and maintain some backward compatibility
            #
            my $recycleTimeout = $appInstance->socketTimeout() || $appInstance->recycleTimeout();

            # following times are in milliseconds
            my $connectTimeout = $appInstance->connectTimeout() || 30000;
            my $prepostTimeout = $appInstance->prepostTimeout() || 30000;
            my $replyTimeout = $appInstance->replyTimeout() || 180000;

            #Node redirect would use logical name in redirection if layout5 is supported
            my $nrKey   = $appInstance->workerName();
            my $nrValue = $appInstance->workerName();
            if($product->isLayout(5)){
                $nrKey = $appInstance->logicalName();
            }
            $nrJkMountString .= "JkMount /$_/nr/$nrKey/*\t$nrValue\n" for ( @applicationContexts );

            if($modJK eq "old") {
                #
                #  "old" == modjk-1.2.14
                #
                $confString .= join "\n", (
                    qq(# instance = $name),
                    qq(worker.$name.type=ajp13),
                    qq(worker.$name.lbfactor=1),
                    qq(worker.$name.port=$port),
                    qq(worker.$name.host=$host),
                    qq(worker.$name.cache_timeout=$cacheTimeout),
                    qq(worker.$name.recycle_timeout=$recycleTimeout),
                    qq(worker.$name.connect_timeout=$connectTimeout),
                    qq(worker.$name.prepost_timeout=$prepostTimeout),
                    qq(worker.$name.reply_timeout=$replyTimeout),
                    qq(worker.$name.socket_keepalive=1),
                    qq(\n),
                );
            } else {
                #
                #  "new" == modjk-1.2.28
                #

                #
                # use $recycleTimeout if $cacheTimeout is zero
                #
                $cacheTimeout = $recycleTimeout unless($cacheTimeout);

                $confString .= join "\n", (
                    qq(# instance = $name),
                    qq(worker.$name.type=ajp13),
                    qq(worker.$name.lbfactor=1),
                    qq(worker.$name.port=$port),
                    qq(worker.$name.host=$host),
                    qq(worker.$name.connection_pool_timeout=$cacheTimeout),
                    qq(worker.$name.connect_timeout=$connectTimeout),
                    qq(worker.$name.prepost_timeout=$prepostTimeout),
                    qq(worker.$name.reply_timeout=$replyTimeout),
                    qq(worker.$name.socket_keepalive=1),
                    qq(\n),
                );
            }
        }

        $confString .= "# define worker list and load balance amongst all these workers\n";
        my $errorEscalationTime = 86400; # 1 day

        #
        # Add workers for community specific servlets
        #
        for my $servletWorker (keys(%servletLoadBalancedWorkers)) {
            if ($productName eq 'spotbuy' || $productName eq 'sellerdirect') {
                $confString .= "worker.$servletWorker.sticky_session=0\n";
            }
            else {
                $confString .= "worker.$servletWorker.sticky_session=1\n";
            }
            $confString .= "worker.$servletWorker.error_escalation_time=$errorEscalationTime\n" if($modJK eq "new");
            $confString .= "worker.$servletWorker.type=lb\n";
            # $confString .= "worker.$servletWorker.balance_workers=";
            # $confString .= join(",", keys(%{$servletLoadBalancedWorkers{$servletWorker}})) . "\n";
            my @tempWorkers = keys(%{$servletLoadBalancedWorkers{$servletWorker}});
            for(my $i = 0; $i < scalar(@tempWorkers); $i += 100) {
              my $endPoint = $i + 99;
              $endPoint = $#tempWorkers if $endPoint > $#tempWorkers;

              #
              # XXX -- HACK
              #
              # "old" modjk has a bug which glues lines together with a '*', which
              # makes a mess of the first and last node on a line (at least
              # potentially), so as a hack we put "XX" at beginning and end of
              # line.  These are invalid workers and will get marked as dead,
              # but the side effect is that when modjk glues lines together,
              # it makes an invalid worker named XX*XX out of two already bogus
              # entries, instead of eating two real ones.
              #
              if($modJK eq "old") {
                  $confString .= "worker.$servletWorker.balance_workers=XX," . join(",", @tempWorkers[$i..$endPoint]) . ",XX\n";
              } else {
                  $confString .= "worker.$servletWorker.balance_workers=" . join(",", @tempWorkers[$i..$endPoint]) . "\n";
              }
            }
        }

        $confString .= "#worker.maintain=60\n";
        $confString .= "worker.list=$workerList";
        $confString .= "," . join(",", keys(%servletLoadBalancedWorkers)) if scalar(keys(%servletLoadBalancedWorkers));
        $confString .= "\n";
        for(my $i = 0; $i < scalar(@servletWorkers); $i += 100) {
            my $endPoint = $i + 99;
            $endPoint = $#servletWorkers if $endPoint > $#servletWorkers;
            $confString .= "worker.list=" . join(",", @servletWorkers[$i..$endPoint]) . "\n";
        }
        if ($productName eq 'spotbuy'  || $productName eq 'sellerdirect') {
            $confString .= "worker.$workerList.sticky_session=0\n";
        }
        else {
            $confString .= "worker.$workerList.sticky_session=1\n";
        }       
        if($modJK eq "old") {
            $confString .= "#worker.$workerList.method=Request|Traffic\n";
        } else {
            $confString .= "worker.$workerList.method=Session\n";
            $confString .= "worker.$workerList.error_escalation_time=$errorEscalationTime\n";
        }
        $confString .= "worker.$workerList.type=lb\n";
        # $confString .= "worker.$workerList.balance_workers=";
        # $confString .= join(",", @workers) . "\n";
        for(my $i = 0; $i < scalar(@workers); $i += 100) {
             my $endPoint = $i + 99;
             $endPoint = $#workers if $endPoint > $#workers;

             #
             # HACK -- these XX characters are needed.  See comment about 40
             # lines prior for explaination.
             #
             if($modJK eq "old") {
                 $confString .= "worker.$workerList.balance_workers=XX," . join(",", @workers[$i..$endPoint]) . ",XX\n";
             } else {
                 $confString .= "worker.$workerList.balance_workers=" . join(",", @workers[$i..$endPoint]) . "\n";
             }
        }


        #
        # Add mounts to get to community specific balanced servlets
        #
        if ( $role eq 'mwswebserver' ) {
            $jkMountString .= 'JkMount /Buyer/*/C' . $mobile_community . 
                              ' buyerUI_C' . $mobile_community . "\n";
        }
        else {
            for my $servletMount (sort(keys(%servletMounts))) {
                $jkMountString .= "JkMount /$_/$servletMount\t$servletMounts{$servletMount}\n" for ( @applicationContexts );
            }
        }

        $jkMountString .= $nrJkMountString;

        $confString .= "# End config section for $productName <$customer>\n";
        $jkMountString .= "# End jkmount section for $productName <$customer>\n";
    }

    #
    # Add read-only status worker to the list of worker
    #
    $confString .= join "\n", (
        qq(# status worker),
        qq(worker.list=status),
        qq(worker.status.type=status),
    );
    $confString .= "\nworker.status.read_only=True" if $modJK eq "new";
    $confString .= "\n";
    $jkMountString .= "JkMount /jkstatus status\n";

    #
    # Check to see if modjk will be happy with the configs
    #
    my $modjkConfigError = 0;
    for my $hostPort (keys(%hostPortCount)) {
        if ($hostPortCount{$hostPort} > 1) {
            print "ERROR: $hostPortCount{$hostPort} workers at $hostPort\n";
            print "       This is a fatal error for modjk config.\n";
            $modjkConfigError = 1;
        }
    }
    my @jkLines = split(/\n/, $confString);
    my $linenumber = 0;
    for my $line (@jkLines) {
        $linenumber++;
        if(length($line) > 8100) {
            print "ERROR: $configFile line #$linenumber > 8100 characters long\n";
            print "       This is a fatal error for modjk config.\n";
            $modjkConfigError = 1;
        }
    }
    if ($modjkConfigError) {
        die "ERROR: modjk workers config error. exiting.\n\n";
    }

    open(CONF,"> $configFile.$$") || die "Error: can't open for write $configFile.$$\n";
    print CONF $confString;
    close(CONF);
    rename("$configFile.$$", $configFile);

    open(CONF,"> $softAffinityFile.$$") || die "Error: can't open for write $softAffinityFile.$$\n";
    print CONF $jkMountString;
    close(CONF);
    rename("$softAffinityFile.$$", $softAffinityFile);

    # See the hack notes before the subroutine.
    if ( $role eq 'mwswebserver' ) {
        buildMwsv2Conf( $me );
    }

    return ($configFile, $softAffinityFile);
}

# HACK ALERT!  nginx within mobile can not yet read certs files.  
# As a result all traffic for nginx/mobile is routed through mws.  
# This requires the config file built in this subroutine.
#
# Once ngnix is fixed this will obsolete mws completely.  This subroutine
# and all associated mws code can be ripped out when MWS is sunset

sub buildMwsv2Conf {
    my $me = shift;

    my $configDir = $me->configDir();
    my $cluster   = $me->currentCluster();
    my $configFile = "$configDir/mwsv2.conf";
    my $service = $me->service();

    my $configString = 
        qq(        ProxyPass "/v2/"      "balancer://mobilenginx/v2/"\n) .
        qq(        ProxyPass "/g2/"      "balancer://mobilenginx/g2/"\n) .
        qq(        ProxyPass "/private/" "balancer://mobilenginx/private/"\n) .
        qq(        ProxyPass "/Form/"    "balancer://mobilenginx/Form/"\n) .
        qq(\n) .
        qq(        <Proxy "balancer://mobilenginx">\n);

    unless ( ariba::rc::InstalledProduct->isInstalled( 'mobile', $service )) {
        die "Error: Mobile not installed on this host.  Can not create $configFile\n";
    }

    my $mobile = ariba::rc::InstalledProduct->new( 'mobile' );
    my @hosts = $mobile->hostsForRoleInCluster( 'mobile-nginx', $cluster );
    my $port = $mobile->default( "Nginx.Mobile.Port" );
    
    foreach my $host ( @hosts ) {
        $configString .= qq(            BalancerMember "http://$host:$port"\n);
    }

    $configString .= qq(        </Proxy>\n); 

    open(CONF,"> $configFile.$$") || die "Error: can't open for write $configFile.$$\n";
    print CONF $configString;
    close(CONF);
    rename("$configFile.$$", $configFile);
}

sub buildDocRoot {
    my ($me, $products) = @_;

    my $myname   = $me->name();
    my $destParent = $me->docRoot();

    for my $product (@$products) {

        my $name    = $product->name();
        my $docroot = $product->docRoot();
        unless (defined $docroot) { 
            # doc has its docroot in a different place
            $docroot = $product->default("vendeddirs.contentroot") . "/docroot";
        }
        my $dest_dir = $destParent;

        if ($product->isASPProduct()) {
            $dest_dir = "$destParent/" . $product->customer();
            $docroot  = $product->baseDocRoot();
        }

        my $src  = $docroot;
        my $dest = "$dest_dir/$name";
        unlink ($dest);

        next unless defined $src;
        
        print "Creating $dest -> $src\n";
        mkdirRecursively([$dest_dir]) unless -d $dest_dir;
        symlink($src, $dest) || warn "Warning: Could not create symlink to $src, $!\n";

        for my $pers ( "Personalities", "p") {
            my $frontPage = "$pers/Ariba/DefaultPage/default.htm";
            $src = "$docroot/$frontPage";
            $dest = "$dest_dir/default.htm";
            
            if ( -e $src ) {
                print "Creating $dest -> $src\n";
                unlink ($dest);
                symlink($src, $dest) || 
                    warn "Warning: Could not create symlink to $src, $!\n";
            }
        }

        # TODO: Hack to make AN work
        if ($name eq "an" || $name eq "cxml") {

            opendir(DIR,$docroot);
            my @srcs = grep(!/^\./o,readdir(DIR));
            closedir(DIR);

            for $src (@srcs) {
                $dest = "$dest_dir/$src";
                $src  = "$docroot/$src";
                print "Creating $dest -> $src\n";
                unlink ($dest);
                symlink($src, $dest) || warn "Warning: Could not create symlink to $src, $!\n";
            }
        }
    }


}

sub buildBusyPageSymlink {
    my $me = shift;
    my @products = @_;

    if ($me->name() eq 'ws') {
            
        my $busyPages = ariba::Ops::BusyPageOnHttpVendor->newFromProduct(undef);

        # Get current state (unplanned, rolling, planned...)
        my $currentState = $busyPages->guessState();

        # /home/svcdev/ws/docroot/busypage
        my $src = $me->docRoot() . "/busypage";
    
        # /home/svcdev/ws/busy
        my $dest = ariba::rc::Globals::rootDir($me->name(), $me->service()) . "/busy";

        # This makes sure $dest points to the right state of the right buildname
        # => If we are restarting a just pushed new build, the link was pointing to the right state of the previous build
        $busyPages->setLinkState($currentState);
                    

        if (-l $src) {
            print "Deleting old symlink [$src]\n";
            unlink($src);
        }

        print "Creating symlink [$src] -> [$dest]\n";
        unless (symlink( $dest, $src)) {
            print "Warning : couldn't create symlink [$src]\n";
        }

    } elsif ($me->name() eq 'ssws') {

        my $busyDir = ariba::rc::Globals::rootDir($me->name(), $me->service()) . "/busy";


        foreach my $product (@products) {

    
            # /home/svcdev/ssws/docroot/busy/s4
            my $src = $me->docRoot() . "/busy/" . $product->name();
    
            # /home/svcdev/ssws/busy/s4
            my $dest = ariba::rc::Globals::rootDir($me->name(), $me->service()) . "/busy/" . $product->name();
    
            if (-d $src) {
                
                my $busyPages = ariba::Ops::BusyPageOnHttpVendor->newFromProduct($product->name());

                # Get current state (unplanned, rolling, planned...)
                my $currentState = $busyPages->guessState();

                # This makes sure $dest points to the right state of the right buildname
                # => If we are restarting a just pushed new build, the link was pointing to the right state of the previous build
                $busyPages->setLinkState($currentState);

                if (-l "$src/busy") {
                    print "Deleting old symlink [$src/busy]\n";
                    unlink("$src/busy");
                }
    
                print "Creating symlink [$src/busy] -> [$dest]\n";
                unless (symlink( $dest, "$src/busy")) {
                    print "Warning : couldn't create symlink [$src/busy]\n";
                }
            }
        }
    }
}

sub symlinkModPerlLibs {
    my $me = shift;

    # mod_perl/libapreq's build is different in 2.x, so we drop the Apache
    # modules into the perl tree and link into them.
    my $siteLib = "$Config{'installsitearch'}/Apache2";

    for my $shlib (qw(mod_apreq.so mod_perl.so)) {

        next unless -f "$siteLib/$shlib";

        symlink("$siteLib/$shlib", "$main::INSTALLDIR/lib/modules/$arch/$shlib");
    }
}

sub logDirForRoleHostPort {
    my $role = shift;
    my $serverHost = shift;
    my $serverPort = shift;

    my $logDir = apacheLogDir() . "/$serverHost";

    if ($role eq 'adminserver' 
        || $role eq 'ss-adminserver' 
        || $role eq 'ss-testserver' 
        || $role eq 'monserver'
        || $role eq 'ebswebserver'
        || $role eq 'aodadminserver'
        || $role eq 'cwsadminserver'
        || $role eq 'logi-server') {
        $logDir .= $serverPort if $serverPort;
    }

    return $logDir;
}

sub realmToCommunityMapFileTimestampNameForProduct {
    my $me = shift;
    my $product = shift;

    my $mapFileName = realmToCommunityMapFileNameForProduct($me, $product);
    return "$mapFileName.timestamp";
}

sub realmToCommunityMapFileNameForProduct {
    my $me = shift;
    my $product = shift;

    my $realmToCommunityMapDir = $me->default('RealmToCommunityMapDir') || "/tmp";
    my $productName = $product->name();

    my $realmToCommunityMapFileName = "$realmToCommunityMapDir/$productName.txt";

    return $realmToCommunityMapFileName;
}

sub logViewerUrlForProductRoleHostPort {

    my $product = shift;
    my $role = shift;
    my $host = shift;
    my $port = shift;


    my $serviceHost = $product->default('servicehost');
    $serviceHost =  $product->default('adminservicehost') if ($role =~ /adminserver/);
    my $logViewerPort = ariba::Ops::Constants->logViewerPort();     
    my $apacheUrl = 'http://' . $host . ":$logViewerPort/lspatapache/" . ariba::Ops::Startup::Apache::logDirForRoleHostPort($role, $serviceHost, $port);

    my $logdir = apacheLogDir();
    $apacheUrl =~ s#$logdir/##;
    $apacheUrl =~ s#([^:])\/\/#$1\/#g;

    return $apacheUrl;
}

sub parseIPString {
    my $ipString = shift;

    ## From Apache doc: http://httpd.apache.org/docs/current/mod/mod_authz_core.html
    ## Require ip syntax:
    ## Require ip 10 172.20 192.168.2
    my @ips = split /,/, $ipString;
    my $requireIps;
    foreach my $ip ( @ips ){
        ## Strip leading whitespace:
        $ip =~ s/^\s+//;
        ## Strip trailing comma and space
        $ip =~ s/\s*$//;
        ## Strip trailing .:
        $ip =~ s/\.$//;
        $requireIps .= "$ip "; ## Require needs space separated list
    }
    $requireIps =~ s/\s*$//;   ## Ditch the last trailing space

    return $requireIps;
}

sub generateProxyBalancerConfig {
    my ( $product, $role, $confFile ) = @_;

    ## For CWS/Community $product will be 'community'
    my $me = ariba::rc::InstalledProduct->new("$product", $ENV{'ARIBA_SERVICE'});
    my $cws = ariba::rc::InstalledProduct->new("cws", $ENV{'ARIBA_SERVICE'});
    my @appHosts = $me->hostsForRoleInCluster("$role", $me->currentCluster());

    my $auc = ariba::rc::InstalledProduct->new("community", $ENV{'ARIBA_SERVICE'});
    my @solrIndexerAppInstances = $auc->appInstancesLaunchedByRoleInCluster('aucsolrindexer', $me->currentCluster());
    my @solrSearchAppInstances = $auc->appInstancesLaunchedByRoleInCluster('aucsolrsearch', $me->currentCluster());

    open my $OUT, '>', $confFile or croak "Could not open '$confFile' for writing: $!\n";

    ## Data we'll need:
    my $clusterName = "${role}cluster";
    my $drupalPort = $me->default( "ApacheHttpsPort" );
    my $targetPort;
    unless ( $drupalPort ){
        croak "Could not read 'ApachePort' for '$product'\n";
    }

    my $ipString = $cws->default( "TrustedSubnet" );
    my $requireIps = parseIPString( $ipString );

    print $OUT <<EOT;
#This header is required to set proper ROUTEID cookie which would be used for sticky balancing
Header add Set-Cookie "ROUTEID=.%{BALANCER_WORKER_ROUTE}e; path=/" env=BALANCER_ROUTE_CHANGED

## See: http://www.johnandcailin.com/blog/john/scaling-drupal-step-two-sticky-load-balancing-apache-modproxy
## for description of the "balancer-manager" congig
## Don't proxy these (the !)
ProxyPass /balancer-manager !
ProxyPass /httpdstatus !
ProxyPass /wshealth.html !

SSLProxyEngine on
SSLProxyVerify none
SSLProxyCheckPeerCN off
SSLProxyCheckPeerName off
SSLProxyCheckPeerExpire off
EOT

    ##Solr indexer needs higher value for timeouts for processing POST requests during indexing
    my $indexerRequestTimeout=$cws->default( "SolrIndexerRequestTimeout" );
    my $indexerKeepAlive=$cws->default( "SolrIndexerKeepAlive" );
    if ( scalar @solrIndexerAppInstances ){
        ## Solr Indexer
        print $OUT <<EOT;
<Proxy balancer://aucsolrindexer-$clusterName>
## Apache 2.4.9 access control
Require ip $requireIps
EOT
        ## Iterate over hosts in the role
        foreach my $instance ( @solrIndexerAppInstances ){
            ## Print per-host data
            my $ipAddr = ariba::Ops::NetworkUtils::ipForHost( $instance->host() );
            $targetPort = $instance->port();
            print $OUT "    BalancerMember http://$ipAddr:$targetPort/solr retry=1 keepalive=$indexerKeepAlive timeout=$indexerRequestTimeout\n";
        }
        print $OUT <<EOT;
    ProxySet lbmethod=byrequests forcerecovery=On timeout=$indexerRequestTimeout
</Proxy>
ProxyPass /indexer balancer://aucsolrindexer-$clusterName
ProxyPassReverse /indexer balancer://aucsolrindexer-$clusterName

EOT
    }

    my $retrytime=2700; ##45 minutes
    if ( scalar @solrSearchAppInstances ){
        ## Solr Search
        print $OUT <<EOT;
<Proxy balancer://aucsolrsearch-$clusterName>
## Apache 2.4.9 access control
Require ip $requireIps
EOT
        ## Iterate over hosts in the role
        foreach my $instance ( @solrSearchAppInstances ){
            ## Print per-host data
            my $ipAddr = ariba::Ops::NetworkUtils::ipForHost( $instance->host() );
            $targetPort = $instance->port();
            print $OUT "    BalancerMember http://$ipAddr:$targetPort/solr retry=$retrytime\n";
        }
        print $OUT <<EOT;
    ProxySet lbmethod=bybusyness forcerecovery=On failontimeout=On nofailover=off
</Proxy>
ProxyPass /solrsearch balancer://aucsolrsearch-$clusterName
ProxyPassReverse /solrsearch balancer://aucsolrsearch-$clusterName

EOT
    }

    print $OUT <<EOT;
<Proxy balancer://cloudanalytics/>
## Apache 2.4.9 access control
Require all granted
EOT
    my $caServerTokens = $cws->{'defaults'}->{'cloudanalyticsserver'};
    my @caServerInstances = split(' ', $caServerTokens);
    my $routeCount = 1;
    ## Iterate over cloud analytics hosts
    foreach my $caInstance ( @caServerInstances ){
        ## Print per-host
        print $OUT "    BalancerMember $caInstance/BOE retry=$retrytime route=$routeCount\n";
        $routeCount++;
    }
print $OUT <<EOT;
    #Looks for ROUTEID cookie to manage stickysessions
    ProxySet lbmethod=bybusyness forcerecovery=On stickysession=ROUTEID failontimeout=On nofailover=off
</Proxy>

ProxyPass /BOE  balancer://cloudanalytics/
ProxyPassReverse /BOE  balancer://cloudanalytics/


<Proxy balancer://$clusterName/>
## Apache 2.4.9 access control
Require all granted
EOT

    ## Iterate over hosts in the role
    #route numbers start from 1
    $routeCount = 1;
    foreach my $host ( @appHosts ){
        ## Print per-host data
        my $ipAddr = ariba::Ops::NetworkUtils::ipForHost( $host );
        print $OUT "    BalancerMember https://$ipAddr:$drupalPort retry=$retrytime route=$routeCount\n";
        $routeCount++;
    }

    ## Print close/footer
    print $OUT <<EOT;
    #Looks for ROUTEID cookie to manage stickysessions
    ProxySet lbmethod=bybusyness forcerecovery=On stickysession=ROUTEID failontimeout=On nofailover=off
</Proxy>
ProxyPass / balancer://$clusterName/
ProxyPassReverse / balancer://$clusterName/

EOT
    ## Close balancer.conf
    close $OUT or croak "Error closing '$confFile' after writing: $!\n";

}

sub generateProxyBalancerConfigAdmin {
    my ( $product, $role, $confFile ) = @_;
    ## This only gets called with the role 'communityapp' (from bin/startup) so
    ## lets generate the admin app balancer config here as well:
    open my $BAL, '>', "$ENV{'ARIBA_CONFIG_ROOT'}/balancer-admin.conf"
        or die "Error opening balancer-admin for writing: $!\n";

    ## For CWS/Community $product will be 'community'
    my $me = ariba::rc::InstalledProduct->new("$product", $ENV{'ARIBA_SERVICE'});
    my $cws = ariba::rc::InstalledProduct->new("cws", $ENV{'ARIBA_SERVICE'});
    ## Change some details for the admin app:
    my $clusterName = 'communityappadmincluster';
    $role = 'communityappadmin';
    my $targetPort = $me->default( 'ApacheHttpsPort' ) || die "Could not read apache-https-port: $!\n";
    my @appHosts = $me->hostsForRoleInCluster("$role", $me->currentCluster());
    
    my $ipString = $cws->default( "TrustedSubnet" );
    my $requireIps = parseIPString( $ipString );

    print $BAL <<EOT;
## See: http://www.johnandcailin.com/blog/john/scaling-drupal-step-two-sticky-load-balancing-apache-modproxy
## for description of the "balancer-manager" congig
## Don't proxy these (the !)
ProxyPass /balancer-manager !
ProxyPass /httpdstatus !

SSLProxyEngine on
SSLProxyVerify none
SSLProxyCheckPeerCN off
SSLProxyCheckPeerName off
SSLProxyCheckPeerExpire off

<Proxy balancer://$clusterName//>
    ## Apache 2.4.4 access control
    Require ip $requireIps
EOT

    ## Iterate over hosts in the role
    foreach my $host ( @appHosts ){
        ## Print per-host data
        print $BAL "    BalancerMember https://$host:$targetPort retry=0\n";
    }

        ## Print close/footer
    print $BAL <<EOT;
    ProxySet lbmethod=byrequests forcerecovery=On
</Proxy>
ProxyPass / balancer://$clusterName/
ProxyPassReverse / balancer://$clusterName/

EOT
    ## Close balancer.conf
    close $BAL or croak "Error closing '$ENV{'ARIBA_CONFIG_ROOT'}/balancer-admin.conf' after writing: $!\n";
}

## Since this didn't already exist, I'm hijacking the method name.
## In future, we may need to rename this to setDrupalRuntimeEnv ...
sub setRuntimeEnv {
    my $me = shift;
    my $force = shift;

    return if $envSetup && !$force;

    my @ldLibrary = (
        "$main::INSTALLDIR/lib/linux",
    );

    my @pathComponents = (
        "$main::INSTALLDIR/bin",
        "$main::INSTALLDIR/bin/linux",
    );

    ## Drupal is not JAVA based, thus empty CLASSPATH
    my @classes = (
    );

    ariba::Ops::Startup::Common::setupEnvironment(\@ldLibrary, \@pathComponents, \@classes);

    chdir("$main::INSTALLDIR") || die "ERROR: could not chdir to $main::INSTALLDIR, $!\n";

    $envSetup++;
}

1;

__END__
