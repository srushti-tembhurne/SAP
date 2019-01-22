#!/usr/local/bin/perl

package ariba::Ops::MCL::Notification;

use strict;
use base qw(ariba::Ops::PersistantObject);
use Mail::Send;

my $logger = ariba::Ops::Logger->logger();

sub dir {
    return('/var/mcl');
}

sub validAccessorMethods {
	my $class = shift;

	my $ref = $class->SUPER::validAccessorMethods();
	my @accessors = qw( argument event mcl type step );

	foreach my $accessor (@accessors) {
		$ref->{$accessor} = 1;
	}

	return($ref);
}

sub objectLoadMap {
	my $class = shift;
	my $map = $class->SUPER::objectLoadMap();

	return($map);
}

sub _computeBackingStoreForInstanceName {
    my $class = shift;
    my $instance = shift;

    my ($mclname, $event, $type, $step) = split(/\-\-/, $instance);
    my $store = "/var/mcl/$mclname/notify/${event}-${type}";
	$store .= "-$step" if($step);
    return($store);
}

sub newFromParser {
	my $class = shift;
	my $mcl = shift;
	my $event = shift;
	my $type = shift;
	my $step = shift;

	my $instance = $mcl . "--" . $event . "--" . $type;
	$instance .= "--" . $step if($step);

	my $self = $class->SUPER::new($instance);

	$self->setMcl($mcl);
	$self->setEvent($event);
	$self->setType($type);
	$self->setStep($step);

	return($self);
}

sub rcpostdataFailed {
	my $self = shift;
	my $note = shift;
	return($self->rcpostdata($note, "failure"));
}

sub rcpostdataResumed {
	my $self = shift;
	my $note = shift;
	return($self->rcpostdata($note, "resumed"));
}

sub rcpostdata {
	my $self = shift;
	my $note = shift;
	my $status = shift;
	my $mcl = ariba::Ops::MCL::currentMclObject();

	my $service = $mcl->service();
	my $args = $self->argument();
	my $productName;
	my $buildName;
	foreach my $v ($mcl->variables()) {
		if($v->name() eq 'productName') {
			$productName = $v->value();
		}
		if($v->name() eq 'buildName') {
			$buildName = $v->value();
		}
	}

	my $p;
	if($productName) {
        if(ariba::rc::InstalledProduct->isInstalled($productName, $service, $buildName)) {
            $p = ariba::rc::InstalledProduct->new($productName, $service, $buildName);
        } else {
            $p = ariba::rc::ArchivedProduct->new($productName, $service, $buildName);
        }
	}
	$buildName = $p->buildName();
	my $branchName = $p->branchName();
	my $releaseName = $p->releaseName();

	my $command = "/home/rc/bin/postdata -product $productName -service $service -build $buildName -branch $branchName -release $releaseName -status $status -step autosp";

	$logger->info("Running rcpostdata: $command");

	system($command);
}

sub email {
	my $self = shift;
	my $note = shift;
	my $to = $self->argument();
	my $mcl = ariba::Ops::MCL::currentMclObject();
	my $service = $mcl->service();

	$logger->info("==> (sending email to $to)");

	my ($subject, $body) = split(/\n/,$note,2);
	$body = $subject unless($body);
    $subject .= " " . $mcl->title() if $mcl->title();

    my @to;
    @to = split(/,\s*/, $to);

	my $msg = Mail::Send->new();
	$msg->set("From:", "MCL Tool <svc$service\@ariba.com>");
	$msg->subject($subject);
	$msg->to(@to);
	my $fh = $msg->open();
	print $fh $body;
	$fh->close();

	return(1);
}

sub notify {
	my $self = shift;
	my $note = shift;
	my $action = $self->type();

	$logger->info("Calling $action ($note)");
	eval { return($self->$action($note)) };
	if($@) {
		$logger->warn("Failed to call notify $action ($note)");
		$logger->warn($@);
	}
}

1;
