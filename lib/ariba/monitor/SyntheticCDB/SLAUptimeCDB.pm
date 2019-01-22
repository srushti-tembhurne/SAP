package ariba::monitor::SyntheticCDB::SLAUptimeCDB;

use ariba::Ops::DateTime;
use DateTime;
use ariba::rc::InstalledProduct;
use ariba::rc::ArchivedProduct;
use ariba::monitor::DowntimeEntry;
use ariba::monitor::Outage;
use Date::Parse;
use POSIX qw(strftime);

use base qw(ariba::monitor::BaseUptimeCDB);



sub computeRecord {
	my $self = shift;
	my $sTime = shift || 0;
	my $eTime = shift || time();
	my $outagesRef = shift;


	my $totalTime = $eTime - $sTime;
	my ($plannedCount, $plannedDowntime) = ariba::monitor::Outage->plannedDowntime(@$outagesRef);
	my ($slaCount, $slaUnplannedDowntime) = ariba::monitor::Outage->SLADowntime(@$outagesRef);

	my $slaUptimePercent = 0.00;
	$slaUptimePercent = sprintf("%.2f", ($totalTime - $slaUnplannedDowntime - $plannedDowntime) / ($totalTime - $plannedDowntime) * 100) if($totalTime - $plannedDowntime);

	my $recordTime = $sTime;

	return ($recordTime, $slaUptimePercent);

}

sub name {
	my $self = shift;

	my $productName = $self->product()->name();
	my $serviceName = $self->product()->service();
	my $customerName = $self->product()->customer();
	my $name = "Total percent uptime SLA for product $productName - $serviceName";
	$name .= " / $customerName" if ($customerName);

	return $name;
}

sub fileName {
	my $self = shift;

	return $self->fileNameForTypeAndKind("outage", "uptimesla");
}

1;
