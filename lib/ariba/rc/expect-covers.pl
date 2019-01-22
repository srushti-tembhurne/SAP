#
# This file should not be required directly by a script
# Go through ariba::rc::Utils to pull this in.
#
# Also routines in this file are not available on NT.


use Expect 1.11;

# NOTE:  debug in this module must be "manually" enabled by setting this to a non-negative value.
#        Currently supported values are:
#           1 - runs through the full module code, particularly the Expect code, with Expect debugging.
#           2 - introduced for testing the hideString method and editing of the 'ssh' command to add options,
#               currently specific to the sshCover() method, it prints command and password information, and
#               immediately returns, skipping all Expect processing.
my $debug = 0;

sub printExpectError {
    my ($logStdout,$errString,$retOutput) = @_;

    if ($logStdout) {
        print STDERR $errString;
    } else {
        push(@{$retOutput}, $errString);
    }
}

sub localCover {
    my ($command, $master, $retOutput, $timeout, $password, $cover) = @_;

    # Debugging anyone?
    if ($debug) {
        $Expect::Log_Stdout=1;
        $Expect::Exp_Internal=1;
        $Expect::Debug=1;
    }

    my $logStdout = $retOutput ? 0 : 1;
    my $func = \&logStdout;
    if($cover eq 'Logger') {
        $logStdout = 1;
        $func = \&LoggerStdOut;
    }

    my $masterPrompt = '[Ee]nter [Mm]aster [Pp]assword:';
    my $badMaster = 'Incorrect Master Password';
    my $END_PROMPT = '_-_-_END_-_-_';
    my $END_PROMPT_REGEX = "$END_PROMPT \([0-9]+\)";
    my $sudoPrompt = '(Enter \w+\'s Password:|^Password:|^assword:|\[sudo\] password for|\w+\'s password:|\w+\'s password: )';
    my $badPassword = 'denied[\.,]';
    my $expectFailed;

    local $ENV{ 'EXPECT' } = 'true';

    my $exp = Expect->spawn("$command;echo $END_PROMPT \$?");
    my $status;  # due to our use of echo in the command, $status is set when we match $END_PROMPT

    my $errString;
    unless ($exp) {
        $errString = "ERROR ariba::rc::Utils::localCover spawn of $command failed: $!\n";
        printExpectError($logStdout,$errString,$retOutput);
        return 1;
    }

    my $pid = $exp->pid();
    $exp->log_stdout(0);
    # $exp->log_stdout($logStdout);
    $exp->log_file($func) if ( $logStdout );

    my $exited = 0;
    my $error = 0;
    my $commandOutput = "";

    my $passwordInputHandler = sub {
        my ($exp, $logStdout, $password) = @_;
        # $exp->log_stdout(0);
        $exp->log_file(undef);

        $exp->stty(qw(-echo));
        print $exp "$password\r";
        $exp->stty(qw(echo));

        my $pat = quotemeta($password);
        $exp->expect(0, "-re", "$pat");
        # $exp->log_stdout($logStdout);
        $exp->log_file($func) if ( $logStdout );
        return $exp->error();
    };

    $exp->expect($timeout,
            '-re', $masterPrompt, sub {
                $commandOutput .= $exp->exp_before();
                if ($master) {
                    $expectFailed = $passwordInputHandler->($exp, $logStdout, $master);
                    unless ($expectFailed) {
                        return exp_continue_timeout();
                    } else {
                        return "ariba_exp_breakout";
                    }
                } else {
                    $errString =  "ERROR ariba::rc::Utils::localCover".
                        "(pid: $pid): no master password supplied\n";
                    kill(9, $pid);
                    printExpectError($logStdout,$errString,$retOutput);
                    $error = 1;
                }
            },
            '-re', $badMaster,  sub {
                $errString =  "ERROR ariba::rc::Utils::localCover ".
                    "(pid: $pid): bad master password\n";
                kill(9, $pid);

                printExpectError($logStdout,$errString,$retOutput);
                $error = 1;
            },
            '-re', $sudoPrompt, sub {
                $commandOutput .= $exp->exp_before();
                $expectFailed = $passwordInputHandler->($exp, $logStdout, $password);
                unless ($expectFailed) {
                    return exp_continue_timeout();
                } else {
                    return "ariba_exp_breakout";
                }
            },
            '-re', $badPassword,  sub {
                $errString = "ERROR ariba::rc::Utils::sshCover ".
                                "(pid: $pid): bad password\n";

                printExpectError($logStdout,$errString,$retOutput);
                $error = 1;
            },
            'eof', sub {
                $exited = 1;
                $status = ($exp->exp_exitstatus() || $?) >> 8;
            },
            '-re', "$END_PROMPT_REGEX", sub {
                $exited = 1;
                $status = ($exp->matchlist())[0];
            },
    );

    #
    # If there was an error during the above checks, return that.
    #
    return $error if $error;

    $commandOutput .= $exp->exp_before();

    if($retOutput) {
        # strip out leading \n that might have resulted from password
        # prompt feed.
        $commandOutput =~ s/^\r\n//;
        push(@{$retOutput}, split('\r\n', $commandOutput));
    }

    return $status; #return exit status 0 for success, non zero otherwise
}

sub noOp { }

# This will be a pattern, used in the method 'logStdout'.
my $hidestr = "";

sub hideString {
    my $tmpHidestr = shift;

    $tmpHidestr = quotemeta($tmpHidestr);

    # If we have a $hidestr, add our temp value to it, as an 'or' pattern.
    if ($hidestr)
    {
        $hidestr .= "|$tmpHidestr";
    }
    else # simply set it to our temp value.
    {
        $hidestr = $tmpHidestr;
    }
}

sub logStdout {
    my $txt = shift;

    $txt =~ s/Password/Passwd/g;
    # print the input text to stdout unless it matches any of the hide strings.  Note that this will
    # also not print any text that may surround the forbidden text.
    print STDOUT $txt unless ($txt =~ /$hidestr/);
}

sub LoggerStdOut {
    my $txt = shift;

    chomp($txt);
    $txt =~ s/\r//g;

    my $logger = ariba::Ops::Logger->logger();
    my $q = $logger->quiet();
    $logger->setQuiet(1);
    $logger->info($txt);
    $logger->setQuiet($q);
}

# Arguments:
#               $command        The 'ssh' command to be run, with all options and args
#               $password       The 'user' password, for login to the remote host
#               $master         The 'master' password, required by some remote commands, control-deployment for example
#               $timeout        The Expect timeout, how long to wait for a response from the remote host
#               $retOutput      A ref to an array, to collect error messages, for use in the caller.
#               $prompt         A prompt string to look for, I think.
#               $response       The response being looked for.
#               $interactive    used to specify that script runs a copy of itself on another host that may need to
#                               interact with the user.
#   NOTE:   if a ref (or any value, actually), is passed in for $retOutput, the $logStdout variable will be set to zero,
#           which will DISABLE general printing to the screen of any stdout content and YOU WILL NOT see any (or at least
#           most of) the communications between the two hosts.
sub sshCover
{
    my ($command, $password, $master, $timeout, $retOutput, $prompt, $response, $interactive) = @_;

    # Debugging anyone?
    if ($debug) {
        $Expect::Log_Stdout=1;
        $Expect::Exp_Internal=1;
        $Expect::Debug=1;
    }

    # We actually need to be hiding both "regular" user passwords, *and* the master password.  But just in case only
    # one or the other is supplied, don't call the method unless there's a value.  Otherwise it is possible to get
    # a pattern like 'passwd|' or '|master', either of which will match any/every thing.
    &hideString($password) if $password;
    &hideString($master) if $master;

    my $logStdout = $retOutput ? 0 : 1;

    # We expect (:-) the command to be 'ssh' followed by the user@host.  We need to force *ALL* invocations
    # of 'ssh' to use the -t option at all times.  In fact, per the ssh documentation, if we add two -t options,
    # ssh will *always* allocate a remote pseudo terminal, even if there is no local tty to work with.  This is
    # what we want, because we *MUST* be able to turn off echoing, regardless of how the script connects.  The
    # test here must allow for both a fully qualified path name to ssh, where the path could be most near anything,
    # and a "bare" ssh, found via the environment PATH.  This is a fairly simple pattern, just note that the parens
    # not only capture a possible leading path, they also allow the alternate test of no leading characters.
    $command =~ s!(^|[/\w]+)ssh\s!$1ssh -t -t !;

    # We are very interested in what "$hidestr" has in it, rather than just the passwords themselves.
    print "ssh command = '$command' (hide string = '$hidestr')\n" if $debug;
    if ($debug > 1)
    {
        # Must reset our variable here, as well as the end of the method, to prevent carryover of data.
        $hidestr = '';
        return;
    }

    if ($prompt && !$response) {
        print "ERROR ariba::rc::Utils::sshCover provided prompt '$prompt' with no response\n";
        $hidestr = '';
        return 1;
    }
    my $someRandomString = "nO pArtiCular paTTern";
    $prompt = $someRandomString unless($prompt);
    $response = "" unless($response);

    my $ssh = Expect->spawn($command);
    $ssh->stty(qw(-echo));
    my $errString;

    unless ($ssh) {
        $errString =  "ERROR ariba::rc::Utils::sshCover spawn of $command failed, $!\n";

        printExpectError($logStdout,$errString,$retOutput);
        $hidestr = '';
        return 1;
    }

    my $secureConnxRefused = '^(S)?ecure connection to .* refused\.';
    my $connxRefused  = '^(s)?sh: connect to host .* port .*: [Cc]onnection refused';
    my $noRouteToHost = '^(s)?sh: connect to host .* port .*: [Nn]o route to host';
    my $connxClosed = '^(C)?onnection to .* closed\.';
    my $connxClosedByRemote = '^[Ss]?sh_exchange_identification: Connection closed by remote host';
    my $badHost = '^(s)?sh: .*: no address associated with hostname\.';
    my $sshPrompt = qr/(^P|^|'s p)assword:.*/;
    my $sudoPrompt = '(Enter \w+\'s Password:|^Password:|^assword:|\[sudo\] password for \w+: )';
    my $masterPrompt = '[Ee]nter [Mm]aster [Pp]assword: *';
    my $areYouSure = 'Are you sure you want to continue connecting.*$';
    my $hostKey = 'host key for .* has changed';
    my $badPassword = 'denied[\.,]';
    my $badMaster = 'Incorrect Master Password';
    my $commandNotFound = ': Command not found\.';
    # This matches the output created by the askShouldAbort() method in control-deployment "exactly", hopefully it will not
    # cause problems for other applications.  A grep for this string in monitor/... and tools/... found only the match in
    # the control-deployment script (2017-03-09).  To say nothing about the fact it includes the script name ;>
    my $askAbortContinue = 'Enter .* to continue or .* abort control-deployment.*';
    my $pid = $ssh->pid();

    # $ssh->log_stdout($logStdout);
    $ssh->log_stdout(0);
    $ssh->log_file(\&logStdout) if ( $logStdout );

    my $exited = 0;
    # This is set to TRUE in the $sshPrompt part of the expect, but is not used anywhere else, and in particular is not a
    # variable set or used by Expect itself, at least so far as documentation says.
    my $established = 0;
    my $error = 0;
    my $commandOutput = "";

    #
    # see if host is up by looking for a dummy char
    #
    $ssh->expect(120, '-re', '.');
    if ($ssh->exp_error()) {
        $errString =  "ERROR (pid:$$) ariba::rc::Utils::sshCover $pid not responding\n";
        kill(9, $pid);
        printExpectError($logStdout,$errString,$retOutput);
        # This apparently can return "undef", and so it can't be directly assigned without causing an error.
        if ($ssh->exitstatus())
        {
            $? = $ssh->exitstatus();
        }
        $hidestr = '';
        return 1;
    }

    #
    # We feed passwords at several different points, a generic routine
    # that will feed it in and hide it if it is echoed back.
    #
    my $passwordInputHandler = sub {
        my ($ssh, $logStdout, $password) = @_;
        # $ssh->log_stdout(0);
        $ssh->log_file(undef);
        $ssh->stty(qw(-echo));
        print $ssh "$password\r";

        my $pat = quotemeta($password);
        $ssh->expect(0, "-re", "$pat");
        # $ssh->log_stdout($logStdout);
        $ssh->log_file(\&logStdout) if ( $logStdout );
        return $ssh->error();
    };

    #$ssh->restart_timeout_upon_receive(1);
    #
    # feed in 'yes' for 'connect to this host?' prompt
    #
    my $expectFailed;

    #
    # Check this flag after expect block to see if time out happened
    # before seeing an expected prompt.
    #
    # This is to distinguish between things that we know we should
    # see from things that might come up.  For exmample, if master
    # password is passed in, it's expected that there will be a
    # prompt for it, and lack of one will cause an error, while
    # a host key changed error may or may not happen.
    #
    my $timedOutBeforeExpectedInteraction = 0;
    my $firstTimeout = 90;
    if ($master) {
        $timedOutBeforeExpectedInteraction = 1;
        $firstTimeout = 180;
    }
    my $firstPasswordPrompt = 1;

    $ssh->expect($firstTimeout,
        '-re', $askAbortContinue, sub {
                $commandOutput .= $ssh->exp_before();
                $timedOutBeforeExpectedInteraction = 0;
                # This finagling around with log_file and stty is to stop the ddoouubbllee echoing of user input
                # sent to the remote in response to a prompt from the remote.
                my $fh = $ssh->log_file();
                $ssh->log_file(\&noOp);
                $ssh->stty(qw(-echo));
                # print $ssh "\r";
                $ssh->interact();
                $ssh->stty(qw(echo));
                $ssh->log_file($fh);
                return exp_continue_timeout();
            },
        '-re', $areYouSure, sub {
                  print $ssh "yes\r";
                  exp_continue;
            },
        '-re', $sshPrompt, sub {
                $firstPasswordPrompt = 0;
                $expectFailed = $passwordInputHandler->($ssh, $logStdout, $password);
                $timedOutBeforeExpectedInteraction = 0;
                unless ($expectFailed) {
                    $established = 1;
                    return exp_continue_timeout();
                } else {
                    return "ariba_exp_breakout";
                }
            },
        '-re', $masterPrompt, sub {
                $commandOutput .= $ssh->exp_before();
                if ($master) {
                      $expectFailed = $passwordInputHandler->($ssh, $logStdout, $master);
                      $timedOutBeforeExpectedInteraction = 0;
                      $commandOutput .= $ssh->exp_before();
                      if ( $expectFailed ) {                  # see @@@ below for discussion of logic used here.
                          return "ariba_exp_breakout";
                      } else {
                          return exp_continue_timeout();
                      }
                  } else {
                      $errString =  "ERROR ariba::rc::Utils::sshCover ".
                              "(pid: $pid): no master password supplied\n";
                      kill(9, $pid);
                      printExpectError($logStdout,$errString,$retOutput);
                      $error = 1;
                  }
            },
        '-re', $sudoPrompt, sub {
                  if ( $firstPasswordPrompt ) {
                      $firstPasswordPrompt = 0;
                  } else {
                      $commandOutput .= $ssh->exp_before();
                  }
                  $expectFailed = $passwordInputHandler->($ssh, $logStdout, $password);
                  unless ($expectFailed) {
                      return exp_continue_timeout();
                  } else {
                      return "ariba_exp_breakout";
                  }
            },
        '-re', $prompt, sub {
                  $commandOutput .= $ssh->exp_before();
                  if ($prompt ne $someRandomString &&
                      $response) {
                      print $ssh "$response\r";
                  } else {
                    $timedOutBeforeExpectedInteraction = 0;
                     $errString = "ERROR ariba::rc::Utils::sshCover ".
                                 "(pid: $pid): no response for $prompt\n";
                     kill(9, $pid);
                     printExpectError($logStdout,$errString,$retOutput);
                     $error = 1;
                  }
                  exp_continue_timeout;
            },
        '-re', $hostKey, sub {
                $timedOutBeforeExpectedInteraction = 0;
                $errString = "ERROR ariba::rc::Utils::sshCover " . "(pid: $pid): host key changed!\n";
                printExpectError($logStdout,$errString,$retOutput);
                $error = 1;
            },
        '-re', $badPassword,  sub {
                $timedOutBeforeExpectedInteraction = 0;
                $errString = "ERROR ariba::rc::Utils::sshCover " . "(pid: $pid): bad password\n";
                printExpectError($logStdout,$errString,$retOutput);
                $error = 1;
            },
        '-re', $commandNotFound,  sub {
                $timedOutBeforeExpectedInteraction = 0;
                $errString = "ERROR ariba::rc::Utils::sshCover " . "(pid: $pid): command not found. Perhaps product hasn't been pushed to host?\n";
                printExpectError($logStdout,$errString,$retOutput);
                $error = 1;
            },
        '-re', $badMaster,  sub {
                $timedOutBeforeExpectedInteraction = 0;
                $errString =  "ERROR ariba::rc::Utils::sshCover " . "(pid: $pid): bad master password\n";
                kill(9, $pid);
                printExpectError($logStdout,$errString,$retOutput);
                $error = 1;
            },
        '-re', $badHost,    sub {
                $timedOutBeforeExpectedInteraction = 0;
                $errString = "ERROR ariba::rc::Utils::sshCover " . "(pid: $pid): bad host\n";
                printExpectError($logStdout,$errString,$retOutput);
                $error = 1;
            },
        '-re', $secureConnxRefused, sub {
                $timedOutBeforeExpectedInteraction = 0;
                $errString = "ERROR ariba::rc::Utils::sshCover " . "(pid: $pid): secure connx refused\n";
                printExpectError($logStdout,$errString,$retOutput);
                $error = 1;
            },
        '-re', $connxRefused, sub {
                $timedOutBeforeExpectedInteraction = 0;
                $errString = "ERROR ariba::rc::Utils::sshCover " . "(pid: $pid): connx refused\n";
                printExpectError($logStdout,$errString,$retOutput);
                $error = 1;
            },
        '-re', $connxClosedByRemote , sub {
                $timedOutBeforeExpectedInteraction = 0;
                $errString =  "ERROR ariba::rc::Utils::sshCover " . "(pid: $pid): connx closed by remote host\n";
                printExpectError($logStdout,$errString,$retOutput);
                $error = 1;
            },
        '-re', $noRouteToHost, sub {
                $timedOutBeforeExpectedInteraction = 0;
                $errString =  "ERROR ariba::rc::Utils::sshCover " . "(pid: $pid): no route to host\n";
                printExpectError($logStdout,$errString,$retOutput);
                $error = 1;
            },
        'eof', sub {
                $exited = 1;
            },
    );

    if ($timedOutBeforeExpectedInteraction) {
        my $errString =  "ERROR ariba::rc::Utils::sshCover " . "(pid: $pid): timed out while waiting for expected prompt\n";
        kill(9, $pid);
        printExpectError($logStdout,$errString,$retOutput);
        $error = 1;
    }

    #
    # If there was an error during the above checks, return that.
    #
    if ($error)
    {
        $hidestr = '';
        return $error 
    }

    #
    # wait for the process to finish, by waiting for eof, and get it's
    # exit status. Thanks to a bug in Expect.pm, we cannot always rely
    # on 'exp_exitstatus' to give us the right thing, so use that or $?
    # to find out a good return code.
    #
    if ($exited || $expectFailed) {
        $commandOutput .= $ssh->exp_before();
    } else {
        #
        # HACK! to shutup perl warning in case timeout is undef (wait
        # forever):
        # Use of uninitialized value at
        # /usr/local/lib/perl5/site_perl/5.005/Expect.pm line 318.
        #
        if ( $interactive ) {
            $commandOutput .= $ssh->exp_before();
            $ssh->log_file(\&noOp);
            $ssh->interact();
        } else {
            $ssh->expect($timeout,
                '-re', $prompt, sub {
                          $commandOutput .= $ssh->exp_before();
                          if ($prompt ne $someRandomString &&
                              $response) {
                              print $ssh "$response\r";
                          } else {
                             $errString =  "ERROR ariba::rc::Utils::sshCover ".
                                         "(pid: $pid): no response for $prompt\n";
                             kill(9, $pid);
                             printExpectError($logStdout,$errString,$retOutput);
                             $error = 1;
                          }
                          exp_continue_timeout;
                    },
                'eof', sub {
                           $exited = 1;
                    },
            );
        }
        $commandOutput .= $ssh->exp_before();
    }


    my $status = ($ssh->exp_exitstatus() || $?) >> 8;

    if($retOutput) {
        # strip out leading \n that might have resulted from password
        # prompt feed.
        $commandOutput =~ s/^\r\n//;
        push(@{$retOutput}, grep{$_ !~ /Connection\s*to.*?closed/i}split('\r\n', $commandOutput));
    }

    $ssh->stty(qw(echo));
    # And to be sure things don't get messed up too badly, zero out the hidestr, so it doesn't carry over
    # if this method is called multiple times.
    $hidestr = '';
    return $status; #return exit status 0 for success, non zero otherwise
}

1;

__END__

Original code for the 'if' was:  if ( $expectFailed || $interactive ) {

@@@ It seems to us, today, that using 'interactive' in this section of code is irrelevant, because this is processing the master password
    and that *WILL NOT* ever produce an 'out of band' response needing interactive processing.

    In other words, the 'interactive' flag was introduced for arches (an active-active product), where c-d is run on the copyhost or monserver,
    and connects with the copyhosts in both the primary and secondary clusters, to *re-run* the full c-d script.  In this case, the remotely
    running c-d could have a failure that generates a basic 'continue/abort' question, that is outside the normal Expect processing loop.

    So code was added to check, *after* the first expect loop, to see if the script is running interactively, and if it is, allow the user
    to interact with the remote c-d, in the case where it might have generated the out of bound question.

    Though the above seems to be a proper understanding of the original intent, it does not seem to work reliably.  After much pushing and
    shoving, I finally decided, since c-d has a standardized abort/continue method, it made sense to look for it explicitly and process
    interactively.  Because the setup is two copies of the program (c-d) running, the result was 'double echoing', so turning off echoing for
    one means the user input of one character sees one character returned.  The first part, about master password, is still applicable.
