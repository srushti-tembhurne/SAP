package ariba::rc::dashboard::Timestamp;

#
# Time/Date related functions for RC Dashboard
#

use strict;
use warnings;

# 
# Constants
#
my @MONTHS = qw( Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec );

#
# Display time/date in short format
#
sub prettyprint
{
    my $when = shift || time();
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime ($when);
    return sprintf "%02d-%s-%04d %02d:%02d", $mday, $MONTHS[$mon], 1900 + $year, $hour, $min;
}

1;
