package ariba::Automation::ExecuteScriptAction	;

use warnings;
use strict;
use ariba::Automation::Action;
use ariba::rc::Globals;
use File::Basename;
use Ariba::P4;

use base qw(ariba::Automation::Action);

my $logger = ariba::Ops::Logger->logger();

sub validFields {
	my $class = shift;

	my $fieldsHashRef = $class->SUPER::validFields();

	$fieldsHashRef->{'buildName'} = 1;
	$fieldsHashRef->{'productName'} = 1;
	$fieldsHashRef->{'command'} = 1;

	return $fieldsHashRef;

}

sub execute {
    my $self = shift;
    
    my $logger = ariba::Ops::Logger->logger();
    my $logPrefix = $self->logPrefix();
    
    my $service = ariba::Automation::Utils->service();
    
    my $rawCommand = $self->command();
    my $newCommand = $self->fixCommand($rawCommand, $logger);
    $logger->info("$logPrefix Running UserCommand: $newCommand");
	
    return unless ($self->executeSystemCommand($newCommand));
    $logger->info("$logPrefix UserCommand completed successfully");
}


sub fixCommand {
    my ($self, $command, $logger) = @_;
    my @final = ();
    my $actual;

    chomp($command);    
    my @values = split(/\s+/, $command);
    
    foreach my $val (@values) {
	if($val =~ /\[/)  {
	    my $actual;
	    my ($temp1, $temp2) =  split (/[\[\]]/, $val);
	    
	    my $str = "\$actual = \$self->".$temp2."();";
	    eval "$str";

	    if ($@) {
	    	$logger->error("Error in evaluating $str: $@");
	    	return;
	    }
	    
	    if($actual) {
		push(@final, $actual);
	    }
	    else {
		$logger->error("Could not determine the value of $val");
		return;
	    }
	}
	else {
	    push(@final, $val);
	}
    }
    
    my $finalCommand = join(' ', @final); 
    return $finalCommand;
}

1;
