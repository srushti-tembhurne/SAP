#
# $Id: //ariba/services/tools/lib/perl/ariba/util/StaticCronjobs.pm#1 $
#
# A module to manage static cronjobs for specific product/role to reuse the code 
#
package ariba::util::StaticCronjobs;

use strict;
use ariba::util::Crontab;

sub installCronjobsForHanasim {
    my ($class, $me, $action, $service, $hostname, $cluster ) = @_;
    my $crontab;
    my $product = $me->name(); 

    if ($product =~ /buyer|s4/){

        if($me->servesRoleInCluster($hostname, 'asmui', $cluster) || $me->servesRoleInCluster($hostname, 'asmsvui', $cluster) ||
            $me->servesRoleInCluster($hostname, 'asmadmin', $cluster) || $me->servesRoleInCluster($hostname, 'asmtask', $cluster) ||
            $me->servesRoleInCluster($hostname, 'asmglobaltask', $cluster) ||  $me->servesRoleInCluster($hostname, 'asmaoddatasync', $cluster) ||
            $me->servesRoleInCluster($hostname, 'buyerui', $cluster) || $me->servesRoleInCluster($hostname, 'buyeradmin', $cluster) ||
            $me->servesRoleInCluster($hostname, 'buyertask', $cluster) ) { 

            $crontab = ariba::util::Crontab->new('root', $action);

            $crontab->addEntryToCron(
                "iostat-data-hanasim",
                "/usr/local/ariba/bin/iostat-data-hanasim -e -p", 
                "Monitor Average Wait Time For Requests along with Threshold",
                ## This will run iostat-data-hanasim 1st minute of every hour
                "1 * * * *"
            );
        
            $crontab->addEntryToCron(
                "sqlLogSize-moniotring",
                "/usr/local/ariba/bin/sqlLogSize-moniotring -s $service -prod $product -e -p",
                "Monitor Growth rate of sql log directory and size of the logfiles",
                ## This will run sqlLogSize-moniotring every 5 minute 
                "*/12 * * * *"
            );
        
            $crontab->commit() || die "$0: failed to $action cronjobs for 'root'!\n";
        }
    }
     

}

1;
