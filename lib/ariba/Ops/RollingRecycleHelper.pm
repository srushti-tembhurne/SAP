#
# $Id: //ariba/services/tools/lib/perl/ariba/Ops/RollingRecycleHelper.pm#7 $
#
# A helper class to manage migration and initialization for products
#

package ariba::Ops::RollingRecycleHelper;

use strict;

require "geturl";
use ariba::Ops::PersistantObject;
use ariba::rc::Utils;
use ariba::rc::Globals;
use ariba::rc::Passwords;
use base qw(ariba::Ops::PersistantObject);

my $UPGRADE = "Upgrade";
my $RESTART = "Restart";
my $BEGIN   = "Begin";
my $END     = "End";

sub dir { return undef; }

my %validAccessorMethods = (
	'product' => 1,
);

sub validAccessorMethods {
	return \%validAccessorMethods;
}

sub newFromProduct {
	my $class = shift;
	my $passedInProduct = shift;
	my $cluster = shift;

	my $product = $passedInProduct;

	$product->setClusterName($cluster) if ($cluster);

	my $instanceName = $product->name();
	$instanceName .= $product->customer() if $product->customer();
	$instanceName .= "-rolling-recycle-helper";

	my $self = $class->SUPER::new($instanceName);

	$self->setProduct($product);

	return $self;
}

sub _requiresFlaggingRollingRecycle {
	my $self = shift;

	my $product = $self->product();
	my $name = $product->name();
	my $release = $product->releaseName();
 
	#
	# for buyer, s4 and arches starting eagle (9s5) we need to tell apps that
	# we are going to rolling restart/upgrade it.
	#
	if ( grep  { $name eq $_ } (ariba::rc::Globals::sharedServiceSourcingProducts(), ariba::rc::Globals::sharedServiceBuyerProducts(), ariba::rc::Globals::archesProducts()) ) {
		if ($release !~ m|^9s4|) {
			return 1;
		}
	}

	return 0;
}

sub _tellProductAboutRollingRecycle {
	my $self = shift;
	my $operation = shift;
	my $verb = shift;

	#
	# Do we need to tell the product about rolling recycle?
	#
	return 0 unless ($self->_requiresFlaggingRollingRecycle());

	my $product = $self->product();

	#
	# Can we tell it?
	#
	my @appInstances = $product->appInstancesInCluster($product->currentCluster());
	return 0 unless (@appInstances);

	#
	# tell the product about it, using the various direct actions
	#
	my $appInstance = $appInstances[0];

	my $url = $appInstance->signalRollingRecycleOperationURL($operation, $verb);
	my $timeout = 30;
	my @output;
	my @errors;

	my @geturlArgs = ("-e","-q","-timeout",$timeout,"-results",\@output, "-errors", \@errors);

	# Save current default stdout
	my $outStream = select;

	eval 'main::geturl(@geturlArgs, $url);';

	# Restore saved stdout
	select($outStream);

	#print ">>> url = $url\n";
	#print "    output = ", join("", @output), "\n";
	#print "    error = ", join("", @errors), "\n";

	# return list of errors
	return (@errors);
}

sub createInProgressMarker {
	my $self = shift;
	my $prefix = shift;
	my $file = $prefix . "running";
	my $p = $self->product();

	my $rootDir = $p->default('System.Base.RealmRootDir');
	return unless($rootDir);

	my $user = ariba::rc::Globals::deploymentUser($p->name(), $p->service());
	my $uid = $<;
	my $me = (getpwuid($uid))[0];
	my $password = ariba::rc::Passwords::lookup($me);
	my $command = "sudo su $user -c 'touch $rootDir/$file'";

	my $restore = $main::quiet;
	$main::quiet = 1;
	my @output;
	ariba::rc::Utils::executeLocalCommand(
		$command,
		0,
		\@output,
		undef,
		1,
		undef,
		$password
	);
	$main::quiet = $restore;
}

sub deleteInProgressMarkers {
	my $self = shift;
	my $p = $self->product();

	my $rootDir = $p->default('System.Base.RealmRootDir');
	return unless($rootDir);

	my $user = ariba::rc::Globals::deploymentUser($p->name(), $p->service());
	my $uid = $<;
	my $me = (getpwuid($uid))[0];
	my $password = ariba::rc::Passwords::lookup($me);

	my $restore = $main::quiet;
	$main::quiet = 1;
	my @output;
	ariba::rc::Utils::executeLocalCommand(
		"sudo su $user -c 'rm -f $rootDir/RRrunning $rootDir/RUrunning'",
		0,
		\@output,
		undef,
		1,
		undef,
		$password
	);
	$main::quiet = $restore;
}

sub beginRollingUpgrade {
	my $self = shift;

	$self->createInProgressMarker('RU');
	return $self->_tellProductAboutRollingRecycle($UPGRADE, $BEGIN);
}

sub endRollingUpgrade {
	my $self = shift;

	$self->deleteInProgressMarkers();
	return $self->_tellProductAboutRollingRecycle($UPGRADE, $END);
}

sub beginRollingRestart {
	my $self = shift;

	$self->createInProgressMarker('RR');
	return $self->_tellProductAboutRollingRecycle($RESTART, $BEGIN);
}

sub endRollingRestart {
	my $self = shift;

	$self->deleteInProgressMarkers();
	return $self->_tellProductAboutRollingRecycle($RESTART, $END);
}

1;
