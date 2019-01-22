package ariba::rc::dashboard::Config;

#
# Transform /home/rc/etc/dashboard.xml into tree
#

use strict;
use warnings;
use Carp;
use Data::Dumper;
use XML::Simple;

{
    #
    # Constructor
    #
    sub new
    {
        my ($class, $config_file) = @_;

        $config_file = $config_file || $ENV{'DASHBOARD_CONFIG'} || ariba::rc::dashboard::Constants::dashboard_config_file();

        my $self = 
        {
            'config_file' => $config_file,
            'order' => [],
            'milestones' => {}, 
        };

        bless ($self, $class);
        return $self;
    }

    #
    # Return data structure representing dashboard.xml
    #
    sub parse
    {
        my ($self) = @_;

        my $xs = new XML::Simple();
        my $tree = $xs->XMLin ($self->{'config_file'});

        my $milestones = $tree->{'timeline'}->{'milestone'};
        my %ordered;

        foreach my $milestone (keys %$milestones)
        {
            my $derp = $milestones->{$milestone};
            $derp->{'name'} = $milestone;
            $self->{'milestones'}->{$milestone} = 1;
            push @{$ordered{$milestones->{$milestone}->{'order'}}}, $derp;
        }

        my @ordered;
        foreach my $order (sort { $a <=> $b } keys %ordered)
        {
            push @ordered, @{$ordered{$order}};
        }

        return \@ordered;
    }

    #
    # Return true if milestone defined in dashboard.db
    #
    sub is_valid_milestone
    {
        my ($self, $milestone) = @_;
        return exists $self->{'milestones'}->{$milestone} ? 1 : 0;
    }

}

1;
