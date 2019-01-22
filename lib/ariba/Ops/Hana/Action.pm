package ariba::Ops::Hana::Action;
use strict;
use warnings;

=head1 NAME

ariba::Ops::Hana::Action

=head1 SYNOPSIS

 my $obj = ariba::Ops::Hana::Action->new(
 	primary   => $primary_dbc,
 	secondary => $secondary_dbc,
 	service   => $service,
 );
 my $status  = $obj->status;
 my $reset   = $obj->reset;
 my $backup  = $obj->backup;
 my $offline = $obj->offline;
 my $online  = $obj->online;

=head1 DESCRIPTION

This class handles the Hana Actions needed for the dr-failover jmcl.

=cut

use Carp;
use ariba::Ops::MCLGen;

my $PRIMARY      = 'primary';
my $SECONDARY    = 'secondary';
my $SHELL        = 'Shell';
my $HANA         = 'Hana';
my $STATUS       = 'status';
my $RESET        = 'reset';
my $BACKUP       = 'backup';
my $OFFLINE      = 'offline';
my $ONLINE       = 'online';
my $FREEZE       = 'freeze';
my $UNFREEZE     = 'unfreeze';
my $PRIMARY_HOST = '_primary_host';
my $USER         = '_user';
my $PEER_HOST    = '_peer_hosts';
my $SID          = '_sid';

my %ACTION_ARGS = (
	$ONLINE => {
		hosts  => $PRIMARY_HOST,
		action => $ONLINE,
		type   => $SHELL,
		user   => $USER,
	},
	$OFFLINE => {
		hosts  => $PRIMARY_HOST,
		action => $OFFLINE,
		type   => $SHELL,
		user   => $USER,
	},
	$BACKUP => {
		hosts  => $PEER_HOST,
		action => $BACKUP,
		type   => $SHELL,
		user   => $USER,
	},
	$RESET => {
		hosts  => $PEER_HOST,
		action => $RESET,
		type   => $SHELL,
		user   => $USER,
	},
	$STATUS => {
		hosts  => $PRIMARY_HOST,
		action => $STATUS,
		type   => $HANA,
		user   => $SID,
	},
	$FREEZE => {
		hosts  => $PRIMARY_HOST,
		action => $FREEZE,
		type   => $SHELL,
		user   => $USER,
	},
	$UNFREEZE => {
		hosts  => $PRIMARY_HOST,
		action => $UNFREEZE,
		type   => $SHELL,
		user   => $USER,
	},
);

my %ACTION_COMMAND;
map { $ACTION_COMMAND{$_} = sprintf("_%s_commands", $_) } ( $BACKUP, $OFFLINE, $ONLINE, $RESET, $STATUS, $FREEZE, $UNFREEZE );



=head1 CONSTRUCTOR

=head2 new(primary => $primary_dbc, secondary => $secondary_dbc, service => $service | Str) | ariba::Ops::Hana::Action

Constructor. Required parameters are 'primary', 'secondary' and 'service'.

=cut

sub new {
	my $invocant = shift;
	my $class = ref $invocant || $invocant;
	my $self = bless {}, $class;
	my %args = @_;
	$self->_init(%args);
	return $self;
}

=head1 METHODS

=head2 online() | Str

Returns the online action.

=cut

sub online {
	my $self = shift;
	return $self->_action(%{$ACTION_ARGS{$ONLINE}});
}

=head2 offline() | Str

Returns the offline action.

=cut

sub offline {
	my $self = shift;
	return $self->_action(%{$ACTION_ARGS{$OFFLINE}});
}

=head2 backup() | Str

Returns the backup action.

=cut

sub backup {
	my $self = shift;
	return $self->_action(%{$ACTION_ARGS{$BACKUP}});
}


=head2 reset() | Str

Returns the reset action.

=cut

sub reset {
	my $self = shift;
	return $self->_action(%{$ACTION_ARGS{$RESET}});
}

=head2 status() | Str

Returns the status action.

=cut

sub status {
	my $self = shift;
	return $self->_action(%{$ACTION_ARGS{$STATUS}});
}

=head2 freeze() | Str

Returns the freeze action.

=cut

sub freeze {
	my $self = shift;
	return $self->_action(%{$ACTION_ARGS{$FREEZE}});
}

=head2 unfreeze() | Str

Returns the unfreeze action.

=cut

sub unfreeze {
	my $self = shift;
	return $self->_action(%{$ACTION_ARGS{$UNFREEZE}});
}

=head2 primary() | ariba::Ops::DBConnection

Returns the primary db connection.
Need to set in the constructor.

=cut

sub primary {
	my $self = shift;
	$self->{primary} = shift if @_;
	return $self->{primary};
}

=head2 secondary() | ariba::Ops::DBConnection

Returns the secondary db connection.
Need to set in the constructor.

=cut

sub secondary {
	my $self = shift;
	$self->{secondary} = shift if @_;
	return $self->{secondary};
}

=head2 service() | Str

Returns the service.
Need to set in the constructor.

=cut

sub service {
	my $self = shift;
	$self->{service} = shift if @_;
	return $self->{service};
}



# ----------------
# Private methods
# ----------------

# _init( %args | Hash ) | Undef
# Initializes default values and arguments passed to the constructor.

sub _init {
	my $self = shift;
	my %args = @_;

	# defaults

	while( my($method,$value) = each %args ) {
		if ($self->can($method)) {
			$self->$method($value);
		}
		else {
			croak "invalid method: $method";
		}
	}

	# required
	croak "missing primary dbc"   if ! $self->primary;
	croak "missing secondary dbc" if ! $self->secondary;
	croak "missing service"       if ! $self->service;
}


# _action( hosts => $host_method, action => $action, type => $type, user => $user_method ) | Str
# Returns the action for the JMCL.
# hosts, action, type and user are required parameters.
# hosts would be the name of the host_method that will return the host names.
# user would be the name of the user_method that will return the user name.
#

sub _action {
	my $self = shift;
	my %args = @_;
	my $host_method = $args{hosts}  or croak "missing hosts";
	my $action      = $args{action} or croak "missing action";
	my $type        = $args{type}   or croak "missing type";
	my $user_method = $args{user}   or croak "missing user";

	my $hosts = [$self->$host_method];
	my $user  = $self->$user_method;

	my $command_method = $self->_action_command($action);
	my $ret = "";
	foreach my $host (@$hosts) {
		$ret .= defineAction(
			$type,
			sprintf("%s@%s", $user, $host),
			$self->$command_method(),
		);
	}
	$ret .= "\n";
	return($ret);
}

# _action_command( $action | Str ) | Str
# Returns the method name for the associated action.

sub _action_command {
	my $self = shift;
	my $action = shift;
	croak "no action"                if ! $action;
	croak "invalid action = $action" if ! exists $ACTION_COMMAND{$action};
	return $ACTION_COMMAND{$action};
}


# _hana_user() | Str
# Returns the hana_user.
# Caches the value.

# The shift is for testing. You shouldn't have to use it.

sub _hana_user {
	my $self = shift;
	if (! $self->{hana_user}) {
		$self->{hana_user} = @_ ? shift : $self->_sid() . 'adm';
	}
	return $self->{hana_user};
}

# _user() | Str
# Returns the user.
# Caches the value.

sub _user {
	my $self = shift;
	if (!$self->{user}) {
		$self->{user} = 'mon' . $self->service;
	}
	return $self->{user};

}

# _sid() | Str
# Returns the sid.
# Caches the value.

# The shift is for testing. You shouldn't have to use it.

sub _sid {
	my $self = shift;
	if (!$self->{sid}) {
		$self->{sid} = @_ ? shift : lc($self->primary()->sid());
	}
	return $self->{sid};

}


# _cluster($primary_host | Str, $secondary_host | Str) | Str
# Returns the cluster: primary or secondary

sub _cluster {
	my $self           = shift;
	my $primary_host   = shift;
	my $secondary_host = shift;
	return $primary_host eq $secondary_host ? $SECONDARY : $PRIMARY;
}

# _primary_host() | Str
# Returns the primary host.
# Caches the value.

# The shift is for testing. You shouldn't have to use it.

sub _primary_host {
	my $self  = shift;
	if (!$self->{primary_host}) {
		$self->{primary_host} = @_ ? shift : $self->primary()->host();
	}
	return $self->{primary_host};
}

# _secondary_host() | Str
# Returns the secondary host.
# Caches the value.

# The shift is for testing. You shouldn't have to use it.

sub _secondary_host {
	my $self  = shift;
	if (!$self->{secondary_host}) {
		$self->{secondary_host} = @_ ? shift : $self->secondary()->host();
	}
	return $self->{secondary_host};
}

# _peer_hosts() | ArrayRef[Str]
# Returns the peer hosts.

sub _peer_hosts {
	my $self  = shift;
	my $peer  = $self->_peer();
	my $cluster = $self->_cluster($self->_primary_host, $self->_secondary_host);
	my %hosts;
	map { $hosts{$_->host}++ } $peer->allPeerConnections($cluster);
	return keys %hosts;
}


# _peer() | ariba::Ops::DatabasePeers
# Returns the peer of the primary host.
# This method caches the value.

sub _peer {
	my $self = shift;
	if (!$self->{peer}{$self->_primary_host}) {
		# apparently we only care about the first one
		my($peer) = ariba::Ops::DatabasePeers->newListFromDbcs({}, $self->primary, $self->secondary);
		$self->{peer}{$peer->primary->host} = $peer;
		$self->{peer}{$self->_primary_host} = $peer;
	}
	return $self->{peer}{$self->_primary_host};
}

# _online_commands() | Array[Str]
# Returns the online commands for the JMCL.

sub _online_commands {
	my $self = shift;
	my $hana_user = $self->_hana_user;
	my @commands = (
		"\$ sudo su - $hana_user -c 'sapcontrol -nr 00 -function StartSystem HDB'",
	);
	return @commands;
}


# _offline_commands() | Array[Str]
# Returns the offline commands for the JMCL.

sub _offline_commands {
	my $self = shift;
	my $hana_user = $self->_hana_user;
	my @commands = (
		"\$ sudo su - $hana_user -c 'sapcontrol -nr 00 -function StopSystem HDB 1500 1200'",
	);
	return @commands;
}

# _backup_commands() | Array[Str]
# Returns the backup commands for the JMCL.

sub _backup_commands {
	my $self = shift;
	my @commands = (
		"\$ sudo /usr/local/ariba/bin/manage-backup -d -policy no_stale_ss -sid hana -volType data",
		"\$ sudo /usr/local/ariba/bin/manage-backup -d -policy no_stale_ss -sid hana -volType log",
		"\$ sudo /usr/local/ariba/bin/bcv-backup -d -jira \${TMID} -snap -sid hana -volType data",
		"\$ sudo /usr/local/ariba/bin/bcv-backup -d -jira \${TMID} -snap -sid hana -volType log",
	);
	return @commands;
}

# _reset_commands() | Array[Str]
# Returns the reset commands for the JMCL.

sub _reset_commands {
	my $self = shift;
	my @commands = (
		"\$ sudo /usr/local/ariba/bin/manage-backup -d -policy stale_ss -sid hana -volType data",
		"\$ sudo /usr/local/ariba/bin/manage-backup -d -policy stale_ss -sid hana -volType log",
	);
	return @commands;
}

# _status_commands() | Array[Str]
# Returns the status commands for the JMCL.

sub _status_commands {
	my $self = shift;
	my @commands = (
		"\$ select user() from dummy",
	);
	return @commands;
}

# _freeze_commands() | Array[Str]
# Returns the freeze commands for the JMCL.

sub _freeze_commands {
	my $self = shift;
	return $self->_na_commands($FREEZE);
}

# _unfreeze_commands() | Array[Str]
# Returns the unfreeze commands for the JMCL.

sub _unfreeze_commands {
	my $self = shift;
	return $self->_na_commands($UNFREEZE);
}

# _na_commands( $action | Str ) | Array[Str]
# Returns the placeholder commands for the JMCL.
# freeze and unfreeze are meaningless in this context

sub _na_commands {
	my $self = shift;
	my $action = shift;
	my @commands = (
		"\$ echo $action does not apply to hana database",
	);
	return @commands;
}

1;

__END__

=head1 AUTHOR

Written by David Laulusa.

=head1 COPYRIGHT

Copyright (c), SAP AG, 2016

=cut