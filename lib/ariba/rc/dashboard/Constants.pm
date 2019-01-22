package ariba::rc::dashboard::Constants;

#
# Various constants related to the RC Dashboard project
#

use strict;
use warnings;

use constant VERSION        => '1.0';
use constant HTTP_TIMEOUT   => 30;
use constant CONFIG_FILE    => "/home/rc/etc/dashboard.xml";
use constant DB_FILE        => "/home/rc/etc/rcdb.db";
use constant DB_TABLE       => "timinginfo";
use constant SERVER_URL     => 'http://rc.ariba.com:8080/cgi-bin/dashboard';
use constant HANA_URL       => 'http://hana108.lab1.ariba.com:8000/ariba/rcdb/services/populate.xsjs';
use constant STATUS_RUNNING => 'running';
use constant STATUS_SUCCESS => 'success';
use constant STATUS_FAIL    => 'fail';
use constant STATUS_RESUME  => 'resume';

sub running               { return STATUS_RUNNING; }
sub success               { return STATUS_SUCCESS; }
sub fail                  { return STATUS_FAIL; }
sub resume                { return STATUS_RESUME; }
sub server_url            { return SERVER_URL; }
sub dashboard_config_file { return CONFIG_FILE; }
sub dashboard_db_file     { return DB_FILE; }
sub dashboard_db_table    { return DB_TABLE; }
sub http_timeout          { return HTTP_TIMEOUT; }
sub version               { return VERSION; }
sub hana_url              { return HANA_URL; }

1;
