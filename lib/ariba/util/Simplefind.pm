#
# $Id: //ariba/services/tools/lib/perl/ariba/util/Simplefind.pm#9 $
#

package ariba::util::Simplefind;

use strict;
use DirHandle;
use POSIX;
#
# because use POSIX is missing these
#
# know to work: linux, solaris, hp-ux
#
sub S_IFLNK  { return 40960; }
sub S_ISLNK  { my $m = shift; return(($m & S_IFLNK) == S_IFLNK); }

sub new {
	my $class = shift;
	my $path = shift;
	my $self = {
		'showFiles'      => 1,
		'showDirs'       => 0,
		'showSpecial'    => 0,
		'debug'          => 0,
		'recurse'        => 1,
		'followSymlinks' => 1,
		'path'           => $path,
		'honorIgnore'    => 1,
		'found'          => [],
	};
	bless($self, $class);
	return($self);
}

sub find {
	my $self = shift;
	$self->resetFound();
	$self->_recurse($self->path());
	return($self->found());
}

sub _recurse {
	my $self = shift;
	my $path = shift;
	my $debug = $self->debug();
	my $showFiles = $self->returnFilesInResults();
	my $showDirs = $self->returnDirsInResults();
	my $willRecurse = $self->willRecurse();

	if ($self->honorIgnore()) {
		# the presence of the ignore file will cause all files and directories
		# to be ignored
		my $ignoreFile = "$path/" . $self->ignoreFileName();
		return if -f $ignoreFile;
	}

	my $d = DirHandle->new($path) || warn "Can't open $path: $!\n" && return;
	my @found = $d->read();
	$d->close();
	my $owner = $self->honorOwner();

	foreach (@found) {
		next if(/^\.{1,2}$/); # skip "." and ".."
		$_ = "$path/$_";

		# this saves us a stat call on every file to test symlink and
		# directory.
		my @stats = lstat($_);
		next unless(@stats); # somehow we are getting an undefined value here
		my $mode = $stats[2];

		if(S_ISLNK($mode) && $self->followSymlinks()) {
			$mode = (stat($_))[2]; # follow the symlink if it's a dir
			next if (!defined($mode)); # target of the link does not exist
		}

		#
		# Match file owner if requested
		#
		if ($owner && $stats[4] != $owner) {
			next;
		}


		if (S_ISDIR($mode)) {
			$self->_recurse($_) if($willRecurse);
			$self->addToFound($_) if ($showDirs);
			print STDERR "$_\n" if($debug);
		} elsif(S_ISREG($mode)) {
			$self->addToFound($_) if ($showFiles);
			print STDERR "$_\n" if($debug);
		} else {
			$self->addToFound($_) if ($self->returnSpecialInResults);
			print STDERR "$_\n" if($debug);
		}
	}
}

sub returnFilesInResults {
	my $self = shift;
	return($self->{'showFiles'});
}

sub setReturnFilesInResults {
	my $self = shift;
	my $set = shift;
	$self->{'showFiles'} = $set;
	return($self);
}

sub returnSpecialInResults {
	my $self = shift;
	return($self->{'showSpecial'});
}

sub setReturnSpecialInResults {
	my $self = shift;
	my $set = shift;
	$self->{'showSpecial'} = $set;
	return($self);
}

sub returnDirsInResults {
	my $self = shift;
	return($self->{'showDirs'});
}

sub setReturnDirsInResults {
	my $self = shift;
	my $set = shift;
	$self->{'showDirs'} = $set;
	return($self);
}

sub willRecurse {
	my $self = shift;
	return($self->{'recurse'});
}

sub setWillRecurse {
	my $self = shift;
	my $set = shift;
	$self->{'recurse'} = $set;
	return($self);
}

sub debug {
	my $self = shift;
	return($self->{'debug'});
}

sub setDebug {
	my $self = shift;
	my $set = shift;
	$self->{'debug'} = $set;
	return($self);
}

sub found {
	my $self = shift;
	return(@{$self->{'found'}});
}

sub addToFound {
	my $self = shift;
	my (@new) = (@_);
	push(@{$self->{'found'}}, @new);
	return($self);
}

sub resetFound {
	my $self = shift;
	$self->{'found'} = [];
	return($self);
}

sub path {
	my $self = shift;
	return($self->{'path'});
}

sub setPath {
	my $self = shift;
	my $path = shift;
	$self->{'path'} = $path;
	return($self);
}

sub setFollowSymlinks {
	my $self = shift;
	my $set = shift;
	$self->{'followSymlinks'} = $set;
	return($self);
}

sub followSymlinks {
	my $self = shift;
	return($self->{'followSymlinks'});
}

sub honorIgnore {
	my $self = shift;
	return ($self->{'honorIgnore'});
}

sub setHonorIgnore {
	my $self = shift;
	my $set = shift;
	$self->{'honorIgnore'} = $set;
}

sub ignoreFileName {
	my $self = shift;

	return ".simplefind-ignore";
}

sub honorOwner {
	my $self = shift;
	return ($self->{'honorOwner'});
}

sub setHonorOwner {
	my $self = shift;
	my $set = shift;

	$self->{'honorOwner'} = $set;
}



1;

__END__

=head1 NAME

ariba::util::Simplefind - recursive depth-first find


=head1 SYNOPSIS

  use ariba::util::Simplefind;
  my $sf = ariba::util::Simplefind->new($path);
  my @files = $sf->find();
  $sf->setReturnDirsInResults(1);
  $sf->setReturnFilesInResults(0);
  my @dirs = $sf->find();
  

=head1 DESCRIPTION

Use this module to do a breadth-first find for files in a directory.  Its
advantage to File::Find is it can handle any character in the filename,
including newlines.

=head2 EXPORT

None by default.

=head2 METHODS

$sf->find()

  Execute a find with current settings (see below).  Returns a list of results.

$sf->setReturnFilesInResults()

  When set to true, results will include files.  This is the default.
  Symlinks to files are reported if this is true.

$sf->returnFilesInResults()

  Returns current setting.

$sf->setReturnSpecialInResults()

  When set to true, results will include special entries, such as pipes, 
  sockets, character devices and block devices.  Off by default.
  Symlinks are "special" if followSymlinks is NOT set.

$sf->returnSpecialInResults()

  Returns current setting.

$sf->setReturnDirsInResults()

  When set to true, results will include directories.  Off by default.
  Symlinks to directories are reported if this is true.

$sf->returnDirsInResults()

  Returns current setting.

$sf->setWillRecurse()

  When set to true, find() will recurse into subdirectories.  This is the 
  default.

$sf->willRecurse()

  Returns current setting.

$sf->setDebug()

  When set to true, will display progress to STDOUT.  Off by default.

$sf->debug()

  Returns current setting.

$sf->found()

  Returns files already found by calling $sf->find().  Returns undef if find 
  has not yet been called.

$sf->setPath($path)

  Use this to set the path find() will use.

$sf->path()

  Returns current pathname.

$sf->setFollowSymlinks()

  When set to true, will recurse into symlinks to directories.  This is the 
  default.  When this is set, symlinks are categorized by what they point to,
  meaning that a symlink to a file is shown or not shown based on the
  showFilesInResult setting.  When this is NOT set, then symlinks are shown
  or not shown based on the showSpecialInResult setting.

$sf->followSymlinks()

  Returns the current setting.

$sf->ignoreFileName()

  Returns the name of the ignore file

$sf->setHonorIgnore()
$sf->honorIgnore()

  Setter/getter for honorIgnore state, by default this returns true.  When
  set to true, if there exists an ignore file in a directory the contents of
  said directory and any subdirectories will not show up in the find results.

=head1 AUTHOR

Chris Jones <cjones@ariba.com>

=head1 SEE ALSO

L<perl>, File::Find

=cut
