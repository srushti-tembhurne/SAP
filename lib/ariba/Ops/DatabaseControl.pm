package ariba::Ops::DatabaseControl;
use strict;
use base qw(ariba::Ops::PersistantObject);

INIT {
        ariba::Ops::PersistantObject->enableSmartCache();
}

=head1 NAME

ariba::Ops::DatabaseControl

=head1 SYNOPSIS

 use base qw(ariba::Ops::DatabaseControl);

=head1 DESCRIPTION

The base class for, at least right now, ariba::Ops::OracleControl and ariba::Ops::HanaControl.

=cut

use ariba::Ops::PersistantObject;
use ariba::rc::Passwords;
use ariba::Ops::Logger;


my $BACKING_STORE = undef;

=head1 METHODS

=head2 logger() | ariba::Ops::Logger

Returns the logger object.

=cut

sub logger {
	return ariba::Ops::Logger->logger();
}

=head2 validAccessorMethods() | HashRef[Str]

Returns a hashref whose keys are the valid accessor methods.

=cut

sub validAccessorMethods {
        my $class = shift;

        my $methodsRef = $class->SUPER::validAccessorMethods();

        $methodsRef->{'debug'} = undef;
        $methodsRef->{'isSecondary'} = undef;
        $methodsRef->{'error'} = undef;
        $methodsRef->{'sid'} = undef;
        $methodsRef->{'host'} = undef;
        $methodsRef->{'user'} = undef;
        $methodsRef->{'dr'} = undef;
        $methodsRef->{'physicalReplication'} = undef;
        $methodsRef->{'physicalActiveRealtimeReplication'} = undef;
        $methodsRef->{'dbFsInfo'} = undef;
        $methodsRef->{'dbFsRef'} = undef;
        $methodsRef->{'isBackup'} = undef;
        $methodsRef->{'service'} = undef;
        $methodsRef->{'testing'} = undef;

        return $methodsRef;
}

=head2 dir() | Str

Returns the directory.

=cut

sub dir {
    my $class = shift;
    return $BACKING_STORE;
}

=head2 setDir() | Str

Sets the directory.

=cut

sub setDir {
    my $class = shift;
    $BACKING_STORE = shift;
}

=head2 setDebug() | Str

Sets the debug level.

=cut

sub setDebug {
    my $class = shift;
    my $debugLevel = shift;

    $class->SUPER::setDebug($debugLevel);

    return 1;
}

=head2 runRemoteCommand() | Bool

Runs a remote command.

=cut

sub runRemoteCommand {
	my $self = shift;
	my $command = shift;
	my $outputRef = shift;

	my $host = $self->host();
	my $username = $self->user();
	my $password = ariba::rc::Passwords::lookup($username);
	my $master;

	if($command =~ /readMasterPassword/) {
		$master = ariba::rc::Passwords::lookup('master');
	}

	$command = "ssh -l $username $host " . $command;
	my $logger = $self->logger();
	my @output;
	if ($self->testing()) {
		$logger->debug("DRYRUN: Would run '$command'");
	} else {
		$logger->info("Run '$command'");
		unless ( ariba::rc::Utils::executeRemoteCommand($command, $password, 0, $master, undef, \@output) ) {
			$self->setError("Failed to run '$command': " . join(';', @output));
			$logger->error($self->error());
			return;
		}
	}

	if($outputRef) {
		@$outputRef = (@output);
	}

	return 1;
}

1;