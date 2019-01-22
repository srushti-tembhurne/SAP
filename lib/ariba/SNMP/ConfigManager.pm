#
# $Id: //ariba/services/tools/lib/perl/ariba/SNMP/ConfigManager.pm#4 $
#
# This package manages a config file that desribes what oids to sample
# for a given machine type.
#
# --------------------------------------------------------------------
# Format is :
# --------------------------------------------------------------------
# Name: <Name of the QueryManager object>
# Frequency: <inteval in secs to sample oids in this file
#
# [<machine query1> <machine query2>]
#    {oids}
#        foo.bar.3
#        100 - foo.bar.3[, <Sample Name>]
#    {walkOids}
#        a.b.0 + 20[, <Sample Name>]
#
# [<machine query3>]
#   ...
# --------------------------------------------------------------------
#
# oidsForMachine() call returns an associative list of oids to sample
# for that machine.
#
# The key of the hash is the pretty name for the oid, and the value is
# the actual oid to sample.
#
#

package ariba::SNMP::ConfigManager;

use FileHandle;
use ariba::Ops::Machine;
use ariba::SNMP::Config;
use ariba::SNMP::Session;

my $debug = 0;

sub _loadConfig {
	my $self = shift;

	my $cfgFile = $self->{'_cfgFile'};
	my @configs = ();

	return 0 unless -f $cfgFile;

	my $fh = FileHandle->new($cfgFile) || return 0;

	my $oidType;

	while (<$fh>) {

		next if (/^\s*#/o || /^\s*;/o);
		chomp;
		s/\cM$//o;
		s/\s*$//o;
		s/^\s*//o;

		next if $_ eq "";

		if (/^Name\s*:\s*(.*)$/io) {

			$self->{'_name'} = $1;
			next;

		} elsif (/^Frequency\s*:\s*(.*)$/io) {

			$self->{'_frequency'} = $1;
			next;

		} elsif (/^SNMPPort\s*:\s*(\d+)$/io) {

			$self->{'_snmpport'} = $1;
			next;
		}

		if (/^\[(.*)\]$/o) {

			my $matchString = $1;
			my @matchArray  = split(/\s+/, $matchString);
			my @matches     = ();

			for my $match (@matchArray) {

				my ($field, $value) = split(/[=:]/, $match, 2);
				push(@matches, $field, $value);
			}

			my $confObj = ariba::SNMP::Config->new($matchString);

			unshift(@configs, $confObj);

			$confObj->setMatches(@matches);

			next;

		} elsif (/^\{(.*)\}/o) {

			$oidType = $1;

			next;

		} else {

			# Achor comma match to the end of the string.  This protects
			# comma's required for the evetual eval on the LHS of the string
			my ($oidString, $name) = $_ =~ m/\s*(.+)\s*,\s*([^,]+)\s*/;

			$name = $oidString unless $name;

			my $confObj = $configs[0];

			$confObj->appendToAttribute($oidType, $oidString);
			$confObj->appendToAttribute("${oidType}Names", $name);
		}
	}

	$fh->close();

	$self->{'_configs'} = [@configs];
}

sub oidsForMachine {
	my $self    = shift;
	my $machine = shift;

	my $configs  = $self->{'_configs'};
	my $hostname = $machine->hostname();

	my %oids = ();

	print "Working on $hostname\n" if $debug;

	# create a snmp session
	my $snmp = ariba::SNMP::Session->newFromMachine($machine);

	$snmp->setEnums(0);
	$snmp->setRetry(2);
	$snmp->setPort($self->snmpPort());

	for my $confObj (@$configs) {

		my %properties = $confObj->matches();

		next unless $machine->hasProperties(%properties);

		my @getOids      = $confObj->oids();
		my @getOidsNames = $confObj->oidsNames();

		my $i;
		for ($i = 0 ; $i < scalar(@getOids); $i++) {

			next unless $getOids[$i];

			# clean oid expression, replacing any pseudo-oids
			$getOids[$i] = _cleanupOidExpr($getOids[$i], $machine);

			if ( defined($snmp->valueForOidExpr($getOids[$i])) ) {

				my $name = $snmp->valueForOidExpr($getOidsNames[$i]);

				$name =~ s|/|:|g;
				$oids{$name} = $getOids[$i];

				print "  get $name -> $getOids[$i]\n" if $debug;

			} else {
				print "  *** get $name -> $getOids[$i] did not work\n" if $debug;
			}
		}

		my @walkOids      = $confObj->walkOids();
		my @walkOidsNames = $confObj->walkOidsNames();

		for ($i = 0; $i < scalar(@walkOids); $i++) {

			next unless $walkOids[$i];

			print "  walk $walkOids[$i]\n" if $debug;

			my %walkedOids = $snmp->walkOidExpr($walkOids[$i], $walkOidsNames[$i]);

			for my $oidName (keys(%walkedOids)) {

				$oids{$oidName} = $walkedOids{$oidName};

				print "    $oidName -> $walkedOids{$oidName}\n" if $debug;
			}
		}
	}

    $snmp->close();

	return %oids;
}

# given an oid expression and a machine object,
# replaces any non-oid words within the expression with the
# machine object values.
sub _cleanupOidExpr {
	my $oidExpr = shift;
	my $machine = shift;

	# pull out each oid-like word in the oid expression
	while ($oidExpr =~ /([a-zA-Z][a-zA-Z.0-9]*)/g) {
		my $oid = $1;

		# if it ends with dot-digit (e.g. ".0" or ".12") skip it, it's
		# a real oid
		next if ($oid =~ m/\.\d+$/);

		my $value = $machine->attribute($oid);

		if (defined($value)) {
			$oidExpr =~ s/$oid/$value/;
		}
	}

	return $oidExpr;
}

sub name {
	my $self = shift;

	return $self->{'_name'};
}

sub frequency {
	my $self = shift;

	return $self->{'_frequency'};
}

sub snmpPort {
	my $self = shift;

	return $self->{'_snmpport'} || 161;
}

sub queryManagerName {
	my $self = shift;

	return $self->{'_queryManagerName'};
}

sub setQueryManagerName {
	my $self = shift;
	my $name = shift;

	$self->{'_queryManagerName'} = $name;
}

sub new {
	my $class   = shift;
	my $cfgFile = shift;

	my $self = {};

	bless($self, $class);

	$self->{'_cfgFile'} = $cfgFile;

	$self->_loadConfig();

	return $self;
}

sub main {
	my $cfgFile = $ARGV[0];
	my $host    = $ARGV[1];

	my $cm = ariba::SNMP::ConfigManager->new($cfgFile);

	my $mc = ariba::Ops::Machine->new($host);

	my %oids = $cm->oidsForMachine($mc);

	print $cm->name(), " to run every ", $cm->frequency(), " mins on snmpport ", $cm->snmpPort(), "\n";
	print "============ OIDS for $host ==========\n";

	for my $oid (sort(keys(%oids))) {

		my $type = ariba::SNMP::Session->oidType($oids{$oid});
		print "name = $oid, oid = $oids{$oid} ($type)\n";
	}
}

# main();

1;

__END__
