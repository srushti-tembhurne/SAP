package ariba::Ops::ProductConfigFactory;

use strict;
use warnings;
use Carp qw(confess);
use Data::Dumper;

use ariba::Ops::ProductConfig::Utils qw(func);

sub new {
    my ($ref, $args) = @_;

    my $class = "ariba::Ops::ProductConfig";

    if($args->{dbtype}) {
        my $dbtype = ucfirst($args->{dbtype});
        my $subclass = $class . "::$dbtype";

        eval ("use $subclass");
        confess "@{[func()]}: Error loading $subclass: $@ ($!)\n" if $@;
        return $subclass->new($args);
    }

    ### if no dbtype was specified, we must be in gen-config mode, which
    ### will need all known db types to be loaded from the base class.
    return $class->new($args);
}

1;
