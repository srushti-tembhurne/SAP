package ariba::monitor::TlsSecurityUtil;

use strict;
use warnings;
use Config::IniFiles;
use Data::Dumper;
use DateTime;
use IO::Zlib;
use Text::CSV_XS;
use File::Path;

use ariba::rc::Globals qw(webServerProducts isServiceValid);
use ariba::rc::InstalledProduct;
use ariba::Ops::Constants;
use ariba::monitor::Utils qw(archive yday_in_ymd csvtoarray);

### Just exporting, so the functions could be used w/o fully qualified names
use Exporter;
our @ISA    = qw(Exporter);
our @EXPORT = qw( is_good_to_go parse_line extract_data);

my $service;       ### Service name
my $base_dir;      ### /subzero/opsdumps/tools/tls-security-$service
my $source_dir;    ### /subzero/opsdumps/tools/tls-security-$service/11/source/
my $csv_dir;       ### /subzero/opsdumps/tools/tls-security-$service/11/csv/
my $target_dir;    ### /subzero/opsdumps/tools/tls-security-$service
my $cw_dir
  ; ### /subzero/opsdumps/tools/tls-security-$service/11  --> One day before last run (current working dir)
my $summary_file
  ; ### /subzero/opsdumps/tools/tls-security-$service/tls-security-$service-summary-$dt.ini --> Temp. file
my $summary_csv
  ; ### /subzero/opsdumps/tools/tls-security-$service/tls-security-$service-summary-$dt.csv
my $source_date;    ### Saves run date

sub fill_in_hash {
    my %protocolUsage;

    # Regular expression describing the current log format
    my (
        $CLIENT_IP,      $PROCESS_ID,       $THREAD_ID,
        $DATE,           $REQUEST_URL,      $STATUS_CODE,
        $RESPONSE_BYTES, $REFERER_URL,      $USER_AGENT,
        $RESPONSE_TIME,  $SSL_PROTOCOL,     $SSL_CIPHER,
        $SSL_KEY_SIZE,   $CANONICAL_SERVER, $HOST
      )
      = /^([0-9.]+) ([0-9]+) ([0-9]+) (\[.+\]) \"((?:[^"]|")+)\" ([0-9-]+) ([0-9-]+) \"((?:[^"]|")*)\" \"((?:[^"]|")+)\" ([0-9]+) ([\w-]+) ([\w-]+) ([0-9-]+) ([\w\-.]+) ([\w\-.]+)/;

    # If the pattern did not match, then the local variable will be undefined
    if ( defined($CLIENT_IP) ) {

# The request requires some additional processing to get the request type, url, and http version
        if ( !defined($REQUEST_URL) ) {
            return;
        }

        my @requestParts = split /\s+/, $REQUEST_URL;

# We need to determine the realm from the Request URL, and if not there, try the Referer URL
        my $realm           = "none";
        my $requestMethod   = $requestParts[0];
        my $requestUrl      = $requestParts[1];
        my $requestProtocol = $requestParts[2];

        if ( $requestUrl =~ /realm=([a-zA-Z1-9\\-_]*)/ ) {
            $realm = $1;
        }
        elsif ( $REFERER_URL =~ /realm=([a-zA-Z1-9\\-_]*)/ ) {
            $realm = $1;
        }

        my $realmKey = $HOST . "\$" . $realm;

        if ( !exists $protocolUsage{$realmKey} ) {
            $protocolUsage{$realmKey} = [ 0, 0, 0, 0, 0 ];
        }

        if ( $SSL_PROTOCOL eq "TLSv1" ) {
            $protocolUsage{$realmKey}[0]++;
        }
        elsif ( $SSL_PROTOCOL eq "TLSv1.1" ) {
            $protocolUsage{$realmKey}[1]++;
        }
        elsif ( $SSL_PROTOCOL eq "TLSv2.0" ) {
            $protocolUsage{$realmKey}[2]++;
        }
        elsif ( ( $SSL_PROTOCOL eq "-" ) || ( $SSL_PROTOCOL eq "" ) ) {
            $protocolUsage{$realmKey}[3]++;
        }
        else {
            $protocolUsage{$realmKey}[4]++;
        }

    }
    else {
        print STDERR "DID NOT MATCH EXPECTED FORMAT:\n$_ \n";
    }
    return %protocolUsage;
}

sub merge_hash {
    my ( $hash_ref_1, $hash_ref_2 ) = @_;
    my %hash1 = %{$hash_ref_1};
    my %hash2 = %{$hash_ref_2};

    foreach my $realmKey ( keys %hash2 ) {
        if ( !exists $hash1{$realmKey} ) {
            $hash1{$realmKey} = $hash2{$realmKey};
        }
        else {
            $hash1{$realmKey}[0] += $hash2{$realmKey}[0];
            $hash1{$realmKey}[1] += $hash2{$realmKey}[1];
            $hash1{$realmKey}[2] += $hash2{$realmKey}[2];
            $hash1{$realmKey}[3] += $hash2{$realmKey}[3];
            $hash1{$realmKey}[4] += $hash2{$realmKey}[4];
        }
    }
    return %hash1;
}

sub service {
    my ($service) = shift;

    $ariba::monitor::TlsSecurityUtil::service = $service if ($service);
    return ($ariba::monitor::TlsSecurityUtil::service);
}

sub base_dir {
    my ($dir) = shift;

    $ariba::monitor::TlsSecurityUtil::base_dir = $dir if ($dir);
    return ($ariba::monitor::TlsSecurityUtil::base_dir);
}

sub source_dir {
    my ($dir) = shift;

    $ariba::monitor::TlsSecurityUtil::source_dir = $dir if ($dir);
    return ($ariba::monitor::TlsSecurityUtil::source_dir);
}

sub target_dir {
    my ($dir) = shift;

    $ariba::monitor::TlsSecurityUtil::target_dir = $dir if ($dir);
    return $ariba::monitor::TlsSecurityUtil::target_dir;
}

sub csv_dir {
    my ($dir) = shift;

    $ariba::monitor::TlsSecurityUtil::csv_dir = $dir if ($dir);
    return $ariba::monitor::TlsSecurityUtil::csv_dir;
}

sub summary_file {
    my $run_dt   = ariba::monitor::TlsSecurityUtil::source_date();
    my $service  = ariba::monitor::TlsSecurityUtil::service();
    my $base_dir = ariba::monitor::TlsSecurityUtil::base_dir();
    my $s_file   = qq($base_dir/tls-security-$service-summary-$run_dt.ini);
    return ($s_file);
}

sub summary_csv {
    my $run_dt   = ariba::monitor::TlsSecurityUtil::source_date();
    my $service  = ariba::monitor::TlsSecurityUtil::service();
    my $base_dir = ariba::monitor::TlsSecurityUtil::base_dir();
    my $s_file   = qq($base_dir/tls-security-$service-summary-$run_dt.csv);
    return ($s_file);
}

sub cw_dir {
    my ($dir) = shift;

    $ariba::monitor::TlsSecurityUtil::cw_dir = $dir if ($dir);
    return $ariba::monitor::TlsSecurityUtil::cw_dir;
}

sub source_date {

    my ($dt) = shift;

    $ariba::monitor::TlsSecurityUtil::source_date = $dt if ($dt);
    return $ariba::monitor::TlsSecurityUtil::source_date;
}

### Validates if the service is valid or not
sub is_service_valid {
    my ($service) = ariba::monitor::TlsSecurityUtil::service();
    return ( ariba::rc::Globals::isServiceValid($service) );
}

### This method looks for patten "TLSv"
### Returns false if it doesn't find
### Returns true if found
sub is_good_to_go {
    my ($line) = shift;
    return 0 unless ($line);

    ( $line =~ m/\bTLSv\d+\b/gi ) ? return 1 : return 0;
}

### Input   : Access log line
### Returns : Array of data
sub parse_line {
    my ($line) = shift;
    $line =~ s/\s+/ /g;
    return () unless ($line);

    my @lines =
      ( $line =~
/^(\S+) (\S+) (\S+) \[(.+)\] \"(.+)\" (\S+) (\S+) \"(.*)\" \"(.*)\" (\S+) (\S+) (\S+) (\S+) (\S+) (\S+)/
      );

    (wantarray) ? return (@lines) : return ( \@lines );
}

### Utility function to return just the needed info
sub extract_data {
    my (@data) = @_;
    return 0 unless ( scalar(@data) );

    my $ip          = $data[0];
    my $url         = $data[4];
    my $status_code = $data[5];
    my $user_agent  = $data[8];
    my $tls         = $data[10];
    my $cipher      = $data[11];
    my $referer     = $data[-1];

    my ( $http_method, $http_url, $http_prot ) = split( /\s/, $url );

    return (
        [
            $tls,        $ip,        $http_method,
            $http_url,   $http_prot, $status_code,
            $user_agent, $cipher,    $referer
        ]
    );
}

### Generates the csv file header
sub get_csv_headers {
    return (
        [
            qw(TLS_VERSION IP HTTP_METHOD HTTP_URL HTTP_PROTOCOL STATUS_CODE USER_AGENT CIPHER REFERER)
        ]
    );
}

sub get_all_input_files {
    my ($source_dir) = ariba::monitor::TlsSecurityUtil::source_dir();
    return ( ariba::monitor::Utils::get_directory_files($source_dir) );
}

sub process_access_log {
    my ( $source_file, $target_file, $verbose ) = @_;
    return unless ( $source_file && $target_file );

    $source_file =
      ariba::monitor::TlsSecurityUtil::source_dir() . "$source_file";
    $target_file = ariba::monitor::TlsSecurityUtil::csv_dir() . "$target_file";

    my ( $ws, $spath, $ignore ) = split( /_/, $source_file );
    my (@arr) = split( /\//, $ws );
    $ws = $arr[-1];

    ### Open gz file
    tie *FILE, 'IO::Zlib', $source_file, "rb";

    open( my $csv_fh, ">:encoding(utf8)", $target_file )
      || die "Unable to open $target_file to write: $! \n";
    my $csv = Text::CSV_XS->new( { eol => "$/" } );
    $csv->print( $csv_fh, get_csv_headers() );

    my %hash;
    my $summary = {};

    while (<FILE>) {
        my $line = $_;
        chomp($line);

        #print "line : $line \n" if ($verbose);

        if ( ariba::monitor::TlsSecurityUtil::is_good_to_go($line) ) {
            my %hash_table = fill_in_hash($line);
            my %hashtemp = merge_hash( \%hash, \%hash_table );
            %hash = %hashtemp;

            my (@line_contents) = parse_line($line);
            my $data            = extract_data(@line_contents);
            my $tls_version     = $data->[0];
            $summary->{"$ws-$spath"}->{$tls_version}++;

            $csv->print( $csv_fh, $data );
        }
    }

    ariba::monitor::TlsSecurityUtil::update_summary($summary);
    close($csv_fh);
    return %hash;
}

sub update_summary {
    my ($data) = shift;
    return unless ( scalar( keys( %{$data} ) ) );

    ### Open file in append mode
    my $summary_file = ariba::monitor::TlsSecurityUtil::summary_file();
    open( my $fh, '>>', $summary_file ) || die "Can't open $summary_file : $!";

    foreach my $ws ( sort keys %{$data} ) {
        print $fh "\n[$ws] \n";
        foreach my $version ( sort keys %{ $data->{$ws} } ) {
            print $fh "$version = " . $data->{$ws}->{$version} . "\n";
        }
    }

    close($fh);
}

# get_access_log_dirs - get array of log dirs for the webserver, a legacy webserver will have an array of one element
#     The default settings are from DeploymentDefaults.[cfg/xml] and tokenmap.cfg
#     The tokenmap tokens of interest are for WS svc-front-door1-www for DD.cfg entry ServiceFrontDoor1 and
#         for SSWS ServiceAltHostName (prior) and WebServerAltHosts (newer) are used and use the tokens svc-front-door-www and
#         webserver-alt-hosts respectively.
#
sub get_access_log_dirs {
    my ( $product, $dirs_array_ref ) = @_;

    my @dirs = ();

    # get primary front door
    my $service_host = $product->default('servicehost') || '';
    $dirs_array_ref->[0] = $service_host;

    # return if not multiple front doors
    return unless is_advanced_webserver($product);

    # get possible secondary front doors
    my $alt_host_name  = $product->default('servicealthostname');
    my $alt_hosts_list = $product->default('webserveralthosts');
    my $front_door1    = $product->default('servicehostfrontdoor1');

    # check for ServiceAltHostName
    if ( defined($alt_hosts_list) && $alt_hosts_list ) {

        # get alternate front doors
        @{$dirs_array_ref} = ariba::monitor::Utils::csvtoarray($alt_hosts_list);

        # prepend primary front door
        unshift @{$dirs_array_ref}, $service_host;
    }
    elsif ( defined($alt_host_name) && $alt_host_name ) {

        # using older deprecated ServiceAltHostName
        $dirs_array_ref->[0] = $product->default('servicehostname') . '.'
          . $product->default('servicehostdomain');
        $dirs_array_ref->[1] = $product->default('servicealthostname') . '.'
          . $product->default('servicealthostdomain');

        # for advanced expect at least 2 front doors
        my $door3_host   = $product->default('servicealt2hostname')   || '';
        my $door3_domain = $product->default('servicealt2hostdomain') || '';
        if ( $door3_host && $door3_domain ) {
            $dirs_array_ref->[2] = $door3_host . '.' . $door3_domain;
        }
    }
    elsif ( defined($front_door1) && $front_door1 ) {

        # newer tokens for WS
        $dirs_array_ref->[0] = $front_door1                               || '';
        $dirs_array_ref->[1] = $product->default('servicehostfrontdoor2') || '';
        $dirs_array_ref->[2] = $product->default('servicehostfrontdoor3') || '';
    }
}

### Return all webserver products information like
### access log hosts and their location etc
sub get_webserver_products_info {
    my ($service) = ariba::monitor::TlsSecurityUtil::service();
    return unless ($service);

    my $ws_products_info = {};

    ### Get the list of webserver products
    my @ws_products = ariba::rc::Globals::webServerProducts();

    foreach my $product (@ws_products) {
        ### If the product is installed, proceed further
        if ( ariba::rc::InstalledProduct->isInstalled( $product, $service ) ) {
            my $product =
              ariba::rc::InstalledProduct->new( $product, $service );
            my $pname = $product->name();    ### Get product name
            my @ws_roles = $product->rolesMatchingFilter("webserver")
              ;    ### Get all webserver roles of that product

            return unless ( scalar(@ws_roles) );

            # get paths for the webserver
            foreach my $ws_role (@ws_roles) {
                my @access_log_dirs = ();
                get_access_log_dirs( $product, \@access_log_dirs );
                my $port = ariba::Ops::Constants->logViewerPort()
                  ;    ### Port # for log viewer
                my @ws_hosts =
                  $product->hostsForRoleInCluster( $ws_role, 'primary' )
                  ;    ### Get all the webserver host names

                ### Store info data structure
                $ws_products_info->{$pname}->{$ws_role}->{access_log_paths} =
                  \@access_log_dirs;
                $ws_products_info->{$pname}->{$ws_role}->{port} = $port;
                $ws_products_info->{$pname}->{$ws_role}->{ws_hosts} =
                  \@ws_hosts;
            }
        }
    }

    return ($ws_products_info);
}

#### This method generates list of source webserver access log files
#### that needs to downloaded for a given service

sub generate_download_info {
    my ($service) = ariba::monitor::TlsSecurityUtil::service();
    return unless ($service);

    my $ws_products_info =
      ariba::monitor::TlsSecurityUtil::get_webserver_products_info($service);
    return unless ( scalar( keys %{$ws_products_info} ) );

    ### Download yesterday's log for processing
    my $yday = ariba::monitor::Utils::yday_in_ymd('.');

    my %generated_info = ();

    foreach my $product_name ( keys %{$ws_products_info} ) {
        my $wsrole_info = $ws_products_info->{$product_name};
        foreach my $role ( keys %{$wsrole_info} ) {
            my $port     = $wsrole_info->{$role}->{port};
            my $paths    = $wsrole_info->{$role}->{access_log_paths};
            my $ws_hosts = $wsrole_info->{$role}->{ws_hosts};

            ### Build the list of hosts from which the file needs to be downloaded
            foreach my $host ( @{$ws_hosts} ) {
                foreach my $path ( @{$paths} ) {
                    if ( defined($path) && $path && $path !~ /dummy/i ) {
                        my $source_url =
                          qq(http://$host:$port/cat/$path/access.$yday.gz);
                        my $target_file =
                          qq($host:$port\_$path\_access.$yday.csv);
                        my $source_file =
                          qq($host:$port\_$path\_access.$yday.gz);

                        $generated_info{$source_file} =
                          [ $source_url, $source_file, $target_file ];
                    }
                }
            }
        }
    }

    return (%generated_info);
}

### Checks if webserver instance is an advanced (multiple front ends)  webserver
sub is_advanced_webserver {
    my ($product) = @_;

    my $is_advanced = 0;

    # check for advanced tokens
    my $token_val =
         $product->default('servicehostfrontdoor1')
      || $product->default('servicealthostname')
      || $product->default('webserveralthosts');

    # check if token exists and is not a dummy value
    if ( defined($token_val) && $token_val && $token_val !~ /dummy/i ) {
        $is_advanced = 1;
    }

    return $is_advanced;
}

sub mk_dirs {
    my ($root_dir) = shift;
    return 0 unless ($root_dir);    ### /subzero/opsdumps/ or /nfs/never/monprod

    my $service = ariba::monitor::TlsSecurityUtil::service();
    return 0 unless ($service);

    ### Source and target directory creations
    my $dt = DateTime->today( time_zone => 'local' );
    $dt->subtract( hours => 24 );
    my $year   = $dt->year();
    my $mon    = sprintf( "%02d", $dt->month() );
    my $yday   = sprintf( "%02d", $dt->day() );
    my $run_dt = ariba::monitor::Utils::yday_in_ymd();

    my $base_dir = qq($root_dir/tls-security-$service)
      ;    ### base_dir   : $root_dir/tls-security-$service
    my $source_dir =
      qq($base_dir/$yday/source/);    ### source_dir : $base_dir/$yday/source/
    my $target_dir = qq($base_dir/)
      ;   ### target_dir : $base_dir i.e /subzero/opsdumps/tls-security-$service
    my $csv_dir =
      qq($base_dir/$yday/csv/);    ### csv_dir    : $base_dir/$yday/csv/
    my $cw_dir = qq($base_dir/$yday/);    ### cw_dir     : $base_dir/$yday/

    ### Set it for global access
    ariba::monitor::TlsSecurityUtil::base_dir($base_dir);
    ariba::monitor::TlsSecurityUtil::source_dir($source_dir);
    ariba::monitor::TlsSecurityUtil::target_dir($target_dir);
    ariba::monitor::TlsSecurityUtil::csv_dir($csv_dir);
    ariba::monitor::TlsSecurityUtil::source_date($run_dt);
    ariba::monitor::TlsSecurityUtil::cw_dir($cw_dir);

    my $stale_summary_file = ariba::monitor::TlsSecurityUtil::summary_file();
    my $stale_summary_csv  = ariba::monitor::TlsSecurityUtil::summary_csv();

    ### Remove directories & create (sort of cleanup of old run)
    ariba::monitor::Utils::remove_tree(
        ariba::monitor::TlsSecurityUtil::cw_dir() );
    unlink($stale_summary_file);
    unlink($stale_summary_csv);

    ariba::monitor::Utils::make_path($source_dir);
    ariba::monitor::Utils::make_path($csv_dir);

    return 1;
}

### Removes current working directory
sub rm_cw_dir {
    ariba::monitor::Utils::remove_tree(
        ariba::monitor::TlsSecurityUtil::cw_dir() );
}

##################################################################################
### This method takes summary ini file and transfer it contens to csv file
### Sample summary ini file:
###     [web43.lab1.ariba.com:61502-svclq25mobile.lab1.ariba.com]
###     TLSv1 = 288
###
###     [web43.lab1.ariba.com:61502-svclq25ss.lab1.ariba.com]
###     TLSv1 = 40449
###
### Sample summary csv file:
###     Host - Product Name,TLSv1
###     web43.lab1.ariba.com:61502-svclq25mobile.lab1.ariba.com,288
###     web43.lab1.ariba.com:61502-svclq25ss.lab1.ariba.com,40449
#################################################################################
sub transform_summary_ini_to_csv {
    my $summary_ini    = ariba::monitor::TlsSecurityUtil::summary_file();
    my $summary_csv    = ariba::monitor::TlsSecurityUtil::summary_csv();
    my (%summary_hash) = %{ $_[0] };

    tie my %summary_ini, 'Config::IniFiles', ( -file => $summary_ini );

    my @tls_versions;
    foreach my $key ( sort keys(%summary_ini) ) {
        push( @tls_versions, keys( %{ $summary_ini{$key} } ) );
    }

    ### Remove duplicate version #s
    my %uniq_tls_versions = map { $_ => 1 } @tls_versions;
    my @uniq_tls_versions = sort keys(%uniq_tls_versions);

    ### Header for summary csv file
    my $header = join( ",",
        "HOST", "REALM", "TLSv1", "TLSv1.1", "TLSv1.2", "NONE", "OTHER" );
    $header .= "\n";

    my @csv_data = qq($header);
    foreach my $realmKey ( sort keys %summary_hash ) {
        my @realmParts = split /\$/, $realmKey;
        my $row =
            $realmParts[0] . ','
          . $realmParts[1] . ','
          . $summary_hash{$realmKey}[0] . ','
          . $summary_hash{$realmKey}[1] . ','
          . $summary_hash{$realmKey}[2] . ','
          . $summary_hash{$realmKey}[3] . ','
          . $summary_hash{$realmKey}[4];

        $row .= "\n";
        push( @csv_data, $row );
    }

    ### Create summary_csv file
    open( my $csv_fh, ">:encoding(utf8)", $summary_csv )
      || die "Unable to open $summary_csv to write: $! \n";
    print $csv_fh @csv_data;
    close($csv_fh);

    ### Remove summary_ini file
    unlink($summary_ini);
}

1;

