package ariba::monitor::SyntheticCDB::UnplannedDowntimeCDB;

use ariba::Ops::DateTime;
use DateTime;
use ariba::rc::InstalledProduct;
use ariba::rc::ArchivedProduct;
use ariba::monitor::DowntimeEntry;
use ariba::monitor::Outage;
use Date::Parse;
use POSIX qw(strftime);


use base qw(ariba::monitor::BaseUptimeCDB);


sub name {
	my $self = shift;

	my $productName = $self->product()->name();
	my $serviceName = $self->product()->service();
	my $customerName = $self->product()->customer();
	my $name = "Total unplanned downtime for product $productName - $serviceName";
	$name .= " / $customerName" if ($customerName);

	return $name;
}


sub computeRecord {
	my $self = shift;
	my $sTime = shift || 0;
	my $eTime = shift || time();
	my $outagesRef = shift;


	my ($unplannedCount, $unplannedDowntime) = ariba::monitor::Outage->unplannedDowntime(@$outagesRef);

	my $recordTime = $sTime;

	return (	$recordTime, $unplannedDowntime );
}

sub units
{
	my $class = shift();
	return "sec";
}

sub fileName {
	my $self = shift;

	return $self->fileNameForTypeAndKind("outage", "unplanneddowntime");
}


1;
