package ariba::Ops::ProcessTable;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/ProcessTable.pm#11 $

use strict;
use Proc::ProcessTable;

# Only for Solaris
my $pmem  = '/usr/proc/bin/pmem';

=head1 NAME

ariba::Ops::ProcessTable - abstract out process table queries.

=head1 SYNOPSIS

use ariba::Ops::ProcessTable;

my $processTable = ariba::Ops::ProcessTable->new();

$processTable->killProcessesWithName('sharity')) {

=head1 DESCRIPTION

Provides an abstract interface to the system's process table.

=head1 CLASS METHODS

=over

=item * new()

Creates a new ariba::Ops::ProcessTable instance.

=back

=cut

sub new {
	my $class = shift;

	my $self  = {
		'proc' => Proc::ProcessTable->new('enable_ttys' => 0),
	};

	bless $self, $class;

	$self->refresh();

	return $self;
}

=head1 INSTANCE METHODS

=over

=item * refresh()

Refreshes the internal copy of the process table - good for long running programs.

=cut

sub refresh {
	my $self = shift;

	my $proc = $self->{'proc'};

	my %table = map { $_->pid(), $_ } @{$proc->table()};

	$self->{'table'} = \%table;
}

=item * dataForProcessID( $pid )

Returns a hash reference with information about the process id, including cpu, and memory.

=cut

sub dataForProcessID {
	my $self = shift;
	my $pid  = shift;

	my $process  = $self->{'table'}->{$pid} || return {};

	my %procData = (
		'pctcpu' => $process->pctcpu(),
		'time'   => $process->time(),
		'rss'    => $process->rss(),
		'size'   => $process->size(),
		'ppid'   => $process->ppid(),
		'pid'    => $process->pid(),
		'cmnd'   => $process->cmndline(),
	);

	if ($^O eq 'solaris') {

		# get the private memory size from pmem
		# look for: total Kb   32312   26904    8000   18904
		# last column is 'private' memory size.
		open(PMEM, "$pmem $pid |") || die "instance-watcher can't open [$pmem $pid|]: $!";
		while (<PMEM>) {
			next unless /^total Kb/o;
			chomp;
			$procData{'privateMemSize'} = (split /\s+/)[5] || 0;
		}
		close(PMEM);

	} elsif ($^O eq 'linux') {

		#
		# linux process table returns size in bytes, we need
		# kb. convert it 
		#
		$procData{'privateMemSize'} = ($process->rss()/1024);


		# XXX Temporary hack
		# Can be removed when TMID 45513 will get closed
		open(PROCINFOS, "< /proc/$pid/stat") || return {};
		my @lines = <PROCINFOS>;
		my $lines = join(' ', @lines);
		my @fields = split(/\s+/, $lines);
		my ($utime, $stime, $cutime, $cstime) = @fields[13..16];

		$procData{time} =  ($utime + $stime) * 10000.0;


	}

	return \%procData;
}

=item * processWithPIDExists( $pid )

Returns true if a process with the pid exists.

=cut

sub processWithPIDExists {
	my $self = shift;
	my $pid  = shift;

	return 1 if defined $self->{'table'}->{$pid};
	return 0;
}

=item * processWithNameExists( $regex )

Returns true if a process with the name or regex exists.

=cut

sub processWithNameExists {
	my $self = shift;
	my $name = shift;
    my %args;
    {   my @args = @_;
        if(scalar @args % 2) {
            die "ariba::Ops::ProcessTable::processWithNameExists: even number of arguments required after \$name\n";
        }
        %args = @args;
    }

	my @running = map { $_->cmndline() || $_->fname() } values %{$self->{'table'}};

    if($args{insensitive}) {
        return 1 if (grep { /$name/i } @running);
    } else {
        return 1 if (grep { /$name/ } @running);
    }

	return 1 if (grep { /$name/ } @running);
	return 0;
}

=item * processNamesMatching( $regex ) 

Returns an array of process names matching the given regex.

=cut

sub processNamesMatching { 
	my $self = shift; 
	my $regex = shift; 

	my @processNames = grep(/$regex/o, map { $_->cmndline() || $_->fname() } values %{$self->{'table'}}); 
	 
	return @processNames; 
}

=item * pidsForProcessName( $regex )

Returns an array of pids that match the passed in name/regex.

=cut

sub pidsForProcessName {
	my $self = shift;
	my $name = shift;

	my @pids = ();

	my %processes = map { $_->pid(), $_->cmndline() || $_->fname() } values %{$self->{'table'}};

	while (my ($pid, $command) = each %processes) {

		push(@pids, $pid) if $command =~ /$name/;
	}

	return @pids;
}

=item * pidForProcessName( $regex )

Returns a signle pid that matches the passed in name/regex.

=cut

sub pidForProcessName {
	my $self = shift;
	my $name = shift;

	return ($self->pidsForProcessName($name))[0];
}

=item * killProcessesWithName( $regex, $signal )

Like killall(1) / pkill(1) - kills all processes matching $regex with $signal.

Returns the number of killed processes.

Sets $! if there was an error killing a process.

=cut

sub killProcessesWithName {
	my $self   = shift;
	my $name   = shift;
	my $signal = shift || 'TERM';

	my $count  = 0;
	my $bang;

	for my $pid ($self->pidsForProcessName($name)) {

		# Don't try and kill ourselves.
		next if $pid == $$;

		if (kill $signal, $pid) {
			$count++;
		} else {
			$bang = $!;
		}
	}

        $! = $bang if defined $bang;

        return $count;
}

=item * childrenForPid( $parentPid )

Returns an array of children for a given PID

=cut

sub childrenForPid {
	my $self = shift;
	my $pid = shift;

	my @children;
	for my $process ( keys %{ $self->{'table'} } ) {
		push(@children, $process)
			if $self->{'table'}->{$process}->ppid() == $pid;
	}

	return @children;
}

=item * processTree( $parentPid )

Returns an array of the descendant PIDs to the given PID.  The array is 
depth first, so killing procs from the bottom up will kill the children 
first.

=cut
sub processTree  {
	my $self = shift;
	my $ancestor = shift;
	my $tree = shift;

	for my $child ($self->childrenForPid($ancestor)) {
		push(@$tree, $child);
		$self->processTree($child, $tree);
	}
	
	# avoid error: Can't use an undefined value as an ARRAY reference
	if ($tree) {
		return @$tree;
	}
	return ();
}

=item * sendSignal( $processID,$signal )

send the signal to the process and return non zero on success else zero

=cut
sub sendSignal  {

    my $self = shift;
    my $pid=shift;
    my $signal = shift || 'QUIT' ;

    return ( kill( $signal, $pid ) );
}

=back

=head1 AUTHOR

Dan Sully, E<lt>dsully@ariba.comE<gt>

=cut

1;
