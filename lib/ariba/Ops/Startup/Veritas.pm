package ariba::Ops::Startup::Veritas;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/Veritas.pm#2 $

use strict;

use ariba::rc::Utils;
use ariba::rc::Globals;
use ariba::rc::Passwords;
use ariba::rc::HadoopAppInstance;
use ariba::Ops::NetworkUtils;

my $SUDO = ariba::rc::Utils::sudoCmd();
my $HAGRP = '/opt/VRTS/bin/hagrp';

=pod

=head1 NAME

ariba::Ops::Startup::Veritas

=head1 SUMMARY 

APIs to check / start / stop / manage Veritas controlled nodes

=head1 CLASS METHODS

=over 4

=item * isVeritasControlEnabled(productInstance)

Returns true if the given product has veritas enabled for running nodes

=cut

sub isVeritasControlEnabled {
    my $me = shift; 

    return $me->default('Ops.VeritasControlEnabled') && 
        $me->default('Ops.VeritasControlEnabled') eq 'true';
}

=item * isVeritasControlEnabledForRole(productInstance, role) 

Returns true if veritas is enabled for the given product and role

=cut

sub isVeritasControlEnabledForRole {
    my $me = shift; 
    my $role = shift; 

    my @veritasCapableRoles = qw(hadoop-name hadoop-jobtracker);     
   
    return isVeritasControlEnabled($me) && (grep { $role eq $_ } @veritasCapableRoles);
}

=item * isVeritasControlEnabledForNode(productInstance, appInstance)

Returns true if veritas is enabled for given product and app instance

=cut

sub isVeritasControlEnabledForNode {
    my $me = shift; 
    my $instance = shift; 
    my $appName = $instance->appName();

    return isVeritasControlEnabled($me) && $me->default("Ops.VeritasControlledNodes.$appName.Group");
}

=item * restartVeritasControlledNode(productInstance, appInstance) 

Restarts the given Veritas control enabled node.
Returns true on success

=cut

sub restartVeritasControlledNode {
    my $me = shift; 
    my $instance = shift; 

    return stopVeritasControlledNode($me, $instance) && 
           startVeritasControlledNode($me, $instance);
}

=item * startVeritasControlledNode(productInstance, appInstance) 

Starts the given Veritas control enabled node.
Returns true on success

=cut

sub startVeritasControlledNode {
    my $me = shift; 
    my $instance = shift; 

    return _startOrStopVeritasControlledNode($me, $instance, 'online');
}

=item * stopVeritasControlledNode(productInstance, appInstance) 

Stops the given Veritas control enabled node.
Returns true on success

=cut

sub stopVeritasControlledNode {
    my $me = shift;
    my $instance = shift; 

    return _startOrStopVeritasControlledNode($me, $instance, 'offline');
}

sub _startOrStopVeritasControlledNode {
    my $me = shift;
    my $instance = shift;
    my $action = shift; 

    my $installDir = $me->installDir();
    my $user = ariba::rc::Globals::deploymentUser($me->name(), $me->service());
    my $nodeName = $instance->appName();

    my $groupKey = "Ops.VeritasControlledNodes.$nodeName.Group";
    my $group = $me->default($groupKey);

    unless ($group) {
        print "Error: No group setup for $groupKey.\n"; 
        return 0; 
    }


    my $virtualHost = $instance->host();
    my $host; 
    foreach my $h ($me->hostsForVirtualHostInCluster($virtualHost)) {
        if (ariba::Ops::NetworkUtils::ping($h)) {
            $host = $h; 
            last;
        }   
    }

    unless ($host) {
        print "Error: Failed to find available host for virtual host $virtualHost.\n"; 
        return 0; 
    }

    my $cmd = "ssh $user\@$host '$SUDO $HAGRP -$action $group -any'"; 

    if ($main::debug) {
        print "Will run: $cmd\n"; 
    } else {
        print "Running: $cmd\n"; 

        my $password = ariba::rc::Passwords::lookup($user); 
        if ($password) {
            my $success = ariba::rc::Utils::executeRemoteCommand($cmd, $password);
            return 0 unless ($success);

            my $sleepInterval = 10;
            my $tries = 30;
            my $verifyCmd = "ssh $user\@$host '$SUDO $HAGRP -state $group'";
            for (my $i = 1; $i <= $tries; $i++) {
                print "Sleeping $sleepInterval sec(s) before checking veritas state\n";
                sleep($sleepInterval);

                print "Running #$i: $verifyCmd\n";
                
                my @output;
                my $success = ariba::rc::Utils::executeRemoteCommand($verifyCmd, $password, 0, undef, undef, \@output);
                return 0 unless ($success);

                print "Output #$i:", join("\n", @output), "\n";

                my $online = 0;
                my $offline = 0;
                foreach my $line (@output) {
                    $online++ if ($line =~ /\s+\|ONLINE\|$/);
                    $offline++ if ($line =~ /\s+\|OFFLINE\|$/);
                }

                return 1 if ($action eq 'online' && $online); 
                return 1 if ($action eq 'offline' && $offline && !$online);
            }

            print "Error: Veritias group $group failed to $action after ", $tries * $sleepInterval, " sec(s)\n";
            return 0;

        } else {
            print "Error: No password found in cipher store for $user.\n"; 
            return 0;
        } 
    }

    return 1;
}

1;

__END__
