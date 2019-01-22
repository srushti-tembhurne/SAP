#!/usr/local/bin/perl

package ariba::Ops::MCL;

use strict;
use File::Basename;
use POSIX;
use base qw(ariba::Ops::PersistantObject);

use ariba::Ops::MCL::Step;
use ariba::Ops::MCL::Variable;
use ariba::Ops::NetworkUtils;
use ariba::Ops::Logger;
use ariba::Ops::ProcessTable;
use ariba::util::Term;
use dmail::LockLib;
use FindBin;

my $logger = ariba::Ops::Logger->logger();
my $currentMCL;
my %wroteVariableFile;
my %sentVariablesToHost;
my %sentMCLToHost;
my %children;
my %stepsAttempted;
my $tryMoreSteps = 1;
my $winchLock = 0;
my $CLASSmclDir;
my $MCLDebug = 0;
my $stepIndex;
my $expandoIndex;
my %runningForGroup;
my $topStatus = "";
my $lastTopStatus = 0;

my $actionCount;
my $defaultLogFile = "main.log";
my $lockDirIsCleaned = 0;

my @displayStepsMenu = (
    'E Return to MCL',
    'C Mark Step as Complete',
    'R Restart Step',
    'X Requeue Step',
    'S Start all Optional Steps',
    'P Pause MCL Execution',
    'Q Quit MCL UI'
);

my @confirmMenu = (
    'X Cancel',
    'C Confirm',
);

sub allowGroupChanges {
    my $self = shift;

    @displayStepsMenu = (
        'E Return to MCL',
        'C Mark Step as Complete',
        'R Restart Step',
        'X Requeue Step',
        'S Start all Optional Steps',
        'P Pause MCL Execution',
        'G Change RunGroup Settings',
        'Q Quit MCL UI'
    );
}

sub validAccessorMethods {
    my $class = shift;

    my $ref = $class->SUPER::validAccessorMethods();
    my @accessors = qw( aggregateLogsTo declared endTime notifications paused previousElapsedTime runGroups startTime stepFailures steps title usage variables );

    foreach my $accessor (@accessors) {
        $ref->{$accessor} = 1;
    }

    return($ref);
}

sub setDefaultLogfile {
    my $logfile = shift;
    $defaultLogFile = $logfile;
}

sub notifyForEvent {
    my $self = shift;
    my $event = shift;
    my $note = shift;
    my $step = shift;
    my $stepname = $step->name() if($step);

    $logger->info("Call notifyForEvent: Event=$event Note=$note Step=$stepname\n");

    my @general;
    my @stepSpecific;

    foreach my $n ($self->notifications()) {
        next unless($n->event() eq $event);
        push(@general, $n) unless($n->step());
        next unless($n->step() && $stepname && $n->step() eq $stepname);
        push(@stepSpecific, $n);
    }

    #
    # if we have a step specific notify, call those, ignoring general ones
    #
    if(scalar(@stepSpecific)) {
        foreach my $n (@stepSpecific) {
            $n->notify($note);
        }
        return;
    }

    #
    # otherwise, call the top level notify, if any exist
    #
    foreach my $n (@general) {
        $n->notify($note);
    }
}

sub loadMclPackages {
    my $dir;

    #
    # unless running from perforce, FORCE /usr/local/ariba/lib
    #
    my @forcedir = ();
    unless($FindBin::Bin =~ m!/ariba/services/(?:monitor|tools)/bin/!) {
        @forcedir = ( '/usr/local/ariba/lib' );
    }

    foreach my $d (@forcedir, @INC) {
        if ( -e "$d/ariba/Ops/MCL/Step.pm" ) {
            $dir = $d;
            last;
        }
    }

    my @saved = @INC;
    push(@INC, $dir);

    opendir(D, "$dir/ariba/Ops/MCL");
    while(my $f = readdir(D)) {
        next unless($f =~ s/\.pm$//);
        my $package = "ariba::Ops::MCL::$f";
        # print "Load $package from $dir.\n";
        eval "use $package";
        if($@) {
            $logger->error("Failed to load $package.");
            die($@);
        }
    }
    closedir(D);

    opendir(D, "$dir/ariba/Ops/MCL/Helpers");
    while(my $f = readdir(D)) {
        next unless($f =~ s/\.pm$//);
        my $package = "ariba::Ops::MCL::Helpers::$f";
        # print "Load $package.\n";
        eval "use $package";
        if($@) {
            $logger->error("Failed to load $package.");
            die($@);
        }
    }
    closedir(D);

    @INC = @saved;
}

sub topLevelStatus {
    my $self = shift;
    my %status;
    my $completed = 1;
    my $started = 0;

    return("No MCL") unless $self;


    #
    # only run this every few seconds.  It's too slow.
    #
    my $now = time();
    if($now < $lastTopStatus+2) {
        return($topStatus);
    }

    foreach my $child ($self->steps()) {
        my $childStatus = $child->status() || "";
        $status{ $childStatus } = 1;
        $completed = 0 if($completed && $childStatus ne 'Completed' && $childStatus ne 'Error OK' && $childStatus ne 'Skipped' && $childStatus ne 'Optional');
        $started = 1 if(!$started && $childStatus && $childStatus ne 'Not Started' && $childStatus ne 'Optional');
    }

    return('Completed') if($completed);
    return('Paused') if($self->isPaused());
    return('Failed') if($status{'Failed'});
    return('Crashed') if($status{'Crashed'});
    return('Confused') if($status{'Confused'});
    return('Waiting') if($status{'Waiting'});
    return('Running') if($status{'Running'} || $started);
    return('Not Started');
}

sub isPaused {
    my $self = shift;
    return($self->paused());
}

sub currentMclObject {
    my $class = shift;
    return($currentMCL);
}

sub setDirectory {
    $CLASSmclDir = shift;
}

sub setDebug {
    my $value = shift;
    $MCLDebug = $value;
}

sub inDebugMode {
    return($MCLDebug);
}

sub dir {
    return '/var/mcl';
}

sub logdir {
    my $self = shift;

    my $dir = $self->dir();
    $dir .= "/";
    $dir .= $self->instance();
    $dir .= "/logs/logfiles";

    return($dir);
}

sub messagedir {
    my $self = shift;

    my $dir = $self->dir();
    $dir .= "/";
    $dir .= $self->instance();
    $dir .= "/messages";

    return($dir);
}

sub _computeBackingStoreForInstanceName {
    my $class = shift;
    my $instance = shift;

    return "/var/mcl/$instance/mcl.object" ;
}

sub objectLoadMap {
    my $class = shift;

    my $map = $class->SUPER::objectLoadMap();

    $map->{'steps'} = '@ariba::Ops::MCL::Step';
    $map->{'variables'} = '@ariba::Ops::MCL::Variable';
    $map->{'runGroups'} = '@ariba::Ops::MCL::RunGroup';
    $map->{'notifications'} = '@ariba::Ops::MCL::Notification';
    $map->{'stepFailures'} = '@SCALAR';
    $map->{'declared'} = '@SCALAR';

    return($map);
}

sub mclDir {
    return $CLASSmclDir if($CLASSmclDir);
    return '/usr/local/ariba/mcl';
}

sub createMCLBackingDir {
    # This method is smart, it knows if it has already been run and will not run again if called a second
    # time.  So if it was run before, this will skip, if not before, this one will run, and any subsequent
    # calls will skip.
    ariba::rc::Passwords::readMasterPasswords;
    my $service = ariba::rc::Passwords::service();

    my $hostname = ariba::Ops::NetworkUtils::hostname();
    my $user = userForService( $service, "svc", $hostname );
    my $password = ariba::rc::Passwords::lookup( $user );

    my @cmds = (
        "ssh -l $user $hostname sudo mkdir /var/mcl",
        "ssh -l $user $hostname sudo chgrp ariba /var/mcl",
        "ssh -l $user $hostname sudo chmod 2775 /var/mcl"
    );

    foreach my $cmd (@cmds) {
        my @output;

        $logger->info("Running '$cmd' ...");
        my $ret = ariba::rc::Utils::executeRemoteCommand(
            $cmd, $password, 0, undef, undef, \@output
        );
        unless($ret) {
            $logger->error("Bang-Dollar = $!");
            foreach my $o (@output) {
                $logger->error("-> $o");
            }
            return(0);
        }
    }

    return(1);
}

sub runGroupForName {
    my $self = shift;
    my $name = shift;

    foreach my $rg ($self->runGroups()) {
        return($rg) if($rg->name() eq $name);
    }
    return undef;
}

sub maxRunningProcessesForGroup {
    my $self = shift;
    my $group = shift;

    my $rg = $self->runGroupForName($group);

    if($rg && $rg->maxParallelProcesses()) {
        return($rg->maxParallelProcesses());
    }

    #
    # this is a default
    #
    return(5);
}

sub runningProcessesForGroup {
    my $self = shift;
    my $group = shift;
    my $count = 0;

    foreach my $s ($self->steps()) {
        $count++ if($s->isRunning() && $s->runGroup() eq $group);
    }

    return($count);
}

sub new {
    my $class = shift;
    my $mclname = shift;
    my $variablesOnly = shift;

    #
    # make sure we have /var/mcl setup
    #
    unless( -r "/var/mcl" ) {
        #
        # due to parallel processing, this can "fail" because someone else
        # did the same thing faster.  So we only blow up if the call fails
        # AND the directory still doesn't exist.
        #
        unless(createMCLBackingDir() || -r "/var/mcl") {
            $logger->error("Failed to create backing store /var/mcl");
            die($!);
        }
    }

    my $self = $class->SUPER::new($mclname);


    if($variablesOnly) {
        $self->loadVariables();
    } else {
        $self->loadMCL();
    }
    $self->cleanLockDir();

    $currentMCL = $self;

    #
    # setup the logging
    #
    my $logdir = $self->logdir();
    ariba::rc::Utils::mkdirRecursively($logdir);
    chmod(02775, $logdir);
    $logger->setLogFile("$logdir/$defaultLogFile");

    my $messagedir = $self->messagedir();
    ariba::rc::Utils::mkdirRecursively($messagedir);
    chmod(02775, $messagedir);
    system("/bin/rm -rf $messagedir/*");

    if($ENV{'ARIBA_MCL_PPID'} && $ENV{'STY'} && $defaultLogFile eq 'main.log') {
        # screen mode -- use the FIFO for main.log
        my $fifo = "/tmp/.screen-mcl-fifo." . $ENV{'ARIBA_MCL_PPID'} . '.' . $ENV{'STY'};
        $logger->setLogFile($fifo);

        #
        # this log line is to FORCE the fifo to get opened.  Don't remove it.
        #
        $logger->info("Starting logging to $fifo for MCLAction logging...");
        if(defined($ENV{'WINDOW'})) {
            #
            # this (eventually) causes the window information to get passed
            # back to the UI, so that it can note that it's in a secondary
            # screen window instead of just saying "Running".
            #
            $logger->info("Child running in WINDOW " . $ENV{'WINDOW'});
        }
    }

    #
    # set the timing information
    #
    $self->setStartTime(time());
    $self->setEndTime(0);
    $self->setPreviousElapsedTime(0) unless($self->previousElapsedTime());

    return($self);
}

sub indexSteps {
    my $self = shift;

    $stepIndex = {};
    $expandoIndex = {};

    foreach my $step ($self->steps()) {
        $stepIndex->{$step->name()} = $step;
    }

    foreach my $step ($self->steps()) {
        if($step->expando() && $stepIndex->{$step->expando()}) {
            push(@{$expandoIndex->{$step->expando()}}, $step);
        }
    }
}

sub stepsForExpando {
    my $self = shift;
    my $name = shift;
    my @ret;

    if($expandoIndex) {
        return(@ret) unless($expandoIndex->{$name});
        return(@{$expandoIndex->{$name}});
    } else {
        foreach my $s ($self->steps()) {
            push(@ret, $s) if($s->expando() eq $name);
        }
        return(@ret);
    }
}

sub stepForName {
    my $self = shift;
    my $name = shift;

    if($stepIndex) {
        return($stepIndex->{$name});
    } else {
        foreach my $s ($self->steps()) {
            return($s) if($s->name() eq $name);
        }
    }

    return undef;
}

sub lockFile {
    my $self = shift;

    my $lockFile = $self->dir() . "/" . $self->instance() . "/.lockFile";
    return($lockFile);
}

sub loadVariables {
    my $self = shift;

    dmail::LockLib::forceQuiet();
    dmail::LockLib::requestlock($self->lockFile(),60);

    my $mcl = $self->mclDir() . "/" . $self->instance();

    open(MCL, $mcl) || die("unable to open $mcl");
    my @in = <MCL>;
    close(MCL);

    $mcl = $self->instance();

    while( my $line = shift(@in) ) {
        next if($line =~ /Ariba::([a-zA-Z0-9]+)\(\s*([^\)]+)\s*\)/);

        if($line =~ /^\s*Usage:\s+\{$/) {
            my $usage;
            while(my $use = shift(@in)) {
                last if($use =~ /^\s*\}\s*$/);
                $use =~ s/^\s*([^\s])/$1/;
                $use =~ s/^\-/    -/;
                if($use =~ /^VariableError:\s*([^=\s]+)\s*=\s*(.*)/) {
                    my $vname = $1;
                    my $hint = $2;
                    my $v = ariba::Ops::MCL::Variable->newFromParser($mcl, $vname);
                    $v->setUsageHint($hint);
                } else {
                    $usage .= $use;
                }
            }
            $usage =~ s/^\s*//;
            $usage =~ s/\s*$//;
            $self->setUsage($usage);
        } elsif($line =~ /^\s*Variable:\s*([^=\s]+)\s*$/) {
            my $vname = $1;
            my $variable = ariba::Ops::MCL::Variable->newFromParser($mcl, $vname);

            unless($self->hasVariable($variable)) {
                $variable->setValue(undef);
                $self->appendToVariables($variable);
            }
        } elsif($line =~ /^\s*Variable:\s*([^=\s]+)\s*=\s*(.*)/) {
            my $vname = $1;
            my $vdefault = $2;
            my $variable = ariba::Ops::MCL::Variable->newFromParser($mcl, $vname);

            unless($self->hasVariable($variable)) {
                $variable->setValue($vdefault);
                $self->appendToVariables($variable);
            }
        }
    }

    dmail::LockLib::releaselock($self->lockFile());
    return($self);
}

sub loadMCL {
    my $self = shift;
    $actionCount = 0;

    my @steps;
    my @runGroups;
    my @empty;
    my @storeVars;
    my @notifications;
    my $loopVar;

    $self->loadVariables();

    dmail::LockLib::forceQuiet();
    dmail::LockLib::requestlock($self->lockFile(),60);

    my $mcl = $self->mclDir() . "/" . $self->instance();

    open(MCL, $mcl) || die("unable to open $mcl");
    my @in = <MCL>;
    close(MCL);

    $mcl = $self->instance();

    my $step;

    $self->setDeclared(@empty);

    while( my $line = shift(@in) ) {
        chomp($line);
        next unless($line);
        #
        # variable substitution first
        #
        $line = $self->expandVariables($line);

        #
        # if we get more than one variable out this line, then we need to
        # take only the first
        #
        my @jnk;
        ( $line, @jnk ) = split(/\n/, $line);

        next if($line =~ /^\s*$/);
        next if($line =~ /^\s*\#/);

        if($line =~ /^\s*Usage:\s+\{$/) {
            #
            # we already parsed this with variables, BUT, we have to accept
            # the syntax here and not error out
            #
            while(my $use = shift(@in)) {
                last if($use =~ /^\s*\}\s*$/);
            }
        }

        elsif($line =~ /^\s*AllowGroupChanges\s*$/) {
            $self->allowGroupChanges();
        }
        elsif($line =~ /^\s*AggregateLogsTo:\s*(.*)/) {
            my $logfile = $1;
            $self->setAggregateLogsTo($logfile) unless($self->aggregateLogsTo());
        }
        elsif($line =~ /^\s*MCLTitle:\s*(.*)/) {
            my $title = $1;
            $self->setTitle($title);
        }
        elsif($line =~ /^\s*Notify:\s*([^\s]+)\s+([^\s]+)\s+(.*)$/) {
            my $event = $1;
            my $type = $2;
            my $arg = $3;

            my $stepname;
            $stepname = $step->name() if($step);

            my $notify = ariba::Ops::MCL::Notification->newFromParser($mcl, $event, $type, $stepname);
            $notify->setArgument($arg);
            push(@notifications, $notify);
        }
        elsif($line =~ /^\s*Step\s+([^\s]+)/) {
            my $stepname = $1;
            if($stepname =~ m|/|) {
                die("MCL Syntax error: Backslash not allowed name of Step $stepname");
            }
            $step->setStoredVariables(@storeVars) if($step);
            if($loopVar) {
                pop(@steps);
                push(@steps, $self->loopSteps($step, $loopVar));
                $loopVar = undef;
            }
            @storeVars = @empty;
            $step = ariba::Ops::MCL::Step->newFromParser($mcl, $stepname);
            $step->setDepends(@empty);
            push(@steps, $step);
            $step->setActions(@empty);
        }

        elsif($line =~ /^\s*Include:\s*\{\s*$/) {
            my ($incFile, $stepPrefix, $dep) = $self->parseInclude(\@in);
            my @include = $self->includeFile($incFile, $stepPrefix, $dep);
            unshift(@in, @include);
        }

        elsif($line =~ /^\s*Group:\s*([^\s]+)\s+\{$/) {
            my $groupName = $1;
            my $group = ariba::Ops::MCL::RunGroup->newFromParser($mcl,$groupName);
            $group->parse($self, \@in);
            push(@runGroups, $group);
        }

        elsif($line =~ /^\s*Declare:\s*([^\s]+)$/) {
            my $declared = $1;
            $self->appendToDeclared($declared);
        }

        #
        # reparse variables with function calls
        #
        elsif($line =~ /^\s*Variable:\s*([^=\s]+)\s*$/) {
            my $vname = $1;
            my $variable = ariba::Ops::MCL::Variable->newFromParser($mcl, $vname);

            unless($self->hasVariable($variable)) {
                $variable->setValue(undef);
                $self->appendToVariables($variable);
            }
        }

        elsif($line =~ /^\s*Variable:\s*([^=\s]+)\s*=\s*(.*)/) {
            my $vname = $1;
            my $vdefault = $2;
            my $variable = ariba::Ops::MCL::Variable->newFromParser($mcl, $vname);

            unless($self->hasVariable($variable)) {
                $variable->setValue($vdefault);
                $self->appendToVariables($variable);
            }
        }

        elsif($step) {
            if($line =~ /^\s*Title:\s*(.*)/) {
                my $title = $1;
                $step->setTitle($title);
            }
            elsif($line =~ /^\s*AlertTimeout:\s*(.*)/) {
                my $alertTime = $1;
                $step->setAlertTime($alertTime);
            }
            elsif($line =~ /^\s*Expando:\s*(.*)/) {
                my $expando = $1;
                $step->setExpando($expando);
            }
            elsif($line =~ /^\s*RunGroup:\s*(.*)$/) {
                my $rungroup = $1;
                $step->setRunGroup($rungroup);
            }
            elsif($line =~ /^\s*Options:\s*(.*)/) {
                my $optsString = $1;
                my @opts = split(/\s*,\s*/, $optsString);
                foreach my $o (@opts) {
                    if($o =~ /^optional$/i) {
                        $step->setStatus('Optional') unless($step->status());
                        next;
                    }
                    if($o =~ /^expando$/i) {
                        $step->setIsExpandoParent(1);
                        $step->setFolderStatus('closed') unless($step->folderStatus());
                        next;
                    }
                    if($o =~ /^rerun$/i) {
                        $step->setRerunOnRestart(1);
                        next;
                    }
                    if($o =~ /^continueonerror$/i) {
                        $step->setContinueOnError(1);
                        next;
                    }
                    if($o =~ /^noinherit$/i) {
                        $step->setNoinherit(1);
                        next;
                    }
                    my $stepname = $step->name();
                    die("MCL Syntax error: Unknown option in Step $stepname: $o");
                }
            }
            elsif($line =~ /^\s*Store:\s*(.*)/) {
                push(@storeVars, $1);
            }
            elsif($line =~ /^\s*Depends:\s*(.*)/) {
                my $d = $1;
                my @depends = split(/\s+/,$d);
                push(@depends,$step->depends()) if(scalar($step->depends()));
                $step->setDepends(@depends);
            }
            elsif($line =~ /^\s*Retries:\s*(\d+)/) {
                my $retries = $1;
                $step->setRetries($retries);
            }
            elsif($line =~ /^\s*RetryInterval:\s*(\d+)/) {
                my $interval = $1;
                $step->setRetryInterval($interval);
            }
            elsif($line =~ /^\s*StoreSuccess:\s*(\w+)/) {
                my $var = $1;
                $step->setStoreSuccess($var);
            }
            elsif($line =~ /^\s*ExecuteIf:\s*(.+)$/) {
                my $ei = $1;
                $step->setExecuteIf($ei);
            }
            elsif($line =~ /^\s*ExecuteUnless:\s*(.+)$/) {
                my $ei = $1;
                $step->setExecuteUnless($ei);
            }
            elsif($line =~ /^\s*Action:\s*(\w+)\s+(.*?)\s*\{$/) {
                my $actionType = $1;
                my $otherArgs = $2;
                my $actionClass = "ariba::Ops::MCL::${actionType}Action";

                #
                # mcl-control implicitly loads all of these
                #
                # eval "use $actionClass";

                my $stepname = $step->name();

                my $action = $actionClass->newFromParser($mcl,$stepname,$actionCount);
                $actionCount++;

                $step->appendToActions($action);
                $action->parse($self, $step, $otherArgs, \@in);
            }
            elsif($line =~ /^\s*Loop:\s*([^=]+=.*)$/) {
                $loopVar = $1;
            }
            else {
                my $stepname = $step->name();
                die("Unrecognized syntax in Step $stepname: $line");
            }
        }

        else {
            my $stepname = "in MCL header";
            $stepname = "in Step " . $step->name() if($step);
            die("Unrecognized syntax $stepname: $line");
        }
    }

    #
    # last one!
    #
    $step->setStoredVariables(@storeVars) if($step);
    if($loopVar) {
        pop(@steps); # this step is a place holder
        push(@steps, $self->loopSteps($step, $loopVar));
        $loopVar = undef;
    }

    $self->setSteps(@steps);
    $self->indexSteps();

    $self->setRunGroups(@runGroups);
    $self->fixStepDependencies();
    $self->setNotifications(@notifications);


    unless( $self->expandAndCheckDependencies() ) {
        $logger->error("Error parsing MCL.  exiting.");
        dmail::LockLib::releaselock($self->lockFile());
        exit(1);
    }
    $self->inheritDependencies();

    dmail::LockLib::releaselock($self->lockFile());
    return($self);
}

sub inheritDependencies {
    my $self = shift;
    my %stepsProcessed;
    my %noinheritDepends;

    my $progress = 1;
    my $continue = 1;
    while($continue) {
        unless($progress) {
            # all remaining steps to check have circular dependancies
            my @circular;
            foreach my $step ($self->steps()) {
                push(@circular, $step->name()) unless($stepsProcessed{$step->name()});
            }
            my $and = pop(@circular);
            my $stepList = join(", ", @circular);
            $logger->error("Steps $stepList and $and are interdependent.");
            $logger->error("(ie: they have circular dependencies.)");
            die("Found circular dependencies in " . $self->instance());
        }
        $progress = 0;
        $continue = 0;
        OUTER: foreach my $step ($self->steps()) {
            next if($stepsProcessed{$step->name()});
            foreach my $dep ($step->depends()) {
                next if($dep eq $step->name());
                unless($stepsProcessed{$dep}) {
                    $continue = 1;
                    next OUTER;
                }
            }

            my @inherited = ();
            foreach my $dep ($step->depends()) {
                my $depObj = $self->stepForName($dep);
                push(@inherited, $depObj->depends()) if($depObj->depends());
            }

            push(@inherited, $step->depends());
            $progress = 1;
            $stepsProcessed{$step->name()} = 1;

            #
            # we have to "inherit" to check for dependency loops...
            # so we save this and reset it later
            #
            if($step->noinherit()) {
                $noinheritDepends{$step->name()} = [ $step->depends() ];
            }

            @inherited = grep { $_ ne $step->name() } @inherited;
            my %mapped;
            map { $mapped{$_} = 1; } @inherited;
            $step->setDepends(sort(keys(%mapped)));
        }
    }

    #
    # reset the depends back to original for steps with noinherit
    #
    foreach my $k (keys %noinheritDepends) {
        my $step = $self->stepForName($k);
        $step->setDepends( @{$noinheritDepends{$k}} );
    }
}

sub resolveVirtualHosts {
    my $self = shift;

    my $service = $self->service();
    my %virtHosts;
    my $save;

    foreach my $step ($self->steps()) {
        foreach my $act ($step->actions()) {
            next unless($act->isRemote());
            my $host = $act->host();

            next if($host eq 'localhost');

            my $user = userForService( $service, 'svc', $host );
            my $pass = ariba::rc::Passwords::lookup($user);

            if($virtHosts{$host}) {
                $act->setHost($virtHosts{$host});
                next;
            }

            my $machine = ariba::Ops::Machine->new($host);

            unless($machine->ipAddr()) {
                
                # see if we have it cached
                my $map = ariba::Ops::MCL::VIPMapping->new($self->instance(), $host);
                if($map->realHost()) {
                    $logger->info(" ----> [cached] Set $host to " . $map->realHost());
                    $act->setHost($map->realHost());
                    $virtHosts{$host} = $map->realHost();
                    $save=1;
                } else {
                    my $cmd = "ssh -l $user $host -x hostname";
                    my @output;

                    $logger->info("Getting real host for $host\n");

                    my $ret = ariba::rc::Utils::executeRemoteCommand(
                        $cmd,
                        $pass,
                        0,
                        undef,
                        60,
                        \@output
                    );

                    if($ret) {
                        foreach my $line (@output) {
                            if($line =~ /\b(.*\.ariba\.com)/) {
                                my $newhost = $1;
                                $logger->info(" ----> Set $host to $newhost");
                                $act->setHost($newhost);
                                $virtHosts{$host} = $newhost;
                                $save=1;
                                my $map = ariba::Ops::MCL::VIPMapping->new($self->instance(), $host, $newhost);
                                $map->save();
                            }
                        }
                    }
                }
            }
        }
    }

    $self->recursiveSave() if($save);
}

sub expandAndCheckDependencies {
    my $self = shift;
    my %dependsOnOwnGroup;
    my $ret = 1;

    foreach my $step ($self->steps()) {
        next unless($step->runGroup());
        foreach my $dep ($step->depends()) {
            if($dep =~ m|group:(.*)|) {
                my $group = $1;
                if($group eq $step->runGroup()) {
                    $dependsOnOwnGroup{$step->name()} = 1;
                }
            }
        }
    }

    foreach my $step ($self->steps()) {
        my @expandedDepends;
        foreach my $dep ($step->depends()) {
            if($dep =~ s/^group:(.+)/$1/) {
                my $ok = 0;
                foreach my $s ($self->steps()) {
                    my $sRunGroup = $s->runGroup() || "";
                    my $stepRunGroup = $step->runGroup() || "";
                    next unless($sRunGroup eq $dep);
                    $ok = 1;
                    next if ($s->name() eq $step->name());
                    next if ($stepRunGroup eq $dep &&
                        $dependsOnOwnGroup{$step->name()} &&
                        $dependsOnOwnGroup{$s->name()}
                    );
                    push(@expandedDepends, $s->name());
                }
                unless($ok) {
                    $logger->error("Step " . $step->name . " depends on group $dep that does not exist.");
                    $ret=0;
                }
            } else {
                unless($self->stepForName($dep) || $self->isDeclared($dep)) {
                    $logger->error("Step " . $step->name . " depends on step $dep that does not exist.");
                    $ret=0;
                }
                my $dependStep = $self->stepForName($dep);
                if($dependStep && $dependStep->isExpandoParent()) {
                    $logger->error("Step " . $step->name . " depends on step $dep which is an expando.");
                    $ret=0;
                }
                push(@expandedDepends, $dep);
            }
        }
        $step->setDepends(@expandedDepends);
    }

    return($ret);
}

sub isDeclared {
    my $self = shift;
    my $name = shift;

    foreach my $declared ($self->declared()) {
        return(1) if($declared eq $name);
    }

    return(0);
}

sub parseInclude {
    my $self = shift;
    my $stream = shift;
    my ($file, $prefix, $depends);

    while(my $line = shift(@$stream)) {
        next if($line =~ /^\s*$/);
        next if($line =~ /^\s*\#/);

        if($line =~ /^\s*File:\s*(.*)$/) {
            $file = $1;
            $file =~ s/^\s+//; $file =~ s/\s+$//;
        } elsif($line =~ /^\s*Prefix:\s*(.*)$/) {
            $prefix = $1;
            $prefix =~ s/^\s+//; $file =~ s/\s+$//;
        } elsif($line =~ /^\s*Depends:\s*(.*)$/) {
            $depends = $1;
            $depends =~ s/^\s+//; $file =~ s/\s+$//;
        } elsif($line =~ /^\s*\}\s*$/) {
            last;
        } else {
            die("Unrecognized Syntax in Include block: $line");
        }
    }

    return($file, $prefix, $depends);
}

sub includeFile {
    my $self = shift;
    my $incMCL = shift;
    my $prefix = shift;
    my $extDepends = shift;

    my $file = $self->mclDir() . "/$incMCL";
    open(INCLUDE, $file) || die ("Cannot Include $file.\n$!");
    my @in = <INCLUDE>;
    close(INCLUDE);

    return(@in) unless($prefix);

    my @ret;
    foreach my $line (@in) {
        if($line =~ s/^\s*Step\s+(\w+)/Step ${prefix}$1/) {
            push(@ret, $line);
            push(@ret, "Depends: $extDepends\n");
        } elsif($line =~ s/Output\((\w+)\)/Output(${prefix}$1)/) {
            push(@ret, $line);
        } elsif($line =~ /^\s*Depends:\s*(.*)/) {
            my $depends = $1;
            my @dep = split(/\s+/, $depends);
            my $list = "";
            foreach my $d (@dep) {
                if($d =~ s/^group://) {
                    $list .= " group:$prefix$d";
                } else {
                    $list .= " $prefix$d";
                }
            }
            push(@ret, "Depends:$list");
        } elsif($line =~ /^\s*Expando:\s*(.*)/) {
            my $expando = $1;
            push(@ret, "Expando: $prefix$expando\n");
        } elsif($line =~ /^\s*RunGroup:\s*(.*)/) {
            my $group = $1;
            push(@ret, "RunGroup: $prefix$group\n");
        } elsif($line =~ /^\s*Group:\s*(.*)/) {
            my $group = $1;
            push(@ret, "Group: $prefix$group\n");
        } else {
            push(@ret, $line);
        }
    }

    return(@ret);
}

sub fixStepDependencies {
    my $self = shift;
    my %expandSteps;

    foreach my $step ($self->steps()) {
        if($step->parentStep()) {
            push(@{$expandSteps{$step->parentStep()}}, $step->name())
        }
    }

    foreach my $step ($self->steps()) {
        my @depends = ();
        foreach my $d ($step->depends()) {
            if($expandSteps{$d}) {
                push(@depends, @{$expandSteps{$d}});
            } else {
                push(@depends, $d);
            }
        }
        $step->setDepends(@depends);
    }
}

sub generateCombinations {
    my $hash = shift;
    my (@iterators) = (@_);
    my $c;

    if(scalar(@iterators) == 1) {
        my ($var, $list) = split(/\=/, $iterators[0]);
        foreach my $val (split(/\s+/, $list)) {
            $$hash{"$var=$val"} = $c++;
        }
    } else {
        my %combos;
        my $me = shift(@iterators);
        generateCombinations(\%combos, @iterators);
        my ($var, $list) = split(/\=/, $me);
        foreach my $val (split(/\s+/, $list)) {
            foreach my $append (sort { $combos{$a} <=> $combos{$b} } (keys %combos)) {
                $$hash{"$var=$val; $append"} = $c++;
            }
        }
    }
}

sub loopSteps {
    my $self = shift;
    my $baseStep = shift;
    my $loopVar = shift;
    my @actions;
    my @ret;
    my $substep = 'a';
    my $count = 0;

    my %combinations;

    my @loopIterators = split(/\s*,\s*/,$loopVar);

    generateCombinations(\%combinations, @loopIterators);

    foreach my $combo (sort {$combinations{$a} <=> $combinations{$b}} (keys %combinations)) {
        my %vars;
        my @items = split(/\;\s/, $combo);
        my @vals;
        my $if = $baseStep->executeIf();
        my $unless = $baseStep->executeUnless();
        foreach my $i (@items) {
            my ($k, $v) = split(/\=/, $i);
            $vars{$k} = $v;
            push(@vals, $v);
            $if =~ s/\$\{$k\}/$v/g if($if);
            $unless =~ s/\$\{$k\}/$v/g if($unless);
        }
        my $iteration = join(',', @vals);
        my $step = ariba::Ops::MCL::Step->newFromParser(
            $self->instance(),
            $baseStep->name() . $substep);
        $step->setExecuteIf($if);
        $step->setExecuteUnless($unless);
        $step->setStoredVariables($baseStep->storedVariables());
        $combo =~ s/\s//g;
        $step->setTitle($baseStep->title() . " ($iteration)");
        $step->setExpando($baseStep->expando());
        $step->setRunGroup($baseStep->runGroup());
        $step->setRetries($baseStep->retries());
        $step->setRetryInterval($baseStep->retryInterval());
        foreach my $baseAction ($baseStep->actions()) {
            my $action = ref($baseAction)->newFromParser(
                $self->instance(),$step->name(),$actionCount
            );
            $actionCount++;
            $action->duplicate($baseAction, \%vars, $count++);
            push(@actions, $action);
        }
        $step->setActions(@actions);
        $step->setDepends($baseStep->depends());
        $step->setParentStep($baseStep->name());
        @actions = ();
        push(@ret, $step);
        $substep++;
    }

    return(@ret);
}

sub hasVariable {
    my $self = shift;
    my $var = shift;

    foreach my $v ($self->variables()) {
        return 1 if($v->instance() eq $var->instance());
    }
    return(0);
}

#
# handle newlines in variable -- should make a loop on commandline lines
#
sub expandVariables {
    my $self = shift;
    my $line = shift;

    my %replaced;

    #
    # make a pre-pass for variables in args to functions
    #
    foreach my $v ($self->variables()) {
        next unless($v->value());
        my $key = $v->name();
        my $value = $v->value();

        #
        # multi-line substitution before function calls is not supported
        #
        next if($value =~ /\n/);

        $line =~ s/\$\{$key\}/$value/g;
    }

    #
    # parse function calls
    #
    while($line =~ /Ariba::([a-zA-Z0-9]+)\(\s*([^\)]*)\s*\)/) {
        my $rep;
        my $func = $1;
        my $arg = $2;

        if($arg =~ /\$\{[^\}]+\}/) {
                $logger->warn("Ariba helper called with unresolved variable");
                $line =~ s/Ariba::([a-zA-Z0-9]+)\(\s*([^\)]*)\s*\)/ERROR/;
        } else {

            $rep = eval "ariba::Ops::MCL::Ariba::$func($arg);";
            if($rep) {
                $line =~ s/Ariba::([a-zA-Z0-9]+)\(\s*([^\)]*)\s*\)/$rep/;
            } else {
                $line =~ s/Ariba::([a-zA-Z0-9]+)\(\s*([^\)]*)\s*\)/ERROR/;

                $logger->warn("call to Ariba helper returned error");
                $logger->warn($@);
            }
        }
    }

    #
    # parse any variables left -- a function can technically return a
    # variable, and have it re-parse... not that I expect to see that.
    #
    # however this pass will get any multi-line variables
    #
    $replaced{$line} = 1;

    foreach my $v ($self->variables()) {
        next unless($v->value());
        my $key = $v->name();
        my $value = $v->value();
        my @vals = split(/\n/, $value);

        my @lines;
        my @new;
        if(scalar keys (%replaced)) {
            @lines = keys %replaced;
        } else {
            @lines = ( $line );
        }
        
        foreach my $subVal (@vals) {
            foreach my $in (@lines) {
                my $change = $in;
                $change =~ s/\$\{$key\}/$subVal/g;
                delete $replaced{$in} if($in ne $change);
                $replaced{$change} = 1;
            }
        }
    }

    $line = join("\n", sort keys %replaced);

    return($line);
}

# If $value has white space then we have multiple services in play.  If we're
# passed in $user we can decipher from it the service in play. 
sub service {
    my $self = shift;
    my $user = shift;

    my $v = $self->variableForName('SERVICE');
    my $service = $v->value() if($v);
    if ( $service && $service =~ /\s+/ ) {
        if ( $user ) {
            my $service = ariba::Ops::Utils::serviceForUser( $user );
        }
    }
    unless ( $service ) {
        if ( $user ) {
            $logger->error( "Error in MCL::service.  Could not match $user to any service delcared in this MCL" );
        }
        else {
            $logger->error( "Error in MCL::service.  No service found.  Is one delcared in the MCL?") unless $service;
        }
    }

    return( $service );
}

#
# note, only mcl-control honors this -- things like DSM that call this
# directly do NOT use this implicitly
#
sub useUI {
    my $self = shift;

    my $v = $self->variableForName('UI');
    return(1) unless($v);
    return(1) if($v->value());
    return(0);
}

sub exitWhenFinished {
    my $self = shift;

    my $v = $self->variableForName('EXIT');
    return(0) unless($v);
    return(1) if($v->value());
    return(0);
}

sub dynamicVariableString {
    my $self = shift;
    my @pairs;

    foreach my $v ($self->variables()) {
        next unless($v->isDynamic());

        push(@pairs, $v->name() . "^B^" . $v->value());
    }

    return("") unless(scalar(@pairs));
    
    my $ret = join("^A^", @pairs);
    $ret =~ s/^\s+//; $ret =~ s/\s+$//;
    $ret =~ s/\s/^S^/g;
    $ret = "-vars $ret ";
    return($ret);
}

sub setVariablesFromString {
    my $self = shift;
    my $string = shift;

    my @pairs = split(/\^A\^/, $string);
    foreach my $p (@pairs) {
        $p =~ s/\^S\^/ /g;
        my ($name, $val) = split(/\^B\^/, $p);

        $val =~ s/\\n/\n/g;
        my $v = ariba::Ops::MCL::Variable->newFromParser( $self->instance(), $name );
        $v->setValue($val);
        $v->setType('dynamic');
        #
        # we can have a variable added by Store, so we have to add it to the
        # list if it's not already in the list
        #
        unless($self->hasVariable($v)) {
            $self->appendToVariables($v);
        }
    }
}

sub setVariablesFromFile {
    my $self = shift;

    my $infile = $self->variableFileName();

    $logger->info("Reading $infile");

    open(F, "< $infile");
    while(my $line = <F>) {
        chomp $line;
        my ($var, $val) = split(/: /, $line, 2);
        $val =~ s/\\n/\n/g;
        my $v = ariba::Ops::MCL::Variable->newFromParser( $self->instance(), $var );
        $v->setValue($val);
        $v->save(); # this is needed for this to override any cached info from prior runs!!!

        #
        # we can have a variable added by Store, so we have to add it to the
        # list if it's not already in the list
        #
        unless($self->hasVariable($v)) {
            $self->appendToVariables($v);
        }
    }
    close(F);
}

sub variableFileName {
    my $self = shift;
    my $mclname = $self->instance();

    return( "/tmp/$mclname.variables" );
}

sub variableForName {
    my $self = shift;
    my $vname = shift;

    foreach my $v ($self->variables()) {
        if($v->name() eq $vname) {
            return($v);
        }
    }
    return(undef);
}

sub clearTransferList {                                                        
    my $self = shift;                                                          
                                                                               
    my $regex = "^" . $self->instance() . ":";                                 
                                                                               
    $wroteVariableFile{$self->instance()} = 0;                                 
    foreach my $k (keys %sentVariablesToHost) {                                
        next unless($k =~ /$regex/);                                           
        $sentVariablesToHost{$k} = 0;                                          
    }                                                                          
    $lockDirIsCleaned = 0;
    $self->cleanLockDir();
}

sub createVariableFile {
    my $self = shift;
    my $host = ariba::Ops::NetworkUtils::hostname();

    return if($wroteVariableFile{$self->instance()});

    my $outfile = $self->variableFileName();
    open(F, "> $outfile");

    foreach my $v ($self->variables()) {
        my $val = $v->value();
        $val =~ s/\n/\\n/g;
        print F $v->name(), ": $val\n";
    }

    close(F);
    chmod(0666, $outfile);

    $outfile =~ /\.([^\.]+)$/;
    my $user = $1;

    $sentVariablesToHost{$self->instance() . ":$host:$user"} = 1;
    $wroteVariableFile{$self->instance()} = 1;
}

sub transferVariableFile {
    my $self = shift;
    my $user = shift;
    my $host = shift;
    my $password = shift;
    my @output;

    $self->createVariableFile();
    #
    # don't do this for localhost -- we don't need to
    #
    $host .= ".ariba.com" unless($host =~ /\.ariba\.com$/ || $host eq 'localhost');
    my $localhost = ariba::Ops::NetworkUtils::hostname();
    return if($host eq $localhost || $host eq 'localhost');

    return if($sentVariablesToHost{$self->instance() . ":$host:$user"});

    my $source = $self->variableFileName();
    my $target = $source;

    $logger->info("Transfer $source to $user\@$host:$target...");

    my $command = "scp $source $user\@$host:$target";
    my $ret;

    eval {
        local $SIG{'ALRM'} = sub { die "alarm\n"; };
        alarm 30;
        $ret = ariba::rc::Utils::executeRemoteCommand(
            $command, $password, 0, undef, 30, \@output
        );
        alarm 0;
    };

    if($@) {
        $ret = 0;
        system("ps auxww | grep scp | grep $host | grep opt | awk '{print \$2}' | xargs kill -9");
        $logger->warn("Timeout transfering MCL.  Try Again");
    }

    unless($ret) {
        $logger->info("RETRY: Transfer $source to $user\@$host:$target...");

        $command = "ssh $user\@$host -x 'bash -c \"if [ -O $target ] ; then chmod 777 $target ; fi\"'";
        $ret = ariba::rc::Utils::executeRemoteCommand(
            $command, $password, 0, undef, undef, \@output
        );

        
        $command = "scp $source $user\@$host:$target";

        eval {
            local $SIG{'ALRM'} = sub { die "alarm\n"; };
            alarm 30;
            $ret = ariba::rc::Utils::executeRemoteCommand(
                $command, $password, 0, undef, 30, \@output
            );
            alarm 0;
        };

        if($@) {
            $ret = 0;
            system("ps auxww | grep scp | grep $host | grep opt | awk '{print \$2}' | xargs kill -9");
            $logger->warn("Timeout transfering MCL.  Giving Up");
        }

        unless($ret) {
            $logger->error("Failed to transfer to $host.");
            my $error = join('\n', @output);
            $logger->error($error);
            return;
        }
    }

    $logger->info("chmod 777 $user\@$host:$target...");

    $command = "ssh $user\@$host -x 'bash -c \"if [ -O $target ] ; then chmod 777 $target ; fi\"'";
    $ret = ariba::rc::Utils::executeRemoteCommand(
        $command, $password, 0, undef, undef, \@output
    );

    $sentVariablesToHost{$self->instance() . ":$host:$user"} = 1;
}

sub lockFileForHost {
    my $self = shift;
    my $host = shift;

    my $dir = $self->dir();
    $dir .= "/" . $self->instance();
    $dir .= "/locks/lock-$host";
    return($dir);
}

sub pidLockFileForHost {
    my $self = shift;
    my $host = shift;

    my $dir = $self->dir();
    $dir .= "/" . $self->instance();
    $dir .= "/locks/pid-$host";
    return($dir);
}

sub completeFileForHost {
    my $self = shift;
    my $host = shift;

    my $dir = $self->dir();
    $dir .= "/" . $self->instance();
    $dir .= "/locks/transfered-$host";
    return($dir);
}

sub initializeChildMode {
    #
    # this may get used for more later, but for now we just set this
    #
    $lockDirIsCleaned = 1;
}

sub cleanLockDir {
    my $self = shift;

    return if($lockDirIsCleaned);

    my $dir = $self->dir();
    $dir .= "/" . $self->instance();
    $dir .= "/locks";

    ariba::rc::Utils::rmdirRecursively($dir);
    ariba::rc::Utils::mkdirRecursively($dir);
    $lockDirIsCleaned = 1;
}

sub userForService {
    my $service = shift;
    my $prefix = shift;
    my $target = shift;

    $prefix = "mon" unless(defined($prefix));

    #
    # HACK -- we only have svcops on this machine
    #
    if($target =~ /penguin/) {
        return("svcops");
    }

    if($service eq "devlab") {
        if($target =~ /\.sales\.ariba\.com$/) {
            return("${prefix}sales");
        }
        return("${prefix}dev");
    }

    return("${prefix}$service");
}

sub productServiceForMCL {
    my $self = shift;
    my $service = $self->service();

    return("dev") if($service eq 'devlab');
    return($service);
}

sub transferMCLFile {
    my $self = shift;
    my $host = shift;
    my $user = shift;

    my $password = ariba::rc::Passwords::lookup($user);
    my @output;

    if( -e $self->completeFileForHost($host) ) {
        return(1);
    }

    unless( symlink( "/tmp", $self->lockFileForHost($host) ) ) {
        $logger->info("Unable to obtain lock.  Waiting");
        my $tick = 220; # do our first crash check relatively quick
        while(1) {
            select(undef, undef, undef, 0.25);
            if( -e $self->completeFileForHost($host) ) {
                $logger->info("MCL transfer completed.");
                return(1);
            }
            if( symlink( "/tmp", $self->lockFileForHost($host) ) ) {
                $logger->info("Obtained lock, transfering MCL.");
                last;
            }
            if(!($tick % 240)) { # approximately a minute
                # check to see if the locking process crashed
                my $pidfile = $self->pidLockFileForHost($host);
                my $F;
                if( open($F, "< $pidfile") ) {
                    my $locker = <$F>;
                    close(F);
                    my $table = ariba::Ops::ProcessTable->new();
                    unless( $table->processWithPIDExists( $locker ) ) {
                        $logger->info("Removing stale lock for $locker($host).");
                        unlink($self->pidLockFileForHost($host));
                        unlink($self->lockFileForHost($host));
                    }
                }
            }

            $tick++;
        }
    }

    my $F;
    my $pidfile = $self->pidLockFileForHost($host);
    open($F, "> $pidfile");
    print $F $$;
    close($F);

    my $source = $self->mclDir() . "/" . $self->instance();
    my $target = "/tmp/" . $self->instance();

    $logger->info("Transfer $source to $user\@$host:$target...");

    my $command = "scp $source $user\@$host:$target";
    my $ret;

    eval {
        local $SIG{'ALRM'} = sub { die "alarm\n"; };
        alarm 30;
        $ret = ariba::rc::Utils::executeRemoteCommand(
            $command, $password, 0, undef, 30, \@output
        );
        alarm 0;
    };

    if($@) {
        $ret = 0;
        system("ps auxww | grep scp | grep $host | grep opt | awk '{print \$2}' | xargs kill -9");
        $logger->warn("Timeout transfering MCL.  Try Again");
    }

    unless($ret) {
        $logger->info("RETRY: Transfer $source to $user\@$host:$target...");

        $command = "ssh $user\@$host -x 'bash -c \"if [ -O $target ] ; then chmod 777 $target ; fi\"'";
        $ret = ariba::rc::Utils::executeRemoteCommand(
            $command, $password, 0, undef, undef, \@output
        );

        $command = "scp $source $user\@$host:$target";

        eval {
            local $SIG{'ALRM'} = sub { die "alarm\n"; };
            alarm 30;
            $ret = ariba::rc::Utils::executeRemoteCommand(
                $command, $password, 0, undef, 30, \@output
            );
            alarm 0;
        };

        if($@) {
            $ret = 0;
            system("ps auxww | grep scp | grep $host | grep opt | awk '{print \$2}' | xargs kill -9");
            $logger->error("Timeout transfering MCL.  Giving Up");
        }

        unless($ret) {
            $logger->error("Failed to transfer to $host.");
            my $error = join('\n', @output);
            $logger->error($error);
            unlink( $self->lockFileForHost() );
            return(0);
        }
    }

    $logger->info("chmod 777 $user\@$host:$target...");

    $command = "ssh $user\@$host -x 'bash -c \"if [ -O $target ] ; then chmod 777 $target ; fi\"'";
    $ret = ariba::rc::Utils::executeRemoteCommand(
        $command, $password, 0, undef, undef, \@output
    );

    $self->transferVariableFile($user, $host, $password);

    symlink( "/tmp", $self->completeFileForHost($host) );
    unlink( $self->lockFileForHost() );
    return(1);
}

sub changeVariables {
    my $self = shift;

    foreach my $v ($self->variables()) {
        print "Set value for \$\{", $v->name(), "\}  \[", $v->value(), "\]\n";
        my $input = <STDIN>;
        chomp($input);
        if($input !~ /^\s*$/) {
            $v->setValue($input);
        }
    }
}

sub execute {
    my $self = shift;
    my $ret;

    foreach my $step ($self->steps()) {
        if($step->isCompleted()) {
            $logger->info("Skipping step " . $step->name() . " (already completed)");
            next;
        }
        $logger->info("Running Step " . $step->name() . "...");
        $step->setStatus('Attempted');
        $ret = $step->execute();
        if( $ret ) {
            if($ret == -1) {
                $step->setStatus('Waiting');
            } else {
                $step->setStatus('Completed');
            }
            $step->storeVariablesFromResult();
        } else {
            if($step->storeSuccess() || $step->continueOnError()) {
                #
                # this is a special case... we're setting a variable based on
                # if this step succeeds or fails, so we continue execution
                # even if it fails.
                #
                $step->setStatus('Error OK');
                $step->storeVariablesFromResult();
            } else {
                $step->setStatus('Failed');
                return(0);
            }
        }
    }


    return(1);
}

# I can't find anything that calls this subroutine.  It may be dead code.
sub executeStep {
    my $self = shift;
    my $stepname = shift;

    my $step = stepForName($stepname);

    $step->setStatus('Attempted');
    if( $step->execute() ) {
        $step->setStatus('Completed');
        $step->storeVariablesFromResult();
    } else {
        if( $step->storeSuccess() || $step->continueOnError() ) {
            $step->setStatus('Completed');
            $step->storeVariablesFromResult();
        } else {
            $step->setStatus('Failed');
        }
        return(0);
    }

    return(1);
}

sub isCompletedSuccessfully {
    my $self = shift;

    foreach my $step ($self->steps()) {
        return(0) unless($step->isCompleted());
    }

    return(1);
}

sub resetRerunSteps {
    my $self = shift;

    foreach my $step ($self->steps()) {
        if($step->isCompleted() && $step->rerunOnRestart()) {
            $step->setStatus("");
        }
    }
}

sub executeInParallel {
    my $self = shift;

    $self->resetRerunSteps();
    $self->moveKnownHosts();
    $self->resolveVirtualHosts();
    $self->forceUpdateExpandos();

    while(1) {
        my $ret = $self->launchAndCheckSteps();
        last unless($ret);
        sleep(1);
    }

    $self->recursiveSave();
    $self->restoreKnownHosts();

    if($self->aggregateLogsTo()) {
        $self->aggregateLogs();
    }

    return($self->isCompletedSuccessfully());
}

sub launchAndCheckSteps {
    my $self = shift;

    my $pid;

    return(0) if($self->endTime());

    my $done = 1;
    foreach $pid (keys %children) {
        if($children{$pid}) {
            $done = 0;
            last;
        }
    }

    foreach my $step ($self->steps()) {
        if((!$stepsAttempted{$step->name()} && !$self->isPaused()) ||
            $stepsAttempted{$step->name()} eq 'STARTED') {
                $done = 0;
                last;
        }
    }

    #
    # wait for this guy too
    #
    if($stepsAttempted{'REMOTE OUTPUT'} && $stepsAttempted{'REMOTE OUTPUT'} eq 'STARTED') {
        $done = 0;
    }

    if($done) {
        $self->setEndTime( time() );
        $self->setPreviousElapsedTime( $self->endTime() - $self->startTime() + $self->previousElapsedTime() );
        return(0);
    }

    # check for slow steps here
    foreach my $step ($self->steps()) {
        next unless($step->isRunning());
        next unless($step->alertTime());
        next if($step->alerted() > $step->startTime());

        if(time() - $step->startTime() > $step->alertTime()) {
            my $prettyTime = formatElapsedTime($step->alertTime());
            my $msg = "Step " . $step->name() . " (" . $step->title() . ") is running for longer than $prettyTime.";
            $self->notifyForEvent('slowstep',$msg, $step);
            $step->setAlerted(time());
        }
    }

    my $launched = 0;
    if($tryMoreSteps && !$self->isPaused()) {
        $tryMoreSteps = 0;
        foreach my $step ($self->steps()) {
            # throttle step launching in favor of allowing the UI to run
            if($launched > 4) {
                $tryMoreSteps = 1;
                last;
            }
            if($step->isExpandoParent()) {
                $stepsAttempted{$step->name()} = "FINISHED";
                next;
            }
            if($step->isCompleted() || $step->isFailed() || $step->isWaiting()) {
                $stepsAttempted{$step->name()} = "FINISHED";
            }
            if(
                $stepsAttempted{$step->name()} eq "FINISHED" &&
                $step->status() eq 'Running'
            ) {
                #
                # this state only happens if the forked process dies before
                # finishing somehow -- 
                #
                $step->setStatus('Confused');
                my $msg = "Step " . $step->name() . " (" . $step->title() . ") Crashed";
                $self->notifyForEvent("failure", $msg, $step);
                $self->appendToStepFailures($step->name());
            }
            next if($stepsAttempted{$step->name()});

            my $launchStep = 1;
            foreach my $dependsOn ($step->depends()) {
                my $d = $self->stepForName($dependsOn);
                next unless($d);
                unless($d->isCompleted()) {
                    $launchStep = 0;
                    if($stepsAttempted{$d->name()} && $stepsAttempted{$d->name()} ne 'STARTED') {
                        $stepsAttempted{$step->name()} = "PREREQ FAILED";
                        #
                        # This can cause other steps to become blocked, so
                        # we have to re-enter if we see this... this only
                        # affects MCLs where steps are out of order, but
                        # needs to be accounted for none the less.
                        #
                        $tryMoreSteps = 1;
                        last;
                    }
                }
            }

            next unless($launchStep);

            if($step->runGroup() && $step->status() ne 'Retry') {
                unless(defined($runningForGroup{$step->runGroup()})) {
                    $runningForGroup{$step->runGroup()} = 0;
                }
                my $running = $runningForGroup{$step->runGroup()};
                unless(defined($running)) {
                    $runningForGroup{$step->runGroup()} = $self->runningProcessesForGroup($step->runGroup());
                    $running = $runningForGroup{$step->runGroup()};
                }
                if($running >= $self->maxRunningProcessesForGroup($step->runGroup())) {
                    next;
                }
                $runningForGroup{$step->runGroup()}++;
            }

            $step->setOutput("");
            foreach my $action ($step->actions()) {
                $action->setOutput("");
            }
            $step->setStartTime(time());
            $step->removeSharedOutput();
            $step->setEndTime(0);
            $step->setMetaInfo("");
            $step->setStatus("Running"); # implicitly calls save()
            if($pid = fork()) {
                #
                # parent
                #
                $stepsAttempted{$step->name()} = "STARTED";
                $children{$pid} = $step->name();
                $launched++;
            } else {
                #
                # child
                #
                # first things first - change the logging, and the session group

                setsid();

                my $logfile = $step->nextLogfile();
                $logger->setLogFile($logfile);
                $logger->setFh(undef);

                # $0 .= "-" . $step->name();

                # log any exceptions
                $SIG{__WARN__} = \&handlePerlExceptionChild;
                $SIG{__DIE__} = \&handlePerlExceptionChild;

                my $title = "";
                $title = " (" . $step->title() . ")" if($step->title());
                $logger->info("Starting Step " . $step->name() . "$title");
                my $status;
                my $retVal;
                if(inDebugMode()) {
                    $retVal = $step->dryrun();
                } else {
                    $retVal = $step->execute();
                }
                if( $retVal ) {
                    if($retVal == -1) {
                        $status = "Waiting";
                    } else {
                        $status = "Completed";
                    }
                    $logger->info("Step " . $step->name() . "$title $status");

                    if($status eq 'Completed') {
                        if($step->executeIf() || $step->executeUnless()) {
                            if($step->output() =~ /not run because/) {
                                $status="Skipped";
                            }
                        }
                    }
                } else {
                    if($step->storeSuccess() || $step->continueOnError()) {
                        $status="Error OK";
                        $logger->info("Step " . $step->name() . "$title Failed (but continuing anyway)");
                    } else {
                        $status="Failed";
                        $logger->info("Step " . $step->name() . "$title Failed");
                    }
                }
                $step->setEndTime(time());
                dmail::LockLib::requestlock($self->lockFile(),5);
                $step->setStatus($status);
                $step->recursiveSave();
                dmail::LockLib::releaselock($self->lockFile());

                #
                # save some state for the parent
                #
                $step->saveSharedOutput();
                close($logger->fh());
                exit(0);
            }
        }
    }

    #
    # reap children here
    #
    my $reaped = 0;
    do {
        $pid = waitpid(-1, WNOHANG);
        if($pid > 0) {
            $logger->info("Reaping child $pid (" . $children{$pid} . ")");
            if($children{$pid} eq 'REMOTE OUTPUT') {
                $children{$pid} = undef;
                $stepsAttempted{'REMOTE OUTPUT'} = "FINISHED";
            } else {
                $reaped++;
                my $exitCode = ($? >> 8);
                $stepsAttempted{$children{$pid}} = "FINISHED";
                #
                # when a step finishes, it can unblock dependancies, so we
                # attempt to start more steps since the state changed.
                #
                $tryMoreSteps = 1;
                my $step = $self->stepForName($children{$pid});
                if($step) {

                    if($step->runGroup()) {
                        $runningForGroup{$step->runGroup()}--;
                    }

                    #
                    # read in state from the child
                    #
                    $step->readSharedOutput();
                    my $reload = $step->storeVariablesFromResult();

                    if($reload) {
                        #
                        # reloading the MCL can cause weird PO behavior here...
                        # so we do this again to make sure we have the right
                        # status here.
                        #
                        $step = $self->stepForName($children{$pid});
                        $step->readSharedOutput();
                    }

                    if($exitCode) {
                        unless( ($step->isCompleted() || $step->isFailed() || $step->isWaiting()) && -e $step->sharedOutputFile() ) {
                            $step->setStatus('Crashed');
                        }
                    }

                    if($step->isFailed()) {
                        my $msg = "Step " . $step->name() . " (" . $step->title() . ") Failed";
                        $msg .= "\n$msg:\n\nOutput:\n\n";
                        $msg .= $step->output();
                        $self->notifyForEvent("failure", $msg, $step);
                        $self->appendToStepFailures($step->name());
                    }
                
                    $step->setEndTime(time());
                    my $elapsed = $step->endTime() - $step->startTime();
                    $elapsed = formatElapsedTime($elapsed);
                    $logger->info("Step " . $step->name() . " (" . $step->title() . ") " . $step->status() . " in $elapsed.");
                    $step->recursiveSave();
                    $children{$pid} = undef;
                }
            }
        }
    } while($pid > 0 && $reaped < 5); # throttle in favor of UI responsiveness

    return(1);
}

sub handlePerlException {
    my $exception = shift;
    closeCurses();
    $logger->setQuiet(0);
    $logger->error("$exception");

    my $i = 0;
    while( my ($func, $line) = (caller($i++))[3,2] ) {
        $logger->error("-> $line:$func");
    }

    print "\n";
    exit 1;
}

sub winch_handler {
    return if($winchLock);
    $winchLock = 1;
    pushInput(KEY_CTRL("L"));
    $winchLock = 0;
}

sub suspend {
    closeCurses();
    kill('STOP',$$);
}

sub continue {
    initCurses();
    pushInput(KEY_CTRL("L"));
}

sub DISPLAY_STEP_LIST { 0; }
sub DISPLAY_STEP_DETAILS { 1; }
sub DISPLAY_STEP_LIST_MENU { 2; }
sub DISPLAY_CONFIRM_MENU { 3; }
sub DISPLAY_GROUP_SETTINGS { 4; }

sub initCurses {
    initscr(MODE_CBREAK);
    attrset(A_NORMAL);
}

sub closeCurses {
    erase();
    refresh();
    endwin();
}

sub defaultStatus {
    my $self = shift;
    my $step = shift;

    unless ($stepsAttempted{$step->name()}) {
        return("Not Started");
    }

    if($stepsAttempted{$step->name()} eq 'PREREQ FAILED') {
        return("Blocked");
    }

    return("Unknown");
}

sub renumberSteps {
    my $self = shift;
    my $count;

    foreach my $s ($self->steps()) {
        if($s->expando()) {
            my $expando = $self->stepForName($s->expando());
            if($expando->folderStatus() eq 'closed') {
                $s->setNum(-1);
                next;
            }
        }
        $s->setNum($count);
        if($stepIndex) {
            $stepIndex->{"NUM $count"} = $s;
        }
        $count++;
    }

    return($count-1);
}

sub forceUpdateExpandos {
    my $self = shift;

    foreach my $ex ($self->steps()) {
        next unless($ex->isExpandoParent());
        $ex->setAttribute('status', $ex->expandoStatus());
    }
}

sub controlCenter {
    my $self = shift;
    my $mclCompleted = 0;
    my $selected = 0;
    my $uiInfo;
    my $mode = DISPLAY_STEP_LIST;
    my $count = 0;
    my $inputAfterFinished = 0;

    $self->resetRerunSteps();
    $self->moveKnownHosts();
    $self->resolveVirtualHosts();
    $self->forceUpdateExpandos();

    $main::quiet = 1; # we always want this here!

    $SIG{'QUIT'}="IGNORE";
    $SIG{'INT'}="IGNORE";
    $SIG{'TERM'}="IGNORE";
    $SIG{'HUP'}="IGNORE";
    $SIG{'TSTP'}=\&ariba::Ops::MCL::suspend;
    $SIG{'CONT'}=\&ariba::Ops::MCL::continue;
    $SIG{'__WARN__'}=\&ariba::Ops::MCL::handlePerlException;
    $SIG{'__DIE__'}=\&ariba::Ops::MCL::handlePerlException;

    my $maxSelect = $self->renumberSteps();

    $SIG{INT} = sub {};
    $SIG{'WINCH'}='ariba::Ops::MCL::winch_handler';
    
    $logger->setQuiet(1);
    close(STDERR);
    #
    # have to capture this somewhere.
    #
    # open(NULL, "> /dev/null");
    initCurses();

    if($ENV{'ARIBA_MCL_PPID'}) {
        $uiInfo->{'Error'} = "New window spawned for " . $self->instance() . " -- use Ctl-A,Ctl-N to switch windows";
    }


    my $ch = undef;
    while(1) {
        if(defined($ch)) {
            if($ch eq KEY_CTRL("L")) {
                closeCurses();
                initCurses();
            }
            delete($uiInfo->{'Error'});
            if($ENV{'ARIBA_MCL_PPID'}) {
                $uiInfo->{'Error'} = "New window spawned for " . $self->instance() . " -- use Ctl-A,Ctl-N to switch windows";
            }

            if($mode == DISPLAY_CONFIRM_MENU) {
                if($ch eq KEY_UP || $ch eq 'k') {
                    $uiInfo->{'menuSelected'}--;
                    $uiInfo->{'menuSelected'} = 0 if($uiInfo->{'menuSelected'} < 0);
                } elsif($ch eq KEY_DOWN || $ch eq 'j') {
                    $uiInfo->{'menuSelected'}++;
                    $uiInfo->{'menuSelected'} = scalar(@displayStepsMenu)-1
                        if($uiInfo->{'menuSelected'} >= scalar(@displayStepsMenu));
                } elsif($ch eq KEY_ENTER) {
                    my $ack = $confirmMenu[$uiInfo->{'menuSelected'}];
                    $ack =~ s/^([A-Z]).*/$1/;
                    my $opp = $uiInfo->{'confirmOpp'};
                    if( $ack ne "X" ) {
                        if($opp eq 'C') {
                            my $step = $self->stepForUiNumber($selected);
                            my $msg = "Step " . $step->name() . " (" . $step->title() . ") Marked Complete.";
                            $self->notifyForEvent('markedcomplete',$msg, $step);

                            $step->setStatus("Completed");
                            $step->storeVariablesFromResult();
                            $step->setOutput("Step Marked Complete By User");
                            $stepsAttempted{$step->name()} = "FINISHED";
                            $tryMoreSteps = 1;
                            foreach my $k (keys %stepsAttempted) {
                                $stepsAttempted{$k} = "" if($stepsAttempted{$k} eq 'PREREQ FAILED');
                            }
                            if($mclCompleted) {
                                $self->setEndTime(0);
                                $self->setStartTime(time());
                                $mclCompleted = 0;
                            }
                        }
                        if($opp eq 'R' || $opp eq 'X') {
                            my $step = $self->stepForUiNumber($selected);
                            my $msg = "Step " . $step->name() . " (" . $step->title() . ") Retried.";
                            $self->notifyForEvent('retry',$msg, $step);
                            if($opp eq 'R') {
                                $step->setStatus("Retry");
                            } else {
                                $step->setStatus("");
                            }
                            $tryMoreSteps = 1;
                            $stepsAttempted{$step->name()} = "";
                            foreach my $k (keys %stepsAttempted) {
                                $stepsAttempted{$k} = "" if($stepsAttempted{$k} eq 'PREREQ FAILED');
                            }
                            if($mclCompleted) {
                                $self->setEndTime(0);
                                $self->setStartTime(time());
                                $mclCompleted = 0;
                            }
                        }
                        if($opp eq 'S') {
                            foreach my $step ($self->steps()) {
                                if($step->isOptional()) {
                                    $step->setStatus("Not Started");
                                    $stepsAttempted{$step->name()} = "";
                                    $tryMoreSteps = 1;
                                }
                            }
                            if($mclCompleted) {
                                $self->setEndTime(0);
                                $self->setStartTime(time());
                                $mclCompleted = 0;
                            }
                        }
                        if($opp eq 'E') {
                            $mclCompleted = 2;
                        }
                    } else { ## cancel
                        my $action = $uiInfo->{'confirmAction'};
                        $uiInfo->{'Error'} = "$action canceled";
                    }
                    $uiInfo->{'confirmAction'} = undef;
                    $uiInfo->{'confirmOpp'} = undef;
                    $mode = DISPLAY_STEP_LIST;
                }
            } elsif($mode == DISPLAY_STEP_LIST_MENU) {
                if($ch eq KEY_UP || $ch eq 'k') {
                    $uiInfo->{'menuSelected'}--;
                    $uiInfo->{'menuSelected'} = 0 if($uiInfo->{'menuSelected'} < 0);
                } elsif($ch eq KEY_DOWN || $ch eq 'j') {
                    $uiInfo->{'menuSelected'}++;
                    $uiInfo->{'menuSelected'} = scalar(@displayStepsMenu)-1
                        if($uiInfo->{'menuSelected'} >= scalar(@displayStepsMenu));
                } elsif($ch eq KEY_ENTER) {
                    my $opp = $displayStepsMenu[$uiInfo->{'menuSelected'}];
                    $opp =~ s/^([A-Z]).*/$1/;
                    if($opp eq 'C') {
                        my $step = $self->stepForUiNumber($selected);
                        unless($step->status() eq 'Running') {
                            $uiInfo->{'confirmOpp'} = 'C';
                            $uiInfo->{'confirmAction'} = 'Mark Complete';
                            $uiInfo->{'menuSelected'} = 0;
                            $mode = DISPLAY_CONFIRM_MENU;
                        } else {
                            $uiInfo->{'Error'} = "Cannot Mark a Running Step Complete";
                        }
                    } elsif($opp eq 'P') {
                        if($self->isPaused()) {
                            $self->setPaused(0);
                            $tryMoreSteps = 1;
                            if($mclCompleted) {
                                $self->setEndTime(0);
                                $self->setStartTime(time());
                                $mclCompleted = 0;
                            }
                        } else {
                            $self->setPaused(1);
                        }
                    } elsif($opp eq 'G') {
                        if(scalar($self->runGroups()) > 0) {
                            $mode = DISPLAY_GROUP_SETTINGS;
                            $uiInfo->{'groupSel'} = 0;
                        } else {
                            $uiInfo->{'Error'} = "This MCL does not have any RunGroups.";
                        }
                    } elsif($opp eq 'S') {
                        $uiInfo->{'confirmOpp'} = 'S';
                        $uiInfo->{'confirmAction'} = 'Start Optional';
                        $uiInfo->{'menuSelected'} = 0;
                        $mode = DISPLAY_CONFIRM_MENU;
                    } elsif($opp eq 'R' || $opp eq 'X') {
                        my $step = $self->stepForUiNumber($selected);
                        unless($step->status() eq 'Running') {
                            $uiInfo->{'confirmOpp'} = $opp;
                            if($opp eq 'R') {
                                $uiInfo->{'confirmAction'} = 'Restart Step';
                            } else {
                                $uiInfo->{'confirmAction'} = 'Requeue Step';
                            }
                            $uiInfo->{'menuSelected'} = 0;
                            $mode = DISPLAY_CONFIRM_MENU;
                        } else {
                            $uiInfo->{'Error'} = "Cannot Restart a Running Step";
                        }
                    } elsif($opp eq 'Q') {
                        if($mclCompleted) {
                            $uiInfo->{'confirmOpp'} = 'E';
                            $uiInfo->{'confirmAction'} = 'Exit MCL Control Center';
                            $uiInfo->{'menuSelected'} = 0;
                            $mode = DISPLAY_CONFIRM_MENU;
                        } else {
                            $uiInfo->{'Error'} = "Cannot Exit While MCL is Running";
                        }
                    }
                    $mode = DISPLAY_STEP_LIST unless($mode == DISPLAY_CONFIRM_MENU || $mode == DISPLAY_GROUP_SETTINGS);
                } elsif($ch eq KEY_ESCAPE || $ch eq 'E') {
                    $mode = DISPLAY_STEP_LIST;
                }
            } elsif($mode == DISPLAY_STEP_LIST) {
                my $maxy = getmaxy();
                my $top = $uiInfo->{'top'};
                my $bot = $top+($maxy-7);
                if($ch eq KEY_UP || $ch eq 'k') {
                    $selected-- if($selected);
                    if($selected < $top) {
                        $uiInfo->{'top'}--;
                    }
                } elsif($ch eq KEY_DOWN || $ch eq 'j') {
                    $selected++ if($selected < $maxSelect);
                    if($selected > $bot) {
                        $uiInfo->{'top'}++;
                    }
                } elsif($ch eq KEY_PAGEUP || $ch eq 'b') {
                    $selected -= ($bot-$top);
                    $selected = 0 if($selected < 0);
                    if($selected < $top) {
                        $uiInfo->{'top'} = $selected;
                    }
                } elsif($ch eq KEY_PAGEDOWN || $ch eq ' ') {
                    $selected += ($bot-$top);
                    $selected = $maxSelect if($selected > $maxSelect);
                    if($selected > $bot) {
                        $uiInfo->{'top'} = $selected - ($bot-$top);
                    }
                } elsif($ch eq KEY_CTRL("I")) {
                    my $firstFail;
                    my $nextFail;
                    foreach my $s ($self->steps()) {
                        next unless($s->num() >= 0);
                        if($s->isFailed() || $s->isWaiting()) {
                            $firstFail = $s unless($firstFail);
                            $nextFail = $s if($s->num() > $selected);
                        }
                        last if($nextFail);
                    }
                    $nextFail = $firstFail unless($nextFail);
                    if($nextFail) {
                        $selected = $nextFail->num();
                        if($selected < $top) {
                            $uiInfo->{'top'} = $selected;
                        } elsif($selected > $bot) {
                            if($selected > $maxSelect - ($bot-$top)) {
                                $uiInfo->{'top'} = $maxSelect - ($bot-$top);
                            } else {
                                $uiInfo->{'top'} = $selected;
                            }
                        }
                    } else {
                        $uiInfo->{'Error'} = "No Blocking Steps";
                    }
                } elsif($ch eq KEY_ENTER) {
                    my $step = $self->stepForUiNumber($selected);
                    if($step->isExpandoParent()) {
                        if($step->folderStatus() eq 'closed') {
                            $step->setFolderStatus('open');
                        } else {
                            $step->setFolderStatus('closed');
                        }
                        $maxSelect = $self->renumberSteps();
                    } else {
                        $mode = DISPLAY_STEP_DETAILS;
                        $uiInfo->{'detailMode'} = 'Output';
                        $uiInfo->{'tt'} = 0;
                        $uiInfo->{'tx'} = 0;
                    }
                } elsif($ch eq KEY_F(1) || $ch eq 'M') {
                    $mode = DISPLAY_STEP_LIST_MENU;
                    $uiInfo->{'menuSelected'} = 0;
                } elsif($ch eq 'E' || $ch eq KEY_ESCAPE) {
                    if($mclCompleted) {
                        $uiInfo->{'confirmOpp'} = 'E';
                        $uiInfo->{'confirmAction'} = 'Exit MCL Control Center';
                        $uiInfo->{'menuSelected'} = 0;
                        $mode = DISPLAY_CONFIRM_MENU;
                    } else {
                        $uiInfo->{'Error'} = "Cannot Exit While MCL is Running";
                    }
                }
            } elsif($mode == DISPLAY_STEP_DETAILS) {
                if($ch eq KEY_UP || $ch eq 'k') {
                    $uiInfo->{'tt'}-- if($uiInfo->{'tt'});
                } elsif($ch eq KEY_DOWN || $ch eq 'j') {
                    $uiInfo->{'tt'}++ if($uiInfo->{'tt'} < ($uiInfo->{'outputLen'} - $uiInfo->{'outputLines'}) );
                } elsif($ch eq KEY_LEFT || $ch eq 'h') {
                    $uiInfo->{'tx'}-=8;
                    $uiInfo->{'tx'}=0 if($uiInfo->{'tx'} < 0);
                } elsif($ch eq KEY_RIGHT || $ch eq 'l') {
                    $uiInfo->{'tx'}+=8;
                } elsif($ch eq KEY_CTRL('A') || $ch eq '^') {
                    $uiInfo->{'tx'}=0;
                } elsif($ch eq KEY_ENTER || $ch eq KEY_ESCAPE || $ch eq 'E') {
                    $mode = DISPLAY_STEP_LIST;
                } elsif($ch eq 'b' || $ch eq 'B' || $ch eq KEY_PAGEUP || $ch eq KEY_CTRL('B')) {
                    $uiInfo->{'tt'} -= ($uiInfo->{'outputLines'}-1);
                    $uiInfo->{'tt'} = 0 if($uiInfo->{'tt'} < 0);
                } elsif($ch eq ' ' || $ch eq KEY_PAGEDOWN || $ch eq KEY_CTRL('F')) {
                    $uiInfo->{'tt'} += ($uiInfo->{'outputLines'}-1);
                    $uiInfo->{'tt'} = ($uiInfo->{'outputLen'} - $uiInfo->{'outputLines'}) if($uiInfo->{'tt'} >= ($uiInfo->{'outputLen'} - $uiInfo->{'outputLines'}));
                    $uiInfo->{'tt'} = 0 if($uiInfo->{'tt'} < 0);
                } elsif($ch eq KEY_HOME || $ch eq 'H') {
                    $uiInfo->{'tt'} = 0;
                } elsif($ch eq KEY_END || $ch eq 'G') {
                    $uiInfo->{'tt'} = ($uiInfo->{'outputLen'} - $uiInfo->{'outputLines'});
                    $uiInfo->{'tt'} = 0 if($uiInfo->{'tt'} < 0);
                } elsif($ch eq 'L') {
                    if($uiInfo->{'detailMode'} eq 'Output') {
                        $uiInfo->{'detailMode'} = 'Log Data';
                    } elsif($uiInfo->{'detailMode'} eq 'Log Data') {
                        $uiInfo->{'detailMode'} = 'Definition of Step';
                    } else {
                        $uiInfo->{'detailMode'} = 'Output';
                    }
                    $uiInfo->{'tt'} = 0;
                    $uiInfo->{'tx'} = 0;
                }
            } elsif($mode == DISPLAY_GROUP_SETTINGS) {
                my $g = $self->groupForSelected($uiInfo->{'groupSel'});
                if($ch eq KEY_UP || $ch eq 'k') {
                    $uiInfo->{'groupSel'}-- if($uiInfo->{'groupSel'});
                } elsif($ch eq KEY_DOWN || $ch eq 'j') {
                    $uiInfo->{'groupSel'}++;
                    if($uiInfo->{'groupSel'} == scalar($self->runGroups())) {
                        $uiInfo->{'groupSel'}--;
                    }
                } elsif($ch eq KEY_ENTER || $ch eq KEY_ESCAPE || $ch eq 'E') {
                    $mode = DISPLAY_STEP_LIST;
                } elsif($self->isPaused() && !$g->locked()) {
                    if($ch eq KEY_RIGHT || $ch eq '+') {
                        $g->setMaxParallelProcesses($g->maxParallelProcesses() + 1);
                    } elsif($ch eq KEY_LEFT || $ch eq '-') {
                        $g->setMaxParallelProcesses($g->maxParallelProcesses() - 1);
                    }
                }
            }
        }

        $self->checkForStatusMessages();

        if($mode == DISPLAY_STEP_LIST ||
            $mode == DISPLAY_STEP_LIST_MENU ||
            $mode == DISPLAY_CONFIRM_MENU
        ) {
            $self->displaySteps($selected, $uiInfo, $mode, $maxSelect);
        } elsif($mode == DISPLAY_STEP_DETAILS) {
            $self->displayStepDetails($selected, $uiInfo);
        } elsif($mode == DISPLAY_GROUP_SETTINGS) {
            $self->displayGroupDetails($uiInfo);
        }

        $ch = undef;

        if($mclCompleted && $self->isCompletedSuccessfully() && $ENV{'ARIBA_MCL_PPID'}) {
            # sub MCL screen sessions exit on success instantly.
            last;
        }

        last if($mclCompleted == 2);

        if($mclCompleted && (!$self->exitWhenFinished() || $inputAfterFinished || !$self->isCompletedSuccessfully())) {
            #
            # blocking get here -- no background happenings
            #
            $ch = getch(0);
        } else {
            #
            # watch per input while we sleep
            #
            for(my $sleep = 0; $sleep < 5; $sleep++) {
                select(undef,undef,undef,.05);
                last if($ch = getch(1));
            }

            if($mclCompleted && $self->isCompletedSuccessfully() && $ch) {
                $inputAfterFinished=1;
            }

            #
            # Run the MCL and keep on top of its progress
            #
            unless($ch) { # favor processing keystrokes over launching commands
                unless( $self->launchAndCheckSteps() ) {
                    $mclCompleted = 1;
                    $self->recursiveSave();
                }
            }
        }

        if($self->exitWhenFinished() && $self->isCompletedSuccessfully() && !$inputAfterFinished && $self->endTime()) {
            if(time() - $self->endTime() > 180) {
                last;
            }
        }
    }

    my $displayTime = formatElapsedTime( $self->previousElapsedTime() );
    my $title = $self->title() || $self->instance();
    my $status;
    if($self->isCompletedSuccessfully()) {
        $status = "completed successfully";
    } else {
        $status = "failed";
    }
    closeCurses();
    $logger->info("$title $status in $displayTime.");
    print "$title $status in $displayTime.\n";

    $self->restoreKnownHosts();

    if($self->aggregateLogsTo()) {
        $self->aggregateLogs();
    }

    return($self->isCompletedSuccessfully());
}

sub checkForStatusMessages {
    my $self = shift;

    my $dir = $self->messagedir();
    my $D;

    opendir($D, $dir);
    while (my $f = readdir($D)) {
        next if($f =~ /^\.+$/);

        my $F;
        open($F, "$dir/$f");
        my $line = <$F>;
        close($F);

        chomp $line;
        my ($stepname, $status) = split(/:/, $line);
        my $step = $self->stepForName($stepname);
        $step->setMetaInfo($status);

        unlink("$dir/$f");
    }
    closedir($D);
}

sub groupForSelected {
    my $self = shift;
    my $sel = shift;

    foreach my $g ($self->runGroups()) {
        return($g) unless($sel);
        $sel--;
    }

    return(undef);
}

sub moveKnownHosts {
    my $self = shift;

    my $tgt = $ENV{'HOME'} . "/.ssh/known_hosts.$$";
    my $src = $ENV{'HOME'} . "/.ssh/known_hosts";

    rename($src,$tgt);
}

sub restoreKnownHosts {
    my $self = shift;

    my $src = $ENV{'HOME'} . "/.ssh/known_hosts.$$";
    my $tgt = $ENV{'HOME'} . "/.ssh/known_hosts";

    rename($src,$tgt);
}

sub stepForUiNumber {
    my $self = shift;
    my $selected = shift;
    my $step;

    if($stepIndex && $stepIndex->{"NUM $selected"}) {
        return($stepIndex->{"NUM $selected"});
    }

    foreach my $s ($self->steps()) {
        $step = $s if($selected == $s->num());
        last if($step);
    }

    return($step);  
}

sub displayGroupDetails {
    my $self = shift;
    my $ui = shift;
    my $maxY = getmaxy();
    my $maxX = getmaxx();

    my $selected = $ui->{'groupSel'};
    my $top = $ui->{'groupTop'} || 0;
    my $onScreen = ($maxY - 8);

    if($selected < $top) {
        $top = $selected;
    }
    my $bot = $top+$onScreen;
    if($selected > $bot) {
        $top = $selected - $onScreen;
        $bot = $selected;
    }
    $ui->{'groupTop'} = $top;

    erase();
    box();

    my $hint = "";
    unless($self->isPaused()) {
        $hint = " (pause MCL to change these settings)";
    }

    addstr(1,2,"Group Settings:$hint");
    my $buf = sprintf("%-30s  %s", "Group","Max Parallel");
    addstr(3,3,$buf);
    $buf = sprintf("%-30s  %s", "------------","------------");
    addstr(4,3,$buf);

    my $count = 0;
    my $y = 5;
    foreach my $g ($self->runGroups()) {
        if($count >= $top) {
            my $key="";
            $key = " O-m" if($g->locked());
            if($count == $selected) {
                attrset(A_REVERSE);
                if($self->isPaused() && !$g->locked()) {
                    $buf = sprintf("%-30s  <[-] %d [+]>", $g->name(), $g->maxParallelProcesses());
                } else {
                    $buf = sprintf("%-30s       %d%s", $g->name(), $g->maxParallelProcesses(), $key);
                }
            } else {
                $buf = sprintf("%-30s       %d%s", $g->name(), $g->maxParallelProcesses(), $key);
            }
            addstr($y++, 3, $buf);
            attrset(A_NORMAL);
        }
        $count++;
        last if($count > $bot);
    }

    refresh();
}

sub displayStepDetails {
    my $self = shift;
    my $selected = shift;
    my $ui = shift;
    my $step = $self->stepForUiNumber($selected);
    my $maxY = getmaxy();
    my $maxX = getmaxx();
    my $mode = $ui->{'detailMode'};
    my $tailMode = 0;
    my $hint = " (Press Shift-L to switch between view modes)";

    my @output;
    if($mode eq 'Output') {
        @output = split("\n", $step->output());
        unless(@output) {
            if(!$step->isRunning()) {
                # list the step definition
                my $definition = $step->definition();
                @output = split("\n", $definition);
                $mode = "Definition of Step";
                $hint = "";
            } else {
                @output = split("\n", $step->logdata());
                $mode = "Log Data";
                $hint = "";
            }
        }
    } elsif($mode eq 'Log Data') {
        @output = split("\n", $step->logdata());
        $hint = " (Press Shift-L to switch to regular output mode)";
    } else {
        my $definition = $step->definition();
        @output = split("\n", $definition);
        $mode = "Definition of Step";
    }

    if($step->isRunning() && $step->isRemote() == 2) {
        # this is really remote, let's fetch the logfile real time
        if(!$stepsAttempted{'REMOTE OUTPUT'} || $stepsAttempted{'REMOTE OUTPUT'} ne "STARTED") {
            if(my $pid = fork()) {
                $children{$pid} = 'REMOTE OUTPUT';
                $stepsAttempted{'REMOTE OUTPUT'} = "STARTED";
            } else {
                setsid();
                $step->fetchRemoteLogs();
                exit(0);
            }
        }
    }


    if($mode ne 'Output' && $step->isRunning()) {
        if($ui->{'tt'} >= ($ui->{'outputLen'} - $ui->{'outputLines'}) ) {
            $tailMode = 1;
        }
    }

    erase();
    box();
    my $y = 1;
    my $str=sprintf("Details for Step %s %-35s",substr($step->name(),0,5), substr($step->title(),0,$maxX-10));
    addstr($y++,2,$str);
    addstr($y,3,"Status:");
    $str = $step->status() || $self->defaultStatus($step);
    if($step->storeSuccess() && $str eq 'Error OK') {
        $str = "Checked";
    }

    attrset( colorForStatus($str) );

    if($step->metaInfo() && $str eq 'Running') {
        $str = $step->metaInfo();
    }

    $str = "[$str]";
    addstr($y++,11,$str);
    attrset(A_NORMAL);

    if($step->startTime()) {
        $str = sprintf("Start Time: %s", scalar(localtime($step->startTime())));
        addstr($y++,3,$str);
    }
    if($step->endTime()) {
        $str = sprintf("End Time: %s", scalar(localtime($step->endTime())));
        addstr($y++,3,$str);
    }

    if(scalar(@output)) {
        $ui->{'outputLen'} = scalar(@output);
        $y++;
        addstr($y++,3,"$mode:$hint");
        addstr($y++,3,"----------------------------------");
        $ui->{'outputLines'} = $maxY-$y-2;
        $ui->{'topOutput'} = $y;

        if($tailMode) {
            $ui->{'tt'} = ($ui->{'outputLen'} - $ui->{'outputLines'});
            $ui->{'tt'} = 0 if($ui->{'tt'} < 0);
        }
        if($ui->{'tt'} > ($ui->{'outputLen'} - $ui->{'outputLines'})) {
            $ui->{'tt'} = ($ui->{'outputLen'} - $ui->{'outputLines'});
            $ui->{'tt'} = 0 if($ui->{'tt'} < 0);
        }

        my $i = $ui->{'tt'};

        while($y < $maxY-2 && $i < scalar(@output)) {
            $str = $output[$i++];
            $str =~ s/\r//g;
            $str =~ s/\033\[[0-9\,\;\s]*[a-zA-Z]//g;
            if($str =~ s/^\+\+\+ //) {
                attrset(A_BOLD);
            } elsif($str =~ /(?:ERROR|ORA-\d+)/i && $mode ne 'Definition of Step') {
                attrset(A_COLOR(COLOR_BOLD_WHITE,COLOR_RED));
            }
            $str =~ s/\t/    /g;
            $str = substr($str,$ui->{'tx'},($maxX-6));
            addstr($y++,3,$str);
            attrset(A_NORMAL);
        }
    }

    drawScrollBar(
        $ui->{'topOutput'}, # top of scrollbar
        $maxX-3, # where to draw the scrollbar
        $ui->{'outputLines'}, # size of display window
        $ui->{'tt'}, # top of display window
        $ui->{'outputLen'}, # size of output buffer
    );

    $y++;
    $str = $step->status() || $self->defaultStatus($step);
    if($str eq 'Blocked' || $str eq 'Not Started') {
        addstr($y++, 3, "Status of Dependencies:");
        addstr($y++, 3, "----------------------------------");
        foreach my $depends ($step->depends()) {
            my $d = $self->stepForName($depends);
            if($d) {
                my $dstat = $d->status() || $self->defaultStatus($d);
                next if($dstat eq 'Completed' || $dstat eq 'Optional' || $dstat eq 'Error OK');
                my $msg;
                if($dstat eq 'Blocked' || $dstat eq 'Failed') {
                    attrset( A_COLOR(COLOR_BOLD_RED,COLOR_DEFAULT) );
                    $msg = sprintf("Blocked by Step %-5s %-31s", substr($depends,0,5), substr($d->title(),0,31));
                } else {
                    $msg = sprintf("Step %-5s %-44s", substr($depends,0,5), substr($d->title(),0,44));
                }
                addstr($y, 3, $msg);
                attrset( colorForStatus($dstat) );
                addstr($y++, 7+length($msg), "[$dstat]");
                attrset(A_NORMAL);
            }
            if($y > $maxY-4) {
                addstr($y, 6, "...");
                last;
            }
        }
    }

    refresh();
}

sub displaySteps {
    my $self = shift;
    my $selected = shift;
    my $ui = shift;
    my $mode = shift;
    my $maxSelect = shift;
    my $step = $self->stepForUiNumber($selected);

    $ui->{'top'} = 0 unless(defined($ui->{'top'}));
    my $top = $ui->{'top'};
    my $maxy = getmaxy();
    my $maxx = getmaxx();
    my $bot = $top+($maxy-7);

    attrset(A_NORMAL);
    erase();
    box();
    my $displayTime;
    if( $self->endTime() ) {
        my $elt = $self->previousElapsedTime();
        $displayTime = formatElapsedTime( $elt );
    } else {
        my $st = $self->startTime();
        my $et = time();
        my $elt = $self->previousElapsedTime();
        $displayTime = formatElapsedTime( $et-$st+$elt );
    }
    my $title = $self->title() || $self->instance();
    $title = substr($title,0,40);
    my $dryrun = "";
    $dryrun = "[DRYRUN] " if(inDebugMode());
    my $header = sprintf("%sStatus of %s%s", $dryrun, $title);
    addstr(1,3,$header);

    my $mclStatus = $self->topLevelStatus();
    attrset( colorForStatus($mclStatus) );
    addstr(1,45,"[$mclStatus]");
    attrset(A_NORMAL);

    addstr(1,60,$displayTime);

    my $y = 3;
    my $x = 5;

    foreach my $s ($self->steps()) {
        next unless($s->num() >= $top);
        last if($s->num() > $bot);

        attrset(A_NORMAL);
        if($s->num() == $selected) {
            attrset(A_REVERSE);
        }
        my $name = $s->name();
        my $stepHead;
        if($s->isExpandoParent()) {
            if($s->folderStatus() eq 'open') {
                $name = "[-]";
            } else {
                $name = "[+]";
            }
            $stepHead = sprintf("%-8s : %-36s ", substr($name,0,8), substr($s->title(),0,35));
        } elsif($s->expando()) {
            $name = "|-> $name";
            $stepHead = sprintf(" %-9s : %-34s ", substr($name,0,9), substr($s->title(),0,33));
        } else {
            $stepHead = sprintf(" %-7s : %-36s ", substr($name,0,7), substr($s->title(),0,35));
        }
        addstr($y,2,$stepHead);
        unless($s->isExpandoParent() && $s->folderStatus() eq 'open') {
            my $status = $s->status() || $self->defaultStatus($s);
            if($s->storeSuccess() && $status eq 'Error OK') {
                $status = "Checked";
            }
            attrset( colorForStatus($status) );
            if($s->metaInfo() && $status eq 'Running') {
                $status = $s->metaInfo();
            }
            addstr($y,52,"[$status]");
            attrset(A_NORMAL);
        }
        my $elapsed;
        if($s->endTime()) {
            $elapsed = $s->endTime() - $s->startTime();
        } elsif($s->startTime()) {
            $elapsed = time() - $s->startTime();
        }
        if(defined($elapsed)) {
            my $display = formatElapsedTime($elapsed);
            addstr($y,67,$display);
        }
        $y++;
    }

    attrset(A_NORMAL);
    drawScrollBar( 3, $maxx-3, $bot-$top+1, $top, $maxSelect);

    if($mode == DISPLAY_CONFIRM_MENU) {
        $y = $maxy - (scalar(@confirmMenu)) - 6;
        addstr($y++, $maxx-37, "+" . "-" x 35);
        addstr($y++, $maxx-37, "|" . " " x 35);
        my $action = $ui->{'confirmAction'};
        $action = sprintf("| %-34s", "Confirm $action");
        addstr($y++, $maxx-37, $action);
        addstr($y++, $maxx-37, "| " . "-" x 33 . " ");
        for(my $i=0; $i<scalar(@confirmMenu); $i++) {
            addstr($y, $maxx-37, "|");
            my $pr = $confirmMenu[$i];
            $pr =~ s/^[A-Z]//;
            $pr = sprintf("%-35s", $pr);
            attrset(A_REVERSE) if($ui->{'menuSelected'} == $i);
            addstr($y++, $maxx-36, $pr);
            attrset(A_NORMAL);
        }
        addstr($y, $maxx-37, "|" . " " x 35);
    } elsif($mode == DISPLAY_STEP_LIST_MENU) {
        $y = $maxy - (scalar(@displayStepsMenu)) - 4;
        addstr($y++, $maxx-37, "+" . "-" x 35);
        addstr($y++, $maxx-37, "|" . " " x 35);
        for(my $i=0; $i<scalar(@displayStepsMenu); $i++) {
            addstr($y, $maxx-37, "|");
            my $pr = $displayStepsMenu[$i];
            $pr =~ s/^[A-Z]//;
            if($pr =~ /Mark Step/) {
                if($step->isExpandoParent()) {
                    $pr = " --------";
                }
            }
            if($pr =~ /Re(?:queue|start)/) {
                if($step->isExpandoParent()) {
                    $pr = " --------";
                }
                if($step->status() eq 'Optional') {
                    $pr =~ s/Res/S/;
                }
                unless($step->isCompleted() || $step->isFailed()) {
                    $pr = " --------";
                }
            }
            if($pr =~ /Pause/) {
                $pr =~ s/Pause/Resume/ if($self->isPaused());
            }
            $pr = sprintf("%-35s", $pr);
            attrset(A_REVERSE) if($ui->{'menuSelected'} == $i);
            addstr($y++, $maxx-36, $pr);
            attrset(A_NORMAL);
        }
        addstr($y, $maxx-37, "|" . " " x 35);
    } else {
        if($ui->{'Error'}) {
            attrset(A_COLOR(COLOR_BOLD_WHITE,COLOR_RED));
            addstr($maxy-2,3,$ui->{'Error'});
            attrset(A_NORMAL);
        } else {
            addstr($maxy-2,3,"Use F1 or 'M' to access menu options");
        }
    }
    
    move(0,0);
    refresh();
}

sub formatElapsedTime {
    my $elapsed = shift;

    my $display;
    #if($elapsed < 60) {
    #   $display = "$elapsed secs";
    #} else {
    if($elapsed < 3600) {
        my $mins = floor($elapsed/60);
        $elapsed = ($elapsed%60);
        $display = sprintf("%d:%02d", $mins, $elapsed);
    } else {
        my $hours = floor($elapsed/3600);
        my $min = floor(($elapsed%3600)/60);
        $elapsed = $elapsed%60;
        $display = sprintf("%d:%02d:%02d", $hours, $min, $elapsed);
    }

    return($display);
}

sub colorForStatus {
    my $s = shift;
    return(A_COLOR(COLOR_BOLD_WHITE,COLOR_GREEN)) if($s eq 'Completed');
    return(A_COLOR(COLOR_BOLD_WHITE,COLOR_GREEN)) if($s eq 'Checked');
    return(A_COLOR(COLOR_BOLD_GREEN,COLOR_DEFAULT)) if($s eq 'Paused');
    return(A_COLOR(COLOR_BLACK,COLOR_GREEN)) if($s eq 'Error OK');
    return(A_COLOR(COLOR_BOLD_GREEN,COLOR_DEFAULT)) if($s eq 'Skipped');
    return(A_COLOR(COLOR_BOLD_WHITE,COLOR_RED)) if($s eq 'Failed');
    return(A_COLOR(COLOR_BOLD_YELLOW,COLOR_RED)) if($s eq 'Crashed');
    return(A_COLOR(COLOR_BOLD_CYAN,COLOR_MAGENTA)) if($s eq 'Confused');
    return(A_COLOR(COLOR_BOLD_WHITE,COLOR_BLUE)) if($s eq 'Running');
    return(A_COLOR(COLOR_BOLD_RED,COLOR_WHITE)) if($s eq 'Blocked');
    return(A_COLOR(COLOR_BOLD_YELLOW,COLOR_MAGENTA)) if($s eq 'Waiting');
    return(A_COLOR(COLOR_BOLD_WHITE,COLOR_CYAN)) if($s eq 'Optional');
    return(A_NORMAL);
}

sub aggregateLogs {
    my $self = shift;
    my $file = $self->aggregateLogsTo();

    my $logdir = $self->logdir();

    my @links;
    my @data;
    my @inputFiles;

    my $mcltitle = $self->title() || $self->instance();
    push(@links, "<h3>Logs for $mcltitle</h3>\n<hr>\n");

    my $D;
    opendir($D, $logdir);
    while(my $f = readdir($D)) {
        next if($f =~ /^\.+$/);
        next if($f =~ /^main/);
        push(@inputFiles, $f);
    }
    closedir($D);

    @inputFiles = ( "main.log", sort(@inputFiles) );

    foreach my $logfile (@inputFiles) {
        my $infile = $logdir . "/" . $logfile;
        next unless(-e $infile); # in case we don't have main.log

        if($logfile =~ /^Step-(.*)\.log\.(\d+)$/) {
            my $stepname = $1;
            my $attempt = $2;
            $attempt++;
            my $step = $self->stepForName($stepname);
            my $title = $step->title();
            if($attempt > 1) {
                $title .= " (retry #$attempt)";
            }
            push(@links, "<A HREF='#$logfile'>$logfile</a> Step $stepname - $title<br>\n");
            push(@data, "<A name='$logfile'>\n");
            push(@data, "<h3>$logfile - Step $stepname ($title)</h3>\n");
        } else {
            push(@links, "<A HREF='#$logfile'>$logfile</a> MAIN LOG<br>\n");
            push(@data, "<A name='$logfile'>\n");
            push(@data, "<h3>$logfile - MAIN LOG</h3>\n");
        }

        my $LF;
        open($LF, "< $infile");
        my @in = <$LF>;
        close($LF);
        push(@data, "<pre>\n", @in, "</pre>\n");
    }

    my $F;
    open($F, "> $file");
    print $F join("", "<html>\n", @links, "<P><hr><P>\n", @data, "</body></html>\n");
    close($F);
}

1;
