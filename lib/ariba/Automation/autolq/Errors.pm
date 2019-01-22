package ariba::Automation::autolq::Errors;

my $OK = 0;
my $ERR_MANGLED_ARGS = 1;
my $ERR_LOCKED = 2;
my $ERR_UNKNOWN = 3;

my %ERRORS = 
(
    $OK => "ok",
    $ERR_MANGLED_ARGS => "An internal error occured.",
    $ERR_LOCKED => "LQ is already running.",
    $ERR_UNKNOWN => "LQ daemon not available.",
    $ERR_UNSTARTABLE => "Can't start LQ process", 
);

sub get_error { return $ERRORS{$_[0]}; }
sub ok { return $OK; }
sub mangled_args { return $ERR_MANGLED_ARGS; }
sub locked { return $ERR_LOCKED; }
sub unknown_error { return $ERR_UNKNOWN; }
sub get_unstartable { return $ERROR_UNSTARTABLE; }

1;
