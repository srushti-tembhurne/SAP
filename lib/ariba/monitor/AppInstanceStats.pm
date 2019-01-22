package ariba::monitor::AppInstanceStats;

# $Id: //ariba/services/monitor/lib/ariba/monitor/AppInstanceStats.pm#3 $

use strict;
use vars qw(@ISA);
use ariba::monitor::Url;

@ISA = qw(ariba::monitor::Url);

sub newFromAppInstance {
	my $class = shift;
	my $appInstance = shift;

	my $monitorStatsUrl = $appInstance->monitorStatsURL();
	return undef unless ($monitorStatsUrl);

	# this is a temporary monitoring url, so to minimize amount of changes 
	# needed to remove it use the 'private' method.
	my $ssoClientStateUrl = 
		ariba::monitor::Url->new($appInstance->_directActionURLForCommand("validateSSOClientState/UserActions"));

	my $self = $class->SUPER::new($monitorStatsUrl);

	$self->setAppInstance($appInstance);
	$self->setSsoClientStateURL($ssoClientStateUrl);
	$self->setUseOutOfBandErrors();

	return $self;
}

#
# <?xml version="1.0"?>
# <xml>
# <monitorStatus>    
# <applicationName>ACM</applicationName>
# <applicationVersion>3.0</applicationVersion>
# <applicationBuildNumber>Ariba Spend Management 7.0 (build 4247, 09/13/2005)</applicationBuildNumber>
# <isDBConnectionOn>true</isDBConnectionOn>
# <AverageIdleSince>0</AverageIdleSince>
# <AverageSessionCacheSize>356</AverageSessionCacheSize>
# <AverageSessionLength>0</AverageSessionLength>
# <BackgroundQueue>0</BackgroundQueue>
# <Community>2</Community>
# <ConcurrentUserSessions>2</ConcurrentUserSessions>
# <ForegroundQueue>0</ForegroundQueue>
# <FreeMemory>858009</FreeMemory>
# <Hostname>robin.ariba.com</Hostname>
# <InMemoryMailQueueSize>11</InMemoryMailQueueSize>
# <LocalRealms>site1 (14 - assigned); realm_aqs_1 (5 - enabled); realm_pd_1 (11 - enabled); realm_gpd_fr (10 - enabled); realm_platform_2 (8 - enabled); realm_pd_2 (12 - enabled); realm_aqs_2 (6 - enabled); realm_aqs_4 (2 - enabled)</LocalRealms>
# <MaximumSessionCacheSize>1040</MaximumSessionCacheSize>
# <NodeManagerThreadPoolQueueSize>0</NodeManagerThreadPoolQueueSize>
# <NumAssignedRealms>13</NumAssignedRealms>
# <NumAuthenticationsPerPeriod>0</NumAuthenticationsPerPeriod>
# <NumDelegationsPerPeriod>0</NumDelegationsPerPeriod>
# <NumTotalRealms>25</NumTotalRealms>
# <NumUserConnectionsPerPeriod>0</NumUserConnectionsPerPeriod>
# <PersistedMailQueueSize>0</PersistedMailQueueSize>
# <ServerCacheSize>3273</ServerCacheSize>
# <ServerRoles>AribaUI</ServerRoles>
# <ThreadCount>135</ThreadCount>
# <TotalMemory>1179648</TotalMemory>
# <TotalUserConnections>0</TotalUserConnections>
# <UpTime>915</UpTime>
# <WorkflowQueue>0</WorkflowQueue>
# <sessions>-4</sessions>
# <state>running</state>
# <AnalysisDataLoads>0</AnalysisDataLoads>
# <AnalysisGlobalDataLoads>0</AnalysisGlobalDataLoads>
# <AnalysisGlobalSchemaRefreshes>0</AnalysisGlobalSchemaRefreshes>
# <AnalysisGlobalSchemaSwitches>0</AnalysisGlobalSchemaSwitches>
# <AnalysisGlobalTruncationOperations>1</AnalysisGlobalTruncationOperations>
# <AnalysisQueuedDataLoads>1</AnalysisQueuedDataLoads>
# <AnalysisQueuedSchemaRefreshes>0</AnalysisQueuedSchemaRefreshes>
# <AnalysisQueuedSchemaSwitches>0</AnalysisQueuedSchemaSwitches>
# <AnalysisQueuedTruncationOperations>0</AnalysisQueuedTruncationOperations>
# <AnalysisSchemaRefreshes>0</AnalysisSchemaRefreshes>
# <AnalysisSchemaSwitches>0</AnalysisSchemaSwitches>
# <AnalysisTruncationOperations>1</AnalysisTruncationOperations>
# </monitorStatus>
# </xml>
#

sub fetch {
	my $self = shift;

	#
	# Fetch the output of monitorStats direct action
	#
	my @results = $self->request();

	my $property;
	my $value;

	for my $line (@results) {
		last if ($self->error());
		if ($line =~ m|<(\w+)>\s*(.*)\s*</(\w+)>|i) {
			next if ($1 ne $3);

			$property = lcfirst($1);
			$value = $2;

			$self->setAttribute($property, $value);
		}
	}
}

# temporary check for S4 node logout problem,
# see monitor/bin/common/node-status and
# defect 1-1XIUJ.
#
sub fetchSSOClientState {
	my $self = shift;

	my @results = $self->ssoClientStateURL()->request();

	for my $line (@results) {
		if ($line =~ m/connection refused|timed out/i) {
			$self->setError($line);
		}
	}

	my $ssoClientState = shift(@results);

	return $ssoClientState;
}

1;
