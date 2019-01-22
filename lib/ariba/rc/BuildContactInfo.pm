package ariba::rc::BuildContactInfo;

# This module will fetch two values from product.bdf.
# It is abstracted at such a high level because the
# location of the contact info/threshold will change later.
#
# This module is used in three places:
#
# - cron-build
# - Qual robots
# - LQ
#
# LQ and cron-build do not rely on the threshold value.
# Qual robots do: they store # of consecutive failures.
#
# This module will fail silently unless $verbose is set to true.
# Verbose mode can be set as an optional second argument to 
# get_contact_info and get_contact_info_from_product_file. 
#
# TODO: Modify to use the Ariba-approved library for parsing
# product.bdf files instead of doing it by-hand.

use strict;
use warnings;
use Carp;
use Ariba::P4();
use ariba::rc::BuildDef;

{
# set to true for noisy error messages delivered via Carp 
my $verbose = 0;

# constant: name of file 
my $PRODUCT_BDF = "product.bdf";

# these are the lines we want from product.bdf
my @options = qw (RELEASE_CAPTAIN_EMAIL RELEASE_CONTACT_THRESHOLD BUILD_TIME_LIMIT ARCHIVE_TIME_LIMIT PUSH_TIME_LIMIT ARIBA_BUILD_INFO_EMAILS);

#
# Given a branch name, return build contact information from product.bdf
# 
sub get_contact_info
    {
    my ($targetBranchName, $_verbose, $product) = @_;
    $_verbose = $_verbose || 0;
    $verbose = $_verbose;

    # initialize requested options
    my @options = _get_requested_options();
    my %options;
    foreach my $opt (@options)
        {
        $options{$opt} = "";
        }

    # parse options from file
    _parse_product_file ($targetBranchName, \%options, $product);
    return _generate_results (\%options, \@options);
    }

#
# Given a path to product.bdf, return build contact information
# 
sub get_contact_info_from_product_file
    {
    my ($product_bdf, $_verbose) = @_;
    $_verbose = $_verbose || 0;
    $verbose = $_verbose;

    # initialize requested options
    my @options = _get_requested_options();
    my %options;
    foreach my $opt (@options)
        {
        $options{$opt} = "";
        }

    # load product.bdf into buffer
    my $buf = "";
    if (open FILE, $product_bdf)
        {
        while (<FILE>)
            {
            $buf .= $_;
            }
        close FILE;
        }
    else
        {
        carp "File not found: $product_bdf, $!" if $verbose;
        }

    # parse options from file
    _parse_product_file_contents ($buf, \%options);
    return _generate_results (\%options, \@options);
    }

#
# private
#

#
# make a list of results based on the options we want
#
sub _generate_results
    {
    my ($options, $requested_options) = @_;

    # generate list of arguments based on requested options
    my @results;
    foreach my $opt (@$requested_options)
        {
        push @results, $options->{$opt};
        }
    return @results;
    }

#
# get list of options we're interested in
#
sub _get_requested_options
    {
    return @options;
    }

#
# Determine path to product.bdf from branch name
#
sub _parse_product_file
    {
    my ($targetBranchname, $options, $product) = @_;
    my $cmd;

        if($product) {
           my $defFile = ariba::rc::BuildDef::prodConfigDefinitionFile($product, $targetBranchname);
           $cmd = "print $defFile";
        }
        else {
           $cmd = "print $targetBranchname/$PRODUCT_BDF";
        }
	my %out = Ariba::P4::p4s ($cmd);

	if ($out{'error'} || ! $out{'text'})
		{
		carp "P4 command \"$cmd\" failed: $out{'error'}\n" if $verbose;
		return $options;
		}
	
    return _parse_product_file_contents ($out{'text'}, $options);
    }

#
# Parse contact info from product.bdf
# 
sub _parse_product_file_contents
    {
    my ($buf, $options) = @_;

	my @lines = @{$buf};

    # search output for specified key/value pairs 
    # (release captain e-mail address, threshold, etc.) 
    foreach my $line (@lines)
        {
		chomp $line;

        if ($line =~ m#^(\S+)\s+=\s+(.*)$#)
            {
            my ($key, $value) = ($1, $2);
            if (exists $options->{$key})
                {
                $options->{$key} = $value;
                }
            }
        }
    #
    # fix RELEASE_CAPTAIN_EMAIL when @ariba.com is missing.
    #
    if ($options->{'RELEASE_CAPTAIN_EMAIL'})
        {
        my @raw = split /,/, $options->{'RELEASE_CAPTAIN_EMAIL'};
        my @cooked;

        foreach my $addr (@raw)
            {
            # strip leading/trailing whitespace
            $addr =~ s/^\s+//;
            $addr =~ s/\s+$//;

            # append ariba.com to e-mail address if it is missing
            if ($addr !~ m#\@#)
                {
                $addr .= '@sap.com';
                }
            push @cooked, $addr;
            }

        # overwrite old list of addresses
        $options->{'RELEASE_CAPTAIN_EMAIL'} = join ',', @cooked;
        }

    return $options;
    }
}

1;
