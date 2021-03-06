package ariba::monitor::misc;

# $Id$
# Misc utils for our monitoring software
#
# This is also included by all the ANish RC products
# Do not make this file depend on other monitoring libraries

use strict;
use File::Path;
use File::Basename;
use ariba::rc::Globals;

sub monitorDir {
	return '/var/mon';
}

sub mrtgDir {
	return monitorDir() . "/mrtg";
}

sub downtimeTransactionDir {
	return monitorDir() . "/downtime-transactions";
}

sub snmpDir {
	return monitorDir() . "/snmp";
}

sub queryStorageDir {
	return "/tmp" . monitorDir() . "/query-storage";
}

# this is used to create the /var/mon/query-storage ->
# /tmp/var/mon/query-storage symlink
sub queryStorageDirSymlink {
	return monitorDir() . "/query-storage";
}

sub queryManagerStorageDir {
	return monitorDir() . "/qm-storage";
}

sub queryBehaviorStorageDir {
	return monitorDir() . "/query-behavior";
}

sub queryBehaviorHistoryStorageDir {
	return monitorDir() . "/query-behavior-history";
}

sub faxInfoStorageDir {
	return monitorDir() . "/fax-info";
}

sub outageStorageDir {
	return "/tmp" . monitorDir() . "/outage-storage";
}

# this is used to create the /var/mon/outage-storage ->
# /tmp/var/mon/outage-storage symlink
sub outageStorageDirSymlink {
	return monitorDir() . "/outage-storage";
}

sub circularDBDir {
	my $cdbDir =  monitorDir() . "/circular-db";
	if (-f "/var/tmp/dontwrite-cdb") {
		$cdbDir .= "-throw-away";
	}

	return $cdbDir;
}

sub statusDir {
	my $productName = shift;

	return monitorDir() . "/status";
}

# returns a hash ref in which the keys are names of products,
# the instances of which are to be cycled on a 24hr period
sub cycledWofProducts {
	my %cycledWofProducts = (
		'an'   => 1,
		'edi'  => 1,
		'ais'  => 1,
		'fx'   => 1,
		'ebs'  => 1,
		'help' => 1,
		'estore' => 1,
	);
	return \%cycledWofProducts;
}

# Any product that is cycled
sub cycledProducts {

	my $cycledProducts = cycledWofProducts();

	map { $cycledProducts->{$_} = 1; } (
		ariba::rc::Globals::sharedServiceSourcingProducts(), 
		ariba::rc::Globals::sharedServiceBuyerProducts(),
		's2', 
		'acm',
        ariba::rc::Globals::archesProducts(),
		);

	return $cycledProducts;
}

sub querydPort {
	return 61503;
}

sub alertLogFileForSid {
	my $instance = lc(shift);
	my $instanceUc = uc($instance);

	my $logFile = (glob("/oracle/admin/diag/rdbms/$instance*/$instanceUc/trace/alert_$instanceUc.log"))[0];
	if ($logFile and -f $logFile) {
		return $logFile; 
	} else {
		return ("/oracle/admin/$instanceUc/bdump/alert_$instanceUc.log");
	}
}

sub dbaLogDir {
	my $instance = shift();

	return ("/oracle/app/oracle/logs/$instance");
}

# ugh.
sub tapeRobotDevicesForDatacenter {
	my $datacenter = shift;

	# Can't use commonProduct here, because we'd need to consume
	# StatusPage, and that doesn't work.
	if ($datacenter eq 'snv') {

		return qw(snvaitdrv1 snvaitdrv2 snvaitdrv3 snvaitdrv4 snvaitdrv5 snvaitdrv6);

	} else {

		return qw(bouaitdrv1 bouaitdrv2);

	}
}

sub autoGeneratedDocsDir {
	return monitorDir() . "/docroot";
}

sub imageFileForQueryNameAndFrequency {
	my ($product, $query, $freq) = @_;

	my $fileName = autoGeneratedDocsDir() . "/$product/$query-$freq.png";

	$fileName =~ s#[^\w\d_:\.\/-]#_#go;

	return $fileName;
}

sub htmlWrapperForPregeneratedGraphsForHost {
	my ($host, $oid) = @_;

	my $fileName;

	if ($oid) {
	    $fileName = autoGeneratedDocsDir() . "/snmp/$host/$oid.html";
	} else {
	    $fileName = autoGeneratedDocsDir() . "/snmp/$host/index.html";
	}

	$fileName =~ s#[^\w\d_:\.\/-]#_#go;

	return $fileName;
}

# given $hostname, return a url for it's top-level mrtg monitoring page
sub snmpGraphsUrl {
	my ($hostname,$webserver) = @_;

	my $relativeUrl = "/mon/dynamic/snmp/$hostname/index.html";
	unless ($webserver) {
	    return $relativeUrl;
	} else {
	    return "http://$webserver$relativeUrl";
	}
}

sub expandoJavaScriptHeader {
	my $cookieName = shift || '';
	my $expandoPrefix = shift || '';

	# hack to make opera at least display the page.
	my $block = qq!document.write(".block { display: none }")!;

	if (defined $ENV{'HTTP_USER_AGENT'} && $ENV{'HTTP_USER_AGENT'} =~ /Opera/i) {
		$block = '';
	}

	my @html = qq`
<script type='text/javascript' src='../lib/jquery.js'></script>
<script type='text/javascript' src='../lib/jquery.tools.js'></script>
<script type='text/javascript'>

	var supported = (document.getElementById || document.all);
	var cookieName = '` . $cookieName . qq`';
	var expandoPrefix = '` . $expandoPrefix . qq`';

	function jsmain() {
		if (supported) {
			document.write("<STYLE TYPE='text/css'>");
			$block
			document.write("</STYLE>");

			setInterval('doAutoRefresh()', 4 * 60 * 1000); 
		}
	}

	function getEle(id) { 
		return document.getElementById(id) || document.all[id]; 
	} 
  
	function reExpand() {
		expandos = getExpandos(); 
		for (i = 0; i < expandos.length; i++) {
			var id = expandoPrefix + 'X' + expandos[i]; 
			var node = getEle(id);
			if (typeof node == 'undefined') continue; 

			if (node.style.display != 'block') {
				setExpandoDisplay(id, 'block'); 	
				retrieveQueriesHtmlFromServer(id);
			}
		}
	}

	function setExpandoDisplay(id, state, save) { 
		node = getEle(id);
		if (typeof node == 'undefined') return;
		node.style.display = state; 

		if (save) { 
			id = id.split('X')[1]; // anlprodX123
			found = false; 
			expandos = getExpandos(); 			
			for (i = 0; i < expandos.length; i++) 
				if (expandos[i] == id) { 
					found = true;
					if (state == 'none') 
						expandos.splice(i, 1); 
				}
			if (!found) 
				expandos.push(id);  
			saveExpandos(expandos); 				
		} 
	} 

	function setCookie(name, value, expirationDate) { 
		document.cookie = name + '=' + encodeURIComponent(value) + 
			(expirationDate ? '; expires=' + expirationDate.toGMTString() : '');
	} 

	function getCookie(name) { 
		cookies = document.cookie.split('; '); 
		for (i = 0; i < cookies.length; i++) { 
			cookie = cookies[i].split('='); 
			if (cookie[0] == name) 
				return decodeURIComponent(cookie[1]); 
		}
	}

	function saveExpandos(expandos) { 
		setCookie(cookieName, expandos.join('-'), new Date(new Date().getTime() + 1000 * 60 * 60 * 24));
	} 

	function getExpandos() { 
		savedExpandos = getCookie(cookieName); 
		if (savedExpandos && savedExpandos.search(/[^0-9\-]/) != -1)
			savedExpandos = null; // Removing old expando saved format. 
		expandos = savedExpandos ? savedExpandos.split('-') : [];

		return expandos; 
	} 

	function openClose(id) {
		if (!supported) {
			alert('This link does not work in your browser.');
			return;
		}


		oldState = getEle(id).style.display; 
		if ( oldState == 'block' )
 			setExpandoDisplay(id, 'none', true);
		else {
			setExpandoDisplay(id, 'block', true);
			retrieveQueriesHtmlFromServer(id);
		}
			
	}

	function retrieveQueriesHtmlFromServer(id) {
		var expando = \$('#'+id);
		var qms = expando.attr('qms');
		if (!qms) return;

		id = id.split('X')[1]; // anlprodX123
		expando.load('?', { qmId: id, renderQueriesForQMs: qms }, 
			function (response, status, xhr) { 
				if (status == "error") {
					expando.html("Error occurred while retrieving the queries: " + xhr.status + " " + xhr.statusText + "<br>To retry, re-expand query manager or reload page.");
				} else {
					reExpand(); 
					expando.find("[title]").tooltip({position:"bottom right", offset:[10,0], delay:50});
				}
			});
		
	}

	// http://www.htmlcodetutorial.com/forms/index_famsupp_157.html
	function submitOnEnter(myfield, e) {
		var keycode;

		if (window.event) {
			keycode = window.event.keyCode;
		} else if (e) {
			keycode = e.which;
		} else {
			return true;
		}

		if (keycode == 13) {
		   myfield.form.submit();
		   return false;
		} else {
		   return true;
		}
	}

	function setAutoRefresh (checkbox) {
		var cookieValue = checkbox.checked ? 1 : 0;
		var expirationDate = new Date(new Date().getTime() + 1000 * 60 * 60 * 24 * 3650);
	
		setCookie('autoRefresh', cookieValue, expirationDate);
	}

	function doAutoRefresh () {
		if (\$('#autoRefresh').attr('checked')) {
			window.location.reload();
		}
	}

	jsmain();
	
</script>
`;

	return join("",@html);
}

1;
