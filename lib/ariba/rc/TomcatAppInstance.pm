package ariba::rc::TomcatAppInstance;

use strict;

use base qw(ariba::rc::AbstractAppInstance);
use URI::Escape;

=pod

=head1 NAME

ariba::rc::TomcatAppInstance

=head1 VERSION

$Id: //ariba/services/tools/lib/perl/ariba/rc/TomcatAppInstance.pm#76 $

=head1 DESCRIPTION

A TomcatAppInstance is a model of a Tomcat-based application instance.

=head1 SEE ALSO

ariba::rc::AbstractAppInstance, ariba::rc::AppInstanceManager, ariba::rc::Product

=over 8

=item * $self->logURL()

Return the URL where logviewer makes the keepRunning logs for this instance available.

=cut

=pod

=item * $self->monitorStatsURL()

Return the URL for the "monitorStats" direct action

=cut

sub monitorStatsURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("monitorStats"));
}

=pod

=item * $self->masterDataServiceStatsURL()

Return the URL for the "MasterDataServiceStats" direct action, the 'command' is mdsMonitor,
which will become part of the URL.

=cut

sub masterDataServiceStatsURL {
    my $self = shift;

    return $self->_directActionURLForCommand("mdsMonitor");
}

=pod

=item * $self->masterDataServiceScheduledTaskStatusURL

Return the URL for Master Data Services Scheduled Tasks direct action, 'command' is mdsScheduledTaskStatus.

=cut

sub masterDataServiceScheduledTaskStatusURL{
    my $self = shift;

    return $self->_directActionURLForCommand("mdsScheduledTaskStatus");
}

=pod

=item * $self->durableEmailStatsURL()

Return the URL for the "DurableEmailStats" direct action

=cut

sub durableEmailStatsURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("DurableEmailStats"));
}

sub reportingJobStatsURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("ReportingJobStats"));
}

sub systemRebuildURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("SystemRebuildStatus"));
}


sub vikingDatabaseStatusURL {
    my $self = shift;
    return ($self->_directActionURLForCommand("vikingDatabaseStatus"));
}

sub databaseStatusURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("databaseStatus"));
}

sub internodesResponseTimeMonitorURL {
    my $self = shift;
    my $communityScoped = shift;

    my $url = $self->_directActionURLForCommand("internodesResponseTime");

    if ($communityScoped) {
        $url .= '&scope=community';
    }

    return ($url);
}

sub isGlobalCoordinatorURL {
    my $self = shift;

    # http://bejpro.ariba.com:8550/Sourcing/Main/ad/isGlobalCoordinator/MonitorActions
    return ($self->_directActionURLForCommand("isGlobalCoordinator"));
}

sub getGlobalCoordinatorURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("getGlobalCoordinator"));
}

sub postUpgradeTaskURL {
    my $self = shift;
    my $taskName = shift;

    my $url = $self->_directActionURLForCommand("runScheduledTask/PostRollingUpgradeTaskActions");
    if ($taskName) {
        $url .= "?taskName=$taskName";
    }
    return $url;
}

sub postUpgradeTaskStatusURL {
    my $self = shift;
    return $self->_directActionURLForCommand("PostUpgradetaskStatus");
}

sub clusterGroupStatusURL {
    my $self = shift;
    return $self->_directActionURLForCommand("clusterGroupsStatus");
}

sub postUpgradeErroredTasksURL {
    my $self = shift;
    return $self->_directActionURLForCommand("getErroredTasks/PostUpgradeTaskDirectAction");
}

sub postUpgradeRunningTasksURL {
    my $self = shift;
    return $self->_directActionURLForCommand("getRunningTasks/PostUpgradeTaskDirectAction");
}

sub rollingRestartSuspectURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("rollingRestartSuspect"));
}

sub rollingRestartPrepareURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("rollingRestartPrepare"));
}

sub countNodesURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("countNodes"));
}

sub testSystemAccessLockURL {
    my $self = shift;
    return ($self->_directActionURLForCommand("lockTestSystemAccess/ariba.testmanager.admin.TestServerActions"));
}

sub testSystemAccessUnlockURL {
    my $self = shift;
    return ($self->_directActionURLForCommand("unlockTestSystemAccess/ariba.testmanager.admin.TestServerActions"));
}

sub testSystemAccessStatusURL {
    my $self = shift;
    return ($self->_directActionURLForCommand("testSystemAccessStatus/ariba.testmanager.admin.TestServerActions"));
}

sub applicationActivityURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("applicationActivity"));
}

sub ccmServerStatusURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("ccmServerStatus"));
}

sub scheduledTasksMonitorURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("scheduledTasks"));
}

sub tasksRanLongerThanThresholdURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("TasksRanLongerThanThreshold"));
}

sub tasksRunningLongerThanThresholdURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("TasksRunningLongerThanThreshold"));
}

sub freeTextSearchIndexHealthURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("freeTextSearchOpsMonitoring"));
}

sub backgroundExceptionsMonitorURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("backgroundExceptions/BuyerMonitorActions"));
}

sub documentQueueSizeMonitorURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("documentQueueSize/BuyerMonitorActions"));
}

sub unprocessedCXMLInvoiceActionMonitorURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("unprocessedCXMLInvoice/BuyerMonitorActions"));
}

# tmid 190047
sub contractSURCountURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("contractSURCount/BuyerMonitorActions"));
}

sub catalogSelfTestAdminMonitorURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("selfTestAdmin/BuyerMonitorActions"));
}

sub catalogSelfTestRegistryMonitorURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("selfTestRegistry/BuyerMonitorActions"));
}

sub catalogSelfTestSearchServerMonitorURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("selfTestSearchServer/BuyerMonitorActions"));
}

sub catalogSearchClientStatusMonitorURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("searchClientStatus/BuyerMonitorActions"));
}

sub archesCatalogSearchClientStatusMonitorURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("archesClientStatus/BuyerMonitorActions"));
}

sub archesCatalogPublishMetricsMonitorUrl {
    my $self = shift;

    return ($self->_directActionURLForCommand("publishStatus/BuyerMonitorActions"));
}

sub archesCatalogPerRealmPublishMonitorUrl {
    my $self = shift;

    return ($self->_directActionURLForCommand("publishErrorsPerRealm/BuyerMonitorActions"));
}

sub requisitionsRealmURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("reqCount/BuyerMonitorActions"));
}

sub lateSystemUsageReportsURL {
    my $self = shift;
    my $dayslate = shift || 7;

    return ($self->_directActionURLForCommand("lateSystemUsageReports/MonitorSystemUsageReportActions?dayslate=$dayslate"));
}

sub adminSystemUsageReportsURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("adminRealms/MonitorSystemUsageReportActions"));
}

sub signalRollingRecycleOperationURL {
    my $self = shift;
    my $operation = shift;
    my $verb = shift;

    my $baseUrl = $self->_directActionURLForCommand("shutdownManager/ariba.htmlui.coreui.MonitorActions");
    my $url = $baseUrl . "&" . "action=Rolling${operation}${verb}";

    return $url;
}

sub businessProcessMonitorURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("businessProcessMon/BuyerMonitorActions"));
}

sub isRealmToCommunityMapUpToDateURL {
    my $self = shift;
    return ($self->_directActionURLForCommand("isRealmToCommunityMapUpToDate/ClusterTransitionDirectAction"));
}

sub beginTransitionURL {
    my $self = shift;
    return ($self->_directActionURLForCommand("refreshClusterTransitionState/ClusterTransitionDirectAction"));
}

sub endTransitionURL {
    my $self = shift;
    return ($self->_directActionURLForCommand("refreshClusterTransitionState/ClusterTransitionDirectAction"));
}

sub enterRealmReabalance {
    my $self = shift;
    return ($self->_directActionURLForCommand("enterRealmReabalance/ClusterTransitionDirectAction"));
}

sub exitRealmReabalance {
    my $self = shift;
    return ($self->_directActionURLForCommand("exitRealmReabalance/ClusterTransitionDirectAction"));
}

sub enterCapacityChange {
    my $self = shift;
    return ($self->_directActionURLForCommand("enterCapacityChange/ClusterTransitionDirectAction"));
}

sub exitCapacityChange {
    my $self = shift;
    return ($self->_directActionURLForCommand("exitCapacityChange/ClusterTransitionDirectAction"));
}

sub refreshClusterTransitionStateURL {
    my $self = shift;
    return ($self->_directActionURLForCommand("refreshClusterTransitionState/ClusterTransitionDirectAction"));
}

sub stopBackplaneURL {
    my $self = shift;
    return ($self->_directActionURLForCommand("stopBackplane/ClusterTransitionDirectAction"));
}

sub rebindMessagesURL {
    my $self = shift;
    return ($self->_directActionURLForCommand("rebindMessages/ClusterTransitionDirectAction"));
}

sub refreshL2PMapURL {
    my $self = shift;
    return ($self->_directActionURLForCommand("refreshL2PCache/ClusterTransitionDirectAction"));
}

sub refreshTopologyURL {
    my $self = shift;
    return ($self->_directActionURLForCommand("refreshTopology/ClusterTransitionDirectAction"));
}

sub testServerRunQual {
    my $self = shift;
    my $qualType = shift;
    my $components = shift;
    my $keywordFilter = shift;
    my $testId = shift;
    my $migrationMode = shift;
    my $executionPhase = shift;

    my $recipients = shift;
    my $sender = shift;

    my $component = undef;
    if ($components) {
        $component = join('&component=', split(/,/,$components));
    } else {
        $component = $self->productName();
        $component = "ssp" if $component eq "buyer";
    }

        my $httpArgs = join('&', (
                                "sendTestReport=false",
                                "component=$component",
                                "qual=$qualType",
                                )
                        );

    if ($keywordFilter) {
        $httpArgs .= "&keywordFilter=" . uri_escape($keywordFilter);
    }
    if ($testId) {
        $httpArgs .= "&testRunId=" . $testId;
    }
    if ($migrationMode) {
        $httpArgs .= "&migrationMode=" . $migrationMode;
    }
    if ($executionPhase) {
        $httpArgs .= "&executionPhase=" . $executionPhase;
    }

    if ($sender)  {
        $httpArgs .= "&sendTestReport=true";
        $httpArgs .= "&sendTestReportFrom=" . uri_escape($sender);
        for my $reportRecipient (split(/,\s*/, $recipients)) {
            $httpArgs .= "&sendTestReportTo=" . uri_escape($reportRecipient);
        }
    }

    my $baseUrl = $self->_directActionURLForCommand("runqual");
        my $url = $baseUrl . '?' . $httpArgs;

    return $url;
}

sub testServerCheckQualPhase {
    my $self = shift;
    my $testId = shift;
    my $executionPhase = shift;

    my $component = $self->productName();
    $component = "ssp" if $component eq "buyer";

    my $httpArgs = "testRunId=$testId";
    if (defined($executionPhase)) {
        $httpArgs .= "&executionPhase=$executionPhase";
    }

    my $baseUrl = $self->_directActionURLForCommand("checkqualphase");
        my $url = $baseUrl . '?' . $httpArgs;

    return $url;
}

sub testServerCheckQualStatus {
    my $self = shift;
    my $testId = shift;
    my $executionPhase = shift;

    my $httpArgs = "testRunId=$testId";
    if (defined($executionPhase)) {
        $httpArgs .= "&executionPhase=$executionPhase";
    }

    my $baseUrl = $self->_directActionURLForCommand("checkqualstatus");
        my $url = $baseUrl . '?' . $httpArgs;

    return $url;
}

#                                                                         
#                                                                         
# 1. If even one task has failed the status will be reported back as      
# "Failed".                                                               
#                                                                         
# 2. If all tasks have "Completed" the status will be reported back as    
# "Completed".                                                            
#                                                                         
# 3. If even one task is "Running" and none of the tasks have "Failed" the
# status will be reported back as "Running".                              
#                                                                         
# 4. If some tasks have "Not Started" and all other remaining tasks are   
# "Completed" then we will return "Not Started"                           
#                                                                         
# 5. If some tasks have "Not Started" and some tasks are "Running" and none
# of the tasks have "Failed" the status will be reported back as "Running".

sub canStartQualURL {
    my $self = shift;

    my $url = $self->_directActionURLForCommand("canStartBQorLQ/PostUpgradeMonitorAction");

    return $url;
}

sub buyerCatalogIndexPublishStatus {
    my $self = shift;
    my $waitTime = shift;

    my $url = $self->_directActionURLForCommand("rebuildBuyerCatalog");
    if ( $waitTime ) {
        $waitTime *= 1000;
            $url .= "?MaxWaitTime=$waitTime" 
    }

    return $url;
}

sub invalidateBuyerCatalogSearchVersionsURL {
    my $self = shift;
    return ($self->_directActionURLForCommand("invalidateBuyerCatalogSearchVersions"));
}

sub persistentQueueURL {
    my $self = shift;
    return ($self->_directActionURLForCommand("persistentQueue"));
}

=pod

=item * $self->schemaRealmMappingStatusMonitorURL()
Url to retrieve the results of realm-schema mapping scheduled task
https://devwiki.ariba.com/bin/view/Main/DBSchemaRealmMappingVerificationTask

=cut

sub schemaRealmMappingStatusMonitorURL {
    my $self = shift;
    
    return ($self->_directActionURLForCommand("schemaRealmMappingStatus"));
}

sub realmPurgeStatusURL {
    my $self = shift;
    #http://amandal:8080/ACM/Main/ad/realmPurgeStatus/MonitorActions

    return ($self->_directActionURLForCommand("realmPurgeStatus"));
}

sub cdsActivityURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("CdsActivity"));
}


sub searchIndexStatusURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("sc/search/ruok"));
}

sub searchIndexResponseURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("searchmetrics"));
}

sub archesNodeRuokUrl {
    my $self = shift;

    return ($self->_directActionURLForCommand("archesNodeRuok"));
}

sub archesQueueMessageGetURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("archesQueueMessage"));
}

sub shardStatusURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("api/shardstatus"));
}

sub shardSizeURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("sc/shardsize"));
}

sub jobsUrlForType {
    my $self = shift;
    my $type = shift;

    return ($self->_directActionURLForCommand("api/jobs/$type"));
}

sub nrtMetricsMonitoringURL {
    my $self = shift;
    return ( $self->_directActionURLForCommand( "nrtMetricsMonitoring" ) );
}

sub indexManagerMonitoringURL {
    my $self = shift;
    return ( $self->_directActionURLForCommand( "indexManagerMonitoring" ) );
}

=pod

=item * $self->inspectorURL()

Return the URL for accessing inspector functionality

=cut

sub inspectorURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("inspector"));
}

=pod

=item * $self->killURL()

Return the URL for accessing kill functionality

=cut

sub killURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("kill"));
}

=pod

=item * $self->shutdownURL()

Return the URL for accessing shutdown functionality

=cut

sub shutdownURL {
    my $self = shift;

    return ($self->_directActionURLForCommand("shutdown"));
}

=pod

=back

=head1 PRIVATE INSTANCE METHODS

=over 8

=item * $self->_directActionURLForCommand($command)

=cut

# This is a manually contructed direct action url for MDS:
#   https://  app184.lab1.ariba.com  :7559/   Buyer/     Main/       ad/   mdsMonitor/  MonitorActions
#   protocol     Host name            port    product    DA Parent   ??    command         ???

sub _directActionURLForCommand {
    my $self    = shift;
    my $command = shift;

    my $host      = $self->host();
    my $port      = $self->httpPort();
    my $context   = $self->applicationContext();
    my $secureDirectAction = $self->manager()->product()->default('Ops.Monitoring.SecureDirectAction');
    my $requireHttps = $self->manager()->product()->default('RequireHTTPS')||'';
    my $protocol = ( $secureDirectAction || ($requireHttps =~ /YES/i) ) ? 'https' : 'http';
    # in the arches case, urls for direct action do not start
    # with Main.  They start with api instead.  
    my $directActionParent = 'Main';
    $directActionParent = 'api' if ( grep {$self->productName() eq $_} ariba::rc::Globals::archesProducts() );

    my $urlPrefix;
    my $urlSuffix;

    if ($command eq "monitorStats") {
        if ( $self->monitorUrl() ) {
           $urlSuffix = $self->monitorUrl();
           return "$protocol://$host:$port$urlSuffix";
        } else {
           $urlSuffix = "$directActionParent/ad/$command/AWMonitorActions";
        }
    } elsif ($command eq "vikingDatabaseStatus" ) {
        $urlSuffix = "$directActionParent/ad/databaseStatus/BaseUIMonitorActions";
    } elsif ($command eq "kill" || $command eq "shutdown" || $command eq "freeTextSearchOpsMonitoring") {
        $urlSuffix = "$directActionParent/ad/$command";
    } elsif ($command eq "inspector") {
        $urlSuffix = "$command";
    } elsif ($command eq "runqual") {
        $urlSuffix = "$directActionParent/ad/runTests/ariba.testmanager.admin.TestServerActions";
    } elsif ($command eq "checkqualphase") {
        $urlSuffix = "$directActionParent/ad/testRunPhase/ariba.testmanager.admin.TestServerActions";
    } elsif ($command eq "checkqualstatus") {
        $urlSuffix = "$directActionParent/ad/testRunStatus/ariba.testmanager.admin.TestServerActions";
    } elsif ($command eq "rebuildBuyerCatalog") {
        $urlSuffix = "$directActionParent/ad/waitForPublish/ariba.catalog.admin.ui.publish.PublisherDirectAction";
    } elsif ($command eq "invalidateBuyerCatalogSearchVersions") {
        $urlSuffix = "$directActionParent/ad/invalidateSearchVersions/ariba.catalog.admin.ui.publish.PublisherDirectAction";
    } elsif ( $command =~ /^(?:api|sc)\//o ) {       # Used by Arches DA's
        $urlSuffix = $command;
    } elsif ( $command eq 'indexManagerMonitoring' ) {
        $context = 'inspector';
        $urlSuffix = 'web/info/object.htm?objectName=ariba.searchinfrastructure%3aname%3dIndexerJobStatus';
    } elsif ($command eq 'nrtMetricsMonitoring') {
        $urlSuffix = "api/nrtmetrics/summary?reset=true";
    } elsif ($command =~ m|/|) {
        $urlSuffix = "$directActionParent/ad/$command";
    } elsif ($command eq "archesNodeRuok") {
        $urlSuffix = "api/nodestatus/ruok";
    } elsif ($command eq "archesQueueMessage") {
        $urlSuffix = "api/queuemessage/getallcount";
    } elsif ($command eq "searchmetrics") {
        $urlSuffix = "search/searchmetrics";
    } elsif ($command eq "SystemRebuildStatus") {
        $urlSuffix = "api/jobs/systemrebuildstatus";
    } elsif ($command eq "ReportingJobStats") {
        $urlSuffix = "$directActionParent/ad/$command/ariba.htmlui.coreui.MonitorActions";
    } else {
        $urlSuffix = "$directActionParent/ad/$command/MonitorActions";
    }

    $urlPrefix = "$protocol://$host:$port/$context";

    return "$urlPrefix/$urlSuffix" if $command eq "inspector" 
                       or $command eq "runqual" 
                       or $command eq "checkqualphase"
                       or $command eq "checkqualstatus"
                       or $command eq "rebuildBuyerCatalog"
                       or $command eq "invalidateBuyerCatalogSearchVersions"
                       or $command eq "indexManagerMonitoring"
                       or $command eq "nrtMetricsMonitoring"
                       or $command eq "archesNodeRuok"
                       or $command eq "archesQueueMessage"
                       or $command eq "searchmetrics"
                       or $command eq "DurableEmailStats"
                       or $command eq 'mdsMonitor'
                       or $command eq 'mdsScheduledTaskStatus'
                       or $command eq "SystemRebuildStatus"
                       or $command =~ /^runScheduledTask/;
    return "$urlPrefix/$urlSuffix?awpwd=awpwd";
}

sub supportsRollingRestart {
    my $self = shift;

    return 1;
}

1;
