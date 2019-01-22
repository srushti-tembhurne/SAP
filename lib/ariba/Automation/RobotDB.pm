package ariba::Automation::RobotDB;

#
# Create robot database accounts
#

$|++;

use strict;
use warnings;
use Carp;
use Data::Dumper;
use Expect;

my $DEBUG = 0;
my $TIMEOUT = 5;

my $output = "";

sub debug
{
    print "" . (join " ", @_) . "\n" if $DEBUG;
}

sub derp
{
    my $sqlplus = shift;
    my $cmd = shift;

    debug ("derping", $cmd);

    $sqlplus->expect 
    (
        $TIMEOUT,
        [
        qr/SQL>/i, 
            sub 
            {
            my $self = shift;
            $self->send ("$cmd\n");
            }
        ]
    );

    $output .= $sqlplus->exp_before();
}

sub create_accounts
{
    my $host = shift || "chinstrap.ariba.com";
    my $sid = shift || "LO102U89";
    my $user = shift || "oracle";
    my $passwd = shift || "oracle";
    my $account = shift || "robot101";
    my $product = shift || "s4";
    my $role = shift || "BQ";
    my $type = shift || "initdb";

    if (! $host || ! $sid || ! $user || ! $passwd || ! $account || ! $product || ! $role)
    {
        return;
    }

    $output = "";

    $ENV{'ORACLE_HOME'} = "/usr/local/oracle";
    $ENV{'PATH'} = join ":", $ENV{'PATH'}, "$ENV{'ORACLE_HOME'}/bin";
    
    my $command = "/usr/local/oracle/bin/sqlplus";
    my @args = ($user . '/' . $passwd . '@' . $host . '/' . $sid);

    debug ("Spawning $command", @args);
    $output .= "$command " . (join " ", @args) . "\n";

    my $sqlplus = Expect->spawn ($command, @args);
    my $exited = 0;
    $sqlplus->log_stdout(0);

    derp ($sqlplus, "EXECUTE new_account('$account','Y')");
    
    if ($product eq "s4")
    {
        derp ($sqlplus, "EXECUTE new_Account('$account" . "_tx')");

		if ($role eq "LQ")
		{
			derp ($sqlplus, "EXECUTE new_Account('$account" . "_tx2')");
		}

        derp ($sqlplus, "EXECUTE new_Account('$account" . "_star')");
        derp ($sqlplus, "EXECUTE new_Account('$account" . "_star2')");
        derp ($sqlplus, "EXECUTE new_Account('$account" . "_star3')");
        derp ($sqlplus, "EXECUTE new_Account('$account" . "_star4')");
    }
    elsif ($product eq "buyer")
    {
        derp ($sqlplus, "EXECUTE new_Account('$account" . "_tx1')");
        derp ($sqlplus, "EXECUTE new_Account('$account" . "_tx2')");
        derp ($sqlplus, "EXECUTE new_Account('$account" . "_tx3')");        
    }

	# Adding a new type of DB account
	# As of Nov-2012, this is needed only for releases on R2+ platform, but
	# adding this for all releases is not harmless.
	# It helps to have it for all releases as it is difficult to predict when
	# each app will adopt R2.
	derp ($sqlplus, "EXECUTE new_Account('$account" . "_gen')");

    debug ("Exiting...");

    $sqlplus->expect
    (
        $TIMEOUT,
        [
        qr/SQL>/i,
            sub
            {
            my $self = shift;
            $self->send ("quit\n");
            $exited = 1;
            }
        ]
    );

    $output .= $sqlplus->exp_before();
    undef $sqlplus;

    debug ("done");
    return ($output, $exited);
}

1;
