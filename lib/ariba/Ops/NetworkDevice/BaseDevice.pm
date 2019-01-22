# $Id: //ariba/services/tools/lib/perl/ariba/Ops/NetworkDevice/BaseDevice.pm#18 $

package ariba::Ops::NetworkDevice::BaseDevice;

use strict;
use Expect;

use base qw(ariba::Ops::PersistantObject);

use ariba::Ops::NetworkUtils;
use ariba::SNMP::Session;
use ariba::rc::Passwords;
use ariba::rc::Utils;

# need at least this expect version
Expect::version(1.11);

# Class methods

sub accessPassword {
    my $self = shift;

    return($self->attribute('accessPassword')) if($self->attribute('accessPassword'));

    return(undef) if($self->noPassword());

    my $machine = ariba::Ops::Machine->new($self->hostname());
    return(undef) unless($machine);

    my $lookup = $machine->os() . "Password";

    my $password = ariba::rc::Passwords::lookup($lookup);

    return($password);
}

sub newFromMachine {
    my $class    = shift;
    my $machine  = shift;
    my $proxy    = shift;

    my $hostname = $machine->hostname();

    my $self     = $class->SUPER::new($hostname);

    if($proxy) {
        $self->setProxyHost($machine->proxyHost());
        $self->setProxyPort($machine->proxyPort());
    }

    $self->setHostname($hostname);
    $self->setShortName( ariba::Ops::NetworkUtils::fqdnToShortHostname($hostname) );
    $self->setCommunity( $machine->snmpCommunity() );
    $self->setDatacenter( $machine->datacenter() );
    $self->setIp( $machine->ipAddrAdmin() );

    $self->setSendCR(1);

    $self->setMachine($machine);
    $self->setSnmp( ariba::SNMP::Session->newFromMachine($machine) );

    $self->snmp()->setEnums(1);

    return $self;
}

# No backing store
sub dir {
    return undef;
}

# Instance methods

sub DESTROY {
    my $self = shift;

    $self->disconnect();
}

sub setDebug {
    my $self  = shift;
    my $debug = shift;

    if ($debug && $debug > 1) {
        $Expect::Log_Stdout   = 1;
        $Expect::Exp_Internal = 1;
        $Expect::Debug        = 1;
    }

    $self->SUPER::setDebug($debug);
}

sub connect {
    my $self = shift;

    # No-op if we're already connected.
    return 1 if $self->handle();

    if ( $self->routeServerWithLogin() ) {
        return $self->telnetToDevice();
    }

    if (!defined $self->accessPassword() && !$self->noPassword()) {
        warn "accessPassword() is not set - you must set it before calling connect()\n";
        return;
    }

    if ( $self->machine->useSsh() ) {
        return $self->sshToDevice();
    } else {
        return $self->telnetToDevice();
    }
}

sub disconnect {
    my $self = shift;

    $self->setInEnableMode(0);

    if ($self->handle()) {
        my $pid = $self->handle()->pid();
        kill(9, $pid) if $pid;
        $self->setHandle(undef);
        $self->deleteHandle();
    }
}

sub telnetToDevice {
    my $self     = shift;

    my $telnetTo = $self->proxyHost() || $self->ip() || $self->hostname();
    my $telnetPort = $self->proxyPort() || 23;

    if ($self->debug()) {
        printf("Host: [%s] logging in via telnet, username: [%s]\n", $self->hostname(), $self->loginName());
    }

    my $password;

    if ($self->routeServerWithLogin()) {
        $password = 'Rviews';
    } else {
        $password = $self->accessPassword();
    }

    my $command  = sprintf('telnet %s %d', $telnetTo, $telnetPort);

    my $telnet   = Expect->spawn($command) or die sprintf("Spawn of command $command failed for host: %s: $!", $self->hostname());

    $telnet->log_stdout(0);

    # some hosts netapp, css, want a username
    if ($self->loginName()) {
        my $expectTimeout = 10;
        #
        # wait longer for the proxy
        #
        $expectTimeout = 240 if($self->proxyHost());
        $telnet->expect($expectTimeout, '-re', '(ogin|name):', 'onnection refused');

        if($telnet->exp_match() =~ /onnection refused/) {
            return(undef);
        }

        $telnet->send(sprintf("%s\n", $self->loginName()));
    }

    my $commandPrompt  = $self->commandPrompt();
    my $passwordPrompt = $self->passwordPrompt();

    unless ($self->noPassword()) {
        my $expectTimeout = 30;
        #
        # wait longer for the proxy
        #
        $expectTimeout = 240 if($self->proxyHost());
        $telnet->expect($expectTimeout, '-re', $passwordPrompt);

        my $savedInternal = $telnet->exp_internal();
        $telnet->exp_internal(0);
        $telnet->send("$password\r");
        $telnet->exp_internal($savedInternal);
    }

    my @promptMatches = ();

    push(@promptMatches, $commandPrompt);
    push(@promptMatches, $passwordPrompt) unless $self->noPassword();

    my $expectTimeout = 30;
    #
    # wait longer for the proxy
    #
    $expectTimeout = 240 if($self->proxyHost());
    $telnet->expect($expectTimeout, '-re', @promptMatches);

    if ( (!$self->noPassword() && $telnet->exp_match() =~ m/$passwordPrompt/i)
        || $telnet->exp_error()
        || $telnet->exp_match() !~ m/$commandPrompt/i ) {

        # failed to log in
        # this is a workaround so we can exit fast
        # instead of waiting for the destructor to wait 20 secs
        my $pid = $telnet->pid();
        kill(9, $pid) if $pid;

        return undef;
    }

    #
    # save the actual returned prompt -- this matches WITHOUT regex patterns
    # we use this to exclude it from diffs in config differ
    #
    $self->setActualCommandPrompt($telnet->exp_match());

    $self->setHandle($telnet);

    return 1;
}

sub sshToDevice {
    my $self     = shift;

    if ($self->debug()) {
        printf("Host: [%s] logging in via ssh, username: [%s]\n", $self->hostname(), $self->loginName());
    }

    my $password = $self->accessPassword;
    my $hostname = $self->ip() || $self->hostname();
    my $port = $self->port() ? '-p ' . $self->port() : '';
    my $sshPath = ariba::rc::Utils::sshCmd();

    my $command  = sprintf('%s -q -c des %s@%s %s', $sshPath, $self->loginName(), $hostname, $port);

    my $ssh;

    # Establishing a connection can be flaky. Try up to 5 times to connect.
    my $tryCount = 0;
    my $errorStatus = 1;
    while ( $tryCount++ < 5 && $errorStatus ) {
        if ( $tryCount > 1 ) {
            # If $tryCount > 1 then our previous connection attempt has failed.
            # Clean up the previous connection and try again.
            $self->disconnect();
            print "Connection failed.  Trying connection attempt $tryCount\n" if $self->debug();
        }

        $ssh = Expect->spawn($command) or die sprintf("Spawn of command $command failed for host: %s: $!", $self->hostname());
        $ssh->log_stdout(0);

        if ( $self->machine->useSsh() == 2 ) {
            #
            # this ssh server is brain dead and ignores username@host
            #
            $ssh->expect(60,
                '-re', 'yes/no', sub {
                    $ssh->send("yes\r");
                    exp_continue;
                },
                '-re', '(ogin|name):', sub {
                        $ssh->send( $self->loginName() );
                        $ssh->send( "\r" );
                        exp_continue;
                },
                '-re', $self->passwordPrompt()
            );
        } else {
            $ssh->expect(60,
                '-re', 'yes/no', sub {
                    $ssh->send("yes\r");
                    exp_continue;
                },
                '-re', $self->passwordPrompt()
            );
        }

        my $savedInternal = $ssh->exp_internal();
        $ssh->exp_internal(0);
        $ssh->send("$password\r");
        $ssh->exp_internal($savedInternal);

        # 4th arg is a second match to make.  We're looking for a valid command line prompt.
        # This is the bit that can be flaky.  Sometimes we get an invalid EOF returned.
        $ssh->expect(60,
            '-re', 'Terminal type', sub {
                $ssh->send("\r");
                exp_continue;
            },
            '-re', $self->commandPrompt(), $self->passwordPrompt());
        $errorStatus = $ssh->error();
    }

    if ($ssh->exp_match() =~ $self->passwordPrompt() || $ssh->exp_error()) {

        # this is a workaround so we can exit fast
        # instead of waiting for the destructor to wait 20 secs
        my $pid = $ssh->pid();
        kill(9, $pid) if $pid;

        return undef;
    }

    #
    # save the actual returned prompt -- this matches WITHOUT regex patterns
    # we use this to exclude it from diffs in config differ
    #
    $self->setActualCommandPrompt($ssh->exp_match());

    $self->setHandle($ssh);

    return 1;
}

sub sendCommand {
    my $self    = shift;
    my $command = shift;
    my $prompt1 = shift || $self->commandPrompt();
    my $prompt2 = shift || $prompt1;
    my $timeoutForCommandOutput = shift || 90;
    my $dontRetry = shift;

    if ($self->debug()) {
        printf("DEBUG - running command: [%s] on host: [%s] expecting prompt1: [%s], prompt2: [%s]\n",
            $command, $self->hostname(), $prompt1, $prompt2
        );
    }

    unless (defined $self->handle()) {

        printf("No handle for connection to: %s\n", $self->hostname());
        print "Have you called ->connect() ?\n";
        $self->setError("No handle for connection to ", $self->hostname());
        return;
    }

    #
    # if our handle has exited, then we need to reconnect.
    #
    if(defined($self->handle()->exitstatus())) {
        print "reconnecting because handle is closed.\n" if($self->debug());
        $self->setHandle(undef);
        $self->connect();
    }

    # Some things - such as passsword changing, we don't want to send another \r
    if ($self->sendCR()) {

        # removing this line is a hack to fix bogus ssh behavior on pix
        $self->handle()->send("\r");
    }

    my ($matched_pattern_position, $error, $successfully_matching_string, $before_match, $after_match) = $self->handle()->expect(30, '-re', $prompt1, '-re', $prompt2);

    if ($error) {
        $self->setError("expect: got $error waiting for $prompt1");
        return $self->handle()->exp_before();
    }

    $self->handle()->send("$command\r");

    ($matched_pattern_position, $error, $successfully_matching_string, $before_match, $after_match) = $self->handle()->expect($timeoutForCommandOutput, '-re', "\r\n?$prompt1", '-re', "\r\n?$prompt2");

    #
    # check handle again... if the command fails because we lost connection,
    # and we don't notice until now, then  we need to try again here.
    #
    if(!$dontRetry && $error && $self->handle->exitstatus()) {
        #
        # don't login again when we INTENTIONALLY logged out.
        #
        if($command !~ /^\s*exit\s*$/) {
            print "reconnecting because handle is closed.\n" if($self->debug());
            $self->setHandle(undef);
            $self->connect();
            return($self->sendCommand($command, $prompt1, $prompt2, $timeoutForCommandOutput, 1));
        }
    }

    if ($error) {
        $self->setError("expect: got $error running $command");
    }

    return $self->handle()->exp_before();
}

sub getConfig {
    my $self      = shift;
    my $timeout   = shift;

    my $shortName = $self->shortName();
    my @config    = ();

    $self->enable();

    my $output = $self->sendCommand( $self->configCommand(), $self->enablePrompt(), undef, $timeout );

        for my $line (split /\n/, $output) {

        return if $line =~ m/Bad secrets/;
        return if $line =~ m/Sorry/i;

        unless ($line =~ m/(^This command shows)/io ||
            $line =~ m/(^Use \'write terminal all\')/io ||
            $line =~ m/(^\.+)|(^\s+$)/o ||
            $line =~ m/^(?:[# ])?write term/o ||
            $line =~ m/^Screen length for this session/o ||
            $line =~ m/^(\d+)/o ||
            $line =~ m/^Enter password:/io ||
            $line =~ m/(^Building configuration)/io ||
                        $line =~ m/(^Current configuration)/io ||
                        $line =~ m/(^\[OK\])|(^\s+$)/o ||
                        $line =~ m/^$shortName/ ||
                        $line =~ m/^show run/o ||
                        $line =~ m/^Password:/io
        ) {
            $line =~ s/\r//;
            $line =~ s/\s*$//g;
            push (@config, $line);
        }
    }

    return join("\n", @config);
}

#
# subclasses should override these when needed.
#

sub passwordPrompt {
    my $self = shift;

    return 'assword: ';
}

sub commandPrompt {
    my $self = shift;

    if ($self->hostname() =~ /\.procuri.com/) {
        my $name = $self->shortName();
        return sprintf('(%s|%s)\*?[>#]', $name, uc($name));
    } else {
        my $datacenter = $self->datacenter() || "";
        return sprintf('%s(_%s)?\*?[>#]', $self->shortName(), $datacenter);
    }
}

sub enablePrompt {
    my $self = shift;

    if ($self->hostname() =~ /\.procuri.com/) {
        my $name = $self->shortName();
        return sprintf('(%s|%s)#', $name, uc($name));
    } else {
        my $datacenter = $self->datacenter() || "";
        return sprintf('%s(_%s)?#', $self->shortName(), $datacenter);
    }
}

sub configTermPrompt {
    my $self = shift;

    # Expect needs ()'s either escaped, or using .'s
    return sprintf('%s.config(-line)?.#', $self->shortName());
}

sub configCommand {
    my $self = shift;

    return 'show run'
}

# get to the enable prompt.
sub enable {
    my $self = shift;

    return if $self->inEnableMode();

    my $passwd = $self->enablePassword();

    unless ($passwd) {
        warn "enablePassword() is not set - you must set it before calling enable()\n";
        return 0;
    }

    $self->sendCommand("en\r$passwd", $self->commandPrompt(), $self->enablePrompt());
    $self->setInEnableMode(1);

    return 1;
}

#
# MCL tool calls this -- why we need two calls for this is rooted in old
# design -- you see, the inserv.pm has this instead of overriding sendCommand(),
# so the MCL tool needs to call that to work with inserv -- and other devices
# now need this to have parameters and return values that look like inserv.pm
#
# ain't it lovely?
#
sub _sendCommandLocal {
    my ($self, $commandString, $timeout, $configPrompt) = (@_);
    my @output;

    $self->connect();

    $self->setError("");
    my $outputText = $self->sendCommand($commandString, undef, $configPrompt, $timeout);

    if($self->error()) {
        return(@output);
    }

    my $commandStringForMatch = quotemeta($commandString);

    for my $line (split(/\r?\n/, $outputText )) {
        #
        # our command gets echoed back to us
        # and sometimes it gets split over 2 lines.
        #
        $line =~ s|\r*$||;
        next if ($line =~ /$commandStringForMatch/);
        my $lineToMatch = quotemeta($line);
        next if ($commandString =~ /$lineToMatch/);

        push(@output, $line);

        if ($self->debug() && $self->debug() >= 2) {
            print "[$line]\n";
        }

        $self->logMessage($line);
    }

    return(@output);
}

1;

__END__
