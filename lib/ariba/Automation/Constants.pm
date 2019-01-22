package ariba::Automation::Constants;

use constant ACTION_SECTION => 'action';
use constant IDENTITY_SECTION => 'identity';
use constant GLOBAL_SECTION => 'global';

#
# It could be argued that these belong somewhere else;
# put them here for now to keep all variables in 
# once place for ease of reference
#

my $BASE_ROOT_DIR = $ENV{'HOME'};

sub setBaseRootDirectory {
	my $class = shift;

	$BASE_ROOT_DIR = shift();
}

sub baseRootDirectory {
	return $BASE_ROOT_DIR;
}

# stateDirectory() - where to put state/persistantObject files
sub stateDirectory { return "$BASE_ROOT_DIR/state"; }

sub communicatorDirectory { return "$BASE_ROOT_DIR/communicator"; }


sub testReportDirectory { return "public_doc/testReports"; }

sub logDirectory { return "public_doc/logs"; }

sub configDirectory { return "config"; }

sub linkBaseUrl { return "http://nashome.ariba.com/"; }

sub serverRootDir { return "/home/rc/robots"; }

sub serverHostname { return "rc.ariba.com"; }

sub serverPort { return 8080; }

sub serverFrontdoor { return "http://" . serverHostname() . ":" . serverPort(); }

sub serverRobotKingUri { return "/cgi-bin/robot-status"; }

sub serverRobotStatusUri { return "/cgi-bin/robot-server"; }

sub sleepTimeForNewRCBuildInMinutes { return 5 };

sub daysToExpireLogs { return 14 };

sub statusChangeLogDirectory { return "/home/rc/robots/status" };

sub latestLogfileLinkName { return "latest.log" };

sub previousLogfileLinkName { return "previous.log" };

sub crontabFile { return "/home/rc/robotswww/crontab.txt"; }

sub releasesConfigFile { return "/home/rc/etc/releases.xml"; }
sub releasesConfigFile2 { return "/home/rc/etc/releases2.xml"; }

sub buildNowFile { return "/tmp/build-now-flag"; }

sub apacheLogDir { return "/var/tmp/apache"; }

sub stableRobotVersionUrl { return serverFrontdoor() . "/robot.version"; }

sub robotTemplatesUrl { return serverFrontdoor() . "/resource/templates"; }

sub bootstrapCommand { return "/home/rc/bin/bootstrap-personal-service"; } 

1;
