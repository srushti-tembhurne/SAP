#!/usr/local/bin/perl

package ariba::Ops::MCL::Step;

use Data::Dumper;
use strict;
use base qw(ariba::Ops::PersistantObject);
use File::Basename;
use ariba::Ops::MCLGen ('!depends', '!setDepends');

sub definition {
        my $self = shift;

        my $name = $self->name();
        my $title = $self->title();
        my $depends = join(" ", $self->depends());
        my $expando = $self->expando();
        my $group = $self->runGroup();
        my $retries = $self->retries();
        my $retryInt = $self->retryInterval();
        my $options;
        my @opts;
        push(@opts, "Optional") if($self->status() eq 'Optional');
        push(@opts, "Rerun") if($self->rerunOnRestart());
        push(@opts, "ContinueOnError") if($self->continueOnError());
        push(@opts, "NoInherit") if($self->noinherit());
        $options = join(',',@opts) if(scalar(@opts));
        my $other;
        my @oth;
        foreach my $sv ($self->storedVariables()) {
                push(@oth, "Store: " . $sv);
        }
        push(@oth, "StoreSuccess: " . $self->storeSuccess()) if($self->storeSuccess());
        push(@oth, "ExecuteIf: " . $self->executeIf()) if($self->executeIf());
        push(@oth, "ExecuteUnless: " . $self->executeUnless()) if($self->executeUnless());
        push(@oth, "AlertTimeout: " . $self->alertTime()) if($self->alertTime());
        $other = join("\n", @oth) . "\n" if(scalar(@oth));

        my $ret = defineStep($name, $title, $depends, $expando, $group, $options, $retries, $retryInt, $other);

        foreach my $action ($self->actions()) {
                $ret .= $action->definition();
        }

        return($ret);
}

sub sendInfoToUI {
        my $self = shift;
        my $info = shift;

        my $mcl = ariba::Ops::MCL->currentMclObject();
        my $dir = $mcl->messagedir();
        my $file = "$dir/message-" . $self->name() . "-" . time();

        my $FH;
        open($FH, "> $file");
        print $FH $self->name() . ":" . "$info\n";
        close($FH);
}

sub validAccessorMethods {
        my $class = shift;

        my $ref = $class->SUPER::validAccessorMethods();
        my @accessors = qw( actions alerted alertTime continueOnError depends endTime executeIf executeUnless expando folderStatus isExpandoParent logfile mcl name noinherit num output parentStep retries retryInterval runGroup startTime status storeSuccess storedVariables title logdata logtime remoteLogdata remoteLogtime rerunOnRestart metaInfo );

        foreach my $accessor (@accessors) {
                $ref->{$accessor} = 1;
        }

        return($ref);
}

sub status {
        my $self = shift;

        if($self->isExpandoParent()) {
                return($self->attribute('status')) if($self->attribute('status'));
                $self->setStatus($self->expandoStatus()); # cache "Not Started" too
                return($self->attribute('status'));
        } else {
                return($self->attribute('status'));
        }
}

sub expandoStatus {
        my $self = shift;
        my $mcl = ariba::Ops::MCL->currentMclObject();
        my %status;
        my $completed = 1;
        my $started = 0;

        return("No MCL") unless($mcl);

        my @steps = $mcl->stepsForExpando($self->name());

        foreach my $child ($mcl->steps()) {
                next unless($child->expando() eq $self->name());
                my $childStatus = $child->status() || "";
                $status{ $childStatus } = 1;
                $completed = 0 if($completed && $childStatus ne 'Completed' && $childStatus ne 'Error OK' && $childStatus ne 'Skipped');
                $started = 1 if(!$started && $childStatus && $childStatus ne 'Not Started' && $childStatus ne 'Optional');
        }

        return('Completed') if($completed);

        return('Failed') if($status{'Failed'});
        return('Crashed') if($status{'Crashed'});
        return('Confused') if($status{'Confused'});
        return('Waiting') if($status{'Waiting'});
        return('Running') if($status{'Running'} || $started);
        return('Optional') if($status{'Optional'});
        return('Not Started');
}

sub isOptional {
        my $self = shift;
        return 1 if($self->status() eq 'Optional');
        return 0;
}

sub isCompleted {
        my $self = shift;
        return 1 if($self->status() eq 'Completed');
        return 1 if($self->status() eq 'Error OK');
        return 1 if($self->status() eq 'Skipped');
        return 1 if($self->status() eq 'Optional');
        return 0;
}

sub isFailed {
        my $self = shift;
        return 1 if($self->status() eq 'Failed');
        return 1 if($self->status() eq 'Crashed');
        return 1 if($self->status() eq 'Confused');
        return 0;
}

sub isWaiting {
        my $self = shift;
        return 1 if($self->status() eq 'Waiting');
        return 0;
}

sub isRunning {
        my $self = shift;
        return 1 if($self->status() eq 'Running');
        return 0;
}

sub isFailedRollback {
        my $self = shift;
        return 1 if($self->status eq 'Failed Rollback');
        return 1 if($self->status eq 'Rollback Attempted');
        return 0;
}

sub setStatus {
        my $self = shift;
        my $mcl = ariba::Ops::MCL->currentMclObject();

        $self->SUPER::setStatus(@_);

        #
        # this can get called during initial loadMCL before currentMclObject
        # is set.  this is an optimization for run time tho, so we just skip
        # during initialization.
        #
        if($mcl) {
                if($self->expando()) {
                        my $ex = $mcl->stepForName($self->expando());
                        if($ex) {
                                $ex->setAttribute('status', $ex->expandoStatus());
                        }
                }
        }

        $self->save();
}

sub logfile {
        my $self = shift;

        my $file = $self->SUPER::logfile() || $self->nextLogfile();
        return($file);
}

sub nextLogfile {
        my $self = shift;
        my $mcl = ariba::Ops::MCL->currentMclObject();
        my $dir = $mcl->logdir();
        my $basefile = "$dir/Step-" . $self->name() . ".log";
        my $file;
        my $c = 0;

        while(1) {
                $file = $basefile . ".$c";
                last unless( -e $file );
                $c++;
        }

        $self->setLogfile($file);
        return($file);
}

sub logFiles {
        my $self = shift;
        my $mcl = ariba::Ops::MCL->currentMclObject();
        my $dir = $mcl->logdir();
        my $basefile = "$dir/Step-" . $self->name() . ".log";
        my $file;
        my $c = 0;
        my @ret;

        while(1) {
                $file = $basefile . ".$c";
                last unless( -e $file );
                push(@ret, $file);
                $c++;
        }

        return(@ret);
}

sub dir {
        return('/var/mcl');
}

sub actionForNumber {
        my $self = shift;
        my $number = shift;

        foreach my $a ($self->actions()) {
                return($a) if($a->actionNumber() eq $number);
        }

        return undef;
}

sub _computeBackingStoreForInstanceName {
        my $class = shift;
        my $instance = shift;

        my ($mclname, $stepname, $rollback) = split(/\-\-/, $instance);
        $stepname .= "--rollback" if($rollback);
        my $store = "/var/mcl/$mclname/steps/$stepname";
        return($store);
}

sub objectLoadMap {
        my $class = shift;

        my $map = $class->SUPER::objectLoadMap();

        $map->{'actions'} = '@ariba::Ops::MCL::BaseAction';
        $map->{'storedVariables'} = '@SCALAR';
        $map->{'depends'} = '@SCALAR';

        return($map);
}

sub output {
        my $self = shift;

        return($self->attribute('output')) if($self->attribute('output'));
        my $output="";
        foreach my $action ($self->actions()) {
                if($action->header()) {
                        $output .= $action->header() . "\n\n";
                }
                $output .= $action->output();
                chomp($output);
                $output .= "\n";
        }
        $self->setOutput($output);
        return($output);
}

sub remoteLogdata {
        my $self = shift;
        my $data = "";
        my $mcl = ariba::Ops::MCL->currentMclObject();

        unless($self->isRunning()) {
                $self->setRemoteLogdata(undef);
                $self->setRemoteLogtime(undef);
                return(undef);
        }

        if($self->attribute('remoteLogdata')) {
                if($self->remoteLogtime() + 1 > time()) {
                        return($self->attribute('remoteLogdata'));
                }
        }

        foreach my $action ($self->actions()) {
                if(my $remoteType = $action->isRemote()) {
                        my $step = $action->step();
                        my $actionNumber = $action->actionNumber();
                        my $file = $mcl->logdir() . "/main.remote-${step}-${actionNumber}.log";
                        my $IN;
                        open($IN, "< $file");
                        my @input = <$IN>;
                        close($IN);

                        $data .= "\n" if($data);
                        $data .= join("", "==== main.remote-${step}-${actionNumber}.log ====\n", @input);
                }
        }

        unless($data) {
                return(undef);
        }

        $self->setRemoteLogdata($data);
        $self->setRemoteLogtime(time());
        return($data);
}

sub isRemote {
        my $self = shift;
        my $ret = 0;

        foreach my $action ($self->actions()) {
                my $try = $action->isRemote();
                $ret = $try if($try > $ret);
        }

        return($ret);
}

sub fetchRemoteLogs {
        my $self = shift;
        my $mcl = ariba::Ops::MCL->currentMclObject();

        foreach my $action($self->actions()) {
                my $host = $action->host();
                my $user = $action->user();
        $self->setPasswordEnv( $mcl, $user );
                my $password = ariba::rc::Passwords::lookup( $user );
                my $mclctl = $FindBin::Bin . "/" . basename($0);
                unless( $mclctl =~ /mcl-control/ && -e $mclctl ) {
                        $mclctl = "/usr/local/ariba/bin/mcl-control";
                }
                my $step = $action->step();
                my $actionNumber = $action->actionNumber();

                my $command = "ssh -l $user $host $mclctl logdata -mcl " . $action->mcl() . " -step $step -action $actionNumber -dir /tmp -started " . $self->startTime();

                my @input;
                my $ret = ariba::rc::Utils::executeRemoteCommand(
                        $command,
                        $password,
                        0,
                        undef,
                        undef,
                        \@input
                );

                my $data = join("\n", @input, "");
                next unless($data);
                my $file = $mcl->logdir() . "/main.remote-${step}-${actionNumber}.log";

                my $IN;
                open($IN, "> $file");
                print $IN $data;
                close($IN);
        }
}

sub logdata {
        my $self = shift;

        if($self->attribute('logdata')) {
                if(!$self->isRunning() && $self->logtime() > $self->endTime()) {
                        return($self->attribute('logdata'));
                }
                if($self->logtime() + 1 > time()) {
                        return($self->attribute('logdata'));
                }
        }

        # not cached, reload it
        my $data;

        my @logs = $self->logFiles();

        while(my $log = shift(@logs)) {
                my $IN;
                open($IN, "< $log");
                my @input = <$IN>;
                close($IN);
                # my $logfile = basename($log);
                my $logfile = $log;

                $data .= "\n" if($data);
                $data .= "==== $logfile ====\n";
                $data .= join("", @input);
        }

        $data .= "\n" if($data);
        $data .= $self->remoteLogdata() || "";

        return(undef) unless($data);

        $self->setLogdata($data);
        $self->setLogtime(time());

        return($data);
}

sub newFromParser {
        my $class = shift;
        my $mcl = shift;
        my $stepname = shift;
        my $rollback = shift;

        my $instance = $mcl . "--" . $stepname;
        $instance .= "--rollback" if ($rollback);

        my $self = $class->SUPER::new($instance);
        $self->setIsRollback(1) if($rollback);

        $self->setMcl($mcl);
        $self->setName($stepname);

        return($self);
}

sub sharedOutputFile {
        my $self = shift;

        my $mcl = ariba::Ops::MCL->currentMclObject();
        my $dir = $mcl->logdir();
        $dir =~ s/logfiles/output/;
        ariba::rc::Utils::mkdirRecursively($dir);
        my $file = "$dir/Step-" . $self->name();

        return($file);
}

sub removeSharedOutput {
        my $self = shift;

        unlink($self->sharedOutputFile());
}

sub saveSharedOutput {
        my $self = shift;

        my $f = $self->sharedOutputFile();
        open(F, "> $f");
        print F $self->status(), "\n";
        print F $self->endTime(), "\n";
        print F $self->output();
        close(F);
}

sub readSharedOutput {
        my $self = shift;

        my $f = $self->sharedOutputFile();
        open(F,$f) || return;
        my $status = <F>;
        my $endTime = <F>;
        my @output = <F>;
        close(F);

        chomp($status);
        chomp($endTime);
        $self->setEndTime($endTime);
        my $output = join("",@output);
        $self->setOutput($output);
        $self->setStatus($status);
}

# If multiple master passwords (services) are in play we need to determine the service
# from the user name and reinit the Passwords.pm lib to that service.  This will allow
# for the lookup of the correct master password of that service.  This master password
# will then be passed along as part of the remote command such that the remote command
# unlocks the correct password file.
sub setPasswordEnv {
    my $self = shift;
    my $user = shift;
    my $service = shift;

    $service = ariba::Ops::Utils::serviceForUser( $user ) unless $service;
    my $master = ariba::rc::Passwords::masterPasswordForService( $service ) if $service;
    ariba::rc::Passwords::reinitialize( $service, $master ) if $master;
}

sub execute {
        my $self = shift;

        my $retVal;

        #
        # force it to rebuild this
        #
        $self->setOutput(0);

        #
        # if no actions are defined, we fail in the UI -- this is likely an MCL
        # definition error by the user, and if we are skipping intended actions,
        # that could be bad... but let's fail with a useful error in the "output".
        #
        unless(scalar($self->actions())) {
                $self->setStatus("Failed");
                $self->setOutput("Step " . $self->name() . " not run because there are no actions defined.");
                return(0);
        }

        if($self->executeIf()) {
                my $mcl = ariba::Ops::MCL::currentMclObject();
                my $v = $mcl->variableForName($self->executeIf());
                if($self->executeIf() =~ /^\s*([a-zA-Z0-9]+)\(\s*([^\)]*)\s*\)\s*$/) {
                        my $func = $1;
                        my $arg = $2;
                        my $rep = eval "ariba::Ops::MCL::Checks::$func($arg);";
                        if($@ || !$rep) {
                                my $reason = "returned false";
                                $reason = "failed to compile: $@" if($@);
                                $self->setOutput("Step " . $self->name() . " not run because " . $self->executeIf() . " $reason.");
                                $self->setStatus('Skipped');
                                return(1);
                        }
                } else {
                        if(!$v || !$v->value()) {
                                $self->setOutput("Step " . $self->name() . " not run because " . $self->executeIf() . " is false or not set.");
                                $self->setStatus('Skipped');
                                return(1);
                        }
                }
        }

        if($self->executeUnless()) {
                my $mcl = ariba::Ops::MCL::currentMclObject();
                if($self->executeUnless() =~ /^\s*([a-zA-Z0-9]+)\(\s*([^\)]*)\s*\)\s*$/) {
                        my $func = $1;
                        my $arg = $2;
                        my $rep = eval "ariba::Ops::MCL::Checks::$func($arg);";
                        if(!$@ && $rep) {
                                $self->setOutput("Step " . $self->name() . " not run because " . $self->executeUnless() . " returned true.");
                                $self->setStatus('Skipped');
                                return(1);
                        }
                } else {
                        my $v = $mcl->variableForName($self->executeUnless());
                        if($v && $v->value()) {
                                $self->setOutput("Step " . $self->name() . " not run because " . $self->executeUnless() . " is set to true.");
                                $self->setStatus('Skipped');
                                return(1);
                        }
                }
        }

        my $tries = $self->retries() || 1;
        my $sleep = $self->retryInterval() || 5;
        my $attempts = 0;

        my $loopedOutput = "";
        while($tries) {
                $tries--;
                foreach my $action ($self->actions()) {
                        $action->setStatus('Attempted');
                        # This command assumes the step has a user.  This makes NetworkDevice steps and other
                        # steps that don't have a user ambiguous.  Need to expand these step definitions and
                        # parsing to have a service somehow.  Only then can we do cross service NetworkDevice
                        # steps from a single MCL
                        $self->setPasswordEnv( $action->user(), $action->service() ) if $action->user();
                        my $ret = $action->execute();
                        if($ret) {
                                if($ret == -1) {
                                        $action->setStatus('Waiting');
                                        $retVal = -1;
                                        last;
                                } else {
                                        $action->setStatus('Completed');
                                        $retVal = 1;
                                }
                        } else {
                                $action->setStatus('Failed');
                                $retVal = 0;
                                last;
                        }
                }
                $loopedOutput .= "\n==== retry $attempts ====\n\n" if($loopedOutput);
                $loopedOutput .= $self->output();
                $attempts++;


                #
                # this forces the next call to $self->output() to reconstruct from
                # the sub actions.
                #
                $self->setOutput(0);

                last if($retVal);
                if($tries) {
                        $self->sendInfoToUI("Retry #$attempts");
                        sleep($sleep);
                }
        }

        $self->setOutput($loopedOutput);

        return($retVal);
}

sub dryrun {
        my $self = shift;
        my $retVal = 0;

        foreach my $action ($self->actions()) {
                my $ret = $action->dryrun();
                if($ret) {
                        if($ret == -1) {
                                $action->setStatus('Waiting');
                                $retVal = -1;
                                last;
                        } else {
                                $action->setStatus('Completed');
                                $retVal = 1;
                        }
                } else {
                        $action->setStatus('Failed');
                        $retVal = 0;
                        last;
                }
        }
        $self->setOutput(0); # force next call to $self->output() to rebuild

        sleep(5); # make the dry run take a little time so a human can observe
        return($retVal);
}

sub storeVariablesFromResult {
        my $self = shift;
        my $reload;
        my $mcl = ariba::Ops::MCL->currentMclObject();

        if($self->storeSuccess()) {
                my $v = $mcl->variableForName($self->storeSuccess());

                if($v) {
                        if($self->status() eq 'Completed') {
                                $v->setValue(1);
                        } else {
                                $v->setValue(0);
                        }
                }
        }

        my @storedVars = $self->storedVariables();
        if(scalar(@storedVars)) {
                my $output = $self->output();

                #
                # sanitize
                #
                my @out = split(/\n/, $output);
                $output = "";
                foreach my $o (@out) {
                        next if($o =~ /^\+\+\+/);
                        $output .= " " if($output);
                        $output .= $o;
                }

                foreach my $store ($self->storedVariables()) {
                        my ($var, $regex);
                        if($store =~ /=/) {
                                ($var, $regex) = split(/\=/,$store,2);
                        } else {
                                $var = $store;
                        }
                        next unless($var);

                        my $val;
                        if($regex) {
                                if($output =~ /$regex/m) {
                                        $val = $1;
                                }
                        } else {
                                $val = $output;
                        }

                        if($val) {
                                #
                                # remove the last newline
                                #
                                chomp $val;
                                my $v = $mcl->variableForName($var);
                                unless($v) {
                                        $v = ariba::Ops::MCL::Variable->newFromParser($mcl->instance(), $var);
                                        $mcl->appendToVariables($v);
                                }
                                $v->setValue($val);
                                $v->setType('dynamic');
                                $v->save();
                                $reload = 1;
                        }
                }
        }
        #
        # reparse the MCL to account for the new variable values
        #
        if($reload) {
                $mcl->clearTransferList();
                $mcl->loadMCL();
        }

        return($reload);
}

1;
