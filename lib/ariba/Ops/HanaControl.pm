package ariba::Ops::HanaControl;
# vi:et ts=4 sw=4

use strict;

use base qw(ariba::Ops::DatabaseControl);

=head1 NAME

ariba::Ops::HanaControl

=head1 SYNOPSIS

 my $obj = ariba::Ops::HanaControl->new(name => $server_name);


=head1 DESCRIPTION


=cut

use FindBin;
use ariba::rc::Passwords;
use ariba::rc::Utils;
use ariba::Ops::FileSystemUtilsRPC;
use ariba::Ops::HanaClient;
use ariba::rc::CipherStore;
use Carp;

my $MON         = 'mon';
my %HANA_USER;
my %PASSWORD;
my %LANDSCAPE_HOST_CONFIGURATION;
my $LANDSCAPE_HOST_CONFIGURATION_PATH;

my $SAPSERVICES = '/usr/sap/sapservices';

=head1 FUNCTIONS


=cut

=head2 hana_user( %args | Hash ) | Str

Returns the HANA user.
Need to pass in these input parameters: $args{user}, $args{password}, $args{host}.
Caches the result.

=cut


sub hana_user {
	my %args = @_;
	croak "missing user"     if ! $args{user};
	croak "missing password" if ! $args{password};
	croak "missing host"     if ! $args{host};

	if (!$HANA_USER{$args{host}}) {
	    my $cmd = "ssh -t $args{user}\@$args{host} -x cat $SAPSERVICES";
		my $logger = ariba::Ops::DatabaseControl::logger();
	    $logger->debug("run $cmd...");
	    my @output = ();
	    my $ret = ariba::rc::Utils::executeRemoteCommand(
	        $cmd,
	        $args{password},
	        0,
	        undef,
	        undef,
	        \@output
	    );

	    my $hana_user;
	    foreach my $line (@output) {
	        if ($line =~ m|-u\s+(\w+)|) {
	            $hana_user = $1;
	            last;
	        }
	    }
		$HANA_USER{$args{host}} = $hana_user;
	}

	return $HANA_USER{$args{host}};
}

=head2 landscape_host_configuration_path() | Str

Returns the full path to landscapeHostConfiguration.py.
Caches the results.

=cut

sub landscape_host_configuration_path {
	if ( !$LANDSCAPE_HOST_CONFIGURATION_PATH ) {
	    my $bin      = $FindBin::Bin;
	    my $path1    = "$bin/hanautil";
	    my $path2    = "$bin/everywhere/hanautil";
	    my $path3    = "/usr/local/ariba/bin/hanautil";
	    my $filename = 'landscapeHostConfiguration.py';
	    my $script = -x "$path1/$filename" ? "$path1/$filename"
	    		   : -x "$path2/$filename" ? "$path2/$filename"
	    		   :                         "$path3/$filename"
	               ;
	    $LANDSCAPE_HOST_CONFIGURATION_PATH = $script;
	}
	return $LANDSCAPE_HOST_CONFIGURATION_PATH;
}

=head2 serviceFromDBC( $dbc | ariba::Ops::DBConnection ) | Str

Returns the service.

=cut

sub serviceFromDBC {
	my $dbc  = shift;
    return $dbc->product->service();
}

=head2 user( $service | Str ) | Str

Returns the user.

=cut

sub user {
	my $service = shift;
    return $MON . $service;
}

=head2 password( $user | Str, [ $service | Str ] ) | Str

Returns the password.
Need to, at least, pass in the user.
If it can't find the password with the first method,
then you need to pass in the service so it can use the second method.
If you don't know, then you should probably pass in both the $user and the $service.
Caches the results.

=cut


sub password {
	my $user    = shift;
	my $service = shift;
	croak "missing user" if ! $user;

	if (!$PASSWORD{$user}) {
	    my $password;
	    if (ariba::rc::Passwords::initialized()) {
	        $password = ariba::rc::Passwords::lookup($user);
	    }
	    else {
	        my $cipherStore = ariba::rc::CipherStore->new($service);
	        $password = $cipherStore->valueForName($user);
	    }

	    unless ($password) {
	        Carp::croak("Cannot create newFromDbc inside HanaControl.pm as could not get password for '$user'");
	    }

		$PASSWORD{$user} = $password;
	}
	return $PASSWORD{$user};
}

=head2 hana_sid( $hana_user | Str ) | Str

Returns the hana SID.

=cut

sub hana_sid {
	my $hana_user = shift;
	croak "missing hana_user" if ! $hana_user;

    my($hana_sid) = $hana_user =~ m|([a-z0-9]+)adm|;
	return $hana_sid;
}

=head2 landscape_host_configuration( %args | Hash ) | ariba::Ops::HanaControl

Returns an ariba::Ops::HanaControl object.
Need to pass in a bunch of parameters: user, password, host, service, dbc and hana_user.
Can optionally pass in backup.

=cut

sub landscape_host_configuration {
	my %args = @_;
	croak "missing class"     if ! $args{class};
	croak "missing user"      if ! $args{user};
	croak "missing password"  if ! $args{password};
	croak "missing host"      if ! $args{host};
	croak "missing service"   if ! $args{service};
	croak "missing hana_user" if ! $args{hana_user};
	croak "missing dbc"       if ! $args{dbc};
	croak "dbc is not object" if ref($args{dbc}) ne 'ariba::Ops::DBConnection';

    #
    # CAREFUL -- -t is NEEDED since python freaks out without a terminal
    #
    if (!$LANDSCAPE_HOST_CONFIGURATION{$args{host}}) {
	    my $script = landscape_host_configuration_path();
	    my $cmd = "ssh -t $args{user}\@$args{host} -x 'sudo -u $args{hana_user} -i $script'";
		my $logger = ariba::Ops::DatabaseControl::logger();
	    $logger->debug("run $cmd...");
	    my @output = ();
	    my $ret = ariba::rc::Utils::executeRemoteCommand(
	        $cmd,
	        $args{password},
	        0,
	        undef,
	        undef,
	        \@output
	    );

        # RHEL7 hana hosts are returning an empty line, throwing off the assumption (see @p and @q below)
        # that the landscape config header begins on the 1st line. As a quick workaround, let's strip any
        # blank lines prepending the header line.
        shift @output while($output[0] =~ /^\s*$/);

	    my $domain = $args{host};
	    $domain =~ s/^[^\.]+//;
	    my $return;
	    my @slaveHosts;
	    my @standbyHosts;
            #############################Find HANA indexserver actual role index in the returned array######
             chomp($output[0]);
             chomp($output[1]);
             my @p = split(/\s*\|\s*/, $output[0]);
             my @q = split(/\s*\|\s*/, $output[1]);
             my @r;
             my %lh;
             my $hc = 0;
             shift @p;
             shift @q;
             map {$lh{$hc} = $_.shift(@q);$hc++;}@p;
             my ($c) = grep{$lh{$_} =~ m/^IndexServerActual/}keys %lh;
             #######################################################
	    foreach my $line (@output) {
	        $line =~ s/^\|\s+//;
                my ($host, $role) = (split(/\s*\|\s*/, $line))[0,$c];
	        next unless($role =~ /^(?:master|slave|standby)$/);

	        $host .= $domain  unless($host =~ /\.ariba\.com$/);
	        my $instance = $host . "_" . $host;
	        $instance = "DS-" . $instance if $args{backup};

	        my $obj = $args{class}->new($instance);

	        $obj->setClusterRole($role);
	        $obj->setService($args{service});
	        $obj->setHost($args{host});
	        $obj->setUser($args{user});

	        $obj->setIsBackup(1)                          if $args{backup};
	        $obj->setPhysicalReplication(1)               if $args{dbc}->isPhysicalReplication();
	        $obj->setPhysicalActiveRealtimeReplication(1) if $args{dbc}->isPhysicalActiveRealtimeReplication();
	        $obj->setIsSecondary(1)                       if $args{dbc}->isDR();

	        if($role eq 'master') {
	            $return = $obj;
	        }
	        elsif($role eq 'slave') {
	            push(@slaveHosts, $obj);
	        }
	        else {
	            push(@standbyHosts, $obj);
	        }
	    }

	    $return->setSlaveNodes(@slaveHosts);
	    $return->setStandbyNodes(@standbyHosts);

    	$LANDSCAPE_HOST_CONFIGURATION{$args{host}} = $return;
    }

    return $LANDSCAPE_HOST_CONFIGURATION{$args{host}};
}


=head2 newFromDbc( $dbc | ariba::Ops::DBConnection, [ $backup | Bool ] ) | ariba::Ops::HanaControl

Returns an ariba::Ops::HanaControl object using data from the DBConnection object.

=cut

sub newFromDbc {
    my $class  = shift;
    my $dbc    = shift;
    my $backup = shift;

	my $service   = serviceFromDBC($dbc);
	my $user      = user($service);
    my $password  = password($user,$service);
    my $hana_host = $dbc->host();

    # on pacemaker-managed clusters, the VIP is not guaranteed to be accessible when pacemaker inn't
    # actively managing the cluster. and, we keep pacemaker disabled on DR clusters by design. thus,
    # if this is a DR dbc, and it's virtual, then we need to connect using the 1st sorted real host.
    $hana_host = (sort $dbc->realHosts)[0] if $dbc->isDR && $dbc->isVirtual;

    my $hana_user = hana_user(
    	user     => $user,
    	password => $password,
    	host     => $hana_host,
    );

	my $return = landscape_host_configuration(
		class     => $class,
    	user      => $user,
    	password  => $password,
    	host      => $hana_host,
    	service   => $service,
    	backup    => $backup,
    	dbc       => $dbc,
    	hana_user => $hana_user,
	);

	my($hana_sid) = hana_sid($hana_user);
    $return->setSid(uc($hana_sid)) if($hana_sid);
    $return->setAdminID($hana_user);
    foreach my $d ($return->standbyNodes(), $return->slaveNodes()) {
        $d->setSid($hana_sid) if($d && $hana_sid);
    }

    return $return;
}



=head1 METHODS

=cut

#################################################
# if these aren't called anywhere, then delete 'em


=head2 startupOracleSid() | Bool

This actually does a startupHana.

=cut

sub startupOracleSid {
    my $self = shift;

    return $self->startupHana();

}

=head2 shutdownOracleSid() | Bool

This actually does a shutdownHana.

=cut

sub shutdownOracleSid {
    my $self = shift;
    my $abort = shift;
    my $ignoreError = shift;

    return $self->shutdownHana($abort,$ignoreError);


}

=head2 suspendArchiveLogDeletions() | Bool

Prints out a message.
This really doesn't pertain to hana.
Returns TRUE.

=cut

sub suspendArchiveLogDeletions {
    print "Skipping suspension of archive logs deletions on hana\n";
    return 1;
}


=head2 resumeArchiveLogDeletions() | Bool

Prints out a message.
This really doesn't pertain to hana.
Returns TRUE.

=cut

sub resumeArchiveLogDeletions {
    print "Skipping resumption of archive logs deletions on hana\n";
    return 1;
}


=head2 unmountDbFilesystems() | Bool

Prints out a message.
This really doesn't pertain to hana.
Returns TRUE.

=cut

sub unmountDbFilesystems {
    print "Skipping unmounting for hana\n";
    return 1;
}

=head2 mountDbFilesystems() | Bool

Prints out a message.
This really doesn't pertain to hana.
Returns TRUE.

=cut

sub mountDbFilesystems {
    print "Skipping mounting for hana\n";
    return 1;
}

# down to here
#################################################


=head2 dbVersion() | Str

Returns 'UNKNOWN'.

=cut

sub dbVersion {
    my $self = shift;

    return("UNKNOWN"); # temporary for now
}

=head2 isClustered() | Bool

Returns TRUE if there are slaveNodes or standbyNodes.
Otherwise returns FALSE.

=cut

sub isClustered {
    my $self = shift;

    return(scalar($self->slaveNodes()) || scalar($self->standbyNodes()));
}

=head2 slaveNodes() | Array

Returns an array of slave nodes.

=cut

sub slaveNodes {
    my $self = shift;

    my @ret = $self->attribute('slaveNodes');

    return(@ret);
}

=head2 standbyNodes() | Array

Returns an array of standby nodes.

=cut

sub standbyNodes {
    my $self = shift;

    my @ret = $self->attribute('standbyNodes');

    return(@ret);
}

=head2 adminID() | Str

Returns the hana systemdb O/S admin user ID

=cut

sub adminID {
    my $self = shift;
    return ($self->attribute('adminID'));
}

=head2 validAccessorMethods() | HashRef[Str]

Returns a hashref whose keys are the valid accessor methods.

=cut

sub validAccessorMethods {
    my $class = shift;

    my $methodsRef = $class->SUPER::validAccessorMethods();

    $methodsRef->{'slaveNodes'}   = undef;
    $methodsRef->{'standbyNodes'} = undef;
    $methodsRef->{'clusterRole'}  = undef;
    $methodsRef->{'adminID'}      = undef;

    return $methodsRef;
}

=head2 objectLoadMap() | HashRef

Returns a hash ref of objects.

=cut

sub objectLoadMap {
    my $class = shift;

    my %map = (
        'dbFsInfo', '@ariba::Ops::FileSystemUtilsRPC',
        'slaveNodes', '@ariba::Ops::HanaControl',
        'standbyNodes', '@ariba::Ops::HanaControl',
    );

    return \%map;
}

=head2 peerType() | Str

Returns the peerType, which is 'hana'.

=cut

sub peerType {
    return 'hana';
}

=head2 clusterRole() | Str

Returns the clusterRole.

=cut

sub clusterRole {
    my $self = shift;

    return($self->attribute('clusterRole'));
}

=head2 setDbFsInfo() | Undef

Sets some database filesystem information.

=cut

sub setDbFsInfo {
    my $self = shift;
    my $dbc = shift;
    my $includeLogVolumes = shift;
	my $logger = $self->logger();
    $logger->debug("Gathering filesystem details on " . $self->host());
    my ($dbFsRef, @fileSystemInfoForDbFiles) = ariba::Ops::FileSystemUtilsRPC->newListOfVVInfoFromSID($self->host(), $self->host(), $self->service(), $self->isBackup(), $includeLogVolumes, 1);

    $self->SUPER::setAttribute('dbFsInfo', @fileSystemInfoForDbFiles);
    $self->SUPER::setAttribute('dbFsRef', $dbFsRef);

    return 1;
}

=head2 checkFilesystemForOpenFiles() | Bool

Checks file systems for open files.
Returns TRUE if ....
Otherwise returns FALSE.

=cut

sub checkFilesystemForOpenFiles {
    my $self = shift;
    my $ret = 1;

	my $logger = $self->logger();
    foreach my $hanaFs ( $self->dbFsInfo() ) {
        my $fs = $hanaFs->fs();

        #
        # the pipe to cat is so that the exit status is 0 normally
        # since lsof exits with 1 if there is no output
        #
        my $cmd = "/usr/bin/sudo /usr/bin/lsof $fs | /bin/cat";

        my @output;
        $logger->info("Checking for open files on $fs on " . $self->host());

        if( $self->runRemoteCommand($cmd, \@output) ) {
            foreach my $line (@output) {
                chomp($line);
                if($line =~ m|(\d+)\s+\w+\s+cwd\s+DIR.*$fs|) {
                    my $pid = $1;
                    print "INFO: killing $pid with open handle on $fs.\n";
                    my $scmd = "/usr/bin/sudo /usr/bin/kill -9 $pid";
                    unless( $self->runRemoteCommand($scmd) || $self->error() =~ /No such process/ ) {
                        print STDERR "Failed to kill $pid that had open files on $fs:\n\t$line\n";
                        $ret = 0;
                    }
                }
            }
        } else {
            print STDERR "failed to run $cmd for $fs.\n";
            print STDERR "-------------\n",$self->error(),"\n-------------\n";
            $ret = 0;
        }
    }

    return($ret);
}

=head2 shutdownHana() | Bool

Shut down hana.
Returns TRUE if successful.
Otherwise returns FALSE.

=cut

sub shutdownHana {
    my $self = shift;
    my $abort = shift;
    my $ignoreError = shift;
    my $stop = "stop";
    $stop = "-k $stop" if $ignoreError;

    my $admKey = "sysadm_" . (split(/\./,$self->host()))[0];
    my $admid = ariba::Ops::Constants->$admKey();

    my $command = "/usr/local/ariba/bin/hana-control -d -n -s $admid $stop -readMasterPassword";


    return unless $self->runRemoteCommand($command);

    return 1;
}

=head2 startupHana() | Bool

Start up hana.
Returns TRUE if successful.
Otherwise returns FALSE.

=cut

sub startupHana {
    my $self = shift;

    my $admKey = "sysadm_" . (split(/\./,$self->host()))[0];
    my $admid = ariba::Ops::Constants->$admKey();

    my $command = "/usr/local/ariba/bin/hana-control -d -k -n -s $admid start -readMasterPassword";

    return unless $self->runRemoteCommand($command);

    return 1;
}

=head2 onlineOfflineDisks( $command | Str ) | Bool

Run either the online or offline command.
Returns TRUE if successful.
Otherwise returns FALSE.

=cut

sub onlineOfflineDisks {
    my $self = shift;
    my $command = shift;

    return unless $command =~ /^(offline|online)$/;

    if ($command eq 'offline') {
        print "Skipping offline disks for hana\n";
        return 1;
    }

    $command = "sudo /usr/bin/rescan-scsi-bus.sh";

    return unless $self->runRemoteCommand($command);

    return 1;

}

1;
