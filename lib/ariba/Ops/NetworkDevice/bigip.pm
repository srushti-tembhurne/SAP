package ariba::Ops::NetworkDevice::bigip;

use strict;
use base qw(ariba::Ops::NetworkDevice::BaseDevice);

sub commandPrompt {
	my $self = shift;

	my $str = substr($self->shortName(), 0, 4);

	return $str . '[\w\-:~]+?# ';
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

	# No-op 
}

sub getConfig {
	my $self   = shift;

	my @config = ();
	my $prompt = $self->actualCommandPrompt();
	if($prompt) {
		$prompt =~ s/\s+$//;
	} else {
		$prompt = $self->commandPrompt();
	}

	$self->setSendCR(0);
	my $output = $self->sendCommand('bigpipe list', $prompt);

	for my $line (split /\n/, $output) {
                
		$line =~ s///;
		$line =~ s/\s*$//g;

		push (@config, $line);
	}
        
	return join("\n", @config);
}

1;

__END__
