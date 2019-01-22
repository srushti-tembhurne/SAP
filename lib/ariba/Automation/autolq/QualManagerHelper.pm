package ariba::Automation::autolq::QualManagerHelper;

use strict;
use ariba::Ops::PersistantObject;
use base qw(ariba::Ops::PersistantObject);

sub dir {
       my $class = shift;
       return "/home/rc/autolq/QualManagerHelper";
}

sub setAttribute {
    my $self = shift;
    my $attribute = shift;
    my @value = @_;

	$self->SUPER::setAttribute($attribute, @value);
	$self->save();
}

sub expire {
    my $self = shift;
    my $dir = $self->dir();
    my $instance = $self->instance();

    my $out = `rm $dir/$instance`;
    if ($out)
    {
        print "Warning: Unable to remove $dir/$instance. Will not expire this object \n";
        return;
    }
}


1;


