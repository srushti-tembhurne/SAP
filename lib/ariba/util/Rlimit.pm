#
# Util covers for getrlimit() and setrlimit()
#

package ariba::util::Rlimit;

use strict;

require "sys/resource.ph";
require "sys/syscall.ph";

my $rlim_t = "L";
my $rlimit = "$rlim_t $rlim_t";

my %resources = (
	"cputime", RLIMIT_CPU(),
	"filesize", RLIMIT_FSIZE(),
	"datasize", RLIMIT_DATA(),
	"stacksize", RLIMIT_STACK(),
	"coredumpsize", RLIMIT_CORE(),
	"descriptors", RLIMIT_NOFILE(),
	"vmemory", RLIMIT_VMEM(),
);


sub getrlimit {
	my $resource = shift;
	my ($rlim_cur, $rlim_max, $rs);

	$resource = $resources{$resource} if defined($resources{$resource});

	$! = 0;
	$rs = pack($rlimit, 0, 0);
	syscall(SYS_getrlimit(), $resource, $rs);
	if ( $! ) {
		warn "getrlimit: $!\n";
	}
	($rlim_cur, $rlim_max) = unpack($rlimit, $rs);
	
	return ($rlim_cur, $rlim_max);
}

sub setrlimit {
	my $resource = shift;
	my $rlim_cur = shift;
	my $rlim_max = shift;
	my $rs;

	$resource = $resources{$resource} if defined($resources{$resource});

	$!=0;
	$rs = pack($rlimit, $rlim_cur, $rlim_max);
	syscall(SYS_setrlimit(), $resource, $rs);
	if ( $! ){
		warn "setrlimit: $!\n";
	}
	($rlim_cur, $rlim_max) = unpack($rlimit, $rs);
	return ($rlim_cur, $rlim_max);
}

1;
