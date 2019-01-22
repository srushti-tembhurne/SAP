# Simple interface to HTTP.  This has no dependencies on any other Ariba module.  Everything Ariba specific should be handled
# by the parent scripts and/or modules.

package ariba::Ops::HTTP;

use strict;
use warnings;

use Data::Dumper;

use LWP::UserAgent;
use HTTP::Request::Common;

sub new
{
    my $class = shift;
    my $url  = shift;
    my $http  = {};

    # The url must have this form:
    $url =~ m@^http://@
        or die "ERROR:  invalid url ($url), must begin with http://.\n";
    $http->{userAgent} = LWP::UserAgent->new;
    $http->{url}       = $url;

    return bless ($http, $class);
}

# This method returns a data string.
sub get_data
{
    my $self = shift;

    # Build up a header to handle the above.
    my $request = HTTP::Request::Common::GET($self->{url},);
    my $dataRef = $self->{userAgent}->request ($request);
    if ($dataRef->is_success)
    {
        return $dataRef->content;
    }
    else
    {
        die "ERROR:  data retrieval failed for '", $self->{url}, "', aborting!\n", $dataRef->status_line, "\n";
    }
}

1;

__END__
