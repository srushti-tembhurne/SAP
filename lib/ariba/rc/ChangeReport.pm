package ariba::rc::ChangeReport;

use strict;
use warnings;
use Carp;
use ariba::rc::BuildDef;
use ariba::Automation::Utils;
use Ariba::P4;
use Ariba::P4::User;

#
# Static method pretty-prints changelog in HTML form suitable
# for e-mail
#
    
my $MAX_CHANGES = 1000;

sub generateHtmlReport
{
	my ($productName, $branch, $lastChange, $currentChange) = @_;

	my ($message, $submitters) = ("", "");
    my $configDir = ariba::rc::BuildDef::prodConfigDir ($productName, $branch);
    my $ctxt = "$configDir/components.txt";
    my @monitor = ($ctxt, $branch);

    my @changes = ariba::Automation::Utils::getChanges ($lastChange, $currentChange, \@monitor);
	if (! @changes)
	{
		carp "There are no changes from the last good run or the robot couldn't generate the list of changes.";
		return ($message, $submitters);
	}

    $message = "List of changes from the last good run ($lastChange) till this run (" . $currentChange . "):\n";

    if (scalar(@changes) > $MAX_CHANGES ) 
	{
        $message .= "List of changes is too large, reducing to first $MAX_CHANGES\n";
        @changes = @changes[0..$MAX_CHANGES-1];
    }

    $message .= getHtmlChangeListSummary (@changes);

    my @emails = getEmails (@changes);
    if (@emails > 0) 
	{
        $submitters .= join ',', @emails;
    }

    return ($message, $submitters);
}

sub getHtmlChangeListSummary
{
    my (@changes) = @_;
    my @rcchanges=();
	my @aclchanges=();
    my $body = "";

    if (@changes > 0)
    {
        $body = <<FIN;
<table style="font-family: sans-serif" border=1 cellpadding=1 cellspacing=1 width="100%">
<tr bgcolor="#efefef">
<td width="10%" align=center valign=middle><b>User</b></td>
<td width="10%" align=center valign=middle><b>Change</b></td>
<td width="80%" align=left valign=middle><b>Title</b></td>
</tr>
FIN

        foreach my $change (@changes)
        {
            my $info = Ariba::P4::getChangelistInfo($change);
            my $desc = $$info{Description};
            $desc =~ s/^\s*//;
            $desc =~ s/^\n*//;
            $desc =~ /(.*)\n/;
            my $title = $1;
            my $user = $$info{User};
            if(($user ne "rc")&&($desc !~ /P4ACL/)){
            $body .= <<FIN;
<tr bgcolor="#FFEB99">
<td width="10%" align=center valign=middle>$user</td>
<td width="10%" align=center valign=middle><a href="https://rc.ariba.com/cgi-bin/change-info?change=$change">$change</a></td>
<td width="80%" align=left valign=middle>$title</td>
</tr>
FIN
}
            elsif ($user eq "rc") {
                push (@rcchanges,"$change");
            }
			elsif ($desc =~ /P4ACL/){
			    push (@aclchanges,"$change");
			}
			else {next;}
        }
       $body .= "</table>";
	   $body .= "Following changes can be ignored as these are done by rc user:<br>@rcchanges" if (@rcchanges);
	   $body .= "\nFollowing changes can be ignored as these are done by P4ACL:<br>@aclchanges" if (@aclchanges);
       $body .= "There is no change by rc user" if (!@rcchanges);
    }
    return $body;
}

# Given a list of Changelists, return a array containing the list
# of user@ariba.com that did check in
sub getEmails (@) 
{
    my (@changes) = @_;
    my @emails = ();
    my %temp;
    if (@changes > 0) 
	{
        foreach my $change (@changes) 
		{
            my $info = Ariba::P4::getChangelistInfo($change);
            my $user = Ariba::P4::User->getUser($$info{User});
            if (! $user) 
			{
                next; # fail silently if getUser can't get user info
            }
            my $email = $user->getEmail();
            $temp{$email}++;
        }
        # to avoid having duplicates
        push(@emails, keys %temp);
    }
    return @emails;
}

1;
