package ariba::Ops::Sybase::Utils;

use strict;
use warnings;
use Date::Parse;
use Data::Dumper;
use File::Temp qw(tempfile);
use lib '/usr/local/ariba/lib';

use ariba::Ops::HanaClient;
use ariba::rc::Utils;
use POSIX qw(strftime);

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(get_rs_ticket submit_rs_ticket disk_space who_is_down ra_status license_monitoring);
my $year = strftime("%y",localtime (time));

my $commands = {
    rs_ticket_max => {
        ##commandTemplate => "select rdb_t, pdb_t, exec_t, h1, h2, h3, h4, cnt   from rs_ticket_history where cnt = (select max(CNT) from rs_ticket_history where H1 not like '%/%')",
        commandTemplate => "select CNT,H1, H2, rdb_t, seconds_between(to_SECONDDATE(concat(concat(concat('20',H1),' '),H2)), NOW())/60.00 as min_delay from rs_ticket_history where H1 like '$year/%' and CNT in (select max(CNT) from rs_ticket_history where H1 like '$year/%')",
        requiredArgs => [],
    },
    license_monitoring => {
        commandTemplate => "cd /opt/sybase/repserver/SYSAM-2_0/licenses; grep INCREMENT  * | grep -v bk",
        requiredArgs => [],
    },
    disk_space => {
        commandTemplate => "admin disk_space\ngo\n",
        requiredArgs => [],
    },
    who_is_down => {
        commandTemplate => "admin who_is_down\ngo\n",
        requiredArgs => [],
    },
    ra_status => {
        commandTemplate => "ra_status\ngo\n",
        requiredArgs => [],
    },
    submit_rs_ticket => {
        commandTemplate => "rs_ticket \$args{h1},\$args{h2}\ngo\nra_date\ngo\n",
        requiredArgs => ['h1','h2'],
    },
};

sub _resolveCommand {
    my %args = @_;
    my $ret = eval {
        my $commandName = $args{commandName}
            or die "required named argument commandName not found";
        my $command = $commands->{$commandName}
            or die "passed named argument commandName($commandName) not valid";
        foreach my $argName (@{$command->{requiredArgs}}) {
            die "argument $argName required by passed commandName($commandName) has not found"
                unless defined $args{$argName};
        }
        my $commandString = eval("return \"$command->{commandTemplate}\";");
        die "eval failure on commandTemplate($command->{commandTemplate}) associated with passed commandName($commandName): $@" if $@;
        die "eval of commandTemplate($command->{commandTemplate}) associated with passed commandName($commandName) returned false"
            unless $commandString;
        return $commandString;
    };
    die "ariba::Ops::Sybase::Utils::_resolveCommand: $@" if $@;
    return $ret;
}

sub get_rs_ticket {
    my %args = @_;
    $args{port} = 30015 unless $args{port};
    $args{hanaTimeout} = 20 unless $args{hanaTimeout};
    $args{hanaTries} = 4 unless $args{hanaTries};
    my $ret = eval {
        die "required named argument hostname not found" unless $args{hostname};
        die "required named argument password not found" unless $args{password};
        die "required named argument userid not found" unless $args{userid};
        $args{sql} = _resolveCommand(%args, commandName => 'rs_ticket_max');
  
        my $hanaClient = ariba::Ops::HanaClient->new(
                $args{userid},
                $args{password},
                $args{hostname},
                $args{port},
                undef, undef)
            or die "ariba::Ops::HanaClient->new($args{userid}, $args{password}, $args{hostname}, $args{port}, undef, undef) returned false";
 #       print "HANA CLIENT ", Dumper($hanaClient), "\n";
        $hanaClient->connect($args{hanaTimeout}, $args{hanaTries})
            or die "\$hanaClient->connect($args{hanaTimeout}, $args{hanaTries}) returned false";
        my $results = $hanaClient->executeSql($args{sql});
        die "\$hanaClient->executeSql($args{sql}) returned false"
            unless defined $results;
        return $results;
    };
    die "ariba::Ops::Sybase::Utils::get_rs_ticket: $@" if $@;
    return $ret;
}
sub submit_rs_ticket {
    my %args = @_;
    my $ret = eval {
        die "required named argument hostname not found" unless $args{hostname};
        die "required named argument instanceName not found"
            unless $args{instanceName};
        die "required named argument password not found" unless $args{password};
        die "required named argument userid not found" unless $args{userid};
        die "required named argument h1 not found" unless $args{h1};
        die "required named argument h2 not found" unless $args{h2};
        $args{command} = _resolveCommand(%args, commandName => 'submit_rs_ticket');
        return runISQLCommand(%args);
    };
    die "ariba::Ops::Sybase::Utils::submit_rs_ticket: $@" if $@;
    return $ret;
}
sub health_status {

}

sub license_monitoring {
    my $debug = shift;
    my %args = @_;

    my $ret = eval {
        die "required named argument hostname not found" unless $args{hostname};
        die "required named argument password not found" unless $args{password};
        die "required named argument userid not found" unless $args{userid};
        my $host_info = "$args{userid}\@$args{hostname}";
        $args{command} = _resolveCommand(%args, commandName => 'license_monitoring');

        my $command = "ssh -t $host_info '$args{command}'";
        print "COMMAND IS ", $command, "\n", if $debug > 1;

        my @output;
        my $status = ariba::rc::Utils::executeRemoteCommand(
            $command,
            $args{password},
            0,
            undef,
            undef,
            \@output
        );

       if ($status){
            my $license_info = '';
            foreach my $license (@output) {
                next unless ($license =~ /INCREMENT/);
                chomp($license);
                my @line = split /:/, $license;

                $line[1] =~ s/^\s+|\s+$//g;
                my  @info = split /\s/, $line[1];

                my $exp_date = $info[4];
                $exp_date = str2time("$exp_date GMT");
                print "Expiration Date $exp_date\n", if $debug;

                my $c_time = localtime ;
                $c_time = str2time ("$c_time GMT");
                print "Current Date $c_time\n", if $debug;
                my $will_expire = sprintf ("%d" , (($exp_date - $c_time)/86400)) ;

                my $licenseName = $info[1];
                if ($will_expire < 30 )  {
                   $license_info .= "Crit: $licenseName expire in $will_expire days\n";
                }
                elsif ($will_expire < 60 )  {
                   $license_info .= "Warning: $licenseName expire in $will_expire days\n";
                }
                if ($will_expire > 60 )  {
                   $license_info .= "$licenseName expire in $will_expire days\n";
                }
           }
        return $license_info;
       }

    };
    die "ariba::Ops::Sybase::Utils::license_monitoring: $@" if $@;

    return $ret;
}

sub disk_space {
    my %args = @_;
    my $ret = eval {
        die "required named argument hostname not found" unless $args{hostname};
        die "required named argument instanceName not found"
            unless $args{instanceName};
        die "required named argument password not found" unless $args{password};
        die "required named argument userid not found" unless $args{userid};
        $args{command} = _resolveCommand(%args, commandName => 'disk_space');
        return runISQLCommand(%args);
    };
    die "ariba::Ops::Sybase::Utils::disk_space: $@" if $@;
    return $ret;
}
sub who_is_down {
    my %args = @_;
    my $ret = eval {
        die "required named argument hostname not found" unless $args{hostname};
        die "required named argument instanceName not found"
            unless $args{instanceName};
        die "required named argument password not found" unless $args{password};
        die "required named argument userid not found" unless $args{userid};
        $args{command} = _resolveCommand(%args, commandName => 'who_is_down');
        return runISQLCommand(%args);
    };
    die "ariba::Ops::Sybase::Utils::who_is_down: $@" if $@;
    return $ret;
}
sub ra_status {
    my %args = @_;
    my $ret = eval {
        die "required named argument hostname not found" unless $args{hostname};
        die "required named argument instanceName not found"
            unless $args{instanceName};
        die "required named argument password not found" unless $args{password};
        die "required named argument userid not found" unless $args{userid};
        $args{command} = _resolveCommand(%args, commandName => 'ra_status');
        return runISQLCommand(%args);
    };
    die "ariba::Ops::Sybase::Utils::ra_status: $@" if $@;
    return $ret;
}

sub runISQLCommand {
    die "ariba::Ops::Sybase::Utils::runISQLCommand: even number of arguments required"
        if scalar @_ % 2;
    my %args = @_;
    for my $argName (qw/hostname userid password instanceName command/) {
        die "ariba::Ops::Sybase::Utils::runISQLCommand: required argument '$argName' not found" unless defined $args{$argName};
    }
    $args{debug} = 0 unless defined $args{debug};
    $args{timeout} = 10 unless defined $args{timeout};
    my ($commandFileName, $outputFileName);
    my $output = eval {
        local $SIG{ALRM} = sub { die "timed out\n"; };
        alarm $args{timeout};
        my (undef, undef, $sybaseUID) = getpwnam('sybase')
            or die "failed to getpwnam('sybase'): $!";
        my (undef, undef, undef, $sybaseGID) = getpwnam('sybase')
            or die "failed to getpwnam('sybase'): $!";
        my $fh;
        ($fh, $commandFileName) = tempfile();
        chmod 0644, $commandFileName;
        print STDERR "\$commandFileName=$commandFileName\n" if $args{debug};
        print $fh $args{command} or die "failed to write to '$commandFileName': $!";
        close $fh or die "failed to close '$commandFileName': $!";
        ($fh, $outputFileName) = tempfile();
        chmod 0644, $outputFileName;
        chown $sybaseUID, $sybaseGID, $outputFileName;
        print STDERR "\$outputFileName=$outputFileName\n" if $args{debug};
        my $sys = "sudo -u sybase -i isql -w2000 -H $args{hostname} -U $args{userid} -P $args{password} -J utf8 -S $args{instanceName} -i $commandFileName -o $outputFileName";
        print STDERR "\$sys=$sys" if $args{debug} > 3;
        system $sys;
        my $out = '';
        while(<$fh>) {
            $out .= $_;
        }
        return $out;
    };
    alarm 0;
    unlink $commandFileName if $commandFileName;
    unlink $outputFileName if $outputFileName;
    die "ariba::Ops::Sybase::Utils::runISQLCommand: $@" if $@;
    return $output;
}

1;
