#!/usr/local/bin/perl

package ariba::Ops::DatasetManager::Lock;

use strict;
use base qw(ariba::Ops::PersistantObject);
use ariba::Ops::Constants;
use ariba::Ops::NetworkUtils;

sub validAccessorMethods {
	my $class = shift;

	my $ref = $class->SUPER::validAccessorMethods();
	my @accessors = qw( action product service status dataset mclfile user host );

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

	my $instance = $product . "-" . $service;

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

sub isRunning {
	my $self = shift;

	if($self->status() eq 'Running') {
		return(1);
	}
	return(0);
}

sub isLocked {
	my $self = shift;

	if($self->status() eq 'Detached') {
		return(1);
	}
	return($self->isRunning());
}

sub checkLock {
	my $self = shift;
	my $dataset = shift;
	my $request = shift;
	my $logger = ariba::Ops::Logger->logger();

	my $host = ariba::Ops::NetworkUtils::hostname();
	my $uid = $<;
	my $user = (getpwuid($uid))[0];

	if( $user eq 'root' ) {
		$logger->error("dataset-manager cannot be run as root!");
		return(0);
	}

	my $product = $self->product();
	my $service = $self->service();
	my $action = $self->action();
	my $lockHost = $self->host();
	my $lockUser = $self->user();
	my $lockDS = $self->dataset();

	if($request eq 'Remove Dataset') {
		#
		# not OK to remove a dataset if an active or detached action is being
		# run using the dataset.
		#
		if($self->status() ne 'Finished' && $lockDS eq $dataset) {
			$logger->error("Cannot remove $dataset because there is an active $action running by $lockUser\@$lockHost.");

			#
			# I expect to see this when people start a backup, and it fails.
			# prompting them to "clean up and try again" as they would in the
			# old world...
			#
			# let's try to be helpful here.
			#
			if($action eq 'backup' && $self->status() eq 'Detached') {
				$logger->info("(Perhaps you mean to do '$0 resume $lockDS'?)");
			}
			return(0);
		} else {
			return(1);
		}
	} elsif(!$self->status() || $self->status() eq 'Finished') {
		#
		# ok to claim a new lock if the old lock is finished
		#
		if($request eq 'New') {
			return(1);
		} else {
			$logger->error("Cannot resume finished $action of $lockDS for $product/$service.");
			return(0);
		}
	} elsif($self->status() eq 'Running') {
		#
		# never ok to claim running lock
		#
		$logger->error("dataset-manager is already running $action of $lockDS to $product/$service by $lockUser\@$lockHost");
		return(0);
	} elsif($self->status() eq 'Detached') {
		#
		# ok to reattach, but only from the right place, for the right dataset
		#
		if($request ne 'Resume') {
			$logger->error("Cannot start new dataset-manager task.  There is a suspended $action session for $lockDS to $product/$service by $lockUser\@$lockHost");
			$logger->info("(Perhaps you mean to do '$0 resume $lockDS'?)");
			return(0);
		}
		if($host ne $lockHost || $user ne $lockUser) {
			$logger->error("Cannot resume $action of $lockDS as $user\@$host.  The session is owned by $lockUser\@$lockHost.");
			return(0);
		}
		if($lockDS ne $dataset) {
			$logger->error("Cannot resume for $dataset while $action is being run for $lockDS by $lockUser\@$lockHost.");
			$logger->info("(Perhaps you mean to do '$0 resume $lockDS'?)");
			return(0);
		}

		return(1);
	}
}

1;
