package ariba::monitor::DowntimeTransaction;

use base qw(ariba::Ops::InstanceTTLPersistantObject);

use ariba::monitor::misc;
use ariba::monitor::DowntimeEntry;
use ariba::Ops::ServiceController;

sub newWithDetails {
	my $class = shift;
	my $data = shift;

	my $instance = $class->_generateInstance($data);
	my $self = $class->new($instance) || $class->new($instance);

	foreach my $key (keys %$data) {
		$self->setAttribute($key, $data->{$key});
	}

	my $now = time();
	$self->setCreationTime($now);
	$self->setTtl( 315360000 );

	return($self);
}

sub _generateInstance {
	my $self = shift;
	my $data = shift;

	my $productname = $data->{'productname'};
	$productname .= ":" . $data->{'customer'} if($data->{'customer'});
	my $appname = $data->{'appname'};
	my $timestamp = $data->{'timestamp'};
	my $instance = "$productname:$appname:$timestamp";

	return $instance;
}

sub replayTransactions {
	my $class = shift;
	my $mon = shift;

	ariba::monitor::DowntimeEntry->connectToDatabase($mon);
	my @transactions = $class->listObjects();

	foreach my $t (@transactions) {
		my $data;
		foreach my $key ($t->attributes()) {
			next if($key =~ /^(?:ttl|creationTime|instance)/);
			$data->{$key} = $t->attribute($key);
		}
		my $entry = ariba::monitor::DowntimeEntry->newWithDetails($data);

		#
		# this can come back as another transaction, as opposed to an entry...
		# we're already trying to process transactions, so we just ignore
		# and move on... we'll have to get this next time.
		#
		# exception -- transactions expire after a day in services other than
		# prod, since otherwise we'd fill up disks, since many of our services
		# don't have proper database connections for mon.
		#
		unless($entry && ref($entry) !~ /DowntimeTransaction/) {
			if(!(ariba::Ops::ServiceController::isProductionServicesOnly($mon->service()) && time()-($t->creationTime()) > 86400)) {
				$t->setTtl(-1);
				$t->save();
			}
			next;
		}

		my $rows;
		eval { $rows = $entry->update(); };
		if($rows || (!(ariba::Ops::ServiceController::isProductionServicesOnly($mon->service()) && time()-($t->creationTime()) > 86400))) {
			#
			# we committed, expire the transaction
			#
			$t->setTtl(-1);
			$t->save();
		}
	}
}

sub dir {
	return ariba::monitor::misc::downtimeTransactionDir();	
}

1;
