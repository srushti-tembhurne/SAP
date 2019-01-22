package ariba::Ops::Startup::S4;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/Startup/S4.pm#1 $

use strict;

use File::Path;
use File::Basename;
use ariba::Ops::Startup::Common;
use ariba::Ops::Startup::Tomcat;
use ariba::rc::Utils;

sub createSymlinkForSystemRealmScratchArea {
	my $me = shift;
	my $realmRootDir =  $me->default('System.Base.RealmRootDir');
	my $attachmentDir = $me->default('System.Base.Directories.AttachmentDir');
	#
	# Setup system realm area under realm root dir and create symlink
	# from install root to this area for storing some data that needs to
	# be on shared fs.
	#
	# XXXX Should be taken out once bug 1-GHHC is fixed.
	#
	if ($realmRootDir && $attachmentDir) {
		my $attachRoot = dirname($attachmentDir);
		my $systemRealmAttachmentDir = "$realmRootDir/system/$attachRoot";
		my $installRootAttachmentDir = "$main::INSTALLDIR/$attachRoot";
		mkdirRecursively($systemRealmAttachmentDir);

		#
		# if attachement root already exists, delete it and
		# recreate it as a symlink
		#
		# Do this only if the attachmentdir is not pointing to
		# the right location. This is so that when we are doing
		# rolling restart, we are not deleting something that
		# another node might be using actively
		#
		if (-l $installRootAttachmentDir &&
		       readlink($installRootAttachmentDir) ne $systemRealmAttachmentDir) {
			rmdirRecursively($installRootAttachmentDir);
			symlink($systemRealmAttachmentDir, $installRootAttachmentDir) || print "Error: Could not create symlink from $installRootAttachmentDir to $systemRealmAttachmentDir, $!\n";
		}
	}
}

1;

__END__
