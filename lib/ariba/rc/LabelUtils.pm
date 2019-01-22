package ariba::rc::LabelUtils;

use File::Temp;

my %cachedLabels;
my @allLabels;
my %labelsForComponent;
#
# Convert label patterns containing * to a Perl regular expression.
#
sub convertLabelPatternToRE
{
    my ($pattern) = @_;

    # Determine if the label is of the form x.y.*, so that we can make
    # that match either x.y or x.y.z.  The tricky part is that the y
    # can be a simple \d+ or a complex (...) sequence.  What we do is
    # take off the trailing .* so the "." doesn't get treated literally,
    # and then put it back on at the end with a ? operator.

    my $isWildRelease = $pattern =~ s/(-\d+\.(\d+|\([^)]+\)))\.\*$/$1/;

    $pattern =~ s/\(([^)]+)\)/makeRangePattern($1)/eg;   # (a|b|c..d)
    $pattern =~ s/([\.\+])/\\$1/g;    # quote metachars: . +
    $pattern =~ s/\*/.*/g;            # * -> .*

    $pattern .= "(\\..*)?" if $isWildRelease;

    return $pattern;
}

sub makeRangePattern
{
    my ($pattern) = @_;
    my @terms;

    foreach my $piece (split(/\|/, $pattern)) {
        if ($piece =~ /^(\d+)\.\.(\d+)$/) {
            push(@terms, $_) foreach $1..$2;
        }
        else {
            push(@terms, $piece);
        }
    }

    return "(" . join('|', @terms) . ")";
}

sub sortLabels
{
    my $aName = $a;
    $aName =~ s/.*-([\d\.]*)$/$1/;
    my @aVers = split(/\./, $aName);

    my $bName = $b;
    $bName =~ s/.*-([\d\.]*)$/$1/;
    my @bVers = split(/\./, $bName);

    my $n = 0;

    while($n == 0 && (@aVers || @bVers)) {
	my $aVer = shift(@aVers) || -1;
	my $bVer = shift(@bVers) || -1;
	$n = $aVer <=> $bVer;
    }

    return $n;
}

sub matchedLabels
{
	my $wildLabels = shift;
	my $labelsToMatch = shift;

	my @matchedLabels;

	for my $wildLabel (split(",", $wildLabels)) {
		if ($wildLabel =~ m/\.|\*|\+|\(/) {
			my $regExLabel = convertLabelPatternToRE($wildLabel);
			my $usedPlus = ($regExLabel =~ s/\d+\\\+/\\d+/g);

			my $labelsToCheck;
			if ($labelsToMatch) {
				$labelsToCheck = $labelsToMatch;
			} else {
				my ($comp) = ($wildLabel =~ m/^(.+)-/);
				if ($comp) {
					$comp = lc($comp);
					$labelsToCheck = $labelsForComponent{$comp} || [];
				} else {
					warn "$wildLabel did not match, checking all labels!!!\n";
					$labelsToCheck = \@allLabels;
				}
			}
			for my $label (@$labelsToCheck) {
				if ($usedPlus) {
					# Pattern match doesn't necessarily have to end at $
					# (plusCheck will take care of confirming that).
					next unless $label =~ m/^$regExLabel\b/i;
					next unless plusCheck($label, $wildLabel);
				} else {
					# Without + there is no implicit extension on the right,
					# so we must match at the end as well.
					next unless $label =~ m/^$regExLabel$/i;
				}
				push(@matchedLabels, $label);
			}
		} else {
			push(@matchedLabels, $wildLabel);
		}
	}
#    print "Matched labels = ", join(", ", sort sortLabels @matchedLabels);

	return @matchedLabels;
}

#
# Compare label name with specification containing "+" wildcard.
# 
sub plusCheck
{
    my ($label, $match) = @_;

    if ($label !~ m/-[\d.]+$/) {
#       print "plusCheck: label $label not in -x[.y[.z]] format\n";
        return 0;
    }

    if ($match !~ m/-[\d.+*]+$/) {
#       print "plusCheck: wildcard $match not in -x[.y[.z]] format\n";
        return 0;
    }

    $label =~ s/.*-//;
    $match =~ s/.*-//;
    my @have = split(/\./, $label);
    my @want = split(/\./, $match);

    while (@want) {
        my $want = shift(@want);
        my $have = shift(@have) || 0;

        if ($want =~ m/^(\d+)\+$/) {
            # Note that we return immediately with the comparison result
            # once a '+' is seen.  This means that 4+.2+ is the same as
            # 4+ the rest of the specification will never be tested.  If
            # I knew the error model used here I would flag a warning if
            # that syntax was used.

            return ($have >= $1);
        }

        if ($want ne "*" && $want ne $have) {
            # If it's not "*" it must be a specific number, so if we don't
            # match on it the whole comparison fails.  If it does match,
            # we keep on looping for the next comparison.

            return 0;
        }
    }

    return 1;
}

#
# compare wildcarded label with the exact label
#
sub exactLabel
{
	my $wildLabel = shift;
	my $noMatch = "No-Labels";

	if (defined $cachedLabels{$wildLabel}) {
		return $cachedLabels{$wildLabel};
	}
	my @matchedLabels = matchedLabels($wildLabel);
	my $exactLabelName;

	if ( $#matchedLabels >= 0 ) {
		$exactLabelName = (sort sortLabels @matchedLabels)[-1];
	} else {
		$exactLabelName = $noMatch;
	}
	$cachedLabels{$wildLabel} = $exactLabelName;

	#print "found label $exactLabelName for $wildLabel\n";

	return $exactLabelName;
}


sub isLabelInRange
{
    my ($label, $range) = @_;
    my @labelsInRange;

    push(@labelsInRange, matchedLabels($range));

    if (($label eq "any" || $label eq "latest") && @labelsInRange) {
	return 1;
    }

    $label = exactLabel($label);

    #print "$#labelsInRange label in $range\n";

    my $v1;

    for $v1 (@labelsInRange) {
	if ($v1 eq $label) {
	    return 1;
	}
    }

    return 0;
}

#
# this duplicates functionality of
# Ariba::P5::parseComponentDetails(), but this function does not
# mangle 'latest' label into 'head', which the P5 one does
# 
# At some point in the future these two should be resolved
#
sub readLabelFile {
	my $file = shift;
	my $labelsHashRef = shift;

	$labelsHashRef = {} unless defined $labelsHashRef;

	open(LABELFILE, "<$file") or die __PACKAGE__."readLabelFile: Can't open $file: $!";
	for my $line (<LABELFILE>) {
		next if $line =~ /^#/;
		next if $line =~ /^\s*$/;
		my ($modname, $label, $location, $labelPattern) = split(/\s+/, $line);
		$labelsHashRef->{$modname} = { 
			'label' => $label,
			'location' => $location,
			'labelPattern' => $labelPattern,
		};
	}
	close(LABELFILE);

	return $labelsHashRef;
}

#
# the format of this file is:
#
# <component name> <new label> <p4 location> <new label mask>
#
# where <new label> is the label labelcomponents would have created
# and <new label mask> is the new label mask that product.bdf would
# have been updated with.
#
sub populateLabelFile {
	my $argsHashRef = shift;

	my $fileName = $argsHashRef->{'file'};
	open(LABELFILE, ">>$fileName") or die __PACKAGE__."populateLabelFile: Can't open $fileName for append: $!";

	print LABELFILE "#\n# auto-labels for ", $argsHashRef->{'product'}, " ", $argsHashRef->{'branch'}, "\n#\n";
	my $labelsHashRef = $argsHashRef->{'labels'};
	foreach my $modname (keys %$labelsHashRef) {

		print LABELFILE join(" ", 
				$modname, 
				$labelsHashRef->{$modname}->{'label'}, 
				$labelsHashRef->{$modname}->{'location'});
		print(LABELFILE " ", $labelsHashRef->{$modname}->{'labelPattern'}) if $labelsHashRef->{$modname}->{'labelPattern'};
		print LABELFILE "\n";
	}
	close(LABELFILE) or die __PACKAGE__."populateLabelFile: Can't open $fileName for append: $!";

	return 1;
}

sub init
{
    my ($refLabels) = @_;

    @allLabels = sort (keys(%{$refLabels}));

    foreach my $label (@allLabels) {
	if ($label =~ m/^(.+)-/) {
	    my $comp = lc($1);
	    my $l = $labelsForComponent{$comp};
	    unless (defined $l) {
		$l = [];
		$labelsForComponent{$comp} = $l;
	    }
	    push @$l, $label;
	}
    }

    #print "components are:\n";
    #print join("\n", sort keys %labelsForComponent);
    #print "\n";


}

#
# Check if the given label is a product label (Ex: Borabora-1403)
#
sub isProductLabel
{
	my $label = shift;

	if (! $label)
	{
		print "LabelUtils::isProductLabel needs a label.\n";
		return 0;
	}

	# Exit early if this looks like a component label
	return 0 if ($label =~ /.*-(\d+)\.(\d+)/);

	my $cmd = "p4 files //ariba/.../product.bdf\@$label 2>&1";
	my $output = `$cmd`;
	if ($output =~ /(\w+) change (\d+)/i)
	{
		print "$label is product label \n" if ($debug);
		return 1;
	}
	else
	{
		return 0;
	}

}

#
# Extract the component label from a product label
#
sub extractCompLabelFromProdLabel
{
	my ($compName,$prodLabel) = @_;
	my $ctxtP4Path;

	# Find out the components.txt file under this product label
	my $cmd = "p4 files //ariba/.../components.txt\@$prodLabel 2>&1";
    my $output = `$cmd`;
	if ($output =~ /(.*) - (\w+) change (\d+)/)
	{
			$ctxtP4Path = $1;
	}
	else
	{
			print "Unable to find the components.txt file under the product label $prodLabel\n";
			print "Cannot find the component label for the component $compName under the product label $prodLabel \n";
			print "Exiting ... \n";
			exit;
	}
	
	# Sync the ctxt file
	my $localCtxtFile = File::Temp::tmpnam();
	`p4 print -o $localCtxtFile  -q $ctxtP4Path`;

	# Read the contents of the ctxt file
	my %labelsInfo;
	readLabelFile ($localCtxtFile,\%labelsInfo);
	
	return ($labelsInfo{$compName}{label}, \%labelsInfo);
}


sub main
{
    my $pattern = shift(@ARGV);

    eval "use Ariba::P4";
    init(Ariba::P4::labels());
    my $label = exactLabel($pattern);

    if ($label eq "No-Labels") {
        print "Label pattern '$pattern' did not match anything!\n";
    } else {
        print "Label pattern '$pattern' matched $label\n";
    }
}

1;
