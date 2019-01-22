package ariba::rc::Sort::Releases;

use strict;
use warnings;

#
# Given a list of releases:
#
#   hawk, 11s2, 11s1, 10s2, 10s2_rel, an
#
# Sort them like so: 
#
#   11s2, 11s1, 10s2_rel, 10s2, an, hawk
#
# Notes:
#
# - Numeric releases are placed before alphabetical releases
# - Numeric releases are sorted in descending order
# - Alphabetical releases are sorted in ascending order
#
sub sort
{
    my (@raw) = @_;
    my (@cooked, @alpha, @numeric);

    # separate releases starting with an alphabetical character
    # from those starting with a number into two piles
    foreach my $i (0 .. $#raw)
    {
        if ($raw[$i] =~ m#^\d#)
        {
            push @numeric, $raw[$i];
        }
        else
        {
            push @alpha, $raw[$i];
        }
    }

    # numerical releases first
    push @cooked, reverse sort @numeric;

    # then alphabetical releases
    push @cooked, sort @alpha;

    return @cooked;
}

1;
