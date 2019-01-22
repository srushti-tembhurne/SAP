package ariba::monitor::Utils;

use strict;
use warnings;
use Data::Dumper;

use Archive::Tar;
use File::Path;
use ariba::rc::Utils;
use ariba::rc::InstalledProduct;

# compensate for older Tar code where COMPRESS_GZIP is not defined
# use constant COMPRESS_GZIP => 9;

sub archive
{
    my ( $source_dir, $target_dir, $pattern, $tar_name ) = @_;

    return unless ( $source_dir && $target_dir && $pattern && $tar_name );

    $source_dir =~ s/\/$//g;         ### Remvoe leading /
    $target_dir =~ s/\/$//g;         ### Remove leading /

    ### Create a new tar object:
    my $tar = Archive::Tar->new();

    ### source_dir : /subzero/opsdumps/2016/02/tls-security-lq25/18/target_csv
    ### tartget_dir: /subzero/opsdumps/2016/02/tls-security-lq25/18/target
    ### Pattern    : *.csv

    $tar->add_files( <"$source_dir/$pattern"> );

    # Finished:
    $tar->write ("$target_dir/$tar_name.tgz", 9);
}

### Returns 2016.02.12
### Returns 2016-02-12
sub yday_in_ymd
{
    my ( $delimiter ) = shift;

    $delimiter = "-" unless ( $delimiter );

    my $dt = DateTime->today( time_zone => 'local' );
    $dt->subtract( hours => 24 );

    return ( $dt->ymd($delimiter) );
}

### Gets list of files in the directory
sub get_directory_files
{
    my ( $dir ) = shift;
    return () unless ( $dir );

    opendir(DIR, $dir ) || die "Can't opendir $dir : $! \n";
    my @files =  grep {  -f "$dir/$_" } readdir(DIR);
    closedir DIR;

    ( wantarray ) ? return (@files) : return (\@files);
}

sub make_path
{
    my ( $dir ) = shift;
    return 0 unless ( $dir );

    File::Path::make_path( $dir );
}

### Remove directory and its underlying directories/files etc
### Full tree gets removed
sub remove_tree
{
    my ( $dir ) = shift;
    return 0 unless ( $dir );

    File::Path::remove_tree( $dir );
}

sub csvtoarray {
    my $csv = shift || "";
    my @array = split(/,/, $csv);
    return @array;
}

# check if dns record exists for hostname
sub dns_exists {
    my ($hostname) = @_;

    if ( $hostname ) {
        my @output = ();
        my $command = "/usr/bin/nslookup $hostname";
        ariba::rc::Utils::executeLocalCommand($command, undef, \@output, undef, 1);
        # check for successful lookup
        my @results = grep /^Address: \d+\.\d+\.\d+\.\d+$/, @output;
        if ( @results ) {
            return 1;
        }
        else {
            return 0;
        }
   }
   else {
       return 0;
   }
}

# return integration host name for product and service
sub integration_host {
    my($product_name, $service_name, $is_legacy) = @_;

    my $int_host = '';

    my $product = ariba::rc::InstalledProduct->new($product_name, $service_name);

    my $alt_hosts = $product->default('WebServerAltHosts') || '';
    my $ws_adv_host = $product->default('svc-front-door2-www') || '';

    # check for advanced
    if ( !$is_legacy ) {
        if ( $alt_hosts ) {
            my @alt_hosts = ariba::monitor::Utils::csvtoarray($alt_hosts);

            if ( @alt_hosts ) {
                # get the advanced host
                my @hosts = grep /-2/, @alt_hosts;

                $int_host = $hosts[0];
                if ($int_host) {
                    if ($is_legacy) {
                        $int_host =~ s/\-2/\-integration-legacy/g;
                    }
                    else {
                        $int_host =~ s/\-2/\-integration/g;
                    }
                }
            }
        }
        elsif ( $ws_adv_host ) {
            $int_host = $ws_adv_host;
            $int_host =~ s/\-2/\-integration/g;
        }
    }
    else {
        my $service_host = $product->default('ServiceHost') || '';

        if ($service_host) {
            # break up host into host part and domain part
            $service_host =~ /^(.*?)(\-eu|\-ru|\.lab1)?\.ariba\.com$/;
            my $host_part = $1;
            my $domain_part = '.ariba.com';
            if ( defined($2) && $2 ) {
                $domain_part = $2 . $domain_part;
            }
            # check if devlab host
            if ( $host_part =~ /svc/ ) {
                # add .lab1 if missing from domain
                # -integration dns names should include .lab1
                if ( $domain_part !~ /\.lab1/ ) {
                    $domain_part = '.lab1' . $domain_part;
                }
            }
            # add the integration
            if ($is_legacy) {
                $domain_part = '-integration-legacy' . $domain_part;
            }
            else {
                $domain_part = '-integration' . $domain_part;
            }

            $int_host = $host_part . $domain_part;
        }
    }

    return $int_host;
}

# This method will be used initially for AUC Learning Center monitoring.  It needs to be called with an offset in
# seconds (or 'duration') and the basic direct action URL with placeholders, and will return the URL, modified with
# a correct start time and duration, based on the offset passed as an argument.  The areas to be modified are
# "tagged" with the variable name to be interpolated into the string, which means the input must be single quoted
# and the string substituted here to make it work.
sub makeDirectActionURL
{
    my $duration = shift;
    my $daURL = shift;

    # Get the current time and subtract 3600 seconds from it to get the start time for the current cycle.
    my $startTime = time () - $duration;

    # Originally, I tried to use eval to substitute the values in place, but couldn't get it to work.  So
    # using patterns and substitution...
    $daURL =~ s/\$duration/$duration/;
    $daURL =~ s/\$startTime/$startTime/;

    return $daURL;
}

1;
