package ariba::Automation::Releases;

# parse release.conf and provide information about 
# mainline robots

use strict;
use warnings;
use vars qw ($AUTOLOAD);
use Carp;
use Data::Dumper;
use Sort::Versions;
use XML::Simple;

{
    my $TYPE_MAINLINE = "mainline";
    my $TYPE_QUAL = "qual";

    #
    # Constructor
    #
    sub new
    {
        my ($class, $file) = @_;

        #
        # Handy for local debugging
        #
        if (exists $ENV{'RC_RELEASES_CONF'})
        {
            $file = $ENV{'RC_RELEASES_CONF'};
        }

        my $self = {};
        bless ($self,$class);
        my $ok = $self->parse_releases ($file);
        $self->{'_initialized'} = $ok;
        return $self;
    }
    
    #
    # Accessors
    #
    sub AUTOLOAD
    {
        no strict "refs";
        my ($self, $newval) = @_;

        my @classes = split /::/, $AUTOLOAD;
        my $accessor = $classes[$#classes];

        if (exists $self->{$accessor})
        {
            if (defined ($newval))
            {
                $self->{$accessor} = $newval;
            }
            return $self->{$accessor};
        }
        carp "Unknown method: $accessor\n";
    }

    #
    # Destructor
    #
    sub DESTROY
    {
        my ($self) = @_;
    }

    #
    # Parse release.xml
    #

    sub parse_releases
    {
        my ($self, $file) = @_;

        eval
        {
            $self->_parse_config_file ($file);
        };

        if ($@)
        {
            carp ref ($self) . " failed parsing $file :$@\n";
            return 0;
        }

        return 1;
    }

    sub _parse_config_file
    {
        my ($self, $file) = @_;
        my $xs = new XML::Simple();
        my $tree = $xs->XMLin ($file);

        foreach my $builds (@{$tree->{'build'}})
        {
            my ($product, $release, $type) = 
            (
                $builds->{'product'},
                $builds->{'release'},
                $builds->{'type'},
            );
            
            foreach my $tag (keys %{$builds->{'robots'}})
            {
                foreach my $robot (@{$builds->{'robots'}->{$tag}})
                {    
                    my ($role, $host, $robot_name) = 
                    (
                        $robot->{'role'},
                        $robot->{'instance'}->{'host'},
                        $robot->{'instance'}->{'content'},
                    );

                    if ($type eq $TYPE_MAINLINE)
                    {
                        $self->{'releases'}->{$release}->{$product}->{$role} = $host;
                    }

                    $self->{'roles'}->{$host} = [ $release, $product, $role, $type ];
                    $self->{'types'}->{$type}->{$host} = 1;
                    $self->{'hosts'}->{$host} = $robot_name;
                    $self->{'instances'}->{$robot_name} = $host;
                }
            }
        }
    }

    sub get_host_by_instance
    {
        my ($self, $instance) = @_;
        return exists $self->{'instances'}->{$instance} ? $self->{'instances'}->{$instance} : "";
    }

    sub get_instance_by_host
    {
        my ($self, $host) = @_;
        return exists $self->{'hosts'}->{$host} ? $self->{'hosts'}->{$host} : "";
    }

    sub get_all_robots
    {
        my ($self) = @_;
        my %robots;
        foreach my $host (keys %{$self->{'roles'}})
        {
            $robots{$host} = $self->{'roles'}->{$host};
        }
        return \%robots;
    }

    sub get_robot_role
    {
        my ($self, $host) = @_;
        return $self->{'roles'}->{$host};
    }

    sub get_releases
    {
        my ($self) = @_;
        return sort { versioncmp($a, $b) } keys %{$self->{'releases'}} if $self->{'_initialized'};
    }

    sub get_products
    {
        my ($self, $release) = @_;
        return sort keys %{$self->{'releases'}->{$release}} if $self->{'_initialized'};
    }

    sub get_robots
    {
        my ($self, $release, $product) = @_;
        return %{$self->{'releases'}->{$release}->{$product}} if $self->{'_initialized'};
    }

    sub get_mainline_robots
    {
        my ($self) = @_;
        return %{$self->{'types'}->{$TYPE_MAINLINE}};
    }

    sub get_rc_buildqual_robots
    {
        my ($self) = @_;
        return %{$self->{'types'}->{$TYPE_QUAL}};
    }

	sub get_groups
	{
		return ( 0 );
	}
}

1;
