# PublishedArtifactIndexer.pl
use Getopt::Long;
use Data::Dumper;
use lib '.';
use lib '../..';
use ariba::rc::PublishedArtifactIndexer;

sub main {

    my $printdebug;
    my $searchdir;
    my $indexfile;

    my $result = GetOptions ("printdebug" => \$printdebug,
        "searchdir=s" => \$searchdir,
        "indexfile=s" => \$indexfile);

    if (defined $searchdir && defined $indexfile) {
        my $mfi = ariba::rc::PublishedArtifactIndexer->new($indexfile);
        $mfi->genPublishIndexFileFromSearch($searchdir);
    }
    else {
        usage();
    }
}

sub usage {
    print "Usage 1 : perl PublishedArtifactIndexer -indexfile <path to index to write to> -searchdir <directory to search for Build.mk>\n";
}

main();
