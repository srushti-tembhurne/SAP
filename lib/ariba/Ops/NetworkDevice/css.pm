package ariba::Ops::NetworkDevice::css;

use strict;
use base qw(ariba::Ops::NetworkDevice::BaseDevice);

sub commandPrompt {
	my $self = shift;

	my $str = substr($self->shortName(), 0, 4);

	return $str . '[\w\-]+?# ';
}

sub configPrompt {
	my $self = shift;

	my $str = substr($self->shortName(), 0, 4);

	return $str . '[\w\-]+\(config\)?# ';
}

sub enablePrompt {
	my $self = shift;

	return $self->commandPrompt();
}

sub passwordPrompt {
	my $self = shift;

	return 'assword:';
}

sub loginName {
	my $self = shift;

	return 'root';
}

sub enable {
	my $self = shift;

	# No-op on CSS
}

sub changePassword {
	my $self           = shift;
	my $accessPassword = shift;
	my $enablePassword = shift;

	$self->sendCommand('config t', $self->enablePrompt(), $self->configPrompt());

	if ($enablePassword) {

		my $username = $self->loginName();

		$self->sendCommand("username-offdm $username password $enablePassword", $self->configPrompt());

		if ($self->handle()->exp_before() =~ m/invalid/) {
			return 0
		}

	}

	$self->sendCommand('exit', $self->configPrompt(), $self->enablePrompt());
	$self->sendCommand('wri mem', $self->enablePrompt());

	if ($self->handle()->exp_before() =~ /100%/) {
		return 1;
	}

	return 0;
}

sub getConfig {
	my $self   = shift;

	my @config = ();
	my $prompt = $self->actualCommandPrompt();
	if($prompt) {
		$prompt =~ s/\s+$//;
	} else {
		$prompt = sprintf('%s#', $self->shortName());
	}

	$self->sendCommand('no term more', $prompt);

	my $output = $self->sendCommand('show run', $prompt);

	for my $line (split /\n/, $output) {
                
		$line =~ s///;
		$line =~ s/\s*$//g;

		push (@config, $line);
	}
        
        return join("\n", @config);
}

sub getDuplexState { 
	#This method gets the duplex status of css interfaces which are up
	my $self   = shift;

	my @errors = ();

	my $output = $self->sendCommand('show phy', $self->enablePrompt());

	for my $line (split /\n/, $output) {

		# columns are separated by whitespaces.
		my @values = split (/\s+/, $line);

		# only check interfaces which are up
		if ($values[8] =~ /Up/i) {
			my $duplex = $values[7];
			my $name = $values[1];

			# If duplex state is not full, add it to the errors array
			push (@errors, "port $name set to $duplex\n") if ($duplex !~ /full/i);
		}
	}

	return join('', @errors);

}

# Get current flows and showtech 6 times 10 seconds apart
sub getFlowInfo {
	my $self = shift;
	my $ipForFlows = shift;

	my @flowInfo = ();
	my $prompt = $self->actualCommandPrompt();
	if($prompt) {
		$prompt =~ s/\s+$//;
	} else {
		$prompt = sprintf('%s#', $self->shortName());
	}

	$self->sendCommand('no term more', $prompt);

	for (my $i = 0 ; $i < 6; $i++) {

		print "\nrunning loop " . ($i + 1) . " of 6\n";
		my $output = $self->sendCommand('show clock', $prompt);

		$output .= $self->sendCommand('show flows 0.0.0.0 ' . $ipForFlows, $prompt);
		$output .= $self->sendCommand('show flows ' . $ipForFlows, $prompt);

		my @showCommands = ('show uptime', 'show system-resources', 'show disk', 'show running-config', 'flow statistics', 'show reporter', 'show reporter', 'show service-internal', 'show service', 'show service', 'show dump-status', 'show core', 'show circuit', 'show arp', 'show ip', 'show phy', 'show summary', 'show rule', 'show group', 'show ether-errors', 'show keepalive', 'show ip', 'show rmon', 'show bridge', 'show bridge', 'show interface', 'show virtual-routers', 'show critical-services', 'show critical-reporters', 'show redundancy', 'show chassis', 'show chassis', 'show ssl', 'show ssl', 'show ssl', 'show dos', 'show boot-config', 'show ip-fragment-stats', 'show isc-ports', 'show session-redundant', 'show version', 'show sticky-stats', 'show global-portmap', 'show ssl', 'show http-methods', 'show sasp', 'show sasp-agent-summary', 'show chassis', 'show inventory', 'show flow-state-table');
		
		foreach (@showCommands) {
			$output .= $self->sendCommand($_, $prompt);
		}

		$output .= "\n======================================================================\n";
	
		for my $line (split /\n/, $output) {
   
			$line =~ s///;
			$line =~ s/\s*$//g;
			push (@flowInfo, $line);
		}

		sleep(10);
	}

	return join("\n", @flowInfo);
}

sub portSpeedTable {
	my $self = shift;

	if($self->psTable()) {
		return($self->psTable());
	}

	my $table = {};
	my $snmp  = $self->snmp();

	$snmp->setTimeout(30);
	$snmp->setRetries(5);
	$snmp->setEnums(1);
	$snmp->setSprintValue(1);

	my $oid = ariba::SNMP::ConfigManager::_cleanupOidExpr( "ifNumber.0", $self->machine() );
	my $numberOf = $snmp->valueForOidExpr($oid);

	for(my $i = 1; $i <= $numberOf; $i++) {
		my $oid = ariba::SNMP::ConfigManager::_cleanupOidExpr( "ifDescr.$i", $self->machine() );
		my $desc = $snmp->valueForOidExpr($oid);
		$desc =~ s/^\s//g;
		$desc =~ s/\//:/g;
		last unless($desc);

		$oid = ariba::SNMP::ConfigManager::_cleanupOidExpr( "ifSpeed.$i", $self->machine() );
		my $speed = $snmp->valueForOidExpr($oid);
		$speed /= 1000000;

		$table->{$desc} = $speed;
	}

	$self->setPsTable($table);

	return($table);
}


1;

__END__
