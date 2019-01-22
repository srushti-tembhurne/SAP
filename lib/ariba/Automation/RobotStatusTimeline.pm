package ariba::Automation::RobotStatusTimeline;

#
# Generate a pretty HTML/CSS robot status timeline given pass/fail datasets
#
# See: https://devwiki.ariba.com/bin/view/Main/RCRobotStatusTimeline
#

use strict;
use warnings;
use vars qw ($AUTOLOAD);
use Carp;
use Data::Dumper;
use File::Copy;

{
    #
    # Constructor
    #
    sub new
    {
        my ($class, $file) = @_;
        my $self = 
        {
            '_datapoints' => undef,
            '_labels' => undef,
            '_file' => $file, 
        };
        bless ($self, $class);
        return $self;
    }
    
    #
    # Accessors
    #
    sub AUTOLOAD
    {
        no strict "refs";
        my ($self, $newval) = @_;

        my @classes = split /::/, $AUTOLOAD;
        my $accessor = $classes[$#classes];

        if (exists $self->{$accessor})
        {
            if (defined ($newval))
            {
                $self->{$accessor} = $newval;
            }
            return $self->{$accessor};
        }
        carp "Unknown method: $accessor\n";
    }

    #
    # Destructor
    #
    sub DESTROY
    {
        my ($self) = @_;
    }

    #
    # Takes a listref in this form:
    # 
    # [ LABEL, { result => RESULT, date => DATE }, ... ]
    #
    # LABEL = robot18
    # RESULT = 0,1
    # DATE = 8/8 
    #
    sub add_datapoints
    {
        my ($self, $datapoints) = @_;
        
        if ($#$datapoints < 1)
        {
            print STDERR <<FIN;
Usage: add_datapoints requires listref of at least 2 arguments: [ label, data point 0, ... ]
FIN
            croak;
            return 0;
        }

        if (! $self->{'_datapoints'})
        {
            $self->{'_datapoints'} = [];
        }
        push @{$self->{'_labels'}}, shift @$datapoints;
        push @{$self->{'_datapoints'}}, $datapoints;

        1;
    }

    #
    # Generate HTML file to specified file or STDOUT
    #
    sub make
    {
        my ($self) = @_;

        my $columns = $#{$self->{'_datapoints'}->[0]};
        my $width = int (100 / ($columns + 2 ));
        my $labelwidth = $width * 2;

        my $buf = <<FIN;
<html>
<head>
<title>Robot Status Timeline</title>
<script type="text/javascript" src="http://www.google.com/jsapi"></script> 
<script type="text/javascript"> google.load("jquery", "1.3.2"); </script> 
<script src="/resource/timeline.js" language="javascript" type="text/javascript"></script>
<script type="text/javascript">
var cols = $columns;
</script>
<style>
body { font-family: Verdana, sans-serif; font-size: 24px; }
.row {  width: 100%;  clear: both; }
.embiggened { font-size: 24px; }
.element { vertical-align: middle; text-align: center; float: left; width: $width%; height: 36px; display: inline; } 
.label { text-align: left; font-size: 12px; width: $labelwidth%; }
.contrast { color: #FFFFFF; }
.success { background-color: #89A54E; }
.failure { background-color: #AA4643; }
</style>
</head>
<body>
FIN


        foreach my $i (0 .. $#{$self->{'_labels'}})
        {
            my $labels = $self->{'_labels'}->[$i];
            my $datapoints = $self->{'_datapoints'}->[$i];
            $buf .= $self->_make_timeline ($labels, $datapoints);
        }

        $buf .= <<FIN;
</body>
</html>
FIN

        my $file = $self->{'_file'} || "";

        if ($file)
        {
            open FILE, ">$file.tmp";
            print FILE $buf;
            close FILE;
            move ("$file.tmp", $file);
        }
        else
        {
            print $buf;
        }
    }

    #
    # Make div/span combo required for one row
    #
    sub _make_timeline
    {
        my ($self, $label, $datapoints) = @_;
        my $buf = <<FIN;
<div class="row">
<span class="element label">$label</span>
FIN
        foreach my $i (0 .. $#$datapoints)
        {
            my $data = $$datapoints[$i];
            my $result = $data->{'result'} ? "success" : "failure";
            my $date = $data->{'date'};
            $buf .= <<FIN;
<span class="contrast element $result embiggened">$date</span>
FIN
        }

        $buf .= <<FIN;
</div>
FIN

        return $buf;
    }
}

1;
