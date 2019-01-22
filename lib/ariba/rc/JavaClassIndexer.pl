# javaClassIndexer.pl
use Getopt::Long;
use Data::Dumper;
use lib '.';
use lib '../..';
use ariba::rc::JavaClassIndexer;

sub main {

    my $indexdir;

    my $result = GetOptions ("indexdir=s" => \$indexdir);

    if (defined $indexdir) {
        my $indexer = ariba::rc::JavaClassIndexer->new($indexdir, 1);
        $indexer->_createSubclassIndex();
    }
    else {
        usage();
    }
}

sub usage {
    print "Usage : perl JavaClassIndexer -indexdir <path to index directory>\n";
}

main();
