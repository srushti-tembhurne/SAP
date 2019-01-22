# $Id: //ariba/services/tools/lib/perl/ariba/rc/IncrBuildPlugins/DBSchemaChangeDetectorPlugin.pm#7 $
package ariba::rc::IncrBuildPlugins::DBSchemaChangeDetectorPlugin;

use strict;
use warnings;
use ariba::rc::CompMeta;

use base ("ariba::rc::IncrBuildPlugins::IncrBuildPluginBase");

my $ARIBA_INSTALL_ROOT=$ENV{'ARIBA_INSTALL_ROOT'};
my $DB_SCHEMA_CHANGE_DETECTED_FILE = "$ARIBA_INSTALL_ROOT/internal/build/dbschemachanged";

# This plugin does not trigger transitive rebuilds so always return 0.
# If an aml file has been changed in such a way as to impact DB schema, then
# signal this in the dbschemachanged file (robot-initdb startAction will monitor)
sub isTransitiveRebuildRequired {
    my ($self, $deltaCompMeta) = @_;

    $self->_updateDBSchemaChangeDetectedFile($deltaCompMeta);
    return 0;
}

sub _preloadComp {
    my ($self, $productUniversMap) = @_;

    $self->{'detectedDBSchemaChange'} = 0;

    my $incrBuildMgr = $self->{'incrBuildMgr'};
    my $buildName = $incrBuildMgr->{'buildName'};

    print "IncrBuildPlugins::DBSchemaChangeDetectorPlugin is initializing\n";

    if ($incrBuildMgr->{'fullBuild'}) {
        print "IncrBuildPlugins::DBSchemaChangeDetectorPlugin Creating $DB_SCHEMA_CHANGE_DETECTED_FILE (this is a full incr build) for build \"$buildName\"\n";
        $self->_updateDBSchemaChangeDetectedFileAux($buildName);
    }
    elsif (! -f $DB_SCHEMA_CHANGE_DETECTED_FILE) {
        print "IncrBuildPlugins::DBSchemaChangeDetectorPlugin Creating $DB_SCHEMA_CHANGE_DETECTED_FILE (the file does not exist) for build \"$buildName\"\n";
        $self->_updateDBSchemaChangeDetectedFileAux($buildName);
    }
}

sub _updateDBSchemaChangeDetectedFile {
    my ($self, $deltaCompMeta) = @_;

    my $incrBuildMgr = $self->{'incrBuildMgr'};
    my $buildName = $incrBuildMgr->{'buildName'};

    return if ($self->{'detectedDBSchemaChange'}); # We alredy detected there is a change; no need to keep checking

    print "IncrBuildPlugins::DBSchemaChangeDetectorPlugin Checking for any db schema changes\n";

    my $fileDiffsRef = $deltaCompMeta->getFileDiffs();
    if (defined $fileDiffsRef) {
        my @fileDiffs = @{$fileDiffsRef};
        my $compName = $deltaCompMeta->getName();
        foreach my $diff (@fileDiffs) {
            if (($diff =~ /==== content/ || $diff =~ /<none>/) &&
                ($diff =~ /.aml/ || $diff =~ /initdb/i || $diff =~ /migrat/i || $diff =~ /realm/i || $diff =~ /qual/i || $diff =~ /restor/i)) {

                # DB Schema impacting change is detected
                # Either an AML or an initdb, restore or migrate tool change

                # TODO: Compare prior aml file against changed aml file to more granularly detect subset of AML changes
                # (skip comment or visibility changes for example)

                print "IncrBuildPlugins::DBSchemaChangeDetectorPlugin detected a possible DB schema impacting change to component \"$compName\" for build \"$buildName\"\n";
                print "\tThe diff is $diff\n";
                $self->_updateDBSchemaChangeDetectedFileAux($buildName);
                last; # Note: we will retain the existing DB_SCHEMA_CHANGE_DETECTED_FILE if no new schema change is detected
            }
        }
    }
}

sub _updateDBSchemaChangeDetectedFileAux {
    my ($self, $buildName) = @_;


    print "Creating $DB_SCHEMA_CHANGE_DETECTED_FILE to signal that build \"$buildName\" requires that the initdb migration needs to be run\n";

    open (my $fh, ">", $DB_SCHEMA_CHANGE_DETECTED_FILE) or die "Cannot open $DB_SCHEMA_CHANGE_DETECTED_FILE : $!" ;
    print $fh $buildName;
    close ($fh) or die "Cannot close $DB_SCHEMA_CHANGE_DETECTED_FILE : $!" ;

    if (-f $DB_SCHEMA_CHANGE_DETECTED_FILE) {
        print "The file $DB_SCHEMA_CHANGE_DETECTED_FILE has been created\n";
        $self->{'detectedDBSchemaChange'} = 1;
    }
    else {
        print "The file $DB_SCHEMA_CHANGE_DETECTED_FILE did not get created\n";
    }
}

1;
