#!/usr/local/bin/perl

package ariba::Ops::MCL::ErrorCheckers;

use ariba::Ops::Logger;
my $logger = ariba::Ops::Logger->logger();

use ariba::rc::InstalledProduct;
use ariba::Ops::OracleClient;
use ariba::Ops::DBConnection;
use ariba::Ops::DatabasePeers;
use ariba::rc::Globals;

sub checkDFForAutoSP {
	my $output = shift;
	my $ret = "";

	my %thresholds = (
		'^/$' => { 'pct' => 90, 'free' => 5000000 },
		'^/ora' => { 'pct' => 90, 'free' => 5000000 },
	);

	$logger->info("In checkDF");

	foreach my $line (@$output) {
		if($line =~ m|^(/dev[^\s]+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\%\s+(.*)$|) {
			my $device = $1;
			my $size = $2;
			my $used = $3;
			my $free = $4;
			my $pct = $5;
			my $mount = $6;

			foreach my $rule (keys %thresholds) {
				if($mount =~ $rule) {
					my $checkPct = $thresholds{$rule}->{'pct'} || 100;
					my $checkFree = $thresholds{$rule}->{'free'} || 0;
					if($pct >= $checkPct) {
						$ret .= "ERROR: $mount is $pct\% full (exceeds $checkPct\%)\n";
					}
					if($free <= $checkFree) {
						$ret .= "ERROR: $mount only has ${free}kb full (less than ${checkFree}kb)\n";
					}
				}
			}
		}
	}

	$ret = "OK" unless($ret);
	return("$ret");
}

1;
