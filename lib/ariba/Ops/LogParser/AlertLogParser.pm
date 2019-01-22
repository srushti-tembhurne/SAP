# $Id: //ariba/services/tools/lib/perl/ariba/Ops/LogParser/AlertLogParser.pm#4 $
package ariba::Ops::LogParser::AlertLogParser;

use strict;

use ariba::monitor::misc;
use ariba::Ops::PersistantObject;
use Date::Calc;

use base qw(ariba::Ops::PersistantObject);

# constants
#
my $SCANPERIOD   = 2 * 60 * 60; # 2 hours
#my $SCANPERIOD   = 72 * 60 * 60; # 3 days
my $ARCHIVESCAN  = 60 * 15; # 15 minutes

my $debug = 0;

sub dir {
    return undef;
}

sub setDebug {
    my $class = shift;

    $debug = shift;
}

sub validAccessorMethods {
    my $class = shift;

    my $methodsRef = $class->SUPER::validAccessorMethods();

    $methodsRef->{'errors'}   = undef;
    $methodsRef->{'warnings'} = undef;
    $methodsRef->{'deferred'} = undef;
    $methodsRef->{'productName'} = undef;
    $methodsRef->{'type'} = undef;
    $methodsRef->{'sid'} = undef;
    $methodsRef->{'hostname'} = undef;
    $methodsRef->{'currentTime'} = undef;
    $methodsRef->{'logsState'} = undef;
    $methodsRef->{'displayErrors'} = undef;
    $methodsRef->{'logEntryTime'} = undef;

    return $methodsRef;
}

sub new {
    my $class       = shift;
    my $productName = shift;
    my $sid         = shift;
    my $type        = shift;
    my $hostName   = shift;

    my $self = $class->SUPER::new($sid . $type . $hostName);

    $self->setSid($sid);
    $self->setType($type);
    $self->setProductName($productName);
    $self->setHostname($hostName);

    $self->setCurrentTime(time());

    $self->reset();
    return $self;
}

sub newFromDBConnectionAndHost {
    my $class = shift;
    my $dbc = shift;
    my $hostName = shift;

    return $class->new($dbc->product()->name(), $dbc->sid(), $dbc->type(), $hostName);
}

sub remove {
    my $self = shift;
    
    $self->reset();
    $self->SUPER::remove();
}

sub reset {
    my $self = shift;

    $self->setErrors(\[]);
    $self->setWarnings(\[]);
    $self->setDeferred({});
    $self->setLogsState({});
}

sub errors {
    my $self = shift;
    my $errorsRef = $self->SUPER::errors();
    return $$errorsRef;
}

sub warnings {
    my $self = shift;
    my $warningsRef = $self->SUPER::warnings();
    return $$warningsRef;
}

sub parseHanaAlertLogFile {
    my $self = shift;
    my $alertLogFile = shift;

    my $hostname = $self->hostname();
    my $sid = $self->sid();
    my $type = $self->type();
    my $prodName = $self->productName();

   print "hostName : $hostname\n";

    my $errors = $self->errors();
    my $warnings = $self->warnings();

    unless (-f $alertLogFile) {
        print "Alert log file [$alertLogFile] not found.\n";
        push(@$errors, "Alert log file [$alertLogFile] not found.");
        return;
    }

    my $displayErrors = 0;
    my $logEntryTime;

    open(LOG, $alertLogFile) || return undef;
    print "hostName : $hostname\n";
    print "parsing $alertLogFile for sid $sid type $type product $prodName\n";
    my $lineCount = 0;
    my $parsedLineCount = 0;

    while (my $line = <LOG>) {
        print "linecount $lineCount parsed $parsedLineCount\n";
        ++$parsedLineCount if ($self->_parseHanaAlertLogLine($line, 1));
        ++$lineCount;
        if ($debug) {
            ++$lineCount;
            print "Doing line $lineCount\r" if ($lineCount % 100 == 0);
        }
    }
    if ($debug) {
        print "parsed $parsedLineCount / $lineCount lines\n";
    }

    close(LOG);

    my $deferred = $self->deferred();

    if ($debug) {
        print '*' x 25, "leftover deferred", '*' x 25, "\n\t";
        print map({ "\t$_ => ", $deferred->{$_}, "\n" }, keys %$deferred), "\n";
    }
    # page for any errors that were deferred but never resolved
    for my $oraError (keys %$deferred) {
        push(@$errors, @{$deferred->{$oraError}});
    }

    # now run through all of our states per-log and see what's left.
    my $logsState = $self->logsState();
    for my $log (keys %$logsState) {

        my $state = $logsState->{$log}->{'state'};
        my $date  = $logsState->{$log}->{'date'};

        next unless $state eq 'failed';

        push @$errors, "$date [$sid:failed to archive log \#$log] $hostname";
    }

    if ($debug) {

        print '*' x 25, "errors", '*' x 25, "\n\t";
        print join("\n\t", @$errors), "\n";

        print '*' x 25, "warnings", '*' x 25, "\n\t";
        print join("\n\t", @$warnings), "\n";
    }

    return 1;
}

sub parseAlertLogFile {
    my $self = shift;
    my $alertLogFile = shift;

    my $hostname = $self->hostname();
    my $sid = $self->sid();
    my $type = $self->type();
    my $prodName = $self->productName();

    $alertLogFile = ariba::monitor::misc::alertLogFileForSid($sid) unless defined($alertLogFile);

    my $errors = $self->errors();
    my $warnings = $self->warnings();

    unless (-f $alertLogFile) {
        push(@$errors, "Alert log file [$alertLogFile] not found.");
        return;
    }

    my $displayErrors = 0;
    my $logEntryTime;

    open(LOG, $alertLogFile) || return undef;
    print "parsing $alertLogFile for sid $sid type $type product $prodName\n" if $debug;
    my $lineCount = 0;
    my $parsedLineCount = 0;

    while (my $line = <LOG>) {

        ++$parsedLineCount if ($self->_parseAlertLogLine($line, 1));

        if ($debug) {
            ++$lineCount;
            print "Doing line $lineCount\r" if ($lineCount % 100 == 0);
        }
    }
    if ($debug) {
        print "parsed $parsedLineCount / $lineCount lines\n";
    }

    close(LOG);

    my $deferred = $self->deferred();

    if ($debug) {
        print '*' x 25, "leftover deferred", '*' x 25, "\n\t";
        print map({ "\t$_ => ", $deferred->{$_}, "\n" }, keys %$deferred), "\n";
    }
    # page for any errors that were deferred but never resolved
    for my $oraError (keys %$deferred) {
        push(@$errors, @{$deferred->{$oraError}});
    }

    # now run through all of our states per-log and see what's left.
    my $logsState = $self->logsState();
    for my $log (keys %$logsState) {

        my $state = $logsState->{$log}->{'state'};
        my $date  = $logsState->{$log}->{'date'};

        next unless $state eq 'failed';

        push @$errors, "$date [$sid:failed to archive log \#$log] $hostname";
    }

    if ($debug) {

        print '*' x 25, "errors", '*' x 25, "\n\t";
        print join("\n\t", @$errors), "\n";

        print '*' x 25, "warnings", '*' x 25, "\n\t";
        print join("\n\t", @$warnings), "\n";
    }

    return 1;
}

sub parseAlertLogArray {
    my $self = shift;
    my $linesRef = shift;

    for my $line (@$linesRef) {
        $self->_parseAlertLogLine($line);
    }
}

sub _parseHanaAlertLogLine{
    my $self = shift;
    my $line = shift;
    my $haveContext = shift;

    my $currentTime  = $self->currentTime();

    my $logEntryTime;
    #
    # this is a date line, save it aside for use later
    #

    # split line for date and errors

   my ($str1, $str2, $str3, $str4, $str5) = split(' ', $line);

    if (defined $str4 && $str4 eq "e"){
      my  ($year, $mon, $day) = split(/-/, $str2);
      my  ($hour,  $min, $sec) = split(/:/, $str3);
      $logEntryTime = Date::Calc::Mktime($year, $mon, $day, $hour,  $min, $sec);
    }
    # check we got a valid date/time, otherwise return.
    if (not defined $logEntryTime){
        return 0;
    }
        $self->setLogEntryTime($logEntryTime);
        if ($currentTime - $logEntryTime <= $SCANPERIOD) {
            $self->setDisplayErrors(1);
        }

    my $logDate = "";
    if ($haveContext) {
        $logEntryTime = $self->logEntryTime();
        $logDate = scalar(localtime($logEntryTime)) if $logEntryTime;
    }

    return 0 unless $self->displayErrors();

    my $archivers = {};
    my $logsState = $self->logsState();

    my $errors = $self->errors();
    my $warnings = $self->warnings();
    my $deferred = $self->deferred();
    my $prodName = $self->productName();
    my $sid = $self->sid();
    my $type = $self->type();
    my $hostname = $self->hostname();

    if($str4 eq "e"){
       push( @$errors, "", $line );
       return 1;
    }

}

sub _parseAlertLogLine {
    my $self = shift;
    my $line = shift;
    my $haveContext = shift;

    my $currentTime  = $self->currentTime();

    my $logEntryTime;
    #
    # this is a date line, save it aside for use later
    #
    if ($line =~ m/^(Mon |Tue |Wed |Thu |Fri |Sat |Sun)/o) {
        $logEntryTime = $self->_alertLogDateToUTC($line);
        $self->setLogEntryTime($logEntryTime);
        if ($currentTime - $logEntryTime <= $SCANPERIOD) {
            $self->setDisplayErrors(1);
        }
    }

    my $logDate = "";
    if ($haveContext) {
        $logEntryTime = $self->logEntryTime();
        $logDate = scalar(localtime($logEntryTime)) if $logEntryTime;
    }

    return 0 unless $self->displayErrors();

    my $archivers = {};
    my $logsState = $self->logsState();

    my $errors = $self->errors();
    my $warnings = $self->warnings();
    my $deferred = $self->deferred();
    my $prodName = $self->productName();
    my $sid = $self->sid();
    my $type = $self->type();
    my $hostname = $self->hostname();

    if ($line =~ /(ORA-\d+)/o) {
        my $oraErr = $1;

        # these errors may or may not be pageable, so deffer this decision
        # until we know more about the error
        if ($oraErr eq "ORA-00272" ||
                $oraErr eq "ORA-12541" ||
                $oraErr eq "ORA-12514" ) {

            # if this is a second deferrable error, page for the first
            if (exists $deferred->{$oraErr}) {
                push(@$errors, @{$deferred->{$oraErr}});
            }
            # defer the decision to page or warn
            $deferred->{$oraErr} = ["$logDate [$sid:$oraErr] $hostname", $line];
            return 1;
        } elsif (keys %$deferred) {
            # found another ora exception while deciding on a deferred
            # error, so page for the deferred one
            for my $deferredOraErr (keys %$deferred) {
                push(@$errors, @{$deferred->{$deferredOraErr}});
                if ($debug) {
                    print "Deferred: ", join(' ', @{$deferred->{$deferredOraErr}}), "\n";
                }
                delete $deferred->{$deferredOraErr};
            }
        }

        if (
                $oraErr eq "ORA-00314" ||
                $oraErr eq "ORA-00312" ||
                $oraErr eq "ORA-00321" ||
                $oraErr eq "ORA-00313" ||
                $oraErr eq "ORA-01575"
           ) {
            return 1;
        }
        
        #
        # TMID: 132470 - alert log entries to notify DBAs
        #
        
        if (
            $oraErr eq "ORA-00206"	||
            $oraErr eq "ORA-00227"	||
            $oraErr eq "ORA-00235"	||
            $oraErr eq "ORA-00245"	||
            $oraErr eq "ORA-00305"	||
            $oraErr eq "ORA-00313"	||
            $oraErr eq "ORA-00322"	||
            $oraErr eq "ORA-00333"	||
            $oraErr eq "ORA-00367"	||
            $oraErr eq "ORA-00600"	||
            $oraErr eq "ORA-00942"	||
            $oraErr eq "ORA-01157"	||
            $oraErr eq "ORA-01186"	||
            $oraErr eq "ORA-01578"	||
            $oraErr eq "ORA-07445"	||
            $oraErr eq "ORA-1092"	||
            $oraErr eq "ORA-17500"	||
            $oraErr eq "ORA-17503"	||
            $oraErr eq "ORA-17510"	||
            $oraErr eq "ORA-19804"	||
            $oraErr eq "ORA-19809"	||
            $oraErr eq "ORA-3136"
        ) {
            push( @$errors, "$logDate [$sid:$oraErr] $hostname", $line );
            return 1;
        }

        #
        # TMID: 132470 - alert log enteries to ignore per Lily's refined list.
        #

        if (
            $oraErr eq "ORA-00001"  ||
            $oraErr eq "ORA-00060"  ||
            $oraErr eq "ORA-00261"  ||
            $oraErr eq "ORA-00334"  ||
            $oraErr eq "ORA-00338"  ||
            $oraErr eq "ORA-00353"  ||
            $oraErr eq "ORA-00354"  ||
            $oraErr eq "ORA-00445"  ||
            $oraErr eq "ORA-00448"  ||
            $oraErr eq "ORA-00942"  ||
            $oraErr eq "ORA-01013"  ||
            $oraErr eq "ORA-01031"  ||
            $oraErr eq "ORA-01089"  ||
            $oraErr eq "ORA-01090"  ||
            $oraErr eq "ORA-01280"  ||
            $oraErr eq "ORA-01375"  ||
            $oraErr eq "ORA-01555"  ||
            $oraErr eq "ORA-01580"  ||
            $oraErr eq "ORA-02063"  ||
            $oraErr eq "ORA-03113"  ||
            $oraErr eq "ORA-03135"  ||
            $oraErr eq "ORA-03137"  ||
            $oraErr eq "ORA-04020"  ||
            $oraErr eq "ORA-06512"  ||
            $oraErr eq "ORA-1013"   ||
            $oraErr eq "ORA-10173"  ||
            $oraErr eq "ORA-10388"  ||
            $oraErr eq "ORA-1103"   ||
            $oraErr eq "ORA-1109"   ||
            $oraErr eq "ORA-1119"   ||
            $oraErr eq "ORA-1184"   ||
            $oraErr eq "ORA-12012"  ||
            $oraErr eq "ORA-12514"  ||
            $oraErr eq "ORA-12541"  ||
            $oraErr eq "ORA-12801"  ||
            $oraErr eq "ORA-1289"   ||
            $oraErr eq "ORA-13607"  ||
            $oraErr eq "ORA-13639"  ||
            $oraErr eq "ORA-1507"   ||
            $oraErr eq "ORA-1580"   ||
            $oraErr eq "ORA-16009"  ||
            $oraErr eq "ORA-16037"  ||
            $oraErr eq "ORA-16055"  ||
            $oraErr eq "ORA-16103"  ||
            $oraErr eq "ORA-16111"  ||
            $oraErr eq "ORA-16128"  ||
            $oraErr eq "ORA-16146"  ||
            $oraErr eq "ORA-16204"  ||
            $oraErr eq "ORA-16205"  ||
            $oraErr eq "ORA-16222"  ||
            $oraErr eq "ORA-16226"  ||
            $oraErr eq "ORA-16227"  ||
            $oraErr eq "ORA-16246"  ||
            $oraErr eq "ORA-16254"  ||
            $oraErr eq "ORA-16401"  ||
            $oraErr eq "ORA-1665"   ||
            $oraErr eq "ORA-16957"  ||
            $oraErr eq "ORA-19815"  ||
            $oraErr eq "ORA-20000"  ||
            $oraErr eq "ORA-26786"  ||
            $oraErr eq "ORA-26787"  ||
            $oraErr eq "ORA-26808"  ||
            $oraErr eq "ORA-27038"  ||
            $oraErr eq "ORA-29903"  ||
            $oraErr eq "ORA-308"    ||
            $oraErr eq "ORA-48913"
           ) {
            return 1;
        }

        # Warn-only:
        #
        # 3136: "caused by heavy network tarffic between n2 and n3"
        # 
        # ORA-19815: WARNING: db_recovery_file_dest_size of 6442450944 bytes is 85.39% used, and has 941424640 remaining bytes available."
        #

        if ( 
                $oraErr eq "ORA-3136"  ||
                $oraErr eq "ORA-19815"
           ) {
            push(@$warnings, "$logDate [$sid:$oraErr] $hostname", $line);
            return 1;
        }

        # 00600: internal system error
        #        ignore this only if "[soreod_1]" shows up as one of the
        #        arguments, indicating that this is the result of a
        #        deadlock.  See defect 1-1E385F.
        #        Also ingore this error for "sorput_1".
        # 
        if ( $oraErr eq "ORA-00600" &&
                $line =~ m/internal error code, arguments: \[(soreod_1|sorput_1)\]/){
            return 1;
        }

        if ($oraErr eq "ORA-20000" && 
                $line =~ m/index .+ or partition of such index is in unusable state/) {
            return 1;
        }

        if ($sid =~ m/ANL/ && $oraErr eq "ORA-00604") {
            return 1;
        }

        # ORA-16055: FAL request rejected
        # "The temporarily network interruption of the FAL service.  Dataguard will
        # catch up the remote archive log."

        if (($oraErr eq "ORA-16055") &&
                $type eq ariba::Ops::DBConnection->typeMain()) {
            return 1;
        }

        # LOGSTDBY status: ORA-16128: User initiated stop apply successfully completed
        # "This is the DBA's operation on dataguard."
        # 
        # ORA-01341: LogMiner out-of-memory
        # LOGSTDBY status: ORA-01341: LogMiner out-of-memory
        # "This is the known memory leak on dataguard process, dataguard will
        # automatically restart the process."
        # 
        # ORA-12805: parallel query server died unexpectedly
        # "This the PQ child process that died, and dataguard master process will
        # restart them."
        # 
        # LOGSTDBY status: ORA-01403: no data found
        # "This is the dataguard log apply temporarily out of sequence among PQ
        # process, the dataguard will restart them all and retry the operation."
        #
        # 00322: Oracle bug #4038854, does not harm dataguard replication
        #
        # LOGSTDBY status: ORA-00001: unique constraint (ANLIVE.IND_UN_DF4492F6_26657283) violated
        # According to James, such constraint violations are handled by a
        # retry on the primary db but they show up in dr because there is no
        # app to handle the errors.  Due to the nature of the retry it's not
        # necessary to error on these in dr.
        #

        if (($oraErr eq "ORA-16128" ||
                    $oraErr eq "ORA-01341" ||
                    $oraErr eq "ORA-12805" ||
                    $oraErr eq "ORA-00322" ||
                    $oraErr eq "ORA-00001" ||
                    $oraErr eq "ORA-01403") &&
                $type eq ariba::Ops::DBConnection->typeDr()) {
            return 1;
        }

        # 07445: oracle core dump caused by running large ANL reports.
        #      James has opened a defect with Oracle support.  For ANL
        #      products send warning email, page for the rest.
        #
        #   This is also an issue for s4 due to heavy load caused by too many
        #   connections to the db.  See TMID 44944 and Defect 1-8UJQL7.
        #

        if ($oraErr eq "ORA-07445" && ($prodName eq 'anl' || $prodName eq 's4')) {
            push(@$warnings, "$logDate [$sid:$oraErr] $hostname", $line);
            return 1;
        }

        push(@$errors, "$logDate [$sid:$oraErr] $hostname", $line);
    }

    my $deferredOraErr;

    # ORA-00272, ORA-12541 and ORA-12514
    # From James Chiang: 
    # "This is the intermitten remote archival hiccup. It does not hurt
    # the Dataguard replication and db will retry the archiving until it
    # success."
    #
    if ($line =~ m!LGWR: I/O error 272 archiving log \d+ to '\w+_(A|B)'!) {
        $deferredOraErr = "ORA-00272";
        if (exists $deferred->{$deferredOraErr}) {
            push(@$warnings, @{$deferred->{$deferredOraErr}});
        }
    } elsif ($line =~ m!FAL\[server, ARC\d+\]: Error (\d+) creating remote archivelog file '\w+_(A|B)'!) {
        $deferredOraErr = "ORA-$1";
    }

    if ($deferredOraErr && exists $deferred->{$deferredOraErr}) {
        if ($debug) {
            print "Deferred: ", join(' ', @{$deferred->{$deferredOraErr}}), "\n";
        }
        delete $deferred->{$deferredOraErr};
    }

    #
    # Dataguard related log error:
    # RFS[\d+]: Possible network disconnect with primary database
    #
    if ($line =~ m/(RFS\[\d+\])\s*:.*network\s*disconnect(.*)$/o) {
        my $error = $1;
        # disconnects with the primary db are possibly the symptom of an
        # oracle bug -- only flag as an error if this is not the case
        # primary db disconnecs are non-actionable
        # See TMID: 49450
        unless ($2 =~ m/primary database/) {
            push(@$errors, "$logDate [$sid:$error] $hostname", $line);
        }
    }

    if ($line =~ /PMON failed/) {
        push(@$errors, "$logDate [$sid] $hostname", $line);
    }

    if ($haveContext) {
        # match the starting gate
        if ($line =~ m/^(ARC\d+):\s+Beginning\s+to\s+archive\s+log#\s*(\d+)/i) {
            $archivers->{$1}->{'log'}   = $2;
            $archivers->{$1}->{'time'}  = $logEntryTime;
            $logsState->{$2}->{'state'} = 'started';
        }

        if ($line =~ m/^(ARC\d+):\s+Completed\s+archiving\s+log#\s*(\d+)/i) {

            my $arc = $1;

            # this might have been sucessful because we've matched the
            # start - check the time range.
            if (defined $archivers->{$arc} && defined $archivers->{$arc}->{'log'}) {

                if ($currentTime - $archivers->{$arc}->{'time'} >= $ARCHIVESCAN) {
                    push @$errors, "$logDate [$sid:$arc completed, but took longer than $ARCHIVESCAN seconds] $hostname";
                }

                # completed successfully and within the time range
                if ($currentTime - $archivers->{$arc}->{'time'} <= $ARCHIVESCAN) {
                    $archivers->{$arc}->{'state'} = 'ok';
                    delete $logsState->{ $archivers->{$arc}->{'log'} };
                }
            }
        }

        # Bzzzzt!
        if ($line =~ m/^(ARC\d+):\s+Failed\s+to\s+archive\s+log#\s*(\d+)/i) {
            $logsState->{$2}->{'state'} = 'failed';
            $logsState->{$2}->{'date'}  = $archivers->{$1}->{'time'};
        }
    }

    return 1;
}

sub _alertLogDateToUTC {
    my $class = shift;
    my $dateString = shift();

    #print "Decoding: $dateString\n";
    my ($dayOfWeek, $monthName, $monthDay, $hourMinSec, $dateYear, $junk) = split(/\s+/, $dateString, 6);

    my ($year,$month,$day) = Date::Calc::Decode_Date_US("$monthName $monthDay $dateYear");

    my ($hour, $min, $sec) = split(/:/, $hourMinSec);

    # If the log was truncated, bail so Mktime doesn't blow up.
    if (!$year || !$month || !$day || !$hour || !$min || !$sec) {
        return 0;
    }

    my $utime = Date::Calc::Mktime($year,$month,$day, $hour,$min,$sec);

    #print "utime = $utime\n";

    #print "date from this utime = " . localtime($utime) . "\n";

    return $utime;
}

sub _alertLogDateToUTCForHana {
    my $class = shift;
    my $dateString = shift();

    #print "Decoding: $dateString\n";
    my ($dayOfWeek, $monthName, $monthDay, $hourMinSec, $dateYear, $junk) = split(/\s+/, $dateString, 6);

    my ($year,$month,$day) = Date::Calc::Decode_Date_US("$monthName $monthDay $dateYear");

    my ($hour, $min, $sec) = split(/:/, $hourMinSec);

    # If the log was truncated, bail so Mktime doesn't blow up.
    if (!$year || !$month || !$day || !$hour || !$min || !$sec) {
        return 0;
    }

    my $utime = Date::Calc::Mktime($year,$month,$day, $hour,$min,$sec);

    #print "utime = $utime\n";

    #print "date from this utime = " . localtime($utime) . "\n";

    return $utime;
}


1;
