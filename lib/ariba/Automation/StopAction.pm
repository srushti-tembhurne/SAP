package ariba::Automation::StopAction;

use warnings;
use strict;

use ariba::Automation::Utils;
use ariba::Automation::Action;
use base qw(ariba::Automation::Action);

use ariba::Ops::Logger;
use ariba::Ops::ProcessTable;
use ariba::rc::InstalledProduct;
use ariba::rc::Utils;

sub validFields {
	my $class = shift;

	my $fieldsHashRef = $class->SUPER::validFields();

	$fieldsHashRef->{'buildName'} = 1;
	$fieldsHashRef->{'productName'} = 1;

	return $fieldsHashRef;

}

sub execute {
	my $self = shift;

	my $logger = ariba::Ops::Logger->logger();

	my $service = ariba::Automation::Utils->service();

	my $logPrefix = $self->logPrefix();
	my $productName = $self->productName();
	my $buildName = $self->buildName() || "";

	unless (ariba::rc::InstalledProduct->isInstalled($productName, $service)) {
		$logger->info("$logPrefix $productName not installed for service $service, stop not needed");
		return 1;
	}

	my $product = ariba::rc::InstalledProduct->new($productName, $service);
	unless ($product) {
		$logger->error("$logPrefix could not load installed product $productName for service $service");
		return;
	}

	my $installedBuildName = $product->buildName() || "";

	unless ($installedBuildName eq $buildName) {
		$logger->warn("$logPrefix installed build $installedBuildName is different from requested build to stop $buildName");
	}

	$logger->info("Stopping $productName ($installedBuildName) on $service");
	my $stopCmd = $product->installDir() . "/bin/control-deployment -cluster primary "
		. " " . $product->name()
		. " " . $product->service() 
		. " stop";
	return unless ($self->executeSystemCommand($stopCmd));

	if ($productName eq "ssws") {
		my @ports = (
				$product->default('WebServerHTTPSPort'),
				$product->default('WebServerHTTPPort'),
				$product->default('AdminServerHTTPSPort'),
				$product->default('AdminServerHTTPPort'),
				$product->default('TestServerHTTPSPort'),
				$product->default('TestServerHTTPPort'),
				$product->default('CertServerHTTPSPort'),
			      );

		my @pids = $self->pidsForWebPorts(@ports);
		if (@pids) {
			$logger->warn("ssws not shut down completely, the following pids are still running: " . join(" ", @pids) . ".  Sending them the kill signal.");
			kill(9, @pids) if (@pids);
			@pids = $self->pidsForWebPorts(@ports);
			if (@pids) {
				my $msg = "Stop of ssws failed, The following processes still have web ports open:";

				my $processTable = ariba::Ops::ProcessTable->new();
				for my $pid (@pids) {
					my $procData = $processTable->dataForProcessID($pid);
					$msg .= " $pid (" . $procData->{'cmnd'} . ")";
				}
				$logger->error($msg);
				return;
			}
		}
	}

	$logger->info("Stopped $productName ($installedBuildName) on $service");

	return 1;
}

sub pidsForWebPorts {
	my $self = shift;
	my @ports = @_;

	my $cmd = "lsof -t";
	for my $port (@ports) {
		next unless $port;
		$cmd .= " -iTCP:$port";
	}

	my @pids;;
	ariba::rc::Utils::executeLocalCommand($cmd, undef, \@pids, undef, 1);

	return @pids;
}

1;
