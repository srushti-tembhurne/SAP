#
# $Id:
# //ariba/sandbox/analysishana/services/release/tools/2.0.0+/lib/perl/ariba/Ops/HanaServiceManager.pm
#
# Note: This file is based on OracleServiceManager and was ported to Hana by
# Vivek Prasad
#

package ariba::Ops::HanaServiceManager;

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
        'debug' => 0,
        'error' => undef,
		'sid' => $sid,
    };

    bless($self, $class);

    return $self;
}

sub service      { my $self = shift; return $self->{'service'}; }
sub setService   { my $self = shift; my $service = shift; $self->{'service'} = $service; }
sub hostList      { my $self = shift; return $self->{'hostlist'}; }
sub setHostList   { my $self = shift; my $hostlist = shift; $self->{'hostlist'} = $hostlist; }
sub sid      { my $self = shift; return $self->{'sid'}; }
sub setSid   { my $self = shift; my $sid = shift; $self->{'sid'} = $sid; }
sub debug    { my $self = shift; return $self->{'debug'}; }
sub setDebug { my $self = shift; my $debug = shift; $self->{'debug'} = $debug; }
sub error    { my $self = shift; return $self->{'error'}; }
sub setError { my $self = shift; my $error = shift; $self->{'error'} = $error; }
sub useLogger { my $self = shift; return $self->{'logger'}; }
sub setUseLogger { my $self = shift; my $logger = shift; $self->{'logger'} = $logger; }

sub startup {
    my $self = shift;
    my $noerror = shift;
    my $hanadmid = shift;

    unless ( $self->isDatabaseRunning() ) {
        return $self->_runCommandAsAdmUser('HDB start', '^StartWait\r?$', $hanadmid);
    } else {
        if($noerror) {
            print "OK: HANA is already running.\n"
                if($self->debug());
            return 1;
        }
        $self->setError("HANA is already running");
        return 0;
    }
    
}

sub shutdown {
    my $self = shift;
    my $noerror = shift;
    my $hanadmid = shift;

    if ( $self->isDatabaseRunning() ) {
        return $self->_runCommandAsAdmUser('HDB stop', '^hdbdaemon is stopped.\r?$', $hanadmid);
    } else {
        if($noerror) {
            print "OK: HANA is already shutdown.\n"
                if($self->debug());
            return 1;
        }
        $self->setError("HANA is not running");  
        return 0;
    }
}

sub isDatabaseRunning {
    my $self = shift;

    my $processTable = ariba::Ops::ProcessTable->new();

    my $status = $processTable->processWithNameExists("hdbnameserver");

    return $status;
}

sub _runCommandAsAdmUser {
    my $self = shift;
    my $sql = shift;
    my $expectedReturnString = shift || "";
    my $hanadmid = shift;
    my $outputRef = shift;
    my $timeout = shift || 600;
    my $output = "";

    my $debug = $self->debug();
    my $password;

    my $uid = $<;
    my $user = (getpwuid($uid))[0];

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

   my $command = "";
   if ($hanadmid) {
     $command = "sudo su - $hanadmid -c '\$DIR_INSTANCE/$sql'";     
   } else {
     $command = "sudo su hdbadm -c '/usr/sap/HDB/HDB00/$sql'";
   } 

    print "command:$command\n" if ($debug);

    my $hdbcommand = Expect->spawn($command) || do {
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

    $hdbcommand->log_stdout(0);
    $hdbcommand->log_file($func);


    # "Magic" keyword for don't timeout
    #
    $timeout = undef;
       
    my $toExpect = $expectedReturnString || "A string that will never appear in results";

    $hdbcommand->expect($timeout,
            ['-re', '[pP]assword', sub {
                        my $self = shift;
                        $self->log_file(undef);
                        $self->send("$password\n");
                        $self->log_file($func);
                        exp_continue();
                    }
            ],
            ['-re', "$toExpect" =>
                sub {
                    my $self = shift;
                    $output .= $self->exp_before();
                    $success = 1;
                    exp_continue();
                }
            ],
            ['eof', sub {
                       my $self = shift;
                       $output .= $self->exp_before();
                       $exited = 1;
                     }
             ],
    );
    
    if($output) {
        if($outputRef) {
            $output =~ s/^[\r\n]+//;
            my $regex = quotemeta($sql);
            $output =~ s/^\s*$regex[\r\n]*//;
            push(@{$outputRef}, split(/[\n\r]+/, $output));
        }
    }

    return 1 if ($success || !$expectedReturnString) && $exited;

    $self->setError("expect parsing of command failed: " . $hdbcommand->error());
    return 0;

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
	my $hanaInstanceId = shift || "00";

    my $sid = $self->sid();
    my $debug = $self->debug();
        
    my $password;

    my $uid = $<;
    my $user = (getpwuid($uid))[0];

	unless($schema) {
		$schema = "system";
	}
	unless($schemaPassword) {
		if(ariba::rc::Passwords::initialized()) {
			my $service = ariba::rc::Passwords::service();
			my $mon = ariba::rc::InstalledProduct->new('mon',$service);
			if($schema eq 'system') {
				$schemaPassword = $mon->default('dbainfo.hana.system.password');
			} elsif($schema eq 'backup') {
				$schemaPassword = $mon->default('dbainfo.hana.backup.password');
			}
			unless($schemaPassword) {
				croak('Unable to lookup schemaPassword for $schema via mon');
			}
		} else {
			#
			# try cipher store
			#
			if($self->service()) {
				my $cipher = ariba::rc::CipherStore->new( $self->service() );
				my $key;
				if($schema eq 'system') {
					$key = "mon/" . $self->service() . ":dbainfo.hana.system.password";
				} elsif($schema eq 'backup') {
					$key = "mon/" . $self->service() . ":dbainfo.hana.backup.password";
				}
		
				$schemaPassword = $cipher->valueForName( $key ) if($key);
			}
		}
		unless( $schemaPassword ) {
			croak("Must provide schemaPassword or have master password.");
		}
	}
	
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
            croak("HanaServiceManager must run as root or have master password");
        }
    }

	my $admuser = lc($self->sid()) . "adm";

	$ENV{'TERM'} = 'vt100';
	my $hostArg = " ";
	if($self->hostList()) {
		$hostArg = " -n " . $self->hostList() . " ";
	}
    my $command = "sudo su - $admuser -c 'hdbsql -i ${hanaInstanceId}${hostArg}-u $schema -p $schemaPassword'";


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


	my $pageOff = 0;
    $sqlplus->expect(30,
			['-re', '[pP]assword', sub {
						my $self = shift;
						$self->log_file(undef);
						$self->send("$password\n");
						$self->log_file($func);
						exp_continue();
					}
			],
            ['-re', 'hdbsql=>', sub {
                        my $self = shift;
						if($pageOff == 0) {
							#
							# XXX this appears to be a hana bug -- on is off
							#
							$self->send("\\pa on\n") unless($pageOff);
							$pageOff = 1;
                        	exp_continue();
						} else {
							$self->send("$sql\n");
						}
                    }
            ],
            ['-re', "switched OFF" => sub {
						$pageOff = 2;
                       	exp_continue();
                    }
            ],
    );

	#
	# "Magic" keyword for don't timeout
	#
	$timeout = undef if($timeout eq 'undef');
	my $mark = 0;

	my $jnk = $sqlplus->exp_before();

    my $toExpect = $expectedReturnString || "A string that will never appear in SQL results";
    $sqlplus->expect($timeout,
            ['-re', "$toExpect" =>
                sub {
                    my $self = shift;
                    $output .= $self->exp_before();
                    $success = 1;
					$mark = 1;
                    exp_continue();
                }
            ],
            ['-re', 'hdbsql.*=>' =>
                sub {
                    my $self = shift;
                    $output .= $self->exp_before();
                    $self->send("\\q\n");
                    $exited = 1;
					$mark = 1;
                }
            ],
    ) if $sqlplus->match();

	$output .= $sqlplus->exp_before() unless($mark);

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

sub determineSid {
	my $class = shift;

	my $cmd = "ls -ld /hana/data";
	my @output = ();
	my $ret = ariba::rc::Utils::executeLocalCommand(
		$cmd, 0, \@output, undef, 1);

	my $hanaSid;

	foreach my $line (@output) {
		if($line =~ m|\s([a-z0-9]+)adm\s|) {
			$hanaSid = $1;
			last;
		}
	}
	return(uc($hanaSid));
}

sub noop {
}


1;
