#
# Utility function to get some oracle db information
#
# note sidToOracleServerVersion routine is expensive, trys to open oracle connection
# with tracing on, so should not be used in a tight loop.
#
#
package ariba::util::OraInfo;

use strict;
use File::Copy;
use File::Path;
use File::Basename;
use ariba::Ops::ProcessTable; 
use ariba::util::UnitConversion qw(strToNumOfMBs);
use ariba::util::Misc;


my $debug = 0;
my $oratabFile = "/etc/oratab";

sub setDebug { 
	$debug = shift; 
} 

sub oraHome
{
    my $defaultOraHome = -d "/usr/local/oracle" ? 
			    "/usr/local/oracle" :
			    "/opt/oracle";
    my $oracleHome = $ENV{'ORACLE_HOME'};

    if (defined($oracleHome)) {
	return $oracleHome;
    } else {
	return $defaultOraHome;
    }

}

sub tnsAdmin
{
    my $tnsAdmin = $ENV{'TNS_ADMIN'};

    my $oracleHome = oraHome();
    my $adminSubdir = "/network/admin";

    my $val = $tnsAdmin;

    if (!defined($val)) {
	$val = "$oracleHome/$adminSubdir";
    }

    return $val;
}

sub latestOracleHome {

	my $latest;

	open(ORA, $oratabFile)
		or return;
	while (<ORA>) {
		next if (/^\s*#/ || /^\s*$/);
		my ($sid, $home, $autoStart) = split(/:/, $_, 3);
		print STDERR "Unparseable entry in $oratabFile, line $.\n" unless($home);
		my $version = oracleVersionFromHome($home);
		return unless $version;

		unless ($latest) {
			$latest = $home;
		} else {
			my $latestVersion = oracleVersionFromHome($latest);
			if (ariba::util::Misc::compareVersion($version, $latestVersion) == 1) {
				$latest = $home;
			}
		}
	}
			
	close(ORA);

	return $latest;

}

sub oracleVersionFromHome {
	my $home = shift;

	return unless $home;
	my $versionFromPath = basename($home);
	$versionFromPath =~ s/[^0-9.]//g;
	my $version = ($versionFromPath =~ /^\d+\.\d+/) ? $versionFromPath : undef;

	return $version;
}

sub sidToHostname
{
    my $sid = shift();

    my $tnsAdmin = tnsAdmin();
    my $tnsNames = "tnsnames.ora";

    my ($host, $found);

    return $host unless(defined($sid));

    $found = 0;

    open(FL, "$tnsAdmin/$tnsNames") || return $host;
    while(<FL>) {

	next if (/^\s*#/);
	if (/^\s*$sid\b/i) {
	    $found = 1;
	}
	next if (!$found);

	if (/Host\s*=\s*([\w-]*)/io) {
	    $host = $1;
	    last;
	}
    }

    return $host;
}

sub serverVersionFromTraceFile
{
	my $traceFile = shift();
	my $version;

	open(FL, "$traceFile") || return $version;
	while(<FL>) {
		if (/Version received/o) {
			$version = (split(/:/, $_))[-1];
			$version = (split(/\s+/, $version))[2];
			last;
		}
	}
	close(FL);

	return $version;
}


sub serverVersionFromString
{
	my $string = shift;
	my $version;

	$version = $1 if ($string =~ /SQL\*Plus: Release ([\d.]+) /);	

	return $version;
}

sub turnOnTracing
{
    my $scratch = shift();
    my $sqlNet = shift();

    my $file = "$scratch/$sqlNet";
    chmod(0700, $file);

    open(FL, ">> $file") || return 0;
    print FL "TRACE_LEVEL_CLIENT = 16\n";
    print FL "TRACE_DIRECTORY_CLIENT = $scratch\n";
    print FL "TRACE_FILE_CLIENT = $$\n";
    close(FL);

    return "$scratch/$$.trc";
}

# Have to setup tnsnames.ora and sqlnet.ora prior to calling
# See ariba::Ops::OracleClient.pm
sub sidToOracleServerVersion
{
	my $sid = shift();
	my $scratch = "/tmp/oraVer$$";

	my $tnsAdmin = tnsAdmin();
	my $tnsNames = "tnsnames.ora";
	my $sqlNet = "sqlnet.ora";
	my $sqlPlus = oraHome() . "/bin/sqlplus";

	mkpath($scratch);

	File::Copy::copy("$tnsAdmin/$tnsNames", $scratch);
	File::Copy::copy("$tnsAdmin/$sqlNet", $scratch);

	my $traceFile = turnOnTracing($scratch, $sqlNet);

	$ENV{'TNS_ADMIN'} = $scratch;
	system("$sqlPlus junk/junk\@$sid < /dev/null > /dev/null 2>&1");
	$ENV{'TNS_ADMIN'} = $tnsAdmin;

	my $version = serverVersionFromTraceFile($traceFile);

	rmtree($scratch);

	return $version;
}

# This is easier to get but only works locally on the db server
sub sidToOracleBinaryVersion
{
	my $sid = shift();
	my $home = oraHome(); 

	my @oratab = sidToOratab($sid); 
	$home = $oratab[1] if (@oratab);

	local $ENV{'ORACLE_HOME'} = $home;
	my $sqlPlus = "$home/bin/sqlplus";

	# Get from sqlplus 
	my $output = `$sqlPlus junk/junk\@$sid < /dev/null 2>&1;`;
	my $version = serverVersionFromString($output);

	# Get from Oracle home path as a last result
	$version = oracleVersionFromHome($home) unless ($version);

	return $version;
}

sub sidToOratab
{
	my $requestedSid = shift;
	my @oratab;

	open(ORA, $oratabFile)
		or return @oratab;
	while (<ORA>) {
		next if (/^\s*#/ || /^\s*$/);
		my ($sid, $home, $autoStart) = split(/:/, $_, 3);
		print STDERR "Unparseable entry in $oratabFile, line $.\n" unless($home);
		if (!defined $requestedSid || lc($sid) eq lc($requestedSid)) {
			@oratab = ($sid, $home, $autoStart);
			last;
		}
	}
	close(ORA);
	return @oratab;
}

sub sidToOracleHome
{
    my $requestedSid = shift;
	my @oratab = sidToOratab($requestedSid);

	return $oratab[1];
}

sub sidFromProcessName { 
	my $processName = shift;
	my $sid;  

	$sid = $1 if ($processName =~ /ora_pmon_(\w+)\s*$/);
	
	return $sid; 
}

sub initSettingsForSid { 
	my $sid = shift; 
	my %settings = (); 

	my $initFile = "/oracle/admin/pfile/init$sid.ora"; 
	if (open(my $fh, $initFile)) { 
		# Doesn't work for some multilined settings, 
		# but no need to write a full parser atm.
		for my $line (<$fh>) {  
			if ($line !~ /^\s*#/ && $line =~ /^\s*(.+?)\s*=\s*(.+?)\s*$/) {
				$settings{$1} = $2; 
			}
		};  
		close($fh); 
	} 

	return \%settings; 
} 

# size is -1 if failed to convert value to number of MBs. 
sub sgaInfoForSid { 
	my $sid = shift;
	my %sgaInfo = (size => undef, 'type' => undef);  

	my %settings = %{initSettingsForSid($sid)}; 
	if (%settings) { 
		if ($settings{sga_target}) { 
			$sgaInfo{size} = strToNumOfMBs($settings{sga_target}); 
			$sgaInfo{type} = 'dynamic'; 				
		} else { # static. Going to get sga size from other keys. 
			my $size = 0; 
			my $incorrectUnit = 0; 
			for my $key (keys %settings) {  
				if ($key =~ /db_cache_size|db_keep_cache_size|java_pool_size|large_pool_size|shared_pool_size/io) { 
					my $numOfMBs = strToNumOfMBs($settings{$key}); 
					if ($numOfMBs >= 0) {
						$size += $numOfMBs; 
					} else { 
						$incorrectUnit = 1;
					} 
				} 
			}; 
			$size = -1 if ($incorrectUnit); 
			$sgaInfo{size} = $size; 
			$sgaInfo{type} = 'static'; 
		} 
	
	}
	
	return %sgaInfo;	
} 

sub totalUsedSga { 		
	my $ps = ariba::Ops::ProcessTable->new(); 
	my @processNames = $ps->processNamesMatching("ora_pmon");
	my $totalUsed = 0; 

	for my $processName (@processNames) { 
		my $sid = sidFromProcessName($processName); 
		if ($sid) { 
			my %sgaInfo = sgaInfoForSid($sid); 
			if ($sgaInfo{size} && $sgaInfo{size} > 0) { 
				$totalUsed += $sgaInfo{size}; 
			} 
		} else { 
			print "WARNING: Failed to convert $processName to SID\n" if ($debug); 
		} 
	}
	
	return $totalUsed;  
} 

sub test
{
    my $sid = $ARGV[0];
    my $version = sidToOracleServerVersion($sid);
    my $binaryVersion = sidToOracleBinaryVersion($sid);
	my $latestOracleHome = latestOracleHome();
    my $host = sidToHostname($sid);
	my $home = sidToOracleHome($sid);
	my @oratab = sidToOratab($sid);

    print "Oracle server version for $sid = $version\n";
    print "Oracle binary version for $sid = $binaryVersion\n";
    print "Oracle for $sid runs on host = $host\n";
	print "ORACLE_HOME for $sid = $home\n";
	print "/etc/oratab for $sid = ", join(':', @oratab), "\n";
	print "Latest Oracle home = $latestOracleHome\n";
}

#test();

1;
