# $Id: //ariba/services/tools/lib/perl/ariba/Ops/LogParser/SendmailLogParser.pm#3 $
package ariba::Ops::LogParser::SendmailLogParser;

use strict;
use base qw(ariba::Ops::LogParser::BaseParser);

sub instanceName {
	my $class = shift;
	return "sendmail";
}

## Instance methods
sub logFile {
	my $self = shift;
	return "/var/log/maillog";
}

sub parseLine {
	my $self = shift;
	my $line = shift;
	my $time = shift;

	# Jun 17 16:08:18 phoenix sendmail[6308]: o5HN8IGV006308: ruleset=check_rcpt, arg1=<nobody@ansmtp.ariba.com>, relay=idcbuildbox103.ariba.com [10.57.86.36], discard
	#
	my ($date, $host, $client, $msg) = $line =~ /^(...\s+\d+\s\d\d:\d\d:\d\d)\s(\w+)\s+(\S+):\s+(.+)$/;
	return unless ($client && $client =~ /sendmail/);

	my $uTimeOfEvent = $self->dateToUTC($date);

	# Only process event that happens less than $SCANPERIOD ago
	return if ( $time - $self->scanPeriod() > $uTimeOfEvent );

	$msg = "$date $msg";

	if ($msg =~ /EX_TEMPFAIL/o) {
		$msg = "INFO: $msg";
		if ($self->infos()) {
			$self->appendToAttribute('infos', $msg);
		} else {
			$self->setInfos($msg);
		}
	}

        if ($msg =~ /rejecting connections on daemon MTA/o || $msg =~ /You may not perform this action from the machine you are on/o) {
                $msg = "ERROR: $msg";
                if ($self->errors()) {
                        $self->appendToAttribute('errors', $msg);
                } else {
                        $self->setErrors($msg);
                }
        }

	if ($msg =~ /savemail panic/o) {
		$msg = "WARNING: $msg";
		if ($self->warnings()) {
			$self->appendToAttribute('warnings', $msg);
		} else {
			$self->setWarnings($msg);
		}
	}

	return 1;

}

1;
