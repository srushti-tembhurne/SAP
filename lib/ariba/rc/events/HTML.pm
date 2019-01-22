package ariba::rc::events::HTML;

# 
# Static methods used by CGI scripts
#
# References:
# http://www.jankoatwarpspeed.com/post/2008/05/22/CSS-Message-Boxes-for-different-message-types.aspx
# http://itweek.deviantart.com/art/Knob-Buttons-Toolbar-icons-73463960
#

my $ICONS = "http://rc.ariba.com:8080/resource/events";

sub header
{
    my ($title) = @_;

    print <<FIN;
<html>
<head>
<style>
.feeditem { background: #efefef; }
.grey { background: #dfdfdf; }
.pretty { font-family: Verdana, sans-serif; }
.prettytable { width: 750px; border: 1px solid #000000; }

.info, .success, .warning, .error, .validation {
border: 1px solid;
margin: 10px 0px;
padding:15px 10px 15px 50px;
width: 689px;
background-repeat: no-repeat;
background-position: 10px center;
}
.info { color: #00529B; background-color: #BDE5F8; background-image: url('$ICONS/info.png'); }
.success { color: #4F8A10; background-color: #DFF2BF; background-image:url('$ICONS/success.png'); }
.warning { color: #9F6000; background-color: #FEEFB3; background-image: url('$ICONS/warning.png'); }
.error { color: #D8000C; background-color: #FFBABA; background-image: url('$ICONS/error.png'); }
</style>
<title>$title</title>
</head>
<body class="pretty" bgcolor="#ffffff" vLink=#000000 aLink=#000000 link=#000000>
FIN
}

#
# Print global set of topmost links
#
sub chrome
{
    print <<FIN;
<div class="grey">
<b>RC Event Viewer</b><br>
</div>
FIN
}

#
# Print global footer
#
sub chrome_footer
{
    my ($uri) = @_;

	my $maillog_link = ariba::rc::events::Constants::maillog_url();
	my $subscriptions_link = ariba::rc::events::Constants::view_all_subscriptions_url();
	my $schedule_editor = ariba::rc::events::Constants::schedule_editor_url();
	my $opml_export_url = ariba::rc::events::Constants::opml_export_url();

    print <<FIN;
<b>Feeds by Type:</b>
<ul>
<li> <a href="$ENV{'SCRIPT_NAME'}?event=view_feed&dirname=builds">Builds</a> - Feeds for individual products</li>
<li> <a href="$ENV{'SCRIPT_NAME'}?event=view_feed&dirname=robots">Robots</a> - Feeds by Robot</li>
</ul>
<b>E-mail Subscriptions:</b>
<ul>
<li> <a href="$maillog_link">Delivery Log</a> - List of deliveries with timestamp, result</li>
<li> <a href="$subscriptions_link">Subscribers</a> - List of subscribers by channel</li>
<li> <a href="$schedule_editor">My Schedule</a> - Mobile Device Delivery Schedule</li>
</ul>
<b>Links:</b>
<ul>
<li> <a href="$ENV{'SCRIPT_NAME'}">RC Events: Main Menu</a>
<li> <a href="https://devwiki.ariba.com/bin/view/Main/RCEvents">RC Event Syndication wiki page</a>
</ul>
<b>Contact:</b>
<ul>
<li> <a href="mailto:Ask_RC\@ariba.com">&lt;Ask_RC\@ariba.com&gt;</a></li>
</ul>
FIN
}

#
# Print global HTML footer
#
sub footer
{
    print <<FIN;
</body>
</html>
FIN
}

#
# Handle errors
#
sub fail
{
    my ($msg) = @_;
    $msg = $msg || "An unexpected error occured. O UNTIMELY DEATH";
	error ($msg);
    return 0;
}

sub warning { _dialog ($_[0], "warning"); }
sub info { _dialog ($_[0], "info"); }
sub success { _dialog ($_[0], "success"); }
sub error { _dialog ($_[0], "error"); }

sub _dialog
{
	my ($msg, $dialog) = @_;
	print <<FIN;
<p><div class="$dialog">$msg</div></p>
FIN
}

1;
