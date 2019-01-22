package ariba::monitor::ANLogReport;

use 5.006;
use strict;
use warnings;
use Carp;
use Data::Dumper;
use Template;

=head1 NAME

ariba::monitor::ANLogReport - Parses AN KeepRunning logs and generates HTML report

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

    use ariba::monitor::ANLogReport;
    
    my $params = {
        logdir => "/home/monprod/krlogs/an/20120628",
        apps => [ qw/Authenticator Register ProfileManagement Supplier Buyer Discovery/ ],
        loglevels => [ qw/error/ ],
        error_patterns  => [
            'java.lang.IllegalStateException: Attempt to pop past initial state of Security Context.',
            'ariba.util.core.FatalAssertionException: Mismatch in tokens.',
            'IOException caught javax.imageio.IIOException',
        ],
    };
    
    my $htmldir = '/home/monprod/logreports/an/2012-06-28"; # location on the filesystem
    my $docroot = '/logreport';                             # URL from /
    my $template_dir = "/home/monprod/etc";

    eval {
        my $obj = ariba::monitor::ANLogReport->new( $params );
        $obj->gen_html( $htmldir, $docroot, $template_dir );
    };
    
    if ( $@ ) {
        # something went wrong
    }

=head1 SUBROUTINES/METHODS

=head2 new

    Description: The constructor.  Takes params, parses logs, puts in data structure then return it.
    Arguments: Takes hashref of logdir, apps, loglevels and error_patterns.  See usage for each pattern in synopsis.
    Returns: blessed object, or croaks on error.

=cut

sub new {
    my ( $class, $params ) = @_;

    my $logdir = $params->{ logdir };
    my $apps = $params->{ apps };
    my $loglevels = $params->{ loglevels };
    my $error_patterns = $params->{ error_patterns };
    my $debug = $params->{ debug } || 0;
    my $zcat = '/bin/zcat';
    
    croak "initialization failed" unless ( $logdir && -d $logdir && -x $zcat && $loglevels && $error_patterns );
    
    my $self = {};
    $self->{ logdir } = $logdir;
    $self->{ apps } = $apps;
    $self->{ loglevels } = $loglevels;
    $self->{ error_patterns } = $error_patterns;
    $self->{ debug } = $debug;
    $self->{ zcat } = $zcat;
    $self->{ prefix } = 'keepRunning';
    $self->{ date_pattern } = qr/\w{3} \w{3} \d{1,2} \d{2}:\d{2}:\d{2} \w{3} \d{4}/;
    $self->{ facility_loglevel } = qr/\s\((\w+):(\w+)\):?\s/;
    $self->{ message_pattern } = qr/(Message: \[.*?\])/;
    bless $self, $class;
    
    $self->{ logs } = $self->_pick_logs();
    
    for my $log ( @{ $self->{ logs } } ) {
        # 'app' => 'ProfileManagement',
        # 'pid' => '9546',
        # 'file' => '/homes/syagi/Data/repo/root/ariba_modules/ariba-monitor-ANLogReport/t/tlib/krlogs/keepRunning-ProfileManagement-1352266@app347.snv-9546.1-EXIT.gz',
        # 'instance' => '1352266',
        # 'host' => 'app347.snv'
        
        my $app = $log->{ app };
        my $pid = $log->{ pid };
        my $file = $log->{ file };
        my $instance = $log->{ instance };
        my $host = $log->{ host };
        my $ret = $self->_process_log( $file, $app, $instance, $host, $pid );
    }
    
    $self->_compute_count();

    return $self;
}

=head2 _pick_logs

	Description: Pick appropriate logs to parse.  That is, skipping non-KR or non-gzip logs, etc.
	Arguments: None.  The object has the list of apps, if applicable
	Returns: Arrayref of data structure such that: $ref->[ { app => "app", instance => "instance", host => "host", pid => "pid", file => "full_path" } ];

=cut

sub _pick_logs {
    my $self = shift;
    
    my $dir = $self->{ logdir };
    my $apps = $self->{ apps };
    my $prefix = $self->{ prefix };
    my @logs;

    my @apps = @{ $apps } if ( $apps && ref( $apps ) eq "ARRAY" ); # optional argument

    opendir( my $dh, $dir ) or croak "could not open the directory: $!";
    for my $file ( readdir( $dh ) ) {
        next unless ( $file =~ /^$prefix/ );
        
        # keepRunning-ProfileManagement-1202231@app344.snv-15393.1.gz
        # keepRunning-ProfileManagement-1202231@app344.snv-30444.1.gz
        # keepRunning-ProfileManagement-1202231@app344.snv-30444.2-EXIT.gz
        
        my ( $appname, $instance, $host, $pid ) = $file =~ /^$prefix-([^-]+)-(\d+)\@([^-]+)-(\d+)\./;
        next unless ( $appname && $instance && $host && $pid );
        next if ( @apps && !grep( /^$appname$/, @apps ) );

        my $full_path = "$dir/$file";
        print "_pick_logs $full_path\n" if $self->{ debug };
        my $ref = { app => $appname, instance => $instance, host => $host, pid => $pid, file => $full_path };
        push @logs, $ref;
    }
    closedir $dh or croak "failed to close dirhandle: $!";
    
    return \@logs;
}

=head2 _process_log

	Description: Takes one logfile, app, instance, host, pid.  Parse out the log, and fill out the $self->{ data } structure.
	Arguments: logfile, app, instance, host, pid
	Returns: True value if good; undef otherwise

=cut

sub _process_log {
    my ( $self, $log, $app, $instance, $host, $pid ) = @_;
    
    return unless ( -f $log && $app && $instance && $host && $pid );
    my $cmd = "$self->{ zcat } $log";
    open( my $fh, "-|", $cmd ) or return;

    my @block = ();
    my $capture = 0;
    my $date_pattern = $self->{ date_pattern };
    my $facility_loglevel = $self->{ facility_loglevel };
    my $loglevels = $self->{ loglevels };
    
    my @loglevels = @{ $loglevels } if ( $loglevels && ref( $loglevels ) eq "ARRAY" ); # optional argument

    while( my $line = <$fh> ) {
        chomp $line;
        if ( $line =~ /^$date_pattern/ && $capture == 0 ) {
            # Seeing date pattern when I wasn't capturing.  Run checks and start capturing if makes sense.
            my ( $facility, $loglevel ) = $line =~ /$facility_loglevel/;
            next unless ( $facility && $loglevel );
            next if ( @loglevels && !grep( /^$loglevel$/, @loglevels ) );
            push @block, $line;
            $capture = 1;
        }
        elsif ( $line =~ /^$date_pattern/ && $capture == 1 ) {
            # Here, I was capturing and reached the next timestamp line.  So here is what we need to do:
            # 1. process the previous block.  Since there is no telling in here if this block matches the pattern, that decision
            #    will need to happen in _process_block.  In fact, _process_block will update $self->{ data } hash.
            # 2. if this timestamp line is something we want to capture, start capturing.  If not, then turn off capturing
            # 3. Flush the current block.  Empty it if we stop capturing, put the date_pattern line in if we're capturing.

            $self->_process_block( $log, $app, $instance, $host, $pid, @block );

            my ( $facility, $loglevel ) = $line =~ /$facility_loglevel/;
            $capture = 0 unless ( $facility && $loglevel );
            $capture = 0 if ( @loglevels && !grep( /^$loglevel$/, @loglevels ) );

            if ( $capture ) {
                @block = ( $line );
            }
            else {
                @block = (); # we're not capturing, so flush whatever is in there now
            }
        }
        elsif ( $capture == 1 ) {
            push @block, $line;
        }
    }
    close $fh or return;
    $self->{ log_count }++; # incrementing log count that was actually processed
    return 1;
}

=head2 _process_block

	Description: Takes per-logfile arguments and a log block to process.  If the block matches defined patterns, will break it down and update $self->{ data }.
	Arguments: logfile, app, instance, host, pid and array of log block
	Returns: True value on success, undef on failure.  Note that we need to keep on going, as a lot of logs not matching pattern is normal.

=cut

sub _process_block {
    my ( $self, $log, $app, $instance, $host, $pid, @block ) = @_;
    
    return undef unless ( $log && $app && $instance && $host && $pid && @block );

    my $date_pattern = $self->{ date_pattern };
    my $facility_loglevel = $self->{ facility_loglevel };
    my $message_pattern = $self->{ message_pattern };
    my @error_patterns = @{ $self->{ error_patterns } };
    my $ref;
    my $matched = undef;

    for my $pattern ( @error_patterns ) {
        if ( grep( /$pattern/, @block ) ) {
            $matched = $pattern;
            last;
        }
    }
    
    return undef unless ( $matched );
    
    my $header = shift @block;
    $header =~ s/^($date_pattern)//;
    my $date = $1;
    $header =~ s/$facility_loglevel//;
    my ( $facility, $loglevel ) = ( $1, $2 );
    $header =~ s/$message_pattern//g;
    my $message = $1; # format is "Message: [GENERIC_ERROR]".  I am capturing more than I need to, since I'm truncating the header line

    if ( $message =~ /^Message: \[(.*)\]/ ) {
        $message = $1;
    }
    else {
        $message = undef; # not all headers have the Message field
    }

    unshift @block, $header;
    
    # need to clean things up here
    my $rest_of_block = join( "\n", @block );
    $ref = { date => $date, facility => $facility, loglevel => $loglevel, message => $message, rest_of_block => $rest_of_block, logfile => $log, pid => $pid };
    
    push @{ $self->{ data }->{ app }->{ $app }->{ instance }->{ $instance }->{ host }->{ $host }->{ $matched }->{ blocks } }, $ref;
    $self->{ data }->{ app }->{ $app }->{ instance }->{ $instance }->{ host }->{ $host }->{ $matched }->{ count }++;
    return 1;
}

=head2 _compute_count

	Description: Traverses data structure and computes counts, stuff in the data structure for easier retrieval
	Arguments: None
	Returns: None, although this method will update $self->{ data } with count information for later use

=cut

sub _compute_count {
    my $self = shift;
    
    my $grand_total;
    for my $app ( keys %{ $self->{ data }->{ app } } ) {
        
        my $per_app_count;
        for my $instance ( keys %{ $self->{ data }->{ app }->{ $app }->{ instance } } ) {
            
            my $per_instance_count;
            for my $host ( keys %{ $self->{ data }->{ app }->{ $app }->{ instance }->{ $instance }->{ host } } ) {           
                
                my $per_host_count;
                for my $matched ( keys %{ $self->{ data }->{ app }->{ $app }->{ instance }->{ $instance }->{ host }->{ $host } } ) {
                    $per_host_count += $self->{ data }->{ app }->{ $app }->{ instance }->{ $instance }->{ host }->{ $host }->{ $matched }->{ count };
                }
                $self->{ data }->{ app }->{ $app }->{ instance }->{ $instance }->{ host }->{ $host }->{ count } = $per_host_count;
                $per_instance_count += $per_host_count;
            }
            $self->{ data }->{ app }->{ $app }->{ instance }->{ $instance }->{ count } = $per_instance_count;
            $per_app_count += $per_instance_count;
        }
        $self->{ data }->{ app }->{ $app }->{ count } = $per_app_count;
        $grand_total += $per_app_count;
    }
    $self->{ data }->{ count } = $grand_total;
}

=head2 get

	Description: Generic getter
	Arguments: Element to return
	Returns: Whatever being asked

=cut

sub get {
    my ( $self, $arg ) = @_;
    return $self->{ $arg };
}

=head2 gen_html

    Description: Generates HTML from the data structure.
    Arguments: htmldir (where file is saved) and docroot (relative path on the URL)
    Returns: True value on success, undef / croak on failure

=cut

sub gen_html {
    my ( $self, $dir, $docroot, $template_dir ) = @_;

    if ( -e $dir ) {
        croak "not a directory" unless ( -d $dir );
    }
    else {
        mkdir $dir or croak "could not create directory: $!";
    }
    
    croak "docroot not provided" unless( $docroot );
    
    my $detailed_template = "detailed.tt";
    my $table_template = "table.tt";
    
    croak "template files not found" unless ( -f "$template_dir/$detailed_template" && -f "$template_dir/$detailed_template" );
    
    my $config = {
        INTERPOLATE     => 1,
        INCLUDE_PATH    => $template_dir,
    };
    my $tt = Template->new( $config ) || croak "template object creation failed";

    # extremely complicated nested loops that work like this:
    # 1. Starts from the inner-most loop where I generate the "citation" pages.
    # 2. I am creating data structure with just enough info so the outer loop can generate appropriate links.
    # 3. I am then Schwartzian Transforming the data structure to sort in descending order by error count
    # 4. Then I move onto generating the HTML on the outer loop; and moves outward
    # There is some duplicate code in here, but it's probably better not to refactor this for clarity
    my $total_ref;
    
    for my $app ( keys %{ $self->{ data }->{ app } } ) {
        my $apptotal = $self->{ data }->{ app }->{ $app }->{ count };
        my $app_ref;
        
        for my $instance ( keys %{ $self->{ data }->{ app }->{ $app }->{ instance } } ) {
            my $instancetotal = $self->{ data }->{ app }->{ $app }->{ instance }->{ $instance }->{ count };
            my $instance_ref;
            
            for my $host ( keys %{ $self->{ data }->{ app }->{ $app }->{ instance }->{ $instance }->{ host } } ) {
                my $hosttotal = $self->{ data }->{ app }->{ $app }->{ instance }->{ $instance }->{ host }->{ $host }->{ count };
                my $host_ref;       
        
                for my $matched ( keys %{ $self->{ data }->{ app }->{ $app }->{ instance }->{ $instance }->{ host }->{ $host } } ) {
                    next if ( $matched eq "count" );
                    my $vars;
                    $vars->{ matched } = $matched;
                    $vars->{ blocks } = $self->{ data }->{ app }->{ $app }->{ instance }->{ $instance }->{ host }->{ $host }->{ $matched }->{ blocks };

                    # from list of blocks, I'm just fetching a sample.  Printing every stacktrace would be too much
                    for my $block ( @{ $self->{ data }->{ app }->{ $app }->{ instance }->{ $instance }->{ host }->{ $host }->{ $matched }->{ blocks } } ) {
                        unless( $vars->{ sample } ) {
                            $vars->{ sample } = $block->{ rest_of_block };
                            last;
                        };
                    }
                    
                    # removes strange characters from $matched
                    my $copy = $matched;
                    $copy =~ s/[^a-zA-Z]//g;
                    my $filename = "$dir/$app/$instance/$host/$copy.html";
                    $tt->process( $detailed_template, $vars, $filename );
                    
                    my $count = $self->{ data }->{ app }->{ $app }->{ instance }->{ $instance }->{ host }->{ $host }->{ $matched }->{ count };
                    
                    my $chunk = {
                        count => $count,
                        link => "$host/$copy.html",
                        percentage => sprintf( "%.2f%%", $count * 100 / $hosttotal ),
                        matched => $matched,
                        total => $hosttotal,
                    };
                    push @{ $host_ref }, $chunk;
                }
                
                my @sorted = $self->_schwartzian_transform( $host_ref, "count" );
            
                my $host_vars;
                $host_vars->{ label } = "Host: $host";
                $host_vars->{ matches } = \@sorted;
                my $filename = "$dir/$app/$instance/$host.html";
                $tt->process( $table_template, $host_vars, $filename );
                
                my $chunk = {
                    count => $hosttotal,
                    link => "$instance/$host.html",
                    percentage => sprintf( "%.2f%%", $hosttotal * 100 / $instancetotal ),
                    matched => $host,
                    total => $instancetotal,
                };
                push @{ $instance_ref }, $chunk;
            }

            my @sorted = $self->_schwartzian_transform( $instance_ref, "count" );
            
            my $instance_vars;
            $instance_vars->{ label } = "Instance: $instance";
            $instance_vars->{ matches } = \@sorted;
            my $filename = "$dir/$app/$instance.html";
            $tt->process( $table_template, $instance_vars, $filename );
            
            my $chunk = {
                count => $instancetotal,
                link => "$app/$instance.html",
                percentage => sprintf( "%.2f%%", $instancetotal * 100 / $apptotal ),
                matched => $instance,
                total => $apptotal,
            };
            push @{ $app_ref }, $chunk;
        }

        my @sorted = $self->_schwartzian_transform( $app_ref, "count" );
        my $app_vars;
        $app_vars->{ label } = "App: $app";
        $app_vars->{ matches } = \@sorted;
        my $filename = "$dir/$app.html";
        $tt->process( $table_template, $app_vars, $filename );
        
        my $chunk = {
            count => $apptotal,
            link => "$docroot/$app.html",
            percentage => sprintf( "%.2f%%", $apptotal * 100 / $self->{ data }->{ count } ),
            matched => $app,
            total => $self->{ data }->{ count },
        };
        push @{ $total_ref }, $chunk; 
    }
    
    my @sorted = $self->_schwartzian_transform( $total_ref, "count" );
    my $total_vars;
    $total_vars->{ label } = "AN KeepRunning Log Report";
    $total_vars->{ matches } = \@sorted;
    my $filename = "$dir/index.html";
    $tt->process( $table_template, $total_vars, $filename );
    
    return 1;
}

=head2 _schwartzian_transform

	Description: Generic sub to perform Schwartzian Transform
	Arguments: Arrayref and keyword to sort with
	Returns: Array of elements

=cut

sub _schwartzian_transform {
    my ( $self, $ref, $key ) = @_;

    croak "bad params" unless( $key && $ref && ref( $ref ) eq "ARRAY" );

    my @array = 
        map $_->[0],
        sort { $b->[1] <=> $a->[1] }
        map [ $_, $_->{ $key } ],
        @{ $ref };

    return @array;
}

=head1 AUTHOR

Satoshi Yagi, C<< <syagi at ariba.com> >>


=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc ariba::monitor::ANLogReport


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

Copyright 2012 Ariba, Inc.

=cut

1; # End of ariba::monitor::ANLogReport
