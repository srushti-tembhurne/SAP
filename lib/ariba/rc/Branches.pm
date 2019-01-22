package ariba::rc::Branches;

#
# Static methods used by jupiter-build-request and build-info
#
# TODO: Find a better home for this function
# TODO: Modify build-info cgi script to use this function 
#

use strict;
use warnings;
use Carp;
use ariba::rc::Globals;

#
# return available branches given a product name
#
sub getBranchNames
{
    my $product = shift;
    my $debug = shift || 0;
    my %branches;
    my $branch;

    my $archivedProduct = ariba::rc::Globals::archiveBuilds ($product);
    print "archivedProduct: $archivedProduct\n" if $debug;

    if (! opendir (DIR, $archivedProduct))
    {
        carp "Cannot open $archivedProduct:$!\n";
        return %branches;
    }

    my @currentLink = grep (/^current/, readdir(DIR));
    closedir(DIR);

    foreach my $curr (sort(@currentLink))
    {
        my $file = "$archivedProduct/$curr/config/BranchName";
        if (-f $file)
        {
            print "parsing $file\n" if $debug;
            open(CURRENT, $file);
            while (<CURRENT>)
            {
                chomp;
                $branch = $_;
                print "  found $branch\n" if $debug;
            }
            close (CURRENT);
            $branches{$branch} = $curr;
         }
    }
    return %branches;
}

1;
