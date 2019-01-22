package ariba::rc::dashboard::DB;

#
# SQLite database wrapper for RC Dashboard tables
#

use strict;
use warnings;
use vars qw ($AUTOLOAD);
use Carp;
use Data::Dumper;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../lib/perl";
use lib "$FindBin::Bin/../../bin";
use ariba::rc::AbstractDB;
use ariba::rc::dashboard::Constants;
use base ( "ariba::rc::AbstractDB" );
use Storable qw(dclone);

#
# Constructor
#
sub new {
    my ( $self ) = @_;
    return $self->SUPER::new();
}

# Return path to db file
sub get_dbfile {
    return exists $ENV{ 'DASHBOARD_DB' }
      ? $ENV{ 'DASHBOARD_DB' }
      : ariba::rc::dashboard::Constants::dashboard_db_file();
}

# Create DB
sub create_db {
    my ( $self ) = @_;
    $self->initialize();
    my $tablename = ariba::rc::dashboard::Constants::dashboard_db_table();

    my $query = <<FIN;
CREATE TABLE $tablename
(
    buildname VARCHAR(96) NOT NULL,
    milestone VARCHAR(32) NOT NULL,
    status VARCHAR(32),
    start_date INTEGER,
    end_date INTEGER,
    hostname VARCHAR(128),
    logfile BLOB,
    productname VARCHAR(96),
    branchname VARCHAR(96),
    releasename VARCHAR(96),
    servicename VARCHAR(32) NOT NULL,
    startDate VARCHAR(12),
    endDate VARCHAR(12),
    startTime VARCHAR(12),
    endTime VARCHAR(12),
    PRIMARY KEY (buildname, milestone, servicename)
);
FIN

    $self->{ 'dbh' }->do( $query );
}

#
# Create database indexes
#
sub create_indexes {
    my ( $self ) = @_;
    $self->initialize();
    my $tablename = ariba::rc::dashboard::Constants::dashboard_db_table();
    $self->{ 'dbh' }->do( "CREATE INDEX buildnameindex0 ON $tablename (buildname)" );
}

# Drop database table
sub drop_db {
    my ( $self ) = @_;
    $self->initialize();
    my $tablename = ariba::rc::dashboard::Constants::dashboard_db_table();
    $self->{ 'dbh' }->do( "DROP TABLE $tablename " );
}

# Insert Event object into DB
sub insert {
    my ( $self, $hashref ) = @_;
    $self->initialize();

    my $tablename = ariba::rc::dashboard::Constants::dashboard_db_table();

    my $query = "SELECT * from $tablename WHERE buildname=" . $self->quote( $hashref->{ 'buildname' } ) . " AND milestone=" . $self->quote( $hashref->{ 'milestone' } ) . " AND hostname=" . $self->quote( $hashref->{ 'hostname' } );

    my $data = $self->_fetch( $query );

    # use existing start date if start_date is 0: don't require the client
    # to keep track of start/end dates
    if ( ( exists $data->{ $hashref->{ 'buildname' } }->{ $hashref->{ 'milestone' } } ) && ( $hashref->{ 'status' } ne 'running' ) ) {
        $hashref->{ 'start_date' } = $data->{ $hashref->{ 'buildname' } }->{ $hashref->{ 'milestone' } }->{ 'start_date' };
        $hashref->{ 'startDate' }  = $data->{ $hashref->{ 'buildname' } }->{ $hashref->{ 'milestone' } }->{ 'startDate' };
        $hashref->{ 'startTime' }  = $data->{ $hashref->{ 'buildname' } }->{ $hashref->{ 'milestone' } }->{ 'startTime' };
    }

    my @values = (
        $self->quote( $hashref->{ 'buildname' } ),
        $self->quote( $hashref->{ 'milestone' } ),
        $self->quote( $hashref->{ 'status' } ),
        $self->quote( $hashref->{ 'start_date' } ),
        $self->quote( $hashref->{ 'end_date' } ),
        $self->quote( $hashref->{ 'hostname' } ),
        $self->quote( $hashref->{ 'logfile' } ),
        $self->quote( $hashref->{ 'productname' } ),
        $self->quote( $hashref->{ 'branchname' } ),
        $self->quote( $hashref->{ 'releasename' } ),
        $self->quote( $hashref->{ 'servicename' } ),
        $self->quote( $hashref->{ 'startDate' } ),
        $self->quote( $hashref->{ 'endDate' } ),
        $self->quote( $hashref->{ 'startTime' } ),
        $self->quote( $hashref->{ 'endTime' } ),
    );

    my $ok = $self->do( "REPLACE INTO $tablename VALUES (" . ( join ",", @values ) . ")" );
    return 0 unless $ok;

    my $id = $self->{ 'dbh' }->func( 'last_insert_rowid' );
    return $id;
}

sub fetch {
    my ( $self, $limit, $releasename, $productname, $searchbuild ) = @_;
    $self->initialize();

    # Generate select statement
    my $query;
    my $tablename = ariba::rc::dashboard::Constants::dashboard_db_table();

    if ( $searchbuild ) {
        $query = "SELECT * FROM $tablename  WHERE buildname like \"%$searchbuild%\"";
    }

    if ( $productname ) {
        $query = "SELECT * FROM $tablename  WHERE buildname in (select buildname FROM $tablename where productname like \"%$productname%\" and (hostname like \"%aries%\" or hostname like \"%penguin%\" or hostname like \"%emu%\" or hostname like \"%mars%\") ORDER BY start_date)";
    }

    if ( $releasename ) {
        $query = "SELECT * FROM $tablename  WHERE buildname in (select buildname FROM $tablename where releasename like \"%$releasename%\" and (hostname like \"%aries%\" or hostname like \"%penguin%\" or hostname like \"%emu%\" or hostname like \"%mars%\") ORDER BY start_date)";

        if ( $productname ) {
            $query = "SELECT * FROM $tablename  WHERE buildname in (select buildname FROM $tablename where productname like \"%$productname%\" and releasename like \"%$releasename%\" and (hostname like \"%aries%\" or hostname like \"%penguin%\" or hostname like \"%emu%\" or hostname like \"%mars%\") ORDER BY start_date)";
        }
    }

    if ( !$productname && !$releasename && !$searchbuild ) {
        $query = "SELECT * FROM $tablename WHERE buildname in (select buildname from $tablename where hostname like \"%mars%\" or hostname like \"%aries%\" or hostname like \"%penguin%\" or hostname like \"%emu%\") ORDER BY start_date DESC LIMIT $limit";
    }

    return $self->_fetch( $query );
}

sub data_for_graph {
    my ( $self, $limit, $searchbuild, $service ) = @_;
    $self->initialize();

    my $query;
    my $tablename = ariba::rc::dashboard::Constants::dashboard_db_table();

    if ( $searchbuild && !$service ) {
        $query = "SELECT * FROM $tablename  WHERE buildname = \'$searchbuild\' AND hostname not like \'%buildbox%\'";
    }

    if ( $searchbuild && $service ) {
        $query = "SELECT * FROM $tablename  WHERE buildname = \"$searchbuild\" and servicename = \'$service\' and hostname not like \"%buildbox%\" union select * from $tablename where buildname = \"$searchbuild\"  and hostname not like \"%buildbox%\" and \( milestone = \'compile\' or milestone = \'archive\' \)";
    }

    if ( !$searchbuild && !$service ) {
        $query = "SELECT * FROM $tablename WHERE buildname in (select buildname from $tablename where hostname like \"%mars%\" or hostname like \"%aries%\" or hostname like \"%penguin%\" or hostname like \"%emu%\") ORDER BY start_date DESC LIMIT $limit";
    }

    return $self->graph_fetch( $query );
}

sub _fetch {
    my ( $self, $query ) = @_;
    my $row = $self->{ 'dbh' }->selectall_arrayref( $query );
    my $timeline;

    while ( $#$row != -1 ) {
        my $listref = shift @$row;
        my $hashref = $self->coerce( $listref );
        $timeline->{ $hashref->{ 'buildname' } }->{ $hashref->{ 'milestone' } } = $hashref;
    }

    return $timeline;
}

sub graph_fetch {
    my ( $self, $query ) = @_;
    my $row = $self->{ 'dbh' }->selectall_arrayref( $query );

    my $timeline;

    while ( $#$row != -1 ) {
        my $listref = shift @$row;
        my $hashref = $self->coerce( $listref );
        $timeline->{ $hashref->{ 'buildname' } }->{ $hashref->{ 'servicename' } }->{ $hashref->{ 'milestone' } } = $hashref;
    }

    return $timeline;
}

sub get_trend_builds {
    my ( $self, $limit, $product, $service ) = @_;
    $self->initialize();

    my $tablename = ariba::rc::dashboard::Constants::dashboard_db_table();
    my $query     = "SELECT distinct buildname from $tablename where servicename = \'$service\' and productname = \'$product\' and hostname not like \"%buildbox%\" order by start_date  desc limit $limit ";
    my $row       = $self->{ 'dbh' }->selectall_arrayref( $query );

    return $row;
}

sub form_pair_hash {
    my $self = shift;
    my $row  = shift;

    my $trendline;
    while ( $#$row != -1 ) {
        my $listref = shift @$row;
        my $hashref = &{
            sub {
                my ( $buildref ) = @_;
                return {
                    'buildname'   => shift @$buildref,
                    'servicename' => shift @$buildref,
                    'milestone'   => shift @$buildref,
                    'end'         => shift @$buildref,
                    'start'       => shift @$buildref,
                };
              }
        }( $listref );
        $trendline->{ $hashref->{ 'buildname' } }->{ $hashref->{ 'servicename' } }->{ $hashref->{ 'milestone' } } = $hashref;
    }

    my $pair;
    foreach my $bld ( sort { $a cmp $b } keys %$trendline ) {
        next if ( !defined $bld );
        my @tempvalues = values %{ $trendline->{ $bld }->{ 'Build' } };
        foreach my $s ( sort { $a cmp $b } keys %{ $trendline->{ $bld } } ) {
            next if ( $s eq 'Build' );
            push @{ $pair->{ "$bld:$s" } }, values %{ $trendline->{ $bld }->{ $s } };
            push @{ $pair->{ "$bld:$s" } }, @{ dclone( \@tempvalues ) };
            #print Dumper @tempvalues;
        }
    }

    return $pair;
}

# Probably the shittiest sub routine you would have ever seen.
# Sorry, time crunch and I am low on caffine, could not think of anything better.
sub get_data_for_trend_pair {
    my ( $self, $limit, $rhjson, $wait ) = @_;
    $self->initialize();
    my $tablename = ariba::rc::dashboard::Constants::dashboard_db_table();
    my $length    = scalar ( @{ $rhjson } );

    my ( $trendline, $return );
    my @pair;

    for ( my $i = 0; $i < $length; $i++ ) {
        my $build   = @{ $rhjson }[ $i ]->{ 'build' };
        my $service = @{ $rhjson }[ $i ]->{ 'service' };
        push ( @pair, $build . ':' . $service );
        push ( @pair, $build . ':' . 'Build' );
    }

    my $pairstring = join ( "',", map "'$_", @pair );

    my $query = "select buildname, servicename, milestone, end_date, start_date, (buildname || ':' || servicename) as pair from $tablename  where pair in ( $pairstring\' )";
    my $row   = $self->{ 'dbh' }->selectall_arrayref( $query );

    $trendline = $self->form_pair_hash( $row );

    foreach my $pair ( keys %$trendline ) {
        my $length = scalar ( @{ $trendline->{ $pair } } );
        my ( $appstartStart, $appstartEnd, $rsyncWaitStart, $rsyncWaitEnd, $installWaitStart, $installWaitEnd, $prequalWaitStart, $prequalWaitEnd );
        for ( my $i = 0; $i < $length; $i++ ) {
            $return->{ $pair }->{ $trendline->{ $pair }[ $i ]->{ 'milestone' } } = ( $trendline->{ $pair }[ $i ]->{ 'end' } - $trendline->{ $pair }[ $i ]->{ 'start' } ) / 60;

            $appstartStart    = $trendline->{ $pair }[ $i ]->{ 'start' } if ( $trendline->{ $pair }[ $i ]->{ 'milestone' } eq 'install' );
            $appstartEnd      = $trendline->{ $pair }[ $i ]->{ 'end' }   if ( $trendline->{ $pair }[ $i ]->{ 'milestone' } eq 'restoremigrate' );
            $rsyncWaitStart   = $trendline->{ $pair }[ $i ]->{ 'start' } if ( $trendline->{ $pair }[ $i ]->{ 'milestone' } eq 'rsync' );
            $rsyncWaitEnd     = $trendline->{ $pair }[ $i ]->{ 'end' }   if ( $trendline->{ $pair }[ $i ]->{ 'milestone' } eq 'archive' );
            $installWaitStart = $trendline->{ $pair }[ $i ]->{ 'start' } if ( $trendline->{ $pair }[ $i ]->{ 'milestone' } eq 'install' );
            $installWaitEnd   = $trendline->{ $pair }[ $i ]->{ 'end' }   if ( $trendline->{ $pair }[ $i ]->{ 'milestone' } eq 'rsync-2' );
            $prequalWaitStart = $trendline->{ $pair }[ $i ]->{ 'start' } if ( $trendline->{ $pair }[ $i ]->{ 'milestone' } eq 'PreQual-LQ' );
            $prequalWaitEnd   = $trendline->{ $pair }[ $i ]->{ 'end' }   if ( $trendline->{ $pair }[ $i ]->{ 'milestone' } eq 'restoremigrate' );

            if ( defined ( $appstartStart ) && defined ( $appstartEnd ) ) {
                $return->{ $pair }->{ 'App-Start' } = ( $appstartEnd - $appstartStart ) / 60;
            }

            if ( $wait ) {
                $return->{ $pair }->{ 'rsync-archive-wait' }  = ( $rsyncWaitEnd - $rsyncWaitStart ) / 60     if ( defined ( $rsyncWaitStart )   && defined ( $rsyncWaitEnd ) );
                $return->{ $pair }->{ 'install-rsync2-wait' } = ( $installWaitEnd - $installWaitStart ) / 60 if ( defined ( $installWaitStart ) && defined ( $installWaitEnd ) );
                $return->{ $pair }->{ 'prequal-start-wait' }  = ( $prequalWaitEnd - $prequalWaitStart ) / 60 if ( defined ( $prequalWaitStart ) && defined ( $prequalWaitEnd ) );
            }
        }
    }

    return $return;
}

sub get_data_for_trend_build {
    my ( $self, $limit, $allbuilds, $service, $wait ) = @_;
    $self->initialize();

    my @builds = split ( ',', $allbuilds );
    my $prefix = " buildname = '";
    my $sep    = "' or";
    my $str    = join ( $sep, map "$prefix$_", @builds );

    my $tablename = ariba::rc::dashboard::Constants::dashboard_db_table();

    my $query = "select buildname, milestone, end_date, start_date from $tablename  where ( $str\' ) and ( servicename = \"$service\" or servicename = \'Build\' ) and hostname not like \"%buildbox%\" and milestone not like \"%MCL_%\" order by buildname";
    my $row   = $self->{ 'dbh' }->selectall_arrayref( $query );

    my $trendline;

    while ( $#$row != -1 ) {
        my $listref = shift @$row;
        my $hashref = $self->set_hash_ref_for_trend( $listref );
        $trendline->{ $hashref->{ 'buildname' } }->{ $hashref->{ 'milestone' } } = $hashref;
    }

    my $return;

    foreach my $build ( @builds ) {
        foreach my $key ( keys %{ $trendline->{ $build } } ) {
            $return->{ $build }->{ $key } = ( $trendline->{ $build }->{ $key }->{ 'end' } - $trendline->{ $build }->{ $key }->{ 'start' } ) / 60;
        }

        if ( exists ( $trendline->{ $build }->{ 'install' } ) && exists ( $trendline->{ $build }->{ 'restoremigrate' } ) ) {
            $return->{ $build }->{ 'App-Start' } =
              ( $trendline->{ $build }->{ 'install' }->{ 'end' } - $trendline->{ $build }->{ 'restoremigrate' }->{ 'end' } ) / 60;
        }

        if ( $wait ) {
            if ( exists ( $trendline->{ $build }->{ 'rsync' } ) && exists ( $trendline->{ $build }->{ 'archive' } ) ) {
                $return->{ $build }->{ 'rsync-archive-wait' } =
                  ( $trendline->{ $build }->{ 'rsync' }->{ 'start' } - $trendline->{ $build }->{ 'archive' }->{ 'end' } ) / 60;
            }

            if ( exists ( $trendline->{ $build }->{ 'install' } ) && exists ( $trendline->{ $build }->{ 'rsync-2' } ) ) {
                $return->{ $build }->{ 'install-rsync2-wait' } =
                  ( $trendline->{ $build }->{ 'install' }->{ 'start' } - $trendline->{ $build }->{ 'rsync-2' }->{ 'end' } ) / 60;
            }

            if ( exists ( $trendline->{ $build }->{ 'PreQual-LQ' } ) && exists ( $trendline->{ $build }->{ 'restoremigrate' } ) ) {
                $return->{ $build }->{ 'prequal-start-wait' } =
                  ( $trendline->{ $build }->{ 'PreQual-LQ' }->{ 'start' } - $trendline->{ $build }->{ 'restoremigrate' }->{ 'end' } ) / 60;
            }
        }
    }

    return $return;
}

sub set_hash_ref_for_trend {
    my ( $self, $buildref ) = @_;

    return {
        'buildname' => shift @$buildref,
        'milestone' => shift @$buildref,
        'end'       => shift @$buildref,
        'start'     => shift @$buildref,
    };

}

# Generate hashref from DB row
sub coerce {
    my ( $self, $listref ) = @_;

    return {
        'buildname'   => shift @$listref,
        'milestone'   => shift @$listref,
        'status'      => shift @$listref,
        'start_date'  => shift @$listref,
        'end_date'    => shift @$listref,
        'hostname'    => shift @$listref,
        'logfile'     => shift @$listref,
        'productname' => shift @$listref,
        'branchname'  => shift @$listref,
        'releasename' => shift @$listref,
        'servicename' => shift @$listref,
        'startDate'   => shift @$listref,
        'endDate'     => shift @$listref,
        'startTime'   => shift @$listref,
        'endTime'     => shift @$listref,
    };
}

# Expire records from db
sub expire_db {
    my ( $self ) = @_;
}

sub fetch_auto_data {
    my ( $self, $limit ) = @_;
    $self->initialize();

    # Generate select statement
    my $tablename = ariba::rc::dashboard::Constants::dashboard_db_table();
    my $query     = "SELECT buildname, productname, servicename, milestone from $tablename where hostname not like \'%buildbox%\' limit $limit";

    my $rows = $self->{ 'dbh' }->selectall_arrayref( $query );
    my $data;

    while ( $#$rows != -1 ) {
        my $listref = shift @$rows;
        my $hashref = &{
            sub {
                my ( $buildref ) = @_;
                return {
                    'build'     => shift @$buildref,
                    'product'   => shift @$buildref,
                    'service'   => shift @$buildref,
                    'milestone' => shift @$buildref,
                };
              }
        }( $listref );

        $data->{ $hashref->{ 'product' } }->{ $hashref->{ 'build' } }->{ $hashref->{ 'milestone' } } = $hashref;
    }

    foreach my $product ( keys %$data ) {
        foreach my $build ( keys %{ $data->{ $product } } ) {
            my @services = ();
            foreach my $milestone ( keys %{ $data->{ $product }->{ $build } } ) {
                my $service = $data->{ $product }->{ $build }->{ $milestone }->{ 'service' };
                push ( @services, $service ) unless ( $service eq '' );
                delete $data->{ $product }->{ $build }->{ $milestone };
            }
            push ( @{ $data->{ $product }->{ $build }->{ 'services' } }, unique( @services ) );
            delete $data->{ $product }->{ '' };
        }
        delete $data->{ '' };
    }

    return $data;
}

sub fetch_distinct_data {
    my ( $self, $limit ) = @_;
    $self->initialize();

    # Generate select statement
    my $tablename = ariba::rc::dashboard::Constants::dashboard_db_table();
    my @columns = ( 'productname', 'servicename', 'buildname' );

    my $data;
    foreach my $column ( @columns ) {
        my $query = "SELECT distinct ( $column )  FROM $tablename where hostname not like '%buildbox%' order by $column";
        my $rows  = $self->{ 'dbh' }->selectall_arrayref( $query );
        my @values;
        while ( $#$rows != -1 ) {
            my $listref = shift @$rows;
            push ( @values, shift @$listref );
        }

        push @{ $data->{ $column } }, @values;

    }

    return $data;
}

# Returns unique elements of an array
sub unique {
    return keys %{ { map { $_ => 1 } @_ } };
}

1;
