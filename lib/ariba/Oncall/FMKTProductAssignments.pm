package ariba::Oncall::FMKTProductAssignments;

# $Id: //ariba/services/monitor/lib/ariba/Oncall/FMKTProductAssignments.pm#2 $
#
# This is code to allow us to have a "oncall schedule" style
# list of who supports which Legacy FMKT products, replacing
# manually maintained spreadsheet.   Once we turn off the FMKT
# products except for QS or hand them off to IT, this code
# should go away.
#
# data file format:
# productName	primary prodops, backup prodops, dba
#
#
# This is based on ariba::Oncall::Schedule, so that's why 
# the product->people mapping is called a "schedule" in the API
#
#

use strict;
use ariba::Ops::Constants;

my @methods = qw(fileName sched);

my $scheduleCache;

# create autoloaded methods
for my $datum (@methods) {
	no strict 'refs';
	*$datum = sub { return shift->{$datum} }
}

sub _keyForProductName {
        my $self = shift;
        my $key = shift;
        my $productName = shift;

        return ${$self->sched()}{$productName}{$key};
}

sub primaryForProductName {
	my $self = shift;
	my $day = shift;

	return $self->_keyForProductName("primary", $day);
}

sub backupForProductName {
	my $self = shift;
	my $day = shift;

	return $self->_keyForProductName("backup", $day);
}

sub dbaForProductName {
	my $self = shift;
	my $day = shift;

	return $self->_keyForProductName("dba", $day);
}

sub commentForProductName {
	my $self = shift;
	my $day = shift;

	return $self->_keyForProductName("comment", $day);
}

sub productNames {
	my $self = shift;

	return sort keys %{$self->sched()};
}

sub new {
	my $class = shift;

	if ( $scheduleCache ) {

		return $scheduleCache;

	} else {

		my $self = {
			'fileName'	=> undef,
			'sched'		=> {},
		};
		bless($self, $class);

		my $scheduleDir = ariba::Ops::Constants->oncallscheduledir();

		$self->{'fileName'} = $scheduleDir . '/misc/'. "fmkt-app-ownership";
		
		open(SCHED,$self->fileName()) || do {
				warn "can't open ".$self->fileName()." $!\n";
				return undef;
		};

		my %sched;

		while ( <SCHED> ) {
			next if /^#/o;
			next if /^;/o;
			chomp;
			next if /^\s*$/o;
			next unless /^\w+/o;

			# productName grio, dsully, sams # AN move to Mtn. View
			/^([^\s]+):?(\s*(\w+))?(\s*,?\s*(\w*))?(\s*,?\s*(\w*))?(\s*#\s*(.+))?/o;
			my ($productName,$primary,$backup,$dba,$comment)=($1,$3,$5,$7,$9);

			$sched{$productName} = {
				'primary' => $primary,
				'backup'  => $backup,
				'dba' => $dba,
				'comment' => $comment,
			};
		}
		close(SCHED);

		$self->{'sched'} = \%sched;

		$scheduleCache = $self;

		return $self;
	}
}

sub _removeSchedulesFromCache {
	my $class = shift;
	
	$scheduleCache = undef;	
	return 1;
}

1;
