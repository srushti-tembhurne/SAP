package ariba::Apache::Dispatcher;

# $Id: //ariba/services/tools/lib/perl/ariba/Apache/Dispatcher.pm#5 $

use strict;

use ariba::Apache::Util;
use ariba::util::PerlRuntime;

use Apache2;
use Apache::Const -compile => qw(:common :http);
use Apache::RequestRec ();
use Template::Config;
use Template::Constants qw(:debug);

# Make the templates use C code
$Template::Config::STASH = 'Template::Stash::XS';

# Never invoke directly. Should be subclassed!
# The prototype is required for mod_perl to know what should be passed.
sub handler : method {
	my ($class,$r) = @_;

	# we weren't subclassed.
	return Apache::HTTP_INTERNAL_SERVER_ERROR() if ref($class) eq __PACKAGE__;

	# this turns something like /user/login to ->dispatch_login()
	# and /user/process/login to ->dispatch_processLogin()
	my $handler = $class->findHandlerForRequest($r) || return Apache::HTTP_INTERNAL_SERVER_ERROR();

	eval {
		#local $SIG{__DIE__} = sub {
		#	die &ariba::util::PerlRuntime::dumpStack;
		#};

		my ($contentType, $view) = $class->$handler($r);

		# short circuit on redirect
		return Apache::HTTP_MOVED_TEMPORARILY() if $contentType eq Apache::HTTP_MOVED_TEMPORARILY();

		# we might be sending text/xml
		$r->content_type($contentType || 'text/html');

		# run it through Template toolkit
		return $class->processTemplate({
			TEMPLATE	=> $view->{'template'},
			DATA		=> $view,
		});
	};

	if ($@) {
		$r->status(Apache::HTTP_INTERNAL_SERVER_ERROR());
		$r->content_type('text/html');
		$r->print("An error occured while trying to run $class\:\:$handler()<p><pre>$@</pre>\n");
	};
}

# run this through Template Toolkit.
# We can take either a FH, or default to APR's output
sub processTemplate {
	my ($class, $vars, $output) = @_;

	my $apr = ariba::Apache::Util->getRequest();

	my $tt  = $class->templateEngine() || do {

		$apr->log_error("No template engine exists for $class!");

		return Apache::HTTP_INTERNAL_SERVER_ERROR();
	};

	$tt->process(
		$vars->{'TEMPLATE'},
		$vars->{'DATA'},
		$output || $apr,

	) || do {

		$apr->log_error($tt->error());

		return Apache::HTTP_INTERNAL_SERVER_ERROR();
	};

	return Apache::OK();
}

sub findHandlerForRequest {
	my $class     = shift;
	my $r         = shift;

	# get just the uri parts.
	# $r->path_info() doesn't get us what we want.
	my $uri	      = $r->uri(); 
	   $uri	      =~ s|^/||o;

	my @parts     = split '/', $uri;
	my $pathInfo  = $parts[-1];
	my $handler   = scalar @parts > 1 ? "dispatch_$pathInfo" : "dispatch_index";

	# we're good.
	if (UNIVERSAL::can($class, $handler)) {
		return $handler;
	}

	$r->content_type('text/html');
	$r->print("An error occured while trying to access [" . $r->uri() . "]<p>\n");
	$r->log_error(sprintf("$class\:\:$handler() does not exist for %s\n", $r->uri()));

	return undef;
}

1;

__END__
