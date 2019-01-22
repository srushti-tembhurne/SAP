package ariba::monitor::SyntheticCDB::UptimeCDB;

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
	my $name = "Total percent uptime for product $productName - $serviceName";
	$name .= " / $customerName" if ($customerName);

	return $name;
}


sub computeRecord {
	my $self = shift;
	my $sTime = shift || 0;
	my $eTime = shift || time();
	my $outagesRef = shift;


	my $totalTime = $eTime - $sTime;
	my ($totalCount, $totalDowntime) = ariba::monitor::Outage->totalDowntime(@$outagesRef);


	my $totalUptimePercent = 0.00;
	$totalUptimePercent = sprintf("%.2f", ($totalTime - $totalDowntime) / $totalTime * 100) if($totalTime);

	my $recordTime = $sTime;

	return ( $recordTime, $totalUptimePercent );

}

sub fileName {
	my $self = shift;

	return $self->fileNameForTypeAndKind("outage", "uptime");
}


1;
