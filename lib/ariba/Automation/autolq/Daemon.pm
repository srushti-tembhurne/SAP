package ariba::Automation::autolq::Daemon;

#
# Auto LQ Daemon
#

use strict 'vars';
use warnings;
use Carp;
use CGI;
use Data::Dumper;
use File::Copy;
use HTTP::Daemon;
use HTTP::Status;
use dmail::LockLib;
use ariba::Automation::autolq::Errors;

$SIG{'CHLD'} = "IGNORE";
$SIG{'PIPE'} = 'IGNORE';

#
# Path to lockfile
# TODO: Change path to /home/rc/etc/autolq/
#
my $LOCKFILE_DIR = "/home/rc/etc/autolq"; 

#
# Path to qual-manager-controller script
# TODO: Change path to /home/rc/bin
#
my $QUAL_MANAGER_CONTROLLER = "/home/rc/bin/everywhere/qual-manager-controller";

#
# Increment this as the program is changed, allows us to deal with
# backwards compatibility or outdated clients
#k
my $VERSION = "1.0";

#
# TODO: Enable this line. Right now the debug output is useful.
#
# dmail::LockLib::forceQuiet();

#
# Dispatch table
#
my %DISPATCH_TABLE = 
(
    'server/status' => "handle_server_status",
    'qual/start' => "start_qual_manager", 
);

#
# Built-in commands
#
my %CONVENIENCES = 
(
    "_all" => 
        [
        "echo test",
        ],
);

#
# Attribute defaults
#
my %DEFAULTS = 
(
    'version' => $VERSION,
    'running' => 1,
    'verbose' => 1,
    'port' => 46601,
    'pidfile' => '/tmp/robotd.pid',
    'errorlog' => '/tmp/robotd.log',
);

#
# Constructor
#
sub new
{
    my ($caller, %arg) = @_;
    my $caller_is_obj = ref($caller);
    my $class = $caller_is_obj || $caller;
    my $self = bless {}, $class;

    foreach my $key (keys %DEFAULTS)
    {
        $self->{$key} = $arg{$key} || $DEFAULTS{$key};
    }

    $self->{'uptime'} = time();

    return $self;
}

#
# Show debug line with pid and timestamp
#
sub debug
{
    my ($self, $msg) = @_;
    print "[$$] " . localtime (time()) . " <daemon> $msg\n";
}

#
# Write event to error log
#
sub log_error
{
    my ($self, $msg) = @_;
    return $self->log_event ($msg, $self->{'errorlog'});
}

#
# Write event to specified logfile with timestamp, version, process id
#
sub log_event
{
    my ($self, $msg, $logfile) = @_;

    $msg = $msg || "";

    if ($msg)
    {
        if (open FILE, ">>$logfile")
        {
            print FILE "" . localtime (time()) . " $VERSION $$ $msg\n";
            close FILE;
        }
    }
    else
    {
        carp "Won't log empty message to $logfile";
        return;
    }

    if ($self->{'verbose'})
    {
        carp $msg;
    }
}

#
# Write process id to file
#
sub write_pid
{
    my ($self) = @_;
    my $tmp = $self->{'pidfile'} . ".tmp";
    my $fail = 0;

    if (open FILE, ">$tmp")
    {
        print FILE "$$\n";
        if (! close FILE)
        {
            $self->log_error ("Can't close pidfile $tmp: $!");
            $fail = 1;
        }
    
        if (! move ($tmp, $self->{'pidfile'}))
        {
            $self->log_error ("Can't move pidfile $tmp to " . $self->{'pidfile'} . ": $!");
            $fail = 1;
        }
    }
    else
    {
        $self->log_error ("Can't write temporary pidfile $tmp: $!");
        $fail = 1;
    }
    unlink $tmp if $fail;
}

#
# Main loop
#
sub run
{
    my $self = shift;

    $self->write_pid();

    $self->debug ("Auto LQ Daemon starting up");

    # make new daemon to listen on port
    $self->{'daemon'} = HTTP::Daemon->new 
    (
        LocalPort => $self->{'port'},
        ReuseAddr => 1, 
    );

    #
    # Something's already listening on this port _or_ the requested
    # port number is too low for a non-root user
    #
    if (! $self->{'daemon'})
    {
        $self->log_error ("Can't listen on port " . $self->{'port'} . ", $!");
        return 0;
    }

    $self->debug ("Listening on port $$self{'port'}");

    #
    # Handle new connection
    #
    while ($self->{'running'})
    {
        my $connection = $self->{'daemon'}->accept or next;

        #
        # Fork!
        #
        $self->debug ("Handling connection via fork");
        next if fork;
        $self->debug ("Forked");
        
        #
        # Handle command
        #
        $self->execute ($connection);
    }
}

#
# Call handler after fork
#
sub execute
{
    my ($self, $connection) = @_;

    # 
    # Handle each request as it arrives
    #
    while (my $request = $connection->get_request) 
    {
        $self->handle_request ($connection, $request);
    }
    $connection->close;
    undef ($connection);
    exit (0);
}

#
# Handle request
#
sub handle_request
{
    my ($self, $connection, $request) = @_;
    
    #
    # Convert raw HTTP query into CGI object
    #
    my $cgi = new CGI ($request->url->query);

    #
    # Extract URI from URI
    #
    my ($uri) = $request->url->path =~ m#^/(.*)$#;
    $self->debug ($uri);
    my $output = "UNKNOWN COMMAND: $uri\n";

    #
    # Check dispatch table for associated subroutine
    #
    if (exists $DISPATCH_TABLE{$uri})
    {
        my $method = $DISPATCH_TABLE{$uri};
        $self->debug ("Calling method $method");
        $output = $self->$method ($connection, $request, $cgi);
        $self->debug ("$method returned $output");
    }

    #
    # Send HTTP response
    #
    my $response = new HTTP::Response (RC_OK);
    $response->content ("$output\n");
    $connection->send_response ($response);
	$connection->force_last_request;
	$connection->close;
	undef ($connection);
}

#
# Command harness
#
sub execute_commands
{
    my ($self, $command) = @_;
    my @commands;

    foreach my $set ("_all", $command)
    {
        push @commands, @{$CONVENIENCES{$set}};
    }

    my @output;

    foreach my $cmd (@commands)
    {
        push @output, $self->control ($cmd);
    }
    return "" . (join "\n", @output) . "\n";
}

#
# Run program, return output
#
sub control
{
    my ($self, $command) = @_;
    if ($self->{'verbose'})
    {
        $self->debug ($command);
        system ($command);
        return ();
    }
    my $output = qx{$command 2>&1};
    $output = $output || "";
    my @output = split /\n/, $output; 
    return @output;
}

#
# Generate path to lockfile from product/release/service
#
sub make_lockfile
{
    my ($self, $deployment) = @_;
    my $lockfile = $LOCKFILE_DIR . "/" . "qual-manager-controller.$deployment";
    return $lockfile;
}

#
# Server commands
#
sub handle_server_status
{
    my ($self, $connection, $request, $cgi) = @_;
    my $now = localtime ($self->{'uptime'});
	my $response = new HTTP::Response (RC_OK);
	$response->content ("Version: $VERSION\nUptime: $now\n");
	$connection->send_response ($response);
	$connection->close;
	undef ($connection);
	return 0;
}

#
# Open lockfile, extract pid
#
sub fetch_pid_from_lockfile
{
    my ($self, $lockfile) = @_;
    
    if (open LOCKFILE, $lockfile)
    {
        my $pid = <LOCKFILE>;
        close LOCKFILE;
        chomp $pid;
        return $pid;
    }

    0;
}

#
# Run the qual manager
#
sub start_qual_manager
{
    my ($self, $connection, $request, $cgi) = @_;
    
    #
    # Extract arguments from CGI object
    #
    my ($deployment) = $cgi->param('deployment') =~ m#^([-A-Z_0-9]+)$#i;
	my ($user) = $cgi->param('user');

    # 
    # Set to blank defined values if caller failed to provide them
    #
    $deployment = $deployment || "";
    
    # 
    # Arguments mangled, can't continue
    #
    if (! $deployment)
    {
        return ariba::Automation::autolq::Errors::mangled_args();
    }

    #
    # Get a lockfile for this product/release/service
    #
    my $lockfile = $self->make_lockfile ($deployment);

    #
    # See if something's using this lock already
    #
    my $pid = $self->fetch_pid_from_lockfile ($lockfile);

    #
    # Oh something's there...
    #
    if ($pid)
    {
        #
        # Is it still alive?
        #
        if (kill (0, $pid))
        {
            #
            # Yup, something's running...
            #
            $self->debug ("Fail: LQ already running via pid $pid");
            return ariba::Automation::autolq::Errors::locked();
        }
    }

    # 
    # Fork to run the qual manager controller script
    #
    if (! fork)
    {
		$connection->close;
		undef ($connection);

        $self->debug ("<forked> Starting qual manager...");

        #
        # Generate arguments to script
        #
        my @cmd = 
        (
            $QUAL_MANAGER_CONTROLLER,
            "--pid", $lockfile, 
            "--deployment", $deployment,
            "--readmpf",
			"--user", $user,
        );
        my $cmd = join " ", @cmd;

        #
        # Run the command
        #
        $self->debug ($cmd);
        open (CMD, "| $cmd");
        close CMD;
        
        # All done
        #
        exit (0);
    }
    #
    # Meanwhile, back in the parent process...
    #
    $self->debug ("<parent> done");
	return ariba::Automation::autolq::Errors::ok();
}

1;
