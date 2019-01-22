#!/usr/local/bin/perl
package Discovery;

use strict;
use FindBin;
use File::Basename;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../lib/perl";
use Data::Dumper;
use ariba::rc::InstalledProduct;
use ariba::Ops::Machine;
use ariba::rc::Utils;
use ariba::rc::Passwords;
use JSON;
use Parallel::ForkManager;
use Term::ANSIColor;

#--------------------------------------------------------------------------------------------------------------------------------------
# Purpose : Section for various getter-setter methods
#--------------------------------------------------------------------------------------------------------------------------------------
my $debug = 0;

sub getDataCenter { my $self = shift; return $self->{datacenter}; }

sub getProductName { my $self = shift; return $self->{product}; }

sub getProductRoleName { my $self = shift; return $self->{product_role}; }

sub getConfigPath { my $self = shift; return $self->{config_path}; }

sub getHostName { my $self = shift; return $self->{host}; }

sub getCluster { my $self = shift; return $self->{cluster}; }

sub isDRSite { my $self = shift; return $self->{drSite}; }

sub isFailOver { my $self = shift; return $self->{failover}; }

sub getMonitorConfigFiles {
    my $self = shift;
    return @{ $self->{monitor_config_list} };
}

sub getMacDBHostList { my $self = shift; return $self->{host_macdb_type_map}; }

sub getMacDBHostListClean {
    my $self = shift;
    return $self->{host_macdb_type_clean};
}

sub getTelegrafOutputConfig {
    my $self = shift;
    return $self->{telegraf_output_config};
}

sub getTelegrafOutputConfigTemplate {
    my $self = shift;
    return $self->{telegraf_output_config_template};
}

sub getTelegrafOutput { my $self = shift; return $self->{telegraf_output}; }

sub getTelegrafOutputFile {
    my $self = shift;
    return $self->{telegraf_output_file};
}

sub getHostProductTag { my $self = shift; return $self->{host_product_tag}; }

sub getTransferUser { my $self = shift; return 'mon' . $self->{service}; }

sub getTelegrafConfigTemplate {
    my $self = shift;
    return $self->{telegraf_config_template};
}

sub getTransferUserPassword {
    my $self = shift;
    return ariba::rc::Passwords::lookup( $self->{transfer_user} );
}

sub setDebugModeOn { $debug = 1; }

sub setDebugModeOff { $debug = 0; }

sub _setAttribute {
    my ( $self, $attrName, $attrValue ) = @_;
    $self->{$attrName} = $attrValue;
}

our @machineDbHostTypes;

sub compileConfigs {
    my $self       = shift;
    my $dataCenter = $self->getDataCenter();
    my $me         = ariba::rc::InstalledProduct->new();

    #print Dumper($me);
    my $cluster = $me->currentCluster();
	
    $self->_setAttribute( 'service',       $me->service() );
    $self->_setAttribute( 'transfer_user', 'mon' . $me->service() );
    $self->_setAttribute( 'config_path',
        "$FindBin::Bin/../../base/config" );

    ariba::rc::Passwords::initialize( $self->{service} );

    my @productConfigList = ();
    my %matchDatacenter   = ();
    my @provideServices   = ();
   
    foreach my $prod ( ariba::rc::InstalledProduct->installedProductsList() ) {

        print "Cluster : :".$cluster." getProductName() is "
          . $self->getProductName()
          . " prod->name is "
          . $prod->name() . "\n"
          if ($debug);
        next
          if ( $self->getProductName()
            && ( $prod->name() ne $self->getProductName() ) );
        print "--------------------------------------------------\n"
          if ($debug);
        print "Compiling Configurations for : " . $prod->name() . "\n"
          if ($debug);
	print "Current Cluster : " . $prod->currentCluster(). " Argument : $cluster\n" if($debug);
        print "--------------------------------------------------\n"
          if ($debug);
        my %productConfig;
	my $prodCluster = $prod->currentCluster();
	#if($self->isDRSite()) {
	#	if($prodCluster eq 'primary') {
	#		$prodCluster = 'secondary';
	#	}else{
	#		$prodCluster = 'primary';
	#	}
	#}
        #next unless ( $prodCluster eq $cluster );
        $productConfig{name} = $prod->name();
	################################################################
        my @roles = $prod->allRolesInCluster($cluster);
	@roles = grep { $_ !~ /^dr-/i } @roles;
	foreach my $roleName ( @roles ) {
            print "getProductRoleName() is "
              . $self->getProductRoleName()
              . " roleName is "
              . $roleName . "\n"
              if ($debug);
            next
              if ( $self->getProductRoleName()
                && ( $roleName ne $self->getProductRoleName() ) );
            print "--------------------------------------------------\n"
              if ($debug);
            my @hostPropertyList = ();
	    my $roleCluster;	 



		if($self->isDRSite()) {
			$roleCluster = 'secondary';
		}else {
			$roleCluster = 'primary';
		}



	    print "Role Name : $roleName, Cluster : $cluster \n" if ($debug);
            $productConfig{$roleName} =
              [ $prod->hostsForRoleInCluster( $roleName, $roleCluster ) ];
            foreach
              my $host ( $prod->hostsForRoleInCluster( $roleName, $roleCluster ) )
            {
                print "Getting Machine DB entires for the Host : $host ....."
                  if ($debug);
               $self->_getMachineRolesFromMacDB( $dataCenter, $host, $roleName );
            }
        }
	###############################################################
        #$productConfig{product} = $prod;
        push( @productConfigList, \%productConfig );
    }
    $self->_setAttribute( 'host_macdb_type_map', \@machineDbHostTypes );
    $self->_setAttribute( 'product_config_list', \@productConfigList );
}

sub _clenseCompileConfigData {
    my $self = shift;

    #Remove all those records which does not have a server_type
    my @newConfigList = ();
    foreach my $host ( @{ $self->getMacDBHostList() } ) {
        print "host is $host->{name}\n" if ($debug);
        if ( $host->{name} && $host->{product} && $host->{server_type} ) {
            push( @newConfigList, $host );
        }
    }
    for ( my $i = 0 ; $i <= $#newConfigList ; $i++ ) {
        for ( my $j = $i + 1 ; $j <= $#newConfigList ; $j++ ) {
            if (
                ( $newConfigList[$i]->{name} eq $newConfigList[$j]->{name} )
                && ( $newConfigList[$i]->{product} eq
                    $newConfigList[$j]->{product} )
                && ( $newConfigList[$i]->{server_type} eq
                    $newConfigList[$j]->{server_type} )
              )
            {
                splice( @newConfigList, $j, 1 );
                $i--;
                last;
            }
        }
    }
    $self->_setAttribute( 'host_macdb_type_clean', \@newConfigList );
}

#--------------------------------------------------------------------------------------------------------------------------------------
# Purpose : Read all the valid hosts
#         : Check if the host is shared by another product
#         : Create an attribute - tag_name which contains <product1>!!<product2>...<productN> if shared product
#         : If not a shared product tag_name = <product>
#--------------------------------------------------------------------------------------------------------------------------------------

sub prepareHostMetricData {
    my $self     = shift;
    my @hostList = @{ $self->getMacDBHostListClean() };
    for ( my $i = 0 ; $i <= $#hostList ; $i++ ) {
        $hostList[$i]->{tag_name} = $hostList[$i]->{product};
        for ( my $j = $i + 1 ; $j <= $#hostList ; $j++ ) {
            if (   ( $hostList[$i]->{name} eq $hostList[$j]->{name} )
                && ( $hostList[$i]->{product} ne $hostList[$j]->{product} ) )
            {
                $hostList[$i]->{tag_name} || '!!' . $hostList[$j]->{product};
                splice( @hostList, $j, 1 );
                $i--;
                last;
            }
        }
    }
    $self->_setAttribute( 'host_product_tag', \@hostList );
}

sub _getMachineRolesFromMacDB {
    my ( $self, $dataCenter, $host, $roleName ) = @_;
    my %matchDatacenter = (
        status     => 'inservice',
        datacenter => $dataCenter,
        hostname   => $host
    );
    my %hostDetails = ( name => $host );
    my @machines =
      ariba::Ops::Machine->machinesWithProperties(%matchDatacenter);
	
    my $serverTypeMap = { mon                 => "mon",
                          httpvendor          => "web",
                          database            => "db",
                          "product-db-server" => "db",
                          "hadoop-name"       => "hadoopname",
                          hanadatabase        => "hana",
                          smtp                => "util",
                        };

    # first check roles.cfg... if cant find there for this host,
    # look at machineDB to provide a service type
    foreach my $roleBeginning ( keys %$serverTypeMap ) {
        if ( index($roleName, $roleBeginning) == 0 ) {
	            $hostDetails{server_type} = $serverTypeMap->{$roleBeginning};
	}
    }
    if(defined ($hostDetails{server_type}) && (defined $machines[0])){
       push( @machineDbHostTypes, \%hostDetails );

   } elsif ( (!defined $hostDetails{server_type}) && (defined $machines[0]) ) {
       if ( $machines[0]->provides('web') && $machines[0]->provides('stratustelegraf') ) {
           $hostDetails{server_type} = 'web';
           print "Success(web)\n" if ($debug);
       }
       elsif ( $machines[0]->provides('mon') && $machines[0]->provides('stratustelegraf')) {
           $hostDetails{server_type} = 'mon';
           print "Success(mon)\n" if ($debug);
       }
       elsif ( $machines[0]->provides('hadoop') && $machines[0]->provides('stratustelegraf') ) {
           $hostDetails{server_type} = 'hadoop';
           print "Success(hadoop)\n" if ($debug);
       }
       elsif ( $machines[0]->provides('app') && $machines[0]->provides('stratustelegraf')) {
           $hostDetails{server_type} = 'app';
           print "Success(app)\n" if ($debug);
       }
       elsif ( $machines[0]->provides('snmp') && $machines[0]->provides('stratustelegraf') ) {
           $hostDetails{server_type} = 'util';
           print "Success(util)\n" if ($debug);
       }
       elsif ( $machines[0]->provides('db') && $machines[0]->provides('stratustelegraf')) {
           $hostDetails{server_type} = 'db';
           print "Success(DB)\n" if ($debug);
       }
       elsif ( $machines[0]->provides('hana') && $machines[0]->provides('stratustelegraf')) {
           $hostDetails{server_type} = 'hana';
           print "Success(hana)\n" if ($debug);
       }
       else {
           print "Warn(***Not Mapped***)\n" if ($debug);
           print "[  WARN!  ] [$host] Host type not defined in Iris\n"
             if ( !$debug );
       }
       push( @machineDbHostTypes, \%hostDetails );
   } else {
       #if ( ! defined $hostDetails{server_type} ) {
           print "Error: Unable to find details in machinedb\n" if ($debug);
           print "[ ERROR!! ] [$host] Unable to find records in MachineDB\n"
             if ( !$debug );
           return;
       #}
   }	

}

our $_rpsConfigData    = {};
our $_outputConfigData = {};

sub readRPSConfigFile {
    my $self = shift;

    my $configPath = $self->getConfigPath();

    my $json;
    {
        local $/;
        open my $fh, "<", $configPath . '/telegraf_inputs_by_product_role.json'
          || die "Unable to open telegraf_inputs_by_product_role.json $!";
        $json = <$fh>;
        close $fh;
    }

    my $data = decode_json($json);

    #print Dumper($data);
    $_rpsConfigData = $data;
    return $data;
}

#Loop thorugh the products in the datacenter
#Get the mapping of product-role-hosts : compileConfigs
#Get the mapping of machine & machine-db roles : getMachineRolesFromMacDB
#Get the details pf product-role-script from rps.conf file : readRPSConfigFile
#Mode 1 - All - Loop through the entire list of products and its hosts for all roles. Find the equivallent roles in machinedb. Get the script name using productname - machinedb role.

sub init {
    my $self = shift;
    $self->compileConfigs();
    $self->readRPSConfigFile();
    $self->_mapProductRoleToMacDbRole();
    $self->_clenseCompileConfigData();
    $self->_readTelegrafOutputConfig();
    $self->_readTelegrafConfigTemplate();

#Hardcoding the user creentials here
#username and password of the remote host (root), has to be obtained through ciferstore or vault

    #$self->_setAttribute('','');

    #print Dumper %_rpsConfigData;
}

sub genConfig {
    my $self = shift;
    $self->_genTelegrafExecBlock();
    $self->_genTelegrafOutputFile();
    $self->prepareHostMetricData();
    $self->_genTelegrafHostFiles();
}

sub initNoConfigGen {
    my $self = shift;
    $self->compileConfigs();
    $self->_mapProductRoleToMacDbRole();
    $self->_clenseCompileConfigData();

}

sub getRunStatus {
    my $self     = shift;
    my @hostList = @{ $self->getMacDBHostListClean() };
    print
"------------------------------------------------------------------------------------------\n";
    print "Show Agent Run Status\n";
    print
"------------------------------------------------------------------------------------------\n";
    print
"------------------------------------------------------------------------------------------\n";
    printf( "%s%-40s%s%-47s%s\n", "|", " Host Name", "|", " Run Status", "|" );
    print
"------------------------------------------------------------------------------------------\n";
    my $pm = new Parallel::ForkManager(5);

    my $seen = {};
    foreach my $host (@hostList) {
        $seen->{ $host->{name} } ? next : ( $seen->{ $host->{name} } = 1 );
        $pm->start and next;
        $self->_runTelegrafStatus($host);
        $pm->finish;
    }
    $pm->wait_all_children;
    print
"------------------------------------------------------------------------------------------\n";
}

sub startAgent {
    my $self     = shift;
    my @hostList = @{ $self->getMacDBHostListClean() };
    print
"------------------------------------------------------------------------------------------\n";
    print "Start Iris Agents\n";
    print
"------------------------------------------------------------------------------------------\n";
    print
"------------------------------------------------------------------------------------------\n";
    printf( "%s%-40s%s%-47s%s\n", "|", " Host Name", "|", " Start Status",
        "|" );
    print
"------------------------------------------------------------------------------------------\n";
    my $pm   = new Parallel::ForkManager(5);
    my $seen = {};
    foreach my $host (@hostList) {
        $seen->{ $host->{name} } ? next : ( $seen->{ $host->{name} } = 1 );
        $pm->start and next;
        $self->_startTelegrafAgent($host);
        $pm->finish;
    }
    $pm->wait_all_children;
    print
"------------------------------------------------------------------------------------------\n";
}

sub stopAgent {
    my $self     = shift;
    my @hostList = @{ $self->getMacDBHostListClean() };
    print
"------------------------------------------------------------------------------------------\n";
    print "Stop Iris Agents\n";
    print
"------------------------------------------------------------------------------------------\n";
    print
"------------------------------------------------------------------------------------------\n";
    printf( "%s%-40s%s%-47s%s\n", "|", " Host Name", "|", " Stop Status", "|" );
    print
"------------------------------------------------------------------------------------------\n";
    my $pm   = new Parallel::ForkManager(5);
    my $seen = {};
    foreach my $host (@hostList) {
        $seen->{ $host->{name} } ? next : ( $seen->{ $host->{name} } = 1 );
        $pm->start and next;
        $self->_stopTelegrafAgent($host);
        $pm->finish;
    }
    $pm->wait_all_children;
    print
"------------------------------------------------------------------------------------------\n";
}

sub exportGenFiles {
    my $self            = shift;

    my @monitorFileList = $self->getMonitorConfigFiles();
    print "monitorFileList: " . Dumper(@monitorFileList) if ($debug);
    my @hostList = @{ $self->getMacDBHostListClean() };
    print "hostList: " . Dumper(@hostList) if ($debug);
    my $pm = new Parallel::ForkManager(5);
    foreach my $host (@hostList) {
        $pm->start and next;
		#if($self->isFailOver()){
		#	$self->_removeTelegafConfigs($host);
		#}
        $self->_runTransferCommands($host);

        # don't intermingle a restart with an export of the
        # generated files
        # $self->_runTelegrafRestart($host);

        $pm->finish;
    }
    $pm->wait_all_children;
}

sub restartAgents {
    my $self     = shift;

    my $pm       = new Parallel::ForkManager(5);
    my @hostList = @{ $self->getMacDBHostListClean() };
    my $seen     = {};
    foreach my $host (@hostList) {
        $seen->{ $host->{name} } ? next : ( $seen->{ $host->{name} } = 1 );
        $pm->start and next;
        $self->_runTelegrafRestart($host);
        $pm->finish;
    }
    $pm->wait_all_children;
}

sub _genTelegrafHostFiles {
    my $self       = shift;
    my @hostList   = @{ $self->getHostProductTag() };
    my $dataCenter = $self->getDataCenter();

    foreach my $host (@hostList) {
        my $template = $self->getTelegrafConfigTemplate();
        $template =~ s/<<ARIBA_PRODUCT_NAME>>/$host->{tag_name}/g;
        $template =~ s/<<ARIBA_DATACENTER>>/$dataCenter/g;
        my $fileName = $self->getConfigPath() . "/host_config/" . $host->{name};
        $host->{telegraf_conf_file} = $host->{name};
        print "[  INFO  ] [ $host->{name} ] Telegraf Configuration ... ";
        my $FH;
        open( $FH, ">$fileName" )
          || die "Unable to create file -  $fileName - $!";
        print "Success\n";
        print $FH $template;
        close($FH);
    }

}

sub logMessage {
    my ( $type, $host, $message );
    printf( "%-10s %-30s %s", $type, $host, $message );
}

sub _runTelegrafStatus {
    my ( $self, $host ) = @_;
    my $dest          = $host->{name};
    my $user          = $self->getTransferUser();
    my $password      = $self->getTransferUserPassword();
    my $bg            = 0;
    my @output        = ();
    my $statusCommand = qq!sudo /etc/init.d/telegraf status!;
    my $command       = qq!ssh $dest -l $user "$statusCommand"!;

    #print "$command and password is $password\n";
    my $success =
      ariba::rc::Utils::executeRemoteCommand( $command, $password, 0, undef,
        undef, \@output );
    my $status = undef;
    if ( grep( /telegraf Process is running \[ OK \]/, @output ) ) {
        $status = "Running";
    }
    elsif ( grep( /telegraf Process is not running \[ FAILED \]/, @output ) ) {
        $status = "Installed but not Running";
    }
    else {
        $status = "Unknown";
    }
    printf( "%s%-40s%s%-47s%s\n", "|", " $dest", "|", " $status", "|" );

}

sub _startTelegrafAgent {
    my ( $self, $host ) = @_;
    my $dest          = $host->{name};
    my $user          = $self->getTransferUser();
    my $password      = $self->getTransferUserPassword();
    my $bg            = 0;
    my @output        = ();

    my $telegrafUser = $self->_getMachineSpecificTelegrafUser($host->{product}, $host->{server_type}) || $user;

    my $initScript    = "/etc/init.d/telegraf";
    my $editUserCmd   = "sed -i 's/^USER=.*\$/USER=$telegrafUser/' $initScript";
    my $editGroupCmd  = "sed -i 's/^GROUP=.*\$/GROUP=ariba/' $initScript";
    my $statusCommand = qq!sudo $editUserCmd && sudo $editGroupCmd && sudo chmod 666 /var/log/telegraf/telegraf.log && sudo chmod 777 /var/run/telegraf && sudo $initScript restart!;
    my $command       = qq!ssh $dest -l $user "$statusCommand"!;
    my $success =
      ariba::rc::Utils::executeRemoteCommand( $command, $password, 0, undef,
        undef, \@output );
    my $status = undef;

    if ( grep( /telegraf process was started \[ OK \]/, @output ) ) {
        $status = colored( " STARTED ", 'black on_green' );

        #$status =  " STARTED ";
    }
    else {
        #$status = "  FAILED ";
        $status = colored( " FAILED ", 'black on_red' );
    }
    printf( "%s%-40s%s%-59s%s\n", "|", " $dest", "|", " $status", "|" );

}

sub _stopTelegrafAgent {
    my ( $self, $host ) = @_;
    my $dest          = $host->{name};
    my $user          = $self->getTransferUser();
    my $password      = $self->getTransferUserPassword();
    my $bg            = 0;
    my @output        = ();
    my $statusCommand = qq!sudo /etc/init.d/telegraf stop!;
    my $command       = qq!ssh $dest -l $user "$statusCommand"!;
    my $success =
      ariba::rc::Utils::executeRemoteCommand( $command, $password, 0, undef,
        undef, \@output );
    my $status = undef;

    if ( grep( /telegraf process was stopped \[ OK \]/, @output ) ) {
        $status = colored( " STOPPED ", 'black on_green' );

        #$status =  " STOPPED ";
    }
    else {
        #$status = "  FAILED ";
        $status = colored( " FAILED ", 'black on_red' );
    }
    printf( "%s%-40s%s%-59s%s\n", "|", " $dest", "|", " $status", "|" );

}


sub _removeTelegafConfigs {
	my ( $self, $host ) = @_;
	my $dest     = $host->{name};
	my $user     = $self->getTransferUser();
	my $password = $self->getTransferUserPassword();
	my $bg       = 0;
	my @output   = ();
	
	my $telegrafUser = $self->_getMachineSpecificTelegrafUser($host->{product}, $host->{server_type}) || $user;
	my $rmCommand = qq!sudo find /etc/telegraf/telegraf.d/ -type f -not -name '*_output.conf' -not -name '*_input.conf' -print0 | xargs -0 sudo rm -f --!;
	my $command = qq!ssh $dest -l $user "$rmCommand"!;
	print "Running Command : $command\n";
	print "Running Command : $command\n" if ($debug);
	my $status;
	$status =
 	     executeRemoteCommand( $command, $password, $bg, undef, undef, \@output );
	print "-----------------------\n";
	print @output;
	print "----------------------\n";
	unless ($status) {
        	print "[  ERROR  ] [ $dest ] Config file removal Failed \n";
	}
	else {
        	print "[  INFO  ] [ $dest ]  Config file removal Succeeded \n";
    	}
}

sub _runTelegrafRestart {
    my ( $self, $host ) = @_;
    my $dest     = $host->{name};
    my $user     = $self->getTransferUser();
    my $password = $self->getTransferUserPassword();
    my $bg       = 0;
    my @output   = ();
  
    my $telegrafUser = $self->_getMachineSpecificTelegrafUser($host->{product}, $host->{server_type}) || $user;

    my $initScript     = "/etc/init.d/telegraf";
    my $editUserCmd    = "sed -i 's/^USER=.*\$/USER=$telegrafUser/' $initScript";
    my $editGroupCmd   = "sed -i 's/^GROUP=.*\$/GROUP=ariba/' $initScript";
    my $restartCommand = qq!sudo $editUserCmd && sudo $editGroupCmd && sudo chmod 666 /var/log/telegraf/telegraf.log && sudo chmod 777 /var/run/telegraf && sudo $initScript restart!;
    my $command        = qq!ssh $dest -l $user "$restartCommand"!;
    print "Running Command : $command\n" if ($debug);
    my $status =
      executeRemoteCommand( $command, $password, $bg, undef, undef, \@output );
    unless ($status) {
        print "[  ERROR  ] [ $dest ] Agent Restart Failed \n";
    }
    else {
        print "[  INFO  ] [ $dest ]  Agent Restart Succeeded \n";
    }

}

# Whitelist of servers where telegraf should be 
# run with product's deployment user
#
# Defaults to transfer user (mon<<service>>) if
# prod / type isnt whitelisted
sub _getMachineSpecificTelegrafUser {
    my ( $self, $product, $server_type ) = @_;

    # the whitelist for scripts that are 
    # in telegraf_input_by_product_role.json
    my $whitelist = { "hadoop" => { 
				    "hadoopname" => 1, 
                                  }
                    };

    if ( $whitelist->{$product}{$server_type} ) {
        return ariba::rc::Globals::deploymentUser($product, $self->{service});
    }


    return $self->getTransferUser();
}

sub _runTransferCommands {
    my ( $self, $host ) = @_;

    my ( $destHost, $prop );
    my $user       = $self->getTransferUser();
    my $password   = $self->getTransferUserPassword();
    my $dataCenter = $self->getDataCenter();

    my $bg     = 0;
    my $status = 0;
    my $dest   = $host->{name};

    #Exporting telegraf output file
    my @output       = ();
    my $srcRoot      = $self->getConfigPath() . "/monitor_config";
    my $srcFile      = 'telegraf_output.conf';
    my $dstroot      = '/var/tmp/';
    my $dstFile      = $srcFile;
    my $fileFullPath = $srcRoot . '/' . $srcFile;
    my @result       = ();

    if ( !( -e $fileFullPath ) ) {
        print
          "[ ERROR!! ] [ $dest ] Configuration file : $srcFile not available\n";
        return;
    }
    else {
        print "[  INFO  ] [ $dest ]  Exporting configuration file : $srcFile \n"
          if ($debug);
    }

    #ariba::rc::Utils::transferFromSrcToDestNoCheck(
    #    undef,    $user,    $srcRoot, $srcFile, $dest, $user,
    #    $dstroot, $dstFile, 0,        0,        0,     $password,
    #    \@output
    #);
    #my $copyCommand = "sudo cp $dstroot/$dstFile /etc/telegraf/telegraf\.d/";
    #my $command     = qq!ssh $dest -l $user "$copyCommand"!;
    #print "Running Command : $command\n" if ($debug);
    #executeRemoteCommand( $command, $password, $bg, undef, undef, \@result );

    if ( grep /rsync error/, @output ) {
        print "[ ERROR!! ] [ $dest ]" . join( " ", @output ) . "\n";
    }

    # Exporting main telegraf file
    @output       = ();
    $srcRoot      = $self->getConfigPath() . "/host_config";
    $srcFile      = $host->{telegraf_conf_file};
    $dstroot      = '/var/tmp/';
    $dstFile      = $srcFile;
    $fileFullPath = $srcRoot . '/' . $srcFile;
    if ( !( -e $fileFullPath ) ) {
        print "[ ERROR!! ] [ $dest ] Configuration file : $srcFile not available\n";
        return;
    }
    else {
        print "[  INFO  ] [ $dest ]  Exporting configuration file : $srcFile \n" if ($debug);
    }

    @result = ();
    ariba::rc::Utils::transferFromSrcToDestNoCheck(
        undef,    $user,    $srcRoot, $srcFile, $dest, $user,
        $dstroot, $dstFile, 0,        0,        0,     $password,
        \@output
    );
    my $copyCommand = "sudo cp $dstroot/$dstFile /etc/telegraf/telegraf.conf";
    my $command     = qq!ssh $dest -l $user "$copyCommand"!;
    print "Running Command : $command\n" if ($debug);
    executeRemoteCommand( $command, $password, $bg, undef, undef, \@output );

    if ( grep /rsync error/, @output ) {
        print "[ ERROR!! ] [ $dest ]" . join( " ", @output ) . "\n";
    }

    # Exporting exec plugin based on the product role
    my $installedProductNamesMap = $self->_getInstalledProdNameMap();
    my $globPatternProdName      = '{' . join(',', keys %{$installedProductNamesMap}) . '}';

    @output  = ();
    @result  = ();
    $srcRoot = $self->getConfigPath() . "/monitor_config";
    $dest    = $host->{name};

    # if no product, glob all confs of installed prodcuts (only if files exist) and take the basename
    my @srcFiles = $self->{product} ? ( $host->{product} . '_' . $host->{server_type} . '.conf') : map { (split('/', $_))[-1] } grep { -f } glob($srcRoot . "/${globPatternProdName}_" . $host->{server_type} . ".conf");
    foreach my $srcFile ( @srcFiles ) {
        my $fileFullPath = $srcRoot . '/' . $srcFile;
        if ( ! -e $fileFullPath ) {
            # this should never be the case, but sure, keep the check
            print "[  WARN  ] [ $dest ] Configuration file : $srcFile not available\n";
            next;
        }
        else {
            print "[  INFO  ] [ $dest ]  Exporting configuration file : $srcFile \n" if ($debug);
        }
        $dstroot = '/var/tmp/';
        $dstFile = $srcFile;
        ariba::rc::Utils::transferFromSrcToDestNoCheck(
            undef,    $user,    $srcRoot, $srcFile, $dest, $user,
            $dstroot, $dstFile, 0,        0,        0,     $password,
            \@output
        );
        $copyCommand = "sudo cp $dstroot/$dstFile /etc/telegraf/telegraf\.d/";
        $command     = qq!ssh $dest -l $user "$copyCommand"!;
        print "Running Command : $command\n" if ($debug);
        $status = executeRemoteCommand( $command, $password, $bg, undef, undef, \@output );

        if ( grep /rsync error/, @output ) {
            print "[ ERROR!! ] [ $dest->{name} ]" . join( " ", @output ) . "\n";
        }
    }
    print "[  INFO  ] [ $dest ] Configuration Deployment Succeeded \n";

}

#--------------------------------------------------------------------------------------------------------------------------------------
# Purpose : Compute the path having the telegraf configuration file which should be deployed as /etc/telegraf/telegraf.conf
#         : Verifies the file exists. If not, throw error and exit.
#--------------------------------------------------------------------------------------------------------------------------------------
sub _readTelegrafConfigTemplate {
    my $self           = shift;
    my $telegrafConfig = $self->getConfigPath() . "/telegraf_global_template.conf";
    if ( -e $telegrafConfig ) {
        $self->_setAttribute( 'telegraf_template_file', $telegrafConfig );
    }
    else {
        die "Error: Unable to find the file : $telegrafConfig\n";
    }
    my $FH;
    open( $FH, "<$telegrafConfig" )
      || die "Error: Unable to open configuration file $telegrafConfig - $!\n";
    my @dataChunks = <$FH>;
    chomp(@dataChunks);
    close($FH);
    my $telegrafConfigTemplate = join( "\n", @dataChunks );
    $self->_setAttribute( 'telegraf_config_template', $telegrafConfigTemplate );

}

#--------------------------------------------------------------------------------------------------------------------------------------
# Purpose : Get the telegraf output template config content
#         : Get the values for telegraf template configuruation substition
#         : Perform substitution of values in placeholder
#         : Store modified template content as new object attribute
#--------------------------------------------------------------------------------------------------------------------------------------
sub _genTelegrafOutputFile {
    my $self = shift;

    my $configPath         = $self->getConfigPath() . "/monitor_config";
    my $dataCenter         = $self->getDataCenter();
    my $cluster            = $self->getCluster();
    my @monitorConfigFiles = ();

    print Dumper $_outputConfigData if ($debug);
    my $fileName    = 'telegraf_output.conf';
    my $fileContent = "";
    foreach
      my $confSection ( @{ $_outputConfigData->{$dataCenter}{$cluster} } )
    {
        $fileContent .= "[[outputs." . $confSection->{'output_type'} . "]]\n";
        foreach my $parameter ( @{ $confSection->{'parameters'} } ) {
            $parameter = $self->_replaceTelegrafConfigParamTokens({parameter => $parameter});
            $fileContent .= "  " . $parameter . "\n";
        }
    }

    print "File Name : $fileName \n"                                if ($debug);
    print $fileContent . "\n"                                       if ($debug);
    print "-----------------------------------------------------\n" if ($debug);

    my $fh;
    print "Creatingfile - $configPath/$fileName \n";
    open $fh, ">", "$configPath/$fileName"
      || die "Unable to create file - $configPath/$fileName : $!";
    print $fh $fileContent;
    close $fh;

    push( @monitorConfigFiles, "$configPath/$fileName" );

    $self->_setAttribute( 'monitor_config_list', \@monitorConfigFiles );
}

#sub _mapProductRoleToMacDbRole{
#	my $self = shift;
#	my %productRoleHostDict;
#	foreach my $prodConfig(@{$self->{product_config_list}}){
#		while(my ($roleName,$hostListRef) = each(%{$prodConfig})){
#			next if($roleName eq "product" || $roleName eq "name" || $roleName eq "cluster_name");
#			$productRoleHostDict{$prodConfig->{name}.'!!'.$roleName} = $hostListRef;
#		}
#	}
#	$self->_setAttribute('product_role_host_map',\%productRoleHostDict);
#	#print Dumper %productRoleHostDict;
#}

sub _mapProductRoleToMacDbRole {
    my $self = shift;
    my %productRoleHostDict;
    foreach my $prodConfig ( @{ $self->{product_config_list} } ) {
        while ( my ( $roleName, $hostListRef ) = each( %{$prodConfig} ) ) {
            next if ( $roleName eq "product" || $roleName eq "name" );
            foreach my $host (@$hostListRef) {
                $self->updateMacDBWithProduct( $prodConfig->{name}, $host );
            }
        }
    }

}

sub updateMacDBWithProduct {
    my ( $self, $productName, $host ) = @_;
    foreach my $macdbRec ( @{ $self->getMacDBHostList() } ) {
        if ( $macdbRec->{name} eq $host ) {
            $macdbRec->{product} = $productName;
        }
    }
}

sub _readTelegrafOutputConfig {
    my $self = shift;
    print "Reading template configuration for Telegraf output....." if ($debug);
    my $configPath = $self->getConfigPath();

#$self->_setAttribute('telegraf_output_config_template',$telegrafOutputConfigTemplate);

    my $json;
    {
        local $/;
        open my $fh, "<", $configPath . '/telegraf_outputs_by_datacenter.json'
          || die "Unable to open telegraf_outputs_by_datacenter.json $!";
        $json = <$fh>;
        close $fh;
    }

    my $data = decode_json($json);

    #print Dumper($data);
    $_outputConfigData = $data;
    return $data;
}

sub _genTelegrafExecBlock {
    my $self = shift;

    my $configPath         = $self->getConfigPath() . "/monitor_config";
    my $cluster            = $self->getCluster(); 

    my $configCluster;
    #If runmode is null / failback, if dr site,configCluster = secondary  
    #If runmode is failover, if dr site, configCluster = primary
    #If runmode is null / failback, if not dr site, configCluster = primary
    #If runmode is failover, if not dr site, configCluster = secondary  	
	
    if(!$self->isFailOver() && $self->isDRSite()) {
	$configCluster = 'secondary';	
    } elsif($self->isFailOver() && $self->isDRSite()) {
 	$configCluster = 'primary';
    } elsif(!$self->isFailOver() && !$self->isDRSite()) {
	$configCluster = 'primary';
    } elsif($self->isFailOver() && !$self->isDRSite()) {
	$configCluster = 'secondary';
    }		

    my @monitorConfigFiles = ();
    print "Config Cluster -------------------->>>>> $configCluster \n";	
    #print Dumper $_rpsConfigData;
    foreach my $prod ( keys %{$_rpsConfigData} ) {
        foreach my $role ( keys %{ $_rpsConfigData->{$prod} } ) {
            my $fileName    = $prod . '_' . $role . '.conf';
            my $fileContent = "";
            foreach my $confSection (
                @{ $_rpsConfigData->{$prod}{$role}{$configCluster} } )
            {
                $fileContent .=
                  "[[inputs." . $confSection->{'input_type'} . "]]\n";
                foreach my $parameter ( @{ $confSection->{'parameters'} } ) {
                    $parameter = $self->_replaceTelegrafConfigParamTokens({parameter => $parameter});
                    $fileContent .= "  " . $parameter . "\n";
                }
                $fileContent .= "\n";
            }

            print "File Name : $fileName \n" if ($debug);
            print $fileContent . "\n" if ($debug);
            print "-----------------------------------------------------\n"
              if ($debug);

            my $fh;
            print "Creatingfile - $configPath/$fileName \n";
            open $fh, ">", "$configPath/$fileName"
              || die "Unable to create file - $configPath/$fileName : $!";
            print $fh $fileContent;
            close $fh;

            push( @monitorConfigFiles, "$configPath/$fileName" );
        }
    }

    $self->_setAttribute( 'monitor_config_list', \@monitorConfigFiles );
}

sub _replaceTelegrafConfigParamTokens {
    my $self = shift;
    my $args = shift;

    my $service   = $self->{service};
    my $parameter = $args->{parameter};

    $parameter =~ s/<<SERVICE>>/$service/g;

    return $parameter;
}

sub _getInstalledProdNameMap {
    my $self = shift;

    my $map = {};
    foreach my $installProdInfo (ariba::rc::InstalledProduct->installedProductsList() ) {
        $map->{ $installProdInfo->{prodname} } = 1
    }

    return $map;
}

sub new {
    my $class = shift;
    my $vars  = {@_};
    my $self = bless( $vars, $class );
    if(defined $vars->{debug} && $vars->{debug}) {
       	$self->setDebugModeOn();
    }else {
        $self->setDebugModeOff();
    }
    return $self;	
}

1;
