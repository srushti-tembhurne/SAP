package ariba::Automation::Remote::Utils;

use warnings;
use strict;

use vars qw(@EXPORT);
use Exporter;
use base qw(Exporter);

my $constants = {
		cgiRobotConfig => "robotConfig",
    cgiRobotStatus => "robotStatus",
    cgiRobotProduct => "robotProduct",
		cgiRobotName => "robotName",
		cgiGlobalState => "globalState",
		cgiTimingReports => "robotTimingReport",
		cgiVar => "var",
		cgiAction => "action",
		cgiActionShow => "show",
		cgiActionUpdate => "update",
		cgiActionGetvar => "getvar",
};

@EXPORT = keys %$constants;

INIT {
	no strict 'refs';
	no warnings; # avoid 'Subroutine xx redefined at yy'
	for my $datum (keys %$constants) {
        *$datum = sub { return $constants->{$datum} };
	}
}


1;
