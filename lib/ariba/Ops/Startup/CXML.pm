package ariba::Ops::Startup::CXML;

use strict;

sub createSymLinks
{
	my $me = shift;

	my $currentVer = join('/', ($me->docRoot(), $me->default('specsRoot'), $me->default('curVersion')));
	my $linkName   = $me->docRoot(). "/current";

	$currentVer =~ s/\s*$//;

	unlink $linkName;

	print "Creating $linkName -> $currentVer\n";

	symlink($currentVer, $linkName) || die "Error: Could not create symlink to $currentVer, $!\n";
}

1;

__END__
