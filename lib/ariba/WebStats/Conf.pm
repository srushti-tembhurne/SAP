# $Id: Conf.pm,v 1.1 1999/12/07 04:58:08 dsully Exp dsully $
# Stats configuration file.

# XXX - Should be dynamic from product! - dsully

package ariba::WebStats::Conf;

use strict;
use vars qw(@ISA @EXPORT %servers);
use Exporter;

@ISA	= qw(Exporter);
@EXPORT = qw(%servers);

%servers = (

	'web11' => {
		'host' => 'web11.snv.ariba.com',
		'log'  => '/var/log/apache',
		'type' => 'apache',
		'rdir' => 0,
		'rcp'  => 1,
		'ssl'  => 0,
	},

	'web11-ssl' => {
		'host' => 'web11.snv.ariba.com',
		'log'  => '/var/log/apache',
		'type' => 'apache',
		'rdir' => 0,
		'rcp'  => 1,
		'ssl'  => 1,
	},

	'web12' => {
		'host' => 'web12.snv.ariba.com',
		'log'  => '/var/log/apache',
		'type' => 'apache',
		'rdir' => 0,
		'rcp'  => 1,
		'ssl'  => 0,
	},

	'web12-ssl' => {
		'host' => 'web12.snv.ariba.com',
		'log'  => '/var/log/apache',
		'type' => 'apache',
		'rdir' => 0,
		'rcp'  => 1,
		'ssl'  => 1,
	},
);

1;

__END__
