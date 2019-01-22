#------------------------------------------------------------------------------
# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Jira.pm#2 $
# $HeadURL$
#------------------------------------------------------------------------------
package ariba::Ops::Jira;
$ariba::Ops::Jira::VERSION = '0.1';

use warnings;
use strict;
use Carp;

use base qw( Exporter );
our @EXPORT_OK = qw/ /;

our %EXPORT_TAGS = ( ALL => [ @EXPORT_OK ] );

use Data::Dumper;
# Some Data::Dumper settings:
local $Data::Dumper::Useqq  = 1;
local $Data::Dumper::Indent = 3;

use POSIX qw{ strftime };

local $| = 1;

use FindBin;
use lib "$FindBin::Bin/../../../lib/perl";
use JIRA::Client::Automated;

=head1 NAME

ariba::Ops::Jira - Ariba specific wrapper for JIRA::Client::Automated

=head1 VERSION

Version 0.1

=cut

use version; our $VERSION = '0.01';

=head1 SYNOPSIS

ariba::Ops::Jira provides Ariba specific communication with the Ariba Jira server.

    use ariba::Ops::Jira;

    my $jira = ariba::Ops::Jira->new();

    my $jira_id = 'HOA-1234';
    my $issue = $jira->get_issue( $jira_id );

    $jira->add_watchers( $jira_id, [ 'i836129' ] );
    $jira->add_watchers( $jira_id, [ 'i844276', 'i836129' ] );

    my $attach = '/tmp/lorem.svg';
    $jira->add_attachment( $jira_id, $attach );

    my $comment = 'This is a comment.\nActually, this is a multi-line comment!';
    $jira->add_comment( $jira_id, $comment );

    $jira->set_team( $jira_id, 'Tools' );

    $jira->set_severity( $jira_id, 'S3' );

    my $future = '2014-12-12';
    $jira->set_due( $jira_id, $future )

    my $now = time;
    $jira->set_due( $jira_id, $now )

    $jira->set_type( $jira_id, 'Incident' );

    my $summary = 'TEST TICKET FOR JIRA API TESTING (updated using API/Perl)';
    $jira->set_summary( $jira_id, $summary );

    my $desc = 'This is a test ticket, please ignore!! (updated using API/Perl)';
    $jira->set_description( $jira_id, $desc );

    $jira->set_category( $jira_id, 'Troubleshoot Request' );

    $jira->set_service( $jira_id, 'DEV3' );

    $jira->set_dc( $jira_id, '(SNV)' );

    $jira->set_product( $jira_id, 'AN' );

    $jira->set_assignee( $jira_id, 'i123456' );

    my $id = $jira->create_servicedesk({
        summary     => 'Ignore this ticket, testing the Jira REST API',
        description => 'This is a test of the Jira REST API, ignore this ticket!',
        team        => 'Tools',
        severity    => 'S1',
    });

    $id = $jira->create_automated({
        summary     => 'Ignore this ticket, testing the Jira REST API',
        description => 'This is a test of the Jira REST API, ignore this ticket!',
        team        => 'Tools',
        severity    => 'S1',
    });

    $id = $jira->create_subtask( 'HOA-2630', {
        summary     => 'Ignore this ticket, testing the Jira REST API',
        description => 'This is a test of the Jira REST API, ignore this ticket!',
        team        => 'Tools',
        severity    => 'S1',
    });

    $jira->create_incident({
            DATA ...
    });

=head1 DESCRIPTION

TLDR; This module uses JIRA::Client::Automated under the hood.  This module will
alleviate the need for the end programmer to have to worry about connecting to
the correct server.  Also provides wrappers and convenience functions for the rest
of the JIRA::Client::Automated module.

We are using default values for Jira User/Password.  This is a "headless" user and should
be fine for automation.  If you need to login to Jira as a different user, this module
will use values from a couple of environment variables rather than these defaults.  
JIRA_USER and JIRA_PASS are the variable names.

=cut


## Some globals:
my %issuetypes = (
    'Bug'                 => 1,
    'New Feature'         => 2,
    'Task'                => 3,
    'Improvement'         => 4,
    'Sub-task'            => 5,
    'Feature'             => 6,
    'Story'               => 7,
    'Technical task'      => 8,
    'Defect'              => 13,
    'Use Case'            => 14,
    'CPAS'                => 15,
    'Process Improvement' => 16,
    'CIRS'                => 37,
    'Enhancement'         => 10501,
    'Global Constants'    => 10502,
    'Process'             => 10600,
    'Service Desk'        => 10700,
    'Change Request'      => 10701,
    'Incident'            => 10702,
    'OpsAutomated'        => 10703 ,
);

my %teams = (
    'SRE'                => 10765,
    'DBA'                => 10766,
    'ProdOps Deployment' => 12821,
    'NetAdmin'           => 12822,
    'SysAdmin'           => 12900,
    'Tools'              => 10771,
    'DRE'                => 11503,
    'PMO'                => 13100,
    'Ops Manager'        => 13308,
);


=head1 PUBLIC METHODS

=item new()

    FUNCTION: Object oriented constructor

   ARGUMENTS: hashref, only recognized key is debug
           
     RETURNS: An ariba::Ops::Jira object

=cut

sub new {
    my ( $class, $args ) = @_;
    my $self;

    $self->{ 'debug' } = $args->{ 'debug' } || undef;
    $self->{ 'url'   } = $ENV{ JIRA_URL   } || 'https://product-jira.ariba.com';
    $self->{ 'user'  } = $ENV{ JIRA_USER  } || 'hoa_auto_reporter';
    $self->{ 'pass'  } = $ENV{ JIRA_PASS  } || 'headless';

    eval {
        $self->{ '_jira' } = JIRA::Client::Automated->new(
            $self->{ 'url'  },
            $self->{ 'user' },
            $self->{ 'pass' },
        );
    };
    croak "Error creating new Jira object: $@" if $@;

    $self->{ '_jira' }->{ '_json' }->allow_nonref;

    return bless $self, $class;
}


=head1

=item add_watchers()

    FUNCTION: Add a list of watchers to a JIRA_ID.  Use i-numbers!!

   ARGUMENTS: JIRA-ID, arrayref of i-numbers
           
     RETURNS: Nothing.  croak's on errors.

=cut

sub add_watchers {
    my ( $self, $jira_id, $watchers ) = @_;

    foreach my $w ( @{ $watchers } ){
        if ( $self->{ 'debug' } ){
            print "Adding watcher to '$jira_id': '$w'\n";
        }
        eval {
            $self->{ '_jira' }->add_watcher( $jira_id, $w );
        };
        croak $@ if $@;
    }

    return;
}


=head1

=item get_issue()

    FUNCTION: Return a Jira issue

   ARGUMENTS: JIRA-ID
           
     RETURNS: Jira issue for JIRA-ID, undef if not found.  croak's on errors.

=cut

sub get_issue {
    my ( $self, $jira_id ) = @_;
    my $issue = undef;

    if ( $self->{ 'debug' } ){
        print "Retrieving issue: '$jira_id'\n";
    }

    eval{
        $issue = $self->{ '_jira' }->get_issue( $jira_id );
    };
    if ( $@ && $@ =~ /404 Not Found/ ){
        print "Issue '$jira_id' not found\n" if $self->{ 'debug' };
        $issue = undef; ## Requested ID not found, return undef ...
    } elsif ( $@ ) {
        croak $@;
    }

    return $issue;
}


=head1

=item add_attachment()

    FUNCTION: Add an attachment to a JIRA_ID.

   ARGUMENTS: JIRA-ID, name of file to attach
           
     RETURNS: Nothing.  croak's on errors.

=cut

sub add_attachment {
    my ( $self, $jira_id, $file ) = @_;

    if ( $self->{ 'debug' } ){
        print "Attaching file to '$jira_id': '$file'\n";
    }
    eval {
        $self->{ '_jira' }->attach_file_to_issue( $jira_id, $file );
    };
    croak $@ if $@;

    return;
}


=head1

=item add_comment()

    FUNCTION: Add a comment to a JIRA_ID.

   ARGUMENTS: JIRA-ID, scalar content of the comment
           
     RETURNS: Nothing.  croak's on errors.

=cut

sub add_comment {
    my ( $self, $jira_id, $comment ) = @_;

    if ( $self->{ 'debug' } ){
        print "Adding comment to '$jira_id': '$comment'\n";
    }
    eval {
        $self->{ '_jira' }->create_comment( $jira_id, $comment );
    };
    croak $@ if $@;

    return;
}


=head1

=item set_team()

    FUNCTION: Assigns a JIRA-ID to an Ops team

   ARGUMENTS: JIRA-ID, name of team to assign to
           
     RETURNS: Nothing.  croak's on errors.

        NOTE: Valid teams: 'SRE', 'DBA', 'ProdOps Deployment', 'NetAdmin', 'SysAdmin', 'Tools', 'DRE', 'PMO', 'Ops Manager'

=cut

sub set_team {
    my ( $self, $jira_id, $team ) = @_;

    croak "Unknown team: '$team'" unless grep { $_ =~ /^$team$/ } keys %teams;

    my $issue = $self->{ _jira }->get_issue( $jira_id );
    my $currTeam = $issue->{ 'fields' }->{ 'customfield_10625' }->{ 'value' } || undef;

    if ( $currTeam eq $team ){
        if ( $self->{ 'debug' } ){
            print "'$currTeam' is already set, ignoring ...\n";
        }
        return;
    }

    my $update = {};

    $update = { 'customfield_10625' => [{ set => { 'value' => $team }, }] };

    if ( $self->{ 'debug' } ){
        print "Setting team for '$jira_id': '$team'\n";
    }
    eval {
        $self->{ '_jira' }->update_issue( $jira_id, undef, $update );
    };
    croak $@ if $@;

    return;
}


=head1

=item set_severity()

    FUNCTION: Sets the severity level for a JIRA-ID

   ARGUMENTS: JIRA-ID, severity
           
     RETURNS: Nothing.  croak's on errors.

        NOTE: Valid values: 'S0', 'S1', 'S2', 'S3', 'S4', 'S5', 'S2 - Bus. Function Inoperative'

=cut

sub set_severity {
    my ( $self, $jira_id, $sev ) = @_;

    my @sevs = ( 'S0', 'S1', 'S2', 'S3', 'S4', 'S5', 'S2 - Bus. Function Inoperative' ); 
    croak "Unknown severity: '$sev'" unless grep { $_ =~ /^$sev$/ } @sevs;

    my $update = {};

    $update = { 'customfield_10108' => [{ set => { 'value' => $sev }, }] };

    if ( $self->{ 'debug' } ){
        print "Setting severity for '$jira_id': '$sev'\n";
    }
    eval {
        $self->{ '_jira' }->update_issue( $jira_id, undef, $update );
    };
    croak $@ if $@;

    return;
}


=head1

=item set_due()

    FUNCTION: Set the due date for a JIRA-ID

   ARGUMENTS: JIRA-ID, due date (as epoch timestamp or YYYY-MM-DD format)
           
     RETURNS: Nothing.  croak's on errors.

=cut

sub set_due {
    my ( $self, $jira_id, $due ) = @_;

    my $update = {};

    unless ( $due =~ m/\d{4}-\d{2}-\d{2}/ ){
        ## Not in YYYY-MM-DD format
        $due = strftime( "%Y-%m-%d", localtime( $due ) );
    }

    $update = { 'duedate' => $due };

    if ( $self->{ 'debug' } ){
        print "Setting due date for '$jira_id': '$due'\n";
    }
    eval {
        $self->{ '_jira' }->update_issue( $jira_id, $update );
    };
    croak $@ if $@;

    return;
}


## This does NOT work.  Probably cannot change this after ticket has been created.
## =head1
## 
## =item set_issuetype()
## 
##     FUNCTION: Sets the issue type for a JIRA-ID
## 
##    ARGUMENTS: JIRA-ID, issue type
##            
##      RETURNS: Nothing.  croak's on errors.
## 
##         NOTE: Valid values: 'Service Desk', 'Change Request', 'Incident', 'Story', 'Feature', 'OpsAutomated'
## 
## =cut
## 
## sub set_issuetype {
##     my ( $self, $jira_id, $type ) = @_;
## 
##     my @types = ( 'Service Desk', 'Change Request', 'Incident', 'Story', 'Feature', 'OpsAutomated' ); 
##     croak "Unknown type: '$type'" unless grep { $_ =~ /^$type$/ } @types;
## 
##     my $update = {};
## 
##     $update = { 'issuetype' => { 'name' => $type } };
## 
##     if ( $self->{ 'debug' } ){
##         print "Setting severity for '$jira_id': '$type'\n";
##     }
##     eval {
##         $self->{ '_jira' }->update_issue( $jira_id, $update );
##     };
##     croak $@ if $@;
## 
##     return;
## }


=head1

=item set_description()

    FUNCTION: Sets the description for a JIRA-ID

   ARGUMENTS: JIRA-ID, description
           
     RETURNS: Nothing.  croak's on errors.

=cut

sub set_description {
    my ( $self, $jira_id, $desc ) = @_;

    my $update = {};

    $update = { 'description' => $desc };

    if ( $self->{ 'debug' } ){
        print "Setting description for '$jira_id': '$desc'\n";
    }
    eval {
        $self->{ '_jira' }->update_issue( $jira_id, $update );
    };
    croak $@ if $@;

    return;
}


=head1

=item set_summary()

    FUNCTION: Sets the summary for a JIRA-ID

   ARGUMENTS: JIRA-ID, summary
           
     RETURNS: Nothing.  croak's on errors.

=cut

sub set_summary {
    my ( $self, $jira_id, $summary ) = @_;

    my $update = {};

    ## summary cannot have newlines, lets just massage the text
    $summary =~ s/\n/ -- /g;
    $update = { 'summary' => $summary };

    if ( $self->{ 'debug' } ){
        print "Setting summary for '$jira_id': '$summary'\n";
    }
    eval {
        $self->{ '_jira' }->update_issue( $jira_id, $update );
    };
    croak $@ if $@;

    return;
}


=head1

=item set_category()

    FUNCTION: Sets the category for a JIRA-ID

   ARGUMENTS: JIRA-ID, category
           
     RETURNS: Nothing.  croak's on errors.

        NOTE: Valid values: "Troubleshoot Request", "Account Request",
            "Infrastructure Request", "Application Request", "Monitoring Request",
            "Deployment Request", "Other Request", "Project Request",
            "Security\/Audit Request", "Release Control Request", "CPAS", "Defect",
            "Eng Service Request", "Jira Enhancement Request"

=cut

sub set_category {
    my ( $self, $jira_id, $cat ) = @_;

    my @cats = (
        "Troubleshoot Request",
        "Account Request",
        "Infrastructure Request",
        "Application Request",
        "Monitoring Request",
        "Deployment Request",
        "Other Request",
        "Project Request",
        "Security\/Audit Request",
        "Release Control Request",
        "CPAS",
        "Defect",
        "Eng Service Request",
        "Jira Enhancement Request",
    ); 
    croak "Unknown category: '$cat'" unless grep { $_ =~ /^$cat$/ } @cats;

    my $update = {};

    $update = { 'customfield_10614' => [{ set => { 'value' => $cat }, }] };

    if ( $self->{ 'debug' } ){
        print "Setting severity for '$jira_id': '$cat'\n";
    }
    eval {
        $self->{ '_jira' }->update_issue( $jira_id, undef, $update );
    };
    croak $@ if $@;

    return;
}


=head1

=item set_service()

    FUNCTION: Sets the service for a JIRA-ID

   ARGUMENTS: JIRA-ID, service
           
     RETURNS: Nothing.  croak's on errors.

=cut

sub set_service {
    my ( $self, $jira_id, $service ) = @_;

    ## Not going to try and keep this list updated ... we just add too many
    ## services too frequently for this to be ssustainable ...
    #my @servs = (
    #); 
    #croak "Unknown category: '$cat'" unless grep { $_ =~ /^$service$/ } @servs;

    my $update = {};

    $update = { 'customfield_10611' => [{ set => [{ 'value' => $service },], }] };

    if ( $self->{ 'debug' } ){
        print "Setting service for '$jira_id': '$service'\n";
    }
    eval {
        $self->{ '_jira' }->update_issue( $jira_id, undef, $update );
    };
    if ( $@ ){
        if ( $@ =~ /Option value '.*' is not valid/ ){
            croak "Unknown service: '$service'";
        } else {
            croak $@ if $@;
        }
    }

    return;
}


=head1

=item set_dc()

    FUNCTION: Sets the service for a JIRA-ID

   ARGUMENTS: JIRA-ID, service
           
     RETURNS: Nothing.  croak's on errors.

        NOTE: Valid values:  "Not Applicable", "Devlab", "All Production Datacenters", 
            "(SNV)", "(BOU)", "EU1", "EU2", "Opslab", "US1 (ASH)", "US2", "Unknown"

=cut

sub set_dc {
    my ( $self, $jira_id, $dc ) = @_;

    my @dcs = (
          'Not Applicable',
          'Devlab',
          'All Production Datacenters',
          '(SNV)',
          '(BOU)',
          'EU1',
          'EU2',
          'Opslab',
          'US1 (ASH)',
          'US2',
          'Unknown',
    ); 
    croak "Unknown datacenter: '$dc'" unless grep { $_ =~ /$dc/ } @dcs;

    my $update = {};

    $update = { 'customfield_10608' => [{ set => [{ 'value' => $dc },], }] };

    if ( $self->{ 'debug' } ){
        print "Setting datacenter for '$jira_id': '$dc'\n";
    }
    eval {
        $self->{ '_jira' }->update_issue( $jira_id, undef, $update );
    };
    croak $@ if $@;

    return;
}


=head1

=item set_product()

    FUNCTION: Sets the product for a JIRA-ID

   ARGUMENTS: JIRA-ID, product
           
     RETURNS: Nothing.  croak's on errors.

        NOTE: Valid values: "Not Applicable", "All", "AESWS", "Alexandria", "AN",
                "Arches", "Arches, Hadoop", "Community", "CSC", "CWS", "DOC",
                "Hadoop", "Hana", "InfoNet", "LOGI", "Logi2", "Lumira", "Mobile",
                "MON", "MonX", "OWS", "Platform", "S2", "S4", "SDB", "Spotbuy", "SSP",
                "SSWS", "PWS", "WS", "Unknown"

=cut

sub set_product {
    my ( $self, $jira_id, $prod ) = @_;

    my @prods = (
        "Not Applicable",
        "All",
        "AESWS",
        "Alexandria",
        "AN",
        "Arches",
        "Arches, Hadoop",
        "Community",
        "CSC",
        "CWS",
        "DOC",
        "Hadoop",
        "Hana",
        "InfoNet",
        "LOGI",
        "Logi2",
        "Lumira",
        "Mobile",
        "MON",
        "MonX",
        "OWS",
        "Platform",
        "S2",
        "S4",
        "SDB",
        "Spotbuy",
        "SSP",
        "SSWS",
        "PWS",
        "WS",
        "Unknown",
    ); 
    croak "Unknown product: '$prod'" unless grep { $_ =~ /$prod/ } @prods;

    my $update = {};

    $update = { 'customfield_10609' => [{ set => [{ 'value' => $prod },], }] };

    if ( $self->{ 'debug' } ){
        print "Setting product for '$jira_id': '$prod'\n";
    }
    eval {
        $self->{ '_jira' }->update_issue( $jira_id, undef, $update );
    };
    croak $@ if $@;

    return;
}


=head1

=item set_assignee()

    FUNCTION: Set the assignee for a JIRA-ID

   ARGUMENTS: JIRA-ID, assignee (use the user's i/c-number)
           
     RETURNS: Nothing.  croak's on errors.

        NOTE: This DOES NOT WORK.  This value should be settable
              but the API tells me this is NOT settable.

=cut

sub set_assignee {
    my ( $self, $jira_id, $to ) = @_;

    my $update = {};

    unless ( $to =~ m/^(?:i|c)/i ){
        ## Not an i-number or c-number ...
        croak "Assignee '$to' not in i/c-number format.  Should be i###### or c######.\n";
    }

    #$update = { 'Assignee' => $to };
    $update = { 'assignee' => { 'name' => $to } };

    if ( $self->{ 'debug' } ){
        print "Setting assignee for '$jira_id': '$to'\n";
    }
    eval {
        $self->{ '_jira' }->update_issue( $jira_id, $update );
    };
    croak $@ if $@;

    return;
}


=head1

=item create_incident()

    FUNCTION: Create a ticket of type Incident

   ARGUMENTS: hashref, needs entries for 'description', 'summary' and 'team'
           
     RETURNS: Nothing.  croak's on errors.

=cut

sub create_incident {
    my ( $self, $args ) = @_;

    if ( $self->{ 'debug' } ){
        print "create_incident():\n";
        print Dumper $args;
    }

    my $data = {
        'description'       => $args->{ 'description' },
        'summary'           => $args->{ 'summary' },
        'issuetype'         => { 'name' => 'Incident' },
        'project'           => { 'key' => 'HOA' },
        'customfield_10625' => { 'value' => $args->{ 'team' } },
    };

    my $id = $self->_create_ticket( $data );

    return $id;
}


=head1

=item create_servicedesk()

    FUNCTION: Create a ticket of type Service Desk

   ARGUMENTS: hashref, needs entries for 'description', 'summary' and 'team'
           
     RETURNS: Nothing.  croak's on errors.

=cut

sub create_servicedesk {
    my ( $self, $args ) = @_;

    if ( $self->{ 'debug' } ){
        print "create_servicedesk():\n";
        print Dumper $args;
    }

    my $data = {
        'description'       => $args->{ 'description' },
        'summary'           => $args->{ 'summary' },
        'issuetype'         => { 'name' => 'Service Desk' },
        'project'           => { 'key' => 'HOA' },
        'customfield_10625' => { 'value' => $args->{ 'team' } },
    };

    my $id = $self->_create_ticket( $data );

    return $id;
}


=head1

=item create_automated()

    FUNCTION: Create a ticket of type OpsAutomated

   ARGUMENTS: hashref, needs entries for 'description', 'summary' and 'team'
           
     RETURNS: Nothing.  croak's on errors.

=cut

sub create_automated {
    my ( $self, $args ) = @_;

    if ( $self->{ 'debug' } ){
        print "create_servicedesk():\n";
        print Dumper $args;
    }

    my $data = {
        'description'       => $args->{ 'description' },
        'summary'           => $args->{ 'summary' },
        'issuetype'         => { 'name' => 'OpsAutomated' },
        'project'           => { 'key' => 'HOA' },
        'customfield_10625' => { 'value' => $args->{ 'team' } },
    };

    my $id = $self->_create_ticket( $data );

    return $id;
}

## Task is not a valid issuetype for the HOA project ...
## =head1
## 
## =item create_task()
## 
##     FUNCTION: Create a ticket of type Task
## 
##    ARGUMENTS: hashref, needs entries for 'description', 'summary' and 'team'
##            
##      RETURNS: Nothing.  croak's on errors.
## 
## =cut
## 
## sub create_task {
##     my ( $self, $args ) = @_;
## 
##     if ( $self->{ 'debug' } ){
##         print "create_task():\n";
##         print Dumper $args;
##     }
## 
##     my $data = {
##         'description' => $args->{ 'description' },
##         'summary'     => $args->{ 'summary' },
##         'issuetype'   => { 'name' => 'Task' },
##         'project'     => { 'key' => 'HOA' },
##         'customfield_10625' =>  { 'value' => $args->{ 'team' } },
##     };
## 
##    my $id = $self->_create_ticket( $data );
## 
##     return $id;
## }
## 

=head1

=item create_subtask()

    FUNCTION: Create a ticket of type Sub-task

   ARGUMENTS: parent ticket ID, hashref, needs entries for 'description', 'summary' and 'team'
           
     RETURNS: Nothing.  croak's on errors.

=cut

sub create_subtask {
    my ( $self, $parent, $args ) = @_;

    unless ( $parent && $parent =~ /^HOA/ ){
        croak "Missing or malformed parent ticket '$parent'";
    }

    if ( $self->{ 'debug' } ){
        print "create_subtask():\n";
        print Dumper $args;
        print "Parent: '$parent'\n";
    }

    my $data = { 
        'description'       => $args->{ 'description' },
        'summary'           => $args->{ 'summary' },
        'issuetype'         => { 'name'  => 'Sub-task' },
        'project'           => { 'key'   => 'HOA' },
        'customfield_10625' => { 'value' => $args->{ 'team' } },
        'parent'            => { 'key'   => $parent },
    };

    my $id = $self->_create_ticket( $data );

    return $id;
}


=head1

=item search()

    FUNCTION: Search tickets based on JQL criteria

   ARGUMENTS: JQL search string
           
     RETURNS: array of issues matching search criteria.  croak's on errors.

=cut

sub search {
    my $self = shift;
    my $jql = shift || croak "JQL required!!";
    my $ret = $self->{ '_jira' }->search_issues( $jql );

    return $ret;
}


=head1 PRIVATE METHODS

=item _create_ticket ()

    FUNCTION: Generic method for creating a ticket.

   ARGUMENTS: Ticket Type ('Service Desk', 'Change Request', 'Incident', 'Story', 'Feature', 'Task', 'Sub-task' or 'OpsAutomated')
           
     RETURNS: Ticket ID (or -1 if something non-fatal went wrong), croak's on errors

=cut

sub _create_ticket {
    my ( $self, $args ) = @_;

    my $type = $args->{ 'issuetype' }->{ 'name' };
    print "Type: '$type'\n" if $self->{ 'debug' };

    croak "Ticket type is a mandatory argument!\n" unless $type;
    croak "Unknown ticket type: '$type'\n" unless ( grep { $_ =~ /^$type$/ } keys %issuetypes );

    if ( $self->{ 'debug' } ){
        print "_create_ticket():\n";
        print Dumper $args;
    }

    delete $args->{ 'issuetype' }->{ 'name' };
    $args->{ 'issuetype' }->{ 'id' } = $issuetypes{ $type };

    ## Some default values:
    unless ( $type =~ /Sub-task/ ){ ## This is an error for a sub-task ...
        ## Default datacenter to "Not Applicable" ...
        $args->{ 'customfield_10608' } = [{ 'value' => 'Not Applicable', }];
        ## Default Ops Application Product to "Not Applicable" ...
        $args->{ 'customfield_10609' } = [{ 'value' => 'Not Applicable', }];
        ## Default Service to "Not Applicable" ...
        $args->{ 'customfield_10611' } = [{ 'value' => 'Not Applicable', }];
    }

    print "Creating a ticket of type '$type' ($issuetypes{ $type })\n" if $self->{ 'debug' };
    my $id = -1;

    ## Mandatory items for creating a ticket:
    ## my $issue = $jira->create({
    ##     # Jira issue 'fields' hash
    ##     project     => {
    ##         key => $project,
    ##     },
    ##     issuetype   => {
    ##         name => $type,
    ##     },
    ##     summary     => $summary,
    ##     description => $description,
    ##     ...
    ## });

    my $ret;
    eval {
        $ret = $self->{ '_jira' }->create( $args );
    };
    croak $@ if $@;

    print Dumper $ret if $self->{ 'debug' };
    ## $self->{ '_jira' }->create() returns:
    ##     {
    ##        id => 24066,
    ##        key => "TEST-57",
    ##        self => "https://example.atlassian.net/rest/api/latest/issue/24066"
    ##     }

    if ( $ret->{ 'key' } ){
        $id = $ret->{ 'key' };
    }

    return $id;
}


=head1 SEE ALSO

JIRA::Client::Automated - http://search.cpan.org/~frimicc/JIRA-Client-Automated-1.1/lib/JIRA/Client/Automated.pm

Jira REST API Reference - https://docs.atlassian.com/jira/REST/latest/

=head1 DEPENDENCIES

JIRA::Client::Automated - Actually we're using such an old version of Perl (and modules)
that you'll need the Ariba hacked version from Perforce:

//ariba/services/tools/lib/perl/JIRA/Client/Automated.pm

The big difference is that our version of HTTP::Request::Common does not support
DELETE.  Thus, none of the DELETE methods will work ...

JIRA::Client::Automated also makes use of // and //= (defined or/or-equals) which
our version of Perl is too old to support.

=head1 AUTHOR

Marc Kandel C<< <marc.kandel at sap.com> >>

=head1 LICENSE

Copyright 2014 Ariba, Inc. (an SAP Company)

=cut

1; # End of Module

__END__

