# MergeFileIndexer.pl
use Getopt::Long;
use Data::Dumper;
use lib '.';
use lib '../..';
use ariba::rc::MergeFileIndexer;

sub main {

    my $printdebug;
    my $component;
    my $files;
    my $indexfile;
    my $searchdir;
    my $worstcase;

    my $result = GetOptions ("printdebug" => \$printdebug,
        "component=s" => \$component,
        "searchdir=s" => \$searchdir,
        "worstcase" => \$worstcase,
        "files" => \$files,
        "indexfile=s" => \$indexfile);

    if (defined $searchdir && defined $indexfile) {
        my $mfi = ariba::rc::MergeFileIndexer->new($indexfile);
        $mfi->genIndexFileFromSearchByDir($searchdir);
    }
    elsif (defined $indexfile && defined $worstcase) {
        my $mfi = ariba::rc::MergeFileIndexer->new($indexfile);
        #   1. key 'size' value is scalar size (1 based) of list of other comps to merge against
        #   2. key 'component' value is scalar name of the component with the largest filemerge network
        #   3. key 'listref' value is reference to a list of other component names in the filemerge network

        my $ret = $mfi->getWorstCaseComponentsToMergeWith();
        if (defined $ret) {
            my $worstCaseSize = $ret->{'size'};
            my $worstCaseComp = $ret->{'component'};
            my $worstCaseListRef = $ret->{'listref'};
            print "The worst case is that touching component \"$worstCaseComp\" requires the following $worstCaseSize components to filemerged with: @$worstCaseListRef\n";
        }
        else {
            print "The component \"$component\" could not be found\n";
        }
    }
    elsif (defined $indexfile && defined $component && defined $files) {
        my $mfi = ariba::rc::MergeFileIndexer->new($indexfile);
        my $listref = $mfi->getFilesToMergeWith($component);
        if (defined $listref) {
            print "The component \"$component\" requires the following files to merge with: @$listref\n";
        }
        else {
            print "The component \"$component\" could not be found\n";
        }
    }
    elsif (defined $indexfile && defined $component) {
        my $mfi = ariba::rc::MergeFileIndexer->new($indexfile);
        my $listref = $mfi->getComponentsToMergeWith($component);
        if (defined $listref) {
            print "The component \"$component\" requires the following components to filemerge with: @$listref\n";
        }
        else {
            print "The component \"$component\" could not be found\n";
        }
    }
    else {
        usage();
    }
}

sub usage {
    print "Usage 1 : perl MergeFileIndexer -indexfile <path to index file to read from> -component <component name to drive the discovery of the filemerge network>\n";
    print "Usage 2 : perl MergeFileIndexer -indexfile <path to index to write to> -searchdir <directory to search for index.csv>\n";
    print "Usage 3 : perl MergeFileIndexer -indexfile <path to index to read from> -worstcase\n";
    print "Usage 4 : perl MergeFileIndexer -indexfile <path to index to read from> -component <name> -files\n";
}

main();
