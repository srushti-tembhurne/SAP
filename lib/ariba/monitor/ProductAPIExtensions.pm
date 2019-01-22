#
# $Id: //ariba/services/monitor/lib/ariba/monitor/ProductAPIExtensions.pm#6 $
#
package ariba::monitor::ProductAPIExtensions;

use ariba::HTTPWatcherPlugin::AES;
use ariba::HTTPWatcherPlugin::TomcatAppInstance;
use ariba::monitor::Url;
use ariba::rc::Product;
use ariba::util::PerlRuntime;

INIT {
	ariba::util::PerlRuntime::addCategoryToClass(__PACKAGE__, ariba::rc::Product);
}

sub appNamesWithRecordDowntimeStatus {
	my $product = shift;

	my $class   = ref($product);
	my @apps    = ();

	#XXX ASP customers currently don't have appflags
	#XXX We need ASP product AppInstance.pm!!	
	if ( $product->isASPProduct() ) {

		# this is somewhat magic - it puts these into a global cache.
		#XXX this is also completely bogus that we have hardcoded anything
		#XXX with product names.  We mis-use our HTTP watcher plugins
		#XXX because we don't have AppInstance.pm to rely on

		if ( $product->name() eq "aes" ) {
			ariba::HTTPWatcherPlugin::AES::urls($product);

		} elsif ( $product->name() eq "anl" ) {
			ariba::HTTPWatcherPlugin::TomcatAppInstance::urls($product);

		} else {

			return undef;
		}

		for my $url (ariba::monitor::Url->listObjects()) {

			next unless $url->recordStatus() && $url->recordStatus() eq 'yes';
	
			push @apps, join(' - ', ($url->displayName(), $url->instance()));
		}

		ariba::monitor::Url->_removeAllObjectsFromCache();

	} elsif ($class->can('appNamesWithRecordDowntimeStatus')) {

		@apps = $product->appNamesWithRecordDowntimeStatus();
	}

	return @apps;
}

1;
