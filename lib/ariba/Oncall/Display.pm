package ariba::Oncall::Display;

# $Id: //ariba/services/monitor/lib/ariba/Oncall/Display.pm#6 $

use strict;
use CGI;

sub new {
	my $class = shift;
	my $forceHTML = shift;

	my $self = {};
	bless($self, $class);


	if ( $ENV{'REQUEST_METHOD'} || $forceHTML ) {
		$self->{'cgi'} = CGI->new();
		$self->{'style'} = 'html';
		$self->{'scheduleLink'} = '/cgi-bin/show-schedule';
		$self->{'contactLink'} = '/cgi-bin/list-contacts';
	} else {
		$self->{'style'} = 'text';
		$self->{'cgi'} = undef;
		$self->{'scheduleLink'} = undef;
		$self->{'contactLink'} = undef;
	}

	return $self;
}

sub scheduleLink {
	my $self  = shift;
	my $month = shift || '';
	my $year  = shift || '';

	return $self->{'scheduleLink'} . "?month=$month&year=$year";
}

sub contactLink {
	my ($self,$contact) = @_;

	if ( $contact ) {
		return $self->{'contactLink'} . "?person=$contact";
	} else {
		return $self->{'contactLink'};
	}
}

sub param {
	my ($self,$param) = @_;
	return $self->{'cgi'}->param($param) if defined $self->{'cgi'};
	return undef;
}

sub isHTML {
	my $self = shift;
	return $self->{'style'} eq 'html';
}

sub isText {
	my $self = shift;
	return $self->{'style'} eq 'text';
}

sub printHeaders { 
	my $self = shift;
	
	if ($self->{'style'} eq "html") {
		my $mime = $self->mimeType() || "text/html";
		my $disposition = $self->contentDisposition() || "inline";
		my $filename = $self->fileName() || "";
		print "Content-Type: $mime;\n";
		print "Content-Disposition: $disposition; filename=\"$filename\"\n\n";
	} 
		
}

sub setMimeType {
	my $self = shift;
	$self->{'mime'} = shift;
}

sub mimeType {
	my $self = shift;
	return $self->{'mime'};
}

sub setContentDisposition {
	my $self = shift;
	$self->{'contentdisposition'} = shift;

}

sub contentDisposition {
	my $self = shift;
	return $self->{'contentdisposition'};

}

sub setFileName {
	my $self = shift;
	$self->{'filename'} = shift;
}

sub fileName {
	my $self = shift;
	return $self->{'filename'};
}

1;

__END__
