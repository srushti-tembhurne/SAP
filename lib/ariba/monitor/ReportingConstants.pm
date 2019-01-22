package ariba::monitor::ReportingConstants;

# $Id: //ariba/services/monitor/lib/ariba/monitor/ReportingConstants.pm#4 $

#Europe, Middle East, Africa for Ariba

%EMEACountries = (

"AUT",	"Austria",
"BEL",	"Belgium",
"CZE",	"Czech Republic",
"DNK",	"Denmark",
"EGY",  "Egypt",
"FIN",	"Finland",
"FRA",	"France",
"DEU",	"Germany",
"GRC",	"Greece",
"HUN",	"Hungary",
"ISL",	"Iceland",
"IRL",	"Ireland",
"ISR",	"Israel",
"ITA",	"Italy",
"KWT",	"Kuwait",
"LUX",	"Luxembourg",
"NLD",	"Netherlands",
"NOR",	"Norway",
"POL",	"Poland",
"PRT",	"Portugal",
"RUS",	"Russian Federation",
"ZAF",	"South Africa",
"ESP",	"Spain",
"SWE",	"Sweden",
"CHE",	"Switzerland",
"TUR",	"Turkey",
"GBR",	"United Kingdom",

);

#Asia Pacific for Ariba

%APCountries = (

"AUS",	"Australia",
"BRN",	"Brunei Darussalam",
"CHN",	"China",
"HKG",	"Hong Kong",
"IND",	"India",
"IDN",	"Indonesia",
"JPN",	"Japan",
"KOR",	"South Korea",
"MYS",	"Malaysia",
"NZL",	"New Zealand",
"PAK",	"Pakistan",
"PHL",	"Philippines",
"SGP",	"Singapore",
"LKA",	"Sri Lanka",
"TWN",	"Taiwan",
"THA",	"Thailand",
"VNM",	"Vietnam",

);


sub sqlList {
	my $ref = shift;
	my $result;

	$result = "(";

	for my $key ( sort keys(%$ref) ) {
		$result .= "'" . $key . "', ";
	}
	$result =~ s/, $//o;

	$result .= ")";

	return $result;
}



1;
