package ariba::Automation::Utils::HTML;

use warnings;
use strict;

# tool: generate HTML menu
#
# examples:
#
# my @menu_items = qw (John Paul George Ringo);
# my $menu = form_select ("beatles", \@menu_items, 2, 4);
#
# The above example generates an HTML menu named "beatles" with
# Paul selected with a size of 4 items.
#
# my %menu_items = ( 43 => "George W. Bush", 42 => "Bill Clinton", 43 => "Barack Obama" );
# my $menu = form_select ("presidents", \%menu_items), 3);
#
# The above example generates an HTML menu named "presidents" with
# Barack Obama selected. To get the value:
#
# my $cgi = new CGI();
# my ($presidency) = $cgi->{'president') =~ m#^(\d+)$#;
# print "$presidency\n"; # prints 43 if Barack Obama is selected

sub form_select
  {
  # name = name of menu
  # args = reference to ARRAY or HASH
  # default = name of default menu item (optional, defaults to none)
  # size = number of items to show on menu (optional, defaults to 1)
  # id = id of html element
  my ($name, $args, $default, $size, $id) = @_;

  $size = $size || 1;
  $default = $default || "";
  $id = $id || "";

  my $idstr = "";
  if ($id)
    {
	$idstr = " id=\"$id\"";
	}

  my $buf = <<FIN;
<select name="$name" size="$size"$idstr>
FIN

  if (ref ($args) eq "ARRAY")
    {
    foreach (@$args)
      {
      next unless length ($_);
      my $key = $default eq $_ ? " selected" : "";
      $buf .= <<FIN;
<option value="$_"$key>$_</option>
FIN
      }
    }
  elsif (ref ($args) eq "HASH")
    {
    foreach (sort { $a <=> $b } keys %$args)
      {
      my $key = $default eq $_ ? " selected" : "";
      $buf .= <<FIN;
<option name="$_" value="$_"$key>$$args{$_}</option>
FIN
      }
    }

  $buf .= "</select>";
  return $buf;
  }

1;
