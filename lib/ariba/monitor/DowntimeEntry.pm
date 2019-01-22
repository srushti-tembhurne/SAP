=pod

=head1 NAME

DowntimeEntry

=head1 VERSION

# $Id: //ariba/services/monitor/lib/ariba/monitor/DowntimeEntry.pm#14 $

=head1 DESCRIPTION

Represents an "up" or "down" event in the Ops Metrics DB. An event can
be triggered by a specific product application, and can be customer-specific.

=cut

package ariba::monitor::DowntimeEntry;

use strict;
use base qw(ariba::Ops::ClassDBIBase);

use ariba::Ops::DBConnection;
use ariba::monitor::DowntimeTransaction;
use Date::Parse;
use POSIX qw(strftime);

my %dbiSettings = (
	PrintError => 0,
	RaiseError => 1,
	AutoCommit => 1,
);

my %connectionCache;

=head1 PUBLIC CLASS METHODS

=over 8

=item * $class->connectToDatabase($product)

Activate the database connection for the received product on
the receiving class.

=cut

sub connectToDatabase {
	my $class   = shift;
	my $product = shift;

	# this is needed for NLS altering to work.
	$ENV{'ORACLE_HOME'} = '/usr/local/oracle';

	my $dbc = ariba::Ops::DBConnection->connectionsForProductOfDBType(
		$product, ariba::Ops::DBConnection->typeMain()
	);

	my $dsn = sprintf("dbi:Oracle:host=%s;sid=%s", $dbc->host(), $dbc->sid());
	my $cacheKey = $product->name() . "-$dsn";

	return ($connectionCache{$cacheKey}) if ($connectionCache{$cacheKey});

	# this is Class::DBI notation for connecting to the db.
	$class->set_db('Main', $dsn, $dbc->user(), $dbc->password(), \%dbiSettings);

	$class->table('OPSMETRICS');

	# think objectLoadMap()
	$class->columns('Primary'   => qw/id/);
	$class->columns('Essential' => qw/productname appname transitiontype planned timestamp note opsnote customer/);

	# This is to make oracle sequences work - grio, yes this is needed, it
	# doesn't work without it.
	$class->sequence('OPSMETRICS_SEQ');
	$class->set_sql('Nextval', 'SELECT %s.NEXTVAL from DUAL');

	# and date handling easier.
	eval {
		my $dbh = $class->db_Main();
		$dbh->do(qq{alter session set nls_date_format = 'YYYY-MM-DD:HH24:MI:SS'}) or warn $dbh->errstr();
	};

	$class->add_constructor('entriesForDateRangeAndProduct' => qq{
		timestamp between ? and ? and productname = ? order by timestamp asc
	});

	$class->add_constructor('entriesForDateRangeAndProductPlanned' => qq{
		timestamp between ? and ? and productname = ? and planned = ? order by timestamp asc
	});

	$class->add_constructor('entriesForDateRangeAndProductAndCustomer' => qq{
		timestamp between ? and ? and productname = ? and customer = ? order by timestamp asc
	});

	$class->add_constructor('entriesForDateRangeAndProductAndCustomerPlanned' => qq{
		timestamp between ? and ? and productname = ? and customer = ? and planned = ? order by timestamp asc
	});

	$class->add_constructor('entriesForDateRangeAndCustomer' => qq{
		timestamp between ? and ? and customer = ? order by timestamp asc
	});

	$class->add_constructor('entriesForDateRangeAndCustomerPlanned' => qq{
		timestamp between ? and ? and customer = ? and planned = ? order by timestamp asc
	});

	$class->add_constructor('SSSuiteEntriesForDateRange' => qq{
		timestamp between ? and ? and (productname = 's4' or productname='buyer') order by timestamp asc
	});

	$class->add_constructor('SSSuiteEntriesForDateRangePlanned' => qq{
		timestamp between ? and ? and (productname = 's4' or productname='buyer') and planned = ? order by timestamp asc
	});

	$class->add_constructor('entriesForDateRange' => qq{
		timestamp between ? and ? order by timestamp asc
	});

	$connectionCache{$cacheKey} = $class;
	return $class;
}

sub entriesForDateRangeAndWhereClause {
	my $class = shift;
	my $sDate = shift;
	my $eDate = shift;
	my $whereClause = shift;

	return( $class->retrieve_from_sql("timestamp between '$sDate' and '$eDate' and ( $whereClause )") );

}

=pod

=item * $class->newWithDetails($data)

=cut

sub newWithDetails {
	my $class = shift;
	my $data  = shift;

	if ($data->{'timestamp'} && $data->{'timestamp'} =~ /^\d+$/) {
		$data->{'timestamp'} = $class->formatTimestamp($data->{'timestamp'});
	}
	my $self;

	eval {
		$self = $class->create($data);
	};

	unless( $self && $self->id() ) {
		#
		# if $class->create() fails, then we need to save a transaction for
		# later
		#
		$self = ariba::monitor::DowntimeTransaction->newWithDetails($data);
	}
	return $self;
}

=pod

=item * $class->productList($dateInRange)

Return a list of products which had downtime in the given time range.
$dateInRange is SQL WHERE statement qualifier.

=cut

sub productList {
	my $class = shift;
	my $dateInRange = shift;

	my $dbh = $class->db_Main();

	my $query = "select distinct productname,customer from opsmetrics";
	$query .= " where $dateInRange" if $dateInRange;

	return @{$dbh->selectall_arrayref( $query )};
}


=pod

=item * $class->earliestEntryForProduct( $product )

Return the timestamp of the earliest downtime entry of a given product

=cut


sub earliestEntryForProduct {
	my $class = shift;
	my $product = shift;

	return undef unless ($product);


	my $dbh = $class->db_Main();

	my $productName = $product->name();
	my $customer = $product->customer();

	my $query = "select min( timestamp ) from opsmetrics where productname = '$productName'";
	$query .= " and customer= '$customer' " if $customer;

	return @{$dbh->selectall_arrayref( $query )};

}

=pod

=item * $class->latestEntryForProduct( $product )

Return the timestamp of the latest downtime entry of a given product

=cut


sub latestEntryForProduct {
	my $class = shift;
	my $product = shift;

	return undef unless ($product);


	my $dbh = $class->db_Main();

	my $productName = $product->name();
	my $customer = $product->customer();

	my $query = "select max( timestamp ) from opsmetrics where productname = '$productName'";
	$query .= " and customer= '$customer' " if $customer;

	return @{$dbh->selectall_arrayref( $query )};

}


=pod

=item * $class->dateFormat()

printf-style string, used to format timestamps in a manner suitable
for downtime reports.

=cut

sub dateFormat {
	my $class = shift;

	return '%Y-%m-%d:%H:%M:%S';
}

=pod

=item * $class->formatTimestamp($value)

Format a localtime() type time nicely

=cut

sub formatTimestamp {
	my $class = shift;
	my $value = shift || return 0;

	return strftime($class->dateFormat(), localtime($value));
}

=pod

=back

=head1 PUBLIC INSTANCE METHODS

=over 8

=item * $self->timestamp()

Return self's human-readable timestamp.

=cut

sub timestamp {
	my $self = shift;
	return str2time($self->get('timestamp'));
}

=pod

=item * $self->setTimestamp($value)

Set self's timestamp to the received value (a localtime() time)

=cut

sub setTimestamp {
	my $self  = shift;
	my $value = shift;
	my $class = ref($self);

	return $self->set('timestamp', $class->formatTimeStamp($value));
}

=pod

=item * $self->transitionTypeAsString()

Return self's transition type in human-readable form

=cut

sub transitionTypeAsString {
	my $self = shift;

	my $type = $self->transitiontype();

	#    TRANSITIONTYPE      int not null,
	#-- 0 = up->down; 1 = down->up

	return "up->down" if $type == 0;
	return "down->up" if $type == 1;

	return $type;
}

=pod

=item * $self->plannedAsString()

Return self's planned/unplanned status in human-readable form

=cut

sub plannedAsString {
	my $self = shift;

	my $planned = $self->planned();

	#    PLANNED             int not null,
	#-- 0 = unplanned downtime; 1 = planned downtime

	return "unplanned" if $planned == 0;
	return "planned"   if $planned == 1;

	return $planned;
}

sub save {
	my $self = shift;

	if( $self->update() == 0 ) {
		my $data;
		foreach my $key ($self->attributes()) {
			$data->{$key} = $self->attribute($key) if($self->attribute($key));
		}
		my $t = ariba::monitor::DowntimeTransaction->newWithDetails($data);
		$t->save();
		return;
	}
}

#
# don't die if an exception is thrown
#
sub _croak {
	my ($self, $message, %info) = (@_);
	return;
}

=pod

=back

=head1 AUTHORS

Dan Sully <dsully@ariba.com>

=head1 DOCUMENTATION

PerlDoc by Alex Sandbak <asandbak@ariba.com>


=cut

1;
