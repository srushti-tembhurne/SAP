#
# $Id: //ariba/services/tools/lib/perl/ariba/util/Crontab.pm#40 $
#
# A module to manage various cronjobs automatically, using unix crontab
#
package ariba::util::Crontab;

use strict;
use File::Basename;

use ariba::util::Cronjob;
use dmail::LockLib;
use ariba::Ops::ProcessTable;

my $crontab;

my $CMDS_TO_KILL = 'commands-to-kill';

sub new
{
    my $class = shift;
    my $user  = shift || ($ENV{'USER'} || $ENV{'LOGNAME'});
    my $mode  = shift || 'install';

    my %crontab = ();

    # it has been discovered that heretofor-available env vars (such as USER and LOGNAME)
    # are NOT available when scripts run via salt-minion. Therefore, we need to try even
    # harder to assign a default user.
    my $myuid = $>;
    $user ||= getpwuid($myuid);

    if (defined $crontab{$user}) {
		return $crontab{$user};
    }

    my $cron = {};
    bless ($cron,$class);

    $crontab{$user} = $cron;

    $cron->{'cronCommand'} = 'crontab';
    $cron->{'mode'} = $mode;

	$cron->{'user'} = $user;
    if (getpwuid($myuid) ne $user) {
		$cron->{'cronCommand'} = "sudo -u $user crontab";
    }

    if ($cron->{'mode'} !~ /^remove/) {
    	$cron->readExistingCrontab();
    }

    return $cron;
}

sub cronCommand
{
    my ($self) = shift;

    return $self->{'cronCommand'};
}

sub user
{
    my ($self) = shift;

    return $self->{"user"};
}

sub numJobs
{
    my ($self) = shift;

    return $self->{"numJobs"};
}

sub jobNames
{
    my ($self) = shift;

    my @jobNames = sort keys(%{$self->{"jobs"}});

    return @jobNames;
}

sub jobWithNameExists
{
    my ($self, $name) = @_;

    if (defined $self->{"jobs"} && defined $self->{"jobs"}{$name}){
	return 1;
    }

    return 0;
}

sub jobWithName
{
    my ($self, $name) = @_;

    if (!defined $self->{"jobs"}){
	return undef;
    }

    return $self->{"jobs"}{$name};
}

sub removeJobWithName
{
    my ($self, $name) = @_;

    if (!defined $self->{"jobs"} || !defined $self->{"jobs"}{$name}){
	return 0;
    }

    #
    # If the mode is remove-and-kill, kill the command
    # that might be running
    #
	if ($self->{'mode'} =~ /remove-and-kill/) {
		my $job = $self->{"jobs"}{$name};
		my @commandAndArgs= split(/\s+/, $job->command());
		my $cmd;

		if (@commandAndArgs) {
			$cmd = $commandAndArgs[0];
			# if it's run by crontab-wrapper, we need to kill based on the second field
			# which will be the actual command
			$cmd = $commandAndArgs[1] if $cmd =~ m/crontab-wrapper/;
		}
		push( @{$self->{$CMDS_TO_KILL}}, $cmd);
	}

    undef $self->{"jobs"}{$name} ;
    delete $self->{"jobs"}{$name} ;

    $self->{"numJobs"}--;
}

sub addJobWithName
{
    my ($self, $name, $job) = @_;
    $self->removeJobWithName($name);

    if ( ! $self->jobWithNameExists($name) ){
	    $self->{"numJobs"}++;
    }

    $self->{"jobs"}{$name} = $job;
}

sub addJob
{
    my ($self, $job) = @_;

    my $name = $job->name();
    $self->addJobWithName($name, $job);
}

=head2 sub addEntryToCron (name, command, comment, schedule, [invoker], [wrapper_args])

Where the arguments are defined as:

=over

=item name

The name to be used by the Autocron system, in a comment/header line, in the crontab file.

=item command

The command to run, including all arguments required.

=item comment

A descriptive comment, placed after the B<name> header, just above the actual crontab line.

=item schedule

The schedule to use, see crontab(5) for details.

=item invoker

A "secondary" command, which will invoke the actual command.  Note that this system already supplies a script wrapper,
B<crontab-wrapper>, which will run the script.  If an invoker is used, the command will be structured with the invoker
first, crontab-wrapper second and the actual script third.  This argument is B<optional>.

=item wrapper_args

Arguments and options to pass to the crontab-wrapper script.  If present, there must be an invoker argument placeholder or command.
The only currently supported option is B<-a>, followed by an arbitrary string.  This string will be used as a suffix to the
file name string, to provide unique spew file names.  This allows running 2 or more copies of a script and collecting
any spew output for each independently.  Otherwise, the same name is used for all cases, and the last invocation
will be the only spew data available.  This argument is B<optional>.  If the suffix string should be separated from the
main name by a dash or dot, it must be supplied as part of the argument.  No assumptions are made regarding the string.

=back

=cut

sub addEntryToCron
{
    my ($self, $name, $command, $comment, $schedule, $invoker, $wrapperArgs) = @_;

    my $cronjob = ariba::util::Cronjob->new();

    my $wrapper = "/usr/local/ariba/bin/crontab-wrapper";

    if ($invoker && -x $invoker) {
		$command = "$invoker $wrapper $command";
    }
    elsif ( -x $wrapper ) {
        # These are arguments to the crontab-wrapper script.  Add to the above if defined.
        if ($wrapperArgs)
        {
            $wrapper .= " $wrapperArgs";
        }
		$command = "$wrapper $command";
	}

    $cronjob->setName($name);
    $cronjob->setCommand($command);
    $cronjob->setComment($comment);
    $cronjob->setSchedule([ split(/\s+/o, $schedule) ]);

    $self->addJob($cronjob);
}

sub commit
{
    my ($self) = shift;

    #
    # Check the disk space on local host
    # if it is equal or greater than 99%, return an error and don't install crontab
    #
    my $diskusage = `df -P / | tail -1 | awk '{print \$5}' | cut -c1-3`;
    $diskusage =~ s/%$//g;

    if ($diskusage >= 99) {
        print STDERR "ERROR: current host disk usage >= 99%. Skipping crontab install\n"; 
        return 0;
    }

    my ($file, $time);
    $file = "/tmp/cron$$";
    $time = localtime(time);

	if ($self->{'mode'} =~ /^remove/) {
		$self->readExistingCrontab();
                my @jobNames = $self->jobNames();
		map { $self->removeJobWithName($_) } @jobNames;
	}

    open(CRON, ">$file") || return 0;

    print CRON $self->{"pre-auto-cron"};
    print CRON "# BEGIN AUTOCRON ENTRIES (last updated by $0 at $time)\n";

    my @jobNames = $self->jobNames();
    for my $jobName (@jobNames) {

	my $job = $self->jobWithName($jobName);

	next if (!defined ($job) || ! $job->command());
	my $schedule = $job->schedule();
	my ($min,$hr,$day,$month,$weekday) = @$schedule;

	print CRON "# Autocron Job: [$jobName]\n";
	if (defined ($job->comment())) {
           print CRON "# ", $job->comment(), "\n";
	} else {
           print CRON "#\n";
	}
	print CRON "$min $hr $day $month $weekday ";
	print CRON $job->command(), "\n";
	print CRON "#\n";
    }

    print CRON "# END AUTOCRON ENTRIES\n";
    print CRON $self->{"post-auto-cron"};

    close(CRON);

    # remove the old crontab and install the new one
    my $cmd = $self->cronCommand();

    # The "cmd" here refers to 'crontab'.  It will print warnings and errors, but is
    # otherwise silent, when run with a file argument.  So ...
    my $errorFlag;
	open(CMD, "$cmd $file 2>&1 |") || return 0;
	while(<CMD>) {
        # The following will only happen for warnings, and errors will fall through,
		next if (/warning: commands will be executed using/);
        # so setting a flag here will serve to inform the test below that errors happened.
		print STDERR "ERROR: $_";
        $errorFlag = 1;
	}

    # Don't delete the file if there are errors, flagged above. We need to retain the original
    # processing logic, even though I don't think it makes much sense, to be sure nothing breaks
    # elsewhere.
    if ($errorFlag)
    {
        # It has been discovered that there are many existing error cases that were not known
        # because the files were being removed willy nilly. When this new code was added, it
        # caused problems, probably because of the 128K PID recycling. In any case, the file
        # will be renamed after closing, so it is unique.
        #
        # So this will simply try to close the CMD handle without touching the file or checking
        # for 'close' errors...
        close (CMD);

        # ...and rename it. It needs an underscore added at the beginning of the file name part.
        my $newName = '/tmp/_' . basename $file;
        rename $file, $newName;

        # And I'm assuming this will need to return failure rather than falling through. Though
        # it is not clear from the code just how that would happen, perhaps there's something
        # special with the 'crontab' command when it generate errors that causes the close to fail?
        return 0;
    }

	close(CMD) || do {
		unlink($file);
		return 0;
	};

    unlink($file);

	if ($self->{'mode'} =~ /^remove-and-kill/) {
		$self->killRemovedProcesses();
	}

    return 1;
}

sub killRemovedProcesses {
	my $self = shift;

	my $pt = ariba::Ops::ProcessTable->new();

	for my $cmd (@{$self->{$CMDS_TO_KILL}}) {
		if ($pt && $cmd) {
			unless ($pt->killProcessesWithName($cmd)) {
				$pt->killProcessesWithName($cmd, 'KILL');
			}
		}
	}
}

sub DESTROY 
{
    my $self = shift;

    # make sure we always remove any locks we've left around

    my $lockResource = $self->_lockResource();

    dmail::LockLib::releaselock($lockResource);

}

sub _setLockResource {
    my ($self) = shift;
    my $lockResource = shift;

    $self->{'lockResource'} = $lockResource;
}

sub _lockResource {
    my ($self) = shift;

    return $self->{'lockResource'};
}


sub readExistingCrontab
{
    my ($self) = shift;
    my ($state, $numJobs);

    $self->{"pre-auto-cron"} = "";
    $self->{"post-auto-cron"} = "";

    $state = "pre-auto-cron";
    $numJobs = 0;

    my $cronCommand = $self->cronCommand();
    my $user = $self->user() || "";

    my $lockResource = "/tmp/crontab-$user";

    $self->_setLockResource($lockResource);

    if (!dmail::LockLib::requestlock($lockResource, 20)) {
	die "ariba::util::Crontab could not acquire lock\n";
    }

    open(CRON, "$cronCommand -l 2> /dev/null |") || return $numJobs;

    my ($command, $comment, $jobName);
    while (<CRON>) {

	# A hack to trim out the header that vixie cron auto enters
	#
	if (/^# DO NOT EDIT THIS FILE - edit the master and reinstall/o) {
	    <CRON>;
	    <CRON>;
	    next;
	}
	if (/^\s*#*\s*BEGIN AUTOCRON ENTRIES/o) {
	    $state = "auto-cron";
	    next;
	}

	if (/^\s*#*\s*END AUTOCRON ENTRIES/o) {
	    $state = "post-auto-cron";
	    next;
	}

	if ($state eq "pre-auto-cron" || $state eq "post-auto-cron") {
	    $self->{$state} .= $_;
	} else {
	    chomp;
	    #
	    # skip blank and blank comment lines
	    #
	    next if (/^\s*$/o || /^\s*#\s*$/o) ;

	    #	Each cron entry if of 4 line format like:
	    #	#Autocron Job: [tag]
	    #	#comment
	    #	job info
	    #	<blank line>

	    if (/^\s*#+\s*Autocron Job\s*:\s*\[(.*)\].*/o ) {
		$jobName = $1;
		next;
	    }

	    if (/^\s*#+\s*(.*)/o) {
		$comment = $1;
		next;
	    }

	    my (@info) = split(/\s+/, $_, 6);
	    $command = pop(@info);

	    if (defined $jobName) {
		my $cronjob = ariba::util::Cronjob->new();

		$cronjob->setCommand($command);
		$cronjob->setComment($comment);
		$cronjob->setSchedule(\@info);
		$cronjob->setName($jobName);

		$self->addJob($cronjob);

		undef $jobName;
		undef $comment;
	    }
	}
    }

    close(CRON);

    return $numJobs;
}

1;
