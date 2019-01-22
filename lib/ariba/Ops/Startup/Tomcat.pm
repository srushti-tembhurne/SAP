package ariba::Ops::Startup::Tomcat;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/Tomcat.pm#95 $

use strict;

use File::Path;
use File::Basename;
use ariba::Ops::Startup::Common;
use ariba::Ops::ServiceController;

use ariba::rc::Utils;
use ariba::rc::InstalledProduct;
use ariba::Ops::Url;

my $envSetup = 0;

# Only do this once.
chomp(my $arch = lc(`uname -s`));
chomp(my $kernelName = `uname -s`);

sub setRuntimeEnv {
	my $me = shift;
	my $force = shift;

	my $tomcatHome = $me->tomcatHome();
	$ENV{'JAVA_HOME'} = ariba::Ops::Startup::Common::javaHomeForProduct($me);

	my @ldLibrary = (
		"$main::INSTALLDIR/lib/$kernelName",
		"$main::INSTALLDIR/internal/lib/$kernelName",
        );
       
	my @pathComponents = (
		"$ENV{'JAVA_HOME'}/bin",
		"$ENV{'ORACLE_HOME'}/bin",
		"$main::INSTALLDIR/bin",
		"$main::INSTALLDIR/internal/bin",
        );

	# maybe open $installDir/base/classes/classpath.txt and
	# add them to the class path.   For now hope
	# that installdir/base/classes will do

    ### Keep up the same order. Below order  matters in bringing up the nodes
    my @classes;

    ### Add instr classes into path
    if ( $ENV{'INSTR_MODE'} )
    {
        push (@classes, "$main::INSTALLDIR/instr_classes/patches");
        push (@classes, "$main::INSTALLDIR/instr_classes");
        push (@classes, "$main::INSTALLDIR/instr_classes/extensions");
        push (@classes, "$main::INSTALLDIR/instr_classes/endorsed");
    } else {
        push (@classes, "$main::INSTALLDIR/classes/patches");
        push (@classes, "$main::INSTALLDIR/classes");
        push (@classes, "$main::INSTALLDIR/classes/extensions");
        push (@classes, "$main::INSTALLDIR/classes/endorsed");
    }

    push(@classes, "$tomcatHome/lib");
    push(@classes, "$tomcatHome/bin");
    push(@classes, "$tomcatHome/server/lib");
    push(@classes, "$tomcatHome/common/lib");
    push(@classes, "$main::INSTALLDIR/internal/classes");

	ariba::Ops::Startup::Common::setupEnvironment(\@ldLibrary, \@pathComponents, \@classes);

	chdir("$main::INSTALLDIR") || die "ERROR: could not chdir to $main::INSTALLDIR, $!\n";

	$envSetup++;
}

sub updateClasspathFile {
	my $me = shift;
	my $jdbcDriverDir = shift;

	#
	# get the jdbc driver file by looking through contents of the
	# driver dir
	#
	opendir(DIR,$jdbcDriverDir) || return 0;
	my @zips = grep(/(zip)|(jar)$/o, readdir(DIR));
	close(DIR);

	my $extensionsDir = "classes/extensions";
	my $classes;
	my @allZips = ($extensionsDir);
	for my $zip (@zips) {
		push(@allZips, "$jdbcDriverDir/$zip");
	}

	#
	# Move the old classpath.txt file under extensions dir aside and
	# Add jdbc driver to classpath via extenstions/classpath.txt file
	#
	my $extensionsClassPathFile = $me->baseInstallDir() .  "/$extensionsDir/classpath.txt";
	my $savExtensionsClassPathFile = "$extensionsClassPathFile.sav";

	unless (-f $savExtensionsClassPathFile ) {
		rename($extensionsClassPathFile, $savExtensionsClassPathFile) || die "ERROR: could not rename $extensionsClassPathFile to $savExtensionsClassPathFile, $!\n";
		unlink($extensionsClassPathFile);
	}

	open(EXCLASSPATH, ">$extensionsClassPathFile") || die "ERROR: unable to open $extensionsClassPathFile, $!\n";
	print EXCLASSPATH "# auto generated file by ariba::Ops::Startup::ANL::updateClasspathFile()\n";
	for my $zip (@allZips) {
		print EXCLASSPATH "$zip\n";
	}
	close(EXCLASSPATH);

	return 1;
}

sub setASPRuntimeEnv {
	my $me = shift;

	my $baseRelease = $me->baseReleaseName();

	my $installDir = $me->installDir();

	my $tomcatHome = $me->tomcatHome();
	$ENV{'JAVA_HOME'} = $me->javaHome();

	# class path
	# ${ARIBA_INSTALL_ROOT}/classes
	my @ldLibrary = (
		"$main::INSTALLDIR/base/lib/$kernelName",
		"$main::INSTALLDIR/base/internal/lib/$kernelName",
        );
       
	my @pathComponents = (
		"$ENV{'JAVA_HOME'}/bin",
		"$ENV{'ORACLE_HOME'}/bin",
		"$main::INSTALLDIR/base/internal/bin",
		"$main::INSTALLDIR/base/bin",
		"$main::INSTALLDIR/bin",
        );


	# maybe open $installDir/base/classes/classpath.txt and
	# add them to the class path.   For now hope
	# that installdir/base/classes will do

	my $javaVersion = $me->javaVersion();
	my $jdbcVersion = $me->jdbcVersion();

	$javaVersion =~ s|(\d+\.\d+).*|$1|;

	my $jdbcDriverDir = "/usr/local/jdbc/$javaVersion/lib";

	if ($jdbcVersion) {
		$jdbcDriverDir = "/opt/jdbc-$jdbcVersion/$javaVersion/lib";
	}

	# temporary hack until we have jdbc-<version> package names
	unless (-d $jdbcDriverDir) {
		my $jdbcPackagePrefix = $jdbcVersion;
		$jdbcPackagePrefix =~ s/\.//g;
		$jdbcDriverDir = "/opt/jdbc$jdbcPackagePrefix-$jdbcVersion/$javaVersion/lib";
	}

	my @classes = (
		"$main::INSTALLDIR/base/classes/patches",
		"$main::INSTALLDIR/base/classes",
		$jdbcDriverDir,
		"$main::INSTALLDIR/base/classes/extensions",
		"$main::INSTALLDIR/base/classes/endorsed",
		"$tomcatHome/lib",
		"$tomcatHome/bin",
		"$tomcatHome/server/lib",
		"$tomcatHome/common/lib",
		"$main::INSTALLDIR/base/internal/classes",
	);

	ariba::Ops::Startup::Common::setupEnvironment(\@ldLibrary, \@pathComponents, \@classes);

	ariba::Ops::Startup::Tomcat::updateClasspathFile($me, $jdbcDriverDir);

	$envSetup++;

	chdir("$installDir/base") || die "ERROR: could not chdir to $installDir/base, $!\n";

}

sub _launch {
	my $me = shift;
	my $webInfSubDir = shift;
	my $apps = shift;
	my $role = shift;
	my $community = shift;
	my $updateConfigFile = shift;
	my $masterPassword = shift;
	my $appArgs = shift || "";
	my $additionalAppParamsHashRef = shift;


	ariba::Ops::Startup::Tomcat::setupTomcatForAppInstances($me, $role, $apps, $webInfSubDir);

	ariba::Ops::Startup::Common::prepareHeapDumpDir($me);

	return ariba::Ops::Startup::Tomcat::launchAppsForRole($me, $apps, $appArgs, $role, $community, $updateConfigFile, $masterPassword, $additionalAppParamsHashRef);

}

sub launch {
	my $me = shift;
	my $webInfSubDir = shift;
	my $apps = shift;
	my $role = shift;
	my $community = shift;
	my $masterPassword = shift;
	my $appArgs = shift || "";
	my $additionalAppParamsHashRef = shift;


	return ariba::Ops::Startup::Tomcat::_launch($me, $webInfSubDir, $apps, $role, $community, 0, $masterPassword, $appArgs, $additionalAppParamsHashRef);

}

sub aspLaunch {
	my $me = shift;
	my $webInfSubDir = shift;
	my $apps = shift;
	my $role = shift;
	my $community = shift;
	my $masterPassword = shift;
	my $appArgs = shift || "";

	return ariba::Ops::Startup::Tomcat::_launch($me, $webInfSubDir, $apps, $role, $community, 1, $masterPassword, "-logToConsole");
}

sub setupTomcatForAppInstances {
	my $me = shift;
	my $role = shift;
	my $apps = shift;
	my $webInfSubDir = shift;

	my $installDir = $me->installDir();
	my $productName = $me->name();
	my $configDir = $me->configDir();
	my $applicationContext = $me->default('Tomcat.ApplicationContext');
	my $cluster   = $me->currentCluster();

	my @appInstances = $me->appInstancesOnHostLaunchedByRoleInClusterMatchingFilter(ariba::Ops::NetworkUtils::hostname(),$role,$cluster,$apps);

	my $baseRoot = $me->default('Tomcat.Base');

	for my $appInstance (@appInstances) {
		my $name = $appInstance->instanceName();
		my $tomcatBaseDir = "$baseRoot/$name";
		my $webappsDir = "$tomcatBaseDir/webapps";
		my $webinf =  "$webappsDir/$applicationContext/WEB-INF";

		my $logs = "$tomcatBaseDir/logs";
		my $tmp = "$tomcatBaseDir/temp";
		my $work = "$tomcatBaseDir/work";
		my $conf = "$tomcatBaseDir/conf";
		my $lib = "$tomcatBaseDir/lib";

		#
		# Create sparse tree that will correspond to TOMCAT_BASE
		#
		rmdirRecursively($tomcatBaseDir);
		for my $dir ( $webinf, $logs, $tmp, $work, $conf, $lib ) {
			unless (-d $dir) {
				#FIXME
				# this makes $tomcatBaseDir and down owned by current
				# service user; need to fix permissions to allow
				# other service users to create their own
				# $tomcatBaseDir
				mkpath($dir) || die "ERROR: failed to create $dir: $!";
			}
		}

		$appInstance->setTomcatBase($tomcatBaseDir);
		$appInstance->setApplicationContext($applicationContext);
		$appInstance->setInstallDir($installDir);

		#
		# get the right deployment descriptor (web.xml) file in
		# WEB-INF dir
		#
		# Allow for overriding this file with ${AppName}-web.xml 
		#
		my ($j2eeDir, $internalJ2eeDir);
		if ($me->isASPProduct()) {
			$j2eeDir = "$installDir/base/etc/j2ee";
			$internalJ2eeDir = "$installDir/base/internal/etc/j2ee";
		} else {
			$j2eeDir = "$installDir/etc/j2ee";
			$internalJ2eeDir = "$installDir/internal/etc/j2ee";
		}
		#
		# For some reason creating symlink to this file makes
		# tomcat unhappy
		#

		my $targetWebxml = "$webinf/web.xml";
		my $targetWebxmlTmp = "$targetWebxml.tmp";

		my $customServletConfigFile = $appInstance->appName() . "-web.xml";
		if (-f "$internalJ2eeDir/$customServletConfigFile" ) {
			system("cp $internalJ2eeDir/$customServletConfigFile $targetWebxml");
		} else {
			system("cp $j2eeDir/$webInfSubDir/web.xml $targetWebxml");
		}

		my $targetErrorhtmlDir = "$webappsDir/$applicationContext";
		if (-f "$j2eeDir/$webInfSubDir/error.html" ) {
            # Copy all error html files from the application
			system("cp $j2eeDir/$webInfSubDir/error*.html $targetErrorhtmlDir");
		}

		#
		# check for and insert webxml chunk
		#
		# Chunkfile format consists of the first line that instructs
		# how to insert the chunk; every other line until the end of
		# the file is inserted into web.xml accordingly.
		#
		my $chunkFileParameter = 'Ops.WebXmlChunk';
		my $chunkFile = $me->default($chunkFileParameter);
		if ($chunkFile) {
			my $chunkFullPath = "$installDir/$chunkFile";
			if ( -f $chunkFullPath ) {
				open(CHUNK, "<$chunkFullPath") or die "ERROR: Can't read webxml chunk $chunkFullPath: $!";

				# first line contains instructions of the form
				# before:<someTagFromWebXml>
				#   or
				# after:<someOtherTagFromWebXml/>
				#
				my $line = <CHUNK>;
				my ($action, $tag) = ($line =~ m!\s*(\S+)\s*:\s*(\S+)\s*!);


				#
				# all following lines are the xml that is to be
				# inserted
				#
				my $chunk;
				do {
					local $/;
					$chunk = <CHUNK>;
				};

				close(CHUNK);

				open(WEBXML, "<$targetWebxml") or die "ERROR: can't read $targetWebxml: $!";
				open(WEBXMLTMP, ">$targetWebxmlTmp") or die "ERROR: Can't open tmp file $targetWebxmlTmp: $!";

				$tag = quotemeta($tag);
				while (my $line = <WEBXML>) {
					if ($action =~ /before/i && $line =~ /$tag/) {
						print (WEBXMLTMP $chunk);
					}

					print(WEBXMLTMP $line);

					if ($action =~ /after/i && $line =~ /$tag/) {
						print (WEBXMLTMP $chunk);
					}
				}
				close (WEBXMLTMP) or die "ERROR: Can't write out $targetWebxmlTmp: $!";
				close (WEBXML);
				rename ( $targetWebxmlTmp, $targetWebxml) or die "ERROR: Can't rename tmp file to $targetWebxml: $!";

			} else {
				warn "Expected web.xml chunk file specified in $chunkFileParameter parameter is not present in build";
			}
		}

		#
		# For SDB
		#
		my $wsddFile = "$j2eeDir/$webInfSubDir/server-config.wsdd";
		if (-f $wsddFile ) {
			system("cp $wsddFile $webinf/server-config.wsdd");
		}

		#
		# tomcat default web.xml to specify application independent
		# timeouts etc.
		#
		my $webXml = "web.xml";
		if (-f "$configDir/$webXml") {
			system("cp $configDir/$webXml $conf/$webXml");
		}

		#
		# Create font.properties file for use by mcharts in foreign
		# languages.
		#
		my $fontProperties = "font.properties";
		my $srcFontProps = "/usr/local/ariba/lib/jre/lib/$fontProperties.ariba.$arch.$productName";
		if ( -f $srcFontProps) {
			symlink($srcFontProps, "$lib/$fontProperties") || print "ERROR: Could not create symlink to $srcFontProps from $lib\n";
		}

		#
		# create tomcat server configuration file
		#
		my $templateServerXml = "$configDir/server.cfg";
		my $generatedServerXml = "$conf/$name.xml";

		generateServerConfigurationFileForAppInstance($me, $appInstance,
				$templateServerXml, $generatedServerXml);
		
		#
		# Cheat, set some useful attributes on appInstance
		#
		$appInstance->setServerConfigurationFile($generatedServerXml);
	}

	return @appInstances;
}

sub generateServerConfigurationFileForAppInstance {
	my $me = shift;
	my $appInstance = shift;
	my $templateConfig = shift;
	my $generatedConfig = shift;

	#
	# read in template config. populate the tokens and write it
	# back out
	#

	open(TMPL, $templateConfig) || die "Error: could not read template tomcat config file, $templateConfig, $!\n";
	sysread(TMPL, my $confString, -s TMPL);
	$confString =~ s/\r//g;
	close(TMPL);

	my $config;

	#
	# Initialize set of tokens that we might replace
	#
	$config->{HOST} = $appInstance->host();
	$config->{PORT} = $appInstance->port();
	$config->{HTTPPORT} = $appInstance->httpPort();
	$config->{SHUTDOWNPORT} = $appInstance->shutdownPort();
	$config->{WORKERNAME} = $appInstance->workerName();
	$config->{APPLICATIONCONTEXT} = $appInstance->applicationContext();
	$config->{INSTALLDIR} = $appInstance->installDir();

	#
	# Should the HttpOnly flag be set on session cookies to prevent
	# client side script from accessing the session ID?
	#
	$config->{USEHTTPONLYCOOKIES} = $me->default('Ops.Servercfg.UseHttpOnlySessionCookies');

	for my $from (sort (keys(%$config))) {

		my $to = $config->{$from};

		# Token can be an empty string.
		next unless defined $to;

		$to =~ s/^\s*//g;
		$to =~ s/\s*$//g;
		$confString =~ s/\*$from\*/$to/g;
	}

	chmod (0644, $generatedConfig);
	open(CONF, "> $generatedConfig") || die "Could not write config file $generatedConfig, $!\n";
	print CONF "<!--\nThis file generated by $0\n";
	print CONF "using $templateConfig as the template\n-->\n";
	print CONF $confString;
	close(CONF);

	return $confString;
}

#
# For code based on platform version < jupiter that
# did not support passing P.t values via command line,
# call this routine with updateConfigFile == 1
#
sub launchAppsForRole {
	my($me, $apps, $appArgs, $role, $community, $updateConfigFile, $masterPassword, $additionalAppParamsHashRef) = @_;

	my $cluster   = $me->currentCluster();
	my $rotateInterval = 24 * 60 * 60; # 1 day

	my @instances = $me->appInstancesOnHostLaunchedByRoleInClusterMatchingFilter(ariba::Ops::NetworkUtils::hostname(),$role,$cluster,$apps);

	my @launchedInstances;
	for my $instance (@instances) {

		my $instanceName = $instance->instance();

		my $instanceCommunity = $instance->community();

		if ($instanceCommunity && $community && $instanceCommunity != $community) {
			next;
		}
		
		push (@launchedInstances, $instance) ;

		my ($progArgs, $krArgs, $jvmArgs, $parametersRef) = composeLaunchArguments($me, $instance, $masterPassword, $additionalAppParamsHashRef);

		my $tomcatConfigFile = $instance->serverConfigurationFile();
		my %parameters  = %$parametersRef;

		#
		# All node specific properties are under:
		#
		# System.Nodes.Node<#>.Host
		# System.Nodes.Node<#>.Port
		# System.Nodes.Node<#>.InterNodePort
		# System.Nodes.Node<#>.ClassName
		# System.Nodes.Node<#>.ApplicatonServer
		#
		# When specified on command line in conjunction with
		# -nodename <Nodeid> these change to:
		#
		# System.Node.Host
		# System.Node.Port
		#
		# and so on...
		#

		#
		# Form ariba app related command line options
		#
		my $allArgs = "";

		#
		# All others args need to be set in P.t file
		# XXXXX locking?
		#
		if ($updateConfigFile) {
			my $productParameters = $me->parameters();
			my $parametersTable = $me->parametersTable();

			for my $arg (keys(%parameters)) {
				my $value = $parameters{$arg};
				$productParameters->setValueForKeyPath($arg, $value);
			}
			$productParameters->writeToFile($parametersTable);
		} else {
			for my $arg (keys(%parameters)) {

				#
				# Parameters that are overridden from
				# AppInfo.xml do not need AribaParameters
				# prefix (see asmadmin role for ex.). Only
				# the parameters from P.table need
				# AribaParameters prefix.
				#
				# Also if a arg starts with a '.' (abs path)
				# do not prepend AribaParameters and strip
				# off the leading '.'
				#
				my $paramName = $arg;
				if ($arg !~ m|^AribaAppInfo|) {
					if ($arg =~ m|^\.|) {
						$paramName = $arg;
						$paramName =~ s|^\.||;
					} else {
						$paramName = "AribaParameters.$arg";
					}
				}

				$allArgs .= " -D$paramName=$parameters{$arg}";
			}
		}

		my $catalinaMainClass = "org.apache.catalina.startup.Catalina";
        my $tomcatVersion = $me->tomcatVersion();
        if ($tomcatVersion eq '7.0.29' || $tomcatVersion eq '7.0.69') {
            $catalinaMainClass = "org.apache.catalina.startup.Bootstrap";
        }
		my $progToLaunch = join(" ",
				$me->javaHome($instance->appName()) . "/bin/java",
				$jvmArgs,
				$allArgs,
				"-DAriba.CommandLineArgs=\\\"$progArgs $appArgs\\\"",
				$catalinaMainClass,
				"-config $tomcatConfigFile",
				"start",
				);

		# I'm backing out this temporarily.
		# I assumed keepRunning runs the command in a shell, and it doesn't

		#my $niceness = $instance->niceness();
		#if (defined($niceness)) {
		#	$progToLaunch = join( " ", 
		#			ariba::rc::Utils::nicePrefix($niceness),
		#			$progToLaunch
		#		);
		#}

		my $com = "$main::INSTALLDIR/bin/keepRunning $krArgs -kp $progToLaunch";
		if (defined($masterPassword)) {
			ariba::Ops::Startup::Common::launchCommandFeedResponses($com, $masterPassword, "");
		} else {
			ariba::Ops::Startup::Common::runKeepRunningCommand($com);
		}
	}

	return @launchedInstances;
}

sub composeJGroupsArguments {
    my ($me, $instance, $parameters, $numInstancesInCommunity) = @_;

    my $instanceCommunity = $instance->community();
    my $numCommunities = $me->numCommunities();
    my @appInstances = $me->appInstances();
    my $totalAppInstances = scalar(@appInstances);

    my $baseMulticastIPAddress = $me->default('System.NodeManagers.Cluster.JGroups.UDP.mcast_addr');
    my @baseMulticastIPOctets = split(/\./, $baseMulticastIPAddress);
    
    my $communityMulticastIP;
    if ($baseMulticastIPAddress && $instanceCommunity) {
	
	$baseMulticastIPOctets[3] += $instanceCommunity;
	$communityMulticastIP = join('.', @baseMulticastIPOctets);
	
	#
	# XXXX: check to make sure we dont overflow ip address
	# octect handle this more gracefully by rolling over
	# to next octet
	#
	if ($baseMulticastIPOctets[3] >= 255) {
	    die "ERROR: multicast ip address last octet overflow: $communityMulticastIP, Exiting...\n";
	}
    }
    
    my $baseMulticastPort = $me->default('System.NodeManagers.Cluster.JGroups.UDP.mcast_port');
    my $communityMulticastPort;
    if ($baseMulticastPort && $instanceCommunity) {
	$communityMulticastPort = $baseMulticastPort + $instanceCommunity;
    }

    if (defined $instance->serverRoles()) {
	$parameters->{"System.NodeManagers.Cluster.JGroups.PING.num_initial_members"} = int($totalAppInstances/2) + 1;
    }

    #
    #
    # If the instance belongs to a community, we need to specify
    # community id and the multicast ip group that it should be part of
    #
    if ($numCommunities) {
	$parameters->{'.Ariba.NumCommunities'} = $numCommunities;
	$parameters->{'System.NodeManagers.Community.JGroups.PING.num_initial_members'} = int($numInstancesInCommunity/2) + 1;
	
	if (defined $instanceCommunity) {
	    $parameters->{'.Ariba.CommunityID'} = $instanceCommunity;
	    $parameters->{'System.NodeManagers.Community.JGroups.UDP.mcast_addr'} = $communityMulticastIP;
	    $parameters->{'System.NodeManagers.Community.JGroups.UDP.mcast_port'} = $communityMulticastPort;
	}  else {
	    $parameters->{'.Ariba.CommunityID'} = 0;
	}
    }
}



sub composeLaunchArguments {
	my($me, $instance, $masterPassword, $additionalAppParamsHashRef) = @_;

	my $launched  = 0;
	my $cluster   = $me->currentCluster();
	my $rotateInterval = 24 * 60 * 60; # 1 day
	my $instanceName = $instance->instanceName();
    my $nodeName;
	if ($me->isLayout(5)) {
		$nodeName = $instance->logicalName();
	}
	else {
	    $nodeName = $instance->workerName();
	}
	my $service  = $me->service();

	#
	# Community related stuff
	#
	my $instanceCommunity = $instance->community();
	my $numCommunities = $me->numCommunities();
	my @appInstances = $me->appInstances();
	my $totalAppInstances = scalar(@appInstances);
	my $numInstancesInCommunity = 0;
	if ($numCommunities) {
		#
		# instanceCommunity can be undef, make it be 0 so
		# we dont get perl warns in compare below
		#
		my $matchComm = $instanceCommunity || 0;
		for my $inst (@appInstances) {
			my $comm = $inst->community() || 0;
			if ($comm == $matchComm) {
				$numInstancesInCommunity++;
			}
		}
	}

	my %parameters  = ();
	if (defined $additionalAppParamsHashRef) {
		%parameters = %$additionalAppParamsHashRef;
	}

	#
	# XXXX for anl instanceNames are hardcoded to Node1 in config
	# files and in the code. Since we dont do multinode for anl
	# yet, set Nodename to be Node1 for now.
	#
	if ($me->name() eq "anl") {
		$nodeName = "Node1";
	}
	#
	# XXX for ACM, set Ssytem.Base.PrimaryNode to the nodes real name;
	# this is needed in order for things like scheduledTasks to load properly
	#  
	elsif ($me->name() eq "acm") {
		$parameters{"System.Base.NodeName"} = $nodeName;
		$parameters{"System.Base.PrimaryNode"} = $nodeName;
	}

	#
	# All node specific properties are under:
	#
	# System.Nodes.Node<#>.Host
	# System.Nodes.Node<#>.Port
	# System.Nodes.Node<#>.InterNodePort
	# System.Nodes.Node<#>.ClassName
	# System.Nodes.Node<#>.ApplicatonServer
	#
	# When specified on command line in conjunction with
	# -nodename <Nodeid> these change to:
	#
	# System.Node.Host
	# System.Node.Port
	#
	# and so on...
	#
	$parameters{"System.Nodes.$nodeName.ClassName"} = "ariba.base.server.Node";
	$parameters{"System.Nodes.$nodeName.ApplicationServer"} = $nodeName;

	if (defined $instance->rpcPort()) {
		$parameters{"System.Nodes.$nodeName.Port"} = $instance->rpcPort();
	} 

	if (defined $instance->httpPort()) {
		$parameters{"System.Nodes.$nodeName.HttpPort"} = $instance->httpPort();
	}

	if (defined $instance->internodePort()) {
		$parameters{"System.Nodes.$nodeName.InterNodePort"} = $instance->internodePort();
	} 
	if (defined $instance->host()) {
		$parameters{"System.Nodes.$nodeName.Host"} = $instance->host();
	} 
	if (defined $instance->serverRoles()) {
		my $roleString = $instance->serverRoles();
		$roleString =~ s/\|/,/g;

		$parameters{"System.Nodes.$nodeName.ServerRole"} = "\'\($roleString\)\'";
		unless ($numCommunities) {
			my @similarInstances = $me->appInstancesWithNameInCluster($instance->appName(), $cluster);
			my $numNodes = scalar(@similarInstances);
			$parameters{"System.RealmAffinity.ExpectedNumberOfNodes"} = $numNodes;
		}
	} 
	#
	#
	# If the instance belongs to a community, we need to specify
	# community id and the multicast ip group that it should be part of
	#
	if ($numCommunities) {
		$parameters{'.Ariba.NumCommunities'} = $numCommunities;

		if (defined $instanceCommunity) {
			$parameters{'.Ariba.CommunityID'} = $instanceCommunity;
		}  else {
			$parameters{'.Ariba.CommunityID'} = 0;
		}
	}

	if (defined($me->default('Ops.Topology.MulticastIp'))) {
		my $topologyFile = $instance->tomcatBase() ."/Topology.table"; 
	    composeClusterGroupArguments($me, $topologyFile, \%parameters);
	}
	else {
	    composeJGroupsArguments($me, $instance, \%parameters, $numInstancesInCommunity);
	}

	#
	# need to override some URLs to point to admin web server for
	# adminapps
	#
	if ($instance->launchedBy() eq "asmadmin" ||
		$instance->launchedBy() eq "ssadmin"  ||
	    $instance->launchedBy() eq "buyeradmin" ||
	    $instance->launchedBy() eq "cdbuyeradmin") {

		my $adminFrontDoorTop = $me->default("VendedUrls.AdminFrontDoorTopURL");

		$parameters{"AribaAppInfo.IncomingHttpServerURL"} = $adminFrontDoorTop;
		$parameters{"AribaAppInfo.InternalURL"} = $adminFrontDoorTop;
	}


	if ( grep { $me->name() eq $_ } (ariba::rc::Globals::sharedServiceBuyerProducts()) ) {
		#
		# Calculate total search node count for buyer
		# this should really be in Buyer.pm, but we're currently
		# missing the ability to pass in P.table overrides in from there
        my $numSearchNodes = searchNodeCount($me);
        if ($numSearchNodes > 1 && $me->isLayout(4)) {
            $numSearchNodes = $numSearchNodes/2;
        }
		$parameters{'System.Catalog.Search.NumSearchNodes'} = $numSearchNodes;
	}

	if ( grep  { $me->name() eq $_ } (ariba::rc::Globals::sharedServiceSourcingProducts(), ariba::rc::Globals::sharedServiceBuyerProducts()) ) {
		$parameters{'System.Base.DRClusterId'} = $me->currentCluster();
		unless (defined($me->default('Ops.Topology.MulticastIp'))) {
                        $parameters{"System.Nodes.$nodeName.RecycleGroup"} = $instance->recycleGroup(); }

	}


	my $tomcatBase = $instance->tomcatBase();
	my $tomcatHome = $me->tomcatHome();

    my $prettyName = $instanceName;
    $prettyName .= "--" . $instance->logicalName() if $instance->logicalName();

	# kr options
	my $krArgs = join(" ",
			"-d",
			"-kn $prettyName",
			"-ko",
			"-ks $rotateInterval",
			"-ke $ENV{'NOTIFY'}",
			"-kk",
			);

	if (!(ariba::Ops::ServiceController::isProductionServicesOnly($service))) {
		$krArgs .= " -kc 2";
	}

	if ($me->name() eq "anl" || $me->name() eq "acm") {
		$krArgs .= " -ki";
	}

	if ( grep  { $me->name() eq $_ } (ariba::rc::Globals::sharedServiceSourcingProducts(), ariba::rc::Globals::sharedServiceBuyerProducts(), "s2", "sdb", "help") ) {
		$krArgs .= " -kb";
	}

	#
	# Form ariba app related command line options
	#
	my $progArgs = "-nodeName $nodeName";

	if ($masterPassword) {
		$progArgs .= " -readMasterPassword";
		$krArgs .= " -km -";
	}

	#
	# Form the command to launch VM
	#
	my $appName = $instance->appName();
	my $startHeapSize = $me->default("Ops.JVM.$appName.StartHeapSize") || 
		$me->default('Ops.JVM.StartHeapSize') || 
		$me->default('Ops.JVM.StartHeapSizeInMB') || 
		$me->default('System.Base.ToolsDefault.JavaMemoryStart');
	my $maxHeapSize = $me->default("Ops.JVM.$appName.MaxHeapSize") ||		
		$me->default('Ops.JVM.MaxHeapSize') || 
		$me->default('Ops.JVM.MaxHeapSizeInMB') || 
		$me->default('System.Base.ToolsDefault.JavaMemoryMax');
	my $stackSize =  $me->default("Ops.JVM.$appName.StackSize") ||
		$me->default('Ops.JVM.StackSize') || 
		$me->default("Ops.JVM.StackSizeInMB") ||
		$me->default('System.Base.ToolsDefault.JavaStackJava');

	$startHeapSize .= 'M' if ($startHeapSize =~ /\d$/o);
	$maxHeapSize .= 'M' if ($maxHeapSize =~ /\d$/o);
	$stackSize .= 'M' if ($stackSize =~ /\d$/o);

	my $startSize = $startHeapSize;
	$startSize =~ s/M$//i;
	$startSize *= 1024 if ($startSize =~ s/G$//i);

	my $newSize;
	if ($startSize >= 512) {
		$newSize = "384M";
	} else {
		$newSize = $startSize/2 . "M";
	}

	#
	# Debug param for JVM for remote debugging
	#
	my $debugPort = $ENV{'ARIBA_JVM_DEBUG_PORT'} || "";

	#
	# Allow for just an offset to be specified in case there
	# are multiple instances on the same machine. Offset is
	# applied to the port (derived from BasePort in appflags).
	# So for ex:
	#
	# setenv ARIBA_JVM_DEBUG_PORT_OFFSET 500
	#
	# will add 500 to port for each instance
	#
	my $debugPortOffset = $ENV{'ARIBA_JVM_DEBUG_PORT_OFFSET'};
	if ($debugPortOffset) {
		$debugPort = $instance->port() + $debugPortOffset;
	}

	my $debugOpts = "-Xdebug -Xnoagent -Xrunjdwp:transport=dt_socket,server=y,suspend=n,address=$debugPort";
	my $jvmDebugOpts = "";

	if ($debugPort && !(ariba::Ops::ServiceController::isProductionServicesOnly($service))) {
		$jvmDebugOpts = $debugOpts;
	}

	my $additionalSpecifiedVmArgs = $me->default("Ops.JVM.$appName.Arguments") || $me->default('Ops.JVM.Arguments') || $me->default('System.Base.ToolsDefault.JavaVMArguments'); 
	#
	# commenting out for now as engr needs to resolve issue on how the app handles this parameters values
	#$additionalSpecifiedVmArgs = $me->default('System.Base.ToolsDefault.BuyerCatalogJavaVMArguments') if ($instance->serverRoles() =~ /CatalogSearch/);
	#
	my $additionalVmArgs = "";

	my $instanceVmArgs = $me->default("Ops.JVM.$appName.ArgumentsAppend");	
	if ($instanceVmArgs) {
		$instanceVmArgs = join(' ', @$instanceVmArgs) if (ref($instanceVmArgs) eq 'ARRAY');
		if ($additionalSpecifiedVmArgs) { 
			if (ref($additionalSpecifiedVmArgs) eq "ARRAY") {
				push(@$additionalSpecifiedVmArgs, $instanceVmArgs);
			} else {
				$additionalSpecifiedVmArgs .= ' ' . $instanceVmArgs;
			}
		} else { 
			$additionalSpecifiedVmArgs = $instanceVmArgs;
		}
	}

	#
	# additional jvm args specified in P.table come back as an array,
	# but if specified in DD.xml (help product) come back as a string.
	# handle both cases.
	#
	if ($additionalSpecifiedVmArgs) {
		if (ref($additionalSpecifiedVmArgs) eq "ARRAY") {
			if (@$additionalSpecifiedVmArgs) {
				$additionalVmArgs = join(" ", @$additionalSpecifiedVmArgs);
			}
		} else {
			$additionalVmArgs = $additionalSpecifiedVmArgs;
		}
	}
	
	#P9R2-3208: java 8 use MaxMetaspaceSize instead of MaxPermSize
    my $cmd = $me->javaHome($instance->appName()) . "/bin/java -version 2>&1";
	my $jrev = `$cmd`;
	my $jrevstr = substr $jrev, index($jrev, '.')+1,1;
	my $vmArgsMaxSize = ($jrevstr gt 7) ? "-XX:MaxMetaspaceSize=128M" : "-XX:MaxPermSize=128M";
	unless ($additionalVmArgs) {
		$additionalVmArgs = join(" ",
					"$vmArgsMaxSize",
					"-XX:NewSize=$newSize",
					"-XX:MaxNewSize=$newSize",
					"-XX:SurvivorRatio=1",
					);
	}

	#
	# if one of this signal is set to USR2, then we need to tell vm
	# to use a different Signal for its internal use.
	#
	# TMID: 23858
	#
	my $graceFulSig = $me->default('System.Shutdown.Signals.GracefulShutdown');
	my $forceSig = $me->default('System.Shutdown.Signals.ForcefulShutdown');

	my $useAltSignal = 0;
	my @shutdownSignals = ();

	for my $signal ($graceFulSig, $forceSig) {
		if ($signal) {
			my @sigArray;

			#
			# DD.xml does not have a good way to represent arrays; expect
			# a comma-delimited string in that case

			if (ref($signal) ){  # P.table case
				@sigArray = @$signal;

			} else {  # DD.xml case
				@sigArray = split(/,/, $signal);
			}

			push(@shutdownSignals, @sigArray);
		}
	}

	for my $sig (@shutdownSignals) {
		if ($sig eq "USR2") {
			$useAltSignal = 1;
			last;
		}
	}

	if ($useAltSignal) {
		if ($arch eq "sunos") {
			$additionalVmArgs .= " -XX:+UseAltSigs";
		} elsif ($arch eq "linux") {
			$ENV{'_JAVA_SR_SIGNUM'} = 50;
		}
	}

	my $aribaSecurityProperties = $me->default("Ops.AribaSecurityProperties");
	if ($aribaSecurityProperties) {
		$additionalVmArgs .= " -Djava.security.properties=file:${aribaSecurityProperties}";
	}

	my $yourKitArgs = "";
	if (0 && $me->default('Ops.YourKit.Enabled') && $me->default('Ops.YourKit.Enabled') eq "true") {
		$yourKitArgs = "-agentlib:yjpagent=port=" . $instance->yourKitPort();

		#
		# If user specified additional your kit args in
		# parameters.table, append those here
		#
		my $additionalYourKitArgs = $me->default('Ops.YourKit.AdditionalArgs') || "";
		$yourKitArgs .= $additionalYourKitArgs;
	}

	my $openOfficeArgs = "";
	if( $instance->launchedBy() eq 'asmglobaltask' ) {
		my $openOffice = getPairedOpenOfficeInstance($me, $instanceName);
		if($openOffice) {
			my $openOfficeHost = $openOffice->host();
			my $openOfficePort = $openOffice->port();

			$openOfficeArgs .= "-DAribaParameters.System.Nodes.$nodeName.OpenOfficePort=$openOfficePort ";
			$openOfficeArgs .= "-DAribaParameters.System.Nodes.$nodeName.OpenOfficeHost=$openOfficeHost";
		}
	}

    my ($tomcatEndorsed, $installRootEndorsed, $endorsedDirs);
	$tomcatEndorsed = "$tomcatHome/common/endorsed";
    if ($me->isASPProduct()) {
        $installRootEndorsed = "$main::INSTALLDIR/base/classes/endorsed";
    } else {
        ### Check if instance name is present in the RunTimeInstrumentationConfig.
        ### If present, - rerun setup enviroment (hack) and run in instrumented mode, otherwise - standard mode

        $ENV{'INSTR_MODE'} = $me->is_instance_instrumented($instanceName);          ### Either 0 or 1
        ariba::Ops::Startup::Tomcat::setRuntimeEnv($me);

        ### Run in instrumented mode or not
        $installRootEndorsed = ( $ENV{'INSTR_MODE'} ) ? "$main::INSTALLDIR/instr_classes/endorsed" : "$main::INSTALLDIR/classes/endorsed";
    }
    $endorsedDirs = "$installRootEndorsed:$tomcatEndorsed";    

	
	my $jvmArgs = join(" ",
		"-server",
		"-Xms$startHeapSize",
		"-Xmx$maxHeapSize",
		"-Xss$stackSize",
		ariba::Ops::Startup::Common::expandJvmArguments($me,$prettyName, $additionalVmArgs, $parameters{'.Ariba.CommunityID'}),
		$openOfficeArgs,
		$yourKitArgs,
		$jvmDebugOpts,
		"-Duser.home=$tomcatBase",
		"-Djava.util.prefs.userRoot=$tomcatBase",
		"-Djava.util.prefs.systemRoot=$tomcatBase",
		"-Dcatalina.home=$tomcatHome",
		"-Dcatalina.base=$tomcatBase",
		"-Djava.endorsed.dirs=$endorsedDirs",
	);

	return ($progArgs, $krArgs, $jvmArgs, \%parameters);
}

sub getPairedOpenOfficeInstance {
	my $me = shift;
	my $instanceName = shift;

	my @gtnodes = $me->appInstancesLaunchedByRoleInCluster(
					'asmglobaltask', $me->currentCluster() );
	my @oonodes = $me->appInstancesLaunchedByRoleInCluster(
					'asmopenoffice', $me->currentCluster() );

	my ($gt, $oo);
	while ( ($gt = shift(@gtnodes)) && ($oo = shift(@oonodes)) ) {
		return($oo) if( $gt->instanceName() eq $instanceName );
	}

	return undef;
}

sub searchNodeCount {
    my $me = shift;

    my @instances = $me->appInstancesInCluster($me->currentCluster());
    my $nodeCount = 0;

    for my $instance (@instances) {
        if (defined $instance->serverRoles()) {
            if ($instance->serverRoles() =~ /CatalogSearch/) {
                $nodeCount++;
            }
        }
    }
    return $nodeCount;
}

sub newCommunityMulticastIP {
    my ($me, $community) = @_;

    my $baseMulticastIPAddress = $me->default('Ops.Topology.MulticastIp');
    my $baseMulticastPort = $me->default('Ops.Topology.MulticastPort');

    my $communityMulticastPort;
    $communityMulticastPort = $baseMulticastPort + $community;

    return ($baseMulticastIPAddress, $communityMulticastPort);
}

###########################################
# This method parses the topology.table file 
# and returns the map of logical node name 
# and node id.
###########################################

sub getNodeIdMapFromTopologyString { 
    my $result = shift;
    my %nodeNameAndIdMap = (); 
    my $maxNodeId=-1;
    if(!defined($result)){
        print "Result string which contains topology data is not defined\n";
        return (\%nodeNameAndIdMap, $maxNodeId); 
    }
    my @lines = split /\n/, $result;
    foreach my $line (@lines)  {   
        chomp($line);        
        # check if the line contains nodekey
        if($line =~ m/nodekey/i){            
            # format nodekey = logicalnodename:nodeid;
            $line=~s/\s+//g;
            # split line by "="
            my($key,$value)= split(/=/,$line,2);
            # replace ";" with empty character
            $value=~ s/;//g;            
            # split logicalnodename:nodeid by ":"
            my($nodeName,$nodeId)=split(/:/,$value);             
            $nodeNameAndIdMap{$nodeName}=$nodeId; 
            $maxNodeId=$nodeId if($nodeId>$maxNodeId);
        }     
    }       
    return (\%nodeNameAndIdMap,$maxNodeId);
}

###########################################
# This method returns the node id for the 
# given logical node name.
###########################################

sub getNodeIdFromOldTopology { 
    my $ptrNodeIdMapFromOldTopology=shift;
    my $ptrMaxNodeId=shift;
    my $nodeName=shift;
 
    # if the map is not empty and logical node name contains in the map 
    # then the node id is taken from map, else maxNodeId+1 is returned
    if(defined($ptrNodeIdMapFromOldTopology) && exists($ptrNodeIdMapFromOldTopology->{$nodeName})){        
        return $ptrNodeIdMapFromOldTopology->{$nodeName};
    }
    else{
        ${$ptrMaxNodeId}++;
        return ${$ptrMaxNodeId};
    } 
}

###########################################
# This method retrieves the old topology 
# file and returns the map of logical 
# node name and node id of the old topology
###########################################

sub getIdAndNameHashMapFromOldTopology { 
    my $me = shift;
    my $oldBuildName = shift;
    my $LAYOUT_VERSION_5 = '^v5$';
    if ($me->isLayout(5)) {
        my $result = copyTopologyFromWebServersToLocal($me, $oldBuildName);
        return getNodeIdMapFromTopologyString($result);
    }
    else {
        my %nodeNameAndIdMap = ();
        my $maxNodeId=-1;                   
        return (\%nodeNameAndIdMap, $maxNodeId);
    }
}

###########################################
# This method retrieves the topology
# file from the web server
###########################################

sub getTopologyDataFromWeb
{
    my $thisProduct = shift;
    my $oldBuildName = shift;
    my $result;
    my $weburl = $thisProduct->default('VendedUrls.AdminFrontDoorTopURL');
    my $srcUrl  = $weburl . "/topology/" . $thisProduct->name() . "/CentralizedTopologyTables/CentralizedTopology_" . $oldBuildName . ".table";
    my $request = ariba::Ops::Url->new($srcUrl);
    print "calling direct action: $srcUrl\n"."\n";
    $result = $request->request(60);
    return $result;
}

###########################################
# This method retrieves the old topology 
# file from the webserver to the local machine
###########################################
sub copyTopologyFromWebServersToLocal {  
    my $thisProduct = shift;
    my $oldBuildName = shift;
   
    if(!defined($oldBuildName)){
        $oldBuildName = $thisProduct->buildName();
    }
    my $result = getTopologyDataFromWeb($thisProduct, $oldBuildName);
    return $result;
}

sub composeClusterGroupArguments {
    my ($me, $topologyFile, $parameters, $oldBuildName) = @_;
    
    my ($ptrNodeIdMapFromOldTopology,$maxNodeId) = getIdAndNameHashMapFromOldTopology($me, $oldBuildName);

    if(defined($parameters)) { 
        $parameters->{'System.Topology'} = $topologyFile;
    }

    open(F, "> $topologyFile") || die "Could not create topology file";;

    print F "{\n Groups = {\n";

    for (my $community = 0;$community <= $me->numCommunities();$community++) {
        my ($mc, $mp) = newCommunityMulticastIP($me,$community);
        print F "  $community = { mcastAddress = $mc; mcastPort = $mp; };\n";
    }
    print F " };\n Nodes = {";
    

    my @instances = $me->appInstancesInCluster($me->currentCluster());

    my @instanceNames = ();
    my %instances;
    for my $instance (@instances) {
        if (defined $instance->serverRoles() && $instance->isTomcatApp()) {
            my $instanceName;
            if($me->isLayout(5)) {
                $instanceName = $instance->logicalName();
            } else {
                $instanceName = $instance->workerName();
            }
            $instances{$instanceName} = $instance;
            push @instanceNames, $instanceName;
        }
    }
    @instanceNames = sort(@instanceNames);

    for (my $instanceNum = 0;$instanceNum < scalar(@instanceNames);$instanceNum++) {
        my $instanceName = $instanceNames[$instanceNum];
        my $instance = $instances{$instanceNames[$instanceNum]};
    
        my $nodeId = getNodeIdFromOldTopology($ptrNodeIdMapFromOldTopology,\$maxNodeId,$instanceName);
        
        print F "  " . $instanceName . " = {\n";
        # Added a nodekey field to parse the topology table file easily. 
        # nodekey is a combination of nodename and nodeid.
        print F "   nodekey = ".$instanceName.":$nodeId;\n";
        print F "   id = $nodeId;\n";
        print F "   host = " . $instance->host() . ";\n";
        print F "   groups = { 0 = " . $instance->clusterPort() . ";";
        if ($instance->community() && $instance->community() > 0) {
            print F $instance->community() . " = " . $instance->communityPort() . ";";
        }
        print F "};\n";

        print F "   port = " . $instance->httpPort() . ";\n";
        print F "   failPort = " . $instance->failPort() . ";\n";
        print F "   rpcPort = " . $instance->rpcPort() . ";\n";
        print F "   udpPort = " . $instance->internodePort() . ";\n";
        if (defined $instance->backplanePort()) {
            print F "   backplanePort = " . $instance->backplanePort() . ";\n";
        }
        my $roles = $instance->serverRoles();
        $roles =~ s/\|/\,/g;
        print F "   roles = ( $roles );\n";
        print F "   peers = ( " . (($nodeId+1) % scalar(@instanceNames)) . ");\n";
        print F "   recycleGroup = " . $instance->recycleGroup() . ";\n";
        print F "   physicalName = " . $instance->workerName() . ";\n";
        print F "  };\n";
    }
    print F " };\n";
    print F "}";

    close(F);
}

1;

__END__
