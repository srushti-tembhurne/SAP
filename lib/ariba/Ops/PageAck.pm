package ariba::Ops::PageAck;

#$Id: //ariba/services/tools/lib/perl/ariba/Ops/PageAck.pm#6 $

use strict;
use vars qw(@ISA);

use ariba::Ops::Constants;
use ariba::Ops::DateTime;
use ariba::Ops::PersistantObject;
use ariba::Ops::UDPTransport;

@ISA = qw(ariba::Ops::PersistantObject);

my $rootDir = ariba::Ops::Constants->pagedir() . "/pageack-storage";

# class methods

sub newWithPageId {
	my $class = shift;
	my $pageId = shift;
	my $from = shift;
	my $via = shift;

	my $time = time();
	my $pid = $$;

	# for now
	my $instanceName = "pageAck-" . $pid . "-" . $time;

	my $self = $class->SUPER::new($instanceName); 

	$pageId = lc($pageId);

	$self->setPageId($pageId);
	$self->setFrom($from);
	$self->setVia($via);

	$self->setTime(time());	   #remove this
	$self->setCreationTime(time());

	return $self;
}

sub listObjects {
	my $class = shift;
	
	die "listObjects() not supported";
}

sub dir {
	my $class = shift;
	return $rootDir;
}

sub _instanceNameToYearMonthDay {
	my $class = shift;
	my $instanceName = shift;

	# grab creation time from instance name
	$instanceName =~ m/(\d+)$/;
	my $time = $1;

	return ariba::Ops::DateTime::yearMonthDayFromTime($time);
}

sub _computeBackingStoreForInstanceName {
	my $class = shift;
	my $instanceName = shift;

	# this takes the instance name as an arg
	# so that the class method objectExists() can call it

	my $dir = $class->dir();
	my ( $year, $month, $day ) = $class->_instanceNameToYearMonthDay($instanceName);

	my $file = "$dir/$year/$month/$day/$instanceName";

	return $file;
}


my %via = (
	'unknown', 0,
	'webpage', 1,
	'email', 2,
	'commandline', 3,
);

my %viaString = (
	0, 'unknown',
	1, 'webpage',
	2, 'email',
	3, 'commandline',
);
	

sub viaToString {
	my $class = shift;
	my $via = shift || 0;

	return $viaString{$via};
}

sub viaWebpage {
	my $class = shift;
	return $via{'webpage'};
}

sub viaEmail {
	my $class = shift;
	return $via{'email'};
}

sub viaCommandline {
	my $class = shift;
	return $via{'commandline'};
}

sub viaUnknown {
	my $class = shift;
	return $via{'unknown'};
}

sub sendToServer {
	my $self = shift;
	my $server = shift;
	my $debug = shift;
	my $port = shift;

	my $transport = ariba::Ops::UDPTransport->new();
	$transport->setDebug($debug);
	$transport->initAsClient($server, $port);

	return $transport->sendMessageToServer( $self->saveToString(1) );
}

1;

