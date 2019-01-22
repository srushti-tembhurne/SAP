package ariba::Automation::ConfigReader;

use strict;
use warnings;
use Carp;
use File::Basename;
use File::Find;
use IO::Handle;
use Ariba::P4::User;
use ariba::Ops::Logger;

my $logger = ariba::Ops::Logger->logger();

#
# Constructor
#
sub new {
    my ($class) = @_;
    my $self = {};
    bless ($self,$class);
    return $self;
}

sub load {
    my ($self, $file) = @_;
    return $self->_slurp ($file);
}

# Load a config file into a listref. 
# Supports #include directive.
sub _slurp {
    my ($self, $file) = @_;
    my @lines;
    my $fh;

    # caller responsible for error checking: method returns
    # undef if file can't be opened.
    if (open $fh, "<$file") {
        while (<$fh>) {
            chomp;

            # recursively load included config files
            if ($_ =~ m/^#include\s+(\S+)$/) {
                my $includedFile = $1;

                # pull file from perforce
                if ($includedFile =~ m#^//ariba#) {
                    my @raw = $self->_fetch_config_from_p4 ($includedFile);
                    if ($#raw != -1) {
                        # strip EOL characters from file
                        my @cooked;
                        foreach my $raw (@raw) {
                            chomp $raw;
                            push @cooked, $raw;
                        }
                        push @lines, "# Imported from $includedFile";
                        push @lines, @cooked;
                    } else {
                        $logger->warning ("P4 file not found $includedFile");
                    }
                } else {
                    my $dir = dirname($file);
                    my $includedConfig = join "/", $dir, $includedFile;
                    my $_lines = $self->_slurp ($includedConfig);

                    # fail silently if we can't open an included config file.
                    # these are optional and shouldn't be treated as an error.
                    if ($#$_lines != -1) {
                        push @lines, "# Imported from $includedConfig";
                        push @lines, @$_lines;
                    } else { 
                        $logger->warning ("File not found $includedFile");
                    }
                }
            } else {
                push @lines, $_;
            }
        }
    close $fh;
    } else {
        return;
    }

    return \@lines;
}

sub _fetch_config_from_p4 {
    my ($self, $path) = @_;
    
    Ariba::P4::p4s("sync $path");
    my %output = Ariba::P4::p4s("print -q $path");

    if ($output{error}) {
        $logger->warning ("Can't print $path from p4");
        return ();
    }

    if ($output{text}) {
        return @{$output{text}};
    }

    $logger->warning ("Empty file encountered fetching $path from p4");
    return ();
}

1;
