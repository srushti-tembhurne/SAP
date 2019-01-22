#!/usr/local/tools/bin/perl

use strict;
use warnings;

use JSON;
use DBI;
use File::Basename;
use FindBin;
use URI::Escape;
use lib "/usr/local/tools";
use lib "$FindBin::Bin/../../../tools/lib/perl";
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin";
use ariba::monitor::QueryManager;
use ariba::rc::InstalledProduct;
use ariba::Ops::Logger;
use ariba::Ops::Machine;
use ariba::Ops::OracleClient;
use ariba::Ops::DBConnection;
use ariba::Ops::Constants;
use ariba::Oncall::Person;
use ariba::Ops::AQLClient;
use ariba::Ops::AQLConnection;
use ariba::Ops::ProductAPIExtensions;
use ariba::Ops::ServiceController;
use ariba::Ops::Utils;
use ariba::monitor::Url;
use ariba::Ops::Jira;
use Date::Calc qw(:all);
use Local::SAP::SapAD;
use Data::Dumper;

use POSIX qw{ strftime };

require "geturl";

my $useMock = 0;
my $createMock = 0;
my $debug = 0;
my %sapIdMap;
my $logRoot;

    # Connection Status hash
    my %conn_status = (
        jira => {
            title => "Connection Status: Jira",
            status_str => "",
        },
        sapad => {
            title => "Connection Status: SapAD",
            status_str => "",
        },
    );


# Set up logger
my $log_filename = ariba::Ops::Constants->toolsLogDir() . '/check-user-accounts.log';
my $logger       = ariba::Ops::Logger->logger();

$logger->setLogFile($log_filename);

# append to logger file and dont print to screen
my $LOGGER;
open $LOGGER, '>>', $log_filename;
$logger->setFh($LOGGER);
$logger->setQuiet(1);

my $me = ariba::rc::InstalledProduct->new('mon');

    my $service = $me->service();
    my $date = strftime("%Y-%m-%d", localtime());
    $logRoot = "/tmp/$service/mon";
    my $logFile = "$logRoot/active-accounts-$date.csv";

    if ( ! -d $logRoot ){
        ariba::rc::Utils::mkdirRecursively($logRoot);
    }


 $logger->debug("Initializing \"all Jira tickets\"") if $debug;
    my $allTickets  = getJiraTickets('all', \%conn_status);
	
	foreach my $jira_ticket ($allTickets->{'issues'}) {
		foreach my $ticket (@{$jira_ticket}) {
			my $jira_created =  $ticket->{'fields'}->{'created'};
			my ($created_date,$created_time) = split('T',$jira_created);
			my ($created_year,$created_month,$created_day) = split(/\-/,$created_date);
			my ($year,$month,$day) = Today();
			my $Dd = Delta_Days($created_year,$created_month,$created_day, $year,$month,$day);
			if($Dd <= 7 ) { #only fetch jira tickets if the created_Date is older than 7 days which is approximately 5 buisness days
				print "Skipping Jira ticket [ $ticket->{'key'} ] because of created ticket [ $created_date ] is not older than 7 days \n" if($debug);
				next;
				
			}
			else {
				    my %options = ();
    $options{timeoutSecs} = 10;
    $options{maxResults} = 100;
    $options{nologging} = 1;

my    $sapad = Local::SAP::SapAD->new(\%options);

				print '^+++'.$ticket->{'key'},'+*', $ticket->{'fields'}->{'summary'},'+*',$ticket->{'fields'}->{'description'},'++++$','\n';
		#	print Dumper($ticket);
	
			}
		}
	}
sub getJiraTickets {
    ## Returns ALL Jira tickets that are not closed and have 'delete accounts for' in the subject

    my ($type, $conn_status_ref) = @_;


    my $results = {};
    my $status_str = 'OK';

        #
        my $jira = ariba::Ops::Jira->new();

		my $jql = 'project = HOA AND (summary ~ "Delete Account " OR summary ~ "delete safeguard account (90 day expiration) for") AND issuetype in (OpsAutomated,"Service Desk") AND status in (Open, "In Progress", "All Clear", Stable)';

        eval { $results = $jira->search( $jql ); };

        if (my $exception = $@) {
            $status_str = "Error doing jira $type search $jql: $exception";
            $conn_status_ref->{jira}->{status_str} = $status_str;
            $logger->error($status_str);
            return {};
        }


    # set status as OK at this point if not set
    if ( ! $conn_status_ref->{jira}->{status_str} ) {
        $conn_status_ref->{jira}->{status_str} = 'OK';
    }

    return $results;
}

