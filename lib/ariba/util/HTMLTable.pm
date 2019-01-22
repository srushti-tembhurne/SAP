package ariba::util::HTMLTable;

#
# Slightly more pleasant way to generate HTML tables
#
# TODO: 
# - table_start should take arguments for cellpadding, cellspacing, border, width, etc.
# - support for CSS styles instead of bgcolor
# - support for align, valign
#

use strict;
use warnings;

# 
# Globals
#

my @COLORS = qw (efefef ffffff);
my $k = 0;

#
# Static methods
#

sub table_start
{
	$k = 0;
	return <<FIN;
<table cellpadding=4 cellspacing=4 border=1 width="90%">
FIN
}

sub table_end
{
	return <<FIN;
</table>
FIN
}

sub table_row_header
{
    my ($rows, $alignments) = @_;
    return _table_row ($rows, $alignments, 1);
}

sub table_row
{
    my ($rows, $alignments) = @_;
    return _table_row ($rows, $alignments, 0);
}

sub _table_row
{
    my ($rows, $alignments, $is_header, $colors) = @_;

    my $color = $COLORS[$k];
    my $buf = "<tr bgcolor='#$color'>";
    $k = ! $k;

	my ($label, $align);

    foreach my $i ( 0 .. $#$rows )
    {
        $label = $$rows[$i];
        if ($is_header)
        {
            $label = "<b>" . $label . "</b>";
        }
        $align = $$alignments[$i];
        $buf .= "<td align=$align valign=top>$label</td>";
    }

    $buf .= "</tr>";
	return $buf;
}


1;
