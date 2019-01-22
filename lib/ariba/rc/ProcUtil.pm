#
#   Copyright (c) 1996-2011 Ariba, Inc.
#   All rights reserved. Patents pending.
#
#   $Id: //ariba/services/tools/lib/perl/ariba/rc/ProcUtil.pm#1 $
#
#   Responsible: nagendra
#
# This module provides process related functions such as   
# process tree for any given process id
# killing the whole process tree for any given process id
# 

package ariba::rc::ProcUtil;

@ISA=qw(Exporter);
@EXPORT=qw(killProcTree showProcTree);
%EXPORT_TAGS=();


sub FormProcessHash {
    my $cmd = "ps -ef \| awk \'\{print \$2 \" \" \$3\}\'";
	my @pids = `$cmd`;
	my %pidhash;
	foreach ( @pids)
	{
		#Form parent child hash 
		my ($pid,$ppid) = split;
		if ( exists $pidhash{$ppid} )
			{
			 push @{$pidhash{$ppid}}, $pid;
			} else {
			$pidhash{$ppid} = [$pid];
			}

	}

return %pidhash;	
}


sub FormProcDetailsHash{
	my $cmd = "ps -ef";
	my @pids = `$cmd`;
	my %prochash;
	foreach ( @pids)
	{
		my ($user,$pid,$ppid,$c,$stime,$tty,$time,@cmd) = split;
		$prochash{$pid} = "$pid\t$user\t$stime\t$time\t@cmd";
	}

return %prochash;	
}

	
# Now form tree for given ppid

sub FormProcessTree {
    
	my ($proc_id,$pid_hashref,$proc_treeref) = @_;
	my %pidhash = %$pid_hashref;
	push @{$proc_treeref}, $proc_id;
	
	if ( exists $pidhash{$proc_id} ) 
		{
		
		foreach my $id ( @{$pidhash{$proc_id}} ){
		FormProcessTree($id,$pid_hashref,$proc_treeref);
		}
	}
	
	return;
}

sub getProcTree
{
	my ($pid) = @_;
	$pid =~ s/^\s+//; 
	$pid =~ s/\s+$//; 
	my %pidhash = FormProcessHash();
	my @proc_tree;
	FormProcessTree($pid,\%pidhash,\@proc_tree);
	return @proc_tree;
}

sub PrintProcessHash {
my ($pid_hashref) = @_;
my %pidhash = %$pid_hashref;
 while ( my ($k,$v) = each %pidhash ) 
	{ 
	print "$k => @$v <br>"; 
	}

}
sub killProcTree
{
    my ($pid) = @_;
	$pid =~ s/^\s+//; 
	$pid =~ s/\s+$//; 
	my @proc_tree = getProcTree($pid);
	my $status = kill 9,@proc_tree;
	return $status;

}

sub showProcNames
{
	my ($pid) = @_;
	my @proc_tree = getProcTree($pid);
	my %prochash = FormProcDetailsHash();
	my @procNames;
	foreach $id (@proc_tree)
	{
	push @procNames, $prochash{$id};
	}

	return @procNames;

}

1;

