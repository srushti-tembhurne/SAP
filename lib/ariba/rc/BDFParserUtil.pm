package ariba::rc::BDFParserUtil;

use strict;
use warnings;
use File::Basename;
use File::Find;

my @files = ();

# Internal entry point (dead code?)
# Takes any folder as an input and traverse thru it
# to find all the bdf files in that and returns 
# the array containing the bdf path
#sub checkForBDFPath {
#   my $bdfPath = shift;
#   my @bdfFiles;
#   
#   _validateFilePath($bdfPath);
#
#   if($bdfPath =~ m/bdf$/) {
#      push(@bdfFiles, $bdfPath);
#   } 
#   else {
#      find(\&_findBDF,"$bdfPath"); 
#      @bdfFiles = @files;
#   }
#   return \@bdfFiles;
#}

# Internal entry point
# recursively parses for each file in $dir
#sub _findBDF {
#   if(/\.bdf$/) {
#      push (@files, $File::Find::name);
#   }
#}

# Internal entry point
# Exit if the file path is not valid
#sub _validateFilePath {
#    my $filePath = shift;
#    
#    unless (-e "$filePath") {
#       print "error : $filePath file path is not valid !\n";
#       exit (1);
#    }
#}


# Internal entry point
# Reads any bdf file and returns a hash based
# on various sections mentioned in that bdf file. 
sub _bdfParser {
    my $filePath = shift;
    my $sectionType = "";
    my $line;
    my @parsedLines = ();
    my %parsedBDFHash;

    open FILE ,"<$filePath" or die "Cannot open *.bdf file: $! \n";
    my @out = <FILE>;
    @out = grep(!/^\s*$/, @out); # weed out spaces

    close FILE;

    for (my $i=0; $i<=$#out; $i++){
        $line = $out[$i];    
        chomp($line);

        if ($line =~ /^\s*#*.*\[\s*bein:\s*(.*)\s*\]/io) {
            $sectionType = $1;
            next;
        }

        $line =~ s/\s*//;

        if ( $line !~ /^#/ ){
            push (@{$parsedBDFHash{$sectionType}} , $line);
        }
    }

    return (%parsedBDFHash);
}

# External entry point
# Returns all the compoennts which are mentioned in the bdf file
# under dependency section.
sub getDependencyFromBDF {
    my $bdfPath = shift;
    my %parsedLinesRef;
    my $lines;
    my @dependency;

    %parsedLinesRef = _bdfParser($bdfPath);

    my $tmp = $parsedLinesRef{'dependency-definition-section'};

# TODO This should parse the template and learn that the modname is the first line
    if (!$tmp) {
        return;
    }
    my @temp = @$tmp;
    
    for (my $i = 0; $i<=$#temp; $i++) {
        $lines = $temp[$i];
        chomp($lines);

        if($lines =~ m/\-\d*/ || $lines =~ m/latest/) {
            push (@dependency, $temp[$i-1]);
        }
    }

    return (\@dependency);
}

# External entry point
# Returns the name of the component after reading
# component.bdf file.
#
# Input: String path to component.bdf or product.bdf (relative or absolute)
# Returns the name of the component 
# 
sub getComponentNameFromBDF {
    my $bdfPath = shift ;
    my %parsedLineRef;
    my $lines;
    my $componentName;

    %parsedLineRef = _bdfParser($bdfPath);

    my $tmp = $parsedLineRef{'build-definition-section'};
    my @temp = @$tmp;

    for (my $i = 0; $i<=$#temp; $i++) {
        $lines = $temp[$i];
        chomp($lines);

# TODO This should parse the template and learn that the modname is the third line
        if($lines =~ /BUILD_BRANCH/ || $lines =~ /\/\/ariba\//){ 
            $componentName = $temp[$i+2];
            $componentName =~ s/\s*//;
        }
    }

    return $componentName;
}

1;
