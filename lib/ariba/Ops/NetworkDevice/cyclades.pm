package ariba::Ops::NetworkDevice::cyclades;

use strict;
use base qw(ariba::Ops::NetworkDevice::BaseDevice);

use Net::SSH::Perl;

sub loginName {
	my $self = shift;

	return 'root';
}

sub commandPrompt {
	my $self = shift;

	return 'root]# ';
}

sub enablePrompt {
	my $self = shift;

	return $self->commandPrompt();
}

# Use Net::SSH::Perl here - there's brokenness with using Expect + ssh, the
# config file becomes truncated to the first few lines.
sub getConfig {
	my $self = shift;

	my $ssh;

	eval {
		$ssh  = Net::SSH::Perl->new(
				$self->hostname(),
				'protocol' => '2,1',
				'port'     => 22,
				);
	};

	if ($@) {
		return undef;
	}

	$ssh->login( $self->loginName(), $self->enablePassword() );

	my $runningConfig = ($ssh->cmd('cat /etc/portslave/pslave.conf'))[0];

	return $runningConfig;
}

1;

__END__
