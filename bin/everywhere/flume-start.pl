#!/usr/local/bin/perl -w

use strict;
use lib qw(/usr/local/ariba/lib);
use POSIX qw(setsid);
use ariba::Ops::ProcessTable;
use ariba::Ops::Constants;
use ariba::rc::Utils;

my $debug = 0;
my $java = "/usr/j2sdk1.7.0_25_x86_64/bin/java";
my $logsDir;
eval { $logsDir= ariba::Ops::Constants->flumeKrDir() };
$logsDir ||= "/tmp";
my $pidFile = "$logsDir/keepRunning-flume-tail-agent.pid";


sub main {

    die "Usage $0 [-start|-stop|-restart] -d" if ( @ARGV && @ARGV > 2 );
    
    my $logFile = "/var/tmp/flume-start.log";
    open LOG, ">> $logFile" or die "Unbale to OpenLog File $logFile\n";
    my $mode = shift(@ARGV);
    my $arg = shift(@ARGV);

    $debug = 1 if ( $arg && $arg eq "-d") ;
    
    print "mode is $mode\n" if ( $ debug );

    if ( $mode eq "-start") {
        start();
    }
    elsif ($mode eq "-stop") {
        stop();
    }
    elsif ($mode eq "-restart") {
        restart();
    } else {
        die "The only allowed modes are -start -stop and -restart\n";
    }

}


sub start {
    my $rotateInterval = 24 * 60 * 60; # 1 day;
    my $flag = ""; 
    my $pid = isPortListening($flag);
    my $ctime = localtime; 
    chomp($pid);
    if ( $pid ){
        ## Now check Jolokia listening on Port
        if(isJolokiaListeningOnPort($pid, $flag)) {
            print LOG "$ctime DEBUG: Jolokia Process is already Running \n";
            print "$ctime DEBUG: Jolokia Process is already Running \n", if $debug;
            exit;
        }
        else {
            print LOG "$ctime DEBUG: Port 7777 is listening for other process so just killing if any process is running jolokia-jvm before we start the process\n";
            print "$ctime DEBUG: Port 7777 is listening for other process so just killing if any process is running jolokia-jvm before we start the process\n", if $debug;
            killJolokia(); 
        }
    }

    else {
        print LOG "$ctime DEBUG: Port 7777 is not listening for any process so just killing if any process is running jolokia-jvm before we start the process \n";
        print "$ctime DEBUG: Port 7777 is not listening for any process so just killing if any process is running jolokia-jvm before we start the process \n", if $debug;

        killJolokia(); 
    }

    unless ( -e $logsDir && -d $logsDir) {
        ariba::rc::Utils::mkdirRecursively($logsDir);
    } 

    sleep(3); ##wait 3 secound after killing the process to release/shutdown the port proeprly 

    launchCommandFeedResponses("/usr/local/ariba/bin/keepRunning-ops -m -w -kp $java -Xms256m -Xmx1024m -Xss256m -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=$logsDir -XX:+UseParNewGC -XX:+UseConcMarkSweepGC -Dflume.root.logger=WARN,console -javaagent:/usr/local/flume/TailAgent/lib/jolokia-jvm-1.3.0-agent.jar=port=7777,host=0.0.0.0,agentContext=/hsim  -Dcom.sun.management.jmxremote -Dcom.sun.management.jmxremote.port=4005 -Dcom.sun.management.jmxremote.authenticate=false -Dcom.sun.management.jmxremote.ssl=false -Dcom.sun.management.jmxremote.local.only=false -cp /opt/apache-flume-1.5.2/conf:/usr/local/flume/TailAgent/lib/*:/opt/apache-flume-1.5.2/lib/* -Djava.library.path= org.apache.flume.node.Application --conf-file /usr/local/flume/TailAgent/conf/flume-conf.properties --no-reload-conf --name agent -ks $rotateInterval -ki -kn flume-tail-agent -kl $logsDir");

    sleep(3); ## wait for 3 secound before checking that port is listening for the process we started through launchCommandFeedResponses or not 
    $flag = "CHECKING"; 
    my $portNo = isPortListening($flag);
    $ctime = localtime; 
    print "$ctime VALIDATION port is listening for process ID $portNo \n", if $debug ;
    print LOG "$ctime VALIDATION port is listening for process ID $pid \n"; 

    my $jolokiaRunning = isJolokiaListeningOnPort($portNo, $flag);
    if ($jolokiaRunning){
        print LOG "$ctime VALIDATION Flume agent started \n";
        print "$ctime VALIDATION Flume agent started \n" if ( $debug );
    }
    else {
        print LOG "$ctime VALIDATION Jolokia Process did not started properly.\n";
        print "$ctime VALIDATION Jolokia Process did not started properly.\n";
    } 

}

sub stop {
    killJolokia()
}

sub restart {
    stop();
    sleep(3);
    start();

}


sub launchCommandFeedResponses {
    # This sub is coming from Startup/Common.pm

    my $cmd = shift;
    my @responses = @_;

    #
    # if we need to feed something to the command we are launching
    # fork a process and have the child process feed in the
    # reponses to the launched command (over stdin).
    #
    # we also dissociate the child from the terminal to prevent the
    # launched command from dumping all over the terminal and that
    # actually causes problems with ssh
    #
    unless (my $pid=fork) { # child
        open STDIN, '/dev/null';
        open STDOUT, '>/dev/null';
        setsid();
        open STDERR, '>&STDOUT';
        open(CMD, "| $cmd") || die "ERROR: failed to launch [$cmd], $!";

        select(CMD);
        $| = 1;

        #
        # feed the command everything we need to feed it on
        # stdin.
        #
        for my $response (@responses) {
            print CMD "$response\n";
        }

        #close(CMD); # don't do this, this will cause this process
                     # to hang until child has finished, which is
                     # never in our case.
        exit(0);
    }
}

sub isPortListening {
    my $flag = shift;
    my $pid = `lsof -i :7777 | awk '\$2 !~ /PID/ {print \$2}'`;
    my $ctime = localtime; 

    if (($pid =~ /^\d+$/)) {
        print LOG "$ctime $flag DEBUG: Port 7777 is listening for $pid\n";
        print "$ctime $flag DEBUG: Port 7777 is listening for $pid\n", if ( $debug );

        return $pid
    }
   
   else {
       print LOG "$ctime $flag DEBUG: Port 7777 is not listening\n";
       print "$ctime $flag DEBUG: Port 7777 is not listening\n", if ( $debug );

       return 0;
   }

}

sub killJolokia {
    my $ctime = localtime; 

    print LOG "$ctime DEBUG: killJolokia subroutine called \n";
    print "$ctime DEBUG: killJolokia subroutine called \n", if $debug;

    my $pt = ariba::Ops::ProcessTable->new();
    my $jolokiaProcess = 1 if( $pt->processWithNameExists( 'jolokia-jvm' ) );

    print LOG "$ctime Killing Jolokia Process.....\n", if ( $jolokiaProcess );
    print "$ctime Killing Jolokia Process.....\n", if ($debug && $jolokiaProcess );

    $pt->killProcessesWithName('jolokia-jvm'), if $jolokiaProcess;

}

sub isJolokiaListeningOnPort{
    my $pid = shift; ##  Port 7777 listening for process id $Pid
    my $flag = shift;
    my $ctime = localtime; 
    chomp($pid);

    print LOG "$ctime $flag Port 7777 is listening for $pid \n";
    print "$ctime $flag Port 7777 is listening for $pid \n", if $debug;

    my $pt = ariba::Ops::ProcessTable->new();
    my $jolokiaPids = ( join ("|", ($pt->pidsForProcessName('jolokia-jvm'))) );   

    print LOG "$ctime $flag DEBUG: Jolokia PID ", $jolokiaPids, "\n";
    print "$ctime $flag DEBUG: Jolokia PID ", $jolokiaPids, "\n", if $debug;

    if ($pid =~ /$jolokiaPids/) {
        print LOG "$ctime $flag DEBUG: Port 7777 is listening for jolokia-jvm process id $jolokiaPids\n"; 
        print "$ctime $flag DEBUG: Port 7777 is listening for jolokia-jvm process id $jolokiaPids\n", if $debug; 

        return 1;
    }

    else {
        print LOG "$ctime $flag DEBUG: Port 7777 is not listening for jolokia-jvm process id $jolokiaPids\n";
        print "$ctime $flag DEBUG: Port 7777 is not listening for jolokia-jvm process id $jolokiaPids\n", if $debug;
        return 0;
    } 
}

main;
