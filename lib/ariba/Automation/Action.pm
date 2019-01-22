package ariba::Automation::Action;

use strict;
use warnings;
use Carp;
use ariba::Ops::ProcessTable;
use ariba::Ops::PersistantObject;
use base qw(ariba::Ops::PersistantObject);

use ariba::Automation::State;

my $NAPTIME = 1; # time to sleep between killing/waiting on child process
my $MAX_WAIT_TRIES = 2; # maximum number of times to wait on a child process being killed

#
# This is to be ajle to syntax check robot config files;
# all these fields must be present for each action
#
sub validFields {
    my $class = shift;

    my $fieldsHashRef = {};

    $fieldsHashRef->{'type'}            = 1;
    $fieldsHashRef->{'skip'}            = 1;
    $fieldsHashRef->{'pause'}           = 1;
    $fieldsHashRef->{'stopOnError'}     = 1;
    $fieldsHashRef->{'notifyOnFailure'} = 1;
    $fieldsHashRef->{'origin'}          = 1;

    return $fieldsHashRef;
}

sub newForNameFromHash {
    my $class = shift;
    my $instance = shift;
    my $initHashRef = shift;
    my $robotName = shift;

    my $type = $initHashRef->{'type'};
    die "Can't find type for action $instance in init hash" unless $type;

    my $subName = ucfirst($type);
    my $classToLoad = __PACKAGE__;
    $classToLoad =~ s/(Action)$/${subName}$1/;

    eval "use $classToLoad;";
    if ($@) {
            carp "Error loading $classToLoad for $robotName: $@";
            return;
    }
    my $self = $classToLoad->new($instance);

    $self->SUPER::setAttribute("robotName", $robotName);

    my $validFieldsHashRef = $classToLoad->validFields();
    for my $field (keys %$initHashRef) {
        unless (exists $validFieldsHashRef->{$field}) {
        carp "Config: $field is not a valid field for action $type for $robotName";
        return;
        }
    }

    my $globalVarsHashRef = {};
    for my $key (keys %$initHashRef) {

        my $valueString = $initHashRef->{$key};

        if ($valueString =~ /^\[(.+)\]$/) {
            my $tmpValueString = $1;
            $globalVarsHashRef->{$key} = $tmpValueString;
        } else {
            $self->SUPER::setAttribute($key, $valueString);
        }
    }
    $self->SUPER::setAttribute("globalVarsHash", $globalVarsHashRef);

    return $self;
}

sub skip {
    my $self = shift;

    my $shouldSkip = $self->SUPER::skip();
    if ($shouldSkip && $shouldSkip =~ /^yes|true|1$/i) {
        return 1;
    }

    return 0;
}

sub stopOnError {
    my $self = shift;

    #
    # by default any failure in an action will cause the robot to
    # stop and start from the beginning
    my $shouldStop = $self->SUPER::stopOnError();
    # check for undef so that shouldStop=0 works
    $shouldStop = 1 if !defined($shouldStop);

    if ($shouldStop && $shouldStop =~ /^yes|true|1$/i) {
        return 1;
    }

    return 0;
}

sub setAttribute {
    my $self = shift;
    my $attribute = shift;
    my @value = @_;

    my $logger = ariba::Ops::Logger->logger();

    my $globalVars = $self->SUPER::globalVarsHash();
    my $globalState = ariba::Automation::GlobalState->newFromName($self->SUPER::attribute("robotName"));

    if (exists $globalVars->{$attribute}) {
        my $globalAttribute = $globalVars->{$attribute};
        $logger->debug($self->logPrefix() . " local $attribute caused setting GlobalState attr $globalAttribute to @value");
        $globalState->setAttribute($globalAttribute, @value);
        $globalState->save();
    } else {
        $self->SUPER::setAttribute($attribute, @value);
    }
}

sub attribute  {
    my $self = shift;
    my $attribute = shift;

    my $globalVars = $self->SUPER::attribute("globalVarsHash");
    my $globalState = ariba::Automation::GlobalState->newFromName($self->SUPER::attribute("robotName"));

    if (exists $globalVars->{$attribute}) {
        my $globalAttribute = $globalVars->{$attribute};
        return $globalState->attribute($globalAttribute);
    }

    return $self->SUPER::attribute($attribute);
}

sub attributes {
    my $self = shift;

    my @attribs = $self->SUPER::attributes();

    push(@attribs, keys(%{$self->globalVarsHash()}));

    return @attribs;
}

sub _internalMethodsHashRef {

    my $hashRef = {
        'globalVarsHash' => 1,
        'state'          => 1,
    };

    return $hashRef;
}

sub actionAttributes {
    my $self = shift;

    my $internalMethodsHashRef = $self->_internalMethodsHashRef();

    my @attributes = grep { !exists $internalMethodsHashRef->{$_}  } $self->attributes();

    return @attributes;
}

#
# All log entries will be prefixed with this string
#
sub logPrefix {
    my $self = shift;

    my $type = ref($self);

    #FIXME don't hardcode this
    $type =~ s/ariba::Automation:://;
    my $instance = $self->instance();

    my $prefix = "[$type $instance]";

    return $prefix;
}

sub executeSystemCommand {
    my $self = shift;
    my $cmd = shift;

    my $logger = ariba::Ops::Logger->logger();
    $self->setLastSystemCommand($cmd);

    my $status;
    
    unless ($self->testing()) {
        system($cmd);
        if ( $? == -1 )  { 
            $logger->debug("failed to execute '$cmd': $!");
            $status = -1;
        } elsif ($? & 127) { 
            $logger->debug("'$cmd' died with signal '" . $? & 127 . "'"); 
            $status = -2;
        } else {
            $status = ($? >> 8);
        }
    }

    $self->setLastExitStatus($status);

    if ($status == 0) {
        return 1;
    } else {
        return;
    }

}

sub stop {
    my $self = shift;
    my $robotPid = shift;

    my $logger = ariba::Ops::Logger->logger();
    $logger->info ("Stopping current action, robot PID: $robotPid");

    #
    # track number of processes killed: when robot is waiting for 
    # new checkins, it will not die if there are no child processes.
    #
    my $killed = 0;
    my $processTable = new ariba::Ops::ProcessTable;
    my @ancestors = $processTable->processTree($robotPid);
    my $pid;
    while ( $pid = pop(@ancestors) ) {
        $logger->debug("Killing child process with TERM: $pid");
        kill (15, $pid);
        $killed++;
    }

    # 
    # processTable->processTree returns an empty list when there are
    # no child processes. in this case, only the robot process exists
    # and it is blocking (waiting for new checkins, sleeping on a schedule).
    # the parent must be killed off by-hand.
    #
    if (! $killed) {
        $killed += $self->_hardStop ($robotPid);
        if (! $killed) { 
            $logger->info ("Warning: No processes killed.");
            return; 
        }
    }
    return 1;

    # find the make-build2 command run by the robot user and kill it and all it's children
}

sub _hardStop {
    my ($self, $pid) = @_;

    my $logger = ariba::Ops::Logger->logger();

    my ($nap, $done, $count) = ($NAPTIME, 0, 0);

    kill(15, $pid);
    sleep $nap;

    while (! $done) {
        if (! kill (0, $pid)) {
            $done = 1;
        } else {
            ++$nap;
            $logger->info("Process $pid not killed: Waiting $nap seconds...");
            sleep $nap;
            ++$count;
        }
        $done = 1 if $count > $MAX_WAIT_TRIES;
    }

    if ( kill(0, $pid) ) {
        $logger->info("Process $pid not killed, sending KILL signal");
        kill(9, $pid);
        sleep $NAPTIME;
        if ( kill(0, $pid) ) {
            $logger->error("Process $pid could not be killed.");
            return 0;
        }
    }

    return 1;
}

sub attachment {
    my $self = shift;

    return 0;
}

sub notifyMessage {
    my $self = shift;

    return 0;
}

#
# PersistantObject methods
#
sub dir {
    my $class = shift;
    return undef;
}

sub validAccessorMethods {
    my $class = shift;

    my $methodsRef = $class->SUPER::validAccessorMethods();

    my $fieldsHashRef = $class->validFields();
    foreach my $field (keys %$fieldsHashRef) {
        $methodsRef->{$field} = 1;
    }

    $methodsRef->{'startTime'} = 1;
    $methodsRef->{'endTime'} = 1;
    $methodsRef->{'previousStartTime'} = 1;
    $methodsRef->{'previousEndTime'} = 1;
    $methodsRef->{'status'} = 1;
    $methodsRef->{'lastExitStatus'}  = 1;
    $methodsRef->{'lastSystemCommand'} = 1;
    $methodsRef->{'state'} = 1;
    $methodsRef->{'globalVarsHash'} = 1;
    $methodsRef->{'testing'} = 1;
    $methodsRef->{'skip'} = 1;
    $methodsRef->{'pause'} = 1;
    $methodsRef->{'stopOnError'} = 1;
    $methodsRef->{'executed'} = 1;
    $methodsRef->{'qualTestId'} = 1;
    $methodsRef->{'notifyOnFailure'} = 1;
    $methodsRef->{'shortCircuit'} = 1;
    $methodsRef->{'actionError'} = 1;

    return $methodsRef;
}
1;
