package ariba::Automation::Remote::Client;

use ariba::Automation::Robot;
use ariba::Automation::ConfigReader;
use ariba::Automation::Remote::Utils;

use ariba::Ops::Logger;
use ariba::Ops::Url;
use URI::Escape;

use ariba::Ops::PersistantObject;
use base qw(ariba::Ops::PersistantObject);

my $logger = ariba::Ops::Logger->logger();

my $DEFAULT_TIMEOUT = 15;

sub newFromRobot {
	my $class = shift;
	my $robot = shift;

	$self = $class->SUPER::new($robot->instance());

	$self->setRobot($robot);
	$self->setTimeout($DEFAULT_TIMEOUT);

	return $self;
}

sub getStatus {
	my $self = shift;

	my $robot = $self->robot();

	my $urlString = ariba::Automation::Constants->serverFrontdoor() . "/cgi-bin/robot-server";
	$urlString .= "?" . cgiAction() . "=" . cgiActionShow() . "&". cgiRobotName() . "=" . $robot->instance();
	my $url = ariba::Ops::Url->new($urlString);
	$url->setUseOutOfBandErrors(1);

	my @response = $url->request($self->timeout());
	my $urlError = $url->error();

	my $response = join("", @response) . "\n";
	$response .= "ERROR: $urlError\n" if $urlError;

	return $response;

}

sub postUpdate {
	my $self = shift;

	my $robot = $self->robot();
	my $robotName = cgiRobotName() . "=" . uri_escape($robot->instance());

	my $globalState = $robot->globalState();

        my $robotAction = cgiAction() . "=" . cgiActionUpdate();
	my $robotString = cgiGlobalState() . "=" . uri_escape($robot->globalState()->saveToString(1));

	my $postString = join("&", $robotAction, $robotString, $robotName);

	my $response = $self->sendPost($postString);

	return $response;

}

sub postConfig {
	my $self = shift;

	my $robot = $self->robot();
	my $robotName = cgiRobotName() . "=" . uri_escape($robot->instance());

	my $configFile = $robot->configFile();
	my $configReader = new ariba::Automation::ConfigReader;
	my $configLines = $configReader->load ($configFile);
	my $configStringRaw = (join "\n", @$configLines) . "\n";

    my $robotAction = cgiAction() . "=" . cgiActionUpdate();
	my $configString = cgiRobotConfig() . "=" . uri_escape($configStringRaw);

	my $postString = join("&", $robotAction, $configString, $robotName);

	my $response = $self->sendPost($postString);

	return $response;
}

sub sendPost {
	my $self = shift;
	my $postString = shift;

	my $url = ariba::Ops::Url->new(ariba::Automation::Constants->serverFrontdoor() . "/cgi-bin/robot-server");
	$url->setContentType("application/x-www-form-urlencoded");

	$url->setPostBody([$postString]);
	$url->setUseOutOfBandErrors(1);

	my @response = $url->request($self->timeout());
	my $urlError = $url->error();

	my $response = join("", @response) . "\n";
	$response .= "ERROR: $urlError\n" if $urlError;

	return $response;
}

1;
