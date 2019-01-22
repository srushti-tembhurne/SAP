package ariba::Ops::CFEngine::PackageHelper;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/CFEngine/PackageHelper.pm#27 $
# wrapper around pkgadd/swinstall to do the right thing, 
# and deal with gzipped files.

use strict;

my $os       = $^O;
my $null     = '> /dev/null 2>&1';
my $debug    = 0;

chomp(my $arch = `uname -m`);

my %packageUtilities = (

	'solaris' => {

		'install' => '/usr/sbin/pkgadd -d %s all %s',
		'remove'  => '/usr/sbin/pkgrm  -A -n %s %s',
		'verify'  => '/usr/bin/pkginfo %s %s',
	},

	'hpux' => {
		'install' => '/usr/sbin/swinstall -x mount_all_filesystems=false -x reinstall=true -s %s \\* %s',
		'remove'  => '/usr/sbin/swremove %s %s',
		'verify'  => '/usr/sbin/swlist %s %s',
	},

	'linux' => {
		'install' => '/bin/rpm --nodeps --force -U %s %s',
		'installkernel' => '/bin/rpm -ivh %s %s',
		'remove'  => '/bin/rpm --nodeps -e %s %s',
		'verify'  => '/bin/rpm -q %s %s',
	},
);

###########################################################
sub setDebug {
	my $class = shift;

	$debug = shift;

	# we want to see the output of the programs in debug mode.
	$null  = '' if $debug;
}

sub add {
	my $class   = shift;
	my $package = shift || return 0;
	my $file    = $package;

	# It's too bad the package managers can't handle this automatically.
	if ($file =~ /\.gz$/) {

		my $gunzip = gunzip();

		print  "\tsystem: $gunzip $file\n" if $debug;

		system "$gunzip $file" if $debug < 2;

		$file =~ s/\.gz$//o;
	}

	# HPUX needs both the file and package name.
	if ($os eq 'hpux') {

		my @parts = split(m|/|, $package);

		$package = pop(@parts);
		$package =~ s/^(\S+?)-.*/$1/;

		$file .= " $package";
	}

        my $kernel_regex = qr'kernel\-((large)?smp-)?[0-9]';

	if ($os eq 'linux') {

		my $installedRpm = installedRpmForFile($file);

		if ( defined($installedRpm) && ( $installedRpm ne '' and $installedRpm !~ /^$kernel_regex|^rpm\-[0-9]|^bash-/ and rpmHasUninstallScripts($installedRpm) ) ) {

			# if you call remove() you'll need to pass it a file name which
			# we could hack together but it's ugly. call runPackageCommand
			# directly instead to do the remove.
			my $retVal = runPackageCommand('remove', $installedRpm);

			# if the remove fails for some reason we need to let our
			# caller know about it rather than continue with the install
			return $retVal unless $retVal;
		}
	}
        my $ret;
        if ($file =~ /$kernel_regex/i) {
           $ret = runPackageCommand('installkernel', $file);
        } else {
           $ret = runPackageCommand('install', $file);
        }

	if ($os eq 'hpux') {
		$file =~ s/\s+$package$//go;
	}

	unlink $file or die "Can't unlink [$file]";

	return $ret;
}

sub remove {
	my $class = shift;
	my $file  = shift || return 0;

	my $package = packageNameFromFile($file);

	return runPackageCommand('remove', $package);
}


sub check {
	my $class = shift;
	my $file  = shift || return 0;

	my $found   = 0;
	my $package = packageNameFromFile($file);

	return runPackageCommand('verify', $package);
}

sub runPackageCommand {
	my $action     = shift;
	my $package    = shift;
	my $returnCode = 1;

	if (defined $packageUtilities{$os}->{$action}) {

		my $command = sprintf($packageUtilities{$os}->{$action}, $package, $null);

		print  "\tsystem: $command\n" if $debug;

		if ( $debug < 2 ) {
			system($command) if $debug < 2;
			# Reverse the return value - C/shell uses 0 to mean true, but in perl
			# we use 0 to mean false, and 1 to be true.
			$returnCode = (($? >> 8) == 0) ? 1 : 0;
		}

	} else {

		print  "\twarning - no command for installing on $os !\n";
	}

	print "	Return code is: $returnCode\n" if $debug;
	return $returnCode;

}

sub packageNameFromFile {
	my $name = shift;

	# linux can have package names longer than 9 chars.
	# So shift off the .$arch.rpm
	if ($^O eq 'linux') {

		my @parts = split /\./, $name;

		if ($name =~ /\.rpm$/) {
			pop @parts;
		}

		# and now the arch
		my $arch = pop @parts;

		$name = join('.', @parts);

		# Strip off the -usr/-root/-local
		$name =~ s/^(.*)-[^-]+$/$1/;

		# We need include the architecture when selecting rpms on our redhat hosts
		# because we sometimes install both the 32 and 64 bit versions
		print "	Package name is: $name.$arch\n" if $debug;
		return "$name.$arch";
	
	} else {

		$name =~ s/^([a-zA-Z0-9]+).*$/$1/;

		print "	Package name is: $name\n" if $debug;
		return "$name";
	}

}

sub gunzip {

	for my $path (qw(/usr/local/bin /usr/contrib/bin /usr/bin)) {

		return "$path/gunzip -f" if -x "$path/gunzip";
	}

	die "FATAL - Couldn't find valid gunzip command!";
}

sub installedRpmForFile {
	my $file = shift;

	my $installedRpm = '';

	# Check if the file we are about to install will upgrade an existing rpm
	my $query = qq(/bin/rpm -qp $file --qf "\%{NAME} \%{ARCH}");

	open(RPMQ, "$query |") or die "Unable to run [$query]: $!";

	my ($packageName, $packageArch) = split(/\s/, <RPMQ>);
	
	close(RPMQ);

	open(RPMS, "/bin/rpm -q ${packageName}.${packageArch} |") or die "Unable to run rpm query on [${packageName}.${packageArch}]: $!";

	chomp( my @matches = <RPMS> );

	close(RPMS);

	unless ( grep /not installed/, @matches ) {

		my $count = scalar @matches;

		die "Found more than one rpm matching [${packageName}.${packageArch}]" if ($count > 1);

		$installedRpm = shift @matches;

		if ( defined($installedRpm) ) {
			$installedRpm .= ".${packageArch}"
		}
	}

	print "\tinstalledRpm [$installedRpm]\n" if $debug;

	return $installedRpm;
}

sub rpmHasUninstallScripts {
	my $installedRpm = shift;

	# keys are rpm query tags for preuninstall and postuninstall scripts
	# values are whether the installed rpm has these scripts (0/1 = no/yes)
	my %queryTags = (
		'PREUN'		=>	0,
		'POSTUN'	=>	0,
	);

	foreach my $queryTag (keys %queryTags) {

		my $rpmQuery = qq(/bin/rpm -q $installedRpm --qf "\%{$queryTag}");

		print "\trpmQuery [$rpmQuery]\n" if $debug;

		open(QUERY, "$rpmQuery |") or die "Unable to run query [$rpmQuery]: $!";

		chomp( my $results = <QUERY> );

		close(QUERY);

		if ( $results ne '(none)' ) {

			print "\t[$queryTag] query tag defined for [$installedRpm]\n" if $debug;
			$queryTags{$queryTag} = 1;
		}
	}

	return ( ($queryTags{'PREUN'} or $queryTags{'POSTUN'}) ? 1 : 0 );
}

1;

__END__
