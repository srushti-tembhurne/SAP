#
# $Id: //ariba/services/tools/lib/perl/ariba/Ops/OracleServiceManager.pm#16 $

package ariba::Ops::OracleServiceManager;

# this is 

use strict;

use Carp;
use Expect;

use ariba::rc::Passwords;
use ariba::rc::CipherStore;
use ariba::rc::InstalledProduct;
use ariba::Ops::ProcessTable;
use ariba::Ops::Logger;

sub new {
    my $class = shift;
    my $sid = shift;

    my $self = {
        'sid' => uc($sid),
        'oracleHome' => undef,
        'debug' => 0,
        'error' => undef,
    };

    bless($self, $class);

    return $self;
}

sub sid      { my $self = shift; return $self->{'sid'}; }
sub debug    { my $self = shift; return $self->{'debug'}; }
sub setDebug { my $self = shift; my $debug = shift; $self->{'debug'} = $debug; }
sub error    { my $self = shift; return $self->{'error'}; }
sub setError { my $self = shift; my $error = shift; $self->{'error'} = $error; }
sub useLogger { my $self = shift; return $self->{'logger'}; }
sub setUseLogger { my $self = shift; my $logger = shift; $self->{'logger'} = $logger; }

sub setOracleHome{
    my $self = shift;
    my $home = shift or croak __PACKAGE__ . "::setOracleHome(): required argument 'home' missing!\n";

    $self->{ 'oracleHome' } = $home;
    return 0;
}

sub oracleHome {
    my $self = shift;

    return $self->{'oracleHome'} if $self->{'oracleHome'};

    my $sid = $self->sid();
    my $oracleHome = `/usr/local/bin/dbhome $sid`;
    chomp $oracleHome;
    if (!$oracleHome || ! -f "$oracleHome/bin/sqlplus" ) {
        $self->setError("Could not get ORACLE_HOME for sid '$sid'");
        return;
    }

    $self->{'oracleHome'} = $oracleHome;

    return $oracleHome;
}

sub test {
    my $self = shift;
    return $self->_runSqlFromServiceManager('select \'foo\' from dual;', '^foo\r?$');
}

sub startup {
    my $self = shift;
    my $noerror = shift;

    unless ( $self->isDatabaseRunning() ) {
        return $self->_runSqlFromServiceManager('startup', '^Database opened.\r?$');
    } else {
        if($noerror) {
            print "OK: ", $self->sid(), " is already running.\n"
                if($self->debug());
            return 1;
        }
        $self->setError($self->sid() . " is already running");  
        return;
    }
}

sub startupMount {
    my $self = shift;
    my $noerror = shift;

    unless ( $self->isDatabaseRunning() ) {
        return unless $self->_runSqlFromServiceManager('startup mount', '^Database mounted.\r?$');
        return unless $self->_runSqlFromServiceManager('alter database open;', '^Database altered.\r?$');
        return $self->_runSqlFromServiceManager('alter system register;', '^System altered.\r?$');
    } else {
        if($noerror) {
            print "OK: ", $self->sid(), " is already running.\n"
                if($self->debug());
            return 1;
        }
        $self->setError($self->sid() . " is already running");  
        return;
    }
}

sub flashbackToTime {
	my $self = shift;
	my $dateTime = shift;

	my $sql = "flashback database to timestamp TO_TIMESTAMP('$dateTime','YYYY-MM-DD:HH24:MI:SS');";

    if ( $self->isDatabaseRunning() ) {
        return $self->_runSqlFromServiceManager($sql, undef);
	} else {
        $self->setError($self->sid() . " is not running");
        return;
	}
}

sub startupNoMount {
    my $self = shift;
    my $noerror = shift;

    unless ( $self->isDatabaseRunning() ) {
        return $self->_runSqlFromServiceManager('startup nomount', '^ORACLE instance started.\r?$');
    } else {
        if($noerror) {
            print "OK: ", $self->sid(), " is already running.\n"
                if($self->debug());
            return 1;
        }
        $self->setError($self->sid() . " is already running");
        return;
    }
}

sub shutdown {
    my $self = shift;
    my $noerror = shift;

    if ( $self->isDatabaseRunning() ) {
        return $self->_runSqlFromServiceManager('shutdown immediate', '^ORACLE instance shut down.\r?$');
    } else {
        if($noerror) {
            print "OK: ", $self->sid(), " is already shutdown.\n"
                if($self->debug());
            return 1;
        }
        $self->setError($self->sid() . " is not running");  
        return;
    }
}

sub abort {
    my $self = shift;
    my $noerror = shift;

    if ( $self->isDatabaseRunning() ) {
        return $self->_runSqlFromServiceManager('shutdown abort', '^ORACLE instance shut down.\r?$');
    } else {
        if($noerror) {
            print "OK: ", $self->sid(), " is already shutdown.\n"
                if($self->debug());
            return 1;
        }
        $self->setError($self->sid() . " is not running");  
        return;
    }
}

sub isDatabaseRunning {
    my $self = shift;

    my $sid = $self->sid();

    my $processTable = ariba::Ops::ProcessTable->new();

    my $status = $processTable->processWithNameExists("ora_pmon_$sid\\s*\$");

    return $status;
}

sub _runSqlFromServiceManager {
    my $self = shift;
    my $sql = shift;
    my $expectedReturnString = shift || "";
    my $outputRef = shift;
	my $schema = shift;
	my $schemaPassword = shift;
	my $timeout = shift || 600;
    my $output = "";

    my $sid = $self->sid();
    my $debug = $self->debug();

    my $oracleHome = $self->oracleHome();
    return unless ($oracleHome);
        
    print "Oracle Home is set to: $oracleHome\n" if $debug >= 2;

    my $password;

    my $uid = $<;
    my $user = (getpwuid($uid))[0];

    #
    # root don't need no stinking password...
    #
    unless($user eq 'root') {
        if(ariba::rc::Passwords::initialized()) {
            my $service = ariba::rc::Passwords::service();
            $password = ariba::rc::Passwords::lookup($user);
            unless($password) {
                croak("Unable to lookup password for $user with master password for $service\n");
            }
        } else {
            my $service = $user;
            unless($service =~ s/^mon//) {
                croak("Script must either initialize the master password, or run as a mon user.\n");
            }
            my $cipherStore = ariba::rc::CipherStore->new( $service );
            $password = $cipherStore->valueForName($user);
            unless($password) {
                croak("Unable to get password from cipherStore as user $user for service $service.  (Is mon started?)\n");
            }
        }
    }

	my $oracleLogin;
	if($schema) {
		$oracleLogin = "$schema/$schemaPassword\@$sid";
	} else {
		$oracleLogin = '"/ as sysdba"';
	}

    my $command = "sudo su oracle -c 'export LD_LIBRARY_PATH=/usr/lib:$oracleHome/lib; export ORACLE_HOME=$oracleHome; export ORACLE_SID=$sid; $oracleHome/bin/sqlplus $oracleLogin'";

    print "Spawning: '$command'\n" if $debug >= 2;

    my $sqlplus = Expect->spawn($command) || do {
        $self->setError("spawn of '$command' failed");
        return;
    };

    my $exited = 0;
    my $success = 0;
    my $error = "";

	my $func = \&noop;
	if($self->useLogger()) {
		$func = \&LoggerStdOut;
	} elsif($debug) {
		$func = \&logStdOut;
	}
    $sqlplus->log_stdout(0);
	$sqlplus->log_file($func);
    $sqlplus->expect(30,
            ['-re', '[pP]assword', sub {
                        my $self = shift;
                        $self->log_file(undef);
                        $self->send("$password\n");
                        $self->log_file($func);
                        exp_continue();
                    }
            ],
            ['-re', "SQL>" => sub {
                        my $self = shift;
                        if ( length $sql < 4096 ){
                        	$self->send("$sql\n");
                        } else {
                            ## 0.01 second timeout:
                            $self->send_slow(0.01, "$sql\n");
                        }
                    }
            ],
    );

	#
	# "Magic" keyword for don't timeout
	#
	$timeout = undef if($timeout eq 'undef');

    my $toExpect = $expectedReturnString || "A string that will never appear in SQL results";
    $sqlplus->expect($timeout,
            ['-re', "$toExpect" =>
                sub {
                    my $self = shift;
                    $output .= $self->exp_before();
                    $success = 1;
                    exp_continue();
                }
            ],
            ['-re', 'SQL>' =>
                sub {
                    my $self = shift;
                    $output .= $self->exp_before();
                    $self->send("exit\n");
                    $exited = 1;
                }
            ],
			['eof', sub {
					my $self = shift;
					$output .= $self->exp_before();
					$exited = 1;
				}
			],
    ) if $sqlplus->match();

    if($output) {
        if($outputRef) {
            $output =~ s/^[\r\n]+//;
            my $regex = quotemeta($sql);
            $output =~ s/^\s*$regex[\r\n]*//;
            push(@{$outputRef}, split(/[\n\r]+/, $output));
        }
    }

    return 1 if ($success || !$expectedReturnString) && $exited;

    $self->setError("expect parsing of command failed: " . $sqlplus->error());
    return;

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

sub logStdOut {
	my $txt = shift;
	print STDOUT $txt;
}

sub noop {
}


1;
