package ariba::Automation::RobotCommunicator;

use ariba::Ops::PersistantObject;
use base qw(ariba::Ops::PersistantObject);

use ariba::Automation::Constants;
use ariba::Automation::GlobalState;

# 
# use new() constructor from PersistantObject
#
sub validAccessorMethods {
	my $class = shift;

	my %methods = map { $_, undef } qw(
			pauseRequested pauseAtActionRequested resumeRequested stopRequested 
			);

	return \%methods;
}

sub new {
	my $class = shift;

	my $self = $class->SUPER::new('rbc');
	# I have seen inconsistant results from subsequent calls to new that 
	# happen fairly close (in time) to one another.  I believe it has something
	# to do with PO modification time checking.  This resolves that.
	$self->readFromBackingStore();

	return $self;
}

sub dir {
	my $class = shift;

	return ariba::Automation::Constants::communicatorDirectory();
}

sub pause {
	my $self = shift;

	$self->setPauseRequested(1);

	$self->save();

	return 1;
}

sub ackPause {
	my $self = shift;

	$self->setPauseRequested(0);
	$self->save();

	return 1;
}

sub pauseAtAction {
	my $self = shift;
	my $action = shift;

	$self->setPauseAtActionRequested($action);

	$self->save();

	return 1;
}

sub ackPauseAtAction {
	my $self = shift;

	$self->setPauseAtActionRequested();

	$self->save();

	return 1;
}

sub resume {
	my $self = shift;

	$self->setResumeRequested(1);
	$self->save();

	return 1;
}

sub ackResume {
	my $self = shift;

	$self->setResumeRequested(0);
	$self->save();

	return 1;
}

sub stop {
	my $self = shift;

	$self->setStopRequested(1);
	$self->save();

	return 1;
}

sub ackStop {
	my $self = shift;

	$self->setStopRequested(0);
	$self->save();

	return 1;
}

1;
