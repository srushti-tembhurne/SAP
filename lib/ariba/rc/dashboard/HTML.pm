package ariba::rc::dashboard::HTML;

#
# Static methods used by CGI scripts
#

#
# Print HTML header + stylesheet
#
sub header {
    my ( $title, $releasename ) = @_;

    my $now = localtime ( time () );

    print <<FIN;
<html>
<head>
<script type="text/javascript" src="http://rc.ariba.com/resource/qtip/jquery-1.3.2.min.js"></script>
<script type="text/javascript" src="http://rc.ariba.com/resource/qtip/jquery.qtip-1.0.0-rc3.min.js"></script>
<style>
body { padding: 10px; font-family: Verdana, Helvetica, sans-serif; }
.header { text-align: center; font-size: 110%; font-weight: bold; }
.legend { padding: 4px; }
.legend_icon { width: 32; }
.legend_label { width: 80; }
.inline_block { display:-moz-inline-box;display:inline-block;}.inline_block{position:relative;display:inline-block }
.dashboard { border: 1px solid #BBCCED; }
.status_icon { z-index: 2; height:20px;width:20px;margin:0 1px;background-image:url(/dashboard/dashboard.gif);background-repeat:no-repeat;vertical-align:middle}
.status_icon_group{margin-right:20px}

ul#menu{
   margin:0;
   padding:0;
   list-style-type:none;
   width:auto;
   position:relative;
   display:block;
   height:36px;
   text-transform:uppercase;
   font-size:12px;
   font-weight:bold;
   background:transparent url("/dashboard/images/OFF.gif") repeat-x top left;
   font-family:Helvetica,Arial,Verdana,sans-serif;
   margin-bottom:4px;
   border-bottom:4px solid #004c99;
   border-top:1px solid #74b0c6;
}

ul#menu li{
   display:block;
   float:left;
   margin:0;
   pading:0;
}

ul#menu li a{
   display:block;
   float:left;id="sidemenu"
   color:#6d7078;
   text-decoration:none;
   font-weight:bold;
   padding:12px 20px 0 20px;
   height:24px;
   background:transparent url("/dashboard/images/DIVIDER.gif") no-repeat top right;
}

ul#menu li a:hover{
   background:transparent url("/dashboard/images/HOVER.gif") no-repeat top right;
}


#menu12 {
   width: 178px;
   padding: 0 0 0 0;
   margin-bottom: 1em;
   font-size: 11px;
   font-weight: normal;
   font-family: Verdana, Lucida, Geneva, Helvetica, Arial, sans-serif;
   background-color: #6898d0;
   color: #333;
}

#menu12 ul {
   list-style: none;
   margin: 0;
   padding: 0;
   border: none;
}

#menu12 li {
   border-bottom: 1px solid #90bade;
   margin: 0;
   width: auto;
}

#menu12 li a {
   display: block;
   padding: 3px 0px 3px 0.5em;
   border-left: 5px solid #8AA1B6;
   border-right: 5px solid #8AA1B6;
   background-color: #6898d0;
   color: #fff;
   text-decoration: none;
   width: auto;
}

#menu12 li a:hover {
   border-left: 5px solid #800000;
   border-right: 5px solid #800000;
   background-color: #0e69be;
   color: #fff;
}


.bt1 {
   width : auto;
   font-family : Verdana, Arial, Helvetica, sans-serif;
   font-size : 10px;
   text-align : left;
   font-weight : bold;
   color : #ffffff;
   background-color : #8AA1B6;
   padding-top : 3px;
   padding-bottom : 4px;
   padding-left : 4px;
   border-left: 5px solid #FF7C3E;
   display : block;
}

.ht11 {
   font-size : 10px;
   font-weight: bold;
   color : #000;
   font-family : Verdana, Arial, Helvetica, sans-serif;
   text-decoration : none;
}

.hw12 {
   font-size : 11px;
   font-weight : bold;
   color : #ffffff;
   font-family : verdana, arial, helvetica, sans-serif;
   text-decoration : none;
}


</style>
<title>RC Dashboard</title>
</head>
<body bgcolor="#ffffff" vLink=#000000 aLink=#000000 link=#000000>

<div align="right">
<form name="myform" action="http://rc.ariba.com:8080/cgi-bin/dashboard">
<td> <input type='text' name='searchbuild' style = "vertical-align:middle;background:#FFFFFF url(/dashboard/images/search.png) no-repeat 4px 4px;padding:4px 4px 4px 22px;"/>
<a href="javascript: submitform()">
<img src="/dashboard/images/clicked.png" style = "vertical-align:middle; onmouseover="this.src='/dashboard/images/active.png';" onmouseout="this.src='/dashboard/images/clicked.png';" border="0" /></td>
</a>
</form>


<script type="text/javascript">
function submitform()
{
    if(document.myform.onsubmit &&
    !document.myform.onsubmit())
    {
        return;
    }
 document.myform.submit();
}
</script>
</div>
<table border="0" width="100%" >

<tr>
<td>
<ul id="menu">
   <li><a href="http://rc.ariba.com:8080/cgi-bin/dashboard" title="">ALL</a></li>
   <li><a href="http://rc.ariba.com:8080/cgi-bin/dashboard?releasename=12s1" title="">12s1</a></li>
   <li><a href="http://rc.ariba.com:8080/cgi-bin/dashboard?releasename=11s2" title="" >11s2</a></li>
   <li><a href="http://rc.ariba.com:8080/cgi-bin/dashboard?releasename=11s1" title="" >11s1</a></li>
   <li><a href="http://rc.ariba.com:8080/cgi-bin/dashboard?releasename=10s2" title="">10s2</a></li>
   <li><a href="http://rc.ariba.com:8080/cgi-bin/dashboard?releasename=10s1" title="">10s1</a></li>
   <li><a href="http://rc.ariba.com:8080/cgi-bin/dashboard?releasename=9r1" title="">9r1</a></li>
   <li><a href="http://rc.ariba.com:8080/cgi-bin/dashboard?releasename=1r1" title="">1r1</a></li>
</ul>
<br/>
</td>
</tr>
</table>
<table border="0">
<tr>
<td valign="top">

FIN

    print qq[
<div id="menu12">
  <ul>
    <li><div class="bt1"><span class="ht11">»</span>
    <span class="hw12">$releasename</span></div></li>
    <li><a title="ALL" href="http://rc.ariba.com:8080/cgi-bin/dashboard?releasename=$releasename">ALL</a></li>
    <li><a title="BUYER" href="http://rc.ariba.com:8080/cgi-bin/dashboard?releasename=$releasename&productname=buyer">Buyer</a></li>
    <li><a title="S4" href="http://rc.ariba.com:8080/cgi-bin/dashboard?releasename=$releasename&productname=s4">S4</a></li>
  </ul>
</div>
];

    print <<FIN;
</td>
<td>
FIN
}

sub success_icon {
    return '<img src="/dashboard/success.gif" width=19 height=18 border=0>';
}

sub in_progress_icon {
    return '<img src="/dashboard/in_progress.gif" width=20 height=18 border=0>';
}

sub fail_icon {
    return '<img src="/dashboard/fail.gif" width=20 height=18 border=0>';
}

sub more_info_icon {
    return '<img src="/dashboard/more_info.gif" width=20 height=19 border=0>';
}

sub graph_header {

    print <<HEAD;

    <!DOCTYPE html>
<html lang="en">
    <head>
        <meta charset="utf-8" />
        <!-- Always force latest IE rendering engine (even in intranet) & Chrome Frame Remove this if you use the .htaccess -->
        <meta http-equiv="X-UA-Compatible" content="IE=edge,chrome=1" />
        <title>Graph Page</title>
        <meta name="description" content="" />

        <script type="text/javascript" src="https://rc.ariba.com/timeline/google.jsapi.v1.js"></script>
        <script type="text/javascript" src="https://rc.ariba.com/timeline/google.timeline.v1.js"></script>
		
		<link href="https://rc.ariba.com/timeline/google.timeline.ui.css" type="text/css" rel="stylesheet">

        <style>
		body {
            font-family: Calibri, Helvetica, Arial, sans-serif;
            font-size: 14px;
            color:#272727;
            height: 100%;
        }
        </style>

    </head>
    <body>
HEAD
}

sub graph_script_start {

    my $buffer = <<HEAD;

<script type="text/javascript">
    google.setOnLoadCallback(drawChart);

    function drawChart() {
        var container   = document . getElementById( 'graph' );
        var chart     = new google . visualization . Timeline( container );
        var dataTable = new google . visualization . DataTable();
        dataTable . addColumn( { type : 'string', id : 'Step' } );
        dataTable . addColumn( { type : 'string', id : 'Sub-Step' } );
        dataTable . addColumn( { type : 'date',   id : 'Start' } );
        dataTable . addColumn( { type : 'date',   id : 'End' } );
        var rows= [
HEAD

    return $buffer;
}

sub graph_script_end {
    my $buffer = <<HEAD;

    ] ;

    var options = {
        avoidOverlappingGridLines: false
    };

    dataTable.addRows(rows);
    chart . draw( dataTable, options );
}

</script>
HEAD
}

sub graph_body {
    my ( $buildname, $rhDisplay, $service, $rhAssociation ) = @_;

    my $product = $rhDisplay->{ 'product' };
    my $log     = $rhDisplay->{ 'log' };
    my $branch  = $rhDisplay->{ 'branch' };
    my $time    = $rhDisplay->{ 'time' };

    my ( @services ) = @{ $rhDisplay->{ 'services' } };

    my $link     = "https://rc.ariba.com/cgi-bin/trending-graph?action=product-trend";
    my $multiple = "https://rc.ariba.com/cgi-bin/timeline-graph?action=multiple";

    my $body = <<FIN;

    <h4>Timeline Graph for $buildname</h4>
    <table>
        <tr>
            <td> <b> Buildname </b> </td>
            <td> :  </td>
            <td> $buildname  ( <a href='$log' > Build Log</a> )</td>
        </tr>
        <tr>
            <td> <b> Product</b> </td>
            <td> : </td>
            <td> $product </td>
        </tr>
        <tr>
            <td> <b> Branch</b> </td>
            <td> : </td>
            <td> $branch </td>
        </tr>
        <tr>
            <td> <b> Start Date </b> </td>
            <td> : </td>
            <td> $time </td>
        </tr>
FIN

    if ( exists ( $rhAssociation->{ $service }->{ $buildname } ) ) {
        my $b = $rhAssociation->{ $service }->{ $buildname };
        $body .= <<FIN;

        <tr> 
            <td> <b> Run Type </b> </td>
            <td> : </td>
            <td> AutoLQ </td>
        </tr>

        <tr>
            <td> <b> Multi Build Timeline </b> </td>
            <td> : </td>
            <td> <a href="$multiple&build1=$buildname&build2=$b&servicename=$service">$b and $buildname</a> </td>
        </tr>
FIN

    }

    $product = lc $product;
    if ( defined $service ) {
        my $s = uc $service;    # Sorry I could not think of anything better, Please dont curse me !
        my $p = uc $product;
        $body .= <<FIN;
        <tr>
            <td> <b> Service </b> </td>
            <td> : </td>
            <td> $s </td>
        </tr>
        <tr>
            <td> <b> Current Trend </b> </td>
            <td> : </td>
            <td> <a href="$link&product=$product&service=$service&xtra=$buildname">$p on $s service</a> </td>
        </tr>
FIN
    } else {
        my $count = 0;
        $body .= qq [ </table><table><tr> <td> <b>Current Trend</b> </td> <td> :</td> ];
        foreach my $srv ( sort { $a cmp $b } @services ) {
            next if ( $srv =~ /^Build/ || $srv eq '' );
            $count++;
            $body .= qq [<td><a href='$link&product=$product&service=$srv&xtra=$buildname' >$product on $srv service</a> ];
            $body .= ( scalar ( @services ) - 1 > $count ) ? qq [  | </td>] : qq [</td> </tr> ];
        }
    }

    $body .= <<FIN;
    </table>
    <br>
FIN

    print $body;
}

sub graph_footer {

    print <<FIN;
    </body>
</html>
FIN

}

#
# Print HTML footer
#
sub footer {
    my ( $success, $in_progress, $fail, $more_info ) = ( success_icon(), in_progress_icon(), fail_icon(), more_info_icon() );

    print <<FIN;
<br/>
</td>
</tr>
</table>
<script>
\$('div[title]').qtip
(
    {
        style: { name: 'dark', tip: true, fontSize: '80%' },
        position: { corner: { target: 'bottomMiddle', tooltip: 'topMiddle' } }
    }
);

</script>
</body>
</html>
FIN
}

sub trend_header {
    return <<FIN;
<!DOCTYPE html>
<meta charset="utf-8">
<head>
	<link href="https://rc.ariba.com/nvd3/src/nv.d3.css" rel="stylesheet" type="text/css">
	<script src="https://rc.ariba.com/nvd3/lib/d3.v3.js"></script>
	<script src="https://rc.ariba.com/nvd3/nv.d3.js"></script>
	<script src="https://rc.ariba.com/nvd3/src/tooltip.js"></script>
	<script src="https://rc.ariba.com/nvd3/src/utils.js"></script>
	<script src="https://rc.ariba.com/nvd3/src/models/legend.js"></script>
	<script src="https://rc.ariba.com/nvd3/src/models/axis.js"></script>
	<script src="https://rc.ariba.com/nvd3/src/models/multiBar.js"></script>
	<script src="https://rc.ariba.com/nvd3/src/models/multiBarChart.js"></script>

	<style>
		body {
            overflow-y: scroll;
            font-family: Calibri, Helvetica, Arial, sans-serif;
            font-size: 14px;
            color:#272727;
            height: 100%;
        }
        text {
            font: 12px sans-serif;
        }

        #chart1 {
            height: 600px;
            margin: 10px;
            min-width: 100px;
            min-height: 100px;
        }
	</style>
</head>

FIN

}

sub trend_body {
    my $raBuild = shift;
    my $service = shift;
    my $product = shift;
    my $wait    = shift;
    my $url     = shift;

    my $status =
      ( $wait )
      ? "Enabled | <a href=\"$url&wait=0\">Disabled</a> "
      : "Disabled | <a href=\"$url&wait=1\">Enabled</a>";
    my $graphLink = "https://rc.ariba.com/cgi-bin/timeline-graph?action=graph&buildname";
    $service = uc $service;

    my $return = <<FIN;
    <body>
    <div id="timeline_graph_container">
        <h4>Trending Graph for $service Service</h4>

        <table>
            <tr>
                <td>Service</td>
                <td> :</td>
                <td> $service</td>
            </tr>

FIN

    if ( defined ( $product ) ) {
        $product = ucfirst $product;
        $return .= <<FIN;
            <tr>
                <td>Product</td>
                <td> :</td>
                <td> $product</td>
            </tr>
FIN
    }

    $return .= <<FIN;
            <tr>
                <td>Wait Time</td>
                <td> :</td>
                <td> $status</td>
            </tr>
        </table>
FIN

    my $count = 0;
    $return .= qq [ <table> <tr> <td> Buildnames </td> <td> :</td> ];
    foreach my $build ( sort { $a cmp $b } @$raBuild ) {
        $service = lc $service;
        $count++;
        $return .= qq [<td> <a href='$graphLink=$build&servicename=$service' >$build </a> ];
        $return .= ( $count != scalar ( @$raBuild ) ) ? qq [  |  </td>] : qq [</td> </tr> ];
    }

    $return .= <<FIN;
        </table>
        <br><br>

        <div id="chart1" > <svg></svg> </div>
        <script>
FIN

    return $return;

}

sub trend_footer {
    return <<FIN;
        var chart;
		nv.addGraph(function() {
			chart = nv.models.multiBarChart().margin({
				bottom : 100
			}).transitionDuration(300).delay(0).groupSpacing(0.5);

			chart.multibar.hideable(true);

            chart.stacked(true);
            chart.showControls(false);
			chart.reduceXTicks(false).staggerLabels(false);
			chart.xAxis.axisLabel("Buildnames").showMaxMin(false).tickFormat(function(x) {
				return buildname[x]
			});

			chart.yAxis.axisLabel("Minutes").showMaxMin(true).tickFormat(d3.format('.0f'));

			d3.select('#chart1 svg').datum(data).call(chart);

			nv.utils.windowResize(chart.update);

			chart.dispatch.on('stateChange', function(e) {
				nv.log('New State:', JSON.stringify(e));
			});

			return chart;
		});

        console.log('chart', chart);

	</script>

FIN

}

sub pair_body {
    my $raNames = shift;
    my $wait    = shift;
    my $url     = shift;

    my $graphLink = "https://rc.ariba.com/cgi-bin/timeline-graph?action=graph&buildname";
    my $return    = qq [<body> <div id="timeline_graph_container"> <h4>Trending Graph for Build and Service Pair</h4><table> ];
    my $status    = ( $wait ) ? "Enabled | <a href=\'$url&wait=0\'>Disabled</a> " : "Disabled | <a href=\'$url&wait=1\'>Enabled</a>";

    $return .= qq [<tr> <td>Wait Time</td> <td> :</td> <td> $status</td> </tr></table>];

    $count = 0;
    $return .= qq [ <table><tr> <td> Details </td> <td> :</td> ];
    foreach my $name ( @$raNames ) {
        my ( $build, $service ) = split ( ':', $name );
        $count++;
        $return .= qq [<td> <a href='$graphLink=$build&servicename=$service' >$build on $service </a> ];
        $return .= ( $count != scalar ( @$raNames ) ) ? qq [  |  </td>] : qq [</td> </tr> ];
    }

    $return .= qq [ </table> <br><br> <div id="chart1" > <svg></svg> </div> <script>];

    return $return;
}

sub data_not_found {
    return <<FIN;

    <!DOCTYPE html>
<html>
<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<meta name="viewport" content="width=device-width; initial-scale=1.0; maximum-scale=1.0; user-scalable=0;">
<title>Data Not Available</title>
<!--Stylesheets-->
<link rel="stylesheet" href="https://rc.ariba.com/timeline/style.css" />

</head>
<body>

<div id="timeline_graph_container">
  <div class="error_pages error_full_page">
    <h1>Data not available</h1>
    <p> Sorry! We got little late to make this work.. <br />
      We started collecting data from August 26, 2013 15:00:00 </p>
    <button onclick="return window.history.back()" class="redishBtn button_small" style="margin:5px;">Back to Previous page</button>
</div>
</body>
</html>

FIN

}

sub html_error {
    my $error = shift;

    my $errormsg = <<FIN;

    <!DOCTYPE html>
<html>
<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<meta name="viewport" content="width=device-width; initial-scale=1.0; maximum-scale=1.0; user-scalable=0;">
<title>Something Went Wrong!</title>
<!--Stylesheets-->
<link rel="stylesheet" href="https://rc.ariba.com/timeline/style.css" />

</head>
<body>

<div id="timeline_graph_container">
  <div class="error_pages error_full_page">
  <h1>$error Missing !</h1>
    <p> Oops! Something went seriously wrong. <br />
        Looks like you forgot to mention $error which is mandatory input... </p>

    <button onclick="return window.history.back()" class="redishBtn button_small" style="margin:5px;">Lets input $error </button>
</div>
</body>
</html>

FIN

    return $errormsg;

}

1;
