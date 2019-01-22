# $Id$

package ariba::WebStats::IP2Host;

use strict;
use vars qw(@ISA @EXPORT %servers);
use Exporter;
use IO::Handle;
use IO::Select;
use Net::DNS;
use Socket;

@ISA    = qw(Exporter);
@EXPORT = qw(ip2host);

my %hosts = ();
my %q	  = ();
my %cache = ();
my %socks = ();
my %class = ();
my @lines = ();
my $ipmask = qr/^(\d+)\.(\d+)\.(\d+)\.(\d+)/;

my $res = Net::DNS::Resolver->new();
my $sel = IO::Select->new();

my $max_children = 40;   # Number of children to spawn
my $dns_timeout	 = 30;   # DNS timeout
my $bufsize	 = 10000;

sub ip2host {
	my ($in_fh, $out_fh, $cache_file) = @_;

	if ($cache_file) {
		eval {
			use DB_File;
			tie %cache, 'DB_File', $cache_file or 
				die "unable to tie [$cache_file]: $!";
		};
	}

	while (1) {
		getlines($in_fh);
		last if $#lines == -1;
		makequeries();
		checkresponse();
		checktimeouts($dns_timeout);
		printresults($out_fh);
	}

	untie %cache;
}

sub getlines {
	my $in_fh = shift;
	return if eof $in_fh;

	while (($#lines < $bufsize - 1) and my $line = <$in_fh>) {
		push @lines, $line;
		next if $line !~ /^$ipmask\s/;
		addhost(($line =~ /^(\S+)/));
	}
}

sub addhost {
	my $ip = shift;

	if (exists $hosts{$ip}) {
		$hosts{$ip}{'COUNT'}++;
		return;
	}

	$hosts{$ip}{'NAME'}  = -1;
	$hosts{$ip}{'COUNT'} = 1;
	$q{$ip} = 0;
}

sub removehost {
	my $ip = shift;
	if (--$hosts{$ip}{'COUNT'} < 1) {
		if ($hosts{$ip}{'NAME'} !~ /^(?:-1|-2)$/) {
			$cache{$ip} = $hosts{$ip}{'NAME'};
		}

		my $resolved = getresolved($ip);
		delete $hosts{$ip};
        }
	return;
}

sub getresolved {
	my $ip = shift;
	return -1 if $hosts{$ip}{'NAME'} eq '-1';
	return $hosts{$ip}{'NAME'} if $hosts{$ip}{NAME} ne '-2';
	return $cache{$ip} if exists $cache{$ip};
	return -2;
}

sub makequeries {
	my @keys = keys %q;

	for (1..($max_children - $sel->count)) {
		my $query = shift @keys || last;
		($query =~ /$ipmask/) ? query($query, 'H') : query($query, 'C');
		delete $q{$query};
	}
}

sub checkresponse {
	for ($sel->can_read(5)) {
		my $resolved = 0;
		my $fileno = fileno($_);
		my $query = $socks{$fileno}{'QUERY'};
		my $type  = $socks{$fileno}{'TYPE'};
		my $dnstype = ($type eq 'H') ? 'PTR' : 'SOA';
		my $timespan = time() - $socks{$fileno}{'TIME'};

		my $packet = $res->bgread($_);
		$sel->remove($_);
		delete $socks{$fileno};

		if ($packet) {
			for ($packet->answer) {
				next if $_->type ne $dnstype;

				if ($type eq 'H') {
					$resolved = 1;
					$hosts{$query}{'NAME'} = $_->{'ptrdname'};
					next;
				}

				my ($ns, $domain) = $_->{'mname'} =~ /([^\.]+)\.(.*)/;
				if (defined $domain) {
					if (defined $class{$query}) {
						$class{$query}{'NAME'} = $domain 
					}
					$resolved = 1;
				}
			}
		}
		
		unless ($resolved) {
			if ($type eq 'H') {
				$hosts{$query}{'NAME'} = -2;
			} else {
				$class{$query}{'NAME'} = -2 if defined $class{$query} ;
			} 
		}
	}
}

sub checktimeouts {
	my $timeout = shift;
	my $now = time();

	for ($sel->handles) {
		my $fileno = fileno($_);
		my $query = $socks{$fileno}{'QUERY'};

		my  $timespan = $now - $socks{$fileno}{'TIME'};
		if ($timespan > $timeout) {

			if ($socks{$fileno}{'TYPE'} eq 'H') {
				$hosts{$query}{'NAME'} = -2;

			} else {
				$class{$query}{'NAME'} = -2 if defined $class{$query};
			}

			$sel->remove($_);
			delete $socks{$fileno};
		}
	}
}

sub query {
	my ($find, $type) = @_;
	my $send = $type eq 'H' ? $find : "$find.in-addr.arpa";

	my $sock = $res->bgsend($send, ($type eq 'H') ? 'PTR' : 'SOA');
	die "Error opening socket for bgsend. Are we out of sockets?" if !defined $sock;

	$sel->add($sock);
	my $fileno = fileno($sock);
	$socks{$fileno}{'TIME'} = time();
	$socks{$fileno}{'QUERY'} = $find;
	$socks{$fileno}{'TYPE'} = $type;

	return $fileno;
}

sub printresults {
	my $out_fh = shift;

	while ($#lines != -1) {
		my $line = $lines[0];

		if (!($line =~ /^$ipmask\s/)) {
			print $out_fh $line;
			shift @lines;
			next;
		}

		my ($ip) = $line =~ /^(\S+)/;
		my $resolved = getresolved($ip);
		last if $resolved eq '-1';
		$line =~ s/^(\S+)/$resolved/ if $resolved ne '-2';
		print $out_fh $line;
		shift @lines;
		removehost($ip);
	}
}

1;

__END__
