package ariba::Ops::Utils;
use strict;
use warnings;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Utils.pm#83 $

=head1 NAME

ariba::Ops::Utils

=head1 SYNOPSIS

 use ariba::Ops::Utils;
 my $num = ariba::Ops::Utils::fix_jira_id($jira_id);

=head1 DESCRIPTION

A bunch of general purpose utilities that don't fit anywhere else.
Nothing is exported, so you need to fully qualify each function.

=cut

use Carp;
require "shellwords.pl";
use POSIX ':signal_h';
use FindBin;
use Cwd qw( realpath );
use ariba::Ops::Constants;
use ariba::Ops::Machine;

my $DEBUG = 0;
my $GETTIMEOFDAY;
my $WITHNEWLINES = 1;

# for fast html parsing
my $parser = 0;
my $parserWithNewLines = 0;

my %inside = ();
my @text   = ();

{
    eval "use HTML::Parser 3.00 ()";

    if ($@ !~ /Can't locate/) {

        print "Using XS html parser\n" if $DEBUG;

        $parser = HTML::Parser->new(
            api_version => 3,
            handlers    => [
                start => [\&_htmlTagCallBack, "tagname, '+1'"],
                end   => [\&_htmlTagCallBack, "tagname, '-1'"],
                text  => [\&_htmlTextCallBack, "dtext"],
            ],
            marked_sections => 1,
        );

        $parserWithNewLines = HTML::Parser->new(
            api_version => 3,
            handlers    => [
                start => [\&_htmlTagCallBackWithNewLines, "tagname, '+1'"],
                end   => [\&_htmlTagCallBackWithNewLines, "tagname, '-1'"],
                text  => [\&_htmlTextCallBack, "dtext, '$WITHNEWLINES'"],
            ],
            marked_sections => 1,
        );
    }
}

sub gettimeofdayInit() {
    if ( $^O eq "linux" ) {
        $GETTIMEOFDAY = 78;
    } elsif ( $^O eq "hpux" ||  
                $^O eq "solaris" ||  
                $^O eq "freebsd" || 
                $^O eq "darwin") {

        $GETTIMEOFDAY = 116;
    } else {
        $GETTIMEOFDAY = 156;
    }
}

# Method returns the correct path for the X virtual frame buffer server (Xvfb).  Requires a display value as an argument.
# Default is to return the path for the Solaris version/location, unless running on a Linux 5/6/7 host.  NOTE:  changed,
# to remove the Solaris defaults completely, and to return an empty list if it can't determine the OS and OS version to
# use to set the path and options.  This means, if something changes wrt the distribution being used, it may need to be
# added to the if/else contruct in order to work.
sub checkForXvfbPath
{
    my $display = shift;
    my $cmd;
    my $displayRes;

    # On linux Xvfb is in a different place and needs more options
    # specified.  Still true, but now more so:  RH5 and RH6 have
    # different locations plus different options.  Selection of OS
    # can be done through MachineDB methods.

    my $host = ariba::Ops::NetworkUtils::hostname();
    my $currentMachine = ariba::Ops::Machine->new($host);
    my $osVersion = $currentMachine->osVersion();
    my $os = $currentMachine->os();
    my $cmdargs;
    if ($os eq 'redhat' && $osVersion =~ /^5/) { # Assume RH5.x host:
        $cmd = "/usr/X11R6/bin/Xvfb";
        $cmdargs = "$display -nolisten tcp -sp /dev/null -fp /usr/X11R6/lib/X11/fonts/misc,/usr/X11R6/lib/X11/fonts/75dpi";
        $displayRes = "-pn -screen 0 1280x1024x24";
    }
    elsif ($os eq 'redhat' && $osVersion =~ /^[67]/) { # Assume RH6.x or RH7.x host, for now:
        $cmd = "/usr/bin/Xvfb";
        $cmdargs = "$display -nolisten tcp -fp /usr/share/X11/fonts/misc,/usr/share/X11/fonts/75dpi";
        $displayRes = "-pn -screen 0 1280x1024x24";
    }
    else
    {
        $cmd = undef;
        $cmdargs = undef;
        $displayRes = undef;
    }

    # And return as a list of 3 items.
    return ($cmd, $cmdargs, $displayRes);
}

# Checking for an active software update/distribution process to be sure the host is fully up
# to date.  With the advent of SALT, this routine has been enhanced to look for both cfengine
# OR SALT processes.  Note that these are mutually exclusive, a simple OR and return is fine.
sub checkForActiveCfengine {
    my $service = shift;

    #
    # allow an override for this check
    #
    if( -e "/var/tmp/skip-cfengine-check" ) {
        if( (stat("/var/tmp/skip-cfengine-check"))[9] > (time()-604800) ) {
            return(1);
        }
    }

    unless($FindBin::Bin =~ m|/usr/local/ariba/bin|) {
        #
        # not run from cfengine controlled code, so this is ok
        #
        return(1);
    }

    if($ENV{'ARIBA_OVERRIDE_CFENGINE_CHECK'}) {
        #
        # allow an override
        #
        return(1);
    }

    if( ariba::Ops::NetworkUtils::hostname() =~ /(?:buildbox|selenium)/) {
        #
        # don't check on robots, because I don't know what the ro-butt does
        #
        return(1);
    }

    my $user = "mon$service";
	if( ariba::Ops::NetworkUtils::hostname() =~ /penguin/) {
		#
		# penguin only has svcops
		#
		$user = "svcops";
        }

    my $command = "su $user -c \"sudo crontab -l\"";
    my $password = ariba::rc::Passwords::lookup($user);

    unless( $password ) {
        return(0);
    }

    my @output;
    my $ret = ariba::rc::Utils::executeRemoteCommand(
        $command,
        $password,
        0,
        undef,
        undef,
        \@output
    );

    foreach my $line (@output) {
        next if($line =~ /^\s*#/);
        return(1) if($line =~ m@/usr/local/cfengine/stage1|salt-minion@);
    }

    return(0);
}

sub gettimeofday {
    my $timeval = pack("ll",0,0);
    syscall($GETTIMEOFDAY, $timeval,undef);
    return ( sprintf("%d.%06d", unpack("ll",$timeval)) );
}

sub systemMemorySize {

    my $physicalMemory = 0;

    if ($^O eq 'solaris' or $^O eq 'sunos') {

        local $SIG{__DIE__};
        require 'sys/sysconfig.ph';
        require 'sys/syscall.ph';

        my ($pageSize,$physPages);

        if ($] eq '5.00503') {
            $pageSize  = syscall(&main::SYS_sysconfig, &_CONFIG_PAGESIZE);
            $physPages = syscall(&main::SYS_sysconfig, &_CONFIG_PHYS_PAGES);
        } else {
            $pageSize  = syscall(&SYS_sysconfig, &_CONFIG_PAGESIZE);
            $physPages = syscall(&SYS_sysconfig, &_CONFIG_PHYS_PAGES);
        }

        $physicalMemory = sprintf('%ld', ($pageSize * $physPages) / (1024*1024));

    } elsif ($^O eq 'hpux') {

        eval {
            local $SIG{__DIE__};
            require 'sys/syscall.ph';
            require 'sys/pstat.ph';

            my $pstat = "\0" x 64;

            if ($] eq '5.00503') {
                syscall(&main::SYS_pstat, &PSTAT_STATIC, $pstat, length($pstat), 0, 0);
            } else {
                syscall(&SYS_pstat, &PSTAT_STATIC, $pstat, length($pstat), 0, 0);
            }

            $physicalMemory = sprintf('%d', (unpack('i*', $pstat))[4] / 256);
        };

    } elsif ($^O eq 'linux') {

        # x86 is lame - because there are so many different northbridges, 
        # there's no standardized way to get at the physical ram in the 
        # system. The Memory: line in dmesg is also # not correct, it's 
        # just the information the BIOS 0e20h API told Linux.
        #
        # So, grab the available memory to Linux out of meminfo, and
        # round to the nearest power of two. This may be wrong, but
        # it's better than nothing.

        open(MEMINFO, '/proc/meminfo') or die "Couldn't open /proc/meminfo for reading: $!";

        while (my $line = <MEMINFO>) {

            next unless $line =~ /^MemTotal:\s+(\d+)/;

            $physicalMemory = $1;

            last;
        }

        close(MEMINFO);

        $physicalMemory = sprintf('%ld', (2**(int(log($physicalMemory)/log(2))+1)) / 1024);
    }

    return $physicalMemory;
}

sub sharedMemorySize { 
    open(my $h, "/proc/sys/kernel/shmmax") or return 0; 
    my $sharedMemorySize = <$h>; 
    close($h); 

    return $sharedMemorySize >> 20; 
}

sub usedHugePagesSize {
    my($size, $total, $free, $rsvd) = processHugePagesInfo();

    return ($total - $free + $rsvd) * $size;
}

sub usedHugePagesPercent {
    my($size, $total, $free, $rsvd) = processHugePagesInfo();

    return 0 if $total == 0;
    return ($total - $free + $rsvd) / $total * 100;
}

sub processHugePagesInfo {
    open(my $h, "/proc/meminfo") or return 0;
    my ($size, $total, $free, $rsvd) = (0,0,0,0);
    while(my $line = <$h>) {
        if($line =~ m/Hugepagesize:\s+(\d+)\s+(\w+)/) {
            $size = $1;
            my $type = $2;
            if($type eq "kB") {
                $size /= 1024;
            }
        } elsif($line =~ m/HugePages_Total:\s+(\d+)/) {
            $total = $1;
        } elsif($line =~ m/HugePages_Free:\s+(\d+)/) {
            $free = $1;
        } elsif($line =~ m/HugePages_Rsvd:\s+(\d+)/) {
            $rsvd = $1;
        }
    }

    return ($size, $total, $free, $rsvd);
}

# send statsD line protocol "message" to statsd server
#
# input: the message (see https://wiki.ariba.com/x/ZAHDAg)
#        the statsd server (localhost) - optional
#        the port it's listening on (8125) - optional
# returns: 1 (0 if any problems, stay as quiet as possible,
#               this is a fire-and-forget approach
sub sendToStatsD {
    my $lineProtocol = shift;
    my $statsdServer = shift || 'localhost';
    my $statsdPort   = shift || '8125';

    # let's 'require' instead of 'use' for now, if we find
    # more functions need IO::Socket, we can 'use' it
    require IO::Socket::INET;

    # return quietly if unable to connect, dont die!
    my $sock = IO::Socket::INET->new(PeerAddr => $statsdServer,
                                     PeerPort => $statsdPort,
                                     Proto    => 'udp',
                                     Timeout  => 1), or return 0;

    print $sock "$lineProtocol\n";
    close $sock;

    return 1;
}

sub generateJsonOutput{
    my ( $url ) = shift;

    # let's 'require' instead of 'use' for now
    require LWP;
    require IO::Socket::SSL;
    require JSON;

    my $userAgent = LWP::UserAgent->new(ssl_opts => {SSL_verify_mode => 0, verify_hostname => 0,});
    my $request = HTTP::Request->new(GET => $url);
    my $response = $userAgent->request($request);
    $response->is_success or return $response->message();

    # The response will be JSON from the remote host, which needs to be converted...
    return -1 unless ( $response->content() );

    my $response_hash_ref = eval {JSON::decode_json($response->content())};

    ### Convert values to numberic if its enclosed as string. ie. "4" --> 4
    my $new_hash;
    foreach my $key ( keys %{$response_hash_ref} )
    {
        $new_hash->{$key} =  ( $response_hash_ref->{$key} !~ /[a-z|\s|:]/gi ) ? int $response_hash_ref->{$key}  : $response_hash_ref->{$key};
    }
    return $new_hash;
}  

sub generateStatsDLine{
    my ( $influx_data ) = shift;

    # Mandatory keys in the data structure are : measurement, data , tags->product & tags->service 
    return 0 unless ( $influx_data->{measurement} && $influx_data->{data} && $influx_data->{tags} && $influx_data->{tags}->{product} && $influx_data->{tags}->{service} );

    ### Append few more defaults;
    my $ran_by = realpath "$0";
    my $ran_on_host = ariba::Ops::NetworkUtils::hostname();
    $influx_data->{tags}->{ran_by} = $ran_by;
    $influx_data->{tags}->{ran_as_user} = $ENV{LOGNAME} || $ENV{USERNAME} || $ENV{USER} || "NA";

    ### Append data center
    $influx_data->{tags}->{dc} = ariba::Ops::Machine->new()->datacenter();

    ### Generate tag syntax 
    my $tags;
    foreach my $tag_key ( keys %{$influx_data->{tags}} )
    {
        $tags .= qq(,$tag_key=$influx_data->{tags}->{$tag_key});
    }

    ### Build statsdline
    my $statsd_line;
    foreach my $data_key ( keys %{$influx_data->{data}} )
    {
        $statsd_line .= qq($influx_data->{measurement}.$data_key$tags:$influx_data->{data}->{$data_key}|g\n);
    }

    return $statsd_line
}

sub generateInfluxLine{
    my ( $influx_data ) = shift;

    # Mandatory keys in the data structure are : measurement, data , tags->product & tags->service 
    my $measurement = $influx_data->{measurement};
    return 0 unless ( $measurement && $influx_data->{data} && $influx_data->{tags} && $influx_data->{tags}->{product} && $influx_data->{tags}->{service} );

    ### Append few more defaults;
    my $ran_by = realpath "$0";
    my $ran_on_host = ariba::Ops::NetworkUtils::hostname();
    $influx_data->{tags}->{ran_by} = $ran_by;

    ### Append data center
    $influx_data->{tags}->{dc} = ariba::Ops::Machine->new()->datacenter();

    ### Generate tag syntax 
    my $tags;
    foreach my $tag_key ( sort keys %{$influx_data->{tags}} )
    {
        ### Escape the space in tag
        my $tag_value = $influx_data->{tags}->{$tag_key};
        my $key       = lc($tag_key);
        $tag_value    =~ s/(\s+)/\\$1/g;
        $tags .= qq(,$key="$tag_value");
    }

    ### Build influx fields
    my $fields;
    foreach my $field_key( sort keys %{$influx_data->{data}} )
    {
        my $value = $influx_data->{data}->{$field_key};
        my $key   = lc($field_key);
        $fields .= ($value =~ /[a-z|\s|:]/i) ? qq($key="$value",) : qq($key=$value,);
    }
    chop($fields);

    ### Build influx line
    my $influx_line = qq($measurement$tags $fields);
    return $influx_line;
}

# these are unix specific
sub basename {
    my $fileName = shift;
    my @parts    = split /\//o, $fileName;
    return pop @parts;
}

sub dirname {
    my $fileName = shift;
    my @parts    = split /\//o, $fileName;
    my $basename = pop @parts;
    return join('/', @parts);
}

sub strerror {
    return local $! = shift;
}

sub page {
    email(@_);
}

sub email {
    my ($to,$subject,$body,$cc,$from,$replyto,$precedence) = @_;

    # only $to is required
    # arg order is in rough likelyhood of need

    open  SENDMAIL, '| /usr/lib/sendmail -t' or die $!;
    print SENDMAIL "From: $from\n" if $from;
    print SENDMAIL "To: $to\n";
    print SENDMAIL "Cc: $cc\n" if $cc;
    print SENDMAIL "Subject: $subject\n" if $subject;
    print SENDMAIL "Reply-To: $replyto\n" if $replyto;
    print SENDMAIL "Precedence: $precedence\n" if $precedence;
    print SENDMAIL "\n";
    print SENDMAIL "$body\n" if $body;
    close SENDMAIL;

}

sub emailFile {
    my ($to,$subject,$file,$cc,$from,$replyto) = @_;

    # only $to is required
    # arg order is in rough likelyhood of need

    open  SENDMAIL, '| /usr/lib/sendmail -t' or die $!;
    print SENDMAIL "From: $from\n" if $from;
    print SENDMAIL "To: $to\n";
    print SENDMAIL "Cc: $cc\n" if $cc;
    print SENDMAIL "Subject: $subject\n" if $subject;
    print SENDMAIL "Reply-To: $replyto\n" if $replyto;
    print SENDMAIL "\n";

    if ( $file && -e $file && open(EMAILFILE, $file) ) {
        while(my $line = <EMAILFILE>) {
            print SENDMAIL $line;
        }
        close(EMAILFILE);
    }

    close SENDMAIL;

}

# We need a "simpler" timeout methodology, to allow existing code to be wrapped without
# having to convert it into a code ref, to use with runWith...() methods below.

=head 2 timeoutOn (timeout)

Set up an alarm timeout for the given timeout period.

=cut

# The original runWithTimeout and siblings could use 'local' to isolate $SIG{ALRM}.  This
# cannot, because it would be lost upon return.  To protect possible settings from elsewhere,
# This method needs to save any possible pre-existing value for the signal, and reset that
# when timeoutOff is called.  This requires a file global variable.
my $savedALRM;
sub timeoutOn {
    my $timeout = shift;
    # Ignore if the supplied value is not a positive integer.
    return unless $timeout > 0; # Eliminate possible negative values as well.
    $savedALRM = $SIG{ALRM} if $SIG{ALRM};
    $SIG{ALRM} = sub { die "died due to alarm interrupt.\n" }; # NB: \n required
    alarm $timeout;
}

=head2 timeoutOff

Turn off the alarm set by timeoutOn().

=cut

sub timeoutOff {
    alarm 0;
    $SIG{ALRM} = $savedALRM if $savedALRM;
}

sub runWithTimeout {
    my $timeout = shift;
    my $coderef = shift;

    $@ = undef;

    my $evalError = eval {
        local $SIG{ALRM} = sub { die "alarm\n" }; # NB: \n required
        alarm $timeout;

        &$coderef;

        alarm 0;
        return $@;
    };

    $@ ||= $evalError;
    if ($@) {
        # time out
        croak $@ unless $@ eq "alarm\n";   # propagate unexpected errors

        return 0;
    } else {
        #didn't

        return 1;
    }
}

# In versions of Perl before 5.8, signal handling was not completely safe
# due to the fact that signals could interrupt changes to perl's internal data
# structures.  If the signal-handling code accessed these internal data
# structures it could cause the program to crash or produce strange results.
# 
# Since 5.8 Perl has moved to a safe system of signal handling where it defers
# signals until it finds a safe moment to run the signal handler. However,
# this means that signal handling may be defered for much longer than
# expected, especially 
#
# Using this method reverts back to the old, 'unsafe' way of handling signals,
# but it is the only way to ensure that syscalls are interrupted.
#
# This only seems to be an issue with DBI::Oracle.
#
# See http://search.cpan.org/~timb/DBI/DBI.pm#Signal_Handling_and_Canceling_Operations
# and http://search.cpan.org/~lbaxter/Sys-SigAction/lib/Sys/SigAction.pm
# and http://search.cpan.org/~nwclark/perl-5.8.8/pod/perlipc.pod#Deferred_Signals_(Safe_Signals)
# 

=head2 runWithForcedTimeout (timeout, coderef)

Runs the supplied coderef, wrapped with an 'alarm' set to timeout seconds.  This uses the
POSIX module and sets up B<unsafe> signal handling.

=cut

sub runWithForcedTimeout{
    my $timeout = shift;
    my $coderef = shift;

    $@ = undef;

    my $mask = POSIX::SigSet->new( &POSIX::SIGALRM );
    my $action = POSIX::SigAction->new(
        sub { die "alarm\n" },
        $mask,
        # not using (perl 5.8.2 and later) 'safe' switch or sa_flags
    );

    my $oldaction = POSIX::SigAction->new();
    sigaction( &POSIX::SIGALRM, $action, $oldaction );

    my $evalError = eval {
        alarm $timeout;
        &$coderef;
        alarm 0;
        return $@;
    };

    sigaction ( &POSIX::SIGALRM, $oldaction );
    
    $@ ||= $evalError;
    if ($@) {
        # time out
        die unless $@ eq "alarm\n";   # propagate unexpected errors

        return 0;
    } else {
        #didn't

        return 1;
    }
}

=head2 runWithoutTimeout (coderef)

Run the supplied coderef without any timeout.  See runWithForcedTimeout for the opposite
method (old unsafe signales) or runWithTimeout (new, safe signaling).

=cut

sub runWithoutTimeout {
    my $coderef = shift;

    $@ = undef;

    my $evalError = eval {
        &$coderef;
        return $@;
    };

    $@ ||= $evalError;
    if ($@) {
        return 0;
    } else {
        return 1;
    }
}

# strip out html
sub _htmlTagCallBack {
    my ($tag, $num) = @_;
    $inside{$tag} += $num;
}   

# strip out html with white spaces
sub _htmlTagCallBackWithNewLines {
    my ($tag, $num) = @_;
    $inside{$tag} += $num;

    if ($tag eq 'br') {
        push(@text, "\n");
    }
    if ( ($num < 0) && ($tag eq 'p') ) {
        push(@text, "\n\n");
    }

    if ( ($num < 0) && ($tag eq 'div') ) {
        push(@text, "\n");
    }

}

sub _htmlTextCallBack {
    my $text = shift;
    my $withNewLines = shift ;

    return if $inside{'script'} || $inside{'style'};
    return if $text =~ /^\s*$/;

    # &nbsp; gets turned into ascii a0, which we don't like - strip it out.
    $text =~ s/\xA0/ /g;

    $text =~ s/\n//g if ($withNewLines);

    push @text, $text;
}


sub stripHTMLWithNewLine {
    my $html = shift;

    return $html unless($html);

    # see if we loaded the XS parser

    $parserWithNewLines->parse($html);
    $parserWithNewLines->eof();

    $html = join( '', @text);
    
    %inside = ();
    @text   = ();

    # Pack it.

    $html =~ s/[\t ]+/ /gs;
    $html =~ s/^[\t ]+//gs;
    $html =~ s/[\t ]+$//gs;

    return $html;
}


sub stripHTML {
    my $html = shift;

    return $html unless($html);

    # see if we loaded the XS parser
    if ($parser) {

        $parser->parse($html);
        $parser->eof();

        $html = join(' ', @text);

        %inside = ();
        @text   = ();

    } else {

        # Timeout in 60 secs if something barfs.
        eval {
            # Kill the loop if we can't parse.
            local $SIG{'ALRM'} = sub { die ".Couldn't parse HTML!\n" };
            alarm 10;
    
            # Remove all the comments.
            $html =~ s{<!(.*?)(--.*?--\s*)+(.*?)>}{if($1 || $3){"<!$1 $3>"}}gexs;

            # Remove the HTML.
            $html =~ s/<(?:[^>'"]|'.*?'|".*?")*>//gs;
    
            # Remove any leftovers.
            $html =~ s/<>//gs;
    
            alarm 0;
        };

        # might as well spew some info than none.
        #$html = 'HTML Unparseable.' if $@;
    }

    # Pack it.
    $html =~ s/\s+/ /gs;
    $html =~ s/^\s+//gs;
    $html =~ s/\s+$//gs;

    return $html;
}

sub computeIntersection {
    my $arrays = shift;
    
        my (@union,@intersection,@difference,%count) = ();

    # do required intersection first.
    foreach my $element (@$arrays) {
        map { $count{$_}++ } @$element;
    }

        foreach my $element (keys %count) {
                push @union, $element;

        if ($count{$element} == scalar @$arrays) {
                    push @intersection, $element;
        }
        }

    # If we are only given a single term, the intersection will be empty.
    # So return the union instead.
    if (scalar @$arrays == 1) {
        print "Returning union\n" if $DEBUG and -t STDOUT;
        return \@union;
    } else {
        print "Returning intersection\n" if $DEBUG and -t STDOUT;
        return \@intersection;
    }
}

sub computeUnion {
    my $arrays = shift;
    
        my @union = ();
    my %count = ();

    foreach my $element (@$arrays) {
        map { $count{$_}++ } @$element;
    }

    map { push @union, $_ } keys %count;

    return \@union;
}

sub computeDifference {
    my ($required,$excluded) = @_;
    
        my (@union,@intersection,@difference,%count) = ();

    # do required intersection first.
    map { $count{$_}++ } (@$required, @$excluded);

        foreach my $element (keys %count) {
                push @union, $element;
        print "element: $element => $count{$element}\n" if $DEBUG and -t STDOUT;
                push @{ $count{$element} > 1 ? \@intersection : \@difference }, $element;
        }

    return \@difference;
}

sub fisherYatesShuffle {
    my $array = shift;
    my $i = @$array;
    while ($i--) {
        my $j = int rand ($i+1);
        @$array[$i,$j] = @$array[$j,$i];
    }
}

#
#
# this is only useful for Page and PageRequest;  you can easily claim
# it should not be in this package.   This computes based on *rounded*
# to the hour, not strict 24 hours in secs.
#
# Object must have implemented creationTime()
#

sub _objectCreatedWithinLastDay {
    my $object = shift;

    my $time = time();

    my $currentHour = (localtime($time))[2];
    my $currentDay = (localtime($time))[3];

    my $creationTime = $object->creationTime();

    my $hour = (localtime($creationTime))[2];
    my $day = (localtime($creationTime))[3];

    # check for object between $currentHour ... 24 exclusive
    # and 0 ...  $currentHour inclusive

    if ( $hour > $currentHour && $hour < 24 ) {
        # late yesterday
        return 1;
    } elsif ( $day == $currentDay && $hour <= $currentHour ) {
        # today
        return 1;
    } else {
        return 0;
    }
}

#
# use double-pipe routine to fork a process in the background and be able to feed it
# input on one FD, and read from the other.  OUT closes when program exits.
#
# usage:
#
# $pid = ariba::Ops::Utils::doublePipe(*IN, $program, *OUT);
#
# print IN "password\n";
# while ( my $output = <OUT> ) {
#   print "$program said: $output";
# }
#
# close IN;
# close OUT;
#

sub doublePipe {
        my($in,$cmd,$out) = @_;

        pipe($out,WTMP); 
        pipe(RTMP,$in);
        select($in); $| = 1;
        select($out); $| = 1;
        select(STDOUT);
        my $pid = 0;

        if (!defined ($cmd)) {
            return $pid;
        }

        unless ($pid=fork) {
                # close the unused sides in the child.
                close($in); close($out);

                open(STDIN,"<&RTMP");
                open(STDOUT,">&WTMP");
                open(STDERR,">&WTMP");
                close(RTMP); close(WTMP);
                exec (shellwords($cmd));
        } 
        # close the unused sides in the parent.
        close(WTMP); close(RTMP);
        return $pid;
}

sub outputHasRealRsyncErrors {
    my $output = shift;

    return (grep(!/(^rsync error:|No such file or directory|Permission Denied|Stale NFS file handle|^\s*$)/, @$output));

}

sub hardwareTypeForSystem {
    # Solaris prtdiag output from all Sun hardware we have:
    # System Configuration:  Sun Microsystems  sun4u Sun Enterprise 220R (2 X UltraSPARC-II 450MHz)
    # System Configuration:  Sun Microsystems  sun4u Sun (TM) Enterprise 250 (2 X UltraSPARC-II 400MHz)
    # System Configuration:  Sun Microsystems  sun4u Sun Enterprise 420R (4 X UltraSPARC-II 450MHz)
    # System Configuration:  Sun Microsystems  sun4u Sun Fire 280R (2 X UltraSPARC-III+)
    # System Configuration:  Sun Microsystems  sun4u Sun Fire 480R
    # System Configuration:  Sun Microsystems  sun4u Sun Fire V120 (UltraSPARC-IIe 648MHz)
    # System Configuration:  Sun Microsystems  sun4u Sun Fire V240
    # System Configuration:  Sun Microsystems  sun4u Netra t1 (UltraSPARC-IIi 440MHz)
    # System Configuration:  Sun Microsystems  sun4u Sun Ultra 2 UPA/SBus (2 X UltraSPARC-II 400MHz)
    # System Configuration:  Sun Microsystems  sun4u Sun Ultra 5/10 UPA/PCI (UltraSPARC-IIi 400MHz)
    # System Configuration:  Sun Microsystems  sun4u SPARCengine(tm)Ultra(tm) AXi (UltraSPARC-IIi 440MHz)

    my $os = $^O;
    my $type;

    if ($os eq 'solaris') {

        my $platform = (POSIX::uname())[4];

        # read first line of prtdiag and force to lower case.  (see above for prtdiag strings)
        open(SYSCMD, "/usr/platform/$platform/sbin/prtdiag |") or die $!;
        chomp(my $prtdiag = <SYSCMD>);
        close(SYSCMD);

        # strip out all the useless information
        $prtdiag =~ tr/A-Z/a-z/;
        $prtdiag =~ s/^.+$platform //;
        $prtdiag =~ s/\s\(tm\)//gi;
        $prtdiag =~ s/\(\s+?\)//gi;
        $prtdiag =~ s/^sun\s*//;

        # what we have left is interesting
        my ($modelName,$modelNumber) = split(/\s+/, $prtdiag);

        # this handles the ultra case where prtdiag returns '5/10' (we use '10')
        $modelNumber =~ s/^\d\///;

        # artificially preface 'v' if there isn't one
        if ($modelName =~ /^fire/ and $modelNumber !~ /280r/) {
            $modelNumber =~ s/^v?/v/;
            $type = $modelNumber;
        }

        # 280r is treated as enterprise, though it really isn't
        # all enterprise models: append an artificial 'r' if there isn't one
        if ($modelName =~ /^enterprise/ or $modelNumber =~ /280r/) {
            $modelNumber =~ s/^e?/e/;
            $modelNumber =~ s/r?$/r/;
            $type = $modelNumber;
        }

        if ($modelNumber =~ /^axi/) {
            $type = $modelNumber;
        }

        # No matches above - this will catch ultra, netra, etc
        $type = join('_', $modelName, $modelNumber) unless $type;

    } elsif ($os eq 'hpux') {

        open(MODEL, "/usr/bin/model |") or die $!;
        chomp(my $model = <MODEL>);
        close(MODEL);

        $model =~ tr/A-Z/a-z/;
        my ($modelName) = ($model =~ m|/([a-z])|);

        $type = $modelName . '_class';
    } elsif ($os eq 'linux') {

        my $ipmitool = "/usr/bin/ipmitool";

        if ( -f "/etc/redhat-release" and -x $ipmitool) {

            # see the IPMI 1.5 spec at
            # ftp://download.intel.com/design/servers/ipmi/IPMIv1_5rev1_1.pdf
            #
            # See "Read FRU Data" in table G-1 of the spec for the raw arguments
            $ipmitool .= " -I open raw 0xA 0x11 0x0 0x6D 0x0 17 2>&1";
            
            open(IPMI, "$ipmitool |") or die "Unable to run [$ipmitool]: $!";
            chomp(my @results = <IPMI>);
            close(IPMI);
            
            # remove header information from the response
            splice(@results, 0, 3);
            
            my $productName = '';
            
            foreach my $line (@results) {
            
                my @bytes = split(/\s+/, $line);
            
                # the first element of each line is empty so ditch it
                shift @bytes if ($bytes[0] eq '');
            
                # the first byte of the response is the total
                # number of bytes returned in hex. we don't need this
                shift @bytes if ($productName eq '');
            
                # convert each byte from hex to ascii
                foreach my $byte (@bytes) {
                    $productName .= sprintf("%c", hex($byte));
                }
            }

            # Product name looks like "Sun Fire(tm) V20z". 
            # We only want the V20z portion.
            $type = (split(/\s+/, lc($productName)))[-1];
        }
    }

    print "return value is [$type]\n" if $DEBUG;
    return $type;
}

sub sessionIsInRealTerminal {
    #
    # first look for running from a terminal -- cron jobs do not need screen
    # so we won't force them to have it.
    #
    unless( -t STDIN ) {
        return 0;
    }

    ## We should also return if we're running in Expect.
    if ( defined $ENV{ 'EXPECT' } && $ENV{ 'EXPECT' } eq 'true' ){
        return 0;
    }

    return(1);
}

sub sessionIsInScreen {
    #
    # screen will set an WINDOW environment variable -- look for it.
    # It should always be a numeric value.
    #
    if(defined $ENV{'WINDOW'} && $ENV{'WINDOW'} =~ /^\d+$/) {
        return 1;
    }

    return 0;
}

sub checkForScreen {
    my $warn = shift;

    #
    # don't require screen for headless calls
    #
    unless(sessionIsInRealTerminal()) {
        return;
    }

    if(sessionIsInScreen()) {
        return;
    }

    #
    # if we're in screen, we already returned, so now we either warn or bail
    #
    if($warn) {
        print "WARNING!!!!  You are not in a screen session!!!\n\n";
        print "Continue? [y/N] ";
        my $resp = <STDIN>;
        if($resp =~ /^[yY]/) {
            return;
        }
        print "$0 aborted.\n";
        exit 1;
    }

    print "*** $0 should only be run from screen.\n";
    print "*** Please start a screen session, and then run $0.\n";
    exit 1;
}

sub updateSymlink {
    my $to = shift;
    my $from = shift;

    my $currentTo = readlink($from);

    if(!$currentTo || $currentTo ne $to) {
        unlink($from);
        symlink($to, $from);
    }
}

sub monUrlForService {
    my $service = shift;
    require ariba::rc::InstalledProduct;
    my $me = ariba::rc::InstalledProduct->new('mon', $service);

    ## Hard coding cluster to 'primary', might find a reasson to NOT do this but for now ...
    my $host = ($me->hostsForRoleInCluster("monserver", 'primary'))[0];
    my $port = $me->default('WebServerHTTPPort');

    return "http://$host:$port/";
}

sub monXMLUrlForService {
    my $service = shift;
    my $base = monUrlForService( $service );

    return $base . 'cgi-bin/xml-server';
}

=head2 fix_jira_id( $jira_id | Str ) | Int

Returns the number portion of the jira id.
For example, if you pass in HOA-12345, it will return 12345.

=cut

sub fix_jira_id {
	my $jira_id = shift;
    return unless $jira_id;
	my($num) = $jira_id =~ /(\d+)$/;
	return $num;
}

=head2 sanitizeNonASCIIChars (string)

Cleans up "string", converting any non-ASCII characters to an XML 'entity' of the form
&#...; where the ... is an actual decimal number representing the character.

=cut

sub sanitizeNonASCIIChars
{
    my $strRef = shift;
    # Extract single characters from the string, determine if it is non-ASCII and if it
    # is, encode it for XML use.
    my $offset = 0;
    my ($cleanString, $char);
    # This needs to allow zero as a valid character, and only terminate when the return from substr is empty ('').
    while (defined ($char = substr ($$strRef, $offset++, 1)) && $char ne '')
    {
        # Save as is if it is ASCII, else encode it.
        my $ordinal;
        if (($ordinal = ord ($char)) > 127) # This is the value for DEL, also an illegal XML char, but not handled here.
        {
            $cleanString .= "&#$ordinal;";
        }
        else
        {
            $cleanString .= $char;
        }
    }

    # We are trying to save memory and improve processing speed, but were forced to make a local copy of the data in
    # this routine.  Assigne it to the passed in by ref string, so the local is garbage collected upon exit, returning
    # the ref.
    $$strRef = $cleanString;
    return $strRef;
}

=head2 sanitizeControlChars (string)

Cleans up "string", removing all control characters (anything in the range 0x00-0x1f
and 0x7f), but not touching any of the 'white space' characters, like tab and newline.

=cut

sub sanitizeControlChars
{
    # Need to create the regex in steps, since it uses chr and hex codes for control characters.  And to be safe,
    # need to include the 'del' char (hex 7f).
    my $regex = '[' . chr(0x00) . '-' . chr(0x07) . chr(0x0e) . '-' . chr(0x1f) . chr(0x7f) . ']';
    $regex = qr/$regex/;

    my $strRef = shift;
    # elide the control characters.
    $$strRef =~ s/$regex//g;
    return $strRef;
}

=head2 cleanupStringForXML (string)

Cleans up "string", first removing the control characters as handled by sanitizeControlChars,
above), followed by converting any non-ASCII characters into an encoded entity.  This
combines the functions sanitizeControlChars and sanitizeNonASCIIChars to do both at once.
Args:  a reference to a string.

=cut

sub cleanupStringForXML
{
    my $strRef = shift;
    return sanitizeNonASCIIChars (sanitizeControlChars ($strRef));
}

=head2 getParamsFromAlternateConfig (AltConfigFile, parameter)

AltConfigFile is a string, providing the path to the alternate configuration file.  "parameter"
is a string, the parameter name to look for.  The file is searched for the parameter pattern
and if found, the value on the right side of the equal sign is returned.  If the parameter does
not exist in the file, '0' is returned.  Be sure to check for undef versus 0, as they designate
different outcomes.

This works in devlab.  In production, there are no alternate configuration files and this method
will return 'undef' in that case.

=cut

# This is pulled from ariba::Ops::DatasetManager, with some minor changes: logging is removed and left
# for the caller to deal with; changed the 'open' to the 3 arg form; changed 'split' to use a regex,
# so it will deal with any amount of, or missing, leading/trailing white space.  This last allowed
# removing the 'cleanup' regex used to remove possible leading white space.
# NOTE:  and one major change:  return 0 if the param is not found, return undef if file does
#        not exist.  This is the reverse of the function in DatasetManager.pm.
#        This seems more logical overall.
sub getParamsFromAlternateConfig
{
    my $config = shift;
    my $param = shift;

    # Note that this will happen in production environments, where things like hadoop will always be
    # part of the current service.  In devlab, for exammple, hadoop only exists in 3 services, so
    # other services need to find it using this function.
    return undef unless -r $config;

    my $value;
    open(FILE, '<', $config);
    while (my $line = <FILE>)
    {
        chomp $line;
        if ($line =~ /$param/)
        {
            # Split on an equal sign with any amount of leading/trailing white space.
            $value = (split(/ *= */, $line))[1];
            return $value if $value;
            last;
        }
    }

    return 0;
}

=head2 uniq (strings)

The "strings" argument may be either a normal list of string arguments, or a reference to an array
of strings.  Unlike the utility 'uniq', the strings *do not* need to be sorted.

In either case, the strings are used as the keys of a hash, with the value being a count of the
number of instances of that string.

The return value is a reference to the hash created to hold the strings.  The user may then use
just the keys, to access unique string values, or use both the key and the value (count of
occurances) if needed.

=cut

sub uniq
{
    # Allow input as an array ref or generic list of arguments.
    my $firstArg = $_[0]; # Do not shift, leave @_ intact for later, if needed.
    my %uniqueStrings;
    return FALSE unless $firstArg;
    if (my $refType = ref ($firstArg)) # The argument is a reference of some sort.
    {
        # If the arg is a ref to an array, then it should be an array of strings to process.
        if ($refType eq 'ARRAY')
        {
            for my $str (@$firstArg)
            {
                $uniqueStrings{$str}++;
            }
        }
        else
        {
            return FALSE; # Not the expected ref type.
        }
    }
    else
    {
        # The strings will be elements in @_.
        for my $str (@_)
        {
            $uniqueStrings{$str}++;
        }
    }

    # Return a reference to the hash created.
    return \%uniqueStrings;
}

=head2 bye ([message])

Dies, printing the supplied message or a default, if stdout and stderr point to a terminal.
Otherwise, exits with status 1 and nothing printed, to prevent spew under cron jobs or in
pipes.

=cut

sub bye {
    my $msg = shift;
    $msg = "Good-bye, exiting." unless $msg;

    if ( -t 1 && -t 2 ) {
        die "$msg\n";
    } else {
        exit 1;
    }
}

=head2 getMaxResults ()

Determines the number for MaxResults to create a circular DB with one year's worth of data.
It needs to know the script name and any options *other* than -e and -p that were used.  This
will also need to detect if the job is a cfengine stage1 cron job, based on script name, which
is initially numeric for stage1 jobs.  For testing, this will call another method, to get the
actual crontab entry matching the script name (and options if applicable).  This method can be
'faked' to simply return some hard coded values, without actually reading a crontab.

=cut

sub getMaxResults {
    my $scriptName = shift;
    my $option     = shift; # The value from the command line for '-prod' or '-product', or undef.
}

# This is initially for testing, it will read DATA section, and select a row based on scriptname optional
# hash of options used to start the running script.  I believe the only option of interest is 'product'.
sub _getCrontabEntry
{
    my $scriptName = shift;
    my $option     = shift;
    die "ERROR:  missing required script name\n" unless $scriptName;
    # Add $option to $scriptName if it exists, with required regex text.
    $scriptName .= " .*-prod.*$option" if $option;

    while (<DATA>)
    {
        # Strip off the wrapper/command and arguments, return only the date/time settings.
        /^(.*) .(usr|home).*$scriptName/ && return $1;
    }
}

# match an ops linux username to its service.  Eg monprode will return prodeu.
sub serviceForUser {
    my $user = shift;

    my $service;
    foreach my $svc (sort { length($b) <=> length($a) } ariba::rc::Globals::allServices()) {
        if($user =~ /$svc$/) {
            $service = $svc;
            last;
        }
    }

    return($service);
}

# findSysCmd( str cmd_name ):
# Search the default system paths for the supplied command name.
# (eventually this should probably be broken out ito its own module.)
sub findSysCmd {
    my $cmd = shift;

    # common aliases
    #
    # on CFEngine-managed hosts, these were symlinks in /usr/local/bin/
    # that pointed at the "z" cmds in one of the other system paths.
    #
    # we define both the forward and reverse in the hash for efficiency.
    # otherwise we'd always have to step thru every element via 'while (each ...)'
    # loop to see if $cmd matches either the key or the value.
    my %aliases = (
        # forward
        gznew    => 'znew',
        gzmore   => 'zmore',
        gzgrep   => 'zgrep',
        gzforce  => 'zforce',
        gzdiff   => 'zdiff',
        gzcmp    => 'zcmp',
        gzcat    => 'zcat',

        # reverse
        znew    => 'gznew',
        zmore   => 'gzmore',
        zgrep   => 'gzgrep',
        zforce  => 'gzforce',
        zdiff   => 'gzdiff',
        zcmp    => 'gzcmp',
        zcat    => 'gzcat',
    );

    my $alias = $aliases{$cmd};

    # redefine the search path locally so that we don't interfere with the caller
    local $ENV{'PATH'} = ariba::Ops::Constants::sysCmdSearchPath();

    # would be nice to use File::Which here, but it's only in our perl-5.22.1 distro,
    # so we'll have to use system which to maintain full compatibility.
    my $path = qx(which --skip-alias --skip-functions -- $cmd 2>/dev/null);
    $path ||= qx(which $alias 2>/dev/null) if $alias;
    chomp  $path;
    return $path;
}

1;

# The following is for use with the _getCrontabEntry() function.  Each line translates to a yearly value (rows per year based on frequency):
# hrs  day  wk  yr
# 12 * 24 * 7 * 52 = 104832
# 15 * 24 * 7 * 52 = 131040
#  4 * 24 * 7 * 52 =  34944
#  6 * 24 * 7 * 52 =  52416
#  5 * 24 * 7 * 52 =  43680
#  1 * 24 * 7 * 52 =   8736
#  6 * 24 * 7 * 52 =  52416
# 12 * 24 * 7 * 52 = 104832
#  6 * 24 * 7 * 52 =  52416
#  1 * 24 * 7 * 52 =   8736
# 12 * 24 * 7 * 52 = 104832
# 60 * 24 * 7 * 52 = 524160
#
# The crontab date/time fields are:  minutes hours 'day of month' month 'day of week'

# For Ariba monitoring, the two month fields are not used, so far as I can find.  Generally, the minutes and hours fields are all that are
# used, but in a few cases, I found 'day of week' was also used, for example:
# 15 02 * * 2,3,4,5,6 /usr/local/ariba/bin/crontab-wrapper /home/mondev/Cookies-426/bin/dba/stats-job-status
# The day of the week selected above is Tuesday - Saturday.
# The structure returned from ariba::util::Crontab->new($ENV{LOGNAME}) provides cronjob details via $crontab->{jobs}->{'JOB-NAME'}
# where JOB-NAME is the script being run, for example 'stats-job-status'.  The item at this location is another hash with these keys:
#    'command'  a string
#    'comment'  a string
#    'day'      a sequence of numbers or an *   (day of month)
#    'hour'     a sequence of numbers or an *   (hour)
#    'minute'   a sequence of numbers or an *   (minute)
#    'month'    a sequence of numbers or an *   (month)
#    'name'     a string
#    'weekday'  a sequence of numbers or an *   (day of week)
#
# Processing the cron schedule should follow these steps:
#   1.  check in order:  month weekday day hour minute
#       look for *, single number or sequence of numbers separated by commas

__DATA__
0,5,10,15,20,25,30,35,40,45,50,55 * * * * /usr/local/ariba/bin/crontab-wrapper /home/mondev/Cookies-426/bin/an/document-flux
2,6,10,14,18,22,26,30,34,38,42,46,50,54,58 * * * * /usr/local/ariba/bin/crontab-wrapper /home/mondev/Cookies-426/bin/common/db-conn-status -e -p
7,22,37,52 * * * * /usr/local/ariba/bin/crontab-wrapper /home/mondev/Cookies-426/bin/an/flowExtension
2,12,22,32,42,52 * * * * /usr/local/ariba/bin/crontab-wrapper /home/mondev/Cookies-426/bin/common/integration-of-asp-products -product acm
6,18,30,42,54 * * * * /usr/local/ariba/bin/crontab-wrapper /home/mondev/Cookies-426/bin/acm/acm-status -p -e
0 0 * * * /usr/local/ariba/bin/crontab-wrapper /home/mondev/Cookies-426/bin/aes/auction-counts -e
8,18,28,38,48,58 * * * * /usr/local/ariba/bin/crontab-wrapper /home/mondev/Cookies-426/bin/common/integration-of-asp-products -product aes
2,7,12,17,22,27,32,37,42,47,52,57 * * * * /usr/local/ariba/bin/crontab-wrapper /home/mondev/Cookies-426/bin/aes/jvm-heap-usage -p -e
4,14,24,34,44,54 * * * * /usr/local/ariba/bin/crontab-wrapper /home/mondev/Cookies-426/bin/aes/misc -p -e
45 2 * * * /usr/local/ariba/bin/crontab-wrapper /home/mondev/Cookies-426/bin/common/aggregate-system-packages -o redhat -a x86_64 -v 4.0 -w devlab
3,8,13,18,23,28,33,38,43,48,53,58 * * * * /usr/local/ariba/bin/crontab-wrapper /home/mondev/Cookies-426/bin/common/dataguard-status -e -p -prod an
* * * * * /home/mondev/sre-tools-x/main/create-symlinks.pl

0 22 * * * /usr/local/ariba/bin/crontab-wrapper /home/mondev/Cookies-426/bin/cycle-wof-apps -graceful 50 s2 dev -customer qa_test
15 14 * * * /usr/local/ariba/bin/crontab-wrapper /home/mondev/Cookies-426/bin/an/daily-order-status
15 3 2 * * /usr/local/ariba/bin/crontab-wrapper /home/mondev/Cookies-426/bin/clean-old-files-from-dir -d 60 /var/mon/docroot/perf-detailed-logs
0 0,4,8,12,16,20 * * * /usr/local/ariba/bin/crontab-wrapper /home/mondev/Cookies-426/bin/common/dr-product-status -e
5 0,6,12,18 * * * /usr/local/ariba/bin/crontab-wrapper /home/mondev/Cookies-426/bin/generate-powergraph-index
0 0,2,4,6,8,10,12,14,16,18,20,22 * * * /usr/local/ariba/bin/crontab-wrapper /home/mondev/Cookies-426/bin/an/schedule-task-failure -e -p
15 06 * * 1 /usr/local/ariba/bin/crontab-wrapper /home/mondev/Cookies-426/bin/dba/stats-job-status
15 02 * * 2,3,4,5,6 /usr/local/ariba/bin/crontab-wrapper /home/mondev/Cookies-426/bin/dba/stats-job-status
15 2 2 * * /usr/local/ariba/bin/crontab-wrapper /home/mondev/Cookies-426/bin/clean-old-files-from-dir -d 365 /var/mon/docroot/aql-metrics
0 01 * * * /usr/local/ariba/bin/crontab-wrapper /home/mondev/Cookies-426/bin/auc/auc-comm-content-import-status -e -p
15 1 2 * * /usr/local/ariba/bin/crontab-wrapper /home/mondev/Cookies-426/bin/clean-old-files-from-dir -d 10 /var/mon/docroot -x aql-metrics
44 9 1 * * /usr/local/ariba/bin/crontab-wrapper /home/mondev/Cookies-426/bin/common/aql-metrics -product buyer
0 09 * * * /usr/local/ariba/bin/crontab-wrapper /home/mondev/Cookies-426/bin/dba/db-sequence-check -e -p -prod buyer
0 6 * * 1 /usr/local/ariba/bin/crontab-wrapper /home/mondev/Cookies-426/bin/common/realm-reclaim-status -e -prod buyer
