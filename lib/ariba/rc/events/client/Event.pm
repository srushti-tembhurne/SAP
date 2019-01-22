package ariba::rc::events::client::Event;

#
# Perl wrapper around RC Events HTTP API
#

use strict;
use warnings;
use vars qw ($AUTOLOAD);
use Carp;
use Data::Dumper;
use LWP::UserAgent;
use Time::HiRes;
use ariba::rc::events::Constants;

{
    #
    # Constants
    #
    my @REQUIRED = qw (channel title description);
    my @OPTIONAL = qw (_timeout url _last_error id create_date republished channel_name _server _naptime);
    my %OPTIONAL = map { $_ => 1 } @OPTIONAL;
    my @INTERNAL = qw (verbose debug _last_error _server _naptime);
    my %INTERNAL = map { $_ => 1 } @INTERNAL;
    my %LEGAL = map { $_ => 1 } @REQUIRED, @OPTIONAL, @INTERNAL;
    my %DEFAULTS = 
    (
        id => 0,
        debug => 0,
        verbose => 0,
        republished => 0,
        channel_name => "", 
        _server => "",
        _version => ariba::rc::events::Constants::version(),
        _timeout => ariba::rc::events::Constants::http_timeout(),
        _last_error => 0, 
        _max_retries => 3,
        _naptime => 1.25,
    );

    #
    # Constructors
    #

    sub newFromDirtyObject
    {
        my ($class, $hashref) = @_;
        my $self = $class->new ($hashref, 1);
        return $self;
    }

    sub new
    {
        my ($class, $hashref, $is_dirty) = @_;
    
        $is_dirty = $is_dirty || 0;

        my $self = $hashref ? $hashref : {};
        $self->{'_last_error'} = "";

        # 
        # Check for legal arguments
        #
        foreach my $key (keys %$hashref)
        {
            if (! exists $LEGAL{$key})
            {
                carp "Warning: Unknown key passed to constructor: $key\n" unless $is_dirty;
            }
            else
            {
                $self->{$key} = $hashref->{$key};
            }
        }
        
        #
        # Assign default values
        #
        foreach my $key (keys %DEFAULTS)
        {
            if (! exists $self->{$key})
            {
                $self->{$key} = $DEFAULTS{$key};
            }
        }

        #
        # Generate HTTP User-Agent value
        #
        $self->{'_useragent'} = join "/", "Event", $self->{'_version'};

        bless $self, ref ($class) || $class;
        # bless ($self, $class);
        return $self;
    }

    #
    # Return true if all required attributes are present
    #
    sub is_valid
    {
        my ($self) = @_;

        my $required_count = @REQUIRED;
        my $actual_count = 0;

        foreach my $key (@REQUIRED)
        {
            if (exists $self->{$key})
            {
                ++$actual_count;
            }
        }

        return $actual_count == $required_count;
    }

    sub set_server
    {
        my ($self, $server) = @_;
        $self->{'_server'} = $server;
    }

    #
    # Send to event server
    #
    sub _publish
    {
        my ($self) = @_;

        my $ua = LWP::UserAgent->new();
        $ua->timeout ($self->_timeout());
        $ua->agent ($self->_useragent());

        # generate key/value pairs to send to remote server
        my $hashref = 
            {
            'event' => 'publish', 
            };

        # iterate over attributes
        foreach my $key (keys %$self)
        {
            # skip private/internal-only attributes
            if (! $self->is_private ($key) && ! $self->is_internal ($key))
            {
                $hashref->{$key} = $self->{$key};
            }
        }

        # allow for alternate server to be specified (handy for debugging)
        my $server = $self->{'_server'} || ariba::rc::events::Constants::server();

        # send via HTTP POST
        my $response = $ua->post ($server, $hashref);

        # break server response into lines
        my $reply = $response->content;
        my @lines = split /\n/, $reply;

        return ($response, \@lines);
    }

    sub publish
    {
        my ($self) = @_;

        my $done = 0;
        my $tries = 0;
        my ($response, $lines);
        my $naptime = $self->{'_naptime'};

        print "Publishing...\n" if $self->verbose();
        while (! $done)
        {
            my $start_time = Time::HiRes::time();

            eval 
            {
                ($response, $lines) = $self->_publish();
            };

            # give up if we've exceeded number of retries
            if (++$tries >= $self->{'_max_retries'})
            {
                print "Giving up after $tries tries\n" if $self->verbose();
                $done = 1;
            }
            print "Attempt #$tries took " . (Time::HiRes::time() - $start_time) . "s\n" if $self->verbose();

            if ($@)
            {
                $self->handle_error 
                (
                    "Unexpected error: " . $@,
                    $response
                );
                return 0 if $done;
            }

            # complain if web server gives HTTP 200 but otherwise no response
            if ($#$lines == -1)
            {
                $self->handle_error 
                (
                    ariba::rc::events::Constants::error_empty_response(), 
                    $response
                );
                return 0 if $done;
            }
    
            # complain upon unexpected server reply
            elsif ($$lines[$#$lines] ne ariba::rc::events::Constants::success())
            {
                $self->handle_error 
                (
                    ariba::rc::events::Constants::error_server_reply(),
                    $response
                );
                return 0 if $done;
            }

            # complain if transaction failed
            elsif (! $response->is_success)
            {
                $self->handle_error 
                (
                    ariba::rc::events::Constants::error_http_post(), 
                    $response
                );
                return 0 if $done;
            }

            # went better than expected
            else
            {
                print "Success\n" if $self->verbose();
                $done = 1;
            }

            # debugging
            if ($self->verbose())
            {
                print "Server Response: [" . $self->pretty_print ($response->content()) . "]\n";
            }

            if (! $done)
            {
                # sleep between attempts
                print "Napping for $naptime seconds\n" if $self->verbose();
                Time::HiRes::sleep ($naptime);
                $naptime += $naptime;
            }
            else
            {
                print "All done\n" if $self->verbose();
            }
        }

        return 1;
    }

    sub pretty_print
    {
        my ($self, $content) = @_;
        chomp $content;
        return $content;
    }

    #
    # Share recent error message from event class
    #
    sub get_last_error
    {
        my ($self) = @_;
        return $self->{'_last_error'};
    }
    
    #
    # Pretty-print HTTP error if verbose flag enabled
    #
    sub handle_error
    {
        my ($self, $failure, $response) = @_;

        #
        # Store information about last error encountered
        #
        my $error = join "\n", 
            "Error delivering event: [$failure]", 
            "  URL: [" . ariba::rc::events::Constants::server() . "]", 
            "  Content: [" . $self->pretty_print ($response->content) . "]", 
            "  Status line: [" . $self->pretty_print ($response->status_line) . "]", 
            "  Request: [" . $response->request->as_string . "]";
        
        $self->{'_last_error'} = $error; 

        #
        # Don't carp unless verbose flag is enabled
        #
        carp $error if $self->verbose();
    }

    #
    # True if attribute is internal-only i.e. don't send attribute to server
    #
    sub is_internal
    {
        my ($self, $key) = @_;
        return exists $INTERNAL{$key} ? 1 : 0;
    }

    #
    # True if attribute is private
    #
    sub is_private
    {
        my ($self, $key) = @_;
        return substr ($key, 0, 1) eq "_" ? 1 : 0;
    }

    #
    # Debugging
    #
    sub dump
    {
        return Dumper ($_[0]);
    }

    #
    # Accessors
    #
    sub AUTOLOAD
    {
        no strict "refs";
        my ($self, $newval) = @_;

        my @classes = split /::/, $AUTOLOAD;
        my $accessor = $classes[$#classes];

        if (exists $self->{$accessor})
        {
            if (defined ($newval))
            {
                $self->{$accessor} = $newval;
            }
            return $self->{$accessor};
        }
        carp "Unknown method: $accessor\n";
    }

    #
    # Destructor
    #
    sub DESTROY
    {
        my ($self) = @_;
    }
}

1;
