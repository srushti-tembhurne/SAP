package ariba::Automation::autolq::Config;

#
# parse autolq.conf 
#

use strict;
use warnings;
use vars qw ($AUTOLOAD);
use Carp;
use Data::Dumper;
use XML::Simple;

{
    #
    # Constructor
    #
    sub new
    {
        my ($class, $file) = @_;
        my $self = {};
        bless ($self,$class);
        my $ok = $self->parse_config ($file);
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
    # Accessors
    #
	sub get_deployment_names
	{
		my ($self) = @_;
		return $self->{'deployment_names'};
	}

	sub get_deployment
	{
		my ($self, $deployment_name) = @_;
		return $self->{'deployments'}->{$deployment_name};
	}

	sub get_branch_name
	{
		my ($self, $product, $release) = @_;
		return $self->{'branches'}->{$product}->{$release};
	}

	sub get_products
	{
		my ($self) = @_;
		my @products = keys %{$self->{'products'}};
		return \@products;
	}

	sub get_releases
	{
		my ($self, $product) = @_;
		my @releases = keys %{$self->{'products'}->{$product}};
		return \@releases; 
	}

	sub get_qualrobots
	{
		my ($self, $product, $release) = @_;
		return $self->{'robots'}->{$product}->{$release};
	}

	sub get_owner
	{
		my ($self, $deployment) = @_;
		my $ownerString = $self->{'owners'}->{$deployment};
		my @list = split(/,/,$ownerString);
		my $finalOwnerList;
		foreach my $owner (@list)
		{
			$owner =~ s/\s+//g;
			$owner .= '@ariba.com'	if ($owner !~ /\@ariba\.com/);
            $finalOwnerList .= ",$owner" if ($finalOwnerList);
			$finalOwnerList .= "$owner" if (!$finalOwnerList);
		}
		return $finalOwnerList;
	}

	#
	# Parse configuration file: Convert XML tree to data structures required by caller
	#
	sub parse_config
    {
        my ($self, $file) = @_;
        $file = $file || $self->{'file'};

		# Sync this file from P4 so as to get the latest
		$ENV{P4USER}="rc";
		$ENV{P4CLIENT}="Release_ADMIN_UNIX";
		`/usr/local/bin/p4 sync $file`;

        my $xs = new XML::Simple();
        my $tree = $xs->XMLin ($file);
		
		#
		# Extract deployments from XML
		# To DO: We'll need to resturctu this hash properly.
		# The current sturcture is not scalable.
		my (%deployments, @deployment_names, %owners, %pause);
		foreach my $dep_data (@{$tree->{'deployments'}})
		{
			foreach my $dep_tag (keys %$dep_data)
			{
				my $name = $dep_data->{$dep_tag}->{'name'};
				push @deployment_names, $name;

				my $owner = $dep_data->{$dep_tag}->{'owner'};
				$owners{$name} = $owner;	

				my $pauseAfterDeploy = $dep_data->{$dep_tag}->{'pauseAfterDeployment'};
				$pause{$name} = $pauseAfterDeploy if $pauseAfterDeploy;	

				foreach my $dep (@{$dep_data->{$dep_tag}->{'build'}})
				{
					push @{$deployments{$name}}, $dep;
				}
			}
		}

		#
		# Extract products/robots from XML
		#
		my (%products, %branches, %robots);
		foreach my $prod_name (keys %{$tree->{'products'}->{'product'}})
		{
			my $ptree = $tree->{'products'}->{'product'}->{$prod_name}->{'release'};
			foreach my $release (keys %$ptree)
			{
				push @{$products{$prod_name}{$release}}, $ptree->{$release};

				#
				# Map product/release to branch e.g.
				# 
				# s4 => 11s1 => //ariba/asm/build/11s1
				#
				$branches{$prod_name}{$release} = $ptree->{$release}->{'branch'};

				#
				# Map product/release to qual robots e.g.
				#
				# ssp => 11s2 => [ robot107, robot108 ]
				#
				my $robots = $ptree->{$release}->{'qualrobots'}->{'robot'};
				push @{$robots{$prod_name}{$release}}, @$robots;
			}
		}

		#
		# Keep reference to various useful data structures
		#
		$self->{'deployment_names'} = \@deployment_names;
		$self->{'deployments'} = \%deployments;
		$self->{'products'} = \%products;
		$self->{'branches'} = \%branches;
		$self->{'robots'} = \%robots;
		$self->{'owners'} = \%owners;
		$self->{'pause'} = \%pause;
	
		1;
	}
}

1;
