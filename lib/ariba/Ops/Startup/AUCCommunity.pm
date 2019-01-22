package ariba::Ops::Startup::AUCCommunity;

use strict;

use Carp;
use ariba::Ops::NetworkUtils;
use ariba::Ops::ServiceController;
use ariba::Ops::Startup::Common;
use ariba::rc::Utils;

sub launchApps 
{
	my ($me, $apps, $appArgs, $role, $community, $masterPassword) = @_;
	my $launched  = 0;
	my $cluster   = $me->currentCluster();
	my $product = ariba::rc::InstalledProduct->new();
	my $confFile = "$ENV{'ARIBA_CONFIG_ROOT'}/httpd.conf";
	my @instances = $me->appInstancesOnHostLaunchedByRoleInClusterMatchingFilter(ariba::Ops::NetworkUtils::hostname(),$role,$cluster,$apps);
	my @launchedInstances = ();
        #start memcache
        if ($role eq 'communityapp' &&
                !(grep { "-rolling" eq $_ } @$appArgs)){ ## if we're communityapp and current action is not rolling upgrade/restart
            my $product = ariba::rc::InstalledProduct->new();
            my $installdir = $product->installDir();

            my $memCachedExe = $product->default('AUC.Memcached.Exe');
            my $memCachedArgs = $product->default('AUC.Memcached.Args');

            my $hostname = ariba::Ops::NetworkUtils::hostname();
            my $shortHost = $hostname;
            $shortHost =~ s/\.ariba\.com//;

            # Abort community startup if memcached is configured but not found
            if ($memCachedExe) {
                die "ERROR: '$memCachedExe' does not exist" if ! -f $memCachedExe;
                ariba::Ops::Startup::Common::launchCommandFeedResponses("$installdir/bin/keepRunning -w -kp $memCachedExe $memCachedArgs -ki -kn memcached\@$shortHost");
            }
        }

	
	for my $instance (@instances) {
		# run this code only for AUCCommunity apps
		next unless $instance->isAUCCommunityApp();

		my $prodname = uc($me->name());
		my $port = $instance->port();
		my $app = $instance->appName();
		my $instanceName = $instance->instance();
		# build args
		#Perform stop and start of Apache
		#Also run the commands during each phase
                if ((grep { "-action=upgrade" eq $_ } @$appArgs) ||
                    (grep { "-action=restart" eq $_ } @$appArgs)) {
                    #For rolling upgrade or restart we do the following
                    #(1) run pre-stop(drupal) (2) stop apache (3) run post-stop
                    #(4) start apache (5) run post-start
                    my $bucket = $instance->recycleGroup();
                    push(@$appArgs, $bucket);
                    print "Running pre-stop AUCCommunity - rolling - bucket: $bucket\n";
                    ruPhaseDrupal($product->installDir(), $appArgs, "prestop");
                    ariba::Ops::Startup::Apache::stop($me, $confFile);
                    print "Running post-stop AUCCommunity - rolling - bucket: $bucket\n";
                    ruPhaseDrupal($product->installDir(), $appArgs, "poststop");
                    ariba::Ops::Startup::Apache::start($me, $confFile);
                    print "Running post-start AUCCommunity - rolling - bucket: $bucket\n";
                    ruPhaseDrupal($product->installDir(), $appArgs, "poststart");
                }
                else {
                    #any other action
                    #(1) stop apache
                    #(2) start apache
                    #(3) run start (drupal)
                    print "Stopping Apache for community\n";
		    ariba::Ops::Startup::Apache::stop($me, $confFile);
                    print "Starting Apache for community\n";
    		    startDrupal($product->installDir());
		    ariba::Ops::Startup::Apache::start($me, $confFile);
                }
		push(@launchedInstances, $instance);
	}
	return @launchedInstances;
}

sub runDrupalUpgrade {
    my ( $installDir ) = @_;

    runDrushCommand( $installDir, "upgrade" );
}

sub runDrupalInstall {
    my ( $installDir, $product ) = @_;

    my $user = $product->default('Drupal.User');
    my $pass = $product->default('Drupal.Pass');
    my $site = $product->default('SiteName');
    unless ( $user && $pass && $site ){
        croak "Could not read either 'Drupal.User', 'Drupal.Pass' or 'SiteName' from DD.xml\n";
    }
    runDrushCommand( $installDir, "install $user $pass \"$site\"" );
}

sub startDrupal {
    my ( $installDir ) = @_;
    
    runDrushCommand( $installDir, "start" );
}

=pod

runDrushCommand is used to execute drupal shell (drush) commands while starting
communityapp

=cut
sub runDrushCommand {
    my ( $installDir, $options ) = @_;
    
    my $oldPWD = $ENV{PWD};
    ## Run drush commands:
    r("$installDir/bin/execDrushCommands.sh $installDir $options");
    chdir("$oldPWD") || die "ERROR: could not chdir back to '$oldPWD': $!\n";
}

=pod

ruDrushCommand is used to execute drush during various phases of rolling upgrade/restart
The script that executes resides under //ariba/community bin folder: bin/ruDrushCommand.sh

=cut
sub ruDrushCommand {
    my ( $installDir, $options ) = @_;

    my $oldPWD = $ENV{PWD};
    ## Run drush commands:
    r("$installDir/bin/ruDrushCommand.sh $installDir $options");
    chdir("$oldPWD") || die "ERROR: could not chdir back to '$oldPWD': $!\n";
}

=pod

ruDrushCommand wrapper for different phases (prestop, poststop, poststart)

=cut
sub ruPhaseDrupal {
    my ( $installDir, $appArgs, $phase ) = @_;
    my $ruDrushArgsStr = join(' ', @$appArgs, $phase);

    ruDrushCommand( $installDir, $ruDrushArgsStr );
}

1;

__END__
