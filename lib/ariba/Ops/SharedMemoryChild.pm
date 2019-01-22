# $Id: //ariba/services/tools/lib/perl/ariba/Ops/SharedMemoryChild.pm#14 $
#

package ariba::Ops::SharedMemoryChild;

use strict;
use ariba::util::SharedMemory;

my %_children = ();	# keep pointers to our children

my $join = "!@#UNiQuEtRiNg-=!";

sub new {
	my $class = shift;
	my $code = shift;
	my $outputLength = shift;

	my $coderef;

	if ( ref($code) ){
			$coderef = sub { &$code; };
	} else {
			$coderef = sub { eval $code; };
	}

	my $self = {
		'shareId' => undef,
		'coderef' => $coderef,
		'outputLength' => $outputLength,
		'exitValue' => undef,
		'returnValue' => undef,
		'pid' => undef,
		'tag' => undef,
	};

	bless($self, $class);

	return $self;
}

sub DESTROY {
	my $self = shift;

	# make sure we do not remove the shm segment
	# in the child, only do the remove in the parent process

	if ( $self->pid() ) {
		my $shm = $self->_sharedMemory();
		$shm->destroy() if ($shm);
		$self->_removeChild($self);
	}
}


sub _addChild {
	my $class = shift;
	my $object = shift;

	my $pid = $object->pid();

	$_children{$pid} = $object;
}

sub _removeChild {
	my $class = shift;
	my $object = shift;

	my $pid = $object->pid();

	delete($_children{$pid});
}

sub _childByPid {
	my $class = shift;
	my $pid = shift;


	return $_children{$pid};
}

sub _children {
	my $class = shift;
	return( values(%_children) );
}

sub _moreChildrenToReap {
	my $class = shift;

	for my $child ( $class->_children() ){
		unless ( defined( $child->exitValue() ) ) {
			return 1;
		}
	}
	return 0;
}

sub setTag {
	my $self = shift;
	$self->{'tag'} = shift;
}

sub tag {
	my $self = shift;
	return $self->{'tag'};
}

sub setPid {
	my $self = shift;
	$self->{'pid'} = shift;
}

sub pid {
	my $self = shift;
	return $self->{'pid'};
}

sub setExitValue {
	my $self = shift;
	$self->{'exitValue'} = shift;
}

sub exitValue {
	my $self = shift;
	return $self->{'exitValue'};
}

sub setReturnValue {
	my $self = shift;
	$self->{'returnValue'} = shift;
}

sub returnValue {
	my $self = shift;

	my $returnValue = $self->{'returnValue'};
	
	if ( defined($returnValue) ) {
		return @$returnValue;
	} else {
		return undef;
	}
}

sub _setSharedMemory {
	my $self = shift;
	$self->{'sharedMemory'} = shift;
}

sub _sharedMemory {
	my $self = shift;
	return $self->{'sharedMemory'};
}

sub _coderef {
	my $self = shift;
	return $self->{'coderef'};
}

sub _outputLength {
	my $self = shift;
	return $self->{'outputLength'};
}

sub run {
	my $self = shift;

	my $pid;

	my $shm = ariba::util::SharedMemory->new(undef, $self->_outputLength());

	unless($shm->create()) {
		warn "could not create shm segment! $!\n";
	}

	$self->_setSharedMemory($shm);

	unless($pid = fork() ) {

		# blow away all to parent objects
		# the copy of %_children in the PARENT process
		# is the only one we care about

		for my $pid ( keys %_children ) {
			my $obj = $_children{$pid};
			$obj->setPid(undef);
		}

		$? = 0;
		my $coderef = $self->_coderef();
		my @codeOutput = &$coderef;
		my $store = join($join, @codeOutput);	

		#if coderef lauched a subprocess, make sure we get its 
		#exit status
		my $exitStatus = $?/256;

		my $wrote = $shm->write($store);
		if (length($store) > $wrote) {
		    warn "Storing more than shared memory size! ";
		    warn "wrote $wrote < tried ", length($store), "\n";
		}

		exit($exitStatus);
	}

	$self->setPid($pid);

	my $class = ref($self);
	$class->_addChild($self);

}

sub waitForChildren {
	my $class = shift;
	my $count = shift || 999999;

	my @reapedChildren;

	my $childrenFound = 0;
	
		
	while( $childrenFound < $count &&
		$class->_moreChildrenToReap()
		)
	
	{	
		my $childpid = wait();
		last if($childpid == -1);

		my $child = $class->_childByPid($childpid);

		#
		# reaped child may not be a one of ours, 
		# could be a normal fork
		#
		if ( defined($child) ) {			
			$child->setExitValue( $?/256 );

			my $shm = $child->_sharedMemory();

			my $value = $shm->read();

			$shm->destroy();

			my @array = split(/$join/, $value);

			$child->setReturnValue([@array]);

			push(@reapedChildren, $child);

			$childrenFound++;
		}
	}
	return @reapedChildren;
}

# clean up possible leaked shared memory segments
sub mydie {
	my $class = shift;

	print STDERR "ERROR: ", join("", @_),"\n";
	print STDERR "ERROR: ===", join(" ", caller(1)),"\n";

	for my $child ( $class->_children() ) {
		my $shm = $child->_sharedMemory();

		$shm->destroy();
	}
}

1;
