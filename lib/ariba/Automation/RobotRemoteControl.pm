package ariba::Automation::RobotRemoteControl;

# Call robot-control via SSH. This allows the robot interface to
# change over time if we switch from SSH/Expect to something else.
# Harrison Page <hpage@ariba.com>
# 25-Nov-2009

use strict 'vars';
use vars qw ($AUTOLOAD);
use Carp;
use Data::Dumper;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../lib/perl";
use lib "$FindBin::Bin/../../bin";
use lib "/home/rc/bin/admin/bin";
use ariba::rc::Utils;

{
# list of legal actions
my %legal = ("pause-at-action" => 1, "start" => 1, "pause" => 1, "resume" => 1, "stop" => 1, "respin" => 1);

# path to ssh (assumed to be the same on all robot servers)
my $ssh = "/usr/local/bin/ssh";

sub controlRobot 
  {
  # robot = name of robot i.e. robot20
  # host = remote host i.e. buildbox20
  # command = first argument to robot-control i.e. start, stop, etc.
  # passwd = password for robot@host
  # pauseAtAction = name of action to pause at. optional argument, defaults to ""
  # email = email address for notify-at-pause feature

  my ($robot, $host, $command, $passwd, $pauseAtAction, $email) = @_;

  $email = $email || "";
  if ($email && $email !~ m#\@ariba.com$#)
  {
    return (-1, "Invalid e-mail address");
  }

  # check for valid robot name
  if ($robot !~ m#^[-A-Z0-9\._]+$#i) 
    {
    return (-1, "Malformed robot name: $robot");
    }

  # check for valid host name
  if ($host !~ m#^[-A-Z0-9\._]+$#i) 
    {
    return (-1, "Malformed host name: $host");
    }
  
  # check for valid command
  if ($command !~ m#^[-A-Z0-9]+$#i) 
    {
    return (-1, "Malformed command: $command");
    }

  # check for valid pauseable action
  if (length ($pauseAtAction) && $pauseAtAction !~ m#^[-A-Z]+$#i) 
    {
    return (-1, "Malformed action: Robot won't pause");
    }

  # check for legal command
  if (! exists $legal{$command}) 
    {
    return (-1, "Unknown command: $command");
    }

  my $suffix = $command;
  if (length ($pauseAtAction))
    {
    $suffix .= " " . $pauseAtAction;
    }

  if ($email)
    {
    $suffix .= " " . $email;
    }

  # setup environment variables then call robot-control via SSH
  my $prog = join " && ",
    "source /robots/machine-global-cache-for-personal-service/bashrc",
    "nohup /robots/machine-global-cache-for-personal-service/usr/local/services/tools/bin/robot-control $suffix",
    "sleep 3", # connection closes too soon for fork to occur, sleeping briefly fixes this
    "date"; # probably not required but feeling paranoid

  my $cmd = qq!$ssh -n $host -l $robot "$prog"!;
  print "<p>$cmd</p>\n";
  ariba::rc::Utils::executeRemoteCommand ($cmd, $passwd);

  return (0, "n/a");
  }
}

1;
