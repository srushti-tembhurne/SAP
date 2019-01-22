package ariba::rc::dashboard::Client;

#
# Perl wrapper around RC Dashboard HTTP API
#

use strict;
use warnings;
use vars qw ($AUTOLOAD);
use Carp;
use Data::Dumper;
use LWP::UserAgent;
use Sys::Hostname;
use Time::HiRes;
use JSON;
use POSIX qw(strftime);
use ariba::rc::dashboard::Constants;
use ariba::Ops::ServiceController;

#
# Constructor
#
sub new {
    my ( $class ) = @_;

    my $self = {
        'verbose'      => 0,
        '_max_retries' => 3,
        '_naptime'     => 1,
        '_last_error'  => "",
        '_server'      => ariba::rc::dashboard::Constants::server_url(),
        '_timeout'     => ariba::rc::dashboard::Constants::http_timeout(),
        '_useragent'   => "ariba::rc::dashboard::Client/" . ariba::rc::dashboard::Constants::version(),
    };
    bless $self, ref ( $class ) || $class;
    return $self;
}

sub getPresentDate {
    return strftime "%Y-%m-%d", localtime;
}

sub getPresentTime {
    return strftime "%H:%M:%S", localtime;
}

# Public methods
sub running {
    my ( $self, $buildname, $milestone, $logfile, $productname, $branchname, $releasename, $service ) = @_;
    my $time = time ();

    my $hashref = {
        'buildname'  => $buildname,
        'step'       => $milestone,
        'start_time' => $time,
        'end_time'   => 0,
        'status'     => ariba::rc::dashboard::Constants::running(),
        'hostname'   => hostname,
        'logfile'    => $logfile,
        'product'    => $productname,
        'branch'     => $branchname,
        'release'    => $releasename,
        'service'    => $service,
        'quality'    => "",
    };

    $self->publish( $buildname, $milestone, $time, 0, ariba::rc::dashboard::Constants::running(), $logfile, hostname, $productname, $branchname, $releasename, $service, getPresentDate(), 0, getPresentTime(), 0 );
    $self->publish_to_hana( "insert", $hashref );
}

sub success {
    my ( $self, $buildname, $milestone, $logfile, $productname, $branchname, $releasename, $service ) = @_;
    my $time = time ();

    my $hashref = {
        'buildname'  => $buildname,
        'step'       => $milestone,
        'start_time' => 0,
        'end_time'   => $time,
        'status'     => ariba::rc::dashboard::Constants::success(),
        'hostname'   => hostname,
        'logfile'    => $logfile,
        'product'    => $productname,
        'branch'     => $branchname,
        'release'    => $releasename,
        'service'    => $service,
        'quality'    => "",
    };

    $self->publish( $buildname, $milestone, 0, $time, ariba::rc::dashboard::Constants::success(), $logfile, hostname, $productname, $branchname, $releasename, $service, 0, getPresentDate(), 0, getPresentTime() );
    $self->publish_to_hana( "update", $hashref );
}

sub fail {
    my ( $self, $buildname, $milestone, $logfile, $productname, $branchname, $releasename, $service ) = @_;
    my $time = time ();

    my $hashref = {
        'buildname'  => $buildname,
        'step'       => $milestone,
        'start_time' => 0,
        'end_time'   => $time,
        'status'     => ariba::rc::dashboard::Constants::fail(),
        'hostname'   => hostname,
        'logfile'    => $logfile,
        'product'    => $productname,
        'branch'     => $branchname,
        'release'    => $releasename,
        'service'    => $service,
        'quality'    => "",
    };

    $self->publish( $buildname, $milestone, 0, $time, ariba::rc::dashboard::Constants::fail(), $logfile, hostname, $productname, $branchname, $releasename, $service, 0, getPresentDate(), 0, getPresentTime() );
    $self->publish_to_hana( "update", $hashref );
}

sub resume {
    my ( $self, $buildname, $milestone, $logfile, $productname, $branchname, $releasename, $service ) = @_;
    my $time = time ();

    my $hashref = {
        'buildname'  => $buildname,
        'step'       => $milestone,
        'start_time' => 0,
        'end_time'   => $time,
        'status'     => ariba::rc::dashboard::Constants::resume(),
        'hostname'   => hostname,
        'logfile'    => $logfile,
        'product'    => $productname,
        'branch'     => $branchname,
        'release'    => $releasename,
        'service'    => $service,
        'quality'    => "",
    };

    $self->publish_to_hana( "update", $hashref );
}

sub publishQualData {
    my ( $self, $rhData ) = @_;

    $rhData->{ 'hostname' } = hostname;
    $self->publish_to_hana( 'qualdata', $rhData );

}

sub postQuality {
    my ( $self, $buildname, $milestone, $service, $quality ) = @_;

    my $hashref = {
        'buildname' => $buildname,
        'step'      => $milestone,
        'service'   => $service,
        'quality'   => $quality,
    };

    $self->publish_to_hana( 'quality', $hashref );

}

sub removeUndef {
    my $rhData = shift;
    
    foreach my $key (keys %$rhData ) {
        if (! defined $rhData->{$key} ) {
            $rhData->{$key} = '';
        }
    }
    
    return $rhData;
}

sub publish_to_hana {
    my ( $self, $action, $rhData ) = @_;
    
    # Do not publish if this is prod or lab
    if ( $rhData->{'service'} && ariba::Ops::ServiceController::checkFunctionForService( $rhData->{'service'} , 'publish' ) ) {
        print "Not publishing data for Prod service. Retuning... \n" if $self->verbose();
        return 1;
    }

    $rhData = removeUndef($rhData);
    my $json = JSON::encode_json( $rhData );

    print Dumper $json if $self->verbose();

    my $ua = LWP::UserAgent->new();
    $ua->timeout( $self->_timeout() );
    $ua->agent( $self->_useragent() );

    my $serverURL = ariba::rc::dashboard::Constants::hana_url() . "?action=$action";
    print $serverURL . "\n" if $self->verbose();
    # send via HTTP POST

    my $done  = 0;
    my $tries = 0;
    my ( $response, $lines );
    my $naptime = $self->_naptime();

    while ( !$done ) {
        print "Try #$tries...\n" if $self->verbose();
        eval { $response = $ua->post( $serverURL, 'Content-Type' => 'application/json;charset=utf-8', 'Content' => $json ); };

        my $reply = $response->content;
        my @lines = split /\n/, $reply;

        # give up if we've exceeded number of retries
        if ( ++$tries >= $self->_max_retries() ) {
            print "Giving up after $tries tries\n" if $self->verbose();
            $done = 1;
        }
        print "Attempt #$tries \n" if $self->verbose();

        if ( $@ ) {
            $self->handle_error( "Unexpected error: " . $@, $response );
            return 0 if $done;
        }

        # complain if web server gives HTTP 200 but otherwise no response
        if ( $#lines == -1 ) {
            $self->handle_error( "Empty response", $response );
            return 0 if $done;
        } elsif (
            grep {
                /ReferenceError/
            } @lines
          )
        {
            $self->handle_error( "Hana thorwed some Exception", $response );
            return 0 if $done;
        } elsif ( !$response->is_success ) {    # complain if transaction failed
            $self->handle_error( "HTTP POST error", $response );
            return 0 if $done;
        } else {                                # went better than expected
            my $content = $response->content;
            chomp $content;

            if ( $content eq "0" ) {
                print "FAIL\n" if $self->verbose();
            } else {
                print "Success\n" if $self->verbose();
            }
            $done = 1;
        }

        # debugging
        if ( $self->verbose() ) {
            print "Server Response: [" . $self->pretty_print( $response->content() ) . "]\n";
        }

        if ( !$done ) {
            # sleep between attempts
            print "Napping for $naptime seconds\n" if $self->verbose();
            Time::HiRes::sleep( $naptime );
            $naptime += $naptime;
        } else {
            print "All done\n" if $self->verbose();
        }
    }

    return 1;
}

# Send to RC Dashboard server
sub _publish {
    my ( $self, $buildname, $milestone, $start_date, $end_date, $status, $logfile, $hostname, $productname, $branchname, $releasename, $service, $startDate, $endDate, $startTime, $endTime ) = @_;

    $hostname = $hostname || hostname;
    $logfile  = $logfile  || "";

    my $ua = LWP::UserAgent->new();
    $ua->timeout( $self->_timeout() );
    $ua->agent( $self->_useragent() );

    my $hashref = {
        'action'      => "update",
        'buildname'   => $buildname,
        'milestone'   => $milestone,
        'start_date'  => $start_date,
        'end_date'    => $end_date,
        'status'      => $status,
        'hostname'    => $hostname,
        'logfile'     => $logfile,
        'productname' => $productname,
        'branchname'  => $branchname,
        'releasename' => $releasename,
        'servicename' => $service,
        'startDate'   => $startDate,
        'endDate'     => $endDate,
        'startTime'   => $startTime,
        'endTime'     => $endTime,
    };

    print $self->_server() . "\n" if $self->verbose();
    # send via HTTP POST
    my $response = $ua->post( $self->_server(), $hashref );

    # break server response into lines
    my $reply = $response->content;
    my @lines = split /\n/, $reply;

    return ( $response, \@lines );
}

sub publish {
    my ( $self, $buildname, $milestone, $start_date, $end_date, $status, $logfile, $hostname, $productname, $branchname, $releasename, $service, $startDate, $endDate, $startTime, $endTime ) = @_;

    # Do not publish if this is prod or lab
    if ( $service && ariba::Ops::ServiceController::checkFunctionForService( $service, 'publish' ) ) {
        return 1;
    }

    my $done  = 0;
    my $tries = 0;
    my ( $response, $lines );
    my $naptime = $self->_naptime();

    print "Publishing...\n" if $self->verbose();
    while ( !$done ) {
        $start_date = $start_date || time ();

        print "Try #$tries...\n" if $self->verbose();
        eval { ( $response, $lines ) = $self->_publish( $buildname, $milestone, $start_date, $end_date, $status, $logfile, $hostname, $productname, $branchname, $releasename, $service, $startDate, $endDate, $startTime, $endTime ); };

        # give up if we've exceeded number of retries
        if ( ++$tries >= $self->_max_retries() ) {
            print "Giving up after $tries tries\n" if $self->verbose();
            $done = 1;
        }
        print "Attempt #$tries took " . ( Time::HiRes::time() - $start_date ) . "s\n" if $self->verbose();

        if ( $@ ) {
            $self->handle_error( "Unexpected error: " . $@, $response );
            return 0 if $done;
        }

        # complain if web server gives HTTP 200 but otherwise no response
        if ( $#$lines == -1 ) {
            $self->handle_error( "Empty response", $response );
            return 0 if $done;
        }

        # complain if transaction failed
        elsif ( !$response->is_success ) {
            $self->handle_error( "HTTP POST error", $response );
            return 0 if $done;
        }

        # went better than expected
        else {
            my $content = $response->content;
            chomp $content;

            if ( $content eq "0" ) {
                print "FAIL\n" if $self->verbose();
            } else {
                print "Success\n" if $self->verbose();
            }
            $done = 1;
        }

        # debugging
        if ( $self->verbose() ) {
            print "Server Response: [" . $self->pretty_print( $response->content() ) . "]\n";
        }

        if ( !$done ) {
            # sleep between attempts
            print "Napping for $naptime seconds\n" if $self->verbose();
            Time::HiRes::sleep( $naptime );
            $naptime += $naptime;
        } else {
            print "All done\n" if $self->verbose();
        }
    }

    return 1;
}

sub pretty_print {
    my ( $self, $content ) = @_;
    chomp $content;
    return $content;
}

# Share recent error message
sub get_last_error {
    my ( $self ) = @_;
    return $self->_last_error();
}

# Pretty-print HTTP error if verbose flag enabled
sub handle_error {
    my ( $self, $failure, $response ) = @_;

    # Store information about last error encountered
    my $error = join "\n",
      "Error delivering data: [$failure]",
      "  URL: [" . $self->_server() . "]",
      "  Content: [" . $self->pretty_print( $response->content ) . "]",
      "  Status line: [" . $self->pretty_print( $response->status_line ) . "]",
      "  Request: [" . $response->request->as_string . "]";

    $self->_last_error( $error );

    #
    # Don't carp unless verbose flag is enabled
    #
    carp $error if $self->verbose();
}

#
# Accessors
#
sub AUTOLOAD {
    no strict "refs";
    my ( $self, $newval ) = @_;

    my @classes = split /::/, $AUTOLOAD;
    my $accessor = $classes[ $#classes ];

    if ( exists $self->{ $accessor } ) {
        if ( defined ( $newval ) ) {
            $self->{ $accessor } = $newval;
        }
        return $self->{ $accessor };
    }
    carp "Unknown method: $accessor\n";
}

#
# Destructor
#
sub DESTROY {
    my ( $self ) = @_;
}

1;
