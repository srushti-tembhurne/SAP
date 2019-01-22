#!/usr/local/bin/perl -w
#
#   Copyright (c) 2010 Ariba, Inc.
#   All rights reserved. Patents pending.
#
# See usage just below.
#
# This log analysis script is intended to be self sufficient in one file, with no
# dependencies on anything that is not part of a standard Perl 5.10 distribution anywhere.
# Try to keep it that way for simplicity.
#
# It is a sizable script, about 2000 lines with comments as of 2010.09.24. It is organized
# into sections to make it more manageable. As you change this code, please stay
# consistent with the section organization. Each section starts with a comment line
# consisting of "# " followed by 88 equals signs. Within a section, each method/sub
# definition starts with a comment line consisting of "# " followed by 88 periods. Each
# method/sub has a comment describing what it does and returns, and why it is needed
# and/or how it is used if that is not really obvious.
#
# ----- SECTION TOC: ---------------------------------------------------------------------
# Usage message method.
# Constants - builtin lists of error IDs.
# Global Variables - don't add more of these here, add them in section that uses them.
# MAIN FLOW OF CONTROL Methods.
# CLASSIFICATION OF ERRORS
# FILTERING BLOCK OF LINES.
# COMMAND LINE OPTION HANDLING.
# OUTPUT FORMATTING of initial index.html web page.
# OUTPUT FORMATTING of second level type folder and its index.html page.
# OUTPUT FORMATTING of 3rd level Citation-nnnnnn.html page in the 2nd level type folder.
# OUTPUT FORMATTING utility methods.
# Managing global mappings from Type to Lines, and from Lines to Citations.
# Product Build Label Handling - Global Variables and Methods.
# Timestamp Handling - Constants, Global Variables, and Methods.
# End of Script.
# ----------------------------------------------------------------------------------------

use strict;
use English;
use Getopt::Long ();
use File::Basename;
use Time::Local;

sub main ();
sub doFileDir ($);

# Set $Program to the name of the script prefixed with gnu and with .pl stripped off,
# because that is the way most developers would run the program in Ariba, for usage msg.
my $Program = "gnu " . basename($0);
$Program =~ s|\.pl$||;

# ========================================================================================
# Usage message method.
# ----------------------------------------------------------------------------------------

sub usage ()
{
    print STDERR <<END;
usage: $Program [-for special-case] [-include includedIds] [-exclude excludedIds] [-output <directory>] fileDir1 fileDir2 ...

Apply this script to a directory containing log files or the log files themselves, and it
will look for certain exceptions in the UI, and report them index.html and other
supporting files created in the output directory.

If the -for option is given, it must be followed by one of the following special-case names:

1-Primary, for ID9082, Unhandled UI Exceptions, and a few others, the most serious errors
in the log since in general they result in the user seeing a system error page, losing
their session context, and being forced to log in fresh.

2-Secondary, for including a list of IDs that seem next most interesting and worth
addressing after the unhandled UI Exceptions.

3-Tertiary, for excluding the above two special-cases and a large list of IDs that seem
very uninteresting, to provide a third group of errors, some of which we may want to
address.

If no -for, -include, or -exclude options are given, the script defaults to -for
1-Primary, the most important case.

If the -include option is provided, then we will only include IDs from the include set. If
the -exclude option is provided, then we will exclude IDs from the exclude set.

If the -include or -exclude option starts with @, it is treated as a filename, and the
file contents will be processed as if they appeared as the option value, to support large
sets of custom IDs.

Otherwise the option value will be treated as a set of IDS separated by whitespace,
commas, and/or vertical bars.  Each Id must be in the form "ID" followed by digits.

If the -output option is not given, the script will look at the value of the environment
variable ARIBA_WWW_REVIEW_ROOT. If it is defined and matches a pattern for containing
.../\$userName/public_doc/..., everything after /public_doc will be stripped off and
replaced with /logs followed by a generated folder name, and a line will be printed on
STDOUT with the URL for accessing it on nashome.  Either ARIBA_WWW_REVIEW_ROOT needs to be
defined validly to a path including a public_doc folder, or the -output option must be
given. If -output is given, then it must be the path to a directory and index.html will be
created in it and the extended file path printed on STDOUT.  In either case the output
HTML report is generated where the line on STDOUT says to look.

If you get out of memory mmap errors, try running the perl script directly on a Mac or
Linux box with 64 bit perl. Handling a week of data for a lot of kinds of error reports
can easily require 64 bit address space.  gnu will use a 32 bit perl so we can load 32 bit
.so libraries from our backdrop.

END
    exit(1);
}

# ========================================================================================
# Constants - builtin lists of error IDs.
# ----------------------------------------------------------------------------------------

# ID9082 = Unhandled UI Exception, generally user sees system error page, has to login again.
# ID10658 = Contracts data fix needed, called out specifically in the code.
# ID10660 = Contracts data fix needed, called out specifically in the code.
# ID10776, ID10778, ID10779 added per Robert Wells request on 5/10/2011

my $for1PrimaryInclude = "ID9082, ID10658, ID10660, ID10776, ID10778, ID10779";

my $for2SecondaryInclude = <<'END';
    ID651,  ID1328, ID1397, ID2793, ID2811, ID2851, ID2867, ID4305,
    ID4786, ID5703, ID7403, ID7610, ID8022, ID9023, ID9291, ID9334,
    ID9339, ID9379, ID9576, ID9665, ID9820, ID9892, ID9966, ID10132,
    ID10145, ID10544
END

my $for3TertiaryExclude = <<'END';
    ID1134, ID1332, ID1365, ID1390, ID1673, ID1674, ID1754, ID1755,
    ID2254, ID2926, ID2933, ID2934, ID3256, ID3667, ID3668, ID3997,
    ID4748, ID4987, ID4988, ID5009, ID5064, ID5356, ID5411, ID5431,
    ID5498, ID5704, ID5705, ID5710, ID6566, ID6600, ID6601, ID6602,
    ID6605, ID6606, ID6720, ID6726, ID7102, ID7104, ID7105, ID7106,
    ID7115, ID7116, ID7132, ID7345, ID7348, ID7411, ID7675, ID7734,
    ID7737, ID7738, ID7739, ID7757, ID7758, ID7794, ID7795, ID7805,
    ID7815, ID7926, ID8005, ID8007, ID8010, ID8013, ID8014, ID8015,
    ID8016, ID8053, ID8186, ID8188, ID8218, ID8219, ID8223, ID8237,
    ID8249, ID8261, ID8271, ID8315, ID8392, ID8393, ID8527, ID8528, ID8567,
    ID8632, ID8668, ID8684, ID8688, ID8702, ID8704, ID8706, ID8707,
    ID8723, ID8724, ID8772, ID8772, ID8827, ID8854, ID8903, ID8904,
    ID8906, ID8909, ID8911, ID8913, ID8918, ID8936, ID8937, ID8946,
    ID8961, ID8963, ID8964, ID8965, ID8969, ID8977, ID8987, ID8988,
    ID9006, ID9010, ID9013, ID9016, ID9017, ID9024, ID9024, ID9031,
    ID9060, ID9095, ID9096, ID9098, ID9099, ID9112, ID9114, ID9118,
    ID9129, ID9133, ID9141, ID9161, ID9258, ID9264, ID9271, ID9298,
    ID9303, ID9305, ID9306, ID9341, ID9342, ID9343, ID9344, ID9345,
    ID9346, ID9347, ID9348, ID9349, ID9366, ID9373, ID9374, ID9374,
    ID9375, ID9376, ID9389, ID9390, ID9391, ID9393, ID9394, ID9424,
    ID9430, ID9461, ID9462, ID9463, ID9475, ID9491, ID9492, ID9493,
    ID9494, ID9505, ID9506, ID9507, ID9513, ID9565, ID9572, ID9593,
    ID9606, ID9610, ID9646, ID9657, ID9661, ID9671, ID9772, ID9773,
    ID9801, ID9819, ID9821, ID9828, ID9831, ID9835, ID9924, ID9938,
    ID9971, ID9980, ID9982, 

    ID10008, ID10014, ID10039, ID10047, ID10059, ID10066, ID10113,
    ID10151, ID10157, ID10272, ID10320, ID10334, ID10339, ID10353,
    ID10570, ID10573, ID10574, ID10575, ID10576, ID10577, ID10578,
    ID10579, ID10580, ID10581, ID10582, ID10583, ID10584
END

# ========================================================================================
# Global Variables - don't add more of these here, add them in section that uses them.
# ----------------------------------------------------------------------------------------

my $output = "";
my $forOption = "";
my $includeOption = "";
my $excludeOption = "";

my %includeIDSet = ();
my %excludeIDSet = ();

my $outputUrl = "";
my $outputIndexHtml = "";
my $typeIndexHtml = "";
my $citationFile = 0;
my $citationPageCounter = 0;

my %unfilteredLines = ();

# ========================================================================================
# MAIN FLOW OF CONTROL Methods.
# ----------------------------------------------------------------------------------------

# ........................................................................................
# This method is called after global variable declarations and exits rather than
# returning. It parses, validates, and sets up the command line options. It then processes
# each of the directories or files from the command line after the options.  It then uses
# information collected from the logs to construct a suitable folder name for the output
# report, and creates the output folder or makes sure it is a folder if it already
# exists. It then generates the output report as an index.html in the output folder (default
# page for many web servers including nashome), and also generates a 2nd and 3rd level of
# subfolders and web pages that are hyperlinked from the top level page and secondary folder
# pages. Error messages and the usage message are printed on STDERR, and only a single line
# is written to STDOUT, giving the path to the output report. Exits with status 0 if
# successful, and exits with status 1 and an error message and/or usage message on STDERR
# otherwise.

sub main ()
{
    my %options = ();

    Getopt::Long::GetOptions(\%options,
                             "output:s"  => \$output,
                 "for:s"     => \$forOption,
                             "include:s" => \$includeOption,
                             "exclude:s" => \$excludeOption,
                             "help" => \&usage) || exit(1);
    if (! @ARGV) {
        print STDERR "Error: At least one file must be specified.\n";
        usage();
    }

    # Validate -output or ARIBA_WWW_REVIEW_ROOT, creating logs folder if needed.
    validateOutputFolder();

    setupForIncludeExclude();

    foreach my $fileDir (@ARGV) {
        doFileDir($fileDir);
    }

    my $prodBuildLabel = getProductBuildLabel();
    my $minShortDate = getMinShortTimestamp();
    my $maxShortDate = getMaxShortTimestamp();

    my $outputFolderName = "$forOption-$prodBuildLabel-$minShortDate-$maxShortDate";

    if ($outputUrl) {
        $output = "$output/$outputFolderName";
        $outputUrl = "$outputUrl/$outputFolderName";
    }
    if (! -e $output) {
        mkdir $output || die "Error: $output does not exist and cannot be created: $!\n";
    }
    if (! -d $output) {
        print STDERR "Error: $output must be a directory, but is not.\n";
    }

    # Create index.html, and leave OUTINDEX open for output.
    $outputIndexHtml = "$output/index.html";
    unlink($outputIndexHtml);
    open(OUTINDEX, ">$outputIndexHtml") || die "Error: cannot create $outputIndexHtml: $!\n";

    finishProcessing();

    # Output single line on STDOUT telling where the output report can be viewed.

    if ($outputUrl) {
        print "$outputUrl/\n";
    }
    elsif ($outputIndexHtml) {
        print "$outputIndexHtml\n";
    }

    # Close the output index.html file descriptor opened by createOutputIndexHtml.
    close(OUTINDEX) || dieOutIndex();

    exit(0);
}

# ........................................................................................
# Process a file or directory path from the command line. If it is a directory, we
# recursively process each entry in the directory in sorted order, ignoring "hidden" 
# entries that start with a dot. If it is a readable file we call doPlainFile to process
# it, and if it doesn't exist or is not readable, we print a warning message and
# continue processing.

sub doFileDir ($)
{
    my ($fileDir) = @_;

    if ( -d $fileDir) {
        opendir(DIR, $fileDir) || die "Error: Cannot open directory $fileDir: $!\n";
        my @children = sort(readdir(DIR));
        closedir(DIR) || die "Error: Cannot close directory $fileDir: $!\n";
        foreach my $child (@children) {
            # Ignore dotted (hidden) files in directory contents.
            next if $child =~ /^\./;
            my $dirChild = "$fileDir/$child";
            doFileDir($dirChild);
        }
    }
    elsif ( ! -f $fileDir || ! -r $fileDir) {
        print STDERR "Warning: Cannot read $fileDir, ignoring it.\n";
    }
    else {
        doPlainFile($fileDir);
    }
}

# ........................................................................................
# Process plain readable file given $filePath. We read through the lines of the file and
# keep track of the line number for remembering citation of each place in the logs where a
# given error was found. Each block of lines begins with a timestamp line that contains an
# ID that is being reported, and ends before the next timestamp line. Blank lines in the
# block are ignored, and the lines in the block are canonicalized to end cleanly with no
# trailing spaces or other whitespae, and just a newline at the end of each line. We
# construct a "citation" consisting of the log file path and the line number at the
# beginning of the block, in classic Unix/Emacs compile error format, suitable for click
# linking in emacs compile buffer. We call processBlockOfLines for each block of lines
# including a possible final one terminated by the end of the log file.

sub doPlainFile ($)
{
    my ($filePath) = @_;

	#
	# skip 0 length files that we sometimes get
	#
	return unless( -s $filePath );
    
	if($filePath =~ /\.gz$/) {
    	open(INFILE, "/usr/local/bin/gzcat $filePath |") || die "Error: cannot open $filePath: $!\n";
	} else {
    	open(INFILE, $filePath) || die "Error: cannot open $filePath: $!\n";
	}
    my $lineNum = 0;
    my $captureMode = 0;
    my $blockOfLines = "";
    my $citation = "";
    while (my $line = <INFILE>) {
        $lineNum++;
        my $lineTimestamp = getTimestamp($line);
        rememberMinMaxTimestamp($lineTimestamp);
        rememberProductBuildInfo($line);

        if ($captureMode && $lineTimestamp) {
            processBlockOfLines($blockOfLines, $citation);
            $blockOfLines = "";
            $citation = "";
            $captureMode = 0;
        }
        if (!$captureMode && $lineTimestamp) {
            if ($line =~ m|^[A-Za-z]{3}\s+[A-Za-z]{3}\s+\d\d\s+\d\d:\d\d:\d\d\s+[A-Za-z]{2,}\s+2\d\d\d\s+\(.+?\:[A-Z]+\)\s+\[(ID\d+)\]|) {
                my $lineID = $1;
                if ((!%includeIDSet || $includeIDSet{$lineID}) &&
                    (!%excludeIDSet || !$excludeIDSet{$lineID})) {
                    $captureMode = 1;
                    $citation = "$filePath:$lineNum: \n";
                }
            }
        }

        if ($captureMode) {
            # Canonicalize and trim the end of line on filtered output.
            $line =~ s|\s+$|\n|;
            # Don't output blank lines within the error block.
            if ($line !~ m|^\s*$|) {
                $blockOfLines .= $line;
            }
        }
    }
    if ($captureMode) {
        processBlockOfLines($blockOfLines, $citation);
    }
    close(INFILE) || die "Error: cannot close $filePath: $!\n";
}

# ........................................................................................
# Given a block of $lines and the $citation for where it begins, we call filterBlockOfLines,
# in a subsequent filtering section to reduce the quantity while preserving the quality of,
# the block of lines. We push the $citation onto a list in a mapping that keys on the,
# filtered $lines. We remember the unfiltered lines for the first citation we see in,
# another mapping that keys on the filtered $lines.,

sub processBlockOfLines ($$)
{
    my ($lines, $citation) = @_;
    my $unfiltered = $lines;
    $lines = filterBlockOfLines($lines);

    my $citationListRef = getOrCreateCitationListRef($lines);

    my $listSize = @$citationListRef;
    if ($listSize <= 0) {
        $unfilteredLines{$lines} = $unfiltered;
    }

    push(@$citationListRef, $citation);
}

# ........................................................................................
# After all the files have been processed, we classify all the different filtered $lines
# that we found, assigning each a classification $typeName, and we build a map from
# $typeName to list of $lines of that type. We then sort the $typeNames in descending
# order of citation occurrences for each type, and generate the output report driven be
# the list of sorted types, and calling outputIndexHtmlType in a later section on 
# output formatting to output the reporting for each type.

sub finishProcessing ()
{
    foreach my $lines (getListOfAllLines()) {
        my $typeName = getTypeClassification($lines);
        my $typeListRef = getOrCreateTypeListRef($typeName);
        push(@$typeListRef, $lines);
    }

    my $totalCount = 0;
    my @typePayloads = ();
    foreach my $typeName (getListOfAllTypeNames()) {
        my $typeCitationCount = getTypeCitationCount($typeName);
        $totalCount += $typeCitationCount;
        my $typePayload = sprintf("%09d:%s", $typeCitationCount, $typeName);
        push(@typePayloads, $typePayload);
    }

    outputIndexHtmlBegin();
 
    foreach my $typePayload (reverse(sort(@typePayloads))) {
        my ($count, $typeName) = split(/:/, $typePayload, 2);
        $count =~ s/^0+//;
        outputIndexHtmlType($typeName, $count, $totalCount);
    }

    outputIndexHtmlEnd($totalCount);
}

# ========================================================================================
# CLASSIFICATION OF ERRORS
# ----------------------------------------------------------------------------------------

# ........................................................................................
# Returns text classification of the error, based on the given filtered $lines. These are
# the strings that appear sorted in reverse occurrence order on the initial web page in
# the report. They often have an Ariba team prefix to help with assigning them for further
# investigation and defect filing and fixing.

sub getTypeClassification ($)
{
    my ($lines) = @_;
    my $typeName = "";

    # ------ Platform Patterns -----------------------------------------------------------

    # This one should be very early, otherwise it will get classified as something else
    # before this check, it often occurs is conjunction with other errors, for which
    # the broken output connection is the root problem.
    if ($lines =~ m|SocketException: Broken pipe|) {
        return "Platform-UserClosedBrowserInMidAction";
    }

    elsif ($typeName = getTypeClassifyForClassicJavaException($lines)) {
        return $typeName;
    }
    elsif ($typeName = getTypeClassifyForDatabase($lines)) {
        return $typeName;
    }
    elsif ($typeName = getTypeClassifyForPersistence($lines)) {
        return $typeName;
    }
    elsif ($typeName = getTypeClassifyForPartitionRealm($lines)) {
        return $typeName;
    }
    elsif ($typeName = getTypeClassifyForSessionLifeCycle($lines)) {
        return $typeName;
    }
    elsif ($typeName = getTypeClassifyForAribaWeb($lines)) {
        return $typeName;
    }
    elsif ($typeName = getTypeClassifyForDashboard($lines)) {
        return $typeName;
    }
    elsif ($typeName = getTypeClassifyForMessaging($lines)) {
        return $typeName;
    }

    # ------ Upstream App Patterns -------------------------------------------------------

    elsif ($typeName = getTypeClassifyForContracts($lines)) {
        return $typeName;
    }
    elsif ($typeName = getTypeClassifyForSourcing($lines)) {
        return $typeName;
    }
    elsif ($typeName = getTypeClassifyForAnalysis($lines)) {
        return $typeName;
    }

    # ------ Downstream Buyer App Patterns -----------------------------------------------

    elsif ($typeName = getTypeClassifyForCatalog($lines)) {
        return $typeName;
    }
    elsif ($typeName = getTypeClassifyForACC($lines)) {
        return $typeName;
    }

    # ------ TransientException Patterns -------------------------------------------------

    # This needs to be called late, because there is at least one more specific
    # TransientException pattern that is done as part of AribaWeb patterns. This
    # handling catches any TransientException that hasn't been handled already.
    elsif ($typeName = getTypeClassifyForTransientException($lines)) {
        return $typeName;
    }

    # ------ Data Fix Needed Patterns ----------------------------------------------------

    elsif ($typeName = getTypeClassifyForDataFixNeeded($lines)) {
        return $typeName;
    }

    # ------ Final "catch-all" classification --------------------------------------------

    else {
        # Default to returning "Other" as the type classification.
        my $team = getInferredTeam($lines);
        return "$team-Other";
    }
}

# ........................................................................................
# Returns non-empty typeName string for type classification of $lines, if they match one
# of the "classic" Java exceptions independent of Ariba code. Returns empty string if no 
# match is found.

sub getTypeClassifyForClassicJavaException ($)
{
    my ($lines) = @_;

    if ($lines =~ m|IndexOutOfBoundsException|) {
        my $team = getInferredTeam($lines);
        return "$team-IndexOutOfBoundsException";
    }
    elsif ($lines =~ m|NullPointerException|) {
        my $team = getInferredTeam($lines);
        return "$team-NPE";
    }
    elsif ($lines =~ m|ClassCastException|) {
        my $team = getInferredTeam($lines);
        return "$team-ClassCastException";
    }
    elsif ($lines =~ m|regex\.PatternSyntaxException|) {
        my $team = getInferredTeam($lines);
        return "$team-Regex-Bad-Pattern";
    }

    else {
        return "";
    }
}

# ........................................................................................
# Returns non-empty typeName string for type classification of $lines, if they match one
# of the "Database" related patterns. Returns empty string if no match is found.

sub getTypeClassifyForDatabase ($)
{
    my ($lines) = @_;

    if ($lines =~ m|SQLException: Closed Connection| or 
        $lines =~ m|SQL Error Io exception: Connection reset| or
        $lines =~ m|SQL Error Closed Connection| or
        $lines =~ m|SQL Error No more data to read from socket| or
        $lines =~ m|SQLException: No more data to read from socket|) {
        return "Database-Connection-Problems";
    }
    elsif ($lines =~ m|jdbcserver\.TransactionException| && $lines =~ m|JDBCServer\.createJDBCConnection|) {
        return "Database-Cannot-Create-Connection";
    }
    elsif ($lines =~ m|ORA\-12805|) {
        return "Database-Failures";
    }
    elsif ($lines =~ m|ORA-00001: unique constraint \(.*?\) violated|) {
        my $team = getInferredTeam($lines);
        return "$team-Database-Unique-Constraint-Violated";
    }
    elsif ($lines =~ m|Query monitoring threshold exceeded| or 
           $lines =~ m|Query cancelled since timeout exceeded|) {
        my $team = getInferredTeam($lines);
        return "$team-Database-Slow-Query";
    }
    elsif ($lines =~ m|ORA-| or 
           $lines =~ m|SQL Error| or 
           $lines =~ m|AQL Execution Error| or 
           $lines =~ m|SQLException|) {
        my $team = getInferredTeam($lines);
        return "$team-Database-Other";
    }

    else {
        return "";
    }
}

# ........................................................................................
# Returns non-empty typeName string for type classification of $lines, if they match one
# of the Persistence layer related patterns. Returns empty string if no match is found.

sub getTypeClassifyForPersistence ($)
{
    my ($lines) = @_;

    if ($lines =~ m|OutOfDateException|) {
        my $context = $lines;
        if ($lines =~ m|OutOfDateException: {BASE-ID} of type (.*?) {OUT-OF-DATE-DETAILS}|) {
            $context = $1;
        }
        my $team = getInferredTeam($context);
        return "$team-OutOfDateException";
    }
    elsif ($lines =~ m|realm can read only its data|) {
        my $team = getInferredTeam($lines);
        return "$team-Realm-can-read-only-its-data";
    }
    elsif ($lines =~ m|object \{BASE-ID\} not found| or
           $lines =~ m|BaseObject {BASE-ID} was not found in ClusterRoot|) {
        my $team = getInferredTeam($lines);
        return "$team-BaseId-not-found";
    }
    elsif ($lines =~ m|Object {BASE-ID} was released from the cache|) {
        my $team = getInferredTeam($lines);
        return "$team-BaseId-released-from-cache";
    }
    elsif ($lines =~ m|AQLVisitorException: Field .*? is derived, and cannot be queried|) {
        my $team = getInferredTeam($lines);
        return "$team-AQL-Validation-Derived-Field";
    }
    elsif ($lines =~ m|nested session still in effect| or
           $lines =~ m|FatalAssertionException: no nestedTransactionBegin|) {
        return "Platform-Nested-Session-Problems";
    }
    elsif ($lines =~ m|is not of the expected format| && $lines =~ m|parseInBase36Format|) {
        my $team = getInferredTeam($lines);
        return "$team-Base64-Passed-As-Base36";
    }

    else {
        return "";
    }
}

# ........................................................................................
# Returns non-empty typeName string for type classification of $lines, if they match one
# of the Persistence layer related patterns. Returns empty string if no match is found.

sub getTypeClassifyForPartitionRealm ($)
{
    my ($lines) = @_;

    if ($lines =~ m|partition should be specified| or
        $lines =~ m|BaseObject\.init was given a null Partition|) {
        return "Platform-No-Partition-Specified";
    }
    elsif ($lines =~ m|Unable to find the realm| or
           $lines =~ m|RealmInconsistentException: Failed to set the realm on the session| or
           $lines =~ m|There is no peer realm for {REALM-INFO}| or
           $lines =~ m|A non-empty ANId is req.*? for getting RealmProfile|) {
        return "Platform-Realm-Problems";
    }
    elsif ($lines =~ m|Asked for partitioned parameter .*? without a partition|) {
        my $team = getInferredTeam($lines);
        return "$team-Partitioned-Parameter-Usage";
    }

    else {
        return "";
    }
}

# ........................................................................................
# Returns non-empty typeName string for type classification of $lines, if they match one
# of the Session, Login, SSO, Shutdown, etc related patterns. Returns empty string if 
# no match is found.

sub getTypeClassifyForSessionLifeCycle ($)
{
    my ($lines) = @_;

    if ($lines =~ m|AWSessionRestorationException| or
        $lines =~ m|session keep alive time not available| or
        $lines =~ m|Session already invalidated|) {
        return "Platform-Session-Problems";
    }
    elsif ($lines =~ m|Unable to complete authentication| or
           $lines =~ m|Error occurred while handling session validation| or
           $lines =~ m|SSOLoginPage| or $lines =~ m|UserSSOAuthenticator| or
           $lines =~ m|SSOClientInitManager| or
           ($lines =~ m|IllegalArgumentException: Invalid digest| &&
            $lines =~ m|MessageDigestUtil\.compareWithSalt|)) {
        return "Platform-Login";
    }
    elsif ($lines =~ m|There is no partition on the session\. Can not complete login|) {
        return "Platform-Login";
    }
    elsif ($lines =~ m|Operation is aborted because shutdown has started|) {
        return "Platform-Shutdown-In-Progress";
    }

    else {
        return "";
    }
}

# ........................................................................................
# Returns non-empty typeName string for type classification of $lines, if they match one
# of the AribaWeb/UI related patterns. Returns empty string if no match is found.

sub getTypeClassifyForAribaWeb ($)
{
    my ($lines) = @_;

    if ($lines =~ m|ClientAbortException|) {
        return "AribaWeb-ClientAbortException";
    }
    elsif ($lines =~ m|dashboard object is null for user|) {
        return "AribaWeb-Dashboard-Problems";
    }
    elsif ($lines =~ m|should never be called since this page should never be cached| or
           $lines =~ m|Context component cannot be null\.\s*Binding|) {
        return "AribaWeb-Inconsistent-State";
    }
    elsif ($lines =~ m|errorKey cannot be null|) {
        my $team = getInferredTeam($lines);
        return "$team-AWComponent-Errors";
    }
    elsif ($lines =~ m|ARFVectorField tried to display a vector of objects, but did not know which field of the vector's data type to display|) {
        return "Platform-ARFVectorField-WhichField";
    }
    elsif ($lines =~ m|NumberFormatException: For input string: ""|) {
        return "AribaWeb-NumberFormatException-for-empty-string";
    }
    elsif ($lines =~ m|AWThreadTimeoutException| or
           $lines =~ m|AWMaxWaitingThreadException|) {
        return "AribaWeb-ThreadTimeoutException";
    }
    elsif ($lines =~ m|IncludeComponent failed to rendezvous with existing element| or
           $lines =~ m|AWIncludeComponent cannot locate component named|) {
        return "AribaWeb-IncludeComponent";
    }
    elsif ($lines =~ m|reference to Named Content not found|) {
        return "AribaWeb-Named-Content-not-found";
    }
    elsif ($lines =~ m|TransientException: The values you are working with have been discarded|) {
        return "AribaWeb-Discarded-Values";
    }

    else {
        return "";
    }
}

# ........................................................................................
# Returns non-empty typeName string for type classification of $lines, if they match one
# of the Dashboard related patterns. Returns empty string if no match is found.

sub getTypeClassifyForDashboard ($)
{
    my ($lines) = @_;

    if ($lines =~ m|ariba\.dashboard\.component\.SearchPortlet|) {
        return "Dashboard-Search-Problems";
    }
    elsif ($lines =~ m|Error getting portlet provider strings file| or
           $lines =~ m|Portlet content fetch failed| or
           $lines =~ m|Invalid XML/Data table content for portlet| or
           $lines =~ m|Error in display dashboard content for user| or
           $lines =~ m|Dashboard is unable to connect to App| or
           $lines =~ m|Updating portlet content cache in dashboard|) {
        return "Dashboard-Problems";
    }

    else {
        return "";
    }
}

# ........................................................................................
# Returns non-empty typeName string for type classification of $lines, if they match one
# of the Messaging related patterns. Returns empty string if no match is found.

sub getTypeClassifyForMessaging ($)
{
    my ($lines) = @_;

    if ($lines =~ m|ariba\.integration\.core\.ConfigurationException|) {
        return "Messaging-Configuration-Problems";
    }

    else {
        return "";
    }
}

# ........................................................................................
# Returns non-empty typeName string for type classification of $lines, if they match one
# of the Contracts app related patterns. Returns empty string if no match is found.

sub getTypeClassifyForContracts ($)
{
    my ($lines) = @_;

    if ($lines =~ m|ContractDocumentBaseSyncup|) {
        return "Contracts-Syncup-Problems";
    }
    elsif ($lines =~ m|CreateProjectDetailsPage|) {
        return "Contracts-CreateProjectDetailsPage-Problems";
    }
    elsif ($lines =~ m|ariba\.collaborate\.documentui\.explore| or
           $lines =~ m|ariba\.collaborate\.projectui\.explore|) {
        return "Contracts-Search-Problems";
    }
    elsif (($lines =~ m/AbstractDocumentDownloadIcon/ && $lines =~ m/document binding=null/) or
           ($lines =~ m|Unable to locate getter method or field for: "isEditable"| &&
            $lines =~ m|ariba\.collaborate|)) {
        return "Contracts-AWComponent-Errors";
    }

    else {
        return "";
    }
}

# ........................................................................................
# Returns non-empty typeName string for type classification of $lines, if they match one
# of the Sourcing app related patterns. Returns empty string if no match is found.

sub getTypeClassifyForSourcing ($)
{
    my ($lines) = @_;

    if ($lines =~ m|Unable to locate getter method or field for: "ItemRank"| or
        $lines =~ m|ariba\.sourcing\.rfxui\.ASPComposeMessageForEvent| or
        $lines =~ m|ariba\.sourcing\.rfxui\.fields\.ASVPreviewBeginDate|) {
        return "Sourcing-AWComponent-Errors";
    }
    elsif ($lines =~ m|State of \[ariba.sourcing.content.RFXItemValue {BASE-ID}\] is incorrect !| or
           $lines =~ m|ItemValueProxy| or
           $lines =~ m|ariba\.sourcing\.basic\.ItemValueFieldTypeProperties|) {
        return "Sourcing-ItemValue-Problems";
    }
    elsif ($lines =~ m|ariba\.sourcing\..*?ui\.| &&
           $lines =~ m|null fp in controllerForField|) {
        return "Sourcing-AWComponent-Errors";
    }
    elsif ($lines =~ m/ASCExcelBiddingImport/) {
        return "Sourcing-ExcelBiddingImport-Problems";
    }
    elsif ($lines =~ m|ariba\.sourcing\.chartingui\.BidChart|) {
        return "Sourcing-BidChart-Problems";
    }
    elsif ($lines =~ m|It can't create the Profile Details Page| or
           $lines =~ m|ariba.sourcing.content.profile| or
           $lines =~ m|ariba.sourcing.profileui.|) {
        return "Supplier-Profile-Problems";
    }

    else {
        return "";
    }
}

# ........................................................................................
# Returns non-empty typeName string for type classification of $lines, if they match one
# of the Analysis app related patterns. Returns empty string if no match is found.

sub getTypeClassifyForAnalysis ($)
{
    my ($lines) = @_;

    if ($lines =~ m|ariba\.analytics\.excel\.ExcelExportAction|) {
        return "Analysis-ExcelExport-Problems";
    }
    elsif ($lines =~ m|ariba\.analytics\.olapui\.PivotTabContent| or
        $lines =~ m|ariba\.analytics\.olapwizard\.PivotTableSkeleton| or
        $lines =~ m|ariba\.analytics\.olapui\.ReportTocFieldBrowser|) {
        return "Analysis-OLAP-Problems";
    }

    else {
        return "";
    }
}

# ........................................................................................
# Returns non-empty typeName string for type classification of $lines, if they match one
# of the buyer Catalog related patterns. Returns empty string if no match is found.

sub getTypeClassifyForCatalog ($)
{
    my ($lines) = @_;

    if ($lines =~ m|ariba\.catalog\.search|) {
        return "Catalog-Search";
    }

    else {
        return "";
    }
}

# ........................................................................................
# Returns non-empty typeName string for type classification of $lines, if they match one
# of the TransientException related patterns. Returns empty string if no match is found.

sub getTypeClassifyForTransientException ($)
{
    my ($lines) = @_;

    if ($lines =~ m|TransientException| && $lines =~ m|invokeActionForRequest|) {
        return "TransientException-properly-handled";
    }
    elsif ($lines =~ m|TransientException|) {
        # This match should be after all others involving TransientException.
        my $team = getInferredTeam($lines);
        return "$team-TransientException-that-did-not-display-properly";
    }

    else {
        return "";
    }
}

# ........................................................................................
# Returns non-empty typeName string for type classification of $lines, if they match one
# of the Data Fix Needed patterns. Returns empty string if no match is found.

sub getTypeClassifyForDataFixNeeded ($)
{
    my ($lines) = @_;

    if ($lines =~ m%ID10658|ID10660%) {
        return "Contracts-Datafix-needed";
    }
    elsif ($lines =~ m|Could not send email notification| or
        $lines =~ m|emailAddress for user is null|) {
        return "Data-Bad-Email-Address";
    }

    else {
        return "";
    }
}

# ........................................................................................
# Returns non-empty typeName string for type classification of $lines, if they match one
# of the buyer ACC related patterns. Returns empty string if no match is found.

sub getTypeClassifyForACC ($)
{
    my ($lines) = @_;

    if ($lines =~ m|punchoutSession must not be null| && 
        $lines =~ m|ariba\.htmlui\.procure\.masteragreement\.ContractDirectAction|) {
        return "ACC-Punchout-Session";
    }

    else {
        return "";
    }
}

# ........................................................................................
# Returns string Ariba team name, for the team most likely to be responsible for
# investigating a log error, based on the given text associated with the error.
# We check for the upstream teams in reverse build order. This method can be extended for
# teams within downstream buyer as desired. If the text contains no class paths from
# upstream or downstream application packages, returns default assumption that the
# "Platform" team should look at it first.

my %packageToTeam = ('analytics',"Analysis", 
                     'sourcing',"Sourcing",
                     'collaborate',"Contracts",
                     'asm',"Upstream",
                     'catalog', "Catalog",
                     'buyer',"Buyer");

sub getInferredTeam ($)
{
    my ($text) = @_;
    my $package = "";
    my $team = "";

    if ($text =~ m%ariba\.(analytics)%) {
        $package = $1;
    }
    elsif ($text =~ m%ariba\.(sourcing)% or 
           $text =~ m%ContentTree%) {
        $package = $1;
    }
    elsif ($text =~ m%ariba\.(collaborate)%) {
        $package = $1;
    }
    elsif ($text =~ m%ariba\.(asm)%) {
        $package = $1;
    }
    elsif ($text =~ m%ariba\.(catalog)%) {
        $package = $1;
    }
    elsif ($text =~ m%ariba\.(buyer)%) {
        $package = $1;
    }
    if ($package) {
        $team = $packageToTeam{$package};
    }
    if (!$team) {
        $team = "Platform";
    }
    return $team;
}

# ========================================================================================
# FILTERING BLOCK OF LINES.
# ----------------------------------------------------------------------------------------

# ........................................................................................
# Returns given $lines filtered down to unify root causes and get rid of distractions,
# while retaining information that is either not recognized yet, or is relevant to high
# level reporting of errors in aggregate.  This is the main method in this section, it is
# called on each block of lines starting with a timestamped log error line that we find.

sub filterBlockOfLines ($)
{
    my ($lines) = @_;

    # Remove [Unloading class...] lines, they can come in the middle of other log lines.
    $lines =~ s|\[Unloading class .*?\]\s*\n||g;

    $lines = removeLinesFromGC($lines);

    $lines = removeLogId($lines);

    $lines = removeThreadState($lines);

    # Simplify all stacktrace blocks of tab-at lines.
    $lines =~ s|((?:\tat .*?\n)+)|simplifyStackTrace($1)|eg;

    # Do intelligent truncation of SQL/AQL buffer dumps, which can be extremely large for
    # some query errors.
    $lines =~ s|(\[SQLBuffer \`)(SELECT .*?)(\'\]\s+\[BindVariables:\s+\()(.*?)(\)\] processing statement )(.*?)(\.\s+next\(\) cannot be used .*?\n)|truncateSQLBuffer($1,$2,$3,$4,$5,$6,$7)|egs;

    # Discard " ... NN more lines" from Caused by stack trace abbreviation.
    $lines =~ s%^\s+\.\.\.\s+\d+\s+more\s*\n%%gm;

    # Blur out details like actual date values, BaseId values, Realm ids, etc.
    $lines = blurDetails($lines);

    # If it is a NullPointerException followed by a stack frame line number, filter
    # down to that, the line of code is the root cause for NPE, and the rest of the code
    # stack and other output is not helpful for unifying them in high level summary.

    if ($lines =~ m%(java\.lang\.NullPointerException\s*\n\s*at .*?\(.*?\.java:\d+\))%) {
        $lines = $1;
    }

    # Make sure block of lines ends with a single newline.
    $lines =~ s|\s*$|\n|;

    return $lines;
}

# ........................................................................................
# Returns the given $lines with all the specific details "blurred out".  We want to
# unify occurrences of closely related errors with the same call stack etc., so we need 
# to get rid of particular BaseId values, Java hex instance numbers, realm Ids, timestamps,
# thread info, date-time values, organization details, sourcing item value details, user
# names, particular index values for out of bound errors, and so forth. For most of these
# cases, the value is replaced by a curly braced token indicating what kind of value was
# there. In a few cases we just remove the value altogether for aesthetic reasons.

sub blurDetails ($)
{
    my ($lines) = @_;

    # We should probably get rid of these in the log, or handle them better...
    $lines =~ s|^Info: util core FormatBuffer grew to \d+\s*\n||g;

    $lines =~ s|\@[0-9a-f]+||g;

    $lines =~ s|\[BaseId\s+\d+\s+[\w\+\!]+\s+[0-9a-z]+\.[0-9a-z]+\](\s+\(\d+\))?|{BASE-ID}|g;

    $lines =~ s|'[A-Za-z0-9\+\!]'(?:,'[A-Za-z0-9\+\!]')+|{BASE64-BINDINGS}|g;

    # Get rid of dashed lines from explain plans.
    $lines =~ s|^\s*\-{10,}\s*\n$||g;

    $lines =~ s|\[Realm id=\d+ name=.*? 2\d\d\d\]|{REALM-INFO}|g;

    $lines =~ s|^([A-Za-z]{3}\s+[A-Za-z]{3}\s+\d\d\s+\d\d:\d\d:\d\d\s+[A-Za-z]{2,}\s+2\d\d\d)\s+\(.*?\)\s*|{TIMESTAMP} ({THREAD-INFO}) |gm;
    $lines =~ s|[A-Za-z]{3}\s+\d+,\s+2\d\d\d\s+\d+:\d\d:\d\d\s+[A-Za-z]{2,}(\s+)|{DATETIME}$1|gm;

    $lines =~ s|(AWSessionRestorationException: Unable to restore session with sessionId:) .*?\n|$1 {SESSION-AND-REMOTE-ADDRESS-DETAILS}\n|gm;
    $lines =~ s|(FatalAssertionException: Cannot create new ariba\.user\.core\.Organization with field SystemID equal to) .*?\.\s*(Conflicts with existing object) \[\{.*?\}\]\s*\n|$1 {SYSTEM-ID}. $2 {ORGANIZATION-DETAILS}\n|gms;
    $lines =~ s|(FatalAssertionException: Commiting profile values for Organization) .*? \(.*?\) (with a Draft alternative) .*? \(.*?\) (of type) \d+\.|$1 {ORG-ID-1} $2 {ORG-ID-2} $3 {TYPE-NUMBER}.\n|gm;
    $lines =~ s|(FatalAssertionException: Commiting profile values for Organization) .*? \(.*?\) (with an unpinned alternative) .*? \(.*?\) (of type) \d+\.|$1 {ORG-ID-1} $2 {ORG-ID-2} $3 {TYPE-NUMBER}.\n|gm;
    $lines =~ s|(FatalAssertionException: Unable to find item) \d+ (requested by ItemValueProxy) \- .*?\n\CT=(?:\s*ItemProxy .*?\n)+|$1 {ITEM-NUMBER} $2 - {ITEM-PROXY-DETAILS}\n|gm;
    $lines =~ s|(FatalAssertionException: Unable to find the realm for) ([\w\-]+)|$1 {REALM-NAME}|g;

    $lines =~ s|(FatalAssertionException: a realm can read only its data or system data\.) .*?\n|$1 {BID-REALM-DETAILS}\n|gm;
    $lines =~ s|(FatalAssertionException: dashboard object is null for user) .*?\n|$1 {USER-UNIQUE-NAME}\n|gm;
    $lines =~ s|(FatalAssertionException: session is null for key) .*?\n|$1 {ANALYSIS-SESSION-KEY}\n|gm;
    $lines =~ s|(IndexOutOfBoundsException: Index:) \d+, (Size:) \d+\s*\n|$1 {BOUNDS-INDEX}, $2 {BOUNDS-SIZE}\n|g;
    $lines =~ s|(OutOfDateException:)\s*\n({BASE-ID\} of type .*?)\s*\n.*?^Version of type java\.lang\.Integer \[\d+ -> \d+\]\s*\n\]\s*\n|$1 $2 {OUT-OF-DATE-DETAILS}]\n|gms;
    $lines =~ s|(TransientException:) .*? (has the event locked, therefore you are no longer allowed to make changes to it\.)\s*\n|$1 {USER-NAME} $2\n|gm;
    $lines =~ s|(instance HttpSessionIds key) .*?\n|$1 {HTTP-SESSION-KEY}\n|g;

    $lines =~ s|(Cannot set language string to) .*? (because locale to language mapping is not found for locale) \w+|$1 {LANGUAGE-NAME} $2 {LOCALE_ID}|g;

    $lines =~ s|(Portlet content fetch failed; user:) .*?(, portlet: .*?, instance:) .*?,|$1 {USER-UNIQUE_NAME}$2 {PORTLET-INSTANCE},|g;

    $lines =~ s|Portlet\d+(?:,\s*Portlet\d+)+|{PORTLET-INSTANCES}|g;

    $lines =~ s| /fs/.*?/dashboardcache/.*? | {DASHBOARDCACHE-FILEPATH} |g; 

    $lines =~ s|(New file) .*? (does not exist to rename; current file) .*? (exists: false)|$1 {NEW-FILE-NAME} $2 {CURRENT-FILE-NAME} $3|g;

    $lines =~ s|\(typecode \d+\)|(typecode {TYPECODE-NUMBER})|g;

    $lines =~ s|\[Variant .*? ".*?" \d+ realm\]|[Variant {VARIANT-REALM-INFO}]|g;

    $lines =~ s|UI\d+ does not have|{UI-NODE-ID} does not have|g;


    $lines =~ s|(Could not send email notification to) \[.*?\]: (Invalid Addresses; nested exception is:) .*|$1 [{BAD-EMAIL-ADDRESS}]: $2 ...|g;

    $lines =~ s|{BASE-ID}(?:,\s*{BASE-ID})+|{BASE-IDS}|g;

    $lines =~ s|^Session is \{.*?\}\s*\n||gm;

    return $lines;
}

# ........................................................................................
# Returns given stacktrace text simplified down to its application essentials. This method
# is called with a text value composed of one or more lines starting with a tab character,
# and the word "at" followed by a space. Initially we get rid of stuff associated with
# SystemUtil stacktrace and Assert, because we can get that from the error context, it
# doesn't give any new information. We then protect the first stack frame that remains
# from being removed, because for things like NPE it is the most important stack frame.
# We then start removing stuff that heuristically we have found to be distracting and
# rarely helpful. We remove almost all of the AribaWeb and ariba ui related stack frames.
# We remove the highest frames at the end of the stacktrace that come from various
# infrastructures like Apache, ScheduledTask, servletAdapter, etc. We remove most fields
# associated with making reflective calls and transitioning from Java to JavaScript to
# Java. We get rid of repeated frames for a given method name, most common when there are
# multiple signatures implemented by calling deeper and deeper signatures. And so forth.
# The starting point for this method was the Java code in SystemUtil stackTraceCodePath.

sub simplifyStackTrace ($)
{
    my ($st) = @_;

    # Discard everything through last SystemUtil.stackTrace frame
    $st =~ s%^.*\tat ariba\.util\.core\.SystemUtil\.stackTrace.*?\n%%gs;

    # Discard everything through last Assert.that frame
    $st =~ s%^.*\tat ariba\.util\.core\.Assert\.that.*?\n%%gs;

    # Protect the first line (frame) of the stack trace from this point on...
    my $firstLine = "";
    if ($st =~ s|^(.*?\n)||) {
        $firstLine = $1;
        my $firstDebug = $firstLine;

        $firstDebug =~ s/\s+$//;
    }

    # Discard everything starting with first servletadapter stack frame after first line, boring.
    # It is never interesting to see the internals of servlet dispatching.
    $st =~ s%\tat ariba\.ui\.servletadaptor\..*$%%gs;

    # Discard everything starting with first rpc.server stack frame after first line, boring.
    $st =~ s%\tat ariba\.rpc\.server\..*$%%gs;

    # Discard everything starting with first ScheduledTask.run stack frame after first line, boring.
    $st =~ s%\tat ariba\.util\.scheduler\.ScheduledTask\.run.*$%%gs;

    # Discard java.lang.Thread.run frame.
    $st =~ s%\tat java\.lang\.Thread\.run.*?\n%%g;

    # Protect AWKeyPathBinding from removal, good clue of AWL binding code path.
    $st =~ s%ariba\.ui\.aribaweb\.core\.AWKeyPathBinding%ariba\.UI\.aribaweb\.core\.AWKeyPathBinding%g;

    # Elide all other contiguous ariba.ui stack frames, only aribaweb developers can
    # get much from them, and there are often hundreds of them.  Focus on app frames.
    $st =~ s%(\tat ariba\.ui\..*?\n)+%\t...\n%g;

    # Elide all fieldsui ARPPage frames, don't really help much.
    $st =~ s%\tat ariba\.htmlui\.fieldsui\.ARPPage\..*?\n%\t...\n%g;

    # Restore protected ariba.ui... stack frames.
    $st =~ s%ariba\.UI\.%ariba\.ui\.%g;

    # Elide seven stack frame block associated with reflexive method invokation under
    # FieldValue_Object.getFieldValue.
    $st =~ s%(\tat (sun\.reflect\.|java\.lang\.reflect\.|ariba\.util\.fieldvalue\.ReflectionMethodGetter\.|ariba\.util\.fieldvalue\.FieldPath\.getFieldValue|ariba\.util\.fieldvalue\.FieldValue_Object\.).*?\n)+%\t...\n%gm ;

    # Elide all contiguous javascript frames until last one, mozilla and ariba.
    $st =~ s%(\tat org\.mozilla\.javascript\..*?\n)(?:\tat (?:org\.mozilla|ariba\.util)\.javascript\..*?\n)+(\tat ariba\.util\.javascript\..*?\n)%\t...\n$2%g;

    # Restore the protected first line.
    $st = "$firstLine$st";

    # ***** Final cleanups ***** 

    # Keep only the first of repeated calls to the same method path, maybe
    # interleaved with ellipsis.
    $st =~ s%(\tat .*?)\((.*?):(\d+)\)\s*\n(?:(?:\t\.\.\.\s*\n)*\1\(\2:\d+\)\s*\n)+%$1($2:$3)\n\t...\n%g;

    # If we put in two or more successive ellipsises, compress to one.
    $st =~ s%(\t\.\.\.\s*\n){2,}%\t...\n%g;

    # Get rid of dangling ellipsis at the beginning.
    $st =~ s%^\t\.\.\.\s*\n%%g;

    # Get rid of dangling ellipsis at the end.
    $st =~ s%\t\.\.\.\s*\n\s*$%%g;

    # Get rid of blank lines.
    $st =~ s%\n\s*\n%\n%g;

    # Move ellipsis ... to the end of preceding frame line for final format.
    $st =~ s%(\s*at .*?)\s*\n\t\.\.\.\s*\n%$1 ...\n%g;

    return $st;                         
}

# ........................................................................................
# Returns String SQL buffer dump from the log with the SQL query, bindings, and AQL query
# each truncated to no more than 500 characters. Intended for use in a regex substitution
# with expression evaluation.

sub truncateSQLBuffer ($$$$$$$)
{
    my ($sqlBufLit, $sqlText, $bindLit, $bindText, $procLit, $aqlText, $nextLit) = @_;
    $sqlText = truncateSQLText($sqlText, 500);
    $bindText = truncateSQLText($bindText, 500);
    $aqlText = truncateSQLText($aqlText, 500);
    return sprintf("%s%s%s%s%s%s%s", $sqlBufLit, $sqlText, $bindLit, $bindText, $procLit, 
                   $aqlText, $nextLit);
}

# ........................................................................................
# Returns the given text after replacing all newlines and any whitespace on either side of
# them with a single space, and then truncating to the first $limit chars if it is over
# the limit. Trailing whitespace is removed and ellipsis are added if truncation is done.

sub truncateSQLText ($$)
{
    my ($text, $limit) = @_;
    $text =~ s|\s*\n\s*| |g;
    my $len = length($text);
    if ($len > $limit) {
        $text = substr($text, 0, $limit);
        $text =~ s|\s+$||;
        $text .= "...";
    }
    return $text;
}

# ........................................................................................
# Returns the given $lines with all lines from the Garbage Collector removed, both full
# and incremental GC lines. These can appear in the middle of other log lines, so it is
# important to remove them early, and they are not helpful for finding root causes of
# errors.

sub removeLinesFromGC ($)
{
    my ($lines) = @_;
    $lines =~ s|^\d+\.\d+:\s+\[(Full\s+)?GC\s+.*?\]\s*\n||gm;
    return $lines;
}

# ........................................................................................
# Returns the given $lines with all "Log Id: number" lines removed, because they don't
# help with getting to root causes, and keeping the number would prevent unification,
# since it is different for each instance.

sub removeLogId ($)
{
    my ($lines) = @_;
    $lines =~ s|^Log Id:\s+\d+\s*\n||gm;
    return $lines;
}

# ........................................................................................
# Returns the given $lines with the gigantic Thread state block of lines removed. It works
# to remove everything starting with the line "Thread: whatever {", continuing with lines
# that have leading whitespace, and ending with a line that has no leading whitespace
# matching "} whatever". The Thread state prevents unification and is almost never helpful
# in understanding an error and its root causes.

sub removeThreadState ($)
{
    my ($lines) = @_;
    $lines =~ s|^Thread:\s+.*?\s+{\s*\n(?:\s+.*?\n)+}.*?\n||gm;
    return $lines;
}

# ========================================================================================
# COMMAND LINE OPTION HANDLING.
# ----------------------------------------------------------------------------------------

# ........................................................................................
# Process the -for, -include, and -exclude options. This method is responsible for
# validating the -for option and loading the correct set of IDs for each -for option 
# value, for calling helper methods to actually process the option or for text, and for
# making sure that at least one ID will be included or excluded via the options or 
# defaulting. If none of the three options is given, it defaults to -for 1-Primary.

sub setupForIncludeExclude ()
{
    if (!$forOption && !$includeOption && !$excludeOption) {
    $forOption = "1-Primary";
    }
    if ($forOption eq "1-Primary") {
    setupIncludeExcludeText(\%includeIDSet, $for1PrimaryInclude, 1);
    }
    elsif ($forOption eq "2-Secondary") {
    setupIncludeExcludeText(\%includeIDSet, $for2SecondaryInclude, 1);
    }
    elsif ($forOption eq "3-Tertiary") {
    setupIncludeExcludeText(\%excludeIDSet, $for1PrimaryInclude, 1);
    setupIncludeExcludeText(\%excludeIDSet, $for2SecondaryInclude, 1);
    setupIncludeExcludeText(\%excludeIDSet, $for3TertiaryExclude, 1);
    }
    elsif ($forOption) {
        print STDERR "Error: -for $forOption unrecognized; expected 1-Primary, 2-Secondary, or 3-Tertiary.\n";
        usage();
    }
    else {
        $forOption = "4-Custom";
    }
    
    if ($includeOption) {
    # If user gives -include option and we don't already have an exclude set from a
    # -for option, add the IDs to the include ID set.
    if (!%excludeIDSet) {
        setupIncludeExcludeOption(%includeIDSet, "-include", $includeOption, 1);
    }
    # If user gives -include option and we already have an exclude set from a -for
    # option, remove the IDs from the exclude ID set, on the assumption that the
    # script user wants to modify the behavior of the given -for special-case.
    else {
        setupIncludeExcludeOption(%excludeIDSet, "-include", $includeOption, 0);
    }
    }
    if ($excludeOption) {
    # If user gives -exclude option and we don't already have an include set from a
    # -for option, add the IDs to the exclude ID set.
    if (!%includeIDSet) {
        setupIncludeExcludeOption(%excludeIDSet, "-exclude", $excludeOption, 1);
    }
    # If user gives -exclude option and we already have an include set from a -for
    # option or a -include option, remove the IDs to the include ID set, on the
    # assumption that the script user wants to modify the behavior of the given -for
    # special-case, or is just messing with us by giving both -include and -exclude
    # but no -for option.
    else {
        setupIncludeExcludeOption(%includeIDSet, "-exclude", $excludeOption, 0);
    }
    }
    if (!%includeIDSet && !%excludeIDSet) {
        print STDERR "Error: At least one ID must be specified via -for, -include, or -exclude.\n";
        usage();
    }
}

# ........................................................................................
# Processes -include or -exclude value, given reference to the corresponding ID map to 
# true values that is treated as a set of IDs, and given the $optionName for error 
# messages, and the $optionValue to process. This method handles the value starting with
# @ to give a filename that should be read for the values, in cases where there are a lot
# of IDs to be specified.

sub setupIncludeExcludeOption ($$$$)
{
    my ($IDSetRef, $optionName, $optionValue, $setValue) = @_;
    my $lineNum = 0;

    if ($optionValue =~ m|^\@(.*)$|) {
        my $filePath = $1;

        open(OPTIONFILE, $filePath) || die "Error: cannot open $filePath: $!\n";
        while (my $line = <OPTIONFILE>) {
            $lineNum++;
        setupIncludeExcludeText($IDSetRef, $line, $setValue, $optionName, $optionValue, $lineNum);
        }
        close(OPTIONFILE) || die "Error: cannot close $filePath: $!\n";
    }
    else {
        setupIncludeExcludeText($IDSetRef, $optionValue, $setValue, $optionName, $optionValue);
    }
}

# ........................................................................................
# Strips whitespace, commas, and vertical bars from the beginning and end of $text, and
# splits it into tokens separated by one or more whitespace, commas, and/or vertical bars.
# Each token should be an ID number and will be put in the given $IDSetRef map with the
# given $setValue. If any tokens are not ID numbers, we print an error message and usage
# message and terminate. Can be passed 3, 5, or 6 parameters.

sub setupIncludeExcludeText
{
    my ($IDSetRef, $text, $setValue, $optionName, $optionValue, $lineNum) = @_;
    $text =~ s/^[\s\,\|]+//;
    $text =~ s/[\s\,\|]+$//;
    my @tokens = split(/[\s\,\|]+/, $text);
    foreach my $token (@tokens) {
        if ($token =~ m|^ID\d+$|) {
            $$IDSetRef{$token} = $setValue;
        }
        elsif (!undef($lineNum) && $lineNum) {
            print STDERR "Error: expected IDs, not \"$token\" on line $lineNum of $optionName $optionValue\n";
            usage();
        }
        elsif (!undef($optionName) && $optionName) {
            print STDERR "Error: expected IDs, not \"$token\" in $optionName \"$optionValue\"\n";
            usage();
        }
        else {
            print STDERR "Error: expected IDs, not \"$token\" in -for $forOption value.\n";
            usage();
        }
    }
}

# ........................................................................................
# If an -output option was not passed on the command line, check the ARIBA_WWW_REVIEW_ROOT
# environment variable. If its value matches /$userName/public_doc, we can assume it is a
# valid nashome path used with gnu htmlreview, and we compose a path that will be
# accessible via http://nashome.ariba.com/~$userName/logs, and make that the default value
# of the -output option. If there is no -output option and no ARIBA_WWW_REVIEW_ROOT value
# that matches the pattern, give a usage error. We create the output folder if it doesn't
# exist, and give an error if it exists and is not a folder.

sub validateOutputFolder ()
{
    if (!$output) {
        my $reviewRoot = $ENV{ARIBA_WWW_REVIEW_ROOT};
        if (!$reviewRoot) {
            print STDERR "Error: either -output needs to be given, or ARIBA_WWW_REVIEW_ROOT needs to be defined.\n";
            usage();
        }
        $reviewRoot =~ s|\\|/|;
        if ($reviewRoot =~ m|^(.*)/(\w+)/(public_doc)|) {
            my $userName = $2;
            my $publicPath = "$1/$2/$3";
            if (! -d $publicPath) {
                print STDERR "Error: $publicPath from ARIBA_WWW_REVIEW_ROOT is not a directory.\n";
                usage();
            }
            $output = "$publicPath/logs";
            $outputUrl = "http://nashome.ariba.com/~$userName/logs";
        }
        else {
            print STDERR "Error: $reviewRoot from ARIBA_WWW_REVIEW_ROOT does not contain \$userName/public_doc.\n";
            usage();
        }
    }
    if (! -e $output) {
        mkdir $output || die "Error: $output does not exist and cannot be created: $!\n";
    }
    if (! -d $output) {
        print STDERR "Error: $output must be a directory, but is not.\n";
        usage();
    }
}

# ========================================================================================
# OUTPUT FORMATTING of initial index.html web page.
# ----------------------------------------------------------------------------------------

# ........................................................................................
# Prints initial boilerplate for the top level page, through the table headings.
# OUTINDEX must have been opened already, and calls dieOutIndex if there is an IO error.

sub outputIndexHtmlBegin ()
{
    my $prodBuildLabel = getProductBuildLabel();
    my $minShortDate = getMinShortTimestamp();
    my $maxShortDate = getMaxShortTimestamp();
    my $dateRange = "$minShortDate-$maxShortDate";

    print OUTINDEX "<html>\n" || dieOutIndex();
    print OUTINDEX "<body>\n" || dieOutIndex();
    print OUTINDEX "<h1>$forOption Log Errors in $prodBuildLabel</h1>\n" || dieOutIndex();
    print OUTINDEX "<h2>$dateRange</h2>\n" || dieOutIndex();
    print OUTINDEX "<table border=\"1\">\n" || dieOutIndex();
    print OUTINDEX "<tr><th>Type</th><th>Count</th><th>Percentage</th></tr>\n" || dieOutIndex();
}

# ........................................................................................
# Prints row in the top level table for a given error type classification, count of
# occurrences of that type, and total count of reported errors in the logs.
# Generates a relative hyperlink to a folder that it will generate by calling
# populateFolderForType in a later section.
# OUTINDEX must have been opened already, and calls dieOutIndex if there is an IO error.

sub outputIndexHtmlType ($$$)
{
    my ($typeName, $count, $totalCount) = @_;
    my $typeListRef = getOrCreateTypeListRef($typeName);
    my $percent = "";
    if ($totalCount > 0) {
        $percent = sprintf("%.0f", (100.0 * $count) / $totalCount);
    }

    my $relativeUrl = "Type-$typeName";
    my $typeFolder = "$output/$relativeUrl";

    print OUTINDEX "<tr><td><a href=\"$relativeUrl/index.html\">$typeName</a></td>" || dieOutIndex();
    print OUTINDEX "<td align=\"right\">$count</td><td align=\"right\">$percent\%</td></tr>\n" || dieOutIndex();

    populateFolderForType($typeName, $typeFolder, $count);
}

# ........................................................................................
# Prints final boilerplate for the top level page, printing a Totals row and closing all
# open HTML entities.
# OUTINDEX must have been opened already, and calls dieOutIndex if there is an IO error.

sub outputIndexHtmlEnd ($)
{
    my ($totalCount) = @_;

    print OUTINDEX "<tr><td>Totals</td><td align=\"right\">$totalCount</td><td align=\"right\">100\%</td></tr>\n" || dieOutIndex();
    print OUTINDEX "</table>\n" || dieOutIndex();

    # Print information about the include/exclude configuration at the bottom of the
    # initial index.html page.

    if (%includeIDSet) {
    outputIndexHtmlIDSet(\%includeIDSet, "Included IDs");
    }
    if (%excludeIDSet) {
    outputIndexHtmlIDSet(\%excludeIDSet, "Excluded IDs");
    }

    print OUTINDEX "</body>\n" || dieOutIndex();
    print OUTINDEX "</html>\n" || dieOutIndex();
}

# ........................................................................................
# Prints section starting with h2 $headline, that lists all the IDs in $IDSetRef in sorted
# order, separated by comma-space, with a line break every 100 characters or so, to keep
# the lines from getting too long. Puts this fine print in the smallest easy font size.
# OUTINDEX must have been opened already, and calls dieOutIndex if there is an IO error.

sub outputIndexHtmlIDSet ($$)
{
    my ($IDSetRef, $headline) = @_;

    print OUTINDEX "<h2>$headline</h2>\n" || dieOutIndex();
    print OUTINDEX "<font size=\"1\">\n" || dieOutIndex();

    my $line = "";
    my $needsLeadingComma = 0;
    foreach my $id (sort(keys(%includeIDSet))) {
    $line .= ", " if ($needsLeadingComma);
    $needsLeadingComma = 1;
    if (length($line) > 100) {
        print OUTINDEX "$line\n" || dieOutIndex();
        $line = "";
    }
    $line .= $id;
    }
    if ($line) {
    print OUTINDEX "$line\n" || dieOutIndex();
    }
    print OUTINDEX "\n</font>\n" || dieOutIndex();
}

# ========================================================================================
# OUTPUT FORMATTING of second level type folder and its index.html page.
# ----------------------------------------------------------------------------------------

# ........................................................................................
# Creates or reuses folder for reporting on given type of error.  Creates fresh index.html
# file in the folder, and formats output about each different unified occurrence of the
# error. Ultimately it calls method at third level for each unified occurrence of $lines
# to output a third level webpage of unfiltered log lines and citations in the logs where
# it occurred, so analyst can go back to the original log material in investigating the
# error.

sub populateFolderForType ($$$)
{
    my ($typeName, $typeFolder, $typeCount) = @_;
    if (! -e $typeFolder) {
        mkdir $typeFolder || die "Error: $typeFolder does not exist and cannot be created: $!\n";
    }
    if (! -d $typeFolder) {
        print STDERR "Error: $typeFolder must be a directory, but is not.\n";
        usage();
    }
    $typeIndexHtml = "$typeFolder/index.html";
    unlink($typeIndexHtml);
    open(TYPEINDEX, ">$typeIndexHtml") || die "Error: cannot create $typeIndexHtml: $!\n";

    typeIndexHtmlBegin($typeName);

    my $typeListRef = getOrCreateTypeListRef($typeName);
    my @linesPayloads = ();
    foreach my $lines (@$typeListRef) {
        my $citationListRef = getOrCreateCitationListRef($lines);
        my $citationCount = @$citationListRef;
        my $linesPayload = sprintf("%09d:%s", $citationCount, $lines);
        push(@linesPayloads, $linesPayload);
    }

    foreach my $linesPayload (reverse(sort(@linesPayloads))) {
        my ($count, $lines) = split(/:/, $linesPayload, 2);
        $count =~ s/^0+//;
        typeIndexHtmlLines($lines, $count, $typeCount, $typeName, $typeFolder);
    }

    typeIndexHtmlEnd($typeCount);

    close(TYPEINDEX) || dieTypeIndex();
}

# ........................................................................................
# Prints initial boilerplate for the second level type page, through the table headings.
# TYPEINDEX must have been opened already, and calls dieTypeIndex if there is an IO error.

sub typeIndexHtmlBegin ($)
{
    my ($typeName) = @_;
    print TYPEINDEX "<html>\n" || dieTypeIndex();
    print TYPEINDEX "<body>\n" || dieTypeIndex();
    print TYPEINDEX "<h1>Unhandled UI Exceptions: $typeName</h1>\n" || dieTypeIndex();
    print TYPEINDEX "<table border=\"1\">\n" || dieTypeIndex();
    print TYPEINDEX "<tr><th width=\"65%\">Log Context</th><th align=\"right\">Count</th><th align=\"right\">\%</th><th>Citations</th></tr>\n" || dieTypeIndex();
}

# ........................................................................................
# Prints row in the second level type table for a given $lines unified occurrence, given
# the instance $count for the lines, the total $typeCount for the containing type which is
# used to calculate a displayed percentage, the $typeName and the $typeFolder, which are
# used in printed page header and in passing to the third level page generation.
# Generates a relative hyperlink to a page that it will generate by calling
# generateCitationPage in a later section.
# TYPEINDEX must have been opened already, and calls dieTypeIndex if there is an IO error.

sub typeIndexHtmlLines ($$$$)
{
    my ($lines, $count, $typeCount, $typeName, $typeFolder) = @_;
    my $percent = "";
    if ($typeCount > 0) {
        $percent = sprintf("%.0f", (100.0 * $count) / $typeCount);
    }

    my $htmlLines = formatLinesInHtml($lines);

    my $citationListRef = getOrCreateCitationListRef($lines);
    my $citationRelativeUrl = generateCitationPage($lines, $htmlLines, $citationListRef, $count, $percent, $typeName, $typeFolder);

    print TYPEINDEX "<tr><td width=\"65%\"><font size=\"1\">$htmlLines</font></td>" || dieTypeIndex();
    print TYPEINDEX "<td align=\"right\">$count</td><td align=\"right\">$percent\%</td>" || dieTypeIndex();
    print TYPEINDEX "<td><a href=\"$citationRelativeUrl\">citations</a></td></tr>\n" || dieTypeIndex();
}

# ........................................................................................
# Prints final boilerplate for the second level type page, printing a Totals row and 
# closing all open HTML entities.
# TYPEINDEX must have been opened already, and calls dieTypeIndex if there is an IO error.

sub typeIndexHtmlEnd ($)
{
    my ($typeCount) = @_;

    print TYPEINDEX "<tr><td>Totals</td><td align=\"right\">$typeCount</td><td align=\"right\">100\%</td></tr>\n" || dieTypeIndex();
    print TYPEINDEX "</table>\n" || dieTypeIndex();
    print TYPEINDEX "</body>\n" || dieTypeIndex();
    print TYPEINDEX "</html>\n" || dieTypeIndex();
}

# ========================================================================================
# OUTPUT FORMATTING of 3rd level Citation-nnnnnn.html page in the 2nd level type folder.
# ----------------------------------------------------------------------------------------

# ........................................................................................
# Creates a Citations-nnnnnn.html page in the $typeFolder for the given $lines with the 
# the given $count and $percent from the second level table row for these $lines. Gets
# passed the $htmlLines so it can render the table row again as a visual link with the
# second level table. Also gets the $typeName and $typeFolder for use in the page header
# and in creating the page.  Returns the relative URL string for the citation page so it
# can be hyperlinked in the second level page row for these $lines. Citation pages are
# numbered across the entire generation starting with 000001.

sub generateCitationPage ($$$$$)
{
    my ($lines, $htmlLines, $citationListRef, $count, $percent, $typeName, $typeFolder) = @_;

    $citationPageCounter++;
    my $citationRelativeUrl = sprintf("Citations-%06d.html", $citationPageCounter);

    $citationFile = "$typeFolder/$citationRelativeUrl";
    
    unlink($citationFile);
    open(CITEFILE, ">$citationFile") || die "Error: cannot create $citationFile: $!\n";

    print CITEFILE "<html>\n" || dieTypeIndex();
    print CITEFILE "<body>\n" || dieTypeIndex();
    print CITEFILE "<h1>Log file citations for one context of $typeName</h1>\n" || dieTypeIndex();
    print CITEFILE "<table border=\"1\">\n" || dieTypeIndex();
    print CITEFILE "<tr><th width=\"65%\">Log Context</th><th align=\"right\">Count</th><th align=\"right\">\%</th></tr>\n" || dieTypeIndex();

    print CITEFILE "<tr><td><font size=\"1\">$htmlLines</font></td>" || dieTypeIndex();
    print CITEFILE "<td align=\"right\">$count</td><td align=\"right\">$percent\%</td></tr>\n" || dieTypeIndex();
    print CITEFILE "</table>\n" || dieTypeIndex();

    my $unfiltered = $unfilteredLines{$lines};
    my $unfilteredInHtml = formatUnfilteredInHtml($unfiltered);

    print CITEFILE "<h2>First Citation Unfiltered Log Contents</h2>\n" || dieTypeIndex();
    print CITEFILE "<font size=\"1\">\n" || dieTypeIndex();
    print CITEFILE "<pre>\n" || dieTypeIndex();
    print CITEFILE $unfilteredInHtml || dieTypeIndex();
    print CITEFILE "</pre>\n" || dieTypeIndex();
    print CITEFILE "</font>\n" || dieTypeIndex();

    print CITEFILE "<h2>Complete List of Occurrence Citations</h2>\n" || dieTypeIndex();
    print CITEFILE "<br/>\n" || dieTypeIndex();
    print CITEFILE "<font size=\"1\">\n" || dieTypeIndex();
    foreach my $citation (@$citationListRef) {
        print CITEFILE "<br/>$citation\n" || dieTypeIndex();
    }
    print CITEFILE "</font>\n" || dieTypeIndex();

    print CITEFILE "</body>\n" || dieTypeIndex();
    print CITEFILE "</html>\n" || dieTypeIndex();

    close(CITEFILE) || dieCiteFile();
    return $citationRelativeUrl;
}

# ========================================================================================
# OUTPUT FORMATTING utility methods.
# ----------------------------------------------------------------------------------------

# ........................................................................................
# Returns numeric count for citations for the given $typeName, by summing all the lists
# associated with all the lines for the given $typeName.

sub getTypeCitationCount ($)
{
    my ($typeName) = @_;
    my $count = 0;

    my $typeListRef = getOrCreateTypeListRef($typeName);
    foreach my $lines (@$typeListRef) {
        my $citationListRef = getOrCreateCitationListRef($lines);
        $count += @$citationListRef;
    }
    return $count;
}

# ........................................................................................
# Returns given text with all "&", "<", and ">" chars replaced by equivalent HTML entities
# so they will be rendered as themselves in HTML, rather than treated as markup. It also
# introduces explicit HTML <br/> line breaks before and after lines containing tab-at
# (from stack traces, "Caused by:", and "WARNING:", followed by a space and the rest of
# line, and cleans the result to make sure there are no <br/> at the beginning or end of
# the text, and reduces multiple <br/> to a single one so blank lines are not introduced.
# It is expected that the resulting text will be rendered via normal (not <pre>) HTML
# rendering in which newlines are ignored and text is wrapped as needed.

sub formatLinesInHtml ($)
{
    my ($text) = @_;
    $text = insureFrequentWordBreaks($text, 1);
    $text =~ s|([&<>])|getHtmlCharEntity($1)|ge;
    $text =~ s%((?:\tat|Caused by:|WARNING:) .*?\n)%<br/>$1<br/>%g;
    $text =~ s%<br/>(?:<br/>)+%<br/>%g;
    $text =~ s%^<br/>%%g;
    $text =~ s%<br/>$%%g;
    return $text;
}

# ........................................................................................
# Returns $text with spaces inserted as needed so that there are no more than 100 chars in
# sequence without an intervening space. $text may contain whitespace already, and this
# method's responsibility is to find the subsequences of text that contain no whitespace,
# and pass them to a helper method for processing.

sub insureFrequentWordBreaks ($$)
{
    my ($text, $level) = @_;
    $text =~ s|(\S+)|fixTextWithoutWordBreakIfNeeded($1,$level)|ge;
    return $text;
}

# ........................................................................................
# Returns $text with spaces inserted as needed so that there are no more than 100 chars in
# sequence without an intervening space, assuming that there is no whitespace in $text
# when called.  It tries to repeatedly pieces near the middle until all the pieces are
# within the limit.  It tries to add a space after a non-word char near the middle, but
# if it can't find a place to do that, it just adds a space right in the middle.
# Recursively calls insureFrequentWordBreaks after each time it inserts a space, to deal
# with the fragments.

$::MaxWordLength = 100;

sub fixTextWithoutWordBreakIfNeeded ($$)
{
    my ($text, $level) = @_;
    my $textLength = length($text);
    if ($textLength > $::MaxWordLength) {
        my $origText = $text;
        my $afterFirst  = sprintf("%d", $textLength * (1 / 4));
        my $afterSecond = sprintf("%d", $textLength * (2 / 4));
        my $afterThird  = sprintf("%d", $textLength * (3 / 4));

        my $firstQuarter  = substr($text, 0, $afterFirst);
        my $secondQuarter = substr($text, $afterFirst, $afterSecond - $afterFirst);
        my $thirdQuarter  = substr($text, $afterSecond, $afterThird - $afterSecond);
        my $fourthQuarter = substr($text, $afterThird);

        # We want to add a space near the middle of this long sequence of non-whitespace 
        # chars. We first try to add it after the last non-word char in the 2nd quarter
        # of the string, then we try to add it after the first non-word char in the 
        # 3rd quarter. If there is no non-word char in the 2nd or 3rd quarter, we just
        # insert a space at the mid-point of the text, and call our caller recursively
        # to further split in log N levels of calls as needed.

        if ($thirdQuarter  =~ s|(\W)|$1 | or
            $secondQuarter =~ s|(\W)(\w*)$|$1 $2|) {
            $text = "$firstQuarter$secondQuarter$thirdQuarter$fourthQuarter";
        }
        else {
            $text = substr($text, 0, $afterSecond) . " " . substr($text, $afterSecond);
        }
        $text = insureFrequentWordBreaks($text, $level + 1);
    }
    return $text;
}

# ........................................................................................
# Returns given text with all "&", "<", and ">" chars replaced by equivalent HTML entities
# so they will be rendered as themselves in HTML, rather than treated as markup. No other
# formatting of the text is done. It is expected that the resulting text will be rendered
# in an HTML <pre> block.

sub formatUnfilteredInHtml ($)
{
    my ($text) = @_;
    # Advantage of this approach is that the text is processed in one pass quickly;
    # the method is only called if one of the chars is found, and we don't rescan the
    # replacement text that will generally contain one of the chars we are escaping.
    $text =~ s|([&<>])|getHtmlCharEntity($1)|ge;
    return $text;
}

# ........................................................................................
# Returns HTML character entity for the HTML characters that have to be escaped to appear
# as themselves in HTML rendering: ampersand, less-than, and greater-than, given a one
# character string value. If the given $charText is "&", "<", or ">" it is replaced by
# "&amp;", "&lt;", or "&gt;", and any other value is returned unchanged.  This method is
# used in the replacement side of a regex substititution with expression evaluation.

sub getHtmlCharEntity ($)
{
    my ($charText) = @_;
    if ($charText eq "&") {
        return "&amp;";
    }
    elsif ($charText eq "<") {
        return "&lt;";
    }
    elsif ($charText eq ">") {
        return "&gt;";
    }
    else {
        # This path is not used currently, so just return $charText as default.
        return $charText;
    }
}

# ........................................................................................
# Throws error message about write or close error on $citationFile. Intended to be used
# as alternative if print or close call fails, to report IO errors.

sub dieCiteFile ()
{
    die "Error: Can't write to $citationFile: $!\n";
}

# ........................................................................................
# Throws error message about write or close error on $outputIndexHtml. Intended to be used
# as alternative if print or close call fails, to report IO errors.

sub dieOutIndex ()
{
    die "Error: Can't write to $outputIndexHtml: $!\n";
}

# ........................................................................................
# Throws error message about write or close error on $typeIndexHtml. Intended to be used
# as alternative if print or close call fails, to report IO errors.

sub dieTypeIndex ()
{
    die "Error: Can't write to $typeIndexHtml: $!\n";
}

# ========================================================================================
# Managing global mappings from Type to Lines, and from Lines to Citations.
# ----------------------------------------------------------------------------------------

%::commonTypes = ();
%::commonCauses = ();

# ........................................................................................
# Returns reference to List of String "lines" for the given type name, creating one and
# entering it into the global map if it hasn't been accessed before.

sub getOrCreateTypeListRef ($)
{
    my ($typeName) = @_;
    my $typeListRef = $::commonTypes{$typeName};
    if (!$typeListRef) {
        $typeListRef = [];
        $::commonTypes{$typeName} = $typeListRef;
    }
    return $typeListRef;
}

# ........................................................................................
# Returns list of all $typeName that had getOrCreateTypeListRef called for them.

sub getListOfAllTypeNames ()
{
    return keys(%::commonTypes);
}

# ........................................................................................
# Returns reference to List of String "citation" for the given string lines, creating one
# and entering it into the global map if it hasn't been accessed before.

sub getOrCreateCitationListRef ($)
{
    my ($lines) = @_;
    my $citationListRef = $::commonCauses{$lines};
    if (!$citationListRef) {
        $citationListRef = [];
        $::commonCauses{$lines} = $citationListRef;
    }
    return $citationListRef;
}

# ........................................................................................
# Returns list of all $lines that had getOrCreateCitationsListRef called for them.

sub getListOfAllLines ()
{
    return keys(%::commonCauses);
}

# ========================================================================================
# Product Build Label Handling - Global Variables and Methods.
# ----------------------------------------------------------------------------------------
 
%::minBuildLabel = ();
%::maxBuildLabel = ();

# ........................................................................................
# This method is called for each log line, and if the line is one of the Build lines
# logged when our app server is starting up, it extracts the build label root and the
# build label number. For each build label root that appears in the logs, it remembers the
# minimum and maximum build label numbers. Normally there will only be one build label
# root and one build label number, but there can be a range of numbers if one or more
# rolling upgrades was done during the logging period, and there can be more than one
# label root if the logging interval includes a major release, or includes both upstream
# and downstream logs.

sub rememberProductBuildInfo ($)
{
    my ($line) = @_;

    if ($line =~ m|^\s+Build:\s+(.*?)\-(\d+)\s*$|) {
        my ($labelRoot, $labelNumber) = ($1, $2);

        my $minLabelNumber = $::minBuildLabel{$labelRoot};
        if (!$minLabelNumber || $labelNumber < $minLabelNumber) {
            $::minBuildLabel{$labelRoot} = $labelNumber;
        }

        my $maxLabelNumber = $::maxBuildLabel{$labelRoot};
        if (!$maxLabelNumber || $labelNumber > $maxLabelNumber) {
            $::maxBuildLabel{$labelRoot} = $labelNumber;
        }
    }
}

# ........................................................................................
# Returns string build label tag based on all the build labels we found in the logs,
# suitable for composing the log report output folder name. In the simplest and most
# common case, if there is just one build label in the logs, it returns that build label,
# for example "BigBend-1354". If a range of numbers is present, it returns the build label
# extended to the range, for example "BigBend-1354-1355". If multiple build label roots
# are present, it joins what it gets for each root in sorted order, separated by hyphens,
# for example "BigBend-1354-1355-SSPHawk-1368". If no build labels were seen in the logs,
# for example if the log interval is so short that no node was restarted, it returns
# "Unknown-0".

sub getProductBuildLabel ()
{
    my $buildTag = "";
    foreach my $labelRoot (sort(keys(%::minBuildLabel))) {
        my $minNumber = $::minBuildLabel{$labelRoot};
        my $maxNumber = $::maxBuildLabel{$labelRoot};
        
        my $buildLabel = "$labelRoot-$minNumber";
        $buildLabel .= "-$maxNumber" if ($minNumber < $maxNumber);
        $buildTag .= "-" if ($buildTag);
        $buildTag .= $buildLabel;
    }
    $buildTag = "Unknown-0" if (!$buildTag);
    return $buildTag;
}

# ========================================================================================
# Timestamp Handling - Constants, Global Variables, and Methods.
# ----------------------------------------------------------------------------------------

%::monthNameToNumber = ('Jan',1, 'Feb',2, 'Mar',3, 'Apr',4,  'May',5,  'Jun',6, 
                        'Jul',7, 'Aug',8, 'Sep',9, 'Oct',10, 'Nov',11, 'Dec',12);

$::minTime = 0;
$::minTimestamp = "";
$::maxTime = 0;
$::maxTimestamp = "";

# ........................................................................................
# Returns string timestamp in log file format if one is found at the beginning of the
# given line. Otherwise returns the empty string. This method is also used simply to
# determine whether a given line is a log timestamp line, rather than a following line
# between timestamp lines.

sub getTimestamp ($)
{
    my ($line) = @_;
    if ($line =~ m|^([A-Za-z]{3}\s+[A-Za-z]{3}\s+\d\d\s+\d\d:\d\d:\d\d\s+[A-Za-z]{2,}\s+2\d\d\d)\s+\(|) {
        return $1;
    }
    return "";
}

# ........................................................................................
# Returns string holding a shortened timestamp suitable for use in composing a folder name
# for the log report output, given a string log timestamp.  It consists of the 3 letter
# weekday name, the 3 letter month name, the day of the month without leading zero, a
# period as separator, and the hour followed by am or pm, without leading zero.

sub getShortTimestamp ($)
{
    my ($timestamp) = @_;
    if ($timestamp =~ m|^([A-Za-z]{3})\s+([A-Za-z]{3})\s+(\d\d)\s+(\d\d):|) {
        my ($day3, $month3, $dayOfMonth,$hour) = ($1,$2,$3,$4);
        my $amPmHour = getAmPmHour($hour);
        return "$day3$month3$dayOfMonth.$amPmHour";
    }
    return "None";
}

# ........................................................................................
# This method takes a timestamp string from the log, cracks it into its parts, and
# constructs the equivalent internal numeric $time value
#

sub rememberMinMaxTimestamp ($)
{
    my ($timestamp) = @_;
    my $time = getTimeFromLogTimestamp($timestamp);
    if ($time) {
    if ($time < $::minTime || $::minTime == 0) {
            $::minTime = $time;
            $::minTimestamp = $timestamp;
        }
        if ($time > $::maxTime) {
            $::maxTime = $time;
            $::maxTimestamp = $timestamp;
        }
    }
}

# ........................................................................................
# Returns string holding shortened timestamp for the minimum timestamp in the logs.
# See the method getShortTimestamp for more details.

sub getMinShortTimestamp ()
{
    return getShortTimestamp($::minTimestamp);
}

# ........................................................................................
# Returns string holding shortened timestamp for the minimum timestamp in the logs.
# See the method getShortTimestamp for more details.

sub getMaxShortTimestamp ()
{
    return getShortTimestamp($::maxTimestamp);
}

# ........................................................................................
# Returns numeric time value corresponding to the given log timestamp string, or empty
# string value if the timestamp string cannot be parsed successfully.

sub getTimeFromLogTimestamp ($)
{
    my ($timestamp) = @_;
    my $time = '';
    if ($timestamp =~ m|^[A-Za-z]{3}\s+([A-Za-z]{3})\s+(\d\d)\s+(\d\d):(\d\d):(\d\d)\s+([A-Za-z]{2,})\s+(2\d\d\d)|) {
        my ($month3, $dayOfMonth, $hour, $min, $sec, $tzName, $year) = ($1,$2,$3,$4,$5,$6,$7);
        my $month0 = getMonthIndex($month3);
        my $year1900 = $year - 1900;
        $sec = trimLeadingZeroes($sec);
        $min = trimLeadingZeroes($min);
        $hour = trimLeadingZeroes($hour);
        $dayOfMonth = trimLeadingZeroes($dayOfMonth);
        $time = timelocal($sec, $min, $hour, $dayOfMonth, $month0, $year1900);
    }
    return $time;
}

# ........................................................................................
# Returns the given string value with leading zeroes stripped off.  If the string consists
# entirely of zeroes, it leaves one zero. We use this to make sure numeric strings padded
# with leading zeroes will convert to the correct numeric value, and not be 
# mis-interpreted as octal strings due to leading zero.

sub trimLeadingZeroes ($)
{
    my ($value) = @_;
    $value =~ s/^0+//;
    $value = "0" if $value eq "";
    return $value;
}

# ........................................................................................
# Returns numeric month offset starting with zero for Jan, for given month3, a three char
# string from the log timestamp identifying a particular month. Throws an error if the
# given month3 does not exactly match one of the twelve expected values.  We store a one
# based index in the map, to make it easy to detect when the month3 is not recognized.

sub getMonthIndex ($)
{
    my ($month3) = @_;
    my $monthNumber = $::monthNameToNumber{$month3};
    if (!$monthNumber) {
        die "Error: Unrecognized month=[$month3] in log timestamp.\n";
    }
    return $monthNumber - 1;
}

# ........................................................................................
# Returns string hour of day with am or pm suffix, when passed an hour between 0 and 23;
# gets rid of leading zero if it is present in the given hour.

sub getAmPmHour ($)
{
    my ($hour) = @_;
    if ($hour == 0) {
        return "12am";
    }
    elsif ($hour < 12) {
        return ($hour - 0) . "am";
    }
    elsif ($hour == 12) {
        return "12pm";
    }
    else {
        return ($hour - 12) . "pm";
    }
}

# ........................................................................................
# After everything has been declared, call the main method.
main();

# ========================================================================================
# End of Script.
# ----------------------------------------------------------------------------------------
