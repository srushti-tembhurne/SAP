package ariba::monitor::IntegrationPortal::AIGUtils;

use ariba::monitor::QueryManager;
use ariba::rc::InstalledProduct;

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(process_aig_queries);

sub process_aig_queries {
    my $qmName = shift;
    my $queries = shift;
    my $processArgs = shift;

    # this is the main reason for creating this module
    # to make sure all the aig monitors are
    # coming under the same expando in MON;
    my $AIG = "Ariba Cloud Integration Gateway";
    my $product = ariba::rc::InstalledProduct->new("mon");

    my $qm = ariba::monitor::QueryManager->newWithDetails(
            $qmName, $product->name, $product->service, undef, $queries
        );
    $qm->setUiManager($AIG);
    $qm->processQueries(@$processArgs);
}

