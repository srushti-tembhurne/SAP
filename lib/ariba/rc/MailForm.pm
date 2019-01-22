package ariba::rc::MailForm;

my @FIELDS = qw (from to cc subject data);
my %OPTIONAL = ( "cc" => 1 );

#
# Constructor
#
sub new
{
    my ($class, @fields) = @_;

    my $self = {};
    bless($self,$class);

    foreach my $field (@FIELDS) 
    {
        $self->{$field} = shift @fields;
    }

    return $self;
}

#
# Make sure all required mail headers are present
#
sub check_headers
{
    my ($self, $headers) = @_;
    
    my ($err, $msg, $label) = (0, "", "");

    foreach my $field (@FIELDS) 
    {
		next if $OPTIONAL{$field};
        $label = ucfirst ($field);
        if (! $headers->{$label}) 
        { 
            $err = 1;
            $msg .= <<FIN;
Field "$label" missing<br>
FIN
        }
    }

    return ($err, $msg);
}

#
# Generate mail headers
#
sub get_headers
{
    my ($self, $cgi) = @_;
    my %headers;

	# make a hash of header => value
    foreach my $header (@FIELDS) 
	{
        $headers{ucfirst($header)} = $cgi->param($header) || "";
    }

	# Remove empty, optional headers
	foreach my $optional (keys %OPTIONAL)
	{
		if (! length $headers{ucfirst($optional)})
		{
			delete $headers{ucfirst($optional)};
		}
	}

    return \%headers;
}

#
# Print HTML mail compose form
#
sub print
{
    my ($self, $url, $fields) = @_;
    print <<FIN;
<form action="$url" method="POST">
FIN

    foreach my $field (keys %$fields) 
    {
        print <<FIN;
<input type="hidden" name="$field" value="$$fields{$field}">
FIN
    }

    print <<FIN;
<table border=0 cellpadding=3 cellspacing=3 width="1024">
<tr>
<td align=right width="15%"><b>From:</b></td>
<td align=left width="82%">$self->{'from'}</td>
</tr>
<tr>
<td align=right width="15%"><b>To:</b></td>
<td align=left width="82%"><input name="to" value="$self->{'to'}" size=64></td>
</tr>
<tr>
<td align=right width="15%"><b>Cc:</b></td>
<td align=left width="82%"><input name="cc" value="$self->{'cc'}" size=64></td>
</tr>
<tr>
<td align=right width="15%"><b>Subject:</b></td>
<td align=left width="82%"><input name="subject" value="$self->{'subject'}" size=64></td>
</tr>
<tr>
<tr>
<td valign=top align=right width="15%"><b>Body:</b></td>
<td align=left width="82%">
<textarea cols=90 rows=24 name="data">$self->{'data'}</textarea>
</td>
</tr>
<tr>
<td align=center colspan=2><input type=submit value="Send"></td>
</tr>
</table>
</form>
FIN
}

1;
