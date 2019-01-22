package ariba::Automation::Releases2;

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
    my $MINIMUM_VERSION_REQUIRED = '2.0';
    my $TYPE_MAINLINE = "mainline";
    my $TYPE_QUAL = "qual";
    my %REWRITE_PRODUCT = 
    (
        "s4" => "asm", 
    );
    #
    # Constructor
    #
    sub new
    {
        my ($class, $file, $robot_type) = @_;

		$robot_type = $robot_type || $TYPE_MAINLINE;

        #
        # Handy for local debugging
        #
        if (exists $ENV{'RC_RELEASES_CONF'})
        {
            $file = $ENV{'RC_RELEASES_CONF'};
        }

        my $self = {};
        bless ($self,$class);
        my $ok = $self->parse_releases ($file, $robot_type);
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
    # Parse release.xml facade
    #
    sub parse_releases
    {
        my ($self, $file, $robot_type) = @_;

        eval
        {
            $self->_parse_config_file ($file, $robot_type);
        };

        if ($@)
        {
            carp ref ($self) . " failed parsing $file :$@\n";
            return 0;
        }

        return 1;
    }

    #
    # Private config parser 
    #
    sub _parse_config_file
    {
        my ($self, $file, $robot_type) = @_;
        my $xs = new XML::Simple();
        my $tree = $xs->XMLin ($file);

        if ($tree->{'version'} < $MINIMUM_VERSION_REQUIRED)
        {
            carp ref ($self) . " Warning: Configuration file is version " . $tree->{'version'} . ", wanted " . 
                $MINIMUM_VERSION_REQUIRED . "\n";
        }

        foreach my $builds (@{$tree->{'build'}})
        {
            my ($product, $release, $type, $group) = 
            (
                $builds->{'product'},
                $builds->{'release'},
                $builds->{'type'},
                $builds->{'group'},
            );

            $group = $group || 0;
            $self->{'groups'}->{$release}->{$product}->{$type}->{$group} = 1;
            
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

                    if ($type eq $robot_type)
                    {
                        $self->{'releases'}->{$release}->{$product}->{$group}->{$role} = $host;
                    }

                    $self->{'roles'}->{$host} = [ $release, $product, $role, $type, $group ];

                    #
                    # Map of robot type => host
                    #
                    $self->{'types'}->{$group}->{$type}->{$host} = 1;

                    # 
                    # Maps of host <=> instance and vice-versa
                    #
                    $self->{'hosts'}->{$host} = $robot_name;
                    $self->{'instances'}->{$robot_name} = $host;
                }
            }
        }
    }

    #
    # Fetch hostname ("buildbox57.ariba.com") given instance ("robot57")
    #
    sub get_host_by_instance
    {
        my ($self, $instance) = @_;
        return exists $self->{'instances'}->{$instance} ? $self->{'instances'}->{$instance} : "";
    }

    #
    # Fetch instance ("robot57") given hostname ("buildbox57.ariba.com")
    #
    sub get_instance_by_host
    {
        my ($self, $host) = @_;
        return exists $self->{'hosts'}->{$host} ? $self->{'hosts'}->{$host} : "";
    }

    #
    # Get hash containing all robots and related data 
    #
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

    #
    # Given a hostname, return the robot's role
    #
    sub get_robot_role
    {
        my ($self, $host) = @_;
        return $self->{'roles'}->{$host};
    }

    #
    # Get list of all releases ("10s2", etc.)
    #
    sub get_releases
    {
        my ($self) = @_;
        return sort { versioncmp($a, $b) } keys %{$self->{'releases'}} if $self->{'_initialized'};
    }

    #
    # Get list of all products ("asm", "buyer")
    #
    sub get_products
    {
        my ($self, $release) = @_;
        return sort keys %{$self->{'releases'}->{$release}} if $self->{'_initialized'};
    }

    #
    # Get all robots for a given product, release and optionally group
    #
    sub get_robots
    {
        my ($self, $release, $product, $group) = @_;
        $group = $group || 0;
        return %{$self->{'releases'}->{$release}->{$product}->{$group}} if $self->{'_initialized'};
    }

    #
    # Get list of groups given release, product and type
    #
    sub get_groups
    {
        my ($self, $release, $product, $type) = @_;
        $product = exists $REWRITE_PRODUCT{$product} ? $REWRITE_PRODUCT{$product} : $product;
        return sort { $a <=> $b } keys %{$self->{'groups'}->{$release}->{$product}->{$type}};
    }

    #
    # Get all mainline robots given an optional group (defaults to first group)
    #
    sub get_mainline_robots
    {
        my ($self, $group) = @_;
        $group = $group || 0;
        return %{$self->{'types'}->{$group}->{$TYPE_MAINLINE}};
    }

    #
    # Get all RC qual robots given an optional group (defaults to first group)
    #
    sub get_rc_buildqual_robots
    {
        my ($self, $group) = @_;
        $group = $group || 0;
        return %{$self->{'types'}->{$group}->{$TYPE_QUAL}};
    }
}

1;
