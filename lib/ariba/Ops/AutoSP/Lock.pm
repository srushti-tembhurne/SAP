#!/usr/local/bin/perl

package ariba::Ops::AutoSP::Lock;

use strict;
use base qw(ariba::Ops::PersistantObject);
use ariba::Ops::Constants;
use ariba::Ops::NetworkUtils;

sub validAccessorMethods {
	my $class = shift;

	my $ref = $class->SUPER::validAccessorMethods();
	my @accessors = qw( product service status mclfile user host );

	foreach my $accessor (@accessors) {
		$ref->{$accessor} = 1;
	}

	return($ref);
}

sub dir {
    return('/home/archmgr/locks');
}

sub newFromProductAndService {
	my $class = shift;
	my $product = shift;
	my $service = shift;

	my $instance = "autosp-" . $product . "-" . $service;

	my $self = $class->SUPER::new($instance);

	$self->setProduct($product);
	$self->setService($service);

	return($self);
}

sub detach {
	my $self = shift;
	$self->setStatus('Detached');
	$self->save();
}

sub release {
	my $self = shift;
	$self->setStatus('Finished');
	$self->save();
}

sub checkLock {
	my $self = shift;
	my $request = shift;
	my $logger = ariba::Ops::Logger->logger();

	my $host = ariba::Ops::NetworkUtils::hostname();
	my $uid = $<;
	my $user = (getpwuid($uid))[0];

	if( $user eq 'root' ) {
		$logger->error("autosp cannot be run as root!");
		return(0);
	}

	my $product = $self->product();
	my $service = $self->service();
	my $lockHost = $self->host();
	my $lockUser = $self->user();

	if(!$self->status() || $self->status() eq 'Finished') {
		#
		# ok to claim a new lock if the old lock is finished
		#
		if($request eq 'New') {
			return(1);
		} else {
			if($request eq 'Force') {
				$logger->error("Cannot force restart of finished autosp for $product/$service.");
			} else {
				$logger->error("Cannot resume finished autosp for $product/$service.");
			}
			return(0);
		}
	} elsif($self->status() eq 'Running') {
		#
		# never ok to claim running lock
		#
		$logger->error("autosp is already running for $product/$service by $lockUser\@$lockHost");
		return(0);
	} elsif($self->status() eq 'Detached') {
		#
		# ok to reattach, but only from the right place.
		#
		if($request ne 'Resume' && $request ne 'Force') {
			$logger->error("Cannot start new autosp task.  There is a suspended session for $product/$service by $lockUser\@$lockHost");
			return(0);
		}

		my $action = "resume";
		$action = "force new" if($request eq 'Force');

		if($host ne $lockHost || $user ne $lockUser) {
			$logger->error("Cannot $action autosp for $product/$service as $user\@$host.  The session is owned by $lockUser\@$lockHost.");
			return(0);
		}
		return(1);
	}
}

1;
