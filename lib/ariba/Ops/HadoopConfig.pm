package ariba::Ops::HadoopConfig; 

use XML::Simple;

use ariba::rc::Globals;

=pod

=head1 NAME

ariba::Ops::HadoopConfig - Hadoop Configuration File Object (Read Only)

=head1 VERSION

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/HadoopConfig.pm#3 $

=head1 SYNOPSIS

	my $conf = ariba::Ops::HadooopConfig->new("hdfs-site.xml");

	if ($conf->error()) {
		print "Error: " . $conf->error(), "\n";
	} else {
		my $value = $conf->valueForName('dfs.name.dir');
		my $description = $conf->descriptionForName('dfs.name.dir');
	}

=head1 DESCRIPTION

A read only object representing a Hadoop configuration file

=head1 INSTANCE METHODS

=over 4

=item * new( $xmlFile ) 

Creates a new config object using $xmlFile.
Automatically calls loadXmlFile($xmlFile).
Check $self->error() for loading errors.

=cut

sub new {
	my $class = shift; 
	my $xmlFile = shift;

	my $self = {}; 
	bless $self, $class; 

	$self->loadXmlFile($xmlFile);

	return $self;
}

=pod

=item * loadXmlFile ( $xmlFile ) 

Loads the $xmlFile.
This is automatically called when new($xmlFile) is called.

Sets $self->error() if fails to load the xml file.

=cut

sub loadXmlFile {
	my $self = shift;
	my $xmlFile = shift; 
	my $xml; 

	$self->{'xml'} = undef;

	eval {
		$xml = XMLin($xmlFile); 
	}; 

	$self->error("Failed to parse $xmlFile: $@") if ($@); 
	if (ref $xml) {
		$self->{'xml'} = $xml;
	} else {
		$self->error("Failed to parse $xmlFile: invalid xml ref");
	}

	$self->{'file'} = $xmlFile;
}

=pod

=item * valueForName ( $name ) 

Returns the value for the given name in the config file.
Returns undef if not found.

=cut

sub valueForName {
	return _namedValueForName(@_, 'value');
}

=pod

=item * descriptionForName ( $name ) 

Returns the description for the given name in the config file.
Returns undef if not found.

=cut

sub descriptionForName {
	return _namedValueForName(@_, 'description');
}

sub _namedValueForName {
	my $self = shift; 
	my $name = shift; 
	my $namedValue = shift; 

	return unless defined $name && defined $namedValue;
	return $self->{'xml'} && $self->{'xml'}->{'property'} && $self->{'xml'}->{'property'}->{$name} 
		&& $self->{'xml'}->{'property'}->{$name}->{$namedValue};
}

=pod

=item * error()

Gets error for loading config file.

=cut

sub error {
	my $self = shift; 
	my $msg = shift; 

	$self->{'error'} = $msg if (defined $msg);
	return $self->{'error'};
}

=pod

=item * fsCheckpointDir ( $hadoopProductInstance )

Returns the checkpoint dir based on fs.checkpoint.dir, or hadoop.tmp.dir, or defaults based on 
if the configs are set or not. 

=cut

sub fsCheckpointDir {
	my $self = shift; 
	my $hadoop = shift;
	my $dir; 

	if (my $checkpointDir = $self->valueForName('fs.checkpoint.dir')) {
		($dir) = split(/\s*,\s*/, $checkpointDir); 
	} elsif (my $tmpDir = $self->valueForName('dfs.name.dir')) {
		$dir = $tmpDir;
	} else {
		my $tmpDir = '/tmp/hadoop-' . ariba::rc::Globals::deploymentUser($hadoop->name(), $hadoop->service());
		$dir = "$tmpDir/dfs/namesecondary";
	}

	return $dir;
}


1;
