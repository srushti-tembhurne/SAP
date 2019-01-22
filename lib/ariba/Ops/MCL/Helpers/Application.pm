#!/usr/local/bin/perl

package ariba::Ops::MCL::Helpers::Application;

use LWP::UserAgent;
use XML::Simple;
use Date::Parse;

use ariba::Ops::MCL;
use ariba::Ops::Logger;
my $logger = ariba::Ops::Logger->logger();

use ariba::Ops::Startup::Common;

sub waitForAppInstancesToInitialize {
	my $product = shift;
	my $service = shift;
	my $build = shift;

	my $p = ariba::rc::InstalledProduct->new($product, $service, $build);
	my @instances = $p->appInstances();
	@instances = grep { $_->supportsRollingRestart() } @instances;

	#
	# for autosp, wait up to 30 minutes
	#
	my $waitTime = 30*60;
	if (ariba::Ops::Startup::Common::waitForAppInstancesToInitialize(\@instances, $waitTime,undef,undef,'quiet')) {
		return("OK: all instances are up.");
	} else {
		return("ERROR: timed out checking for instances to initialize (you can retry to check again).");
	}
}

sub isApplicationUp {
    my $product = shift;
    my $service = shift;
    my $build = shift;

    my $p = ariba::rc::InstalledProduct->new($product, $service);
    my @instances = $p->appInstances();
    @instances = grep { $_->canCheckIsUp() } @instances;

    my @upInstances = grep { $_->checkIsUp() } @instances;

    if(scalar(@upInstances) == 0) {
        return "OK: Down";
    } elsif(scalar(@instances) == scalar(@upInstances)) {
        return "OK: Up";
    } else {
        return "Error: Product is partially down, fix and retry";
    }
}

sub waitForScheduledTask {
    my $product = shift;
    my $service = shift;
    my $taskName = shift;
	my $upgradeEndTime = shift; #Optional flag, RU End timing

    my $p = ariba::rc::InstalledProduct->new($product, $service);
    my @instances = $p->appInstances();
    my $instance = $instances[0];

    my $url = $instance->_directActionURLForCommand('taskStatus/ariba.app.server.ScheduledTaskDirectAction');

    $url =~ s/awpwd=awpwd$/task=$taskName/;

    return waitForDirectAction($url, 24*60*60, \&checkScheduledTaskResult, $upgradeEndTime);
}

sub checkScheduledTaskResult {
    my $content = shift;
	my $upgradeEndTime =shift;

    if($content =~ m|<Status status="(\d+)"\s*/>|) {
        my $status = $1;
        if($status == 3) {
			if( defined($upgradeEndTime) && $content =~ m|<StartTime starttime="([A-Za-z0-9:\s]*)"\s*/>|){ #<StartTime starttime=\"Mon Jun 15 02:10:54 PDT 2015\" />
				my $taskStartTime = ($1 =~ /null/i ? 0 :$1);
				if( str2time($taskStartTime) < str2time($upgradeEndTime)){
					$logger->info("Task not yet initialed, DA returned completed(maybe on old build) with startTime as '$taskStartTime' but Upgrade completed on '$upgradeEndTime'");
					return undef;
				}
			}
            return "OK";
        } else {
            $logger->info("Task not completed, DA returned $status");
            return undef;
        }
    } else {
        return "ERROR: DA returned $content";
    }
}

sub waitForDataLoad {
    my $product = shift;
    my $service = shift;

    my $p = ariba::rc::InstalledProduct->new($product, $service);
    my @instances = $p->appInstances();
    my $instance = $instances[0];

    my $url = $instance->_directActionURLForCommand('preQual');

    $url =~ s|preQual.*|preQual|;

    return waitForDirectAction($url, 24*60*60, \&checkPreQual);
}

sub checkPreQual {
    my $content = shift;

    my $xml = XMLin($content);
    if($xml and $xml->{'check'} and $xml->{'check'}->{'PostUpgradeTaskStatus'}) {
        my $status = $xml->{'check'}->{'PostUpgradeTaskStatus'}->{'status'};
        if($status eq "OK") {
            return "OK";
        } elsif ($status ne "IN PROGRESS") {
            return "ERROR: $status";
        } else {
            $logger->info("Dataload not completed, DA returned $status");
            return undef;
        }
    } else {
        return "ERROR: DA returned $content";
    }
}

sub waitForDirectAction {
    my $url = shift;
    my $waitTime = shift;
    my $processingFunction = shift;
	my $upgradeEndTime = shift;

    my $sleepTime = 60;
    my $tries = int($waitTime / $sleepTime);
    my $errors = 0;
	
	$logger->info("Hitting DA via URL: $url");

    my $ua = LWP::UserAgent->new();
    
    for my $i (1 .. $tries) {
        my $response = $ua->get($url);
        if($response->is_success) {
            my $content = $response->decoded_content;
            my $result = &$processingFunction($content,$upgradeEndTime);
            return $result if $result;
        } else {
            $logger->info("Failed to get DA $url: " . $response->status_line);
            $errors++;
            if($errors > 10) {
                return "Error: Failed to get DA $url 10 times, bailing out";
            }
        }
        sleep($sleepTime);
    }
    return "Error: Task is not complete after $waitTime seconds";
}

1;
