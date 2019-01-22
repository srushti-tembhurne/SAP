#!/usr/local/bin/perl

#
# Fyst.pm
#
# Library that handles the FYST database -- can be used by other apps to
# register changes to the file system so that the security tool won't
# show them as being changed later.
#
# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Fyst.pm#4 $
#

package ariba::Ops::Fyst;

use DB_File;
use File::Basename qw ( dirname );
use ariba::util::Simplefind;
use dmail::LockLib;

my $lockfile = "/var/fyst/.fystcache.lock";
my $cachefile = "/var/fyst/fystdat.db";
my $errorCode = 0;

#
# Note this locks so that there can only be one open instance at a time.
#
sub openFystDB {
	my $class = shift;
	my $locktries = shift || 30;
	$errorCode = 0;

	dmail::LockLib::forceQuiet();
	unless (dmail::LockLib::requestlock($lockfile,$locktries)) {
		$errorCode = 2;
		return undef;
	}

	my $self = {};

	unless ( tie( %{$self->{'database'}}, 'DB_File', $cachefile, O_RDWR, 0600 ) ) {
		$errorCode = 1;
		dmail::LockLib::releaselock($lockfile);
		return undef;
	}

	bless( $self, $class );

	return( $self );
}

sub createFystDB {
	my $class = shift;
	my $locktries = shift || 30;
	$errorCode = 0;

	dmail::LockLib::forceQuiet();
	unless (dmail::LockLib::requestlock($lockfile,$locktries)) {
		$errorCode = 2;
		return undef;
	}

	my $self = {};

	unless ( tie( %{$self->{'database'}}, 'DB_File', $cachefile, O_CREAT|O_RDWR, 0600 ) ) {
		$errorCode = 1;
		dmail::LockLib::releaselock($lockfile);
		return undef;
	}

	bless( $self, $class );

	return( $self );
}

#
# delimiter for the directory content lists
#
sub contentDelimeter {
	my $class = shift;
	return ("\004");
}

#
# add or update fyst database info for a list of file entries.  Call this AFTER
# a file is added or updated.
#
# full pathnames (not relative ones) are REQUIRED
#
sub updateFiles {
	my $self = shift;
	my @f = @_;
	my %seen; # keep track of this to avoid doing extra work

	foreach my $file (@f) {
		my $dir = dirname( $file );
		unless ( $seen{$file} ) {
	  		$self->_statAndStore($file);
			$seen{$file} = 1;
	  	}
		unless( $seen{$dir} ) {
		  	$self->_statAndStore($dir);
		  	$seen{$dir} = 1;
		}
	}
}

#
# add/update an entire tree into the database.  Call this AFTER the directory
# tree is added or updated.
# full pathnames (not relative ones) are REQUIRED
#
sub updateDirectories {
	my $self = shift;
	my @d = @_;
	my @f;

	foreach my $dir (@d) {
		my $s;
		unless ( $s = ariba::util::Simplefind->new($dir) ) {
			next;
		}
		$s->setFollowSymlinks(0);
		$s->setReturnSpecialInResults(1);
		$s->setReturnDirsInResults(1);
		push( @f, ($dir, $s->find()) );
	}

	$self->updateFiles( @f );
}

#
# removes an entry from the database.  Can be called before OR after the delete
#
# full pathnames (not relative ones) are REQUIRED
#
sub deleteFiles {
	my $self = shift;
	my @f = @_;
	my %seen;

	foreach my $file (@f) {
		my $dir = dirname($file);
		unless( $seen{ $dir } ) {
			$self->_statAndStore($dir);
			$seen{$dir} = 1;
		}
		# deletes take priority over dir updates
		unless( $seen{$file} && $seen{$file} > 1 ) {
			$self->_removeStatData($f);
			$seen{$file} = 2;
		}
	}
}

#  
# removes a tree from the database.  Call BEFORE the tree is deleted, 
# since it uses the tree to update all the contained cache entries.
#
# full pathnames (not relative ones) are REQUIRED
#
# Note that this is called before the delete operation, you should also
# call updateFiles() on the parent directory after you do the delete to get
# the mtime/ctime change caused by the file deletes
#
sub deleteDirectories {
	my $self = shift;
	my @d = @_;
	my @f;

	foreach my $dir (@d) {
		my $s;
		unless ( $s = ariba::util::Simplefind->new($dir) ) {
			next;
		}
		$s->setFollowSymlinks(0);
		$s->setReturnSpecialInResults(1);
		$s->setReturnDirsInResults(1);
		push(@f, ($s->find, $dir) )
	}

	$self->deleteFiles( @f );
}

sub closeFystDB {
	my $self = shift;

	$self->{'_closed'} = 1;
	untie( %{$self->{'database'}} );
	dmail::LockLib::releaselock($lockfile);
}

sub DESTROY {
	my $self = shift;

	return if ( $self->{'_closed'} == 1 );
	$self->closeFystDB();
}

##################### calls for fyst itself #########################

sub loadDirData {
	my $self = shift;
	my $dir = shift;
	my $ret = {};

	$ret->{$dir} = {};
	$self->statDataFromDB($dir, $ret->{$dir});

	return($ret) unless($ret->{$dir}->{'contents'});

	my @contents = split($self->contentDelimeter(), $ret->{$dir}->{'contents'});
	foreach my $f (@contents) {
		$f = "$dir/$f";
		$ret->{$f} = {};
		$self->statDataFromDB($f, $ret->{$f});
	}

	return($ret);
}

sub statDataToDB {
	my $self = shift;
	my $file = shift;
	my $ref = shift;

	my $dat = _packStatData( $ref );
	$self->{'database'}->{$file} = $dat;
}

sub statDataFromDB {
	my $self = shift;
	my $file = shift;
	my $ref = shift;

	my $dat = $self->{'database'}->{$file};
	_unpackStatData( $ref, $dat );
}

sub _statAndStore {
	my $self = shift;
	my $file = shift;
	my %h;

	my @s = lstat( $file );
	$h{'mode'} = $s[2];
	$h{'uid'} = $s[4];
	$h{'gid'} = $s[5];
	$h{'size'} = $s[7];
	$h{'mtime'} = $s[9];
	$h{'ctime'} = $s[10];

	$self->statDataToDB($file, \%h);
}

#IMPORTANT: you can not call getFileCount while doing a getNextFile iteration
#perldoc -f each
#search for 'for each hash' to describe this.

#iterator that replaced fileList() which pulled all of the filenames into
#an array, which was not so good for memory consumption
sub getNextFile {
	my $self = shift;
	my $key = scalar each %{$self->{'database'}};
	return $key;
}

#the function of this method was previously provided by the
#fileList method, which returned every filename in an array.
#The length of that array was taken to get a file count.
#this replacement method calls the iterator with a simple counter.
sub getFileCount {
	my $self = shift;
	my $ct = 0;
	while(defined $self->getNextFile) {
		$ct++;
	}
	return $ct;
}

sub _removeStatData {
	my $self = shift;
	my $f = shift;

	delete( $self->{'database'}->{$f} );
}

sub errorCode {
	return $errorCode;
}

#################### internal utility functions ########################

sub _packStatData {
	my $ref = shift;
	my $dat;

	foreach my $k ( keys %$ref ) {
		if ( $dat ) {
			$dat .= "\002" . $k . "\003" . $ref->{$k};
		} else {
			$dat = $k . "\003" . $ref->{$k};
		}
	}

	return $dat;
}

sub _unpackStatData {
	my $ref = shift;
	my $dat = shift;

	return unless($dat);

	my ( @kp ) = split( '\002',$dat );
	foreach my $i ( @kp ) {
		my ( $k, $v ) = split( '\003',$i );
		$ref->{$k} = $v;
	}
}

1;
