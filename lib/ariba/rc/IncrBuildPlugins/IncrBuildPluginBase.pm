package ariba::rc::IncrBuildPlugins::IncrBuildPluginBase;

use strict;
use warnings;
use ariba::rc::CompMeta;
use File::Basename;

sub new {
    my $class = shift;
    my $productUniverseMapRef = shift;
    my $incrBuildMgr = shift;
    my $self = {};
    bless ($self, $class);

    if ($incrBuildMgr) {
        $self->{'incrBuildMgr'} = $incrBuildMgr;
    }

    if ($productUniverseMapRef) {
        $self->_loadPlugins($productUniverseMapRef);
    }
    return $self;
}

# Load the plugins member which is a reference to list of instances of IncrBuildPluginBase that exist in
# ariba/rc/IncrBuildPlugins/*Plugin.pm
# Input 1: A hash reference where keys are component names and values are CompMeta references.
sub _loadPlugins {
    my ($self, $productUniverseMapRef) = @_;

    my %rebuildRequiredPlugins = ();
    my $dir;

    foreach my $d (@INC) {
        if ( -e "$d/ariba/rc/IncrBuildPlugins/IncrBuildPluginBase.pm" ) {
            $dir = $d;
            last;
        }
    }

    opendir(D, "$dir/ariba/rc/IncrBuildPlugins");
    while(my $f = readdir(D)) {
        next unless($f =~ s/Plugin\.pm$/Plugin/);

        my $package = "ariba::rc::IncrBuildPlugins::$f";
        eval "use $package";
        if($@) {
            print "IncrBuildPluginBase: Failed to load $package.";
            die($@);
        }
        $rebuildRequiredPlugins{$f} = $package->new(undef, $self->{'incrBuildMgr'} );
    }
    closedir(D);

    $self->{'plugins'} = \%rebuildRequiredPlugins;

    foreach my $name (keys %rebuildRequiredPlugins) {
        my $plgin = $rebuildRequiredPlugins{$name};
        if ($plgin) {
            print "IncrBuildPlugins: initializing $name\n";
            $plgin->_preloadComp($productUniverseMapRef);
        }
    }
}

sub _preloadComp {
    my ($self, $productUniverseMapRef) = @_;
    # Stub: Override in derived classes
}

# Input 1: reference to CompMeta for a delta component that was known to have changed
#
# Return 0: if the change to a delta component does not have to be considered as incompatible
# from the perspctive of derived plugin classes; Returns 1 if the chnage is to be considered
# as an incompatible change (and thus warrant transitive rebuilding of all comps that (in) directly
# depend on this delta comp.
#
sub isTransitiveRebuildRequired {
    my ($self, $deltaCompMeta) = @_;

    if ($self->{'plugins'}) {
        my @plugins = values (%{$self->{'plugins'}});
        foreach my $p (@plugins) {
            my $rr = $p->isTransitiveRebuildRequired($deltaCompMeta);
            if ($rr) {
                return 1;
            }
        }
    }
    return 0;
}

1;
