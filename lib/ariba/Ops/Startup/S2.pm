package ariba::Ops::Startup::S2;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/S2.pm#2 $

use strict;

use File::Path;
use File::Basename;
use ariba::Ops::Startup::Common;
use ariba::Ops::Startup::Tomcat;
use ariba::rc::Utils;

sub createSymlinkForS2NodeLogs {

	my $me = shift;
        my @instances = $me->appInstances();

        for my $instance (@instances) {
                my $logName = "ASM" . $instance->workerName() . "Log.txt";
		my $srcDir = $me->default('System.Logging.DirectoryName');
                my $src = "$srcDir/$logName";
                my $target = $me->baseInstallDir() . "/logs/$logName";
		if (!-l $target) {
                	unless (symlink($src, $target)) {
                        	print "ERROR: cannot create symlink $src to $target: $!";
			}
                } else {
			print "Soft link exists, skipping symlink creation of $src to $target \n";
		}
        }
}

1;

__END__
