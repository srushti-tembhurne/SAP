package ariba::Ops::DBUtils;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/DBUtils.pm#3 $

use strict;
use DBD::Oracle qw(:ora_types);

$| = 1;

sub deleteRowsFromTable {
	my ($dbh, $table, $rowIds) = @_;

	my $sth = $dbh->prepare(sprintf( "DELETE FROM %s WHERE ID = ?", $table));

	for my $rowId (@$rowIds) {

		$sth->execute($rowId) or die $dbh->errstr();
	}

	$sth->finish();

	# not sure what to return here
	return 1;
}

sub copyRowToTable {
	my ($dbh, $sourceTable, $destTable, $nonBlobColumnsSQL, $blobColumns, $rowIds) = @_;

	my $sth = $dbh->prepare(sprintf(
		"INSERT INTO %s (%s) SELECT %s FROM %s WHERE ID = ?",
		$destTable, $nonBlobColumnsSQL, $nonBlobColumnsSQL, $sourceTable,
	));

	print "\nCopying from $sourceTable -> $destTable\n";

	# do the initial copy to the temporary table.
	my $error = 0;
	for my $rowId (@$rowIds) {

		print "\trow: $rowId\n";

		$sth->execute($rowId) or die $dbh->errstr();

		# and now handle the blob columns
		for my $column (@$blobColumns) {

			my $sblob = $dbh->selectrow_array("SELECT $column FROM $sourceTable WHERE ID = $rowId");

			print "\t\tBLOB in column $column of size ", length($sblob), " bytes: ";

			my $bsth = $dbh->prepare_cached("UPDATE $destTable SET $column = ? WHERE ID = ?");

			$bsth->bind_param(1, $sblob, { ora_type => ORA_BLOB }) || die $dbh->errstr();
			$bsth->bind_param(2, $rowId) || die $dbh->errstr();
			$bsth->execute();

			my $dblob = $dbh->selectrow_array("SELECT $column FROM $destTable WHERE ID = $rowId");

			unless ($sblob eq $dblob) {
				printf("ERROR - BLOB in $destTable NOT EQUAL to original!: [%d] bytes.\n", length($dblob));
				$error = 1;
			} else {
				print "ok!\n";
			}

			$bsth->finish();
		}
	}

	$sth->finish();

	if ( $error ) {
		return undef;
	} else {
		return 1;
	}
}

sub verifyRowCopy {
	my ($dbh, $sourceTable, $destTable, $nonBlobColumnsSQL, $columnNames, $rowIds) = @_;

	my $ssth = $dbh->prepare(sprintf("SELECT %s FROM %s WHERE ID = ?", $nonBlobColumnsSQL, $sourceTable));
	my $dsth = $dbh->prepare(sprintf("SELECT %s FROM %s WHERE ID = ?", $nonBlobColumnsSQL, $destTable));

	print "\nVerifying copy from $sourceTable -> $destTable\n";

	my $error = 0;
	for my $rowId (@$rowIds) {

		print "\trow: $rowId - ";

		$ssth->execute($rowId) or die $dbh->errstr();
		$dsth->execute($rowId) or die $dbh->errstr();

		my $sourceRow = $ssth->fetchrow_arrayref();
		my $destRow   = $dsth->fetchrow_arrayref();


		for (my $i = 0; $i < scalar @$sourceRow; $i++) {

			# we're ok here.
			next if $sourceRow->[$i] eq $destRow->[$i];

			printf("Warning! Column: %s value: [%s] doesn't equal [%s] in destination!\n",
				$columnNames->[$i], $sourceRow->[$i], $destRow->[$i]
			);

			$error = 1;
		}

		print "ok!\n" unless $error;
	}

	$ssth->finish();
	$dsth->finish();

	if ( $error ) {
		return undef;
	} else {
		return 1;
	}
}

sub findColumnsForTable {
	my $dbh    = shift;
	my $schema = shift;
	my $table  = shift;

	my $sth    = $dbh->column_info(undef, $schema, $table) || return;

	my @tableData  = ();

	while (my $row = $sth->fetchrow_hashref()) {

		my $colName = $row->{'COLUMN_NAME'};
		my $type    = $dbh->type_info($row->{'DATA_TYPE'})->{'TYPE_NAME'};

		if (defined $row->{'COLUMN_SIZE'} && $type ne 'BLOB' && $type ne 'DATE') {

			my $size = $row->{'COLUMN_SIZE'};

			if ( defined $row->{'DECIMAL_DIGITS'} ) {
				$size .= "," . $row->{'DECIMAL_DIGITS'};
			}

			$type .= "(" . $size . ")";
		}

		# this is really a NUMBER in Oracle.
		if ($type =~ /DOUBLE/) {
			$type = 'DOUBLE PRECISION';
		}

		my $null = $row->{'NULLABLE'} ? 'NULL' : 'NOT NULL';

		push @tableData, [ $colName, $type, $null ];
	}

	$sth->finish();

	return \@tableData;
}

1;

__END__
