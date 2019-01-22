package ariba::Automation::autolq::Builds;

#
# These subroutines generally fetch available labels given a product/release.
# 
# TODO: Move these out of the autolq hierarchy
# TODO: Integrate with build-info
# 

use strict 'vars';
use warnings;
use Data::Dumper;
use FileHandle;
use DirHandle;
use File::Basename;

sub loadStableBuilds {
    my ($product, $dir) = @_;
    my %stable;

    my $input = "$dir/$product/stable.txt";
    my @lines = readFile($input);

    foreach my $line (@lines) {
        my ($stem, @builds) = split(' ', $line);

        foreach my $build (@builds) {
            $stable{$stem}{$build} = 1;
        }
    }

    return \%stable;
}

sub readFile {
    my ($path) = @_;
    my @result;

    if (my $fh = new FileHandle $path) {
        while (my $line = <$fh>) {
            $line =~ s/\r*\n$//;
            push(@result, $line);
            last unless wantarray;
        }
    }

    if (wantarray) {
        return @result;
    } else {
        return $result[0];
    }
}

sub readComponents {
    my ($path) = @_;
    my %result;

    foreach (readFile($path)) {
        next if /^#/;
        my ($component, $version, $path) = split(' ');
        my $type = "ariba";
        $type = "test" if $component =~ /^test/;
        $type = "third" if $path =~ /3rdParty/;
        $component =~ s/^ariba\.//;
        $result{$type}{$component} = { version => $version, path => $path };
    }

    return \%result;
}

sub loadBuildSummary {
    my ($archive) = @_;

    my %build = parseBuildName($archive);

    if (-f "$archive/config/components.txt") {
        $build{branch} = readFile("$archive/config/BranchName");
        $build{release} = readFile("$archive/config/ReleaseName");
        # $build{components} = readComponents("$archive/config/components.txt");
        $build{time} = (stat("$archive/config/components.txt"))[9];
    }

    return \%build;
}

sub loadProductDetails {
    my ($product, $dir) = @_;

    my @builds = getProductBuilds($product, $dir);

    my %product;

    foreach my $raInfo (@builds) {
        my $rhBuild = loadBuildSummary($raInfo->{archive});

        if ($rhBuild->{time}) {
            my $stem = $rhBuild->{stem};
            my $build = $rhBuild->{build};
            my $release = $rhBuild->{release};
            $release =~ s/-OP\d+//;
            $release =~ s/\s+//; #FIX, remove spaces if any
            $product{"$release"}{branch} = $rhBuild->{branch};
            $product{"$release"}{release} = $release;
            $product{"$release"}{builds}{$build} = $rhBuild;
        }
    }

    return \%product;
}

sub getProductBuilds {
    my ($product, $dir) = @_;

    my $rhEntries = getDirEntries("$dir/$product", "d", qr/-\d+$/);
    my @builds;

    foreach my $entry (sort buildSorter keys %$rhEntries) {
        my %info = parseBuildName($rhEntries->{$entry});
        push(@builds, \%info);
    }

    return @builds;
}

sub buildSorter {
    my ($stem1, $build1) = $a =~ m/^(.*)-(\d+)$/;
    my ($stem2, $build2) = $b =~ m/^(.*)-(\d+)$/;

    return $stem1 cmp $stem2 || $build1 <=> $build2;
}

sub getDirEntries {
    my ($dir, $type, $pattern) = @_;
    my %entries;

    $type ||= "df";
    my $wantDirs = $type =~ /d/;
    my $wantFiles = $type =~ /f/;
    my $wantLinks = $type =~ /l/;

    if (my $dh = new DirHandle $dir) {
        while (my $entry = $dh->read()) {
            next if $entry =~ /^\./;
            next if $entry =~ /^locked/;
            my $path = "$dir/$entry";
            next if -l $path && !$wantLinks;
            next if -f $path && !$wantFiles;
            next if -d $path && !$wantDirs;
            next if $pattern && $entry !~ /$pattern/;
            $entries{$entry} = $path;
        }
    }

    return \%entries;
}

sub parseBuildName {
    my ($archive) = @_;

    my $name = basename($archive);
    my ($stem, $build) = $name =~ m/(.*)-(\d+)/;

    return (name => $name, stem => $stem, build => $build, archive => $archive);
}


1;
